import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';
import '../handler/logger.dart';
import '../handler/sha256.dart';

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
    this.isGlobal = false,
    this.tableId,
  });

  /// Get primary key name
  String get primaryKey => primaryKeyConfig.name;

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

    return true;
  }

  /// Validate index fields
  bool validateIndexFields(IndexSchema index) {
    final primaryKeyName = primaryKeyConfig.name;

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
    bool? isGlobal,
    String? tableId,
  }) {
    return TableSchema(
      name: name ?? this.name,
      primaryKeyConfig: primaryKeyConfig ?? this.primaryKeyConfig,
      fields: fields ?? this.fields,
      indexes: indexes ?? this.indexes,
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
      'isGlobal': isGlobal,
      if (tableId != null) 'tableId': tableId,
    };
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
      isGlobal: json['isGlobal'] as bool? ?? false,
      tableId: json['tableId'] as String?,
    );
  }

  /// Validate data against table schema
  /// If [applyConstraints] is true, it will modify the data to fit constraints (e.g., truncate strings)
  Map<String, dynamic>? validateData(Map<String, dynamic> data,
      {bool applyConstraints = false}) {
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
        Logger.warn(
          'Invalid primary key $primaryKeyName value type: $primaryKeyValue (Should be number or string type)',
          label: 'TableSchema.validateData',
        );
        return null;
      }
    }

    // Check required fields
    for (var field in fields) {
      if (!field.nullable &&
          !data.containsKey(field.name) &&
          field.name != primaryKeyName) {
        Logger.warn(
          'Field ${field.name} is required but not provided',
          label: 'TableSchema.validateData',
        );
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

      // Use FieldSchema's validateValue method
      if (!fieldSchema.validateValue(entry.value,
          skipMaxLengthCheck: applyConstraints)) {
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

    // Add sequential increment configuration
    if (config.sequentialConfig != null) {
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
  }

  /// Add index schema to buffer
  static void _addIndexSchemaToBuffer(BytesBuilder buffer, IndexSchema index) {
    _addStringToBuffer(buffer, index.indexName ?? "");
    buffer.addByte(index.unique ? 1 : 0);
    buffer.addByte(index.type.index);

    // Index fields
    final sortedIndexFields = List<String>.from(index.fields)..sort();
    buffer.addByte(sortedIndexFields.length);
    for (final fieldName in sortedIndexFields) {
      _addStringToBuffer(buffer, fieldName);
    }
  }

  /// Add string to binary buffer
  static void _addStringToBuffer(BytesBuilder buffer, String value) {
    final bytes = utf8.encode(value);
    buffer.addByte(bytes.length); // Length prefix
    buffer.add(bytes);
  }

  /// Add optional integer to buffer
  static void _addOptionalInt(BytesBuilder buffer, int? value) {
    if (value == null) {
      buffer.addByte(0);
    } else {
      buffer.addByte(1);
      // Integer to 4 bytes
      buffer.addByte((value >> 24) & 0xFF);
      buffer.addByte((value >> 16) & 0xFF);
      buffer.addByte((value >> 8) & 0xFF);
      buffer.addByte(value & 0xFF);
    }
  }

  /// Add 32-bit integer to buffer
  static void _addInt32ToBuffer(BytesBuilder buffer, int value) {
    buffer.addByte((value >> 24) & 0xFF);
    buffer.addByte((value >> 16) & 0xFF);
    buffer.addByte((value >> 8) & 0xFF);
    buffer.addByte(value & 0xFF);
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
  final int? maxLength; // for text fields
  final int? minLength; // for text fields
  final num? minValue; // for numeric fields (integer, double)
  final num? maxValue; // for numeric fields (integer, double)
  final String? comment; // field comment
  final String?
      fieldId; // Unique identifier for fields, used for rename detection

  const FieldSchema({
    required this.name,
    required this.type,
    this.nullable = true,
    this.defaultValue,
    this.unique = false,
    this.maxLength,
    this.minLength,
    this.minValue,
    this.maxValue,
    this.comment,
    this.fieldId,
  });

  /// Create copy with modifications
  FieldSchema copyWith({
    String? name,
    DataType? type,
    bool? nullable,
    dynamic defaultValue = _unsetValue,
    bool? unique,
    int? maxLength,
    int? minLength,
    num? minValue,
    num? maxValue,
    String? comment,
    String? fieldId,
  }) {
    return FieldSchema(
      name: name ?? this.name,
      type: type ?? this.type,
      nullable: nullable ?? this.nullable,
      defaultValue:
          defaultValue == _unsetValue ? this.defaultValue : defaultValue,
      unique: unique ?? this.unique,
      maxLength: maxLength ?? this.maxLength,
      minLength: minLength ?? this.minLength,
      minValue: minValue ?? this.minValue,
      maxValue: maxValue ?? this.maxValue,
      comment: comment ?? this.comment,
      fieldId: fieldId ?? this.fieldId,
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
      'comment': comment,
      if (fieldId != null) 'fieldId': fieldId,
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

    return FieldSchema(
      name: json['name'] as String,
      type: getType(),
      nullable: json['nullable'] as bool? ?? true,
      defaultValue: json['defaultValue'],
      unique: json['unique'] as bool? ?? false,
      maxLength: json['maxLength'] as int?,
      minLength: json['minLength'] as int?,
      minValue: json['minValue'] as num?,
      maxValue: json['maxValue'] as num?,
      comment: json['comment'] as String?,
      fieldId: json['fieldId'] as String?,
    );
  }

  /// Get default value for this field
  dynamic getDefaultValue() {
    if (defaultValue != null) {
      return defaultValue;
    }
    if (!nullable) {
      switch (type) {
        case DataType.integer:
          return max(minValue?.toInt() ?? 0, 0);
        case DataType.bigInt:
          return BigInt.from(max(minValue?.toInt() ?? 0, 0));
        case DataType.double:
          return max(minValue?.toDouble() ?? 0.0, 0.0);
        case DataType.text:
          return '';
        case DataType.boolean:
          return false;
        case DataType.datetime:
          return DateTime.now().toIso8601String();
        case DataType.blob:
          return Uint8List(0);
        case DataType.array:
          return [];
      }
    }
    return null;
  }

  /// Validate value against field constraints
  bool validateValue(dynamic value, {bool skipMaxLengthCheck = false}) {
    if (value == null && !nullable) {
      return false;
    }

    // Check data type
    if (!isValidDataType(value, type)) {
      return false;
    }

    // Check string length constraints
    if (value is String) {
      if (!skipMaxLengthCheck &&
          maxLength != null &&
          value.length > maxLength!) {
        return false;
      }
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
    }
  }

  /// Convert value between data types
  dynamic convertValue({dynamic value, DataType? targetType}) {
    if (defaultValue == null && value == null) return null;
    final valueTemp = value ?? defaultValue;
    targetType ??= type;

    switch (targetType) {
      case DataType.integer:
        if (valueTemp is int) return valueTemp;
        if (valueTemp is double) return valueTemp.round();
        if (valueTemp is String) return int.tryParse(valueTemp);
        if (valueTemp is bool) return valueTemp ? 1 : 0;
        if (valueTemp is DateTime) {
          return valueTemp.millisecondsSinceEpoch;
        }
        if (valueTemp is BigInt) {
          // Try to convert BigInt to int, return null or max value if out of range
          if (valueTemp <= BigInt.from(9007199254740991) &&
              valueTemp >= BigInt.from(-9007199254740991)) {
            return valueTemp.toInt();
          }
          return null; // Out of range
        }
        return null;
      case DataType.bigInt:
        if (valueTemp is BigInt) return valueTemp;
        if (valueTemp is int) return BigInt.from(valueTemp);
        if (valueTemp is String) {
          try {
            return BigInt.parse(valueTemp);
          } catch (_) {
            return null;
          }
        }
        if (valueTemp is bool) {
          return valueTemp ? BigInt.from(1) : BigInt.from(0);
        }
        if (valueTemp is DateTime) {
          return BigInt.from(valueTemp.millisecondsSinceEpoch);
        }
        return null;
      case DataType.double:
        if (valueTemp is double) return valueTemp;
        if (valueTemp is int) return valueTemp.toDouble();
        if (valueTemp is String) return double.tryParse(valueTemp);
        if (valueTemp is bool) return valueTemp ? 1.0 : 0.0;
        if (valueTemp is DateTime) {
          return valueTemp.millisecondsSinceEpoch.toDouble();
        }
        if (valueTemp is BigInt) {
          // Try to convert BigInt to double, may lose precision
          try {
            return valueTemp.toDouble();
          } catch (e) {
            return null;
          }
        }
        return null;
      case DataType.text:
        if (valueTemp is String) return valueTemp;
        if (valueTemp is DateTime) {
          try {
            return valueTemp.toIso8601String();
          } catch (e) {
            Logger.warn(
              'Failed to convert DateTime to string: $valueTemp',
              label: 'DataStore._toString',
            );
            return null;
          }
        }
        if (valueTemp is BigInt) {
          return valueTemp.toString();
        }
        return valueTemp?.toString();
      case DataType.blob:
        if (valueTemp is Uint8List) return valueTemp;
        if (valueTemp is String) {
          return Uint8List.fromList(utf8.encode(valueTemp));
        }
        if (valueTemp is List<int>) return Uint8List.fromList(valueTemp);
        return null;
      case DataType.boolean:
        if (valueTemp is bool) return valueTemp;
        if (valueTemp is int) return valueTemp != 0;
        if (valueTemp is double) return valueTemp != 0.0;
        if (valueTemp is String) {
          final lower = valueTemp.toLowerCase();
          return lower == 'true' || lower == '1' || lower == 'yes';
        }
        if (valueTemp is BigInt) return valueTemp != BigInt.zero;
        return null;
      case DataType.datetime:
        if (valueTemp == null) return null;
        if (valueTemp is DateTime) return valueTemp.toIso8601String();
        if (valueTemp is String) {
          try {
            return DateTime.parse(valueTemp).toIso8601String();
          } catch (e) {
            Logger.warn(
              'Failed to parse DateTime from string: $valueTemp',
              label: 'DataStore._toDateTimeString',
            );
            return null;
          }
        }
        if (valueTemp is int) {
          try {
            return DateTime.fromMillisecondsSinceEpoch(valueTemp)
                .toIso8601String();
          } catch (e) {
            Logger.warn(
              'Failed to convert timestamp to DateTime: $valueTemp',
              label: 'DataStore._toDateTimeString',
            );
            return null;
          }
        }
        if (valueTemp is BigInt) {
          try {
            if (valueTemp <= BigInt.from(8640000000000000) &&
                valueTemp >= BigInt.from(-8640000000000000)) {
              return DateTime.fromMillisecondsSinceEpoch(valueTemp.toInt())
                  .toIso8601String();
            }
            return null; // Out of range
          } catch (e) {
            Logger.warn(
              'Failed to convert BigInt to DateTime: $valueTemp',
              label: 'DataStore._toDateTimeString',
            );
            return null;
          }
        }
        return null;
      case DataType.array:
        if (valueTemp is List) return valueTemp;
        if (valueTemp is String) {
          try {
            return jsonDecode(valueTemp) as List?;
          } catch (_) {
            return [valueTemp];
          }
        }
        return valueTemp == null ? null : [valueTemp];
    }
  }
}

/// index schema
class IndexSchema {
  final String? indexName;
  final List<String> fields;
  final bool unique;
  final IndexType type;

  const IndexSchema({
    this.indexName,
    required this.fields,
    this.unique = false,
    this.type = IndexType.btree,
  });

  /// get actual index name
  String get actualIndexName {
    final prefix = unique ? 'uniq_' : 'idx_';
    // unified prefix
    final baseName = indexName ?? fields.join('_');
    return '$prefix$baseName';
  }

  factory IndexSchema.fromJson(Map<String, dynamic> json) {
    return IndexSchema(
      indexName: json['indexName'] as String?,
      fields: (json['fields'] as List).cast<String>(),
      unique: json['unique'] as bool? ?? false,
      type: IndexType.values.firstWhere(
        (t) => t.toString() == 'IndexType.${json['type']}',
        orElse: () => IndexType.btree,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (indexName != null) 'indexName': indexName,
      'fields': fields,
      'unique': unique,
      'type': type.toString().split('.').last,
    };
  }

  IndexSchema copyWith({
    String? indexName,
    List<String>? fields,
    bool? unique,
    IndexType? type,
  }) {
    return IndexSchema(
      indexName: indexName ?? this.indexName,
      fields: fields ?? this.fields,
      unique: unique ?? this.unique,
      type: type ?? this.type,
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
}

/// index type enum
enum IndexType {
  btree, // default, btree index
  hash, // hash index
  bitmap, // bitmap index
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

  /// Get default data type for primary key
  DataType getDefaultDataType() {
    // All primary key types use text type
    return DataType.text;
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
