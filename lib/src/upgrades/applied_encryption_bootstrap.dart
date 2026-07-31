import 'dart:convert';
import 'dart:typed_data';

import '../core/data_store_impl.dart';
import '../handler/chacha20_poly1305.dart';
import '../handler/chacha20_poly1305_old.dart';
import '../handler/logger.dart';
import '../model/applied_encryption.dart';
import '../model/data_store_config.dart';
import '../model/global_config.dart';
import 'legacy_model/pre_v3.dart';

/// Blocking upgrade: move SpaceConfig JSON keyring → [GlobalConfig.appliedEncryption].
///
/// Handles legacy JSON space_config key blobs (ChaCha wrap ± AAD / old cipher)
/// and deviceBinding path-derived KEK fallback when no explicit encryptionKey.
/// Unpublished TOBF keyring layouts are not read — keys live only in GlobalConfig.
abstract final class AppliedEncryptionBootstrap {
  AppliedEncryptionBootstrap._();

  /// Prefer existing GlobalConfig.appliedEncryption; otherwise harvest from spaces.
  static Future<void> ensureAppliedEncryption(DataStoreImpl dataStore) async {
    final global = await dataStore.getGlobalConfig() ?? GlobalConfig();
    final existing = global.appliedEncryption;
    if (existing != null &&
        (existing.current.key.isNotEmpty || existing.historyKeys.isNotEmpty)) {
      return;
    }

    final spaces = global.spaceNames.isNotEmpty
        ? global.spaceNames.toList()
        : <String>[dataStore.currentSpaceName];

    EncryptionKeyInfo? bestCurrent;
    final history = <EncryptionKeyInfo>[];

    for (final space in spaces) {
      final harvested = await _harvestPlainKeysFromSpace(dataStore, space);
      for (final entry in harvested.entries) {
        final info = EncryptionKeyInfo(key: entry.value, keyId: entry.key);
        if (bestCurrent == null || info.keyId > bestCurrent.keyId) {
          if (bestCurrent != null &&
              bestCurrent.key.isNotEmpty &&
              !history.any((k) => k.keyId == bestCurrent!.keyId)) {
            history.add(bestCurrent);
          }
          bestCurrent = info;
        } else if (info.key.isNotEmpty &&
            !history.any((k) => k.keyId == info.keyId) &&
            info.keyId != bestCurrent.keyId) {
          history.add(info);
        }
      }
    }

    if (bestCurrent == null || bestCurrent.key.isEmpty) {
      // Fresh DB / no legacy keys: seed from config encoding key.
      final enc = dataStore.config.encryptionConfig ?? const EncryptionConfig();
      final plain = enc.resolveEncodingKey();
      if (plain.isEmpty) return;
      bestCurrent = EncryptionKeyInfo(key: plain, keyId: 1);
    }

    await dataStore.saveGlobalConfig(
      global.copyWith(
        appliedEncryption: AppliedEncryption(
          current: bestCurrent,
          historyKeys:
              history.where((k) => k.keyId != bestCurrent!.keyId).toList(),
        ),
      ),
      propagateErrors: true,
    );

    Logger.info(
      'AppliedEncryptionBootstrap: current keyId=${bestCurrent.keyId}, '
      'history=${history.length}',
    );
  }

  static Future<Map<int, String>> _harvestPlainKeysFromSpace(
    DataStoreImpl dataStore,
    String spaceName,
  ) async {
    final out = <int, String>{};

    final jsonPath =
        LegacyConfigPaths.spaceJson(dataStore.instancePath!, spaceName);
    if (!await dataStore.storage.existsFile(jsonPath)) return out;

    final content = await dataStore.storage.readAsString(jsonPath);
    if (content == null || content.isEmpty) return out;

    final map = LegacySpaceConfigJson.tryParseMap(content);
    if (map == null) return out;

    out.addAll(await _unwrapKeyInfos(
      dataStore,
      LegacySpaceConfigJson.extractKeyInfos(map),
      tryOldCipher: true,
    ));
    return out;
  }

  static Future<Map<int, String>> _unwrapKeyInfos(
    DataStoreImpl dataStore,
    List<EncryptionKeyInfo> infos, {
    required bool tryOldCipher,
  }) async {
    final out = <int, String>{};
    final keks = _candidateKeks(dataStore);
    for (final info in infos) {
      if (info.key.isEmpty) continue;
      final plain = _tryUnwrap(info, keks, tryOldCipher: tryOldCipher);
      if (plain != null && plain.isNotEmpty) {
        out[info.keyId] = plain;
      }
    }
    return out;
  }

  static List<String> _candidateKeks(DataStoreImpl dataStore) {
    final enc = dataStore.config.encryptionConfig ?? const EncryptionConfig();
    final list = <String>[
      enc.resolveEncryptionKey(),
      defaultEncryptionKey,
      LegacyPathKeyDerivation.historicalV2DefaultEncryptionKey(),
    ];
    final dbPath = dataStore.instancePath ?? dataStore.config.dbPath;
    if (dbPath != null && dbPath.isNotEmpty) {
      list.add(
        LegacyPathKeyDerivation.deriveKeyFromPath(dbPath, 'encryption'),
      );
    }
    return list.toSet().toList();
  }

  static String? _tryUnwrap(
    EncryptionKeyInfo info,
    List<String> keks, {
    required bool tryOldCipher,
  }) {
    Uint8List? raw;
    try {
      raw = base64.decode(info.key);
    } catch (_) {
      // Already plaintext encoding key
      return info.key;
    }

    final aad = Uint8List.fromList(utf8.encode('keyId:${info.keyId}'));
    for (final kek in keks) {
      final key32 = ChaCha20Poly1305.generateKeyFromString(kek);
      try {
        return ChaCha20Poly1305.decrypt(
          encryptedData: raw,
          key: key32,
          aad: aad,
        );
      } catch (_) {}
      try {
        return ChaCha20Poly1305.decrypt(
          encryptedData: raw,
          key: key32,
        );
      } catch (_) {}
      if (tryOldCipher) {
        try {
          final key32Old = ChaCha20Poly1305Old.generateKeyFromString(kek);
          return ChaCha20Poly1305Old.decrypt(
            encryptedData: raw,
            key: key32Old,
          );
        } catch (_) {}
      }
    }
    return null;
  }
}

/// One-shot upgrade helpers for pre-v3 `deviceBinding` path-derived keys
/// and historical default KEK literals (never store those as plaintext strings).
///
/// Not used at runtime after upgrade; kept only for v2/v3 blocking migration.
abstract final class LegacyPathKeyDerivation {
  LegacyPathKeyDerivation._();

  /// Same algorithm as the removed EncryptionConfig._deriveKeyFromPath.
  static String deriveKeyFromPath(String dbPath, String purpose) {
    final normalizedPath = dbPath.replaceAll(RegExp(r'[/\\]+'), '/');
    final combined = 'path:$normalizedPath|purpose:$purpose';
    return _deriveKeyFromString(combined);
  }

  /// Historical v2 default KEK, rebuilt from XOR'd bytes so the passphrase
  /// is not present as a plaintext string constant in the binary.
  static String historicalV2DefaultEncryptionKey() {
    // XOR mask 0x5A — must round-trip to the pre-v3 engine default KEK.
    const masked = <int>[
      0x1F,
      0x63,
      0x34,
      0x62,
      0x19,
      0x6D,
      0x28,
      0x6C,
      0x23,
      0x6D,
      0x0A,
      0x62,
      0x0E,
      0x69,
      0x33,
      0x35,
      0x14,
      0x31,
      0x1F,
      0x23,
    ];
    final chars = StringBuffer();
    for (final b in masked) {
      chars.writeCharCode(b ^ 0x5A);
    }
    return chars.toString();
  }

  static String _deriveKeyFromString(String input) {
    final inputBytes = utf8.encode(input);
    final keyBytes = Uint8List(32);
    int hash = 0;

    for (int i = 0; i < inputBytes.length; i++) {
      hash = ((hash << 5) - hash) + inputBytes[i];
      hash = hash & hash;
    }

    for (int i = 0; i < 32; i++) {
      final index = (i * 7 + hash) % inputBytes.length;
      keyBytes[i] = (inputBytes[index] ^ (i * 13 + 41) ^ hash) & 0xFF;
      hash = ((hash << 3) - hash) + keyBytes[i];
    }

    final base64Str = base64Encode(keyBytes);
    return base64Str.substring(
      0,
      base64Str.length > 24 ? 24 : base64Str.length,
    );
  }
}
