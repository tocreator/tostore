/// 表结构定义
class TableSchema {
  final String primaryKey; // 主键
  final bool autoIncrement; // 是否启用自增
  final List<FieldSchema> fields; // 字段列表
  final List<IndexSchema> indexes; // 索引
  final bool isGlobal; // 是否为全局表

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

  /// 验证数据是否符合表结构
  bool validateData(Map<String, dynamic> data) {
    // 检查必填字段
    for (var field in fields) {
      if (!field.nullable && !data.containsKey(field.name)) {
        return false;
      }
    }

    // 检查数据类型
    for (var entry in data.entries) {
      final field = fields.firstWhere(
        (col) => col.name == entry.key,
        orElse: () => throw StateError('Unknown field ${entry.key}'),
      );

      if (!_isValidDataType(entry.value, field.type)) {
        return false;
      }

      // 检查字符串长度
      if (field.maxLength != null &&
          entry.value is String &&
          (entry.value as String).length > field.maxLength!) {
        return false;
      }
    }

    return true;
  }

  /// 检查数据类型是否匹配
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
      default:
        return false;
    }
  }
}

/// 字段定义
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

/// 索引定义
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

  /// 获取实际的索引名称
  String get actualIndexName {
    final prefix = unique ? 'uniq_' : 'idx_';
    // 统一前缀
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

/// 数据类型枚举
enum DataType {
  integer,
  double,
  text,
  blob,
  boolean,
  datetime,
}

/// 索引类型
enum IndexType {
  btree, // 默认,B树索引
  hash, // 哈希索引
  bitmap, // 位图索引
}
