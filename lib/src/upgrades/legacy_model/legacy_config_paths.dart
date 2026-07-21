import '../../handler/common.dart';

/// Legacy JSON config filenames — construct paths only inside upgrades/.
///
/// Do not expose these via [PathManager]; hot path uses `*.tobf` only.
abstract final class LegacyConfigPaths {
  LegacyConfigPaths._();

  static const String globalFileName = 'global_config.json';
  static const String spaceFileName = 'space_config.json';

  static String globalJson(String instancePath) =>
      pathJoin(instancePath, globalFileName);

  static String spaceJson(String instancePath, String spaceName) =>
      pathJoin(instancePath, 'spaces', spaceName, spaceFileName);
}
