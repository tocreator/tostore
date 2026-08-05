import '../core/data_store_impl.dart';
import '../core/yield_controller.dart';
import '../handler/logger.dart';
import '../handler/weight_snapshot_codec.dart';
import '../model/data_store_config.dart';
import 'legacy_model/pre_v3.dart';

/// Async, non-blocking migration of legacy `cache_weights.json` → `access_weights.tobf`.
///
/// - Does **not** block V3 / normal startup.
/// - Formal [WeightManager] never reads JSON; only this upgrade path does.
/// - Path + JSON parse live in [LegacyWeightPaths] / [LegacyCacheWeightsJson].
/// - Parse/write failures are logged and skipped; data loss is acceptable.
/// - Deletes the legacy JSON immediately after a successful tobf write.
/// - Unpublished KV-table experiments are not migrated (never shipped).
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
      final y1 = yieldController.maybeYield();
      if (y1 != null) await y1;
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
    final tobfPath = dataStore.pathManager.getAccessWeightsPath(
      rootPath: root,
      spaceName: spaceName,
    );

    // Already on file-backed binary format — just drop leftover JSON if any.
    if (await dataStore.storage.existsFile(tobfPath)) {
      await _deleteIfExists(dataStore, jsonPath);
      return;
    }

    if (!await dataStore.storage.existsFile(jsonPath)) return;

    Logger.info(
      'WeightFormatMigration: migrating cache_weights.json → access_weights.tobf '
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
    await dataStore.storage.writeAsBytes(tobfPath, bytes, flush: true);

    if (spaceName == dataStore.currentSpaceName) {
      // Best-effort merge into live WeightManager memory.
      dataStore.weightManager?.applySnapshot(snapshot, markDirty: false);
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
