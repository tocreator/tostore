import '../model/data_store_config.dart';
import '../handler/common.dart';
import 'data_store_impl.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_identity.dart';

/// path manager
/// responsible for all file path related operations, including table paths, index paths, data paths, etc.
class PathManager {
  final DataStoreImpl dataStore;
  DataStoreConfig get config => dataStore.config;

  PathManager(this.dataStore);

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

  /// get backup directory path
  String getBackupPath() {
    return pathJoin(_instancePath, 'backups');
  }

  /// get migrations directory path
  String getMigrationsPath() {
    return pathJoin(_instancePath, 'migrations');
  }

  /// get migration meta file path (migration metadata, TOBF)
  String getMigrationMetaPath() {
    return pathJoin(getMigrationsPath(), 'migration_meta.tobf');
  }

  /// get migration task file path (TOBF)
  String getMigrationTaskPath(int dirIndex, String taskId) {
    return pathJoin(getMigrationsPath(), 'dir_$dirIndex', 'task_$taskId.tobf');
  }

  /// get global config file path (TOBF binary)
  String getGlobalConfigPath() {
    return pathJoin(_instancePath, 'global_config.tobf');
  }

  /// get space config path (TOBF binary)
  /// If [rootPath] is provided, build path from that root; otherwise use instance path
  String getSpaceConfigPath({String? rootPath, String? spaceName}) {
    final spacePath = getSpacePath(rootPath: rootPath, spaceName: spaceName);
    return pathJoin(spacePath, 'space_config.tobf');
  }

  /// get temp directory path under current space
  /// All crash-safe temporary files are placed here to ensure same filesystem/volume.
  String getTempDirPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return pathJoin(spacePath, 'tmp');
  }

  //==================================
  // table path methods (async methods)
  //==================================

  /// get table path by UID
  Future<String> getTablePathByUid(TableUid tableUid) async {
    final uid = tableUid;
    if (dataStore.config.persistenceMode == PersistenceMode.memory) {
      return 'memory://${dataStore.currentSpaceName}/tables/$uid';
    }

    final meta = await dataStore.tableMetaManager?.getTableMeta(tableUid);
    if (meta == null) {
      final displayName =
          (await dataStore.tableMetaManager?.getNameByUid(tableUid))?.value ??
              tableUid.value;
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devTableNotFound,
          message: 'Table meta not found for table: $displayName',
          tableName: displayName,
        ),
      ]);
    }

    final String parentDir;
    if (meta.isGlobal) {
      parentDir = pathJoin(_instancePath, 'global');
    } else {
      parentDir = getSpacePath(spaceName: dataStore.currentSpaceName);
    }

    return pathJoin(parentDir, 'tables_${meta.dirIndex}', uid);
  }

  /// get table data root directory path
  Future<String> getDataDirPath(TableUid tableUid) async {
    final tablePath = await getTablePathByUid(tableUid);
    return pathJoin(tablePath, 'data');
  }

  /// get table data btree partitions directory path
  Future<String> getPartitionsDirPath(TableUid tableUid) async {
    final dataPath = await getDataDirPath(tableUid);
    return pathJoin(dataPath, 'btree');
  }

  /// Get table overflow (TOAST-like) directory path.
  Future<String> getOverflowDirPath(TableUid tableUid) async {
    final dataPath = await getDataDirPath(tableUid);
    return pathJoin(dataPath, 'overflow');
  }

  /// Get overflow partition file path by partitionNo.
  Future<String> getOverflowPartitionFilePathByNo(
      TableUid tableUid, int partitionNo) async {
    final overflowDir = await getOverflowDirPath(tableUid);
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dirPath = pathJoin(overflowDir, 'dir_$dirIndex');
    return pathJoin(dirPath, 'p$partitionNo.dat');
  }

  /// get table data partition directory path
  Future<String> getPartitionDirPath(TableUid tableUid, int dirIndex) async {
    final partitionsPath = await getPartitionsDirPath(tableUid);
    return pathJoin(partitionsPath, 'dir_$dirIndex');
  }

  /// Get table B+Tree partition file path by partitionNo (new layout).
  Future<String> getPartitionFilePathByNo(
      TableUid tableUid, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dirPath = await getPartitionDirPath(tableUid, dirIndex);
    return pathJoin(dirPath, 'p$partitionNo.dat');
  }

  /// get table index directory path
  Future<String> getIndexDirPath(TableUid tableUid) async {
    final tablePath = await getTablePathByUid(tableUid);
    return pathJoin(tablePath, 'index');
  }

  /// get index root directory path
  Future<String> getIndexPath(TableUid tableUid, IndexUid indexUid) async {
    final indexDirPath = await getIndexDirPath(tableUid);
    return pathJoin(indexDirPath, indexUid);
  }

  /// get index btree partition directory path
  Future<String> getIndexPartitionDirPath(
      TableUid tableUid, IndexUid indexUid, int dirIndex) async {
    final indexPath = await getIndexPath(tableUid, indexUid);
    return pathJoin(indexPath, 'btree', 'dir_$dirIndex');
  }

  /// Get index B+Tree partition file path by partitionNo (new layout).
  Future<String> getIndexPartitionPathByNo(
      TableUid tableUid, IndexUid indexUid, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dirPath =
        await getIndexPartitionDirPath(tableUid, indexUid, dirIndex);
    return pathJoin(dirPath, 'p$partitionNo.idx');
  }

  // ==================================
  // NGH vector index path methods
  // ==================================

  /// Root path for an NGH vector index.
  Future<String> getNghIndexPath(TableUid tableUid, IndexUid indexUid) async {
    final indexPath = await getIndexPath(tableUid, indexUid);
    return pathJoin(indexPath, 'ngh');
  }

  /// NGH PQ codebook file.
  Future<String> getNghCodebookPath(
      TableUid tableUid, IndexUid indexUid) async {
    final nghPath = await getNghIndexPath(tableUid, indexUid);
    return pathJoin(nghPath, 'codebook.ngh');
  }

  /// NGH graph partition directory path.
  Future<String> _nghPartitionDirPath(TableUid tableUid, IndexUid indexUid,
      String category, int dirIndex) async {
    final nghPath = await getNghIndexPath(tableUid, indexUid);
    return pathJoin(nghPath, category, 'dir_$dirIndex');
  }

  /// NGH graph partition file path by partitionNo.
  Future<String> getNghGraphPartitionPath(
      TableUid tableUid, IndexUid indexUid, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dir =
        await _nghPartitionDirPath(tableUid, indexUid, 'graph', dirIndex);
    return pathJoin(dir, 'p$partitionNo.ngh');
  }

  /// NGH PQ-code partition file path by partitionNo.
  Future<String> getNghPqCodePartitionPath(
      TableUid tableUid, IndexUid indexUid, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dir =
        await _nghPartitionDirPath(tableUid, indexUid, 'pqcode', dirIndex);
    return pathJoin(dir, 'p$partitionNo.ngh');
  }

  /// NGH raw-vector partition file path by partitionNo.
  Future<String> getNghRawVectorPartitionPath(
      TableUid tableUid, IndexUid indexUid, int partitionNo) async {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dir =
        await _nghPartitionDirPath(tableUid, indexUid, 'rawvec', dirIndex);
    return pathJoin(dir, 'p$partitionNo.ngh');
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
    return pathJoin(getTransactionRootPath(spaceName: spaceName), 'meta.tobf');
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
    return pathJoin(dirPath, 'meta.tobf');
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
    return pathJoin(getWalRootPath(spaceName: spaceName), 'meta.bak.tobf');
  }

  /// WAL main meta file path (checkpoint, partition ranges, flags)
  String getWalMainMetaPath({String? spaceName}) {
    return pathJoin(getWalRootPath(spaceName: spaceName), 'meta.tobf');
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
  // Batch page-redo directory
  //==================================

  /// Parallel journal root path under the current space
  String getParallelJournalRootPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return pathJoin(spacePath, 'parallel_journal');
  }

  /// Page redo log path for a batch
  String getPageRedoLogPath(String batchId, {String? spaceName}) {
    return pathJoin(getParallelJournalRootPath(spaceName: spaceName),
        'page_redo_$batchId.log');
  }
}
