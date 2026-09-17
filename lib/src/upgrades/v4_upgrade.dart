import '../core/data_store_impl.dart';
import '../handler/logger.dart';
import '../model/global_config.dart';

/// Version stamp for directories already at engine 3.
///
/// V2/V3 already persist [InternalConfig.engineVersion] when they run on this
/// binary (v4 has no extra format rewrite). This step exists so existing v3
/// data directories still get version=4 + the downgrade guard — without it,
/// a v3 binary could reopen and mix paged nav with `nav_graph.ngh`.
///
/// Vector leftover blobs convert lazily per index ([NghIndexMeta.layoutVersion]
/// on NGH meta), not in this blocking stamp.
class V4Upgrade {
  /// Stamp written here. Keep 4; a future major that *rewrites files* needs
  /// its own upgrade class, not a jump from this stamp.
  static const int targetVersion = 4;

  final DataStoreImpl _dataStore;

  V4Upgrade(this._dataStore);

  Future<void> execute(GlobalConfig oldGlobalConfig) async {
    if (oldGlobalConfig.version >= targetVersion) {
      return;
    }

    final current = await _dataStore.getGlobalConfig() ?? oldGlobalConfig;
    if (current.version >= targetVersion) {
      return;
    }

    await _dataStore.saveGlobalConfig(
      current.setVersion(targetVersion),
      propagateErrors: true,
    );
    await _dataStore.ensureDowngradeGuardJson(version: targetVersion);

    Logger.info(
      'Database upgrade to version $targetVersion completed ',
    );
  }
}
