import '../handler/common.dart';
import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import 'v2_upgrade.dart';

/// Manage database major version upgrades (GlobalConfig/SpaceConfig/table data).
/// Each major upgrade should be implemented in separate files under version_upgrades/
/// to avoid polluting business logic and keep upgrade logic organized.
class VersionUpgradeManager {
  final DataStoreImpl _dataStore;

  VersionUpgradeManager(this._dataStore);

  /// Entry point: run all necessary upgrades based on GlobalConfig.version.
  Future<void> runDatabaseUpgradesIfNeeded() async {
    try {
      final globalConfig = await _dataStore.getGlobalConfig();
      if (globalConfig == null) {
        // No global config yet – treat as fresh database, nothing to upgrade.
        return;
      }

      if (globalConfig.version >= InternalConfig.engineVersion) {
        return;
      }

      // Route to specific version upgrade handlers
      if (globalConfig.version < 2 && InternalConfig.engineVersion >= 2) {
        final v2Upgrade = V2Upgrade(_dataStore);
        await v2Upgrade.execute(globalConfig);
      }

      // Future version upgrades can be added here:
      // if (globalConfig.version < 3 && InternalConfig.databaseVersion >= 3) {
      //   final v3Upgrade = V3Upgrade(_dataStore);
      //   await v3Upgrade.execute(globalConfig);
      // }
    } catch (e, stack) {
      Logger.error(
        'Database version upgrade failed: $e\n$stack',
        label: 'VersionUpgradeManager.runDatabaseUpgradesIfNeeded',
      );
      rethrow;
    }
  }
}
