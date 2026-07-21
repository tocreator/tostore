import 'dart:convert';

import '../../handler/common.dart';
import '../../model/space_config.dart';

/// Legacy JSON parser for pre-TOBF `space_config.json`.
///
/// Keep out of hot-path codecs — used only by config format migration / upgrades.
final class LegacySpaceConfigJson {
  LegacySpaceConfigJson._();

  static SpaceConfig? tryParse(String content) {
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

  static SpaceConfig fromMap(Map<String, dynamic> json) {
    return SpaceConfig(
      current:
          EncryptionKeyInfo.fromJson(json['current'] as Map<String, dynamic>),
      previous: json['previous'] != null
          ? EncryptionKeyInfo.fromJson(json['previous'] as Map<String, dynamic>)
          : null,
      historyKeys: json['historyKeys'] != null
          ? (json['historyKeys'] as List<dynamic>)
              .map((e) => EncryptionKeyInfo.fromJson(e as Map<String, dynamic>))
              .toList()
          : null,
      version: resolveVersionValue(
          json['version'], InternalConfig.legacyEngineVersion),
      totalTableCount: json['totalTableCount'] as int? ?? 0,
      totalRecordCount: json['totalRecordCount'] as int? ?? 0,
      totalDataSizeBytes: json['totalDataSizeBytes'] as int? ?? 0,
      lastStatisticsTime: json['lastStatisticsTime'] != null
          ? DateTime.parse(json['lastStatisticsTime'] as String)
          : null,
    );
  }
}
