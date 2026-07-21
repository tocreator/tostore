import 'dart:convert';

import '../../handler/common.dart';
import '../../model/global_config.dart';

/// Legacy JSON parser for pre-TOBF `global_config.json`.
///
/// Keep out of hot-path codecs — used only by config format migration / upgrades.
final class LegacyGlobalConfigJson {
  LegacyGlobalConfigJson._();

  static GlobalConfig? tryParse(String content) {
    final map = tryParseMap(content);
    if (map == null) return null;
    return fromMap(map);
  }

  /// Raw map so callers (V3) can read `tableDirectoryMap` before model drop.
  static Map<String, dynamic>? tryParseMap(String content) {
    if (content.isEmpty) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  static GlobalConfig fromMap(Map<String, dynamic> json) {
    final rawPageSize = json['pageSize'];
    return GlobalConfig(
      version: resolveVersionValue(
          json['version'], InternalConfig.legacyEngineVersion),
      userVersion: resolveVersionValue(json['userVersion'], 0),
      maxEntriesPerDir: resolveVersionValue(
          json['maxEntriesPerDir'], InternalConfig.defaultMaxEntriesPerDir),
      // Missing key → 0 (unset), must NOT default here or v3 loses the signal
      // to sample page size from existing table meta.
      pageSize: rawPageSize == null ? 0 : (rawPageSize as num).toInt(),
      spaceNames: (json['spaceNames'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toSet() ??
          {'default'},
      activeSpace: json['activeSpace'] as String? ?? 'default',
      hasMigrationTask: json['hasMigrationTask'] as bool? ?? false,
      userSchemaHash: json['userSchemaHash'] as String?,
      systemSchemaHash: json['systemSchemaHash'] as String?,
      lastGlobalDirIndex: (json['lastGlobalDirIndex'] as num?)?.toInt() ?? 0,
      lastGlobalDirEntries:
          (json['lastGlobalDirEntries'] as num?)?.toInt() ?? 0,
      lastNonGlobalDirIndex:
          (json['lastNonGlobalDirIndex'] as num?)?.toInt() ?? 0,
      lastNonGlobalDirEntries:
          (json['lastNonGlobalDirEntries'] as num?)?.toInt() ?? 0,
    );
  }
}
