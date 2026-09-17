import '../core/data_store_impl.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'v2_upgrade.dart';
import 'v3_upgrade.dart';
import 'v4_upgrade.dart';

/// Manage database major version upgrades (GlobalConfig / table data).
/// Each major upgrade should be implemented in separate files under upgrades/
/// to avoid polluting business logic and keep upgrade logic organized.
class VersionUpgradeManager {
  final DataStoreImpl _dataStore;

  VersionUpgradeManager(this._dataStore);

  /// Entry point: run all necessary upgrades based on GlobalConfig.version.
  Future<void> runDatabaseUpgradesIfNeeded() async {
    try {
      final globalConfig = await _dataStore.getGlobalConfig();
      if (globalConfig == null) {
        // No global config yet -- treat as fresh database, nothing to upgrade.
        return;
      }

      final currentVersion = globalConfig.version;
      final engineVersion = InternalConfig.engineVersion;

      // 1. Handle Downgrade: Current engine is older than the database.
      if (currentVersion > engineVersion) {
        // The database was created or upgraded by a newer version of the engine.
        // Opening it with an older engine may lead to data corruption or crashes
        // because the older engine doesn't understand the newer file formats or metadata.
        throw DbException([
          GeneralStatus(
            type: ResultType.devEngineIncompatible,
            message:
                'Database engine version mismatch: The database was created with a newer version of the engine (v$currentVersion), '
                'but the current engine version is v$engineVersion. '
                'Downgrading is not supported as newer engine features may be incompatible with older versions. '
                'Please use the previous database version or the latest version.',
          )
        ]);
      }

      // 2. Handle Up-to-date: Version matches exactly.
      if (currentVersion == engineVersion) {
        return;
      }

      // One hop to the live engine: pick the oldest format entry that still
      // applies. V2 already chains V3 and stamps [InternalConfig.engineVersion];
      // do not run V3/V4 afterwards.
      Logger.info(
        'Database version upgrade required: v$currentVersion -> v$engineVersion',
      );

      if (currentVersion < 2) {
        await V2Upgrade(_dataStore).execute(globalConfig);
      } else if (currentVersion < 3) {
        await V3Upgrade(_dataStore).execute(globalConfig);
      } else {
        await V4Upgrade(_dataStore).execute(globalConfig);
      }
    } catch (e) {
      if (e is DbException) rethrow;

      Logger.critical('Database version upgrade failed', rawError: e);
      rethrow;
    }
  }
}
