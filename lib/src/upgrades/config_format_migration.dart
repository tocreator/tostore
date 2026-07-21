import '../core/data_store_impl.dart';
import '../handler/global_config_codec.dart';
import '../handler/logger.dart';
import '../handler/space_config_codec.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'legacy_model/pre_v3.dart';

/// Finalize GlobalConfig / SpaceConfig TOBF files and delete legacy JSON.
///
/// **Only** call from [V3Upgrade] after `tableDirectoryMap` /
/// `directoryUsageMap` have been fully consumed. Premature JSON deletion
/// (or early TOBF rewrite that drops those fields) causes irreversible
/// table-directory loss on 3.1.2 databases.
final class ConfigFormatMigration {
  ConfigFormatMigration._();

  /// Write current space configs as TOBF, verify readable, then delete JSON.
  ///
  /// Never deletes a legacy JSON file unless the matching `*.tobf` exists and
  /// decodes successfully — prevents silent key/map loss on write failure.
  static Future<void> finalizeTobfAndDeleteJson(
    DataStoreImpl dataStore, {
    required Iterable<String> spaceNames,
  }) async {
    for (final spaceName in spaceNames) {
      final config = await dataStore.getSpaceConfig(spaceName: spaceName);
      if (config == null) {
        // Do not delete JSON when we could not load a domain model to rewrite.
        Logger.warn(
          'ConfigFormatMigration: skip space [$spaceName] — no readable config',
        );
        continue;
      }

      await dataStore.saveSpaceConfigToFile(
        config,
        spaceName: spaceName,
        propagateErrors: true,
      );

      final tobfPath =
          dataStore.pathManager.getSpaceConfigPath(spaceName: spaceName);
      await _verifySpaceTobf(dataStore, tobfPath);
      await LegacyConfigBootstrap.deleteSpaceJson(
        dataStore,
        spaceName: spaceName,
      );
    }

    final globalTobf = dataStore.pathManager.getGlobalConfigPath();
    await _verifyGlobalTobf(dataStore, globalTobf);
    await LegacyConfigBootstrap.deleteGlobalJson(dataStore);
  }

  static Future<void> _verifySpaceTobf(
    DataStoreImpl dataStore,
    String tobfPath,
  ) async {
    if (!await dataStore.storage.existsFile(tobfPath)) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'ConfigFormatMigration: space TOBF missing after write: $tobfPath',
        )
      ]);
    }
    final bytes = await dataStore.storage.readAsBytes(tobfPath);
    if (bytes.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'ConfigFormatMigration: space TOBF empty after write: $tobfPath',
        )
      ]);
    }
    try {
      SpaceConfigCodec.decodeFile(bytes);
    } catch (e) {
      Logger.error('ConfigFormatMigration: space TOBF decode failed',
          rawError: e);
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'ConfigFormatMigration: space TOBF unreadable after write: $tobfPath',
        )
      ]);
    }
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
      GlobalConfigCodec.decodeFile(bytes);
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
