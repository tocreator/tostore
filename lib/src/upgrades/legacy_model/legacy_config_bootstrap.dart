import '../../core/data_store_impl.dart';
import '../../handler/logger.dart';
import '../../model/global_config.dart';
import '../../model/space_config.dart';
import 'legacy_config_paths.dart';
import 'legacy_global_config_json.dart';
import 'legacy_space_config_json.dart';

/// Read-only loaders for pre-TOBF JSON configs.
///
/// Used by the hot path **only** when `*.tobf` is absent (pre-v3 databases),
/// and by V3 to consume `tableDirectoryMap` before JSON is deleted.
/// Never writes TOBF and never deletes JSON.
final class LegacyConfigBootstrap {
  LegacyConfigBootstrap._();

  static Future<GlobalConfig?> readGlobalConfig(DataStoreImpl dataStore) async {
    final root = dataStore.instancePath;
    if (root == null) return null;
    final jsonPath = LegacyConfigPaths.globalJson(root);
    if (!await dataStore.storage.existsFile(jsonPath)) return null;
    final content = await dataStore.storage.readAsString(jsonPath);
    return LegacyGlobalConfigJson.tryParse(content ?? '');
  }

  static Future<SpaceConfig?> readSpaceConfig(
    DataStoreImpl dataStore, {
    required String spaceName,
  }) async {
    final root = dataStore.instancePath;
    if (root == null) return null;
    final jsonPath = LegacyConfigPaths.spaceJson(root, spaceName);
    if (!await dataStore.storage.existsFile(jsonPath)) return null;
    final content = await dataStore.storage.readAsString(jsonPath);
    return LegacySpaceConfigJson.tryParse(content ?? '');
  }

  /// Raw JSON map (preserves `tableDirectoryMap` / `directoryUsageMap`).
  static Future<Map<String, dynamic>?> readGlobalJsonMap(
    DataStoreImpl dataStore,
  ) async {
    final root = dataStore.instancePath;
    if (root == null) return null;
    final jsonPath = LegacyConfigPaths.globalJson(root);
    if (!await dataStore.storage.existsFile(jsonPath)) return null;
    final content = await dataStore.storage.readAsString(jsonPath);
    return LegacyGlobalConfigJson.tryParseMap(content ?? '');
  }

  /// Raw JSON map (preserves `tableDirectoryMap` / `directoryUsageMap`).
  static Future<Map<String, dynamic>?> readSpaceJsonMap(
    DataStoreImpl dataStore, {
    required String spaceName,
  }) async {
    final root = dataStore.instancePath;
    if (root == null) return null;
    final jsonPath = LegacyConfigPaths.spaceJson(root, spaceName);
    if (!await dataStore.storage.existsFile(jsonPath)) return null;
    final content = await dataStore.storage.readAsString(jsonPath);
    return LegacySpaceConfigJson.tryParseMap(content ?? '');
  }

  static Future<void> deleteGlobalJson(DataStoreImpl dataStore) async {
    final root = dataStore.instancePath;
    if (root == null) return;
    final jsonPath = LegacyConfigPaths.globalJson(root);
    if (await dataStore.storage.existsFile(jsonPath)) {
      await dataStore.storage.deleteFile(jsonPath);
      Logger.info('Deleted legacy $jsonPath after TOBF finalize');
    }
  }

  static Future<void> deleteSpaceJson(
    DataStoreImpl dataStore, {
    required String spaceName,
  }) async {
    final root = dataStore.instancePath;
    if (root == null) return;
    final jsonPath = LegacyConfigPaths.spaceJson(root, spaceName);
    if (await dataStore.storage.existsFile(jsonPath)) {
      await dataStore.storage.deleteFile(jsonPath);
      Logger.info('Deleted legacy $jsonPath after TOBF finalize');
    }
  }
}
