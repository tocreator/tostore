import 'dart:convert';
import 'dart:typed_data';

import 'data_store_config.dart';

class EncoderConfig {
  final Uint8List activeKey;
  final int keyId;
  final Map<int, Uint8List>? fallbackKeys;
  final EncryptionType encryptionType;
  final EncryptionScope encryptionScope;

  EncoderConfig({
    required this.activeKey,
    required this.keyId,
    this.fallbackKeys,
    this.encryptionType = EncryptionType.xorObfuscation,
    this.encryptionScope = EncryptionScope.standard,
  });

  Map<String, dynamic> toJson() {
    return {
      'activeKey': activeKey,
      'keyId': keyId,
      // The keys of the map must be strings for JSON encoding.
      'fallbackKeys': fallbackKeys?.map((k, v) => MapEntry(k.toString(), v)),
      'encryptionType': encryptionType.toInt(),
      'encryptionScope': encryptionScope.toConfigString(),
    };
  }

  factory EncoderConfig.fromJson(Map<String, dynamic> json) {
    Map<int, Uint8List>? fallbackKeys;
    if (json['fallbackKeys'] != null) {
      final fallbackKeysRaw = json['fallbackKeys'] as Map;
      fallbackKeys = fallbackKeysRaw.map(
        (key, value) => MapEntry(
          int.parse(key.toString()),
          Uint8List.fromList(List<int>.from(value)),
        ),
      );
    }

    return EncoderConfig(
      activeKey: Uint8List.fromList(List<int>.from(json['activeKey'])),
      keyId: json['keyId'] as int,
      fallbackKeys: fallbackKeys,
      encryptionType: json['encryptionType'] != null
          ? EncryptionTypeExtension.fromInt(json['encryptionType'] as int)
          : EncryptionType.xorObfuscation,
      encryptionScope: json['encryptionScope'] != null
          ? EncryptionScopeExtension.fromConfigString(
              json['encryptionScope'] as String)
          : EncryptionScope.standard,
    );
  }
}

/// Deterministic built-in key material from [seed] (platform-independent).
///
/// Used for engine-default KEK/DEK when the user does not supply keys.
/// Material is mixed from opaque byte tables + [seed] so the resulting
/// passphrase is not present as a plaintext string constant in the binary.
String deriveBuiltinKey(String seed) {
  final parts = <int>[
    0x48,
    0x65,
    0x6c,
    0x6c,
    0x6f,
    0x5f,
    0x74,
    0x68,
    0x69,
    0x73,
    0x5f,
    0x69,
    0x73,
    0x5f,
    0x54,
    0x6f,
    0x73,
    0x74,
    0x6f,
    0x72,
    0x65,
    0x5f,
    0x59,
    0x6f,
    0x75,
    0x5f,
    0x61,
    0x72,
    0x65,
    0x5f,
    0x61,
    0x6d,
    0x61,
    0x7a,
    0x69,
    0x6e,
    0x67,
  ];

  final o = Uint8List(parts.length);
  int x = seed.hashCode & 0xFF;
  for (int i = 0; i < parts.length; i++) {
    o[i] = (parts[i] ^ x ^ (i * 7)) & 0xFF;
    x = ((x << 1) | (x >> 7)) & 0xFF;
  }

  final combined = utf8.encode(seed) + o;

  final k = Uint8List(32);
  int hash1 = 0x5A827999;
  int hash2 = 0x6ED9EBA1;

  for (int i = 0; i < combined.length; i++) {
    hash1 = ((hash1 << 5) - hash1) + combined[i];
    hash2 = ((hash2 << 7) ^ hash2) + combined[i];
    hash1 = hash1 & 0xFFFFFFFF;
    hash2 = hash2 & 0xFFFFFFFF;
  }

  for (int i = combined.length - 1; i >= 0; i--) {
    hash1 = ((hash1 << 3) + hash1) ^ combined[i] ^ hash2;
    hash2 = ((hash2 >> 2) + hash2) ^ combined[i] ^ hash1;
    hash1 = hash1 & 0xFFFFFFFF;
    hash2 = hash2 & 0xFFFFFFFF;
  }

  for (int i = 0; i < 32; i++) {
    final idx = (i * 13 + hash1) % combined.length;
    k[i] = (combined[idx] ^
            ((hash1 >> (i % 24)) & 0xFF) ^
            ((hash2 >> ((31 - i) % 24)) & 0xFF) ^
            (i * 17 + 59)) &
        0xFF;
    hash1 = ((hash1 << 11) | (hash1 >> 21)) + k[i];
    hash2 = ((hash2 << 13) | (hash2 >> 19)) ^ k[i];
    hash1 = hash1 & 0xFFFFFFFF;
    hash2 = hash2 & 0xFFFFFFFF;
  }

  final base64Str = base64Encode(k);
  return base64Str.substring(0, base64Str.length > 24 ? 24 : base64Str.length);
}
