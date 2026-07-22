/// Weight type enum
enum WeightType {
  /// Table record weight
  tableRecord,

  /// Index data weight
  indexData,
}

/// Weight data model
class WeightData {
  /// Weight value (0-100)
  final int weight;

  /// Access count
  final int accessCount;

  /// Last update time
  final int lastUpdateTime;

  /// Whether to never decay
  final bool neverDecay;

  /// Custom weight (if set, use this value instead of calculated value)
  final int? customWeight;

  WeightData({
    this.weight = 0,
    this.accessCount = 0,
    required this.lastUpdateTime,
    this.neverDecay = false,
    this.customWeight,
  });

  WeightData copyWith({
    int? weight,
    int? accessCount,
    int? lastUpdateTime,
    bool? neverDecay,
    int? customWeight,
  }) =>
      WeightData(
        weight: weight ?? this.weight,
        accessCount: accessCount ?? this.accessCount,
        lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
        neverDecay: neverDecay ?? this.neverDecay,
        customWeight: customWeight ?? this.customWeight,
      );
}
