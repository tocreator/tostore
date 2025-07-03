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

  /// list of table names that are allowed to perform data migration without explicit confirmation
  final List<String> allowedAfterDataMigrationTables;

  const MigrationConfig({
    this.backupBeforeMigrate = false,
    this.validateAfterMigrate = true,
    this.batchSize = 1000,
    this.strictMode = false,
    this.allowedAfterDataMigrationTables = const [],
  });

  /// Create from json
  factory MigrationConfig.fromJson(Map<String, dynamic> json) {
    return MigrationConfig(
      backupBeforeMigrate: json['backupBeforeMigrate'] as bool? ?? true,
      validateAfterMigrate: json['validateAfterMigrate'] as bool? ?? true,
      batchSize: json['batchSize'] as int? ?? 1000,
      strictMode: json['strictMode'] as bool? ?? false,
      allowedAfterDataMigrationTables:
          (json['allowedAfterDataMigrationTables'] as List?)?.cast<String>() ??
              const [],
    );
  }

  /// Convert to json
  Map<String, dynamic> toJson() {
    return {
      'backupBeforeMigrate': backupBeforeMigrate,
      'validateAfterMigrate': validateAfterMigrate,
      'batchSize': batchSize,
      'strictMode': strictMode,
      'allowedAfterDataMigrationTables': allowedAfterDataMigrationTables,
    };
  }

  /// Create new instance with some fields replaced
  MigrationConfig copyWith({
    bool? backupBeforeMigrate,
    bool? validateAfterMigrate,
    int? batchSize,
    bool? strictMode,
    List<String>? allowedAfterDataMigrationTables,
  }) {
    return MigrationConfig(
      backupBeforeMigrate: backupBeforeMigrate ?? this.backupBeforeMigrate,
      validateAfterMigrate: validateAfterMigrate ?? this.validateAfterMigrate,
      batchSize: batchSize ?? this.batchSize,
      strictMode: strictMode ?? this.strictMode,
      allowedAfterDataMigrationTables: allowedAfterDataMigrationTables ??
          this.allowedAfterDataMigrationTables,
    );
  }
}
