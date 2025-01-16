import 'dart:typed_data';
import 'dart:io';

import 'business_error.dart';

/// table schema
class TableSchema {
  final String name; // table name
  final String primaryKey; // primary key
  final bool autoIncrement; // auto increment
  final List<FieldSchema> fields; // fields
  final List<IndexSchema> indexes; // indexes
  final bool isGlobal; // is global table

  const TableSchema({
    required this.name,
    required this.primaryKey,
    this.autoIncrement = true,
    required this.fields,
    this.indexes = const [],
    this.isGlobal = false,
  });

  TableSchema copyWith({
    String? name,
    String? primaryKey,
    bool? autoIncrement,
    List<FieldSchema>? fields,
    List<IndexSchema>? indexes,
    bool? isGlobal,
  }) {
    return TableSchema(
      name: name ?? this.name,
      primaryKey: primaryKey ?? this.primaryKey,
      autoIncrement: autoIncrement ?? this.autoIncrement,
      fields: fields ?? this.fields,
      indexes: indexes ?? this.indexes,
      isGlobal: isGlobal ?? this.isGlobal,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'primaryKey': primaryKey,
      'autoIncrement': autoIncrement,
      'fields': fields.map((c) => c.toJson()).toList(),
      'indexes': indexes.map((i) => i.toJson()).toList(),
      'isGlobal': isGlobal,
    };
  }

  factory TableSchema.fromJson(Map<String, dynamic> json) {
    String tableName;
    if (json.containsKey('name')) {
      tableName = json['name'] as String;
    } else {
      final schemaPath = json['_schemaPath'] as String?;
      if (schemaPath != null) {
        final fileName = schemaPath.split(Platform.pathSeparator).last;
        tableName = fileName.replaceAll('.schema', '');
      } else {
        throw const BusinessError(
          'Cannot determine table name from schema',
          type: BusinessErrorType.schemaError,
        );
      }
    }

    return TableSchema(
      name: tableName,
      primaryKey: json['primaryKey'] as String,
      autoIncrement: json['autoIncrement'] as bool? ?? true,
      fields: (json['fields'] as List)
          .map((c) => FieldSchema.fromJson(c as Map<String, dynamic>))
          .toList(),
      indexes: (json['indexes'] as List?)
              ?.map((i) => IndexSchema.fromJson(i as Map<String, dynamic>))
              .toList() ??
          [],
      isGlobal: json['isGlobal'] as bool? ?? false,
    );
  }

  /// validate data against table schema
  bool validateData(Map<String, dynamic> data) {
    // check required fields
    for (var field in fields) {
      if (!field.nullable && !data.containsKey(field.name)) {
        return false;
      }
    }

    // check data type
    for (var entry in data.entries) {
      final field = fields.firstWhere(
        (col) => col.name == entry.key,
        orElse: () => throw StateError('Unknown field ${entry.key}'),
      );

      if (!_isValidDataType(entry.value, field.type)) {
        return false;
      }

      // check string length
      if (field.maxLength != null &&
          entry.value is String &&
          (entry.value as String).length > field.maxLength!) {
        return false;
      }
    }

    return true;
  }

  /// check data type is valid
  bool _isValidDataType(dynamic value, DataType type) {
    if (value == null) return true;
    switch (type) {
      case DataType.integer:
        return value is int;
      case DataType.double:
        return value is double;
      case DataType.text:
        return value is String;
      case DataType.blob:
        return value is List<int>;
      case DataType.boolean:
        return value is bool;
      case DataType.datetime:
        return value is String && DateTime.tryParse(value) != null;
      case DataType.array:
        return value is List;
    }
  }

  /// get default value for a field
  dynamic getDefaultValue(String fieldName) {
    final field = fields.firstWhere(
      (f) => f.name == fieldName,
      orElse: () => throw StateError('Unknown field $fieldName'),
    );
    return field.defaultValue ?? _getTypeDefaultValue(field.type);
  }

  /// get default value for a data type
  dynamic _getTypeDefaultValue(DataType type) {
    switch (type) {
      case DataType.integer:
        return 0;
      case DataType.double:
        return 0.0;
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
}

/// field schema
class FieldSchema {
  static const _unsetValue = Object();

  final String name;
  final DataType type;
  final bool nullable;
  final dynamic defaultValue;
  final bool unique;
  final String? comment;
  final int? maxLength;

  const FieldSchema({
    required this.name,
    required this.type,
    this.nullable = true,
    this.defaultValue,
    this.unique = false,
    this.comment,
    this.maxLength,
  });

  /// Create copy with modifications
  FieldSchema copyWith({
    String? name,
    DataType? type,
    bool? nullable,
    dynamic defaultValue = _unsetValue,
    bool? unique,
    String? comment,
    int? maxLength,
  }) {
    return FieldSchema(
      name: name ?? this.name,
      type: type ?? this.type,
      nullable: nullable ?? this.nullable,
      defaultValue:
          defaultValue == _unsetValue ? this.defaultValue : defaultValue,
      unique: unique ?? this.unique,
      comment: comment ?? this.comment,
      maxLength: maxLength ?? this.maxLength,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type.toString(),
      'nullable': nullable,
      'defaultValue': defaultValue,
      'maxLength': maxLength,
      'unique': unique,
      'comment': comment,
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
      comment: json['comment'] as String?,
      maxLength: json['maxLength'] as int?,
    );
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
  integer,
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
