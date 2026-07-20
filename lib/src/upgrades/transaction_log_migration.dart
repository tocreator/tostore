import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../core/data_store_impl.dart';
import '../handler/logger.dart';
import '../handler/txn_encoder.dart';
import '../model/db_exception.dart';
import '../model/global_config.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_identity.dart';
import '../model/transaction_models.dart';
import 'legacy_model/legacy_json.dart';

/// One-shot migration of legacy NDJSON transaction logs to binary ToTX records.
///
/// Crash-safe / idempotent:
/// - Already-complete ToTX files are skipped (and stale `.old` cleaned).
/// - Half-written ToTX is restored from `.old` when present, then rewritten.
/// - `writeAsBytes(..., flush: true)` uses atomic temp+replace via StorageAdapter.
/// - Per-partition failures do not skip remaining partitions in the same run;
///   the first error is rethrown after the sweep so the next startup resumes.
class TransactionLogMigration {
  final DataStoreImpl _dataStore;

  TransactionLogMigration(this._dataStore);

  /// Migrate all transaction logs under each space's `transactions/` tree.
  Future<void> migrateAllSpaces(Iterable<String> spaceNames) async {
    DbException? firstError;
    for (final spaceName in spaceNames) {
      try {
        await migrateSpace(spaceName);
      } catch (e) {
        Logger.warn(
          'v3: transaction log migration failed for space $spaceName',
          rawError: e,
        );
        firstError ??= DbException.wrap(
          e,
          fallbackType: ResultType.engError,
          fallbackMessage:
              'Transaction log migration failed for space $spaceName',
        );
      }
    }
    if (firstError != null) throw firstError;
  }

  /// Residual entry for DBs whose engine version already matches but a prior
  /// interrupted upgrade may have left NDJSON txn logs (idempotent).
  Future<void> migrateResidualIfNeeded(GlobalConfig globalConfig) async {
    final spaces = globalConfig.spaceNames.isNotEmpty
        ? globalConfig.spaceNames.toList()
        : <String>['default'];
    await migrateAllSpaces(spaces);
  }

  Future<void> migrateSpace(String spaceName) async {
    final root =
        _dataStore.pathManager.getTransactionRootPath(spaceName: spaceName);
    if (!await _dataStore.storage.existsDirectory(root)) return;

    // Prefer TransactionMainMeta.activePartitions (same set as crash recovery).
    final partitions = await _loadActivePartitions(spaceName);
    if (partitions != null) {
      await _migratePartitions(partitions, spaceName);
      return;
    }

    // Meta missing/corrupt: fall back to directory scan so unfinished logs
    // are still rewritten before recovery runs.
    Logger.warn(
      'v3: transaction meta unavailable for space $spaceName; '
      'falling back to directory scan',
    );
    await _migrateSpaceByDirectoryScan(root, spaceName);
  }

  Future<void> _migratePartitions(
    Iterable<int> partitions,
    String spaceName,
  ) async {
    DbException? firstError;
    for (final partitionIndex in partitions) {
      try {
        await _migratePartition(partitionIndex, spaceName);
      } catch (e) {
        Logger.warn(
          'v3: transaction log migration failed for partition $partitionIndex '
          'in space $spaceName',
          rawError: e,
        );
        firstError ??= DbException.wrap(
          e,
          fallbackType: ResultType.engError,
          fallbackMessage:
              'Transaction log migration failed for partition $partitionIndex',
        );
      }
    }
    if (firstError != null) throw firstError;
  }

  /// Returns active partition indexes from `transactions/meta.json`, or null
  /// when the meta file is missing or unreadable.
  Future<Set<int>?> _loadActivePartitions(String spaceName) async {
    final metaPath =
        _dataStore.pathManager.getTransactionMainMetaPath(spaceName: spaceName);
    if (!await _dataStore.storage.existsFile(metaPath)) return null;
    try {
      final content = await _dataStore.storage.readAsString(metaPath);
      if (content == null || content.isEmpty) return null;
      final meta = TransactionMainMeta.fromJson(
          jsonDecode(content) as Map<String, dynamic>);
      final partitions = Set<int>.from(meta.activePartitions);
      partitions.add(meta.currentPartitionIndex);
      return partitions;
    } catch (e) {
      Logger.warn(
        'v3: failed to parse transaction meta for space $spaceName',
        rawError: e,
      );
      return null;
    }
  }

  Future<void> _migrateSpaceByDirectoryScan(
    String root,
    String spaceName,
  ) async {
    final indexes = <int>{};
    final shards = await _dataStore.storage.listDirectory(root);
    for (final shardName in shards) {
      if (!shardName.startsWith('dir_')) continue;
      final shardPath = path.join(root, shardName);
      if (!await _dataStore.storage.existsDirectory(shardPath)) continue;
      final partitions = await _dataStore.storage.listDirectory(shardPath);
      for (final partName in partitions) {
        if (!partName.startsWith('p')) continue;
        final partitionIndex = int.tryParse(partName.substring(1));
        if (partitionIndex == null) continue;
        indexes.add(partitionIndex);
      }
    }
    await _migratePartitions(indexes, spaceName);
  }

  Future<void> _migratePartition(int partitionIndex, String spaceName) async {
    final dirIndex = partitionIndex ~/ _dataStore.maxEntriesPerDir;
    final txLog = _dataStore.pathManager.getTransactionPartitionLogPath(
      dirIndex,
      partitionIndex,
      spaceName: spaceName,
    );
    if (await _dataStore.storage.existsFile(txLog)) {
      await _migrateLogFile(txLog, partitionIndex, spaceName);
    }
    final statusLog =
        _dataStore.pathManager.getTransactionPartitionStatusLogPath(
      dirIndex,
      partitionIndex,
      spaceName: spaceName,
    );
    if (await _dataStore.storage.existsFile(statusLog)) {
      await _migrateLogFile(statusLog, partitionIndex, spaceName);
    }
  }

  Future<void> _migrateLogFile(
    String logPath,
    int partitionIndex,
    String spaceName,
  ) async {
    var bytes = await _dataStore.storage.readAsBytes(logPath);
    if (bytes.isEmpty) {
      await _deleteStaleBackup(logPath);
      return;
    }

    final backupPath = '$logPath.old';

    // Complete ToTX file: nothing to do (clean leftover .old from prior crash).
    if (TxnEncoder.isCompleteBinaryFile(bytes)) {
      await _deleteStaleBackup(logPath);
      return;
    }

    // Truncated / mixed binary: prefer restoring from prior backup.
    if (TxnEncoder.looksLikeBinaryFile(bytes) &&
        !TxnEncoder.isCompleteBinaryFile(bytes)) {
      Logger.warn(
        'v3: incomplete binary txn log at $logPath; attempting .old restore',
      );
      if (await _dataStore.storage.existsFile(backupPath)) {
        await _dataStore.storage.deleteFile(logPath);
        await _dataStore.storage.copyFile(backupPath, logPath);
        bytes = await _dataStore.storage.readAsBytes(logPath);
        if (TxnEncoder.isCompleteBinaryFile(bytes)) {
          await _deleteStaleBackup(logPath);
          return;
        }
        // Restored NDJSON (or still dirty): fall through to rewrite.
      } else {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysIoDataCorrupted,
            message: 'Incomplete binary txn log without .old backup: $logPath',
          ),
        ]);
      }
    }

    final events = await _parseLegacyLog(bytes, partitionIndex, spaceName);
    if (events.isEmpty) {
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.trim().isEmpty) {
        await _deleteStaleBackup(logPath);
        return;
      }
      // Non-empty payload that produced no events: fail closed so runtime
      // does not treat leftover NDJSON as an empty binary log.
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message:
              'Legacy txn log produced zero events (refusing to leave as-is): $logPath',
        ),
      ]);
    }

    final out = BytesBuilder(copy: false);
    for (final event in events) {
      out.add(await TxnEncoder.encodeAsRecord(
        event,
        partitionIndex,
        resolveTable: (tableUid) => _resolveTxnTableCodec(tableUid, spaceName),
      ));
    }
    final rewritten = out.toBytes();
    if (!TxnEncoder.isCompleteBinaryFile(rewritten)) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message: 'Rewritten txn log failed binary integrity: $logPath',
        ),
      ]);
    }

    // Keep .old through the atomic replace so a crash mid-write can restore.
    if (await _dataStore.storage.existsFile(backupPath)) {
      await _dataStore.storage.deleteFile(backupPath);
    }
    await _dataStore.storage.copyFile(logPath, backupPath);
    // flush:true → StorageAdapter temp write + replaceFileAtomic
    await _dataStore.storage.writeAsBytes(logPath, rewritten, flush: true);

    // Drop plaintext backup only after a verified rewrite.
    await _deleteStaleBackup(logPath);
    Logger.info('v3: migrated legacy transaction log $logPath');
  }

  Future<void> _deleteStaleBackup(String logPath) async {
    final backupPath = '$logPath.old';
    try {
      if (await _dataStore.storage.existsFile(backupPath)) {
        await _dataStore.storage.deleteFile(backupPath);
      }
    } catch (_) {}
  }

  Future<List<TxnLogEvent>> _parseLegacyLog(
    Uint8List bytes,
    int partitionIndex,
    String spaceName,
  ) async {
    final text = utf8.decode(bytes, allowMalformed: true);
    final events = <TxnLogEvent>[];
    for (final rawLine in const LineSplitter().convert(text)) {
      try {
        final obj = LegacyTxnJson.parseLine(rawLine);
        if (obj == null) continue;
        final fields = LegacyTxnJson.eventFieldsFromJson(obj);
        if (fields == null) continue;

        TransactionCommitPlan? plan = fields.plan;
        if (plan != null) {
          plan = await _normalizePlanTableKeys(plan, spaceName);
        }

        events.add(TxnLogEvent(
          transactionId: fields.transactionId,
          event: fields.event,
          timestampMs: fields.timestampMs,
          plan: plan,
          nextPartitionIndex: fields.nextPartitionIndex,
          continuedTo: fields.continuedTo,
          insertsApplied: fields.insertsApplied,
          updatesApplied: fields.updatesApplied,
          deletesApplied: fields.deletesApplied,
        ));
      } catch (e) {
        Logger.warn(
          'v3: skipping corrupt legacy txn log line in partition $partitionIndex',
          rawError: e,
        );
      }
    }
    return events;
  }

  Future<TransactionCommitPlan> _normalizePlanTableKeys(
    TransactionCommitPlan plan,
    String spaceName,
  ) async {
    final mgr = _dataStore.tableMetaManager;
    if (mgr == null) return plan;

    Future<Map<String, List<Map<String, dynamic>>>> norm(
      Map<String, List<Map<String, dynamic>>> src,
    ) async {
      final out = <String, List<Map<String, dynamic>>>{};
      for (final e in src.entries) {
        final key = await mgr.normalizeTableFieldKey(e.key);
        out.putIfAbsent(key, () => []).addAll(e.value);
      }
      return out;
    }

    return TransactionCommitPlan(
      transactionId: plan.transactionId,
      inserts: await norm(plan.inserts),
      updates: await norm(plan.updates),
      deletes: await norm(plan.deletes),
      heavyDeletes: plan.heavyDeletes,
      heavyUpdates: plan.heavyUpdates,
    );
  }

  Future<TxnTableCodecContext?> _resolveTxnTableCodec(
    String tableUid,
    String spaceName,
  ) async {
    final mgr = _dataStore.tableMetaManager;
    if (mgr == null) return null;
    final normalized = await mgr.normalizeTableFieldKey(tableUid);
    final ctx = await mgr.getTableContext(TableUid(normalized));
    if (ctx == null) return null;
    final schema = await mgr.getTableSchema(ctx.tableUid);
    if (schema == null) return null;
    final struct =
        await mgr.getStorageFieldStructure(ctx.tableUid, schema: schema);
    return TxnTableCodecContext(
      primaryKeyField: schema.primaryKey,
      fieldStructure: struct,
    );
  }
}
