import '../model/data_store_config.dart';
import '../handler/common.dart';
import 'data_store_impl.dart';
import '../model/meta_info.dart';

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
  /// If [rootPath] is provided, build path from that root; otherwise use instance path
  String getSpacePath({String? rootPath, String? spaceName}) {
    final String baseRoot = rootPath ?? _instancePath;
    return pathJoin(baseRoot, 'spaces', spaceName ?? _currentSpaceName);
  }

  /// get global table directory path
  /// If [rootPath] is provided, build path from that root; otherwise use instance path
  String getGlobalPath({String? rootPath}) {
    final String baseRoot = rootPath ?? _instancePath;
    return pathJoin(baseRoot, 'global');
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
  /// If [rootPath] is provided, build path from that root; otherwise use instance path
  String getSpaceConfigPath({String? rootPath, String? spaceName}) {
    final spacePath = getSpacePath(rootPath: rootPath, spaceName: spaceName);
    return pathJoin(spacePath, 'space_config.json');
  }

  /// Get weight file path
  String getWeightFilePath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return pathJoin(spacePath, 'cache_weights.json');
  }

  /// get temp directory path under current space
  /// All crash-safe temporary files are placed here to ensure same filesystem/volume.
  String getTempDirPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return pathJoin(spacePath, 'tmp');
  }

  /// get schema meta file path (database schema metadata)
  String getSchemaMetaPath() {
    return pathJoin(getSchemasPath(), 'schema_meta.${FileType.schema.ext}');
  }

  /// get schema partition file path
  String getSchemaPartitionFilePath(int partitionIndex, int dirIndex) {
    final dirPath = getSchemaPartitionDirPath(dirIndex);
    return pathJoin(dirPath, 'schema_p$partitionIndex.${FileType.schema.ext}');
  }

  /// get schema partition directory path
  String getSchemaPartitionDirPath(int dirIndex) {
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

  /// get table data root directory path
  Future<String> getDataDirPath(String tableName) async {
    final tablePath = await getTablePath(tableName);
    return pathJoin(tablePath, 'data');
  }

  /// get table data main meta file path
  Future<String> getDataMetaPath(String tableName) async {
    final dataPath = await getDataDirPath(tableName);
    return pathJoin(dataPath, 'meta.json');
  }

  /// get table data btree partitions directory path
  Future<String> getPartitionsDirPath(String tableName) async {
    final dataPath = await getDataDirPath(tableName);
    return pathJoin(dataPath, 'btree');
  }

  /// Get table overflow (TOAST-like) directory path.
  ///
  /// This directory stores out-of-line large values referenced by pointers in the
  /// primary B+Tree. We keep it separated from `btree/` so future format evolution
  /// (heap pages / slotted pages / compression) can be isolated.
  Future<String> getOverflowDirPath(String tableName) async {
    final dataPath = await getDataDirPath(tableName);
    return pathJoin(dataPath, 'overflow');
  }

  /// Get overflow partition file path by partitionNo.
  ///
  /// Deterministic sharding:
  /// `dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir`
  Future<String> getOverflowPartitionFilePathByNo(
      String tableName, int partitionNo) async {
    final overflowDir = await getOverflowDirPath(tableName);
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dirPath = pathJoin(overflowDir, 'dir_$dirIndex');
    return pathJoin(dirPath, 'p$partitionNo.dat');
  }

  /// get table data partition directory path
  Future<String> getPartitionDirPath(String tableName, int dirIndex) async {
    final partitionsPath = await getPartitionsDirPath(tableName);
    return pathJoin(partitionsPath, 'dir_$dirIndex');
  }

  /// Get table B+Tree partition file path by partitionNo (new layout).
  ///
  /// Deterministic sharding:
  /// `dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir`
  Future<String> getPartitionFilePathByNo(
      String tableName, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dirPath = await getPartitionDirPath(tableName, dirIndex);
    return pathJoin(dirPath, 'p$partitionNo.dat');
  }

  /// get table index directory path
  Future<String> getIndexDirPath(String tableName) async {
    final tablePath = await getTablePath(tableName);
    return pathJoin(tablePath, 'index');
  }

  /// get index root directory path
  Future<String> getIndexPath(String tableName, String indexName) async {
    final indexDirPath = await getIndexDirPath(tableName);
    return pathJoin(indexDirPath, indexName);
  }

  /// get index meta file path
  Future<String> getIndexMetaPath(String tableName, String indexName) async {
    final indexPath = await getIndexPath(tableName, indexName);
    return pathJoin(indexPath, 'meta.json');
  }

  /// get index btree partition directory path
  Future<String> getIndexPartitionDirPath(
      String tableName, String indexName, int dirIndex) async {
    final indexPath = await getIndexPath(tableName, indexName);
    return pathJoin(indexPath, 'btree', 'dir_$dirIndex');
  }

  /// Get index B+Tree partition file path by partitionNo (new layout).
  Future<String> getIndexPartitionPathByNo(
      String tableName, String indexName, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dirPath =
        await getIndexPartitionDirPath(tableName, indexName, dirIndex);
    return pathJoin(dirPath, 'p$partitionNo.idx');
  }

  /// get stats file path
  Future<String> getStatsPath(String tableName) async {
    final tablePath = await getTablePath(tableName);
    return pathJoin(tablePath, 'stats.json');
  }

  // ==================================
  // NGH vector index path methods
  // ==================================

  /// Root path for an NGH vector index.
  Future<String> getNghIndexPath(String tableName, String indexName) async {
    final indexPath = await getIndexPath(tableName, indexName);
    return pathJoin(indexPath, 'ngh');
  }

  /// NGH index metadata file.
  Future<String> getNghMetaPath(String tableName, String indexName) async {
    final nghPath = await getNghIndexPath(tableName, indexName);
    return pathJoin(nghPath, 'meta.json');
  }

  /// NGH PQ codebook file.
  Future<String> getNghCodebookPath(String tableName, String indexName) async {
    final nghPath = await getNghIndexPath(tableName, indexName);
    return pathJoin(nghPath, 'codebook.ngh');
  }

  /// NGH graph partition directory path.
  Future<String> _nghPartitionDirPath(
      String tableName, String indexName, String category, int dirIndex) async {
    final nghPath = await getNghIndexPath(tableName, indexName);
    return pathJoin(nghPath, category, 'dir_$dirIndex');
  }

  /// NGH graph partition file path by partitionNo.
  Future<String> getNghGraphPartitionPath(
      String tableName, String indexName, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dir =
        await _nghPartitionDirPath(tableName, indexName, 'graph', dirIndex);
    return pathJoin(dir, 'p$partitionNo.ngh');
  }

  /// NGH PQ-code partition file path by partitionNo.
  Future<String> getNghPqCodePartitionPath(
      String tableName, String indexName, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dir =
        await _nghPartitionDirPath(tableName, indexName, 'pqcode', dirIndex);
    return pathJoin(dir, 'p$partitionNo.ngh');
  }

  /// NGH raw-vector partition file path by partitionNo.
  Future<String> getNghRawVectorPartitionPath(
      String tableName, String indexName, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dir =
        await _nghPartitionDirPath(tableName, indexName, 'rawvec', dirIndex);
    return pathJoin(dir, 'p$partitionNo.ngh');
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

  //==================================
  // Transaction path methods
  //==================================

  /// transaction root path in current space
  String getTransactionRootPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return pathJoin(spacePath, 'transactions');
  }

  /// transaction main meta file path (track active partitions, next index, etc.)
  String getTransactionMainMetaPath({String? spaceName}) {
    return pathJoin(getTransactionRootPath(spaceName: spaceName), 'meta.json');
  }

  /// transaction directory path by directory shard
  String getTransactionDirShardPath(int dirIndex, {String? spaceName}) {
    final root = getTransactionRootPath(spaceName: spaceName);
    return pathJoin(root, 'dir_$dirIndex');
  }

  /// transaction partition directory path
  String getTransactionPartitionDirPath(int dirIndex, int partitionIndex,
      {String? spaceName}) {
    final shard = getTransactionDirShardPath(dirIndex, spaceName: spaceName);
    return pathJoin(shard, 'p$partitionIndex');
  }

  /// transaction partition log directory path
  String getTransactionPartitionLogPath(int dirIndex, int partitionIndex,
      {String? spaceName}) {
    final dirPath = getTransactionPartitionDirPath(dirIndex, partitionIndex,
        spaceName: spaceName);
    return pathJoin(dirPath, 'tx_$partitionIndex.log');
  }

  /// transaction partition main log file path (append-only), stores all transaction entries
  /// Note: This method requires dirIndex to be provided. Use TransactionManager to get dirIndex.
  String getTransactionPartitionLogPathById(String transactionId, int dirIndex,
      {String? spaceName}) {
    final pIndex = parseTransactionPartitionIndex(transactionId);
    return getTransactionPartitionLogPath(dirIndex, pIndex,
        spaceName: spaceName);
  }

  /// transaction partition meta file path, tracking counts and finished stats
  String getTransactionPartitionMetaPath(int dirIndex, int partitionIndex,
      {String? spaceName}) {
    final dirPath = getTransactionPartitionDirPath(dirIndex, partitionIndex,
        spaceName: spaceName);
    return pathJoin(dirPath, 'meta.json');
  }

  /// transaction partition status log file path
  String getTransactionPartitionStatusLogPath(int dirIndex, int partitionIndex,
      {String? spaceName}) {
    final dirPath = getTransactionPartitionDirPath(dirIndex, partitionIndex,
        spaceName: spaceName);
    return pathJoin(dirPath, 'status.log');
  }

  /// transaction partition status log file path, append one line per txn state change
  /// Note: This method requires dirIndex to be provided. Use TransactionManager to get dirIndex.
  String getTransactionPartitionStatusLogPathById(
      String transactionId, int dirIndex,
      {String? spaceName}) {
    final pIndex = parseTransactionPartitionIndex(transactionId);
    return getTransactionPartitionStatusLogPath(dirIndex, pIndex,
        spaceName: spaceName);
  }

  /// Build a transaction ID encoding partition index for quick location.
  /// Format: tx-{partitionIndex}-{uniqueSuffix}
  String buildTransactionId(int partitionIndex, String uniqueSuffix) {
    return 'tx-$partitionIndex-$uniqueSuffix';
  }

  /// Parse transaction ID, return partition index; returns -1 if invalid.
  int parseTransactionPartitionIndex(String transactionId) {
    try {
      // Expected format: tx-<partitionIndex>-<suffix>
      final parts = transactionId.split('-');
      if (parts.length < 3) return -1;
      if (parts[0] != 'tx') return -1;
      return int.tryParse(parts[1]) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  //==================================
  // WAL path methods
  //==================================

  /// WAL root path under the current space
  String getWalRootPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return pathJoin(spacePath, 'wal');
  }

  /// WAL backup meta file path (stores previous stable WAL meta snapshot)
  String getWalBackupMetaPath({String? spaceName}) {
    return pathJoin(getWalRootPath(spaceName: spaceName), 'meta.bak.json');
  }

  /// WAL main meta file path (checkpoint, partition ranges, flags)
  String getWalMainMetaPath({String? spaceName}) {
    return pathJoin(getWalRootPath(spaceName: spaceName), 'meta.json');
  }

  /// WAL partition directory shard path
  String getWalDirShardPath(int dirIndex, {String? spaceName}) {
    final root = getWalRootPath(spaceName: spaceName);
    return pathJoin(root, 'dir_$dirIndex');
  }

  /// WAL partition file path: `wal_partitionIndex.log`
  String getWalPartitionLogPath(int dirIndex, int partitionIndex,
      {String? spaceName}) {
    final dirPath = getWalDirShardPath(dirIndex, spaceName: spaceName);
    return pathJoin(dirPath, 'wal_$partitionIndex.log');
  }

  //==================================
  // Parallel journal (A/B) path methods
  //==================================

  /// Parallel journal root path under the current space
  String getParallelJournalRootPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return pathJoin(spacePath, 'parallel_journal');
  }

  /// Parallel journal A file path
  String getParallelJournalAPath({String? spaceName}) {
    return pathJoin(
        getParallelJournalRootPath(spaceName: spaceName), 'journal_a.log');
  }

  /// Parallel journal B file path
  String getParallelJournalBPath({String? spaceName}) {
    return pathJoin(
        getParallelJournalRootPath(spaceName: spaceName), 'journal_b.log');
  }

  /// Page redo log path for a batch (full page images before writing to index/table files).
  /// Replay on recovery to restore pages without reading possibly corrupted files.
  /// Caller should delete this file after the batch is fully flushed and before checkpoint.
  String getPageRedoLogPath(String batchId, {String? spaceName}) {
    return pathJoin(getParallelJournalRootPath(spaceName: spaceName),
        'page_redo_$batchId.log');
  }
}
