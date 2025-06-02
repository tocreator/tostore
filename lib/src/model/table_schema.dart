import 'dart:math' show max, sqrt;
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

  /// Configuration for vector fields (only valid when type is DataType.vector)
  final VectorFieldConfig? vectorConfig;

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
    this.vectorConfig,
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
    VectorFieldConfig? vectorConfig,
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
      vectorConfig: vectorConfig ?? this.vectorConfig,
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
      if (vectorConfig != null) 'vectorConfig': vectorConfig!.toJson(),
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
      maxLength: json['maxLength'] as int?,
      minLength: json['minLength'] as int?,
      minValue: json['minValue'] as num?,
      maxValue: json['maxValue'] as num?,
      comment: json['comment'] as String?,
      fieldId: json['fieldId'] as String?,
      vectorConfig: vectorConfig,
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
        case DataType.vector:
          return const VectorData([]); // Empty vector as default
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
      case DataType.vector:
        // Accept VectorData, List of numbers, or byte representation
        return value is VectorData ||
            (value is List && value.every((v) => v is num)) ||
            value is Uint8List;
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
      case DataType.vector:
        if (valueTemp is VectorData) return valueTemp;
        if (valueTemp is List && valueTemp.every((v) => v is num)) {
          return VectorData.fromList(valueTemp.cast<num>());
        }
        if (valueTemp is Uint8List) {
          try {
            return VectorData.fromBytes(valueTemp);
          } catch (e) {
            Logger.warn(
              'Failed to convert binary data to vector: $e',
              label: 'DataStore._toVector',
            );
            return null;
          }
        }
        if (valueTemp is String) {
          try {
            final jsonList = jsonDecode(valueTemp);
            if (jsonList is List && jsonList.every((v) => v is num)) {
              return VectorData.fromList(jsonList.cast<num>());
            }
          } catch (e) {
            Logger.warn(
              'Failed to parse vector from string: $valueTemp',
              label: 'DataStore._toVector',
            );
          }
        }
        return null;
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
}

/// index type enum
enum IndexType {
  btree, // default, btree index
  hash, // hash index
  bitmap, // bitmap index
  vector, // vector similarity index
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

/// Represents vector data for machine learning and similarity search operations
///
/// [VectorData] provides a specialized container for managing numerical vectors used in
/// machine learning applications, similarity searches, and other vector operations.
///
/// Key features:
/// - Supports different precision levels ([VectorPrecision])
/// - Performs basic vector operations (normalization, dot product)
/// - Ensures type safety and validation for vector operations
///
/// Example usage:
/// ```dart
/// // Create a vector from a list of doubles
/// final vector = VectorData.fromList([0.1, 0.2, 0.3, 0.4]);
///
/// // Convert to normalized form (unit vector)
/// final normalized = vector.normalize();
///
/// // Calculate similarity with another vector
/// final similarity = normalized.dotProduct(anotherVector);
///
/// // Convert to binary format for storage
/// final bytes = vector.toBytes();
/// ```
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
  ///
  /// Example:
  /// ```dart
  /// final embedding = VectorData.fromList([0.42, -0.087, 0.34, ...]);
  /// ```
  factory VectorData.fromList(List<num> list) {
    return VectorData(list.map((v) => v.toDouble()).toList(growable: false));
  }

  /// Creates a vector from binary data
  ///
  /// The binary data must be in IEEE 754 double-precision format (8 bytes per value).
  /// The total length of the data must be a multiple of 8 bytes.
  ///
  /// Throws [ArgumentError] if the data length is not valid (must be multiple of 8 bytes).
  ///
  /// Example:
  /// ```dart
  /// // Restore a vector from stored binary data
  /// final vector = VectorData.fromBytes(storedBinaryData);
  /// ```
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
  ///
  /// Returns a new [VectorData] instance with normalized values.
  /// Returns a zero vector if the original vector has zero magnitude.
  ///
  /// Example:
  /// ```dart
  /// // Normalize a vector for cosine similarity comparison
  /// final unitVector = embedding.normalize();
  /// ```
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
  ///
  /// Throws [ArgumentError] if the vectors have different dimensions.
  ///
  /// Example:
  /// ```dart
  /// // Calculate similarity between two normalized vectors
  /// final similarity = vector1.normalize().dotProduct(vector2.normalize());
  /// // Values close to 1 indicate high similarity
  /// ```
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
  /// Throws [ArgumentError] if the vectors have different dimensions.
  ///
  /// Example:
  /// ```dart
  /// final similarity = queryVector.cosineSimilarity(documentVector);
  /// if (similarity > 0.8) {
  ///   print('High similarity match found');
  /// }
  /// ```
  double cosineSimilarity(VectorData other) {
    return normalize().dotProduct(other.normalize());
  }

  /// Calculates Euclidean distance between this vector and another
  ///
  /// Euclidean distance measures the straight-line distance between two points
  /// in vector space. Lower values indicate greater similarity.
  ///
  /// Throws [ArgumentError] if the vectors have different dimensions.
  ///
  /// Example:
  /// ```dart
  /// final distance = vector1.euclideanDistance(vector2);
  /// if (distance < threshold) {
  ///   print('Vectors are similar');
  /// }
  /// ```
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
  /// Throws [ArgumentError] if the vectors have different dimensions.
  ///
  /// Example:
  /// ```dart
  /// final combinedVector = vector1.add(vector2);
  /// ```
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
  ///
  /// Throws [ArgumentError] if the vectors have different dimensions.
  ///
  /// Example:
  /// ```dart
  /// final differenceVector = vector1.subtract(vector2);
  /// ```
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
  ///
  /// Example:
  /// ```dart
  /// final doubledVector = vector.scale(2.0);
  /// final halvedVector = vector.scale(0.5);
  /// ```
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
  ///
  /// Throws [ArgumentError] if the vectors have different dimensions.
  ///
  /// Example:
  /// ```dart
  /// final distance = vector1.manhattanDistance(vector2);
  /// ```
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
  /// Creates a new vector containing elements from [start] to [start + length - 1].
  ///
  /// Throws [RangeError] if the range is out of bounds.
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
  ///
  /// Example:
  /// ```dart
  /// // Combine two embeddings into one longer vector
  /// final combinedEmbedding = titleEmbedding.concat(bodyEmbedding);
  /// ```
  VectorData concat(VectorData other) {
    final result = List<double>.from(values)..addAll(other.values);
    return VectorData(result);
  }

  /// Truncates a vector to the specified number of dimensions
  ///
  /// Creates a new vector containing only the first [newDimensions] elements.
  ///
  /// Throws [ArgumentError] if newDimensions is greater than the current dimensions.
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
/// This is used with [FieldSchema] when the field type is [DataType.vector].
class VectorFieldConfig {
  /// Dimension of the vector
  ///
  /// Specifies the number of dimensions (length) of the vector.
  /// Common values are 384, 512, 768, 1024, and 1536 (for OpenAI embeddings).
  final int dimensions;

  /// Precision of vector data (bits per dimension)
  ///
  /// Controls how the vector is stored and the precision of calculations.
  /// - [VectorPrecision.float64]: 64-bit double precision (default, highest precision)
  /// - [VectorPrecision.float32]: 32-bit single precision (reduced memory usage)
  /// - [VectorPrecision.int8]: 8-bit integers (quantized, significant memory savings)
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

/// Vector index type for future use
///
/// Specifies the algorithm used for vector indexing and similarity search.
/// Different types offer various trade-offs between build time, query time,
/// memory usage, and accuracy.
enum VectorIndexType {
  /// Flat index (brute force)
  ///
  /// Performs exhaustive search for exact nearest neighbors
  /// Best accuracy but slowest for large datasets
  flat,

  /// Inverted file index
  ///
  /// Uses quantization and inverted file structure for faster search
  /// Good balance of speed and accuracy
  ivf,

  /// Hierarchical navigable small world
  ///
  /// Graph-based index structure for efficient approximate nearest neighbor search
  /// Excellent search speed with high recall
  hnsw,

  /// Product quantization
  ///
  /// Compresses vectors using product quantization for memory-efficient storage
  /// Allows for memory-efficient similarity search
  pq,
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

/// Vector Index Configuration (for future vector search capabilities)
///
/// Configures how vector indexes are built and searched.
/// This is used with [IndexSchema] when the index type is [IndexType.vector].
class VectorIndexConfig {
  /// Type of vector index
  ///
  /// Specifies the algorithm used for indexing vectors
  final VectorIndexType indexType;

  /// Distance metric for similarity search
  ///
  /// Specifies how similarity between vectors is calculated
  final VectorDistanceMetric distanceMetric;

  /// Additional index parameters
  ///
  /// Algorithm-specific parameters to fine-tune the index behavior
  /// Common parameters:
  /// - 'M': (for HNSW) Maximum number of connections per layer
  /// - 'efConstruction': (for HNSW) Controls index build quality
  /// - 'efSearch': (for HNSW) Controls search accuracy/speed trade-off
  /// - 'nlist': (for IVF) Number of clusters/cells
  /// - 'nprobe': (for IVF) Number of cells to visit during search
  final Map<String, dynamic> parameters;

  /// Constructor
  const VectorIndexConfig({
    this.indexType = VectorIndexType.flat,
    this.distanceMetric = VectorDistanceMetric.cosine,
    this.parameters = const {},
  });

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'indexType': indexType.toString().split('.').last,
      'distanceMetric': distanceMetric.toString().split('.').last,
      'parameters': parameters,
    };
  }

  /// Create from JSON
  factory VectorIndexConfig.fromJson(Map<String, dynamic> json) {
    // Parse index type
    VectorIndexType getIndexType() {
      final typeStr = json['indexType'] as String?;
      if (typeStr == null) return VectorIndexType.flat;

      switch (typeStr.toLowerCase()) {
        case 'ivf':
          return VectorIndexType.ivf;
        case 'hnsw':
          return VectorIndexType.hnsw;
        case 'pq':
          return VectorIndexType.pq;
        default:
          return VectorIndexType.flat;
      }
    }

    // Parse distance metric
    VectorDistanceMetric getDistanceMetric() {
      final metricStr = json['distanceMetric'] as String?;
      if (metricStr == null) return VectorDistanceMetric.cosine;

      switch (metricStr.toLowerCase()) {
        case 'l2':
          return VectorDistanceMetric.l2;
        case 'innerproduct':
          return VectorDistanceMetric.innerProduct;
        default:
          return VectorDistanceMetric.cosine;
      }
    }

    return VectorIndexConfig(
      indexType: getIndexType(),
      distanceMetric: getDistanceMetric(),
      parameters: json['parameters'] as Map<String, dynamic>? ?? {},
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
