import '../model/table_context.dart';
import '../model/data_store_config.dart';
import '../handler/common.dart';
import '../handler/weight_snapshot_codec.dart';
import 'data_store_impl.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
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

  /// Space-local access-weight snapshot (soft stats; not WAL-backed).
  /// If [rootPath] is provided, build path from that root; otherwise use instance path.
  String getAccessWeightsPath({String? rootPath, String? spaceName}) {
    final spacePath = getSpacePath(rootPath: rootPath, spaceName: spaceName);
    return pathJoin(spacePath, WeightSnapshotCodec.fileName);
  }

  /// get temp directory path under current space
  /// All crash-safe temporary files are placed here to ensure same filesystem/volume.
  String getTempDirPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return pathJoin(spacePath, 'tmp');
  }

  //==================================
  // Table / index / NGH paths (sync, TableContext)
  //==================================

  /// Synchronous table path using [TableContext] layout fields (no meta lookup).
  String getTablePathByContext(TableContext table) {
    if (dataStore.config.persistenceMode == PersistenceMode.memory) {
      return 'memory://${dataStore.currentSpaceName}/tables/${table.tableUid}';
    }

    final parentDir = table.isGlobal
        ? pathJoin(_instancePath, 'global')
        : getSpacePath(spaceName: dataStore.currentSpaceName);

    return pathJoin(parentDir, 'tables_${table.dirIndex}', table.tableUid);
  }

  /// Synchronous table data root directory path.
  String getDataDirPathByContext(TableContext table) {
    return pathJoin(getTablePathByContext(table), 'data');
  }

  /// Synchronous table B+Tree partitions directory path.
  String getPartitionsDirPathByContext(TableContext table) {
    return pathJoin(getDataDirPathByContext(table), 'btree');
  }

  /// Synchronous table B+Tree partition directory path by dir shard.
  String getPartitionDirPathByContext(TableContext table, int dirIndex) {
    return pathJoin(getPartitionsDirPathByContext(table), 'dir_$dirIndex');
  }

  /// Synchronous table B+Tree partition file path by partitionNo.
  String getPartitionFilePathByContext(TableContext table, int partitionNo) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return pathJoin(
      getPartitionDirPathByContext(table, dirIndex),
      'p$partitionNo.dat',
    );
  }

  /// Synchronous table overflow (TOAST-like) directory path.
  String getOverflowDirPathByContext(TableContext table) {
    return pathJoin(getDataDirPathByContext(table), 'overflow');
  }

  /// Synchronous overflow partition file path by partitionNo.
  String getOverflowPartitionFilePathByContext(
    TableContext table,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dirPath =
        pathJoin(getOverflowDirPathByContext(table), 'dir_$dirIndex');
    return pathJoin(dirPath, 'p$partitionNo.dat');
  }

  /// Synchronous table index root directory path.
  String getIndexDirPathByContext(TableContext table) {
    return pathJoin(getTablePathByContext(table), 'index');
  }

  /// Synchronous index root directory path.
  String getIndexPathByContext(TableContext table, IndexUid indexUid) {
    return pathJoin(getIndexDirPathByContext(table), indexUid);
  }

  /// Synchronous index B+Tree partition directory path by dir shard.
  String getIndexPartitionDirPathByContext(
    TableContext table,
    IndexUid indexUid,
    int dirIndex,
  ) {
    return pathJoin(
      getIndexPathByContext(table, indexUid),
      'btree',
      'dir_$dirIndex',
    );
  }

  /// Synchronous index B+Tree partition file path by partitionNo.
  String getIndexPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return pathJoin(
      getIndexPartitionDirPathByContext(table, indexUid, dirIndex),
      'p$partitionNo.idx',
    );
  }

  /// Synchronous NGH vector index root path.
  String getNghIndexPathByContext(TableContext table, IndexUid indexUid) {
    return pathJoin(getIndexPathByContext(table, indexUid), 'ngh');
  }

  /// Synchronous NGH PQ codebook file path.
  String getNghCodebookPathByContext(TableContext table, IndexUid indexUid) {
    return pathJoin(
      getNghIndexPathByContext(table, indexUid),
      'codebook.ngh',
    );
  }

  String _nghPartitionDirPathByContext(
    TableContext table,
    IndexUid indexUid,
    String category,
    int dirIndex,
  ) {
    return pathJoin(
      getNghIndexPathByContext(table, indexUid),
      category,
      'dir_$dirIndex',
    );
  }

  /// Synchronous NGH graph partition file path by partitionNo.
  String getNghGraphPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return pathJoin(
      _nghPartitionDirPathByContext(table, indexUid, 'graph', dirIndex),
      'p$partitionNo.ngh',
    );
  }

  /// Synchronous NGH PQ-code partition file path by partitionNo.
  String getNghPqCodePartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return pathJoin(
      _nghPartitionDirPathByContext(table, indexUid, 'pqcode', dirIndex),
      'p$partitionNo.ngh',
    );
  }

  /// Synchronous NGH raw-vector partition file path by partitionNo.
  String getNghRawVectorPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return pathJoin(
      _nghPartitionDirPathByContext(table, indexUid, 'rawvec', dirIndex),
      'p$partitionNo.ngh',
    );
  }

  /// Fixed [TableContext] for `_system_table_meta` (bootstrap; no meta I/O).
  TableContext systemTableMetaContext() {
    return TableContext(
      tableUid: SystemTable.tableMetaTableUid,
      tableName: TableName(SystemTable.tableMetaName),
      isGlobal: true,
      dirIndex: SystemTable.tableMetaDirIndex,
      schema: SystemTable.tableMetaTable(),
    );
  }

  //==================================
  // Table path by UID (async layout resolve; cold / bootstrap only)
  //==================================

  /// Resolve persisted layout fields for [tableUid].
  ///
  /// Hot paths should pass [TableContext] and use the sync `*ByContext` APIs.
  Future<TableContext> _resolveTableLayout(TableUid tableUid) async {
    if (tableUid == SystemTable.tableMetaTableUid) {
      return systemTableMetaContext();
    }

    final syncCtx = dataStore.tableMetaManager?.getTableContextSync(tableUid);
    if (syncCtx != null) return syncCtx;

    final ctx = await dataStore.tableMetaManager?.getTableContext(tableUid);
    if (ctx != null) return ctx;

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

  /// Table root path when only [tableUid] is known (resolves layout once).
  ///
  /// Prefer [getTablePathByContext] on engine hot paths.
  Future<String> getTablePathByUid(TableUid tableUid) async {
    final layout = await _resolveTableLayout(tableUid);
    return getTablePathByContext(layout);
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
