import '../core/data_store_impl.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../model/global_config.dart';

/// Version 3 upgrade:
/// - Bump GlobalConfig/SpaceConfig engine version markers.
/// - Keep storage layout unchanged; compatibility is handled at read paths.
class V3Upgrade {
  final DataStoreImpl _dataStore;

  V3Upgrade(this._dataStore);

  Future<void> execute(GlobalConfig oldGlobalConfig) async {
    Logger.info(
      'Starting database upgrade to version 3',
      label: 'V3Upgrade.execute',
    );

    final spaces = oldGlobalConfig.spaceNames.isNotEmpty
        ? oldGlobalConfig.spaceNames.toList()
        : <String>['default'];

    for (final spaceName in spaces) {
      await _upgradeSpaceVersion(spaceName);
    }

    final updatedGlobal =
        oldGlobalConfig.setVersion(InternalConfig.engineVersion);
    await _dataStore.saveGlobalConfig(updatedGlobal);

    Logger.info(
      'Database upgrade to version 3 completed',
      label: 'V3Upgrade.execute',
    );
  }

  Future<void> _upgradeSpaceVersion(String spaceName) async {
    final config = await _dataStore.getSpaceConfig(spaceName: spaceName);
    if (config == null) {
      return;
    }

    try {
      if (config.version >= InternalConfig.engineVersion) {
        return;
      }
      await _dataStore.saveSpaceConfigToFile(
        config.copyWith(version: InternalConfig.engineVersion),
        spaceName: spaceName,
      );
    } catch (e) {
      Logger.warn(
        'Skip upgrading space [$spaceName] config to v3: $e',
        label: 'V3Upgrade._upgradeSpaceVersion',
      );
    }
  }
}
