/// 表统计信息
class TableStatistics {
  final Map<String, FieldStatistics> fieldStats;
  final int totalRows;

  TableStatistics({
    required this.fieldStats,
    required this.totalRows,
  });

  /// 从 JSON 创建
  factory TableStatistics.fromJson(Map<String, dynamic> json) {
    return TableStatistics(
      fieldStats: (json['fieldStats'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, FieldStatistics.fromJson(value)),
      ),
      totalRows: json['totalRows'] as int,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'fieldStats': fieldStats.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'totalRows': totalRows,
    };
  }
}

/// 字段统计信息
class FieldStatistics {
  final int distinctValues;
  final dynamic minValue;
  final dynamic maxValue;
  final double nullPercentage;

  FieldStatistics({
    required this.distinctValues,
    required this.minValue,
    required this.maxValue,
    required this.nullPercentage,
  });

  /// 从 JSON 创建
  factory FieldStatistics.fromJson(Map<String, dynamic> json) {
    return FieldStatistics(
      distinctValues: json['distinctValues'] as int,
      minValue: json['minValue'],
      maxValue: json['maxValue'],
      nullPercentage: json['nullPercentage'] as double,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'distinctValues': distinctValues,
      'minValue': minValue,
      'maxValue': maxValue,
      'nullPercentage': nullPercentage,
    };
  }
}
