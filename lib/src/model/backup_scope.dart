/// Backup scope selector for database backups
/// - database: backup entire database instance (all spaces, globals, schemas, etc.)
/// - currentSpace: backup only current space data (exclude global tables)
/// - currentSpaceWithGlobal: backup current space data plus global tables
enum BackupScope {
  database,
  currentSpace,
  currentSpaceWithGlobal,
}
