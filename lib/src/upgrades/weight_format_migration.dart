import '../core/data_store_impl.dart';
import '../core/yield_controller.dart';
import '../handler/logger.dart';
import '../handler/weight_snapshot_codec.dart';
import '../model/data_store_config.dart';
import 'legacy_model/pre_v3.dart';

/// Async, non-blocking migration of legacy `cache_weights.json` → internal KV.
///
/// - Does **not** block V3 / normal startup.
/// - Formal [WeightManager] never reads JSON; only this upgrade path does.
/// - Path + JSON parse live in [LegacyWeightPaths] / [LegacyCacheWeightsJson].
/// - Parse/write failures are logged and skipped; data loss is acceptable.
/// - Deletes the legacy file immediately after a successful KV write.
final class WeightFormatMigration {
  WeightFormatMigration._();

  /// Fire-and-forget entry; safe to call via `unawaited`.
  static Future<void> migrateAsync(
    DataStoreImpl dataStore, {
    required Iterable<String> spaceNames,
  }) async {
    if (dataStore.config.persistenceMode == PersistenceMode.memory) return;

    final root = dataStore.instancePath;
    if (root == null) return;

    final spaces = spaceNames.toSet();
    if (spaces.isEmpty) {
      spaces.add(dataStore.currentSpaceName);
    }

    final yieldController =
        YieldController('weight_format_migration', checkInterval: 1);

    for (final spaceName in spaces) {
      await yieldController.maybeYield();
      try {
        await _migrateSpace(dataStore, root: root, spaceName: spaceName);
      } catch (e) {
        Logger.warn(
          'WeightFormatMigration: failed for space [$spaceName]; continuing',
          rawError: e,
        );
      }
    }
  }

  static Future<void> _migrateSpace(
    DataStoreImpl dataStore, {
    required String root,
    required String spaceName,
  }) async {
    final jsonPath = LegacyWeightPaths.spaceJson(root, spaceName);

    if (!await dataStore.storage.existsFile(jsonPath)) return;

    Logger.warn(
      'WeightFormatMigration: migrating cache_weights.json → KV '
      'for space [$spaceName]',
    );

    final content = await dataStore.storage.readAsString(jsonPath);
    final snapshot = LegacyCacheWeightsJson.tryParse(content ?? '');
    if (snapshot == null) {
      // Empty/corrupt — drop leftover file.
      await _deleteIfExists(dataStore, jsonPath);
      return;
    }

    final bytes = WeightSnapshotCodec.encode(snapshot);

    if (spaceName == dataStore.currentSpaceName) {
      await dataStore.internalKv.set(
        WeightSnapshotCodec.internalKvKey,
        bytes,
        isGlobal: false,
      );
      // Best-effort merge into live WeightManager memory.
      dataStore.weightManager?.applySnapshot(snapshot, markDirty: false);
    } else {
      final temp = DataStoreImpl(
        dbPath: dataStore.config.dbPath,
        dbName: dataStore.config.dbName,
        config: dataStore.config.copyWith(spaceName: spaceName),
        isMigrationInstance: true,
      );
      try {
        await temp.initialize(applyActiveSpaceOnDefault: false);
        await temp.internalKv.set(
          WeightSnapshotCodec.internalKvKey,
          bytes,
          isGlobal: false,
        );
      } finally {
        await temp.close();
      }
    }

    await _deleteIfExists(dataStore, jsonPath);
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
        'WeightFormatMigration: failed to delete $path',
        rawError: e,
      );
    }
  }
}
