import 'dart:convert';

import 'package:path/path.dart' as p;

import '../core/data_store_impl.dart';
import '../core/yield_controller.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../handler/migration_meta_codec.dart';
import '../handler/migration_task_codec.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/meta_info.dart';
import '../model/migration_meta.dart';
import '../model/migration_task.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';

/// One-shot migration of migration_meta / migration tasks from JSON → `.tobf`.
///
/// Crash-safe / idempotent (safe to re-run after interrupt):
/// - Valid `.tobf` with non-empty mapping → migrate **only** mapped tasks
///   (no directory scan).
/// - Valid `.tobf` with **empty** mapping → one cheap check: if any `dir_*`
///   exists, scan once for orphan tasks (crash before meta update).
/// - Corrupt/partial `.tobf` **with** legacy JSON → delete TOBF, rewrite from
///   JSON, verify, then delete JSON.
/// - Both meta files unreadable / missing → scan once to rebuild mapping.
/// - Never deletes JSON unless the matching `.tobf` decodes successfully.
/// - Partial TOBF left by a failed verify is deleted before rethrow so the
///   next run always prefers residual JSON.
///
/// Legacy JSON parsing lives only here (and v1→v2 shaping in [MigrationMeta.fromJson])
/// so runtime [MigrationManager] stays free of JSON paths.
///
/// **Call site**: blocking [V3Upgrade] only (before version bump), after
/// [KeyManager.initialize] and [MetaFormatMigration].
final class MigrationFormatMigration {
  MigrationFormatMigration._();

  static Future<void> migrate(DataStoreImpl dataStore) async {
    if (dataStore.config.persistenceMode == PersistenceMode.memory) return;

    final migrationsRoot = dataStore.pathManager.getMigrationsPath();
    final tobfMeta = dataStore.pathManager.getMigrationMetaPath();
    final jsonMeta = pathJoin(migrationsRoot, 'migration_meta.json');

    final hasTobf = await dataStore.storage.existsFile(tobfMeta);
    final hasJson = await dataStore.storage.existsFile(jsonMeta);

    // Fast path: no meta files at all.
    if (!hasTobf && !hasJson) {
      if (!await dataStore.storage.existsDirectory(migrationsRoot)) return;
      if (!await _hasAnyTaskDir(dataStore, migrationsRoot)) return;

      Logger.warn(
        'MigrationFormatMigration: no migration_meta; scanning orphan tasks',
      );
      final recovered = await _rebuildMetaByScanningTasks(dataStore);
      if (recovered.directoryMapping.idToDir.isEmpty) return;
      await _persistMetaTobf(dataStore, tobfMeta, recovered);
      await _migrateTasks(dataStore, recovered);
      return;
    }

    MigrationMeta? meta;
    var needRewriteFromJson = !hasTobf && hasJson;
    var needScanRecovery = false;

    if (hasTobf) {
      try {
        meta = await _tryDecodeMetaTobf(dataStore, tobfMeta);
      } catch (e) {
        if (hasJson) {
          Logger.warn(
            'MigrationFormatMigration: migration_meta.tobf corrupt/partial; '
            'recovering from legacy JSON',
            rawError: e,
          );
          await _deleteIfExists(dataStore, tobfMeta);
          needRewriteFromJson = true;
        } else {
          Logger.warn(
            'MigrationFormatMigration: migration_meta.tobf corrupt and no '
            'legacy JSON; will rebuild mapping by scanning task files',
            rawError: e,
          );
          await _deleteIfExists(dataStore, tobfMeta);
          needScanRecovery = true;
        }
      }
      if (meta != null && hasJson) {
        Logger.warn(
          'MigrationFormatMigration: residual migration_meta.json found; '
          'deleting after TOBF verify',
        );
        await _deleteIfExists(dataStore, jsonMeta);
      }
    }

    if (needRewriteFromJson) {
      Logger.warn(
        'MigrationFormatMigration: migrating migration_meta.json → .tobf',
      );
      meta = await _loadMetaJson(dataStore, jsonMeta);
      if (meta == null) {
        final empty =
            (await dataStore.storage.readAsString(jsonMeta))?.trim().isEmpty ??
                true;
        if (empty) {
          await _deleteIfExists(dataStore, jsonMeta);
        } else {
          Logger.warn(
            'MigrationFormatMigration: migration_meta.json unreadable; '
            'will rebuild mapping by scanning task files',
          );
        }
        needScanRecovery = true;
      } else {
        await _persistMetaTobf(dataStore, tobfMeta, meta);
        await _deleteIfExists(dataStore, jsonMeta);
      }
    }

    if (needScanRecovery || meta == null) {
      Logger.warn(
        'MigrationFormatMigration: rebuilding migration_meta from task scan',
      );
      meta = await _rebuildMetaByScanningTasks(dataStore);
      await _persistMetaTobf(dataStore, tobfMeta, meta);
      if (await dataStore.storage.existsFile(jsonMeta)) {
        try {
          await _tryDecodeMetaTobf(dataStore, tobfMeta);
          await _deleteIfExists(dataStore, jsonMeta);
        } catch (_) {
          // Keep JSON; next run retries.
        }
      }
    }

    // Healthy meta with empty mapping: one orphan check (not a full always-scan).
    if (meta.directoryMapping.idToDir.isEmpty &&
        await _hasAnyTaskDir(dataStore, migrationsRoot)) {
      Logger.warn(
        'MigrationFormatMigration: meta mapping empty but task dirs exist; '
        'scanning for orphans',
      );
      final recovered = await _rebuildMetaByScanningTasks(dataStore);
      if (recovered.directoryMapping.idToDir.isNotEmpty) {
        // scan recovery only rebuilds directoryMapping.
        meta = recovered;
        await _persistMetaTobf(dataStore, tobfMeta, meta);
      }
    }

    await _migrateTasks(dataStore, meta);
  }

  static Future<bool> _hasAnyTaskDir(
    DataStoreImpl dataStore,
    String migrationsRoot,
  ) async {
    if (!await dataStore.storage.existsDirectory(migrationsRoot)) return false;
    final entries = await dataStore.storage.listDirectory(migrationsRoot);
    for (final entry in entries) {
      final base = p.basename(entry);
      if (base.startsWith('dir_') &&
          await dataStore.storage.existsDirectory(
            entry.contains('/') || entry.contains('\\')
                ? entry
                : pathJoin(migrationsRoot, entry),
          )) {
        return true;
      }
    }
    return false;
  }

  static Future<void> _persistMetaTobf(
    DataStoreImpl dataStore,
    String tobfMeta,
    MigrationMeta meta,
  ) async {
    final bytes = MigrationMetaCodec.encodeFile(
      meta,
      encryptionConfig: dataStore.config.encryptionConfig,
    );
    await dataStore.storage.writeAsBytes(tobfMeta, bytes, flush: true);
    await _tryDecodeMetaTobf(dataStore, tobfMeta);
  }

  /// Rebuild [MigrationMeta.directoryMapping] from on-disk task files.
  ///
  /// [MigrationMeta.keyMigrationInfo] is a new field not present on legacy
  /// online databases; scan recovery always leaves it null.
  static Future<MigrationMeta> _rebuildMetaByScanningTasks(
    DataStoreImpl dataStore,
  ) async {
    final idToDir = <String, int>{};
    await _discoverTaskFiles(dataStore, idToDir);

    final dirToFileCount = <int, int>{};
    for (final dirIndex in idToDir.values) {
      dirToFileCount[dirIndex] = (dirToFileCount[dirIndex] ?? 0) + 1;
    }

    Logger.info(
      'MigrationFormatMigration: scanned ${idToDir.length} task file(s) '
      'across ${dirToFileCount.length} dir(s) for meta recovery',
    );

    return MigrationMeta(
      directoryMapping: DirectoryMappingString(
        idToDir: idToDir,
        dirToFileCount: dirToFileCount,
      ),
    );
  }

  /// Migrate tasks listed in [meta.directoryMapping] only — no directory scan.
  static Future<void> _migrateTasks(
    DataStoreImpl dataStore,
    MigrationMeta meta,
  ) async {
    final entries = Map<String, int>.from(meta.directoryMapping.idToDir);
    if (entries.isEmpty) return;

    final yieldController =
        YieldController('migration_format_migration', checkInterval: 1);

    final droppedTaskIds = <String>[];
    DbException? firstTaskError;

    for (final entry in entries.entries) {
      await yieldController.maybeYield();
      try {
        final outcome = await _migrateOneTask(
          dataStore,
          dirIndex: entry.value,
          taskId: entry.key,
        );
        if (outcome == _TaskMigrateOutcome.dropped) {
          droppedTaskIds.add(entry.key);
        }
      } catch (e) {
        Logger.error(
          'MigrationFormatMigration: task migration failed for '
          'taskId[${entry.key}]; continuing other tasks',
          rawError: e,
        );
        firstTaskError ??= DbException.wrap(
          e,
          fallbackType: ResultType.engError,
          fallbackMessage:
              'MigrationFormatMigration: task migration failed for '
              'taskId ${entry.key}',
        );
      }
    }

    // Prune mapping for tasks that are gone / unrecoverable so version bump
    // does not leave stale hasMigrationTask / phantom pending entries.
    if (droppedTaskIds.isNotEmpty) {
      var mapping = meta.directoryMapping;
      for (final taskId in droppedTaskIds) {
        mapping = mapping.removeId(taskId);
      }
      try {
        await _persistMetaTobf(
          dataStore,
          dataStore.pathManager.getMigrationMetaPath(),
          meta.copyWith(directoryMapping: mapping),
        );
      } catch (e) {
        Logger.warn(
          'MigrationFormatMigration: failed to prune dropped tasks from meta',
          rawError: e,
        );
      }
    }

    if (firstTaskError != null) throw firstTaskError;
  }

  /// Discover `task_*.json` / `task_*.tobf` under `dir_*`.
  static Future<void> _discoverTaskFiles(
    DataStoreImpl dataStore,
    Map<String, int> out,
  ) async {
    final root = dataStore.pathManager.getMigrationsPath();
    if (!await dataStore.storage.existsDirectory(root)) return;

    final dirs = await dataStore.storage.listDirectory(root);
    for (final dirEntry in dirs) {
      final base = p.basename(dirEntry);
      if (!base.startsWith('dir_')) continue;
      final dirIndex = int.tryParse(base.substring(4));
      if (dirIndex == null) continue;
      final dirPath = dirEntry.contains('/') || dirEntry.contains('\\')
          ? dirEntry
          : pathJoin(root, dirEntry);
      if (!await dataStore.storage.existsDirectory(dirPath)) continue;
      final files = await dataStore.storage.listDirectory(dirPath);
      for (final fileEntry in files) {
        final name = p.basename(fileEntry);
        if (!name.startsWith('task_')) continue;
        String? taskId;
        if (name.endsWith('.json')) {
          taskId = name.substring(5, name.length - 5);
        } else if (name.endsWith('.tobf')) {
          taskId = name.substring(5, name.length - 5);
        }
        if (taskId == null || taskId.isEmpty) continue;
        out.putIfAbsent(taskId, () => dirIndex);
      }
    }
  }

  static Future<_TaskMigrateOutcome> _migrateOneTask(
    DataStoreImpl dataStore, {
    required int dirIndex,
    required String taskId,
  }) async {
    final migrationsRoot = dataStore.pathManager.getMigrationsPath();
    final tobfPath =
        dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);
    final jsonPath =
        pathJoin(migrationsRoot, 'dir_$dirIndex', 'task_$taskId.json');

    final hasTobf = await dataStore.storage.existsFile(tobfPath);
    final hasJson = await dataStore.storage.existsFile(jsonPath);

    if (!hasTobf && !hasJson) {
      // Mapping ghost — nothing on disk.
      return _TaskMigrateOutcome.dropped;
    }

    var needRewriteFromJson = !hasTobf && hasJson;

    if (hasTobf) {
      try {
        await _tryDecodeTaskTobf(dataStore, tobfPath);
        if (hasJson) {
          await _deleteIfExists(dataStore, jsonPath);
        }
        return _TaskMigrateOutcome.ok;
      } catch (e) {
        if (hasJson) {
          Logger.warn(
            'MigrationFormatMigration: task TOBF corrupt/partial for '
            'taskId[$taskId]; recovering from legacy JSON',
            rawError: e,
          );
          await _deleteIfExists(dataStore, tobfPath);
          needRewriteFromJson = true;
        } else {
          Logger.warn(
            'MigrationFormatMigration: task TOBF corrupt for taskId[$taskId] '
            'and no legacy JSON; removing partial file',
            rawError: e,
          );
          await _deleteIfExists(dataStore, tobfPath);
          return _TaskMigrateOutcome.dropped;
        }
      }
    }

    if (!needRewriteFromJson) return _TaskMigrateOutcome.ok;

    Logger.warn(
      'MigrationFormatMigration: migrating task_$taskId.json → .tobf',
    );

    final task = await _loadTaskJson(dataStore, jsonPath);
    if (task == null) {
      final empty =
          (await dataStore.storage.readAsString(jsonPath))?.trim().isEmpty ??
              true;
      if (empty) {
        await _deleteIfExists(dataStore, jsonPath);
        return _TaskMigrateOutcome.dropped;
      }
      // Non-empty but unreadable: leave file for inspection, drop mapping so
      // version bump is not blocked by a permanent poison pill.
      Logger.warn(
        'MigrationFormatMigration: unreadable task JSON for taskId[$taskId]; '
        'dropping from mapping and continuing',
      );
      return _TaskMigrateOutcome.dropped;
    }

    final bytes = MigrationTaskCodec.encodeFile(
      task,
      encryptionConfig: dataStore.config.encryptionConfig,
    );
    await dataStore.storage.writeAsBytes(tobfPath, bytes, flush: true);
    try {
      await _tryDecodeTaskTobf(dataStore, tobfPath);
    } catch (e) {
      // Keep JSON; remove partial TOBF so retry always rewrites from JSON.
      await _deleteIfExists(dataStore, tobfPath);
      rethrow;
    }
    await _deleteIfExists(dataStore, jsonPath);
    return _TaskMigrateOutcome.ok;
  }

  static Future<MigrationMeta?> _loadMetaJson(
    DataStoreImpl dataStore,
    String jsonPath,
  ) async {
    try {
      final content = await dataStore.storage.readAsString(jsonPath);
      if (content == null || content.isEmpty) return null;
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      return MigrationMeta.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      Logger.warn(
        'MigrationFormatMigration: failed to parse migration_meta.json',
        rawError: e,
      );
      return null;
    }
  }

  static Future<MigrationTask?> _loadTaskJson(
    DataStoreImpl dataStore,
    String jsonPath,
  ) async {
    try {
      final content = await dataStore.storage.readAsString(jsonPath);
      if (content == null || content.isEmpty) return null;
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      return MigrationTask.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      Logger.warn(
        'MigrationFormatMigration: failed to parse task JSON $jsonPath',
        rawError: e,
      );
      return null;
    }
  }

  static Future<MigrationMeta> _tryDecodeMetaTobf(
    DataStoreImpl dataStore,
    String tobfPath,
  ) async {
    if (!await dataStore.storage.existsFile(tobfPath)) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'MigrationFormatMigration: migration_meta.tobf missing: $tobfPath',
        )
      ]);
    }
    final bytes = await dataStore.storage.readAsBytes(tobfPath);
    if (bytes.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'MigrationFormatMigration: migration_meta.tobf empty: $tobfPath',
        )
      ]);
    }
    try {
      return MigrationMetaCodec.decodeFile(bytes);
    } catch (e) {
      Logger.error(
          'MigrationFormatMigration: migration_meta TOBF decode failed',
          rawError: e);
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'MigrationFormatMigration: migration_meta.tobf unreadable: $tobfPath',
        )
      ]);
    }
  }

  static Future<void> _tryDecodeTaskTobf(
    DataStoreImpl dataStore,
    String tobfPath,
  ) async {
    if (!await dataStore.storage.existsFile(tobfPath)) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'MigrationFormatMigration: task TOBF missing: $tobfPath',
        )
      ]);
    }
    final bytes = await dataStore.storage.readAsBytes(tobfPath);
    if (bytes.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'MigrationFormatMigration: task TOBF empty: $tobfPath',
        )
      ]);
    }
    try {
      MigrationTaskCodec.decodeFile(bytes);
    } catch (e) {
      Logger.error('MigrationFormatMigration: task TOBF decode failed',
          rawError: e);
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'MigrationFormatMigration: task TOBF unreadable: $tobfPath',
        )
      ]);
    }
  }

  static Future<void> _deleteIfExists(
    DataStoreImpl dataStore,
    String path,
  ) async {
    try {
      if (await dataStore.storage.existsFile(path)) {
        await dataStore.storage.deleteFile(path);
      }
    } catch (e) {
      Logger.warn(
        'MigrationFormatMigration: failed to delete residual file $path',
        rawError: e,
      );
    }
  }
}

enum _TaskMigrateOutcome { ok, dropped }
