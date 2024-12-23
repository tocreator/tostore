/// table schema
class TableSchema {
  final String primaryKey; // primary key
  final bool autoIncrement; // auto increment
  final List<FieldSchema> fields; // fields
  final List<IndexSchema> indexes; // indexes
  final bool isGlobal; // is global table

  const TableSchema({
    required this.primaryKey,
    this.autoIncrement = true,
    required this.fields,
    this.indexes = const [],
    this.isGlobal = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'primaryKey': primaryKey,
      'autoIncrement': autoIncrement,
      'fields': fields.map((c) => c.toJson()).toList(),
      'indexes': indexes.map((i) => i.toJson()).toList(),
      'isGlobal': isGlobal,
    };
  }

  factory TableSchema.fromJson(Map<String, dynamic> json) {
    return TableSchema(
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
    }
  }
}

/// field schema
class FieldSchema {
  final String name;
  final DataType type;
  final bool nullable;
  final dynamic defaultValue;
  final int? maxLength;
  final bool unique;

  const FieldSchema({
    required this.name,
    required this.type,
    this.nullable = true,
    this.defaultValue,
    this.maxLength,
    this.unique = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type.toString(),
      'nullable': nullable,
      'defaultValue': defaultValue,
      'maxLength': maxLength,
      'unique': unique,
    };
  }

  factory FieldSchema.fromJson(Map<String, dynamic> json) {
    return FieldSchema(
      name: json['name'] as String,
      type: DataType.values.firstWhere(
        (e) => e.toString() == json['type'],
      ),
      nullable: json['nullable'] as bool? ?? true,
      defaultValue: json['defaultValue'],
      maxLength: json['maxLength'] as int?,
      unique: json['unique'] as bool? ?? false,
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
}

/// data type enum
enum DataType {
  integer,
  double,
  text,
  blob,
  boolean,
  datetime,
}

/// index type enum
enum IndexType {
  btree, // default, btree index
  hash, // hash index
  bitmap, // bitmap index
}
