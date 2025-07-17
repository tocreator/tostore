import 'dart:convert';
import 'dart:typed_data';

import '../model/encoder_config.dart';

/// Data encoding is efficient and fast, slightly slower than regular UTF-8 encoding
/// Protects data privacy by preventing casual viewing of data files
class EncoderHandler {
  /// encoding version
  static const int _encodingVersion = 1;

  // is encoding enabled
  static bool _enableEncoding = false;

  // is obfuscation enabled
  static bool _enableObfuscation = false;

  /// set encoding config
  static void setEncodingConfig({
    required bool enableEncoding,
    required bool enableObfuscation,
  }) {
    _enableEncoding = enableEncoding;
    _enableObfuscation = enableObfuscation;
  }

  /// get current encoding config
  static Map<String, bool> getEncodingConfig() {
    return {
      'enableEncoding': _enableEncoding,
      'enableObfuscation': _enableObfuscation,
    };
  }

  // default xor key
  static const List<int> _defaultXorKey = [
    42,
    127,
    89,
    13,
    71,
    240,
    23,
    190,
    119,
    63
  ];

  // current active key
  static List<int> _activeKey = _defaultXorKey;

  // Standard encoding: XOR obfuscation + Base64 encoding
  static const String _encodeBase64Prefix = "ToB64_";

  // Simple encoding: only Base64 encoding without obfuscation
  static const String _encodeBase64SimplePrefix = "ToBs_";

  // High-performance encoding: UTF8 encoding with XOR obfuscation (binary data)
  static const String _encodeUtf8Prefix = "ToU8_";

  // Raw encoding: plain UTF8 encoding without obfuscation (binary data)
  static const String _encodeRawPrefix = "ToUr_";

  // Binary encoding prefixes derived from string prefixes
  static final List<int> _utf8PrefixBytes = utf8.encode(_encodeUtf8Prefix);
  static final List<int> _rawPrefixBytes = utf8.encode(_encodeRawPrefix);

  // Fallback keys, mapping keyId to the key.
  static Map<int, List<int>>? _fallbackKeys;

  static int _currentKeyId = 0;

  /// Sets the fallback keys. This is used to provide older keys for decoding data
  /// that might have been encrypted with a previous key.
  static void setFallbackKeys(Map<int, List<int>>? keys) {
    _fallbackKeys = keys;
  }

  static void setCurrentKey(String key, int keyId) {
    _activeKey = generateKey(key);
    _currentKeyId = keyId;
  }

  /// The key should be a list of integers, each representing a byte value (0-255)
  static void setKey(List<int> customKey) {
    if (customKey.isNotEmpty) {
      _activeKey = List<int>.from(customKey);
    } else {
      _activeKey = _defaultXorKey;
    }
  }

  /// Reset to default key
  static void resetToDefaultKey() {
    _activeKey = _defaultXorKey;
  }

  /// Generate a key from a string
  static List<int> generateKey(String text) {
    if (text.isEmpty) return _defaultXorKey;

    final keyBytes = utf8.encode(text);
    final keyResult = <int>[];

    for (int i = 0; i < 10; i++) {
      keyResult.add(keyBytes[i % keyBytes.length] ^ (i * 13 + 41));
    }

    return keyResult;
  }

  /// Highest performance encoding: returns UTF-8 bytes, optionally XOR obfuscated
  /// Returns complete binary data with header bytes, suitable for direct storage in files or binary dataspaces
  static Uint8List encode(String input,
      {List<int>? customKey, bool? enableObfuscation, int? keyId}) {
    if (!_enableEncoding) {
      return Uint8List.fromList(utf8.encode(input));
    }

    if (input.isEmpty) return Uint8List(0);
    final usedKey = customKey ?? _activeKey;
    final usedKeyId = keyId ?? _currentKeyId;
    final bytes = utf8.encode(input);
    Uint8List encodedData;
    String headerStr;

    final useObfuscation = enableObfuscation ?? _enableObfuscation;

    if (useObfuscation) {
      encodedData = _applyXor(bytes, usedKey);
      headerStr = _buildHeader(_encodeUtf8Prefix, usedKeyId);
    } else {
      encodedData = Uint8List.fromList(bytes);
      headerStr = _buildHeader(_encodeRawPrefix, usedKeyId);
    }
    final headerBytes = utf8.encode(headerStr);
    final result = Uint8List(headerBytes.length + encodedData.length);
    result.setAll(0, headerBytes);
    result.setAll(headerBytes.length, encodedData);
    return result;
  }

  /// Decode string from binary data with header information
  static Future<String> decode(Uint8List encoded,
      {List<int>? customKey, int? keyId}) async {
    if (encoded.isEmpty) return '';
    if (!_enableEncoding) {
      try {
        return utf8.decode(encoded);
      } catch (e) {
        // If decoding fails, continue to decoding
      }
    }

    try {
      final decodedStr = utf8.decode(encoded, allowMalformed: true);
      if (decodedStr.startsWith(_encodeUtf8Prefix) ||
          decodedStr.startsWith(_encodeRawPrefix)) {
        final stripped = _stripHeader(decodedStr);
        final headerLength = decodedStr.length - stripped.length;
        final dataBytes = encoded.sublist(headerLength);

        // If the header indicates obfuscated (UTF8) encoding
        if (decodedStr.startsWith(_encodeUtf8Prefix)) {
          List<int>? key = customKey ?? _activeKey;
          // Extract keyId from header using regex pattern '_k<number>_'
          final keyIdMatch = RegExp(r'_k(\d+)_').firstMatch(decodedStr);
          int headerKeyId =
              keyIdMatch != null ? int.parse(keyIdMatch.group(1)!) : 0;

          // If an expected keyId is provided and doesn't match header keyId, try to retrieve the proper key
          if (headerKeyId != (keyId ?? _currentKeyId)) {
            if (headerKeyId == 0) {
              key = _defaultXorKey;
            } else if (_fallbackKeys?.containsKey(headerKeyId) ?? false) {
              key = _fallbackKeys![headerKeyId] ?? key;
            }
          }
          final restored = _applyXor(dataBytes, key);
          return utf8.decode(restored);
        } else {
          return utf8.decode(dataBytes);
        }
      } else {
        return utf8.decode(encoded);
      }
    } catch (e) {
      return '';
    }
  }

  /// Internal method: check if binary data has a specified prefix
  static bool _hasPrefix(Uint8List data, List<int> prefix) {
    if (data.length < prefix.length) return false;

    for (int i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }

    return true;
  }

  /// This is not meant for security but just to prevent casual viewing of data
  /// If enableObfuscation is false, only base64 encoding is applied (faster but less secure)
  static String encodeBase64(String input,
      {List<int>? customKey, bool? enableObfuscation, int? keyId}) {
    if (!_enableEncoding) {
      return input;
    }

    if (input.isEmpty) return input;
    final usedKey = customKey ?? _activeKey;
    final usedKeyId = keyId ?? _currentKeyId;
    final bytes = utf8.encode(input);

    final useObfuscation = enableObfuscation ?? _enableObfuscation;

    if (useObfuscation) {
      final encoded = _applyXor(bytes, usedKey);
      final header = _buildHeader(_encodeBase64Prefix, usedKeyId);
      return '$header${base64.encode(encoded)}';
    } else {
      // Skip XOR step for better performance
      final header = _buildHeader(_encodeBase64SimplePrefix, usedKeyId);
      return '$header${base64.encode(bytes)}';
    }
  }

  /// Decode a previously encoded Base64 string (with header) asynchronously
  static Future<String> decodeBase64(String encoded,
      {List<int>? customKey, int? keyId}) async {
    if (encoded.isEmpty) return encoded;

    if (!_enableEncoding) {
      return encoded;
    }

    if (!isBase64Encoded(encoded)) {
      return encoded;
    }
    var usedKey = customKey ?? _activeKey;
    var usedKeyId = keyId ?? _currentKeyId;
    try {
      if (encoded.startsWith(_encodeBase64SimplePrefix)) {
        final stripped = _stripHeader(encoded);
        final bytes = base64.decode(stripped);
        return utf8.decode(bytes);
      } else if (encoded.startsWith(_encodeBase64Prefix)) {
        final stripped = _stripHeader(encoded);
        // Extract keyId from header using regex pattern '_k<number>_'
        final keyIdMatch = RegExp(r'_k(\d+)_').firstMatch(encoded);
        int headerKeyId =
            keyIdMatch != null ? int.parse(keyIdMatch.group(1)!) : 0;

        // If header keyId does not match the provided keyId, try to retrieve the proper key
        if (headerKeyId != usedKeyId) {
          if (_fallbackKeys?.containsKey(headerKeyId) ?? false) {
            usedKey = _fallbackKeys![headerKeyId] ?? usedKey;
          }
        }

        final bytes = base64.decode(stripped);
        final decoded = _applyXor(bytes, usedKey);
        return utf8.decode(decoded);
      } else {
        // fallback
        return utf8.decode(base64.decode(encoded));
      }
    } catch (e) {
      return encoded;
    }
  }

  // Cache for frequently decoded strings
  static final Map<String, String> _decodeCache = {};
  static const int _maxCacheSize = 100; // Limit cache size

  /// Decoding method with cache, suitable for frequently decoding the same string
  static Future<String> decodeWithCache(String encoded,
      {List<int>? customKey, int? keyId}) async {
    if (encoded.isEmpty) return encoded;
    if (!isBase64Encoded(encoded) || customKey != null) {
      return await decodeBase64(encoded, customKey: customKey, keyId: keyId);
    }
    if (_decodeCache.containsKey(encoded)) {
      return _decodeCache[encoded]!;
    }
    final decoded = await decodeBase64(encoded, keyId: keyId);
    if (_decodeCache.length >= _maxCacheSize) {
      _decodeCache.remove(_decodeCache.keys.first);
    }
    _decodeCache[encoded] = decoded;
    return decoded;
  }

  /* Adding caching logic for key precomputation */
  static List<int>? _cachedKey;
  static List<int>? _cachedKeyWordCache;

  /* Further optimized _applyXor implementation using precomputed keyWordCache with caching */
  static Uint8List _applyXor(List<int> bytes, List<int> key) {
    final int keyLength = key.length;
    final int len = bytes.length;
    final Uint8List result = Uint8List(len);
    final Uint8List inBytes =
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final ByteData inData = ByteData.sublistView(inBytes);
    final ByteData outData = ByteData.sublistView(result);

    // Check if the provided key matches the cached key
    bool useCache = false;
    if (_cachedKey != null &&
        _cachedKeyWordCache != null &&
        _cachedKey!.length == keyLength) {
      useCache = true;
      for (int i = 0; i < keyLength; i++) {
        if (_cachedKey![i] != key[i]) {
          useCache = false;
          break;
        }
      }
    }

    List<int> keyWordCache;
    if (useCache) {
      keyWordCache = _cachedKeyWordCache!;
    } else {
      // Compute keyWordCache and update cache
      keyWordCache = List<int>.filled(keyLength, 0);
      for (int r = 0; r < keyLength; r++) {
        int b0 = key[r];
        int b1 = key[(r + 1) % keyLength];
        int b2 = key[(r + 2) % keyLength];
        int b3 = key[(r + 3) % keyLength];
        keyWordCache[r] = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
      }
      _cachedKey = List<int>.from(key);
      _cachedKeyWordCache = keyWordCache;
    }

    final int blockCount = len ~/ 4;
    for (int j = 0; j < blockCount; j++) {
      int i = j * 4;
      int r = i % keyLength; // effective starting index for this block
      int keyWord = keyWordCache[r];
      int inputWord = inData.getUint32(i, Endian.little);
      outData.setUint32(i, inputWord ^ keyWord, Endian.little);
    }

    // Process any remaining bytes
    for (int i = blockCount * 4; i < len; i++) {
      result[i] = inBytes[i] ^ key[i % keyLength];
    }

    return result;
  }

  /// Check if a string is base64 encoded with our method
  static bool isBase64Encoded(String? content) {
    if (content == null || content.isEmpty) {
      return false;
    }
    // Simple prefix check
    return content.startsWith(_encodeBase64Prefix) ||
        content.startsWith(_encodeBase64SimplePrefix);
  }

  /// Check if a string is encoded with obfuscation
  static bool isEncodedWithObfuscation(String? content) {
    if (content == null || content.isEmpty) {
      return false;
    }
    return content.startsWith(_encodeBase64Prefix);
  }

  /// Check if utf8 data is encoded with our method
  static bool isEncoded(Uint8List bytes) {
    return _hasPrefix(bytes, _utf8PrefixBytes) ||
        _hasPrefix(bytes, _rawPrefixBytes);
  }

  // encoding method, encoding version, keyId, for example 'ToB64_v1_k0_'
  static String _buildHeader(String basePrefix, int keyId) {
    return '${basePrefix}v${_encodingVersion}_k${keyId}_';
  }

  // strip header
  static String _stripHeader(String encoded) {
    // Using regular expressions to match header formats for more reliable determination of header end positions
    final headerPattern = RegExp(
        '^($_encodeBase64Prefix|$_encodeBase64SimplePrefix|$_encodeUtf8Prefix|$_encodeRawPrefix)v\\d+_k\\d+_');
    final match = headerPattern.firstMatch(encoded);

    if (match != null) {
      return encoded.substring(match.end);
    }

    // if no match found, return the original string
    return encoded;
  }

  /// Get key ID
  static int getCurrentKeyId() {
    return _currentKeyId;
  }

  /// Get current complete encoding state, for isolate thread passing
  static EncoderConfig getCurrentEncodingState() {
    return EncoderConfig(
      enableEncoding: _enableEncoding,
      enableObfuscation: _enableObfuscation,
      activeKey: List<int>.from(_activeKey),
      keyId: _currentKeyId,
      fallbackKeys: _fallbackKeys,
    );
  }

  /// set complete encoding state, for isolate thread passing
  static void setEncodingState(EncoderConfig config) {
    _enableEncoding = config.enableEncoding;
    _enableObfuscation = config.enableObfuscation;
    _activeKey = List<int>.from(config.activeKey);
    _currentKeyId = config.keyId;
    if (config.fallbackKeys != null) {
      _fallbackKeys = Map<int, List<int>>.from(config.fallbackKeys!);
    }
  }

  /// Check if encoding is enabled
  static bool get isEncodingEnabled => _enableEncoding;

  /// Check if obfuscation is enabled
  static bool get isObfuscationEnabled => _enableObfuscation;
}
