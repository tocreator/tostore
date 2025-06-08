import '../model/data_store_config.dart';
import '../handler/common.dart';
import 'data_store_impl.dart';
import '../model/file_info.dart';

/// path manager
/// responsible for all file path related operations, including table paths, index paths, data paths, etc.
class PathManager {
  final DataStoreImpl dataStore;
  final DataStoreConfig config;

  // table path cache
  final Map<String, String> _tablePathCache = {};

  PathManager(this.dataStore) : config = dataStore.config;

  /// clear all cache
  void clearCache() {
    _tablePathCache.clear();
  }

  /// clear specific table cache
  void clearTableCache(String tableName) {
    _tablePathCache.remove(tableName);
  }

  //==================================
  // base path methods (sync methods)
  //==================================

  /// get space directory path
  String getSpacePath() {
    return pathJoin(config.dbPath!, 'spaces', config.spaceName);
  }

  /// get global table directory path
  String getGlobalPath() {
    return pathJoin(config.dbPath!, 'global');
  }

  /// get schemas directory path (at root level)
  String getSchemasPath() {
    return pathJoin(config.dbPath!, 'schemas');
  }

  /// get backup directory path
  String getBackupPath() {
    return pathJoin(config.dbPath!, 'backups');
  }

  /// get log directory path
  String getLogPath() {
    return pathJoin(config.dbPath!, 'logs');
  }

  /// get migrations directory path
  String getMigrationsPath() {
    return pathJoin(config.dbPath!, 'migrations');
  }

  /// get migration meta file path (migration metadata)
  String getMigrationMetaPath() {
    return pathJoin(getMigrationsPath(), 'migration_meta.json');
  }

  /// get migration task file path
  String getMigrationTaskPath(int dirIndex, String taskId) {
    return pathJoin(getMigrationsPath(), 'dir_$dirIndex', 'task_$taskId.json');
  }

  /// get global config file path
  String getGlobalConfigPath() {
    return pathJoin(config.dbPath!, 'global_config.json');
  }

  /// get space config path
  String getSpaceConfigPath(String spaceName) {
    return pathJoin(config.dbPath!, 'spaces', spaceName, 'space_config.json');
  }

  /// get schema meta file path (database schema metadata)
  String getSchemaMetaPath() {
    return pathJoin(getSchemasPath(), 'schema_meta.${FileType.schema.ext}');
  }

  /// get schema partition file path
  String getSchemaPartitionFilePath(int partitionIndex) {
    final dirPath = getSchemaPartitionDirPath(partitionIndex);
    return pathJoin(dirPath, 'schema_p$partitionIndex.${FileType.schema.ext}');
  }

  /// get schema partition directory path based on partition index
  String getSchemaPartitionDirPath(int partitionIndex) {
    final dirIndex = partitionIndex ~/ config.maxEntriesPerDir;
    return pathJoin(getSchemasPath(), 'dir_$dirIndex');
  }

  //==================================
  // table path methods (async methods)
  //==================================

  /// get table path
  Future<String> getTablePath(String tableName) async {
    // check cache
    if (_tablePathCache.containsKey(tableName)) {
      return _tablePathCache[tableName]!;
    }

    // get table directory info using DirectoryManager
    final tablePath =
        await dataStore.directoryManager?.getTablePathIfExists(tableName);
    if (tablePath == null) {
      throw StateError(
          'Table $tableName does not exist or path cannot be determined');
    }

    // update cache
    _tablePathCache[tableName] = tablePath;

    return tablePath;
  }

  /// create table path for new table
  Future<String> createTablePath(String tableName, bool isGlobal) async {
    // get table path
    final tablePath = await dataStore.directoryManager
        ?.createTablePathIfNotExists(tableName, isGlobal);

    if (tablePath == null) {
      throw StateError('Failed to create path for table $tableName');
    }

    // update cache
    _tablePathCache[tableName] = tablePath;

    return tablePath;
  }

  /// get table data directory path
  Future<String> getDataDirPath(String tableName) async {
    final tablePath = await getTablePath(tableName);
    return pathJoin(tablePath, 'data');
  }

  /// get data meta file path
  Future<String> getDataMetaPath(String tableName) async {
    final dataPath = await getDataDirPath(tableName);
    return pathJoin(dataPath, 'main.${FileType.data.ext}');
  }

  /// get partition directory path
  Future<String> getPartitionsDirPath(String tableName) async {
    final dataPath = await getDataDirPath(tableName);
    return pathJoin(dataPath, 'partitions');
  }

  /// get partition directory path
  Future<String> getPartitionDirPath(
      String tableName, int partitionIndex) async {
    final partitionsPath = await getPartitionsDirPath(tableName);
    final dirIndex = partitionIndex ~/ config.maxEntriesPerDir;
    return pathJoin(partitionsPath, 'dir_$dirIndex');
  }

  /// get partition file path
  Future<String> getPartitionFilePath(
      String tableName, int partitionIndex) async {
    final dirPath = await getPartitionDirPath(tableName, partitionIndex);
    return pathJoin(dirPath, 'p$partitionIndex.${FileType.data.ext}');
  }

  /// get table index directory path
  Future<String> getIndexDirPath(String tableName) async {
    final tablePath = await getTablePath(tableName);
    return pathJoin(tablePath, 'index');
  }

  /// get index meta file path
  Future<String> getIndexMetaPath(String tableName, String indexName) async {
    final indexPath = await getIndexDirPath(tableName);
    return pathJoin(indexPath, indexName, '$indexName.meta.json');
  }

  /// get index partition directory path
  Future<String> getIndexPartitionDirPath(
      String tableName, String indexName, int partitionIndex) async {
    final indexPath = await getIndexDirPath(tableName);
    final dirIndex = partitionIndex ~/ config.maxEntriesPerDir;
    return pathJoin(indexPath, indexName, 'partitions', 'dir_$dirIndex');
  }

  /// get index partition file path
  Future<String> getIndexPartitionPath(
      String tableName, String indexName, int partitionIndex) async {
    final dirPath =
        await getIndexPartitionDirPath(tableName, indexName, partitionIndex);
    return pathJoin(
        dirPath, '${indexName}_p$partitionIndex.${FileType.idx.ext}');
  }

  /// get auto increment id file path
  Future<String> getAutoIncrementPath(String tableName) async {
    final tablePath = await getTablePath(tableName);
    return pathJoin(tablePath, 'maxid.txt');
  }

  /// get stats file path
  Future<String> getStatsPath(String tableName) async {
    final tablePath = await getTablePath(tableName);
    return pathJoin(tablePath, 'stats.json');
  }

  /// get transaction log file path
  Future<String> getTransactionLogPath(String tableName) async {
    final tablePath = await getTablePath(tableName);
    return pathJoin(tablePath, 'transaction.log');
  }

  //==================================
  // cache path methods (sync methods)
  //==================================

  /// get cache root path
  String getCacheRootPath() {
    return pathJoin(config.dbPath!, 'caches');
  }

  /// get global cache path
  String getGlobalCachePath() {
    return pathJoin(getCacheRootPath(), 'global');
  }

  /// get spaces cache root path
  String getSpacesCachePath() {
    return pathJoin(getCacheRootPath(), 'spaces');
  }

  /// get current space cache path
  String getCurrentSpaceCachePath() {
    return pathJoin(getSpacesCachePath(), config.spaceName);
  }

  /// get space cache path
  String getSpaceCachePath(String spaceName) {
    return pathJoin(getSpacesCachePath(), spaceName);
  }

  /// get query cache path
  String getQueryCachePath() {
    return pathJoin(getCurrentSpaceCachePath(), 'queries');
  }

  /// get stats cache path
  String getStatsCachePath() {
    return pathJoin(getCurrentSpaceCachePath(), 'stats');
  }

  /// get startup cache path
  String getStartupCachePath() {
    return pathJoin(getCurrentSpaceCachePath(), 'startup');
  }

  /// get global startup cache path
  String getGlobalStartupCachePath() {
    return pathJoin(getGlobalCachePath(), 'startup');
  }

  /// get startup cache file pathp cache file path
  String getStartupCacheFilePath() {
    return pathJoin(getStartupCachePath(), 'startup_cache.bin');
  }

  /// get global startup cache file path
  String getGlobalStartupCacheFilePath() {
    return pathJoin(getGlobalStartupCachePath(), 'global_startup_cache.bin');
  }

  /// get write buffer directory path
  String getWriteBufferDirPath() {
    return pathJoin(getSpacePath(), 'write_queue');
  }

  /// get write buffer backup path
  String getWriteBufferBackupPath() {
    return pathJoin(getWriteBufferDirPath(), 'write_queue_backup.bak');
  }
}
