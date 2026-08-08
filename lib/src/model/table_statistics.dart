/// table statistics
class TableStatistics {
  final Map<String, FieldStatistics> fieldStats;
  final int totalRecordCount;

  TableStatistics({
    required this.fieldStats,
    required this.totalRecordCount,
  });

  /// from json
  factory TableStatistics.fromJson(Map<String, dynamic> json) {
    return TableStatistics(
      fieldStats: (json['fieldStats'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, FieldStatistics.fromJson(value)),
      ),
      totalRecordCount: (json['totalRecordCount'] as int?) ??
          (json['totalRows'] as int? ?? 0),
    );
  }

  /// to json
  Map<String, dynamic> toJson() {
    return {
      'fieldStats': fieldStats.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'totalRecordCount': totalRecordCount,
    };
  }
}

/// field statistics
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

  /// from json
  factory FieldStatistics.fromJson(Map<String, dynamic> json) {
    return FieldStatistics(
      distinctValues: json['distinctValues'] as int,
      minValue: json['minValue'],
      maxValue: json['maxValue'],
      nullPercentage: json['nullPercentage'] as double,
    );
  }

  /// to json
  Map<String, dynamic> toJson() {
    return {
      'distinctValues': distinctValues,
      'minValue': minValue,
      'maxValue': maxValue,
      'nullPercentage': nullPercentage,
    };
  }
}
