import '../core/data_store_impl.dart';
import '../handler/logger.dart';
import 'legacy_model/legacy_config_bootstrap.dart';

/// Finalize GlobalConfig / SpaceConfig TOBF files and delete legacy JSON.
///
/// **Only** call from [V3Upgrade] after `tableDirectoryMap` /
/// `directoryUsageMap` have been fully consumed. Premature JSON deletion
/// (or early TOBF rewrite that drops those fields) causes irreversible
/// table-directory loss on 3.1.2 databases.
final class ConfigFormatMigration {
  ConfigFormatMigration._();

  /// Write current space configs as TOBF (if not already), then delete all
  /// legacy `*.json` config files for [spaceNames] + global.
  static Future<void> finalizeTobfAndDeleteJson(
    DataStoreImpl dataStore, {
    required Iterable<String> spaceNames,
  }) async {
    try {
      for (final spaceName in spaceNames) {
        final config = await dataStore.getSpaceConfig(spaceName: spaceName);
        if (config != null) {
          // Ensures `space_config.tobf` exists before JSON removal.
          await dataStore.saveSpaceConfigToFile(config, spaceName: spaceName);
        }
        await LegacyConfigBootstrap.deleteSpaceJson(
          dataStore,
          spaceName: spaceName,
        );
      }

      // Global TOBF should already have been written by saveGlobalConfig;
      // still delete leftover JSON.
      await LegacyConfigBootstrap.deleteGlobalJson(dataStore);
    } catch (e) {
      Logger.warn('ConfigFormatMigration.finalizeTobfAndDeleteJson failed',
          rawError: e);
      rethrow;
    }
  }
}
