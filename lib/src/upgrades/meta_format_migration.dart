import 'dart:convert';

import '../core/data_store_impl.dart';
import '../core/wal_manager.dart';
import '../core/yield_controller.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../handler/txn_meta_codec.dart';
import '../handler/wal_meta_codec.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/transaction_models.dart';

/// One-shot migration of WAL / transaction meta from JSON → `.tobf`.
///
/// Crash-safe / idempotent:
/// - Already-valid `.tobf` → only delete residual JSON after decode succeeds.
/// - JSON present without `.tobf` → write TOBF → verify decode → delete JSON.
/// - Never deletes JSON unless the matching `.tobf` decodes successfully.
///
/// **Call site**: blocking [V3Upgrade] only (before version bump), after
/// [KeyManager.initialize]. Not invoked on normal startup once version is
/// current.
final class MetaFormatMigration {
  MetaFormatMigration._();

  /// Migrate [spaceNames] (caller-supplied; do not rediscover during V3).
  static Future<void> migrateAllSpaces(
    DataStoreImpl dataStore, {
    required Iterable<String> spaceNames,
  }) async {
    if (dataStore.config.persistenceMode == PersistenceMode.memory) return;

    final spaces = spaceNames.toSet();
    if (spaces.isEmpty) {
      spaces.add(dataStore.currentSpaceName);
    }

    final yieldController =
        YieldController('meta_format_migration', checkInterval: 1);
    for (final spaceName in spaces) {
      await yieldController.maybeYield();
      await migrateSpace(dataStore, spaceName: spaceName);
    }
  }

  /// Migrate WAL + transaction meta for a single space.
  static Future<void> migrateSpace(
    DataStoreImpl dataStore, {
    required String spaceName,
  }) async {
    await _migrateWalMeta(dataStore, spaceName: spaceName);
    await _migrateTxnMeta(dataStore, spaceName: spaceName);
  }

  static Future<void> _migrateWalMeta(
    DataStoreImpl dataStore, {
    required String spaceName,
  }) async {
    final walRoot = dataStore.pathManager.getWalRootPath(spaceName: spaceName);
    final tobfPath =
        dataStore.pathManager.getWalMainMetaPath(spaceName: spaceName);
    final bakTobfPath =
        dataStore.pathManager.getWalBackupMetaPath(spaceName: spaceName);
    final jsonPath = pathJoin(walRoot, 'meta.json');
    final bakJsonPath = pathJoin(walRoot, 'meta.bak.json');

    final hasTobf = await dataStore.storage.existsFile(tobfPath);
    final hasJson = await dataStore.storage.existsFile(jsonPath);
    final hasBakJson = await dataStore.storage.existsFile(bakJsonPath);

    // Primary TOBF present: delete residual JSON only after decode succeeds.
    if (hasTobf) {
      try {
        await _verifyWalTobf(dataStore, tobfPath);
      } catch (e) {
        if (hasJson || hasBakJson) {
          Logger.error(
            'MetaFormatMigration: WAL TOBF corrupt for space [$spaceName]; '
            'keeping legacy JSON for retry',
            rawError: e,
          );
          rethrow;
        }
        rethrow;
      }
      if (hasJson || hasBakJson) {
        Logger.warn(
          'MetaFormatMigration: residual WAL JSON found for space '
          '[$spaceName]; deleting after TOBF verify',
        );
      }
      await _deleteIfExists(dataStore, jsonPath);
      await _deleteIfExists(dataStore, bakJsonPath);
      return;
    }

    if (!hasJson && !hasBakJson) {
      return; // Fresh space: WalManager will create TOBF on first persist.
    }

    Logger.warn(
      'MetaFormatMigration: migrating WAL meta JSON → TOBF for space '
      '[$spaceName]',
    );

    // Prefer primary JSON; only fall back to bak when primary missing/unreadable.
    WalMeta? meta;
    var recoveredFromBackup = false;
    if (hasJson) {
      try {
        meta = await _loadWalMetaJson(dataStore, jsonPath);
      } catch (e) {
        Logger.warn(
          'MetaFormatMigration: primary WAL JSON unreadable for space '
          '[$spaceName]; will try bak',
          rawError: e,
        );
      }
    }
    if (meta == null && hasBakJson) {
      try {
        meta = await _loadWalMetaJson(dataStore, bakJsonPath);
        recoveredFromBackup = meta != null;
        if (recoveredFromBackup) {
          Logger.warn(
            'MetaFormatMigration: recovered WAL meta from bak.json for space '
            '[$spaceName]',
          );
        }
      } catch (e) {
        Logger.error(
          'MetaFormatMigration: WAL bak.json also unreadable for space '
          '[$spaceName]',
          rawError: e,
        );
      }
    }

    if (meta == null) {
      // Empty residual files only: drop and continue as fresh WAL meta.
      final primaryEmptyFile = hasJson &&
          ((await dataStore.storage.readAsString(jsonPath))?.trim().isEmpty ??
              true);
      final bakEmptyFile = !hasBakJson ||
          ((await dataStore.storage.readAsString(bakJsonPath))
                  ?.trim()
                  .isEmpty ??
              true);
      if (primaryEmptyFile && bakEmptyFile) {
        await _deleteIfExists(dataStore, jsonPath);
        await _deleteIfExists(dataStore, bakJsonPath);
        return;
      }
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'MetaFormatMigration: unreadable WAL JSON for space $spaceName',
        )
      ]);
    }

    final bytes = WalMetaCodec.encodeFile(
      meta,
      encryptionConfig: dataStore.config.encryptionConfig,
    );
    await dataStore.storage.writeAsBytes(tobfPath, bytes, flush: true);
    await _verifyWalTobf(dataStore, tobfPath);

    // Only persist bak.tobf when primary came from backup recovery.
    if (recoveredFromBackup) {
      try {
        await dataStore.storage.writeAsBytes(bakTobfPath, bytes, flush: true);
      } catch (e) {
        Logger.warn(
          'MetaFormatMigration: failed to write WAL bak.tobf for space '
          '[$spaceName]',
          rawError: e,
        );
      }
    }

    await _deleteIfExists(dataStore, jsonPath);
    await _deleteIfExists(dataStore, bakJsonPath);
  }

  static Future<WalMeta?> _loadWalMetaJson(
    DataStoreImpl dataStore,
    String jsonPath,
  ) async {
    final content = await dataStore.storage.readAsString(jsonPath);
    if (content == null || content.isEmpty) return null;
    return WalMeta.fromJson(jsonDecode(content) as Map<String, dynamic>);
  }

  static Future<void> _verifyWalTobf(
    DataStoreImpl dataStore,
    String tobfPath,
  ) async {
    if (!await dataStore.storage.existsFile(tobfPath)) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'MetaFormatMigration: WAL TOBF missing after write: $tobfPath',
        )
      ]);
    }
    final bytes = await dataStore.storage.readAsBytes(tobfPath);
    if (bytes.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'MetaFormatMigration: WAL TOBF empty after write: $tobfPath',
        )
      ]);
    }
    try {
      WalMetaCodec.decodeFile(bytes);
    } catch (e) {
      Logger.error('MetaFormatMigration: WAL TOBF decode failed', rawError: e);
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'MetaFormatMigration: WAL TOBF unreadable after write: $tobfPath',
        )
      ]);
    }
  }

  static Future<void> _migrateTxnMeta(
    DataStoreImpl dataStore, {
    required String spaceName,
  }) async {
    final root =
        dataStore.pathManager.getTransactionRootPath(spaceName: spaceName);
    if (!await dataStore.storage.existsDirectory(root)) return;

    final mainTobf =
        dataStore.pathManager.getTransactionMainMetaPath(spaceName: spaceName);
    final mainJson = pathJoin(root, 'meta.json');

    final hasMainTobf = await dataStore.storage.existsFile(mainTobf);
    final hasMainJson = await dataStore.storage.existsFile(mainJson);

    // Source of truth: activePartitions ∪ currentPartitionIndex (ring wrap;
    // do NOT directory-scan).
    final partitionsToCheck = <int>{};

    if (hasMainTobf) {
      TransactionMainMeta? meta;
      try {
        meta = TxnMetaCodec.decodeMainFile(
            await dataStore.storage.readAsBytes(mainTobf));
        partitionsToCheck.addAll(meta.activePartitions);
        partitionsToCheck.add(meta.currentPartitionIndex);
      } catch (e) {
        Logger.error(
          'MetaFormatMigration: txn main TOBF unreadable for space '
          '[$spaceName]',
          rawError: e,
        );
        if (hasMainJson) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message: 'MetaFormatMigration: txn main TOBF corrupt for space '
                  '$spaceName; legacy JSON retained for retry',
            )
          ]);
        }
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'MetaFormatMigration: txn main TOBF unreadable for space '
                '$spaceName',
          )
        ]);
      }
      // Decode succeeded — safe to drop residual JSON.
      if (hasMainJson) {
        Logger.warn(
          'MetaFormatMigration: residual txn main JSON for space '
          '[$spaceName]; deleting after TOBF verify',
        );
        await _deleteIfExists(dataStore, mainJson);
      }
    } else if (hasMainJson) {
      Logger.warn(
        'MetaFormatMigration: migrating txn main meta JSON → TOBF for space '
        '[$spaceName]',
      );
      final content = await dataStore.storage.readAsString(mainJson);
      if (content == null || content.isEmpty) {
        await _deleteIfExists(dataStore, mainJson);
      } else {
        final meta = TransactionMainMeta.fromJson(
            jsonDecode(content) as Map<String, dynamic>);
        partitionsToCheck.addAll(meta.activePartitions);
        partitionsToCheck.add(meta.currentPartitionIndex);
        final bytes = TxnMetaCodec.encodeMainFile(
          meta,
          encryptionConfig: dataStore.config.encryptionConfig,
        );
        await dataStore.storage.writeAsBytes(mainTobf, bytes, flush: true);
        try {
          TxnMetaCodec.decodeMainFile(
              await dataStore.storage.readAsBytes(mainTobf));
        } catch (e) {
          Logger.error(
            'MetaFormatMigration: txn main TOBF verify failed for space '
            '[$spaceName]',
            rawError: e,
          );
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'MetaFormatMigration: txn main TOBF unreadable after write '
                  'for space $spaceName',
            )
          ]);
        }
        await _deleteIfExists(dataStore, mainJson);
      }
    }

    if (partitionsToCheck.isEmpty) return;

    await _migrateTxnPartitionMetas(
      dataStore,
      spaceName: spaceName,
      knownPartitions: partitionsToCheck,
    );
  }

  /// Migrate partition metas listed in [knownPartitions] only.
  static Future<void> _migrateTxnPartitionMetas(
    DataStoreImpl dataStore, {
    required String spaceName,
    required Set<int> knownPartitions,
  }) async {
    final yieldController = YieldController('meta_format_txn_partitions');
    final indexes = knownPartitions.toList()..sort();
    DbException? firstError;

    for (final partitionIndex in indexes) {
      await yieldController.maybeYield();
      final dirIndex = partitionIndex ~/ dataStore.maxEntriesPerDir;
      final partitionDir = dataStore.pathManager.getTransactionPartitionDirPath(
        dirIndex,
        partitionIndex,
        spaceName: spaceName,
      );
      final tobf = dataStore.pathManager.getTransactionPartitionMetaPath(
        dirIndex,
        partitionIndex,
        spaceName: spaceName,
      );
      final json = pathJoin(partitionDir, 'meta.json');

      final hasTobf = await dataStore.storage.existsFile(tobf);
      final hasJson = await dataStore.storage.existsFile(json);

      if (hasTobf) {
        // Verify before deleting residual JSON.
        try {
          final bytes = await dataStore.storage.readAsBytes(tobf);
          TxnMetaCodec.decodePartitionFile(bytes);
          if (hasJson) {
            await _deleteIfExists(dataStore, json);
          }
        } catch (e) {
          Logger.error(
            'MetaFormatMigration: txn partition TOBF corrupt p$partitionIndex '
            'space [$spaceName]; keeping JSON if present',
            rawError: e,
          );
          firstError ??= DbException([
            GeneralStatus(
              type: ResultType.engError,
              message: 'MetaFormatMigration: txn partition TOBF corrupt '
                  'p$partitionIndex space $spaceName',
            )
          ]);
        }
        continue;
      }

      if (!hasJson) continue;

      try {
        final content = await dataStore.storage.readAsString(json);
        if (content == null || content.isEmpty) {
          await _deleteIfExists(dataStore, json);
          continue;
        }
        final meta = TransactionPartitionMeta.fromJson(
            jsonDecode(content) as Map<String, dynamic>);
        final bytes = TxnMetaCodec.encodePartitionFile(
          meta,
          encryptionConfig: dataStore.config.encryptionConfig,
        );
        await dataStore.storage.writeAsBytes(tobf, bytes, flush: true);
        // Disk verify before deleting JSON (sample = every newly written file;
        // partition metas are tiny so cost is negligible vs data-loss risk).
        final written = await dataStore.storage.readAsBytes(tobf);
        TxnMetaCodec.decodePartitionFile(written);
        await _deleteIfExists(dataStore, json);
      } catch (e) {
        Logger.error(
          'MetaFormatMigration: failed to migrate txn partition meta '
          'p$partitionIndex space [$spaceName]',
          rawError: e,
        );
        // Leave JSON; remove possibly corrupt TOBF so retry rewrites cleanly.
        try {
          if (await dataStore.storage.existsFile(tobf)) {
            await dataStore.storage.deleteFile(tobf);
          }
        } catch (_) {}
        firstError ??= DbException.wrap(
          e,
          fallbackType: ResultType.engError,
          fallbackMessage: 'MetaFormatMigration: txn partition meta failed '
              'p$partitionIndex space $spaceName',
        );
      }
    }

    if (firstError != null) throw firstError;
  }

  static Future<void> _deleteIfExists(
    DataStoreImpl dataStore,
    String filePath,
  ) async {
    try {
      if (await dataStore.storage.existsFile(filePath)) {
        await dataStore.storage.deleteFile(filePath);
      }
    } catch (e) {
      Logger.warn(
        'MetaFormatMigration: failed to delete $filePath',
        rawError: e,
      );
    }
  }
}
