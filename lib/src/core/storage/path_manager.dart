import 'package:path/path.dart' as path;

import '../../model/data_store_config.dart';
import '../../model/db_exception.dart';
import '../../model/result_status.dart';
import '../../model/result_type.dart';
import '../../model/system_table.dart';
import '../../model/table_context.dart';
import '../../model/table_identity.dart';
import '../codec/weight_snapshot_codec.dart';
import '../engine/data_store_impl.dart';

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
    return path.join(baseRoot, 'spaces', spaceName ?? _currentSpaceName);
  }

  /// get global table directory path
  /// If [rootPath] is provided, build path from that root; otherwise use instance path
  String getGlobalPath({String? rootPath}) {
    final String baseRoot = rootPath ?? _instancePath;
    return path.join(baseRoot, 'global');
  }

  /// get backup directory path
  String getBackupPath() {
    return path.join(_instancePath, 'backups');
  }

  /// get migrations directory path
  String getMigrationsPath() {
    return path.join(_instancePath, 'migrations');
  }

  /// get migration meta file path (migration metadata, TOBF)
  String getMigrationMetaPath() {
    return path.join(getMigrationsPath(), 'migration_meta.tobf');
  }

  /// get migration task file path (TOBF)
  String getMigrationTaskPath(int dirIndex, String taskId) {
    return path.join(getMigrationsPath(), 'dir_$dirIndex', 'task_$taskId.tobf');
  }

  /// get global config file path (TOBF binary)
  String getGlobalConfigPath() {
    return path.join(_instancePath, 'global_config.tobf');
  }

  /// Generate the deterministic temporary file path for any target [filePath]
  /// (used for atomic flush / emergency recovery).
  static String buildTempPath(String filePath) {
    final normalized = path.normalize(filePath);
    final parts = path.split(normalized);
    final idx = parts.indexOf('spaces');

    if (idx != -1 && idx + 1 < parts.length) {
      final spaceRootParts = parts.sublist(0, idx + 2); // .../spaces/<space>
      final spaceRoot = path.joinAll(spaceRootParts);
      final tmpRoot = path.join(spaceRoot, 'tmp');

      final relParts = parts.sublist(idx + 2); // after .../spaces/<space>
      if (relParts.isEmpty) {
        return path.join(tmpRoot, 'temp.tmp');
      }

      final base = relParts.removeLast();
      final relDir = relParts.isEmpty ? '' : path.joinAll(relParts);
      final tmpName = '$base.tmp';

      return relDir.isEmpty
          ? path.join(tmpRoot, tmpName)
          : path.join(tmpRoot, relDir, tmpName);
    }

    final dir = path.dirname(normalized);
    final base = path.basename(normalized);
    return path.join(dir, '$base.tmp');
  }

  /// Space-local access-weight snapshot (soft stats; not WAL-backed).
  /// If [rootPath] is provided, build path from that root; otherwise use instance path.
  String getAccessWeightsPath({String? rootPath, String? spaceName}) {
    final spacePath = getSpacePath(rootPath: rootPath, spaceName: spaceName);
    return path.join(spacePath, WeightSnapshotCodec.fileName);
  }

  /// get temp directory path under current space
  /// All crash-safe temporary files are placed here to ensure same filesystem/volume.
  String getTempDirPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return path.join(spacePath, 'tmp');
  }

  //==================================
  // Table / index / NGH paths (sync, TableContext)
  //==================================

  /// Synchronous table path using [TableContext] layout fields (no meta lookup).
  String getTablePathByContext(TableContext table, {String? spaceName}) {
    if (dataStore.config.persistenceMode == PersistenceMode.memory) {
      return 'memory://${spaceName ?? dataStore.currentSpaceName}/tables/${table.tableUid}';
    }

    final parentDir = table.isGlobal
        ? path.join(_instancePath, 'global')
        : getSpacePath(spaceName: spaceName ?? dataStore.currentSpaceName);

    return path.join(parentDir, 'tables_${table.dirIndex}', table.tableUid);
  }

  /// Synchronous table data root directory path.
  String getDataDirPathByContext(TableContext table, {String? spaceName}) {
    return path.join(
        getTablePathByContext(table, spaceName: spaceName), 'data');
  }

  /// Synchronous table B+Tree partitions directory path.
  String getPartitionsDirPathByContext(TableContext table,
      {String? spaceName}) {
    return path.join(
      getDataDirPathByContext(table, spaceName: spaceName),
      'btree',
    );
  }

  /// Synchronous table B+Tree partition directory path by dir shard.
  String getPartitionDirPathByContext(
    TableContext table,
    int dirIndex, {
    String? spaceName,
  }) {
    return path.join(
      getPartitionsDirPathByContext(table, spaceName: spaceName),
      'dir_$dirIndex',
    );
  }

  /// Synchronous table B+Tree partition file path by partitionNo.
  String getPartitionFilePathByContext(
    TableContext table,
    int partitionNo, {
    String? spaceName,
  }) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return path.join(
      getPartitionDirPathByContext(table, dirIndex, spaceName: spaceName),
      'p$partitionNo.dat',
    );
  }

  /// Synchronous table overflow (TOAST-like) directory path.
  String getOverflowDirPathByContext(TableContext table) {
    return path.join(getDataDirPathByContext(table), 'overflow');
  }

  /// Synchronous overflow partition file path by partitionNo.
  String getOverflowPartitionFilePathByContext(
    TableContext table,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    final dirPath =
        path.join(getOverflowDirPathByContext(table), 'dir_$dirIndex');
    return path.join(dirPath, 'p$partitionNo.dat');
  }

  /// Synchronous table index root directory path.
  String getIndexDirPathByContext(TableContext table) {
    return path.join(getTablePathByContext(table), 'index');
  }

  /// Synchronous index root directory path.
  String getIndexPathByContext(TableContext table, IndexUid indexUid) {
    return path.join(getIndexDirPathByContext(table), indexUid);
  }

  /// Synchronous index B+Tree partition directory path by dir shard.
  String getIndexPartitionDirPathByContext(
    TableContext table,
    IndexUid indexUid,
    int dirIndex,
  ) {
    return path.join(
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
    return path.join(
      getIndexPartitionDirPathByContext(table, indexUid, dirIndex),
      'p$partitionNo.idx',
    );
  }

  /// Synchronous NGH vector index root path.
  String getNghIndexPathByContext(TableContext table, IndexUid indexUid) {
    return path.join(getIndexPathByContext(table, indexUid), 'ngh');
  }

  String _nghPartitionDirPathByContext(
    TableContext table,
    IndexUid indexUid,
    String category,
    int dirIndex,
  ) {
    return path.join(
      getNghIndexPathByContext(table, indexUid),
      category,
      'dir_$dirIndex',
    );
  }

  /// Physical vector-leaf partition file path by partitionNo.
  String getNghLeafPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return path.join(
      _nghPartitionDirPathByContext(table, indexUid, 'leaf', dirIndex),
      'p$partitionNo.ngh',
    );
  }

  /// Navigating graph blob under live `ngh/` (pre-v4 leftover only).
  String getNghNavGraphPathByContext(TableContext table, IndexUid indexUid) {
    return path.join(
      getNghIndexPathByContext(table, indexUid),
      'nav_graph.ngh',
    );
  }

  /// Synchronous NGH paged navigating-centroid partition path.
  String getNghNavPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return path.join(
      _nghPartitionDirPathByContext(table, indexUid, 'nav', dirIndex),
      'p$partitionNo.ngh',
    );
  }

  /// Synchronous NGH PK-locator B+Tree partition path.
  String getNghPkmapPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return path.join(
      _nghPartitionDirPathByContext(table, indexUid, 'pkmap', dirIndex),
      'p$partitionNo.ngh',
    );
  }

  /// Pending-delete PK set used only while PK locator backfill is incomplete.
  String getNghPendingDeletePathByContext(
    TableContext table,
    IndexUid indexUid,
  ) {
    return path.join(
      getNghIndexPathByContext(table, indexUid),
      'pending_delete.ngh',
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
    return path.join(spacePath, 'transactions');
  }

  /// transaction main meta file path (track active partitions, next index, etc.)
  String getTransactionMainMetaPath({String? spaceName}) {
    return path.join(getTransactionRootPath(spaceName: spaceName), 'meta.tobf');
  }

  /// transaction directory path by directory shard
  String getTransactionDirShardPath(int dirIndex, {String? spaceName}) {
    final root = getTransactionRootPath(spaceName: spaceName);
    return path.join(root, 'dir_$dirIndex');
  }

  /// transaction partition directory path
  String getTransactionPartitionDirPath(int dirIndex, int partitionIndex,
      {String? spaceName}) {
    final shard = getTransactionDirShardPath(dirIndex, spaceName: spaceName);
    return path.join(shard, 'p$partitionIndex');
  }

  /// transaction partition log directory path
  String getTransactionPartitionLogPath(int dirIndex, int partitionIndex,
      {String? spaceName}) {
    final dirPath = getTransactionPartitionDirPath(dirIndex, partitionIndex,
        spaceName: spaceName);
    return path.join(dirPath, 'tx_$partitionIndex.log');
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
    return path.join(dirPath, 'meta.tobf');
  }

  /// transaction partition status log file path
  String getTransactionPartitionStatusLogPath(int dirIndex, int partitionIndex,
      {String? spaceName}) {
    final dirPath = getTransactionPartitionDirPath(dirIndex, partitionIndex,
        spaceName: spaceName);
    return path.join(dirPath, 'status.log');
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

  String _wmbpPartitionDirPathByContext(
    TableContext table,
    IndexUid indexUid,
    String category,
    int dirIndex,
  ) {
    return path.join(
      getWmbpCategoryRootPathByContext(table, indexUid, category),
      'dir_$dirIndex',
    );
  }

  /// Category root: `index/<indexUid>/wmbp/<category>/` (contains `dir_*`).
  String getWmbpCategoryRootPathByContext(
    TableContext table,
    IndexUid indexUid,
    String category,
  ) {
    return path.join(
      getIndexPathByContext(table, indexUid),
      'wmbp',
      category,
    );
  }

  /// WMBP dictionary partition: `index/<indexUid>/wmbp/dict/dir_<dir>/p<n>.wmbp`.
  String getWmbpDictPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return path.join(
      _wmbpPartitionDirPathByContext(table, indexUid, 'dict', dirIndex),
      'p$partitionNo.wmbp',
    );
  }

  /// WMBP posting partition: `index/<indexUid>/wmbp/post/dir_<dir>/p<n>.wmbp`.
  String getWmbpPostPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return path.join(
      _wmbpPartitionDirPathByContext(table, indexUid, 'post', dirIndex),
      'p$partitionNo.wmbp',
    );
  }

  /// WMBP active-mask partition: `index/<indexUid>/wmbp/win/dir_<dir>/p<n>.wmbp`.
  String getWmbpWinPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return path.join(
      _wmbpPartitionDirPathByContext(table, indexUid, 'win', dirIndex),
      'p$partitionNo.wmbp',
    );
  }

  /// WMBP forward-map partition: `index/<indexUid>/wmbp/fwd/dir_<dir>/p<n>.wmbp`.
  String getWmbpFwdPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return path.join(
      _wmbpPartitionDirPathByContext(table, indexUid, 'fwd', dirIndex),
      'p$partitionNo.wmbp',
    );
  }

  /// WMBP partition file for [category] (`dict`, `post`, `win`, `fwd`, `rev`).
  String getWmbpPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    String category,
    int partitionNo,
  ) {
    switch (category) {
      case 'dict':
        return getWmbpDictPartitionPathByContext(table, indexUid, partitionNo);
      case 'post':
        return getWmbpPostPartitionPathByContext(table, indexUid, partitionNo);
      case 'win':
        return getWmbpWinPartitionPathByContext(table, indexUid, partitionNo);
      case 'fwd':
        return getWmbpFwdPartitionPathByContext(table, indexUid, partitionNo);
      case 'rev':
        return getWmbpRevPartitionPathByContext(table, indexUid, partitionNo);
      default:
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentType,
            message: 'Unknown WMBP category $category',
            parameterName: 'category',
            passedValue: category,
          ),
        ]);
    }
  }

  /// WMBP reverse-map partition: `index/<indexUid>/wmbp/rev/dir_<dir>/p<n>.wmbp`.
  String getWmbpRevPartitionPathByContext(
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ dataStore.maxEntriesPerDir;
    return path.join(
      _wmbpPartitionDirPathByContext(table, indexUid, 'rev', dirIndex),
      'p$partitionNo.wmbp',
    );
  }

  //==================================
  // WAL path methods
  //==================================

  /// WAL root path under the current space
  String getWalRootPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return path.join(spacePath, 'wal');
  }

  /// WAL backup meta file path (stores previous stable WAL meta snapshot)
  String getWalBackupMetaPath({String? spaceName}) {
    return path.join(getWalRootPath(spaceName: spaceName), 'meta.bak.tobf');
  }

  /// WAL main meta file path (checkpoint, partition ranges, flags)
  String getWalMainMetaPath({String? spaceName}) {
    return path.join(getWalRootPath(spaceName: spaceName), 'meta.tobf');
  }

  /// WAL partition directory shard path
  String getWalDirShardPath(int dirIndex, {String? spaceName}) {
    final root = getWalRootPath(spaceName: spaceName);
    return path.join(root, 'dir_$dirIndex');
  }

  /// WAL partition file path: `wal_partitionIndex.log`
  String getWalPartitionLogPath(int dirIndex, int partitionIndex,
      {String? spaceName}) {
    final dirPath = getWalDirShardPath(dirIndex, spaceName: spaceName);
    return path.join(dirPath, 'wal_$partitionIndex.log');
  }

  //==================================
  // Batch page-redo directory
  //==================================

  /// Parallel journal root path under the current space
  String getParallelJournalRootPath({String? spaceName}) {
    final spacePath = getSpacePath(spaceName: spaceName);
    return path.join(spacePath, 'parallel_journal');
  }

  /// Page redo log path for a batch
  String getPageRedoLogPath(String batchId, {String? spaceName}) {
    return path.join(getParallelJournalRootPath(spaceName: spaceName),
        'page_redo_$batchId.log');
  }
}
