/// Write mode defining which target storage components are rewritten during migration.
enum MigrationWriteMode {
  /// Only write index data.
  indexOnly,

  /// Only write table raw data.
  tableOnly,

  /// Write both table raw data and index data.
  tableAndIndex,

  /// No physical write operations (neither table raw data nor index data).
  none,
}
