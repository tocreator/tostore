/// Information about the current effective configuration of the database
class ConfigInfo {
  /// Root database path
  final String dbPath;

  /// Database name
  final String dbName;

  /// Absolute path to the database instance directory
  final String instancePath;

  /// Current space name
  final String currentSpaceName;

  /// Current business version (set by the developer via setVersion)
  final int userVersion;

  /// Internal engine/storage format version
  final int engineVersion;

  /// Whether write-ahead logging (WAL) is enabled
  final bool isJournalEnabled;

  /// Effective encryption type (none, xor, chacha20, aes256)
  final String encryptionType;

  /// Whether data encryption is currently active
  final bool isEncryptionEnabled;

  /// Memory budget for all caches (MB)
  final int cacheMemoryBudgetMB;

  /// Whether memory manager is initialized
  final bool isMemoryManaged;

  /// Maximum number of parallel workers (isolates)
  final int maxParallelWorkers;

  /// Current storage flush policy (adaptive, low, medium, high, off)
  final String flushPolicy;

  const ConfigInfo({
    required this.dbPath,
    required this.dbName,
    required this.instancePath,
    required this.currentSpaceName,
    required this.userVersion,
    required this.engineVersion,
    required this.isJournalEnabled,
    required this.encryptionType,
    required this.isEncryptionEnabled,
    required this.cacheMemoryBudgetMB,
    required this.isMemoryManaged,
    required this.maxParallelWorkers,
    required this.flushPolicy,
  });

  Map<String, dynamic> toJson() {
    return {
      'dbPath': dbPath,
      'dbName': dbName,
      'instancePath': instancePath,
      'currentSpaceName': currentSpaceName,
      'userVersion': userVersion,
      'engineVersion': engineVersion,
      'isJournalEnabled': isJournalEnabled,
      'encryptionType': encryptionType,
      'isEncryptionEnabled': isEncryptionEnabled,
      'cacheMemoryBudgetMB': cacheMemoryBudgetMB,
      'isMemoryManaged': isMemoryManaged,
      'maxParallelWorkers': maxParallelWorkers,
      'flushPolicy': flushPolicy,
    };
  }
}
