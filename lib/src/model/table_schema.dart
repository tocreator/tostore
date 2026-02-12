import 'dart:math' show sqrt;
import 'dart:typed_data';
import 'dart:convert';
import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../handler/sha256.dart';
import '../handler/value_matcher.dart';
import 'business_error.dart';

/// table schema
class TableSchema {
  /// Table name
  final String name;

  /// Primary key configuration
  final PrimaryKeyConfig primaryKeyConfig;

  /// Field list
  final List<FieldSchema> fields;

  /// Index list
  final List<IndexSchema> indexes;

  /// Foreign key constraints list
  final List<ForeignKeySchema> foreignKeys;

  /// Whether it's a global table
  final bool isGlobal;

  /// Table unique identifier, used for rename detection
  final String? tableId;

  // Default constructor
  const TableSchema({
    required this.name,
    required this.primaryKeyConfig,
    required this.fields,
    this.indexes = const [],
    this.foreignKeys = const [],
    this.isGlobal = false,
    this.tableId,
  });

  /// Get primary key name
  String get primaryKey => primaryKeyConfig.name;

  /// Returns a new map with primary key first, then other fields in original order.
  /// Use when returning rows from storage so display/serialization shows PK first.
  static Map<String, dynamic> rowWithPrimaryKeyFirst(
    String primaryKeyName,
    dynamic primaryKeyValue,
    Map<String, dynamic> row,
  ) {
    final out = <String, dynamic>{};
    out[primaryKeyName] = primaryKeyValue;
    for (final e in row.entries) {
      if (e.key == primaryKeyName) continue;
      out[e.key] = e.value;
    }
    return out;
  }

  /// Get all indexes (Consolidated list of Explicit, Unique, and FK indexes)
  List<IndexSchema> getAllIndexes() {
    final allIndexes = <IndexSchema>[];
    final existingIndexNames = <String>{};
    // Track which fields are already the *prefix* of an index
    // Key: Field Name, Value: Is this field the first field in an index?
    final fieldIndexPrefixMap = <String, bool>{};

    // 1. Add explicit indexes
    for (final index in indexes) {
      if (_isPrimaryKeyOnlyIndex(index)) {
        Logger.warn(
          'Table $name contains redundant primary-key index ${index.actualIndexName}; table data is already range-partitioned by PK, ignoring this index.',
          label: 'TableSchema.getAllIndexes',
        );
        continue;
      }
      allIndexes.add(index);
      existingIndexNames.add(index.actualIndexName);
      if (index.fields.isNotEmpty) {
        fieldIndexPrefixMap[index.fields.first] = true;
      }
    }

    // 2. Add implicit unique indexes and field-level indexes
    for (final field in fields) {
      // Skip primary key (already handled by storage engine)
      if (field.name == primaryKey) continue;

      if (field.unique) {
        // Check if there's already an explicit unique index on this single field
        final alreadyHasUniqueIndex = indexes.any((i) =>
            i.unique && i.fields.length == 1 && i.fields.first == field.name);

        if (!alreadyHasUniqueIndex) {
          // Avoid duplicate names (though unlikely if schema validation is correct)
          final uniqueIndexSchema = IndexSchema(
            indexName: field.name,
            fields: [field.name],
            unique: true,
          );
          if (!existingIndexNames.contains(uniqueIndexSchema.actualIndexName)) {
            allIndexes.add(uniqueIndexSchema);
            existingIndexNames.add(uniqueIndexSchema.actualIndexName);
            fieldIndexPrefixMap[field.name] = true;
          }
        }
      } else if (field.createIndex) {
        // Identify if there is an explicit index on this field
        // Note: Even if there is a composite index starting with this field,
        // if the user explicitly marks createIndex, we prefer to create a separate independent index
        // to ensure simple query optimization (unless a single-field index already exists).
        final alreadyHasIndex = indexes
            .any((i) => i.fields.length == 1 && i.fields.first == field.name);

        if (!alreadyHasIndex) {
          final indexSchema = IndexSchema(
            indexName: field.name,
            fields: [field.name],
            unique: false,
          );

          // Check if we already created a unique index derived from field.unique above
          // (Actually if field.unique is true, we entered the block above, not this one)
          // So just check name collision
          if (!existingIndexNames.contains(indexSchema.actualIndexName)) {
            allIndexes.add(indexSchema);
            existingIndexNames.add(indexSchema.actualIndexName);
            fieldIndexPrefixMap[field.name] = true;
          }
        }
      }
    }

    // 3. Add implicit foreign key indexes
    for (final fk in foreignKeys) {
      if (!fk.enabled || !fk.autoCreateIndex) continue;

      // Check if covered
      bool isCovered = false;

      // Check exact match or prefix match
      for (final index in allIndexes) {
        if (index.fields.length >= fk.fields.length) {
          bool match = true;
          for (int i = 0; i < fk.fields.length; i++) {
            if (index.fields[i] != fk.fields[i]) {
              match = false;
              break;
            }
          }
          if (match) {
            isCovered = true;
            break;
          }
        }
      }

      if (!isCovered) {
        // Create auto index for FK
        final fkIndex = IndexSchema(
          indexName: fk.actualName,
          fields: fk.fields,
          unique: false, // FKs are not necessarily unique
        );
        if (!existingIndexNames.contains(fkIndex.actualIndexName)) {
          allIndexes.add(fkIndex);
          existingIndexNames.add(fkIndex
              .actualIndexName); // This is approximate, actual comparison handled better structurally
        }
      }
    }

    return allIndexes;
  }

  /// Validate table schema
  bool validateTableSchema() {
    // validate name format
    final nameRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');

    // validate name format
    if (!nameRegex.hasMatch(name) && name.isEmpty) {
      Logger.warn(
        'Invalid table name format',
        label: 'TableSchema.validateTable',
      );
      return false;
    }

    // validate primary key name format
    if (!nameRegex.hasMatch(primaryKey) && primaryKey.isEmpty) {
      Logger.warn(
        'Invalid primary key name format',
        label: 'TableSchema.validateTable',
      );
      return false;
    }

    // validate field name format
    for (final field in fields) {
      if (!nameRegex.hasMatch(field.name)) {
        Logger.warn(
          'Invalid field name format',
          label: 'TableSchema.validateTable',
        );
        return false;
      }

      // Field should not have the same name as the primary key
      if (field.name == primaryKey) {
        Logger.error(
          'Field $field has the same name as the primary key, primary key should not be defined in the field list',
          label: 'TableSchema.validateTableSchema',
        );
        return false;
      }
    }

    if (fields.isEmpty) {
      Logger.warn(
        'Table $name has no fields',
        label: 'TableSchema.validateTableSchema',
      );
      return false;
    }

    // Validate field name uniqueness
    final fieldNames = fields.map((f) => f.name).toSet();
    if (fieldNames.length != fields.length) {
      Logger.warn(
        'Field names must be unique',
        label: 'TableSchema.validateTableSchema',
      );
      return false;
    }

    // Validate index configuration
    for (final index in indexes) {
      if (!validateIndexFields(index)) {
        return false;
      }
    }

    // Validate foreign key configuration
    for (final fk in foreignKeys) {
      if (!validateForeignKey(fk)) {
        return false;
      }
    }

    return true;
  }

  /// Validate foreign key configuration
  ///
  /// This method validates the foreign key within the current table context.
  /// For complete validation including referenced table field types, use validateForeignKeyWithReferencedTable.
  bool validateForeignKey(ForeignKeySchema fk) {
    // Validate foreign key schema itself
    if (!fk.validate()) {
      Logger.error(
        'Invalid foreign key schema: ${fk.actualName}',
        label: 'TableSchema.validateForeignKey',
      );
      return false;
    }

    // Validate that foreign key fields exist in this table
    for (final fieldName in fk.fields) {
      final fieldExists = fields.any((field) => field.name == fieldName) ||
          fieldName == primaryKey;
      if (!fieldExists) {
        Logger.error(
          'Foreign key ${fk.actualName} references non-existent field: $fieldName',
          label: 'TableSchema.validateForeignKey',
        );
        return false;
      }
    }

    // Validate that foreign key fields are not the same as primary key
    // (unless it's a self-referencing foreign key, which is allowed)
    if (fk.fields.length == 1 && fk.fields.first == primaryKey) {
      // Self-referencing foreign key is allowed
      return true;
    }

    return true;
  }

  /// Validate foreign key configuration with referenced table
  ///
  /// This method validates that:
  /// 1. Foreign key fields exist in this table
  /// 2. Referenced fields exist in the referenced table
  /// 3. Field types are compatible between foreign key fields and referenced fields
  ///
  /// [fk] The foreign key schema to validate
  /// [referencedSchema] The schema of the referenced table
  ///
  /// Returns true if validation passes, false otherwise
  bool validateForeignKeyWithReferencedTable(
    ForeignKeySchema fk,
    TableSchema referencedSchema,
  ) {
    // First validate within current table context
    if (!validateForeignKey(fk)) {
      return false;
    }

    // Validate that referenced fields exist in the referenced table
    for (final refFieldName in fk.referencedFields) {
      final refFieldExists = referencedSchema.fields.any(
            (field) => field.name == refFieldName,
          ) ||
          refFieldName == referencedSchema.primaryKey;
      if (!refFieldExists) {
        Logger.error(
          'Foreign key ${fk.actualName} references non-existent field: $refFieldName in table ${fk.referencedTable}',
          label: 'TableSchema.validateForeignKeyWithReferencedTable',
        );
        return false;
      }
    }

    // Validate field type compatibility
    for (int i = 0; i < fk.fields.length; i++) {
      final fkFieldName = fk.fields[i];
      final refFieldName = fk.referencedFields[i];

      // Get field schemas
      FieldSchema? fkField;
      if (fkFieldName == primaryKey) {
        // Primary key field - need to check primary key type
        // For now, we'll skip type validation for primary key fields
        // as they may have special handling
        continue;
      } else {
        fkField = fields.firstWhere(
          (f) => f.name == fkFieldName,
          orElse: () => throw StateError('Field $fkFieldName not found'),
        );
      }

      FieldSchema? refField;
      DataType refFieldType;
      if (refFieldName == referencedSchema.primaryKey) {
        // Referenced primary key - primary keys are always stored as text
        // Get the default data type for primary key
        refFieldType = referencedSchema.primaryKeyConfig.getDefaultDataType();
        // Create a virtual FieldSchema for type comparison
        refField = FieldSchema(
          name: refFieldName,
          type: refFieldType,
        );
      } else {
        refField = referencedSchema.fields.firstWhere(
          (f) => f.name == refFieldName,
          orElse: () => throw StateError('Field $refFieldName not found'),
        );
        refFieldType = refField.type;
      }

      // Validate type compatibility
      // Note: fkField and refField are guaranteed to be non-null here due to the logic above
      if (!_areTypesCompatible(fkField.type, refFieldType)) {
        Logger.error(
          'Foreign key ${fk.actualName}: Field type mismatch - $fkFieldName (${fkField.type}) vs $refFieldName ($refFieldType). '
          'Foreign key fields must have compatible types with referenced fields. '
          'Note: Primary keys are stored as text, so numeric types (integer, bigInt, double) can reference them.',
          label: 'TableSchema.validateForeignKeyWithReferencedTable',
        );
        return false;
      }
    }

    return true;
  }

  /// Check if two data types are compatible for foreign key relationships
  bool _areTypesCompatible(DataType fkType, DataType refType) {
    // Exact match is always compatible
    if (fkType == refType) {
      return true;
    }

    // Numeric types are compatible with each other (with some restrictions)
    final numericTypes = [
      DataType.integer,
      DataType.bigInt,
      DataType.double,
    ];

    if (numericTypes.contains(fkType) && numericTypes.contains(refType)) {
      // Integer and BigInt are compatible
      if ((fkType == DataType.integer || fkType == DataType.bigInt) &&
          (refType == DataType.integer || refType == DataType.bigInt)) {
        return true;
      }
      // Integer can be stored in Double, but not vice versa
      if (fkType == DataType.integer && refType == DataType.double) {
        return true;
      }
      // BigInt can be stored in Double (with precision loss warning)
      if (fkType == DataType.bigInt && refType == DataType.double) {
        return true;
      }
    }

    // Primary keys are stored as text, so numeric types can reference text primary keys
    // This is a common pattern: user_id (integer) -> users.id (text primary key)
    if (numericTypes.contains(fkType) && refType == DataType.text) {
      return true;
    }

    // Text can reference text (exact match already handled above)
    // But text cannot reference numeric types (would require parsing, which is error-prone)

    return false;
  }

  /// Validate index fields
  bool validateIndexFields(IndexSchema index) {
    final primaryKeyName = primaryKeyConfig.name;

    // Primary-key-only index is redundant:
    // table data itself is range-partitioned by primary key.
    if (_isPrimaryKeyOnlyIndex(index)) {
      Logger.warn(
        'Table $name contains redundant primary key-only index: ${index.actualIndexName}. Table data is already range-partitioned by primary key.',
        label: 'TableSchema.validateIndexFields',
      );
      // do not return false, because this is just a warning, should not block the table creation
    }

    for (final fieldName in index.fields) {
      // Check if the field is the primary key
      if (fieldName == primaryKeyName) {
        continue;
      }

      // Check if the field exists in the field list
      final fieldExists = fields.any((field) => field.name == fieldName);
      if (!fieldExists) {
        Logger.error(
          'Table $name index ${index.actualIndexName} references non-existent field $fieldName',
          label: 'TableSchema.validateIndexFields',
        );
        return false;
      }
    }

    return true;
  }

  TableSchema copyWith({
    String? name,
    PrimaryKeyConfig? primaryKeyConfig,
    List<FieldSchema>? fields,
    List<IndexSchema>? indexes,
    List<ForeignKeySchema>? foreignKeys,
    bool? isGlobal,
    String? tableId,
  }) {
    return TableSchema(
      name: name ?? this.name,
      primaryKeyConfig: primaryKeyConfig ?? this.primaryKeyConfig,
      fields: fields ?? this.fields,
      indexes: indexes ?? this.indexes,
      foreignKeys: foreignKeys ?? this.foreignKeys,
      isGlobal: isGlobal ?? this.isGlobal,
      tableId: tableId ?? this.tableId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'primaryKeyConfig': primaryKeyConfig.toJson(),
      'fields': fields.map((c) => c.toJson()).toList(),
      'indexes': indexes.map((i) => i.toJson()).toList(),
      'foreignKeys': foreignKeys.map((fk) => fk.toJson()).toList(),
      'isGlobal': isGlobal,
      if (tableId != null) 'tableId': tableId,
    };
  }

  bool _isPrimaryKeyOnlyIndex(IndexSchema index) {
    return index.fields.length == 1 && index.fields.first == primaryKey;
  }

  factory TableSchema.fromJson(Map<String, dynamic> json) {
    // Backward compatibility handling
    PrimaryKeyConfig getPrimaryKeyConfig() {
      if (json['primaryKeyConfig'] != null) {
        return PrimaryKeyConfig.fromJson(
            json['primaryKeyConfig'] as Map<String, dynamic>);
      }

      // Old version compatibility handling
      if (json['primaryKey'] != null) {
        final primaryKeyName = json['primaryKey'] as String;
        final autoIncrement = json['autoIncrement'] as bool? ?? true;

        return PrimaryKeyConfig(
          name: primaryKeyName,
          type: autoIncrement ? PrimaryKeyType.sequential : PrimaryKeyType.none,
          sequentialConfig: autoIncrement ? const SequentialIdConfig() : null,
        );
      }

      return const PrimaryKeyConfig();
    }

    return TableSchema(
      name: json['name'] as String,
      primaryKeyConfig: getPrimaryKeyConfig(),
      fields: (json['fields'] as List)
          .map((c) => FieldSchema.fromJson(c as Map<String, dynamic>))
          .toList(),
      indexes: (json['indexes'] as List?)
              ?.map((i) => IndexSchema.fromJson(i as Map<String, dynamic>))
              .toList() ??
          [],
      foreignKeys: (json['foreignKeys'] as List?)
              ?.map(
                  (fk) => ForeignKeySchema.fromJson(fk as Map<String, dynamic>))
              .toList() ??
          [],
      isGlobal: json['isGlobal'] as bool? ?? false,
      tableId: json['tableId'] as String?,
    );
  }

  /// Validate data against table schema
  ///
  /// - When [applyConstraints] is true, it will modify the data to fit
  ///   constraints (e.g., truncate strings).
  /// - When [errors] is provided, detailed validation error messages will be
  ///   appended to it instead of only logging via [Logger].
  Map<String, dynamic>? validateData(
    Map<String, dynamic> data, {
    bool applyConstraints = false,
    List<String>? errors,
  }) {
    // Create a new result Map
    var result = Map<String, dynamic>.from(data);

    // First handle primary key field
    final primaryKeyName = primaryKeyConfig.name;
    var primaryKeyValue = data[primaryKeyName];

    // Handle primary key value
    if (primaryKeyValue != null) {
      // Convert to string and handle leading/trailing spaces
      if (primaryKeyValue is int || primaryKeyValue is BigInt) {
        // Directly convert number types to string
        result[primaryKeyName] = primaryKeyValue.toString();
      } else if (primaryKeyValue is String) {
        // String type, remove leading/trailing spaces
        result[primaryKeyName] = primaryKeyValue.trim();
      } else {
        // Unsupported type
        final msg =
            'Invalid primary key $primaryKeyName value type: $primaryKeyValue (should be number or string type)';
        Logger.warn(
          msg,
          label: 'TableSchema.validateData',
        );
        errors?.add(msg);
        return null;
      }
    }

    // Check required (non-nullable) fields
    for (var field in fields) {
      if (!field.nullable &&
          !data.containsKey(field.name) &&
          field.name != primaryKeyName) {
        final msg =
            'Field ${field.name} is required but not provided for table $name';
        Logger.warn(
          msg,
          label: 'TableSchema.validateData',
        );
        errors?.add(msg);
        return null;
      }
    }

    // Validate field type and constraints
    for (var entry in data.entries) {
      // If it's the primary key field, it's already validated, skip
      if (entry.key == primaryKeyName) continue;

      // Find field definition
      final fieldSchema = fields.firstWhere(
        (col) => col.name == entry.key,
        orElse: () => throw ArgumentError('Unknown field ${entry.key}'),
      );

      // Use FieldSchema's detailed validation helper to get error message
      final fieldError = fieldSchema.getValidationError(
        entry.value,
        skipMaxLengthCheck: applyConstraints,
      );
      if (fieldError != null) {
        final msg =
            'Field ${fieldSchema.name} validation failed: $fieldError (table $name)';
        Logger.warn(
          msg,
          label: 'TableSchema.validateData',
        );
        errors?.add(msg);
        return null;
      }

      // Apply constraint conditions
      if (applyConstraints && entry.value != null) {
        if (entry.value is String) {
          String stringValue = entry.value;
          if (fieldSchema.maxLength != null &&
              stringValue.length > fieldSchema.maxLength!) {
            Logger.warn(
              'Field ${fieldSchema.name} exceeds maximum length ${fieldSchema.maxLength}, will truncate',
              label: 'TableSchema.validateData',
            );
            result[entry.key] =
                stringValue.substring(0, fieldSchema.maxLength!);
          }
        }
      }
    }

    return result;
  }

  /// Validate primary key format against corresponding type requirements
  bool validatePrimaryKeyFormat(dynamic value) {
    if (value == null) return false;

    switch (primaryKeyConfig.type) {
      case PrimaryKeyType.sequential:
      case PrimaryKeyType.timestampBased:
      case PrimaryKeyType.datePrefixed:
        // Numeric format validation
        if (value is String) {
          return RegExp(r'^\d+$').hasMatch(value);
        }
        return value is int || value is BigInt;

      case PrimaryKeyType.shortCode:
        // Base62 format validation (0-9, A-Z, a-z)
        if (value is String) {
          return RegExp(r'^[0-9A-Za-z]+$').hasMatch(value);
        }
        return false;

      case PrimaryKeyType.none:
        // User-defined primary key, accept any string
        return true;
    }
  }

  /// Get MatcherType for primary key
  MatcherType getPrimaryKeyMatcherType() {
    return primaryKeyConfig.getMatcherType();
  }

  /// Get MatcherType for a field
  MatcherType getFieldMatcherType(String fieldName) {
    if (fieldName == primaryKey) {
      return getPrimaryKeyMatcherType();
    }
    try {
      final field = fields.firstWhere((f) => f.name == fieldName);
      return field.getMatcherType();
    } catch (e) {
      Logger.warn('Field $fieldName not found, using unsupported matcher',
          label: 'TableSchema.getFieldMatcherType');
      return MatcherType.unsupported;
    }
  }

  /// Encode primary key as a MemComparable component.
  ///
  /// Primary keys are treated as strings to avoid precision overflow while still
  /// supporting monotonic ordering for numeric/base62-based PKs.
  Uint8List encodePrimaryKeyComponent(String pk) {
    switch (getPrimaryKeyMatcherType()) {
      case MatcherType.pkNumericString:
      case MatcherType.pkShortCodeString:
        return MemComparableKey.encodeTextLenFirst(pk);
      case MatcherType.pkString:
      default:
        return MemComparableKey.encodeTextLex(pk);
    }
  }

  /// Encode a field value as a MemComparable component.
  ///
  /// When [truncateText] is true, long text values are truncated to 256 chars
  /// (recommended for non-unique indexes).
  Uint8List? encodeFieldComponentToMemComparable(
    String fieldName,
    dynamic value, {
    required bool truncateText,
  }) {
    if (value == null) return null;
    final mt = getFieldMatcherType(fieldName);
    switch (mt) {
      case MatcherType.pkNumericString:
      case MatcherType.pkShortCodeString:
        return MemComparableKey.encodeTextLenFirst(value.toString());
      case MatcherType.pkString:
      case MatcherType.text:
      case MatcherType.textNullable:
      case MatcherType.datetime:
      case MatcherType.datetimeNullable:
      case MatcherType.unsupported:
        var s = value.toString();
        if (truncateText && s.length > 256) {
          s = s.substring(0, 256);
        }
        return MemComparableKey.encodeTextLex(s);
      case MatcherType.integer:
      case MatcherType.integerNullable:
        final n =
            (value is num) ? value.toInt() : int.tryParse(value.toString());
        if (n == null) return MemComparableKey.encodeTextLex(value.toString());
        return MemComparableKey.encodeInt64(n);
      case MatcherType.bigInt:
      case MatcherType.bigIntNullable:
        final s = value.toString();
        // Avoid incorrect numeric ordering for negative bigints here; fall back to lex.
        if (s.startsWith('-')) {
          return MemComparableKey.encodeTextLex(s);
        }
        final asInt = int.tryParse(s);
        if (asInt != null) return MemComparableKey.encodeInt64(asInt);
        // Length-first preserves numeric order for non-negative decimal strings.
        return MemComparableKey.encodeTextLenFirst(s);
      case MatcherType.double:
      case MatcherType.doubleNullable:
        final d = (value is num)
            ? value.toDouble()
            : double.tryParse(value.toString());
        if (d == null) return MemComparableKey.encodeTextLex(value.toString());
        return MemComparableKey.encodeFloat64(d);
      case MatcherType.boolean:
      case MatcherType.booleanNullable:
        final b = (value is bool)
            ? value
            : (value.toString().toLowerCase() == 'true'
                ? true
                : (value.toString().toLowerCase() == 'false' ? false : null));
        if (b == null) return MemComparableKey.encodeTextLex(value.toString());
        return MemComparableKey.encodeBool(b);
      case MatcherType.blob:
      case MatcherType.blobNullable:
        if (value is Uint8List) return MemComparableKey.encodeBytes(value);
        return MemComparableKey.encodeTextLex(value.toString());
    }
  }

  /// Create a delimiter-free canonical key for unique refs (buffer overlay).
  ///
  /// - Does NOT truncate values (unique indexes must preserve full value).
  dynamic createCanonicalIndexKey(
    List<String> fields,
    Map<String, dynamic> record,
  ) {
    if (fields.isEmpty) return null;
    if (fields.length == 1) return record[fields[0]];
    return fields.map((f) => record[f]).toList();
  }

  /// Check if primary key is ordered type
  bool isPrimaryKeyOrdered() {
    try {
      final pkConfig = primaryKeyConfig;

      // If isOrdered is explicitly set, return directly
      if (pkConfig.isOrdered != null) {
        return pkConfig.isOrdered!;
      }

      // Determine primary key type
      switch (pkConfig.type) {
        case PrimaryKeyType.timestampBased:
        case PrimaryKeyType.datePrefixed:
        case PrimaryKeyType.shortCode:
        case PrimaryKeyType.sequential:
          // These types of primary keys are ordered
          return true;
        case PrimaryKeyType.none:
          // User-defined primary key, default to unordered
          return false;
      }
    } catch (e) {
      Logger.error('Check primary key order failed: $e',
          label: 'TableSchema.isPrimaryKeyOrdered');
      return false;
    }
  }

  /// Get default value for a field
  dynamic getDefaultValue(String fieldName) {
    // Check if it's the primary key
    if (fieldName == primaryKey) {
      // Primary key should not have a default value because it's usually generated by the system
      return null;
    }

    final field = fields.firstWhere(
      (f) => f.name == fieldName,
      orElse: () => throw StateError('Unknown field $fieldName'),
    );
    return field.getDefaultValue();
  }

  // Check if table exists
  bool isTableExists() {
    return fields.isNotEmpty;
  }

  /// Quickly generate table structure hash for judging whether table structure has changed
  /// Avoid using JSON serialization, directly calculate hash value from table structure in memory
  static String generateSchemasHash(List<TableSchema> schemas) {
    if (schemas.isEmpty) return '';

    // Use binary buffer to optimize performance
    final byteBuffer = BytesBuilder();

    // Copy and sort tables to ensure hash value consistency
    final sortedSchemas = List<TableSchema>.from(schemas)
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final schema in sortedSchemas) {
      // Write table basic information
      _addStringToBuffer(byteBuffer, schema.name);

      // Write primary key configuration
      _addPrimaryKeyConfigToBuffer(byteBuffer, schema.primaryKeyConfig);

      byteBuffer.addByte(schema.isGlobal ? 1 : 0);

      // Write field information - Sort to ensure consistency
      final sortedFields = List<FieldSchema>.from(schema.fields)
        ..sort((a, b) => a.name.compareTo(b.name));

      byteBuffer.addByte(sortedFields.length);
      for (final field in sortedFields) {
        _addFieldSchemaToBuffer(byteBuffer, field);
      }

      // Write index information
      final sortedIndexes = List<IndexSchema>.from(schema.indexes)
        ..sort((a, b) => a.actualIndexName.compareTo(b.actualIndexName));

      byteBuffer.addByte(sortedIndexes.length);
      for (final index in sortedIndexes) {
        _addIndexSchemaToBuffer(byteBuffer, index);
      }

      // Write foreign key information
      final sortedForeignKeys = List<ForeignKeySchema>.from(schema.foreignKeys)
        ..sort((a, b) => a.actualName.compareTo(b.actualName));

      byteBuffer.addByte(sortedForeignKeys.length);
      for (final fk in sortedForeignKeys) {
        _addForeignKeySchemaToBuffer(byteBuffer, fk);
      }
    }

    // Calculate hash value
    final bytes = byteBuffer.toBytes();
    return SHA256.bytesToHex(bytes);
  }

  /// Add primary key configuration to buffer
  static void _addPrimaryKeyConfigToBuffer(
      BytesBuilder buffer, PrimaryKeyConfig config) {
    _addStringToBuffer(buffer, config.name);
    buffer.addByte(config.type.index); // Primary key type

    if (config.isOrdered != null) {
      buffer.addByte(1);
      buffer.addByte(config.isOrdered! ? 1 : 0);
    } else {
      buffer.addByte(0); // isOrdered not set
    }

    // Check if it's the default configuration
    final isDefaultConfig = config.sequentialConfig != null &&
        config.sequentialConfig!.initialValue == 1 &&
        config.sequentialConfig!.increment == 1 &&
        !config.sequentialConfig!.useRandomIncrement;

    // If it's the default configuration or null, it's considered to have no configuration
    if (config.sequentialConfig != null && !isDefaultConfig) {
      buffer.addByte(1); // Has configuration
      final cfg = config.sequentialConfig!;
      _addInt32ToBuffer(buffer, cfg.initialValue);
      _addInt32ToBuffer(buffer, cfg.increment);
      buffer.addByte(cfg.useRandomIncrement ? 1 : 0);
    } else {
      buffer.addByte(0); // No configuration
    }
  }

  /// Add field schema to buffer
  static void _addFieldSchemaToBuffer(BytesBuilder buffer, FieldSchema field) {
    _addStringToBuffer(buffer, field.name);
    buffer.addByte(field.type.index);
    buffer.addByte(field.nullable ? 1 : 0);
    buffer.addByte(field.unique ? 1 : 0);
    buffer.addByte(field.createIndex ? 1 : 0);

    // Add defaultValueType
    buffer.addByte(field.defaultValueType.index);

    // Only check if defaultValue exists but DO NOT include its content
    buffer.addByte(field.defaultValue != null ? 1 : 0);

    // to ensure consistent hash values regardless of dynamic content

    // Special handling for BigInt type to ensure it can be recognized in table structure comparison
    if (field.type == DataType.bigInt) {
      buffer.addByte(255); // Special BigInt type marker
    }

    // Add field constraint information
    _addOptionalInt(buffer, field.maxLength);
    _addOptionalInt(buffer, field.minLength);

    // Add numeric range
    if (field.minValue != null) {
      buffer.addByte(1);
      _addStringToBuffer(buffer, field.minValue.toString());
    } else {
      buffer.addByte(0);
    }

    if (field.maxValue != null) {
      buffer.addByte(1);
      _addStringToBuffer(buffer, field.maxValue.toString());
    } else {
      buffer.addByte(0);
    }

    // Add field ID
    if (field.fieldId != null) {
      buffer.addByte(1);
      _addStringToBuffer(buffer, field.fieldId!);
    } else {
      buffer.addByte(0);
    }

    // Add comment information
    if (field.comment != null) {
      buffer.addByte(1);
      _addStringToBuffer(buffer, field.comment!);
    } else {
      buffer.addByte(0);
    }
  }

  /// Add index schema to buffer
  static void _addIndexSchemaToBuffer(BytesBuilder buffer, IndexSchema index) {
    _addStringToBuffer(buffer, index.actualIndexName);
    buffer.addByte(index.unique ? 1 : 0);
    buffer.addByte(index.type.index); // Keep original type index
    // Index fields
    final sortedIndexFields = List<String>.from(index.fields)..sort();
    buffer.addByte(sortedIndexFields.length);
    for (final fieldName in sortedIndexFields) {
      _addStringToBuffer(buffer, fieldName);
    }
  }

  /// Add foreign key schema to buffer
  static void _addForeignKeySchemaToBuffer(
      BytesBuilder buffer, ForeignKeySchema fk) {
    _addStringToBuffer(buffer, fk.actualName);
    _addStringToBuffer(buffer, fk.referencedTable);
    buffer.addByte(fk.fields.length);
    for (final field in fk.fields) {
      _addStringToBuffer(buffer, field);
    }
    for (final field in fk.referencedFields) {
      _addStringToBuffer(buffer, field);
    }
    buffer.addByte(fk.onDelete.index);
    buffer.addByte(fk.onUpdate.index);
    buffer.addByte(fk.autoCreateIndex ? 1 : 0); // Keep original autoCreateIndex
    buffer.addByte(fk.enabled ? 1 : 0); // Keep original enabled
    if (fk.comment != null) {
      // Keep original comment
      buffer.addByte(1);
      _addStringToBuffer(buffer, fk.comment!);
    } else {
      buffer.addByte(0);
    }
  }

  /// Add string to binary buffer
  static void _addStringToBuffer(BytesBuilder buffer, String value) {
    final bytes = utf8.encode(value);
    _addInt32ToBuffer(buffer, bytes.length);
    buffer.add(bytes);
  }

  /// Add optional integer to buffer
  static void _addOptionalInt(BytesBuilder buffer, int? value) {
    if (value != null) {
      buffer.addByte(1);
      _addInt32ToBuffer(buffer, value);
    } else {
      buffer.addByte(0);
    }
  }

  /// Add 32-bit integer to buffer
  static void _addInt32ToBuffer(BytesBuilder buffer, int value) {
    buffer.addByte((value >> 24) & 0xFF);
    buffer.addByte((value >> 16) & 0xFF);
    buffer.addByte((value >> 8) & 0xFF);
    buffer.addByte(value & 0xFF);
  }

  MatcherType getMatcherTypeForIndex(String indexName) {
    final index = indexes.firstWhere((i) => i.actualIndexName == indexName,
        orElse: () => const IndexSchema(fields: []));
    if (index.fields.isNotEmpty) {
      if (index.fields.length > 1) {
        return MatcherType.text; // Composite keys are strings
      }
      if (index.fields.length == 1) {
        return getFieldMatcherType(index.fields.first);
      }
    }

    // could be an auto-unique index
    if (indexName.startsWith('uniq_')) {
      final fieldName = indexName.substring(5);
      return getFieldMatcherType(fieldName);
    }
    return MatcherType.unsupported;
  }
}

/// field schema
class FieldSchema {
  static const _unsetValue = Object();

  final String name;
  final DataType
      type; // data type, Recommend integer primary key for efficient indexing
  final bool nullable;
  final dynamic defaultValue;
  final bool unique;
  final bool createIndex; // create index for this field
  final int? maxLength; // for text fields
  final int? minLength; // for text fields
  final num? minValue; // for numeric fields (integer, double)
  final num? maxValue; // for numeric fields (integer, double)
  final String? comment; // field comment
  final String?
      fieldId; // Unique identifier for fields, used for rename detection

  /// Default value type, used for special default value processing (e.g. timestamp)
  final DefaultValueType defaultValueType;

  /// Configuration for vector fields (only valid when type is DataType.vector)
  final VectorFieldConfig? vectorConfig;

  const FieldSchema({
    required this.name,
    required this.type,
    this.nullable = true,
    this.defaultValue,
    this.unique = false,
    this.createIndex = false,
    this.maxLength,
    this.minLength,
    this.minValue,
    this.maxValue,
    this.comment,
    this.fieldId,
    this.vectorConfig,
    this.defaultValueType = DefaultValueType.none,
  });

  /// Create copy with modifications
  FieldSchema copyWith({
    String? name,
    DataType? type,
    bool? nullable,
    dynamic defaultValue = _unsetValue,
    bool? unique,
    bool? createIndex,
    int? maxLength,
    int? minLength,
    num? minValue,
    num? maxValue,
    String? comment,
    String? fieldId,
    VectorFieldConfig? vectorConfig,
    DefaultValueType? defaultValueType,
  }) {
    return FieldSchema(
      name: name ?? this.name,
      type: type ?? this.type,
      nullable: nullable ?? this.nullable,
      defaultValue:
          defaultValue == _unsetValue ? this.defaultValue : defaultValue,
      unique: unique ?? this.unique,
      createIndex: createIndex ?? this.createIndex,
      maxLength: maxLength ?? this.maxLength,
      minLength: minLength ?? this.minLength,
      minValue: minValue ?? this.minValue,
      maxValue: maxValue ?? this.maxValue,
      comment: comment ?? this.comment,
      fieldId: fieldId ?? this.fieldId,
      vectorConfig: vectorConfig ?? this.vectorConfig,
      defaultValueType: defaultValueType ?? this.defaultValueType,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type.toString(),
      'nullable': nullable,
      'defaultValue': defaultValue,
      'maxLength': maxLength,
      'minLength': minLength,
      'minValue': minValue,
      'maxValue': maxValue,
      'unique': unique,
      'createIndex': createIndex,
      'comment': comment,
      if (fieldId != null) 'fieldId': fieldId,
      if (vectorConfig != null) 'vectorConfig': vectorConfig!.toJson(),
      // Only serialize if not none
      if (defaultValueType != DefaultValueType.none)
        'defaultValueType': defaultValueType.toString().split('.').last,
    };
  }

  /// Create from partial updates
  factory FieldSchema.fromJson(Map<String, dynamic> json) {
    DataType getType() {
      if (json['type'] == null) return DataType.text;
      if (json['type'] is DataType) return json['type'] as DataType;

      try {
        return DataType.values.firstWhere(
          (e) => e.toString() == json['type'],
        );
      } catch (_) {
        return DataType.text;
      }
    }

    // Parse default value type
    DefaultValueType getDefaultValueType() {
      final typeStr = json['defaultValueType'] as String?;
      if (typeStr == null) return DefaultValueType.none;

      switch (typeStr.toLowerCase()) {
        case 'currenttimestamp':
          return DefaultValueType.currentTimestamp;
        default:
          return DefaultValueType.none;
      }
    }

    final type = getType();

    // Parse vector configuration if it's a vector field
    VectorFieldConfig? vectorConfig;
    if (type == DataType.vector && json['vectorConfig'] != null) {
      vectorConfig = VectorFieldConfig.fromJson(
          json['vectorConfig'] as Map<String, dynamic>);
    }

    return FieldSchema(
      name: json['name'] as String,
      type: type,
      nullable: json['nullable'] as bool? ?? true,
      defaultValue: json['defaultValue'],
      unique: json['unique'] as bool? ?? false,
      createIndex: json['createIndex'] as bool? ?? false,
      maxLength: json['maxLength'] as int?,
      minLength: json['minLength'] as int?,
      minValue: json['minValue'] as num?,
      maxValue: json['maxValue'] as num?,
      comment: json['comment'] as String?,
      fieldId: json['fieldId'] as String?,
      vectorConfig: vectorConfig,
      defaultValueType: getDefaultValueType(),
    );
  }

  /// Get default value for this field
  dynamic getDefaultValue() {
    // handle special default value type
    if (defaultValueType == DefaultValueType.currentTimestamp) {
      if (type == DataType.datetime) {
        return DateTime.now().toIso8601String();
      }
      if (type == DataType.integer) {
        return DateTime.now().millisecondsSinceEpoch;
      }
      if (type == DataType.bigInt) {
        return BigInt.from(DateTime.now().millisecondsSinceEpoch);
      }
      return DateTime.now().toIso8601String();
    }

    // use static default value
    if (defaultValue != null) {
      return _convertValueInternal(defaultValue);
    }

    // allow null and no default value, return null
    return null;
  }

  /// Get field value: handle null value and execute type conversion
  dynamic convertValue(dynamic value) {
    // handle null value
    if (value == null) {
      return getDefaultValue();
    }

    // execute type conversion for non-null value
    return _convertValueInternal(value);
  }

  /// Type conversion (internal method)
  dynamic _convertValueInternal(dynamic value) {
    if (value == null) return null;

    switch (type) {
      case DataType.integer:
        if (value is int) return value;
        if (value is double) return value.round();
        if (value is String) return int.tryParse(value);
        if (value is bool) return value ? 1 : 0;
        if (value is DateTime) {
          return value.millisecondsSinceEpoch;
        }
        if (value is BigInt) {
          // Try to convert BigInt to int, return null or max value if out of range
          if (value <= BigInt.from(9007199254740991) &&
              value >= BigInt.from(-9007199254740991)) {
            return value.toInt();
          }
          return null; // Out of range
        }
        return null;
      case DataType.bigInt:
        if (value is BigInt) return value;
        if (value is int) return BigInt.from(value);
        if (value is String) {
          try {
            return BigInt.parse(value);
          } catch (_) {
            return null;
          }
        }
        if (value is bool) {
          return value ? BigInt.from(1) : BigInt.from(0);
        }
        if (value is DateTime) {
          return BigInt.from(value.millisecondsSinceEpoch);
        }
        return null;
      case DataType.double:
        if (value is double) return value;
        if (value is int) return value.toDouble();
        if (value is String) return double.tryParse(value);
        if (value is bool) return value ? 1.0 : 0.0;
        if (value is DateTime) {
          return value.millisecondsSinceEpoch.toDouble();
        }
        if (value is BigInt) {
          // Try to convert BigInt to double, may lose precision
          try {
            return value.toDouble();
          } catch (e) {
            return null;
          }
        }
        return null;
      case DataType.text:
        String? rawString;
        if (value is String) {
          rawString = value;
        } else if (value is DateTime) {
          try {
            return value.toIso8601String();
          } catch (e) {
            Logger.warn(
              'Failed to convert DateTime to string: $value',
              label: 'DataStore._toString',
            );
            return null;
          }
        } else {
          rawString = value?.toString();
        }

        if (rawString == null) return null;

        return rawString.trim();
      case DataType.blob:
        if (value is Uint8List) return value;
        if (value is String) {
          return Uint8List.fromList(utf8.encode(value));
        }
        if (value is List<int>) return Uint8List.fromList(value);
        return null;
      case DataType.boolean:
        if (value is bool) return value;
        if (value is int) return value != 0;
        if (value is double) return value != 0.0;
        if (value is String) {
          final lower = value.toLowerCase();
          return lower == 'true' || lower == '1' || lower == 'yes';
        }
        if (value is BigInt) return value != BigInt.zero;
        return null;
      case DataType.datetime:
        if (value == null) return null;
        if (value is DateTime) return value.toIso8601String();
        if (value is String) {
          try {
            return DateTime.parse(value).toIso8601String();
          } catch (e) {
            Logger.warn(
              'Failed to parse DateTime from string: $value',
              label: 'DataStore._toDateTimeString',
            );
            return null;
          }
        }
        if (value is int) {
          try {
            return DateTime.fromMillisecondsSinceEpoch(value).toIso8601String();
          } catch (e) {
            Logger.warn(
              'Failed to convert timestamp to DateTime: $value',
              label: 'DataStore._toDateTimeString',
            );
            return null;
          }
        }
        if (value is BigInt) {
          try {
            if (value <= BigInt.from(8640000000000000) &&
                value >= BigInt.from(-8640000000000000)) {
              return DateTime.fromMillisecondsSinceEpoch(value.toInt())
                  .toIso8601String();
            }
            return null; // Out of range
          } catch (e) {
            Logger.warn(
              'Failed to convert BigInt to DateTime: $value',
              label: 'DataStore._toDateTimeString',
            );
            return null;
          }
        }
        return null;
      case DataType.array:
        if (value is List) return value;
        if (value is String) {
          try {
            return jsonDecode(value) as List?;
          } catch (_) {
            return [value];
          }
        }
        return value == null ? null : [value];
      case DataType.vector:
        if (value is VectorData) return value;
        if (value is List && value.every((v) => v is num)) {
          return VectorData.fromList(value.cast<num>());
        }
        if (value is Uint8List) {
          try {
            return VectorData.fromBytes(value);
          } catch (e) {
            Logger.warn(
              'Failed to convert binary data to vector: $e',
              label: 'DataStore._toVector',
            );
            return null;
          }
        }
        if (value is String) {
          try {
            final jsonList = jsonDecode(value);
            if (jsonList is List && jsonList.every((v) => v is num)) {
              return VectorData.fromList(jsonList.cast<num>());
            }
          } catch (e) {
            Logger.warn(
              'Failed to parse vector from string: $value',
              label: 'DataStore._toVector',
            );
          }
        }
        return null;
      case DataType.json:
        if (value is Map) return value;
        if (value is String) {
          try {
            final decoded = jsonDecode(value);
            if (decoded is Map) {
              return decoded;
            }
            return null;
          } catch (_) {
            return null;
          }
        }
        return null;
    }
  }

  /// Get detailed validation error message for a value.
  ///
  /// Returns `null` when the value is valid, otherwise returns a human-readable
  /// description of which constraint failed. This is designed for single-record
  /// validation and does not perform any table-wide scan.
  String? getValidationError(
    dynamic value, {
    bool skipMaxLengthCheck = false,
  }) {
    if (value == null && !nullable) {
      return 'Field $name is required and cannot be null';
    }

    // Check data type
    if (!isValidDataType(value, type)) {
      return 'Field $name expects type $type but got ${value.runtimeType}';
    }

    // Check string length constraints
    if (value is String) {
      if (!skipMaxLengthCheck &&
          maxLength != null &&
          value.length > maxLength!) {
        return 'Field $name length ${value.length} exceeds maxLength $maxLength';
      }
      if (minLength != null && value.length < minLength!) {
        return 'Field $name length ${value.length} is less than minLength $minLength';
      }
    }

    // Check numeric value constraints
    if (value is num) {
      if (minValue != null && value < minValue!) {
        return 'Field $name value $value is less than minValue $minValue';
      }
      if (maxValue != null && value > maxValue!) {
        return 'Field $name value $value exceeds maxValue $maxValue';
      }
    }

    return null;
  }

  /// Validate value against field constraints
  bool validateValue(dynamic value, {bool skipMaxLengthCheck = false}) {
    return getValidationError(
          value,
          skipMaxLengthCheck: skipMaxLengthCheck,
        ) ==
        null;
  }

  /// Validate value for update operation against field constraints
  bool validateUpdateValue(dynamic value) {
    if (value == null && !nullable) {
      return false;
    }

    // Check string length constraints
    if (value is String) {
      if (minLength != null && value.length < minLength!) {
        return false;
      }
    }

    // Check numeric value constraints
    if (value is num) {
      if (minValue != null && value < minValue!) {
        return false;
      }
      if (maxValue != null && value > maxValue!) {
        return false;
      }
    }

    return true;
  }

  /// Check if value matches data type
  bool isValidDataType(dynamic value, DataType type) {
    if (value == null) return true;
    switch (type) {
      case DataType.integer:
        return value is int;
      case DataType.bigInt:
        return value is BigInt ||
            (value is String && BigInt.tryParse(value) != null) ||
            value is int;
      case DataType.double:
        return value is double || value is int;
      case DataType.text:
        return value is String;
      case DataType.blob:
        return value is Uint8List;
      case DataType.boolean:
        return value is bool;
      case DataType.datetime:
        if (value is String) {
          try {
            DateTime.parse(value);
            return true;
          } catch (_) {
            return false;
          }
        }
        return false;
      case DataType.array:
        return value is List;
      case DataType.vector:
        // Accept VectorData, List of numbers, or byte representation
        return value is VectorData ||
            (value is List && value.every((v) => v is num)) ||
            value is Uint8List;
      case DataType.json:
        return value is Map;
    }
  }

  /// Get matcher type for field
  MatcherType getMatcherType() {
    switch (type) {
      case DataType.integer:
        return nullable ? MatcherType.integerNullable : MatcherType.integer;
      case DataType.bigInt:
        return nullable ? MatcherType.bigIntNullable : MatcherType.bigInt;
      case DataType.double:
        return nullable ? MatcherType.doubleNullable : MatcherType.double;
      case DataType.text:
        return nullable ? MatcherType.textNullable : MatcherType.text;
      case DataType.boolean:
        return nullable ? MatcherType.booleanNullable : MatcherType.boolean;
      case DataType.datetime:
        return nullable ? MatcherType.datetimeNullable : MatcherType.datetime;
      case DataType.blob:
        return nullable ? MatcherType.blobNullable : MatcherType.blob;
      default:
        return MatcherType.unsupported;
    }
  }
}

/// index schema
class IndexSchema {
  final String? indexName;
  final List<String> fields;
  final bool unique;
  final IndexType type;

  /// Vector index configuration (only valid when type is IndexType.vector)
  final VectorIndexConfig? vectorConfig;

  const IndexSchema({
    this.indexName,
    required this.fields,
    this.unique = false,
    this.type = IndexType.btree,
    this.vectorConfig,
  });

  /// get actual index name
  String get actualIndexName {
    final prefix = unique ? 'uniq_' : 'idx_';
    // unified prefix
    final baseName = indexName ?? fields.join('_');
    return '$prefix$baseName';
  }

  factory IndexSchema.fromJson(Map<String, dynamic> json) {
    // Parse the index type
    IndexType getIndexType() {
      final typeStr = json['type'] as String?;
      if (typeStr == null) return IndexType.btree;

      // Match using lowercase to be more forgiving
      switch (typeStr.toLowerCase()) {
        case 'hash':
          return IndexType.hash;
        case 'bitmap':
          return IndexType.bitmap;
        case 'vector':
          return IndexType.vector;
        default:
          return IndexType.btree;
      }
    }

    // Parse type
    final indexType = getIndexType();

    // Parse vector configuration if it's a vector index
    VectorIndexConfig? vectorConfig;
    if (indexType == IndexType.vector && json['vectorConfig'] != null) {
      vectorConfig = VectorIndexConfig.fromJson(
          json['vectorConfig'] as Map<String, dynamic>);
    }

    return IndexSchema(
      indexName: json['indexName'] as String?,
      fields: (json['fields'] as List).cast<String>(),
      unique: json['unique'] as bool? ?? false,
      type: indexType,
      vectorConfig: vectorConfig,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (indexName != null) 'indexName': indexName,
      'fields': fields,
      'unique': unique,
      'type': type.toString().split('.').last,
      if (vectorConfig != null) 'vectorConfig': vectorConfig!.toJson(),
    };
  }

  IndexSchema copyWith({
    String? indexName,
    List<String>? fields,
    bool? unique,
    IndexType? type,
    VectorIndexConfig? vectorConfig,
  }) {
    return IndexSchema(
      indexName: indexName ?? this.indexName,
      fields: fields ?? this.fields,
      unique: unique ?? this.unique,
      type: type ?? this.type,
      vectorConfig: vectorConfig ?? this.vectorConfig,
    );
  }
}

/// data type enum
enum DataType {
  integer, // Occupies slightly less than bigInt, loses precision overflow above 18 digits
  bigInt, // Large integer, supports integer values above 18 digits
  double,
  text,
  blob,
  boolean,
  datetime,
  array,
  vector, // Vector data type for storing numerical vector (embeddings)
  json,
}

/// index type enum
enum IndexType {
  btree, // default, btree index
  hash, // hash index
  bitmap, // bitmap index
  vector, // vector similarity index
}

/// Field default value type
enum DefaultValueType {
  /// No special default value, use defaultValue static value
  none,

  /// Use current timestamp
  currentTimestamp,
}

/// Primary key generation method
enum PrimaryKeyType {
  /// Do not automatically generate primary key
  none,

  /// Sequential primary key  (Enabled by central server after exhaustion, then apply)
  sequential,

  /// Timestamp primary key (Based on timestamp + node + sequence number)
  timestampBased,

  /// Date prefixed primary key (Accurate to seconds, date + node + sequence number)
  datePrefixed,

  /// Short code primary key (Timestamp primary key encoded in Base62)
  shortCode,
}

/// Sequential primary key configuration
class SequentialIdConfig {
  /// Initial increment value
  final int initialValue;

  /// Increment step
  final int increment;

  /// Whether to enable random step (1 to increment)
  final bool useRandomIncrement;

  const SequentialIdConfig({
    this.initialValue = 1,
    this.increment = 1,
    this.useRandomIncrement = false,
  });

  SequentialIdConfig copyWith({
    int? initialValue,
    int? increment,
    bool? useRandomIncrement,
  }) {
    return SequentialIdConfig(
      initialValue: initialValue ?? this.initialValue,
      increment: increment ?? this.increment,
      useRandomIncrement: useRandomIncrement ?? this.useRandomIncrement,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'initialValue': initialValue,
      'increment': increment,
      'useRandomIncrement': useRandomIncrement,
    };
  }

  factory SequentialIdConfig.fromJson(Map<String, dynamic> json) {
    return SequentialIdConfig(
      initialValue: json['initialValue'] as int? ?? 1,
      increment: json['increment'] as int? ?? 1,
      useRandomIncrement: json['useRandomIncrement'] as bool? ?? false,
    );
  }
}

/// Primary key configuration
class PrimaryKeyConfig {
  /// Primary key field name
  final String name;

  /// Primary key generation method
  final PrimaryKeyType type;

  /// Sequential increment configuration (Only valid when genType is sequential)
  final SequentialIdConfig? sequentialConfig;

  /// Whether primary key is ordered
  final bool? isOrdered;

  const PrimaryKeyConfig({
    this.name = 'id',
    this.type = PrimaryKeyType.sequential,
    this.sequentialConfig,
    this.isOrdered,
  });

  PrimaryKeyConfig copyWith({
    PrimaryKeyType? type,
    String? name,
    SequentialIdConfig? sequentialConfig,
    bool? isOrdered,
  }) {
    return PrimaryKeyConfig(
      type: type ?? this.type,
      name: name ?? this.name,
      sequentialConfig: sequentialConfig ?? this.sequentialConfig,
      isOrdered: isOrdered ?? this.isOrdered,
    );
  }

  /// Get matcher type for primary key
  MatcherType getMatcherType() {
    switch (type) {
      case PrimaryKeyType.sequential:
      case PrimaryKeyType.timestampBased:
      case PrimaryKeyType.datePrefixed:
        return MatcherType.pkNumericString;
      case PrimaryKeyType.shortCode:
        return MatcherType.pkShortCodeString;
      default:
        if (isOrdered == true) {
          return MatcherType.pkShortCodeString;
        }
        return MatcherType.pkString; // default
    }
  }

  /// Get default data type for primary key
  DataType getDefaultDataType() {
    // All primary key types use text type
    return DataType.text;
  }

  /// Convert value to primary key type
  dynamic convertPrimaryKey(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      return value;
    }
    try {
      return value.toString();
    } catch (e) {
      throw BusinessError(
        'Failed to convert value to primary key type: $value',
        type: BusinessErrorType.invalidData,
      );
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type.toString().split('.').last,
      'name': name,
      if (sequentialConfig != null)
        'sequentialConfig': sequentialConfig!.toJson(),
      if (isOrdered != null) 'isOrdered': isOrdered,
    };
  }

  factory PrimaryKeyConfig.fromJson(Map<String, dynamic> json) {
    PrimaryKeyType getGenType() {
      final value = json['type'] as String?;
      if (value == null) return PrimaryKeyType.sequential;

      switch (value.toLowerCase()) {
        case 'none':
          return PrimaryKeyType.none;
        case 'timestampbased':
          return PrimaryKeyType.timestampBased;
        case 'dateprefixed':
          return PrimaryKeyType.datePrefixed;
        case 'shortcode':
          return PrimaryKeyType.shortCode;
        default:
          return PrimaryKeyType.sequential;
      }
    }

    final genType = getGenType();

    return PrimaryKeyConfig(
      type: genType,
      name: json['name'] as String? ?? 'id',
      sequentialConfig: json['sequentialConfig'] != null
          ? SequentialIdConfig.fromJson(
              json['sequentialConfig'] as Map<String, dynamic>)
          : (genType == PrimaryKeyType.sequential
              ? const SequentialIdConfig()
              : null),
      isOrdered: json['isOrdered'] as bool?,
    );
  }
}

/// Represents vector data for machine learning and similarity search operations
///
/// [VectorData] provides a specialized container for managing numerical vectors used in
/// machine learning applications, similarity searches, and other vector operations.
///
/// Key features:
/// - Supports different precision levels ([VectorPrecision])
/// - Performs basic vector operations (normalization, dot product)
/// - Ensures type safety and validation for vector operations

class VectorData {
  /// Internal storage of vector values
  final List<double> values;

  /// The number of dimensions in this vector
  int get dimensions => values.length;

  /// Creates a new vector with the given values
  ///
  /// Each element represents one dimension in the vector.
  const VectorData(this.values);

  /// Creates a vector from a list of double values
  ///
  /// This is the standard way to create a vector from application data.

  factory VectorData.fromList(List<num> list) {
    return VectorData(list.map((v) => v.toDouble()).toList(growable: false));
  }

  /// Creates a vector from binary data
  ///
  /// The binary data must be in IEEE 754 double-precision format (8 bytes per value).
  /// The total length of the data must be a multiple of 8 bytes.

  factory VectorData.fromBytes(Uint8List bytes) {
    if (bytes.length % 8 != 0) {
      throw ArgumentError(
        'Binary data length (${bytes.length}) must be a multiple of 8 bytes',
      );
    }

    final buffer = bytes.buffer;
    final doubleList = Float64List.view(buffer, 0, bytes.length ~/ 8);
    return VectorData(doubleList.toList(growable: false));
  }

  /// Converts this vector to binary format
  ///
  /// Returns the vector as a list of bytes in IEEE 754 double-precision format.
  /// Each double value (8 bytes) is stored in little-endian byte order.
  ///
  /// Example:
  /// ```dart
  /// // Convert vector to binary for storage
  /// final bytes = vectorData.toBytes();
  /// await database.storeVector(fieldName, bytes);
  /// ```
  Uint8List toBytes() {
    final Float64List floatList = Float64List.fromList(values);
    return Uint8List.view(floatList.buffer);
  }

  /// Convert vector to a standard JSON representation
  List<double> toJson() {
    return List<double>.from(values);
  }

  /// Create a vector from JSON
  factory VectorData.fromJson(List<dynamic> json) {
    return VectorData(
        json.map<double>((v) => (v as num).toDouble()).toList(growable: false));
  }

  /// Get string representation of the vector
  @override
  String toString() {
    if (dimensions <= 6) {
      return 'VectorData$values';
    }
    // For long vectors, show first 3 and last 3 values
    return 'VectorData[${values[0].toStringAsFixed(4)}, ${values[1].toStringAsFixed(4)}, ${values[2].toStringAsFixed(4)}, ..., ${values[dimensions - 3].toStringAsFixed(4)}, ${values[dimensions - 2].toStringAsFixed(4)}, ${values[dimensions - 1].toStringAsFixed(4)}] (dim: $dimensions)';
  }

  /// Compare with another vector
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VectorData) return false;
    if (other.values.length != values.length) return false;

    for (int i = 0; i < values.length; i++) {
      // Use epsilon comparison for floating point values
      if ((values[i] - other.values[i]).abs() > 1e-10) {
        return false;
      }
    }

    return true;
  }

  @override
  int get hashCode => Object.hashAll(values);

  /// Creates a normalized copy of this vector (unit vector)
  ///
  /// Normalization scales the vector so its magnitude (length) equals 1,
  /// which is useful for cosine similarity calculations.

  VectorData normalize() {
    final magnitude = _magnitude();
    if (magnitude == 0) {
      return VectorData(List<double>.filled(dimensions, 0));
    }

    final normalized = List<double>.generate(
      dimensions,
      (i) => values[i] / magnitude,
    );
    return VectorData(normalized);
  }

  /// Calculates the magnitude (length) of this vector
  ///
  /// Returns the Euclidean norm (square root of the sum of squared values).
  double _magnitude() {
    double sumOfSquares = 0;
    for (final value in values) {
      sumOfSquares += value * value;
    }
    return sqrt(sumOfSquares);
  }

  /// Calculates the dot product between this vector and another
  ///
  /// The dot product is the sum of the products of corresponding elements.
  /// For normalized vectors, the dot product equals the cosine similarity.

  double dotProduct(VectorData other) {
    if (dimensions != other.dimensions) {
      throw ArgumentError(
        'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
      );
    }

    double result = 0;
    for (int i = 0; i < dimensions; i++) {
      result += values[i] * other.values[i];
    }
    return result;
  }

  /// Calculates cosine similarity between this vector and another
  ///
  /// Cosine similarity measures the cosine of the angle between two vectors,
  /// providing a value between -1 and 1 where:
  /// - 1 means vectors are identical
  /// - 0 means vectors are orthogonal (unrelated)
  /// - -1 means vectors are exactly opposite
  ///

  double cosineSimilarity(VectorData other) {
    return normalize().dotProduct(other.normalize());
  }

  /// Calculates Euclidean distance between this vector and another
  ///
  /// Euclidean distance measures the straight-line distance between two points
  /// in vector space. Lower values indicate greater similarity.

  double euclideanDistance(VectorData other) {
    if (dimensions != other.dimensions) {
      throw ArgumentError(
        'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
      );
    }

    double sumSquaredDifferences = 0;
    for (int i = 0; i < dimensions; i++) {
      final diff = values[i] - other.values[i];
      sumSquaredDifferences += diff * diff;
    }
    return sqrt(sumSquaredDifferences);
  }

  /// Adds another vector to this vector
  ///
  /// Element-wise addition of corresponding values.
  ///

  VectorData add(VectorData other) {
    if (dimensions != other.dimensions) {
      throw ArgumentError(
        'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
      );
    }

    final result = List<double>.generate(
      dimensions,
      (i) => values[i] + other.values[i],
    );
    return VectorData(result);
  }

  /// Subtracts another vector from this vector
  ///
  /// Element-wise subtraction of corresponding values.

  VectorData subtract(VectorData other) {
    if (dimensions != other.dimensions) {
      throw ArgumentError(
        'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
      );
    }

    final result = List<double>.generate(
      dimensions,
      (i) => values[i] - other.values[i],
    );
    return VectorData(result);
  }

  /// Scales this vector by a scalar value
  ///
  /// Multiplies each element by the given scale factor.

  VectorData scale(double factor) {
    final result = List<double>.generate(
      dimensions,
      (i) => values[i] * factor,
    );
    return VectorData(result);
  }

  /// Calculates the L1 (Manhattan) distance between this vector and another
  ///
  /// L1 distance is the sum of the absolute differences between corresponding elements.

  double manhattanDistance(VectorData other) {
    if (dimensions != other.dimensions) {
      throw ArgumentError(
        'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
      );
    }

    double sum = 0;
    for (int i = 0; i < dimensions; i++) {
      sum += (values[i] - other.values[i]).abs();
    }
    return sum;
  }

  /// Returns a subset of the vector with specified start and length
  ///
  /// Creates a new vector containing elements from `start` index to the index `start + length - 1`.
  ///
  /// Throws RangeError if the range is out of bounds.
  ///
  /// Example:
  /// ```dart
  /// // Get the first 128 dimensions
  /// final firstPart = embedding.subvector(0, 128);
  /// ```
  VectorData subvector(int start, int length) {
    if (start < 0 || start >= dimensions) {
      throw RangeError('Start index out of range: $start');
    }
    if (start + length > dimensions) {
      throw RangeError('End index out of range: ${start + length}');
    }

    return VectorData(values.sublist(start, start + length));
  }

  /// Creates a new vector by concatenating this vector with another
  ///
  /// The resulting vector will have dimensions equal to the sum of both vectors' dimensions.

  VectorData concat(VectorData other) {
    final result = List<double>.from(values)..addAll(other.values);
    return VectorData(result);
  }

  /// Truncates a vector to the specified number of dimensions
  ///
  /// Creates a new vector containing only the first `newDimensions` elements.
  ///
  /// Throws ArgumentError if newDimensions is greater than the current dimensions.
  ///
  /// Example:
  /// ```dart
  /// // Reduce a 1536-dim vector to 768 dimensions
  /// final reducedVector = fullVector.truncate(768);
  /// ```
  VectorData truncate(int newDimensions) {
    if (newDimensions > dimensions) {
      throw ArgumentError(
        'New dimensions ($newDimensions) cannot be greater than current dimensions ($dimensions)',
      );
    }
    return subvector(0, newDimensions);
  }
}

/// Vector field configuration
///
/// Configures the properties of a vector field, such as dimensions and precision.
class VectorFieldConfig {
  /// Dimension of the vector
  ///
  /// Specifies the number of dimensions (length) of the vector.
  /// Common values are 384, 512, 768, 1024, and 1536 (for OpenAI embeddings).
  final int dimensions;

  /// Precision of vector data (bits per dimension)
  ///
  /// Controls how the vector is stored and the precision of calculations.
  final VectorPrecision precision;

  /// Constructor
  const VectorFieldConfig({
    required this.dimensions,
    this.precision = VectorPrecision.float64,
  });

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'dimensions': dimensions,
      'precision': precision.toString().split('.').last,
    };
  }

  /// Create from JSON
  factory VectorFieldConfig.fromJson(Map<String, dynamic> json) {
    // Parse precision
    VectorPrecision getPrecision() {
      final precisionStr = json['precision'] as String?;
      if (precisionStr == null) return VectorPrecision.float64;

      switch (precisionStr.toLowerCase()) {
        case 'float32':
          return VectorPrecision.float32;
        case 'int8':
          return VectorPrecision.int8;
        default:
          return VectorPrecision.float64;
      }
    }

    return VectorFieldConfig(
      dimensions: json['dimensions'] as int? ?? 0,
      precision: getPrecision(),
    );
  }

  /// Copy with new values
  VectorFieldConfig copyWith({
    int? dimensions,
    VectorPrecision? precision,
  }) {
    return VectorFieldConfig(
      dimensions: dimensions ?? this.dimensions,
      precision: precision ?? this.precision,
    );
  }
}

/// Vector precision options
///
/// Specifies the numeric precision used for storing vector values.
/// Higher precision offers better accuracy but uses more storage space.
enum VectorPrecision {
  /// 64-bit floating point (IEEE 754)
  ///
  /// Default and highest precision, uses 8 bytes per dimension
  float64,

  /// 32-bit floating point
  ///
  /// Standard single precision, uses 4 bytes per dimension
  /// Offers a good balance between precision and storage efficiency
  float32,

  /// 8-bit integer (quantized)
  ///
  /// Uses quantization to reduce storage to 1 byte per dimension
  /// Significant memory savings with some loss of precision
  int8,
}

/// Vector index type.
///
enum VectorIndexType {
  /// NGH (Node-Graph Hybrid)
  ngh,
}

/// Vector distance metric for similarity calculations
///
/// Specifies how the distance/similarity between vectors is calculated.
/// The appropriate metric depends on your application and how vectors were created.
enum VectorDistanceMetric {
  /// Euclidean distance (L2)
  ///
  /// Straight-line distance in vector space
  /// Lower values indicate greater similarity
  l2,

  /// Inner product
  ///
  /// Dot product of vectors
  /// Higher values indicate greater similarity
  /// Most efficient but requires normalized vectors for meaningful similarity
  innerProduct,

  /// Cosine similarity
  ///
  /// Measures the cosine of the angle between vectors
  /// Higher values indicate greater similarity
  /// Invariant to vector magnitude, focuses on direction
  cosine,
}

/// Vector Index Configuration for NGH (Node-Graph Hybrid) vector search.
///
/// Configures how vector indexes are built and searched.
/// This is used with [IndexSchema] when the index type is [IndexType.vector].
///
/// Example:
/// ```dart
/// VectorIndexConfig(
///   distanceMetric: VectorDistanceMetric.cosine,
///   maxDegree: 64,
///   efSearch: 64,
///   constructionEf: 128,
/// )
/// ```
class VectorIndexConfig {
  /// Type of vector index. Currently only supports [VectorIndexType.ngh].
  final VectorIndexType indexType;

  /// Distance metric for similarity search.
  ///
  /// - [VectorDistanceMetric.l2]: Euclidean distance (lower = more similar)
  /// - [VectorDistanceMetric.cosine]: Cosine similarity (higher = more similar)
  /// - [VectorDistanceMetric.innerProduct]: Dot product (higher = more similar)
  final VectorDistanceMetric distanceMetric;

  /// Maximum out-degree per graph node (R).
  ///
  /// Higher values improve recall but increase memory and construction time.
  /// Recommended: 32 for mobile/edge, 64 for desktop/server.
  final int? maxDegree;

  /// Search expansion factor (ef_search).
  ///
  /// Controls the search quality–speed trade-off. Higher values improve
  /// recall at the cost of latency. Standard ANN terminology.
  final int? efSearch;

  /// Expansion factor during graph construction (ef_construction).
  ///
  /// Higher values build a better-quality graph but take longer.
  /// Typical range: 64–256.
  final int? constructionEf;

  /// Diversity parameter for Robust Prune (α ≥ 1.0).
  ///
  /// Higher values produce more diverse neighbor selections, improving recall
  /// for high-dimensional data. Default 1.2.
  final double? pruneAlpha;

  /// Number of PQ sub-spaces (M).
  ///
  /// If null, automatically calculated as `dimensions / 8` (clamped to [8, 128]).
  /// Must evenly divide the vector dimensions.
  final int? pqSubspaces;

  /// Constructor
  const VectorIndexConfig({
    this.indexType = VectorIndexType.ngh,
    this.distanceMetric = VectorDistanceMetric.cosine,
    this.maxDegree,
    this.efSearch,
    this.constructionEf,
    this.pruneAlpha,
    this.pqSubspaces,
  });

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'indexType': indexType.name,
      'distanceMetric': distanceMetric.name,
      if (maxDegree != null) 'maxDegree': maxDegree,
      if (efSearch != null) 'efSearch': efSearch,
      if (constructionEf != null) 'constructionEf': constructionEf,
      if (pruneAlpha != null) 'pruneAlpha': pruneAlpha,
      if (pqSubspaces != null) 'pqSubspaces': pqSubspaces,
    };
  }

  /// Create from JSON
  factory VectorIndexConfig.fromJson(Map<String, dynamic> json) {
    VectorIndexType indexType = VectorIndexType.ngh;
    final typeStr = json['indexType'] as String?;
    if (typeStr != null && typeStr.toLowerCase() == 'ngh') {
      indexType = VectorIndexType.ngh;
    }

    VectorDistanceMetric distanceMetric = VectorDistanceMetric.cosine;
    final metricStr = json['distanceMetric'] as String?;
    if (metricStr != null) {
      switch (metricStr.toLowerCase()) {
        case 'l2':
          distanceMetric = VectorDistanceMetric.l2;
          break;
        case 'innerproduct':
          distanceMetric = VectorDistanceMetric.innerProduct;
          break;
      }
    }

    // Support both flat fields and legacy nested 'parameters' map
    final params = json['parameters'] as Map<String, dynamic>? ?? json;

    return VectorIndexConfig(
      indexType: indexType,
      distanceMetric: distanceMetric,
      maxDegree: (params['maxDegree'] as num?)?.toInt() ??
          (json['maxDegree'] as num?)?.toInt(),
      efSearch: (params['efSearch'] as num?)?.toInt() ??
          (json['efSearch'] as num?)?.toInt(),
      constructionEf: (params['constructionEf'] as num?)?.toInt() ??
          (json['constructionEf'] as num?)?.toInt(),
      pruneAlpha: (params['pruneAlpha'] as num?)?.toDouble() ??
          (json['pruneAlpha'] as num?)?.toDouble(),
      pqSubspaces: (params['pqSubspaces'] as num?)?.toInt() ??
          (json['pqSubspaces'] as num?)?.toInt(),
    );
  }
}

/// Vector utility methods extension
extension VectorMethods on VectorData {
  /// Calculate dot product with another vector
  double dotProduct(VectorData other) {
    if (dimensions != other.dimensions) {
      throw ArgumentError('Vectors must have same dimensions');
    }

    double sum = 0;
    for (int i = 0; i < dimensions; i++) {
      sum += values[i] * other.values[i];
    }
    return sum;
  }

  /// Calculate Euclidean distance (L2) to another vector
  double l2Distance(VectorData other) {
    if (dimensions != other.dimensions) {
      throw ArgumentError('Vectors must have same dimensions');
    }

    double sum = 0;
    for (int i = 0; i < dimensions; i++) {
      final diff = values[i] - other.values[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }

  /// Calculate cosine similarity to another vector
  double cosineSimilarity(VectorData other) {
    if (dimensions != other.dimensions) {
      throw ArgumentError('Vectors must have same dimensions');
    }

    // Calculate dot product
    double dotProd = dotProduct(other);

    // Calculate magnitudes
    double mag1 = 0;
    double mag2 = 0;

    for (int i = 0; i < dimensions; i++) {
      mag1 += values[i] * values[i];
      mag2 += other.values[i] * other.values[i];
    }

    mag1 = sqrt(mag1);
    mag2 = sqrt(mag2);

    // Avoid division by zero
    if (mag1 == 0 || mag2 == 0) return 0;

    return dotProd / (mag1 * mag2);
  }

  /// Normalize the vector (convert to unit vector)
  VectorData normalize() {
    // Calculate magnitude
    double sumSquares = 0;
    for (final val in values) {
      sumSquares += val * val;
    }

    final magnitude = sqrt(sumSquares);

    // Avoid division by zero
    if (magnitude == 0) return this;

    // Create normalized values
    final normalizedValues =
        values.map((v) => v / magnitude).toList(growable: false);
    return VectorData(normalizedValues);
  }
}

/// ForeignKeyCascadeAction: Foreign key cascade action enum
///
/// Define how to handle related records in the child table (referenced table) when the record in the parent table (referenced table) is deleted or updated
enum ForeignKeyCascadeAction {
  /// Restrict operation (RESTRICT)
  ///
  /// If there are rows referencing this record in the child table, prohibit deleting or updating the record in the parent table
  /// This is the strictest constraint, ensuring data integrity
  restrict,

  /// Cascade delete/update (CASCADE)
  ///
  /// When the record in the parent table is deleted or updated, automatically delete or update all rows referencing this record in the child table
  /// For example: when deleting a user, automatically delete all orders of the user
  cascade,

  /// Set to null (SET NULL)
  ///
  /// When the record in the parent table is deleted or updated, set the foreign key field in the child table referencing this record to null
  /// Note: the foreign key field must allow null
  setNull,

  /// Set to default value (SET DEFAULT)
  ///
  /// When the record in the parent table is deleted or updated, set the foreign key field in the child table referencing this record to default value
  /// Note: the foreign key field must have a default value
  setDefault,

  /// No action (NO ACTION)
  ///
  /// Similar to RESTRICT, but in some database systems, the check may be delayed until the end of the transaction
  /// If the constraint is violated, the transaction will be rolled back
  noAction,
}

/// ForeignKeySchema: Foreign key constraint configuration
///
/// Define the relationship between tables, ensuring reference integrity
///
/// Example:
/// ```dart
/// // Simple foreign key: order table references user table
/// ForeignKeySchema(
///   name: 'fk_order_user',
///   fields: ['user_id'],
///   referencedTable: 'users',
///   referencedFields: ['id'],
///   onDelete: ForeignKeyCascadeAction.cascade,
///   onUpdate: ForeignKeyCascadeAction.cascade,
/// )
///
/// // Composite foreign key: order item table references order table and product table
/// ForeignKeySchema(
///   name: 'fk_order_item_order',
///   fields: ['order_id', 'product_id'],
///   referencedTable: 'orders',
///   referencedFields: ['id', 'product_id'],
///   onDelete: ForeignKeyCascadeAction.restrict,
///   onUpdate: ForeignKeyCascadeAction.cascade,
/// )
/// ```
class ForeignKeySchema {
  /// Foreign key constraint name (optional, used for identification and management)
  ///
  /// If not provided, the system will automatically generate: fk_{table name}_{field name}
  final String? name;

  /// Fields in this table (child table)
  ///
  /// For simple foreign keys, only contains one field name
  /// For composite foreign keys, contains multiple field names, the order must correspond to referencedFields
  ///
  /// Example:
  /// - Simple foreign key: `['user_id']`
  /// - Composite foreign key: `['order_id', 'product_id']`
  final List<String> fields;

  /// Referenced table name (parent table)
  final String referencedTable;

  /// Fields in the referenced table (parent table)
  ///
  /// Usually the primary key or unique index fields
  /// The order must correspond to fields, and the field types must be compatible
  ///
  /// Example:
  /// - Simple foreign key: `['id']`
  /// - Composite foreign key: `['id', 'product_id']`
  final List<String> referencedFields;

  /// Cascade action for DELETE operation
  ///
  /// When the record in the parent table is deleted, how to handle the related records in the child table
  /// Default value: restrict (prohibit deletion)
  final ForeignKeyCascadeAction onDelete;

  /// Cascade action for UPDATE operation
  ///
  /// When the record in the parent table is updated, how to handle the related records in the child table
  /// Default value: restrict (prohibit update)
  final ForeignKeyCascadeAction onUpdate;

  /// Whether to automatically create index for foreign key fields
  ///
  /// Default value: true
  /// Foreign key fields usually need indexes to improve JOIN query performance
  final bool autoCreateIndex;

  /// Whether the foreign key constraint is enabled
  ///
  /// Default value: true
  /// Can temporarily disable foreign key constraints (e.g. during data migration)
  final bool enabled;

  /// Comment for the foreign key constraint
  final String? comment;

  ForeignKeySchema({
    this.name,
    required this.fields,
    required this.referencedTable,
    required this.referencedFields,
    this.onDelete = ForeignKeyCascadeAction.restrict,
    this.onUpdate = ForeignKeyCascadeAction.restrict,
    this.autoCreateIndex = true,
    this.enabled = true,
    this.comment,
  })  : assert(
          fields.isNotEmpty,
          'Foreign key fields cannot be empty',
        ),
        assert(
          referencedFields.isNotEmpty,
          'Referenced fields cannot be empty',
        ),
        assert(
          fields.length == referencedFields.length,
          'Fields and referencedFields must have the same length',
        );

  /// Get the actual name of the foreign key constraint
  ///
  /// If name is provided, use it; otherwise, generate automatically
  String get actualName {
    if (name != null && name!.isNotEmpty) {
      return name!;
    }
    // Automatically generate name: fk_{table name}_{field name}
    final fieldNames = fields.join('_');
    return 'fk_$fieldNames';
  }

  /// Whether it is a composite foreign key (contains multiple fields)
  bool get isComposite => fields.length > 1;

  /// Create a copy and modify some properties
  ForeignKeySchema copyWith({
    String? name,
    List<String>? fields,
    String? referencedTable,
    List<String>? referencedFields,
    ForeignKeyCascadeAction? onDelete,
    ForeignKeyCascadeAction? onUpdate,
    bool? autoCreateIndex,
    bool? enabled,
    String? comment,
  }) {
    return ForeignKeySchema(
      name: name ?? this.name,
      fields: fields ?? this.fields,
      referencedTable: referencedTable ?? this.referencedTable,
      referencedFields: referencedFields ?? this.referencedFields,
      onDelete: onDelete ?? this.onDelete,
      onUpdate: onUpdate ?? this.onUpdate,
      autoCreateIndex: autoCreateIndex ?? this.autoCreateIndex,
      enabled: enabled ?? this.enabled,
      comment: comment ?? this.comment,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      if (name != null) 'name': name,
      'fields': fields,
      'referencedTable': referencedTable,
      'referencedFields': referencedFields,
      'onDelete': onDelete.toString().split('.').last,
      'onUpdate': onUpdate.toString().split('.').last,
      'autoCreateIndex': autoCreateIndex,
      'enabled': enabled,
      if (comment != null) 'comment': comment,
    };
  }

  /// Create from JSON
  factory ForeignKeySchema.fromJson(Map<String, dynamic> json) {
    // Parse cascade action
    ForeignKeyCascadeAction parseCascadeAction(String? value) {
      if (value == null) return ForeignKeyCascadeAction.restrict;
      switch (value.toLowerCase()) {
        case 'restrict':
          return ForeignKeyCascadeAction.restrict;
        case 'cascade':
          return ForeignKeyCascadeAction.cascade;
        case 'setnull':
        case 'set_null':
          return ForeignKeyCascadeAction.setNull;
        case 'setdefault':
        case 'set_default':
          return ForeignKeyCascadeAction.setDefault;
        case 'noaction':
        case 'no_action':
          return ForeignKeyCascadeAction.noAction;
        default:
          return ForeignKeyCascadeAction.restrict;
      }
    }

    return ForeignKeySchema(
      name: json['name'] as String?,
      fields: (json['fields'] as List).cast<String>(),
      referencedTable: json['referencedTable'] as String,
      referencedFields: (json['referencedFields'] as List).cast<String>(),
      onDelete: parseCascadeAction(json['onDelete'] as String?),
      onUpdate: parseCascadeAction(json['onUpdate'] as String?),
      autoCreateIndex: json['autoCreateIndex'] as bool? ?? true,
      enabled: json['enabled'] as bool? ?? true,
      comment: json['comment'] as String?,
    );
  }

  /// Validate the validity of the foreign key configuration
  ///
  /// Check the number of fields, name format, etc.
  bool validate() {
    // Validate that the field list is not empty
    if (fields.isEmpty || referencedFields.isEmpty) {
      return false;
    }

    // Validate that the number of fields matches
    if (fields.length != referencedFields.length) {
      return false;
    }

    // Validate that the field name format is valid (letters, numbers, underscores)
    final nameRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');
    for (final field in fields) {
      if (!nameRegex.hasMatch(field)) {
        return false;
      }
    }
    for (final field in referencedFields) {
      if (!nameRegex.hasMatch(field)) {
        return false;
      }
    }

    // Validate that the table name format is valid
    if (!nameRegex.hasMatch(referencedTable)) {
      return false;
    }

    // Validate that the foreign key name format is valid (if provided)
    if (name != null && name!.isNotEmpty && !nameRegex.hasMatch(name!)) {
      return false;
    }

    return true;
  }

  @override
  String toString() {
    return 'ForeignKeySchema('
        'name: $actualName, '
        'fields: $fields, '
        'referencedTable: $referencedTable, '
        'referencedFields: $referencedFields, '
        'onDelete: $onDelete, '
        'onUpdate: $onUpdate)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ForeignKeySchema) return false;
    return actualName == other.actualName &&
        fields.toString() == other.fields.toString() &&
        referencedTable == other.referencedTable &&
        referencedFields.toString() == other.referencedFields.toString();
  }

  @override
  int get hashCode {
    return Object.hash(
      actualName,
      fields.toString(),
      referencedTable,
      referencedFields.toString(),
    );
  }
}
