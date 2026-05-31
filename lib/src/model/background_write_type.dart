/// Type of background write operation.
enum BackgroundWriteType {
  /// Schema alteration or migration task.
  schemaMigration,

  /// Data migration due to encryption key changes.
  keyMigration,

  /// Large volume data delete operation.
  largeDelete,

  /// Large volume data update operation.
  largeUpdate,
}
