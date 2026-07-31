import '../core/data_store_impl.dart';
import '../handler/common.dart';
import '../handler/global_config_codec.dart';
import '../handler/logger.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'legacy_model/pre_v3.dart';

/// Finalize GlobalConfig TOBF and delete legacy space/global JSON.
///
/// **Only** call from [V3Upgrade] after `tableDirectoryMap` /
/// `directoryUsageMap` have been fully consumed. Premature JSON deletion
/// causes irreversible table-directory loss on 3.1.2 databases.
///
/// Space aggregate stats live in InternalKv (`stats.space.v1`) after init.
/// Legacy `space_config.json` is deleted here once directory maps are consumed;
/// its counters are not migrated (incremental stats / explicit reconcile).
final class ConfigFormatMigration {
  ConfigFormatMigration._();

  /// Verify GlobalConfig TOBF, delete space JSON, write downgrade-guard stub.
  ///
  /// Never deletes/replaces a legacy JSON file unless GlobalConfig TOBF
  /// exists and decodes successfully.
  static Future<void> finalizeTobfAndDeleteJson(
    DataStoreImpl dataStore, {
    required Iterable<String> spaceNames,
  }) async {
    final globalTobf = dataStore.pathManager.getGlobalConfigPath();
    await _verifyGlobalTobf(dataStore, globalTobf);

    for (final spaceName in spaceNames) {
      await LegacyConfigBootstrap.deleteSpaceJson(
        dataStore,
        spaceName: spaceName,
      );
    }

    await LegacyConfigBootstrap.writeDowngradeGuardJson(
      dataStore,
      version: InternalConfig.engineVersion,
    );
  }

  static Future<void> _verifyGlobalTobf(
    DataStoreImpl dataStore,
    String tobfPath,
  ) async {
    if (!await dataStore.storage.existsFile(tobfPath)) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'ConfigFormatMigration: global TOBF missing after write: $tobfPath',
        )
      ]);
    }
    final bytes = await dataStore.storage.readAsBytes(tobfPath);
    if (bytes.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'ConfigFormatMigration: global TOBF empty after write: $tobfPath',
        )
      ]);
    }
    try {
      GlobalConfigCodec.decodeFile(
        bytes,
        encryptionKey:
            dataStore.config.encryptionConfig?.resolveEncryptionKey() ??
                defaultEncryptionKey,
      );
    } catch (e) {
      Logger.error('ConfigFormatMigration: global TOBF decode failed',
          rawError: e);
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'ConfigFormatMigration: global TOBF unreadable after write: $tobfPath',
        )
      ]);
    }
  }
}
