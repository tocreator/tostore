import '../model/data_store_config.dart';
import '../handler/common.dart';
import 'data_store_impl.dart';
import '../model/file_info.dart';

/// path manager
/// responsible for all file path related operations, including table paths, index paths, data paths, etc.
class PathManager {
  final DataStoreImpl dataStore;
  DataStoreConfig get config => dataStore.config;

  // table path cache
  final Map<String, String> _tablePathCache = {};

  PathManager(this.dataStore);

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

  String get _instancePath => dataStore.instancePath!;
  String get _currentSpaceName => dataStore.currentSpaceName;

  /// get space directory path
  String getSpacePath({String? spaceName}) {
    return pathJoin(_instancePath, 'spaces', spaceName ?? _currentSpaceName);
  }

  /// get global table directory path
  String getGlobalPath() {
    return pathJoin(_instancePath, 'global');
  }

  /// get schemas directory path (at root level)
  String getSchemasPath() {
    return pathJoin(_instancePath, 'schemas');
  }

  /// get backup directory path
  String getBackupPath() {
    return pathJoin(_instancePath, 'backups');
  }

  /// get log directory path
  String getLogPath() {
    return pathJoin(_instancePath, 'logs');
  }

  /// get migrations directory path
  String getMigrationsPath() {
    return pathJoin(_instancePath, 'migrations');
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
    return pathJoin(_instancePath, 'global_config.json');
  }

  /// get space config path
  String getSpaceConfigPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return pathJoin(spacePath, 'space_config.json');
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

  //==================================
  // WAL path methods (sync methods)
  //==================================

  /// get WAL root path for a space
  String getWalRootPath() {
    return pathJoin(getSpacePath(), 'wal');
  }

  /// get main WAL meta file path
  String getMainWalMetaPath() {
    return pathJoin(getWalRootPath(), 'wal_meta.json');
  }

  /// get table WAL root path
  Future<String> getTableWalRootPath(String tableName) async {
    final tablePath = await getTablePath(tableName);
    return pathJoin(tablePath, 'wal');
  }

  /// get table WAL meta file path
  Future<String> getTableWalMetaPath(String tableName) async {
    final walRootPath = await getTableWalRootPath(tableName);
    return pathJoin(walRootPath, 'wal_meta.json');
  }

  /// get table WAL partition directory path
  Future<String> getTableWalPartitionsDirPath(String tableName) async {
    final walRootPath = await getTableWalRootPath(tableName);
    return pathJoin(walRootPath, 'partitions');
  }

  /// get table WAL partition directory path
  Future<String> getTableWalPartitionDirPath(
      String tableName, int partitionIndex) async {
    final walRootPath = await getTableWalPartitionsDirPath(tableName);
    final dirIndex = partitionIndex ~/ config.maxEntriesPerDir;
    return pathJoin(walRootPath, 'dir_$dirIndex');
  }

  /// get table WAL partition file path
  Future<String> getTableWalPartitionPath(
      String tableName, int partitionIndex) async {
    final dirPath =
        await getTableWalPartitionDirPath(tableName, partitionIndex);
    return pathJoin(dirPath, 'wal_$partitionIndex.log');
  }

  //==================================
  // cache path methods (sync methods)
  //==================================

  /// get cache root path
  String getCacheRootPath() {
    return pathJoin(_instancePath, 'caches');
  }

  /// get global cache path
  String getGlobalCachePath() {
    return pathJoin(getCacheRootPath(), 'global');
  }

  /// get spaces cache root path
  String getSpacesCachePath() {
    return pathJoin(getCacheRootPath(), 'spaces');
  }
}
