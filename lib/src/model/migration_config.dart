/// Migration configuration
class MigrationConfig {
  /// Whether to backup data before migration
  final bool backupBeforeMigrate;

  /// Whether to validate data after migration
  final bool validateAfterMigrate;

  /// Batch size for processing records
  final int batchSize;

  /// Whether to throw error on validation failure
  final bool strictMode;

  const MigrationConfig({
    this.backupBeforeMigrate = false,
    this.validateAfterMigrate = true,
    this.batchSize = 1000,
    this.strictMode = false,
  });

  /// Create from json
  factory MigrationConfig.fromJson(Map<String, dynamic> json) {
    return MigrationConfig(
      backupBeforeMigrate: json['backupBeforeMigrate'] as bool? ?? true,
      validateAfterMigrate: json['validateAfterMigrate'] as bool? ?? true,
      batchSize: json['batchSize'] as int? ?? 1000,
      strictMode: json['strictMode'] as bool? ?? false,
    );
  }

  /// Convert to json
  Map<String, dynamic> toJson() {
    return {
      'backupBeforeMigrate': backupBeforeMigrate,
      'validateAfterMigrate': validateAfterMigrate,
      'batchSize': batchSize,
      'strictMode': strictMode,
    };
  }

  /// Create new instance with some fields replaced
  MigrationConfig copyWith({
    bool? backupBeforeMigrate,
    bool? validateAfterMigrate,
    int? batchSize,
    bool? strictMode,
  }) {
    return MigrationConfig(
      backupBeforeMigrate: backupBeforeMigrate ?? this.backupBeforeMigrate,
      validateAfterMigrate: validateAfterMigrate ?? this.validateAfterMigrate,
      batchSize: batchSize ?? this.batchSize,
      strictMode: strictMode ?? this.strictMode,
    );
  }
}
