import 'dart:typed_data';
import 'data_store_config.dart';

class EncoderConfig {
  final Uint8List activeKey;
  final int keyId;
  final Map<int, Uint8List>? fallbackKeys;
  final EncryptionType encryptionType;

  EncoderConfig({
    required this.activeKey,
    required this.keyId,
    this.fallbackKeys,
    this.encryptionType = EncryptionType.xorObfuscation,
  });

  Map<String, dynamic> toJson() {
    return {
      'activeKey': activeKey,
      'keyId': keyId,
      // The keys of the map must be strings for JSON encoding.
      'fallbackKeys': fallbackKeys?.map((k, v) => MapEntry(k.toString(), v)),
      'encryptionType': encryptionType.toInt(),
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
    );
  }
}
