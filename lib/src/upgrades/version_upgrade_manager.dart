import '../handler/common.dart';
import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import '../model/business_error.dart';
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

      final currentVersion = globalConfig.version;
      final engineVersion = InternalConfig.engineVersion;

      // 1. Handle Downgrade: Current engine is older than the database.
      if (currentVersion > engineVersion) {
        // The database was created or upgraded by a newer version of ToStore.
        // Opening it with an older engine may lead to data corruption or crashes
        // because the older engine doesn't understand the newer file formats or metadata.
        throw BusinessError(
          'Database engine version mismatch: The database was created with a newer version of the engine (v$currentVersion), '
          'but the current engine version is v$engineVersion. '
          'Downgrading is not supported as newer engine features may be incompatible with older versions. '
          'Please use the previous database version or the latest version.',
          type: BusinessErrorType.versionError,
        );
      }

      // 2. Handle Up-to-date: Version matches exactly.
      if (currentVersion == engineVersion) {
        return;
      }

      // 3. Handle Upgrade: Current engine is newer than the database.
      Logger.info(
        'Database version upgrade required: v$currentVersion -> v$engineVersion',
        label: 'VersionUpgradeManager',
      );

      // Route to specific version upgrade handlers
      if (currentVersion < 2 && engineVersion >= 2) {
        final v2Upgrade = V2Upgrade(_dataStore);
        await v2Upgrade.execute(globalConfig);
      }

      // Future version upgrades can be added here:
      // if (currentVersion < 3 && engineVersion >= 3) {
      //   final v3Upgrade = V3Upgrade(_dataStore);
      //   await v3Upgrade.execute(globalConfig);
      // }
    } catch (e, stack) {
      if (e is BusinessError) rethrow;

      Logger.error(
        'Database version upgrade failed: $e\n$stack',
        label: 'VersionUpgradeManager.runDatabaseUpgradesIfNeeded',
      );
      rethrow;
    }
  }
}
