

class EncoderConfig {
  final bool enableEncoding;
  final bool enableObfuscation;
  final List<int> activeKey;
  final int keyId;
  final Map<int, List<int>>? fallbackKeys;

  EncoderConfig({
    required this.enableEncoding,
    required this.enableObfuscation,
    required this.activeKey,
    required this.keyId,
    this.fallbackKeys,
  });

  Map<String, dynamic> toJson() {
    return {
      'enableEncoding': enableEncoding,
      'enableObfuscation': enableObfuscation,
      'activeKey': activeKey,
      'keyId': keyId,
      // The keys of the map must be strings for JSON encoding.
      'fallbackKeys': fallbackKeys?.map((k, v) => MapEntry(k.toString(), v)),
    };
  }

  factory EncoderConfig.fromJson(Map<String, dynamic> json) {
    Map<int, List<int>>? fallbackKeys;
    if (json['fallbackKeys'] != null) {
      final fallbackKeysRaw = json['fallbackKeys'] as Map;
      fallbackKeys = fallbackKeysRaw.map(
        (key, value) => MapEntry(
          int.parse(key.toString()),
          List<int>.from(value),
        ),
      );
    }

    return EncoderConfig(
      enableEncoding: json['enableEncoding'] as bool,
      enableObfuscation: json['enableObfuscation'] as bool,
      activeKey: List<int>.from(json['activeKey']),
      keyId: json['keyId'] as int,
      fallbackKeys: fallbackKeys,
    );
  }
} 