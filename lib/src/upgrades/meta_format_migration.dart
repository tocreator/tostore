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

/// One-shot migration of WAL / transaction meta from JSON -> `.tobf`.
///
/// Crash-safe / idempotent (safe to re-run after interrupt):
/// - Valid `.tobf` -> delete residual JSON only after decode succeeds.
/// - Corrupt/partial `.tobf` **with** legacy JSON -> delete TOBF, rewrite from
///   JSON, verify, then delete JSON.
/// - Corrupt/partial `.tobf` **without** JSON -> delete TOBF and continue as
///   fresh (never hard-fail the upgrade solely due to a half-written frame).
/// - Unreadable legacy JSON -> drop empty residuals / skip poison files and
///   continue (WalManager / Txn runtime recreate as needed).
/// - Write-then-verify failure -> keep JSON, delete partial TOBF, rethrow so
///   the next startup retries the same rewrite path.
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
      final y1 = yieldController.maybeYield();
      if (y1 != null) await y1;
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

    var needRewriteFromJson = !hasTobf && (hasJson || hasBakJson);

    if (hasTobf) {
      try {
        await _tryDecodeWalTobf(dataStore, tobfPath);
        if (hasJson || hasBakJson) {
          Logger.info(
            'MetaFormatMigration: residual WAL JSON found for space '
            '[$spaceName]; deleting after TOBF verify',
          );
        }
        await _deleteIfExists(dataStore, jsonPath);
        await _deleteIfExists(dataStore, bakJsonPath);
        return;
      } catch (e) {
        if (hasJson || hasBakJson) {
          Logger.warn(
            'MetaFormatMigration: WAL TOBF corrupt/partial for space '
            '[$spaceName]; recovering from legacy JSON',
            rawError: e,
          );
          await _deleteIfExists(dataStore, tobfPath);
          await _deleteIfExists(dataStore, bakTobfPath);
          needRewriteFromJson = true;
        } else {
          Logger.warn(
            'MetaFormatMigration: WAL TOBF corrupt for space [$spaceName] '
            'with no legacy JSON; removing and treating as fresh',
            rawError: e,
          );
          await _deleteIfExists(dataStore, tobfPath);
          await _deleteIfExists(dataStore, bakTobfPath);
          return;
        }
      }
    }

    if (!needRewriteFromJson) {
      return; // Fresh space: WalManager will create TOBF on first persist.
    }

    Logger.info(
      'MetaFormatMigration: migrating WAL meta JSON -> TOBF for space '
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
      // Empty or poison JSON: drop residuals and continue as fresh WAL.
      // Never hard-fail V3 solely because legacy WAL meta JSON is unreadable.
      Logger.warn(
        'MetaFormatMigration: WAL JSON unusable for space [$spaceName]; '
        'treating as fresh WAL meta',
      );
      await _deleteIfExists(dataStore, jsonPath);
      await _deleteIfExists(dataStore, bakJsonPath);
      await _deleteIfExists(dataStore, tobfPath);
      await _deleteIfExists(dataStore, bakTobfPath);
      return;
    }

    final bytes = WalMetaCodec.encodeFile(
      meta,
      encryptionConfig: dataStore.config.encryptionConfig,
    );
    await dataStore.storage.writeAsBytes(tobfPath, bytes, flush: true);
    try {
      await _tryDecodeWalTobf(dataStore, tobfPath);
    } catch (e) {
      // Keep JSON; remove partial TOBF so retry rewrites from JSON.
      await _deleteIfExists(dataStore, tobfPath);
      await _deleteIfExists(dataStore, bakTobfPath);
      rethrow;
    }

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

  static Future<void> _tryDecodeWalTobf(
    DataStoreImpl dataStore,
    String tobfPath,
  ) async {
    if (!await dataStore.storage.existsFile(tobfPath)) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'MetaFormatMigration: WAL TOBF missing: $tobfPath',
        )
      ]);
    }
    final bytes = await dataStore.storage.readAsBytes(tobfPath);
    if (bytes.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'MetaFormatMigration: WAL TOBF empty: $tobfPath',
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
          message: 'MetaFormatMigration: WAL TOBF unreadable: $tobfPath',
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

    // Source of truth: activePartitions U currentPartitionIndex (ring wrap;
    // do NOT directory-scan).
    final partitionsToCheck = <int>{};
    var needRewriteMainFromJson = !hasMainTobf && hasMainJson;

    if (hasMainTobf) {
      try {
        final meta = TxnMetaCodec.decodeMainFile(
            await dataStore.storage.readAsBytes(mainTobf));
        partitionsToCheck.addAll(meta.activePartitions);
        partitionsToCheck.add(meta.currentPartitionIndex);
        if (hasMainJson) {
          Logger.info(
            'MetaFormatMigration: residual txn main JSON for space '
            '[$spaceName]; deleting after TOBF verify',
          );
          await _deleteIfExists(dataStore, mainJson);
        }
      } catch (e) {
        if (hasMainJson) {
          Logger.warn(
            'MetaFormatMigration: txn main TOBF corrupt/partial for space '
            '[$spaceName]; recovering from legacy JSON',
            rawError: e,
          );
          await _deleteIfExists(dataStore, mainTobf);
          needRewriteMainFromJson = true;
        } else {
          // No JSON: drop half-written TOBF and continue as fresh main meta.
          Logger.warn(
            'MetaFormatMigration: txn main TOBF corrupt for space '
            '[$spaceName] with no legacy JSON; removing and treating as fresh',
            rawError: e,
          );
          await _deleteIfExists(dataStore, mainTobf);
          partitionsToCheck.add(0);
        }
      }
    }

    if (needRewriteMainFromJson) {
      Logger.info(
        'MetaFormatMigration: migrating txn main meta JSON -> TOBF for space '
        '[$spaceName]',
      );
      final rewritten = await _rewriteTxnMainFromJson(
        dataStore,
        spaceName: spaceName,
        mainTobf: mainTobf,
        mainJson: mainJson,
        partitionsToCheck: partitionsToCheck,
      );
      if (!rewritten) {
        // Poison/empty JSON -- continue with default partition 0.
        partitionsToCheck.add(0);
      }
    }

    if (partitionsToCheck.isEmpty) return;

    await _migrateTxnPartitionMetas(
      dataStore,
      spaceName: spaceName,
      knownPartitions: partitionsToCheck,
    );
  }

  /// Returns true when main TOBF was written and verified from JSON.
  static Future<bool> _rewriteTxnMainFromJson(
    DataStoreImpl dataStore, {
    required String spaceName,
    required String mainTobf,
    required String mainJson,
    required Set<int> partitionsToCheck,
  }) async {
    final content = await dataStore.storage.readAsString(mainJson);
    if (content == null || content.trim().isEmpty) {
      await _deleteIfExists(dataStore, mainJson);
      return false;
    }

    late final TransactionMainMeta meta;
    try {
      meta = TransactionMainMeta.fromJson(
          jsonDecode(content) as Map<String, dynamic>);
    } catch (e) {
      Logger.warn(
        'MetaFormatMigration: txn main JSON unreadable for space '
        '[$spaceName]; treating as fresh',
        rawError: e,
      );
      // Leave poison JSON for inspection; do not block upgrade.
      return false;
    }

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
      // Keep JSON; remove partial TOBF so next startup rewrites cleanly.
      await _deleteIfExists(dataStore, mainTobf);
      rethrow;
    }
    await _deleteIfExists(dataStore, mainJson);
    return true;
  }

  /// Migrate partition metas listed in [knownPartitions] only.
  static Future<void> _migrateTxnPartitionMetas(
    DataStoreImpl dataStore, {
    required String spaceName,
    required Set<int> knownPartitions,
  }) async {
    final yieldController = YieldController('meta_format_txn_partitions');
    final indexes = knownPartitions.toList()..sort();
    DbException? retryableError;

    for (final partitionIndex in indexes) {
      final y2 = yieldController.maybeYield();
      if (y2 != null) await y2;
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

      var needRewriteFromJson = !hasTobf && hasJson;

      if (hasTobf) {
        try {
          final bytes = await dataStore.storage.readAsBytes(tobf);
          TxnMetaCodec.decodePartitionFile(bytes);
          if (hasJson) {
            await _deleteIfExists(dataStore, json);
          }
          continue;
        } catch (e) {
          if (hasJson) {
            Logger.warn(
              'MetaFormatMigration: txn partition TOBF corrupt/partial '
              'p$partitionIndex space [$spaceName]; recovering from JSON',
              rawError: e,
            );
            await _deleteIfExists(dataStore, tobf);
            needRewriteFromJson = true;
          } else {
            // No JSON: drop half-written TOBF and continue (fresh partition).
            Logger.warn(
              'MetaFormatMigration: txn partition TOBF corrupt '
              'p$partitionIndex space [$spaceName]; no legacy JSON -- '
              'removing and continuing',
              rawError: e,
            );
            await _deleteIfExists(dataStore, tobf);
            continue;
          }
        }
      }

      if (!needRewriteFromJson) continue;

      try {
        final content = await dataStore.storage.readAsString(json);
        if (content == null || content.trim().isEmpty) {
          await _deleteIfExists(dataStore, json);
          continue;
        }

        late final TransactionPartitionMeta meta;
        try {
          meta = TransactionPartitionMeta.fromJson(
              jsonDecode(content) as Map<String, dynamic>);
        } catch (e) {
          Logger.warn(
            'MetaFormatMigration: txn partition JSON unreadable '
            'p$partitionIndex space [$spaceName]; skipping',
            rawError: e,
          );
          // Leave poison JSON; do not block the rest of V3.
          continue;
        }

        final bytes = TxnMetaCodec.encodePartitionFile(
          meta,
          encryptionConfig: dataStore.config.encryptionConfig,
        );
        await dataStore.storage.writeAsBytes(tobf, bytes, flush: true);
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
        await _deleteIfExists(dataStore, tobf);
        // Retryable: JSON still present -- surface after sweep so V3 re-runs.
        retryableError ??= DbException.wrap(
          e,
          fallbackType: ResultType.engError,
          fallbackMessage: 'MetaFormatMigration: txn partition meta failed '
              'p$partitionIndex space $spaceName',
        );
      }
    }

    if (retryableError != null) throw retryableError;
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
