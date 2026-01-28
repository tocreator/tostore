import 'dart:convert';
import 'dart:typed_data';

import '../model/data_store_config.dart';
import '../model/encoder_config.dart';
import 'chacha20_poly1305.dart';
import 'aes_gcm.dart';

/// Data encoding is efficient and fast, slightly slower than regular UTF-8 encoding
/// Protects data privacy by preventing casual viewing of data files
class EncoderHandler {
  /// encoding version
  static const int _encodingVersion = 1;

  // current encryption type
  static EncryptionType _encryptionType = EncryptionType.xorObfuscation;

  /// Set encryption type (recommended API)
  static void setEncryptionType(EncryptionType type) {
    _encryptionType = type;
  }

  /// Get current encryption type
  static EncryptionType getEncryptionType() {
    return _encryptionType;
  }

  // default xor key
  static final Uint8List _defaultXorKey =
      Uint8List.fromList([42, 127, 89, 13, 71, 240, 23, 190, 119, 63]);

  // current active key
  static Uint8List _activeKey = _defaultXorKey;

  // High-performance encoding: UTF8 encoding with XOR obfuscation (binary data)
  static const String _encodeUtf8Prefix = "ToU8_";

  // Raw encoding: plain UTF8 encoding without obfuscation (binary data)
  static const String _encodeRawPrefix = "ToUr_";

  // ChaCha20-Poly1305 encrypted binary data prefix
  static const String _encodeChaCha20Prefix = "ToCh_";

  // AES-256-GCM encrypted binary data prefix
  static const String _encodeAesPrefix = "ToAe_";

  // Binary encoding prefixes derived from string prefixes
  static final List<int> _utf8PrefixBytes = utf8.encode(_encodeUtf8Prefix);
  static final List<int> _rawPrefixBytes = utf8.encode(_encodeRawPrefix);
  static final List<int> _chacha20PrefixBytes =
      utf8.encode(_encodeChaCha20Prefix);
  static final List<int> _aesPrefixBytes = utf8.encode(_encodeAesPrefix);

  // Fallback keys, mapping keyId to the key.
  static Map<int, Uint8List>? _fallbackKeys;

  static int _currentKeyId = 0;

  /// Sets the fallback keys. This is used to provide older keys for decoding data
  /// that might have been encrypted with a previous key.
  static void setFallbackKeys(Map<int, Uint8List>? keys) {
    _fallbackKeys = keys;
  }

  static void setCurrentKey(String key, int keyId) {
    _activeKey = generateKey(key);
    _currentKeyId = keyId;
  }

  /// The key should be a Uint8List, each byte representing a value (0-255)
  static void setKey(Uint8List customKey) {
    if (customKey.isNotEmpty) {
      _activeKey = customKey;
    } else {
      _activeKey = _defaultXorKey;
    }
  }

  /// Reset to default key
  static void resetToDefaultKey() {
    _activeKey = _defaultXorKey;
  }

  /// Generate a key from a string
  static Uint8List generateKey(String text) {
    if (text.isEmpty) return _defaultXorKey;

    final keyBytes = utf8.encode(text);
    final keyResult = Uint8List(10);

    for (int i = 0; i < 10; i++) {
      keyResult[i] = keyBytes[i % keyBytes.length] ^ (i * 13 + 41);
    }

    return keyResult;
  }

  /// Derive a 32-byte key from a variable-length key for AEAD algorithms
  static Uint8List _deriveKey32(Uint8List key) {
    if (key.length == 32) {
      return key; // Already correct size, no conversion needed!
    }

    // Simple key derivation: repeat and XOR to get 32 bytes
    final result = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      result[i] = key[i % key.length];
      // Add some mixing to avoid simple patterns
      if (i > 0) {
        result[i] ^= result[i - 1];
      }
    }
    return result;
  }

  /// Encode binary data directly (without string conversion)
  /// Suitable for pre-serialized binary data (e.g., MessagePack)
  /// Returns: [header][encrypted binary data]
  ///
  /// [aad] - Additional Authenticated Data for AEAD algorithms.
  /// Should include context like partition index, entry seq, etc.
  /// If not provided, only the header will be used as AAD (less secure).
  static Uint8List encodeBytes(Uint8List input,
      {Uint8List? customKey,
      int? keyId,
      EncryptionType? encryptionType,
      Uint8List? aad}) {
    if (_encryptionType == EncryptionType.none && encryptionType == null) {
      return input;
    }

    if (input.isEmpty) return Uint8List(0);
    final usedKey = customKey ?? _activeKey;
    final usedKeyId = keyId ?? _currentKeyId;

    // Determine encryption type (priority: parameter > global setting)
    EncryptionType actualType = encryptionType ?? _encryptionType;

    String headerStr;
    switch (actualType) {
      case EncryptionType.none:
        headerStr = _buildHeader(_encodeRawPrefix, usedKeyId);
        break;
      case EncryptionType.xorObfuscation:
        headerStr = _buildHeader(_encodeUtf8Prefix, usedKeyId);
        break;
      case EncryptionType.chacha20Poly1305:
        headerStr = _buildHeader(_encodeChaCha20Prefix, usedKeyId);
        break;
      case EncryptionType.aes256Gcm:
        headerStr = _buildHeader(_encodeAesPrefix, usedKeyId);
        break;
    }

    final headerBytes = utf8.encode(headerStr);
    Uint8List result;

    switch (actualType) {
      case EncryptionType.none:
        // No encryption, just prepend header
        final totalLength = headerBytes.length + input.length;
        result = Uint8List(totalLength);
        result.setAll(0, headerBytes);
        result.setAll(headerBytes.length, input);
        break;

      case EncryptionType.xorObfuscation:
        // XOR obfuscation on binary data
        final totalLength = headerBytes.length + input.length;
        result = Uint8List(totalLength);
        result.setAll(0, headerBytes);
        _applyXorToDest(input, usedKey, result, headerBytes.length);
        break;

      case EncryptionType.chacha20Poly1305:
        // ChaCha20-Poly1305 AEAD encryption
        final key32 = _deriveKey32(usedKey);
        // Combine header and additional context as AAD for stronger integrity
        final aadBytes = aad != null
            ? Uint8List.fromList([...headerBytes, ...aad])
            : headerBytes;
        final encrypted = ChaCha20Poly1305.encryptBytes(
          plaintext: input,
          key: key32,
          aad: aadBytes,
        );
        final totalLength = headerBytes.length + encrypted.length;
        result = Uint8List(totalLength);
        result.setAll(0, headerBytes);
        result.setAll(headerBytes.length, encrypted);
        break;

      case EncryptionType.aes256Gcm:
        // AES-256-GCM AEAD encryption
        final key32 = _deriveKey32(usedKey);
        // Combine header and additional context as AAD for stronger integrity
        final aadBytes = aad != null
            ? Uint8List.fromList([...headerBytes, ...aad])
            : headerBytes;
        final encrypted = AESGCM.encryptBytes(
          plaintext: input,
          key: key32,
          aad: aadBytes,
        );
        final totalLength = headerBytes.length + encrypted.length;
        result = Uint8List(totalLength);
        result.setAll(0, headerBytes);
        result.setAll(headerBytes.length, encrypted);
        break;
    }

    return result;
  }

  /// Decode binary data (reverse of encodeBytes)
  /// Returns: decrypted binary data (without header)
  ///
  /// [aad] - Additional Authenticated Data for AEAD algorithms.
  /// Must match the AAD used during encryption.
  static Uint8List decodeBytes(Uint8List encoded,
      {Uint8List? customKey, int? keyId, Uint8List? aad}) {
    if (encoded.isEmpty) return Uint8List(0);

    try {
      // Check for prefixes
      if (_hasPrefix(encoded, _utf8PrefixBytes)) {
        return _decodeBytesWithHeader(
            encoded, _utf8PrefixBytes, EncryptionType.xorObfuscation,
            customKey: customKey, keyId: keyId, aad: aad);
      } else if (_hasPrefix(encoded, _rawPrefixBytes)) {
        return _decodeBytesWithHeader(
            encoded, _rawPrefixBytes, EncryptionType.none,
            customKey: customKey, keyId: keyId, aad: aad);
      } else if (_hasPrefix(encoded, _chacha20PrefixBytes)) {
        return _decodeBytesWithHeader(
            encoded, _chacha20PrefixBytes, EncryptionType.chacha20Poly1305,
            customKey: customKey, keyId: keyId, aad: aad);
      } else if (_hasPrefix(encoded, _aesPrefixBytes)) {
        return _decodeBytesWithHeader(
            encoded, _aesPrefixBytes, EncryptionType.aes256Gcm,
            customKey: customKey, keyId: keyId, aad: aad);
      } else {
        // No header, return as-is
        return encoded;
      }
    } catch (e) {
      return Uint8List(0);
    }
  }

  static Uint8List _decodeBytesWithHeader(
      Uint8List encoded, List<int> prefixBytes, EncryptionType encType,
      {Uint8List? customKey, int? keyId, Uint8List? aad}) {
    // Find end of header
    int underscoreCount = 0;
    int headerEndIndex = -1;

    for (int i = prefixBytes.length; i < encoded.length; i++) {
      if (encoded[i] == 95) {
        // '_'
        underscoreCount++;
        if (underscoreCount == 2) {
          headerEndIndex = i + 1;
          break;
        }
      }
    }

    if (headerEndIndex == -1) {
      return encoded;
    }

    final headerBytes = encoded.sublist(0, headerEndIndex);
    final headerStr = utf8.decode(headerBytes);
    final dataBytes = encoded.sublist(headerEndIndex);

    Uint8List key = customKey ?? _activeKey;
    final keyIdMatch = RegExp(r'_k(\d+)_').firstMatch(headerStr);
    int headerKeyId = keyIdMatch != null ? int.parse(keyIdMatch.group(1)!) : 0;

    if (headerKeyId != (keyId ?? _currentKeyId)) {
      if (headerKeyId == 0) {
        key = _defaultXorKey;
      } else if (_fallbackKeys?.containsKey(headerKeyId) ?? false) {
        key = _fallbackKeys![headerKeyId] ?? key;
      }
    }

    switch (encType) {
      case EncryptionType.none:
        return dataBytes;

      case EncryptionType.xorObfuscation:
        return _applyXor(dataBytes, key);

      case EncryptionType.chacha20Poly1305:
        final key32 = _deriveKey32(key);
        try {
          // Combine header and additional context as AAD for verification
          final aadBytes = aad != null
              ? Uint8List.fromList([...headerBytes, ...aad])
              : headerBytes;
          return ChaCha20Poly1305.decryptBytes(
            encryptedData: dataBytes,
            key: key32,
            aad: aadBytes,
          );
        } catch (e) {
          return dataBytes;
        }

      case EncryptionType.aes256Gcm:
        final key32 = _deriveKey32(key);
        try {
          // Combine header and additional context as AAD for verification
          final aadBytes = aad != null
              ? Uint8List.fromList([...headerBytes, ...aad])
              : headerBytes;
          return AESGCM.decryptBytes(
            encryptedData: dataBytes,
            key: key32,
            aad: aadBytes,
          );
        } catch (e) {
          return dataBytes;
        }
    }
  }

  /// Highest performance encoding: returns UTF-8 bytes, optionally encrypted
  /// Returns complete binary data with header bytes, suitable for direct storage in files or binary dataspaces
  static Uint8List encode(String input,
      {Uint8List? customKey, int? keyId, EncryptionType? encryptionType}) {
    if (_encryptionType == EncryptionType.none && encryptionType == null) {
      return Uint8List.fromList(utf8.encode(input));
    }

    if (input.isEmpty) return Uint8List(0);
    final usedKey = customKey ?? _activeKey;
    final usedKeyId = keyId ?? _currentKeyId;
    final bytes = utf8.encode(input);

    // Determine encryption type (priority: parameter > global setting)
    EncryptionType actualType = encryptionType ?? _encryptionType;

    String headerStr;
    switch (actualType) {
      case EncryptionType.none:
        headerStr = _buildHeader(_encodeRawPrefix, usedKeyId);
        break;
      case EncryptionType.xorObfuscation:
        headerStr = _buildHeader(_encodeUtf8Prefix, usedKeyId);
        break;
      case EncryptionType.chacha20Poly1305:
        headerStr = _buildHeader(_encodeChaCha20Prefix, usedKeyId);
        break;
      case EncryptionType.aes256Gcm:
        headerStr = _buildHeader(_encodeAesPrefix, usedKeyId);
        break;
    }

    final headerBytes = utf8.encode(headerStr);
    Uint8List result;

    switch (actualType) {
      case EncryptionType.none:
        // No encryption, just copy data
        final totalLength = headerBytes.length + bytes.length;
        result = Uint8List(totalLength);
        result.setAll(0, headerBytes);
        result.setAll(headerBytes.length, bytes);
        break;

      case EncryptionType.xorObfuscation:
        // XOR obfuscation
        final totalLength = headerBytes.length + bytes.length;
        result = Uint8List(totalLength);
        result.setAll(0, headerBytes);
        _applyXorToDest(bytes, usedKey, result, headerBytes.length);
        break;

      case EncryptionType.chacha20Poly1305:
        // ChaCha20-Poly1305 AEAD encryption
        final key32 = _deriveKey32(usedKey);
        final encrypted = ChaCha20Poly1305.encrypt(
          plaintext: input,
          key: key32,
          aad: headerBytes, // Use header as AAD
        );
        // encrypted format: [nonce(12)] [ciphertext] [tag(16)]
        final totalLength = headerBytes.length + encrypted.length;
        result = Uint8List(totalLength);
        result.setAll(0, headerBytes);
        result.setAll(headerBytes.length, encrypted);
        break;

      case EncryptionType.aes256Gcm:
        // AES-256-GCM AEAD encryption
        final key32 = _deriveKey32(usedKey);
        final encrypted = AESGCM.encrypt(
          plaintext: input,
          key: key32,
          aad: headerBytes, // Use header as AAD
        );
        // encrypted format: [nonce(12)] [ciphertext] [tag(16)]
        final totalLength = headerBytes.length + encrypted.length;
        result = Uint8List(totalLength);
        result.setAll(0, headerBytes);
        result.setAll(headerBytes.length, encrypted);
        break;
    }

    return result;
  }

  /// Decode string from binary data with header information
  static String decode(Uint8List encoded, {Uint8List? customKey, int? keyId}) {
    if (encoded.isEmpty) return '';

    try {
      // Check for prefixes directly on bytes to avoid expensive utf8.decode on the whole buffer
      if (_hasPrefix(encoded, _utf8PrefixBytes)) {
        return _decodeWithHeader(
            encoded, _utf8PrefixBytes, EncryptionType.xorObfuscation,
            customKey: customKey, keyId: keyId);
      } else if (_hasPrefix(encoded, _rawPrefixBytes)) {
        return _decodeWithHeader(encoded, _rawPrefixBytes, EncryptionType.none,
            customKey: customKey, keyId: keyId);
      } else if (_hasPrefix(encoded, _chacha20PrefixBytes)) {
        return _decodeWithHeader(
            encoded, _chacha20PrefixBytes, EncryptionType.chacha20Poly1305,
            customKey: customKey, keyId: keyId);
      } else if (_hasPrefix(encoded, _aesPrefixBytes)) {
        return _decodeWithHeader(
            encoded, _aesPrefixBytes, EncryptionType.aes256Gcm,
            customKey: customKey, keyId: keyId);
      } else {
        // Fallback for legacy files or plain text
        return utf8.decode(encoded);
      }
    } catch (e) {
      return '';
    }
  }

  static String _decodeWithHeader(
      Uint8List encoded, List<int> prefixBytes, EncryptionType encType,
      {Uint8List? customKey, int? keyId}) {
    // Find end of header: prefix + v<ver>_k<id>_
    // We scan for the third underscore.
    // Prefix format: ToU8_ or ToUr_ (ends with _)
    // Header format: ToU8_v1_k0_

    int underscoreCount = 0;
    int headerEndIndex = -1;

    // Start scanning from prefix length
    for (int i = prefixBytes.length; i < encoded.length; i++) {
      if (encoded[i] == 95) {
        // 95 is '_'
        underscoreCount++;
        if (underscoreCount == 2) {
          headerEndIndex = i + 1;
          break;
        }
      }
    }

    if (headerEndIndex == -1) {
      // Malformed header, try fallback
      return utf8.decode(encoded);
    }

    final headerBytes = encoded.sublist(0, headerEndIndex);
    final headerStr = utf8.decode(headerBytes);
    final dataBytes = encoded.sublist(headerEndIndex);

    Uint8List key = customKey ?? _activeKey;
    // Extract keyId from header using regex pattern '_k<number>_'
    final keyIdMatch = RegExp(r'_k(\d+)_').firstMatch(headerStr);
    int headerKeyId = keyIdMatch != null ? int.parse(keyIdMatch.group(1)!) : 0;

    // If an expected keyId is provided and doesn't match header keyId, try to retrieve the proper key
    if (headerKeyId != (keyId ?? _currentKeyId)) {
      if (headerKeyId == 0) {
        key = _defaultXorKey;
      } else if (_fallbackKeys?.containsKey(headerKeyId) ?? false) {
        key = _fallbackKeys![headerKeyId] ?? key;
      }
    }

    switch (encType) {
      case EncryptionType.none:
        return utf8.decode(dataBytes);

      case EncryptionType.xorObfuscation:
        final restored = _applyXor(dataBytes, key);
        return utf8.decode(restored);

      case EncryptionType.chacha20Poly1305:
        final key32 = _deriveKey32(key);
        try {
          return ChaCha20Poly1305.decrypt(
            encryptedData: dataBytes,
            key: key32,
            aad: headerBytes,
          );
        } catch (e) {
          // Fallback to plain decode if decryption fails
          return utf8.decode(dataBytes);
        }

      case EncryptionType.aes256Gcm:
        final key32 = _deriveKey32(key);
        try {
          return AESGCM.decrypt(
            encryptedData: dataBytes,
            key: key32,
            aad: headerBytes,
          );
        } catch (e) {
          // Fallback to plain decode if decryption fails
          return utf8.decode(dataBytes);
        }
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

  /* Adding caching logic for key precomputation */
  static List<int>? _cachedKey;
  static List<int>? _cachedKeyWordCache;

  /* Further optimized _applyXor implementation using precomputed keyWordCache with caching */
  static Uint8List _applyXor(List<int> bytes, List<int> key) {
    final int len = bytes.length;
    final Uint8List result = Uint8List(len);
    _applyXorToDest(bytes, key, result, 0);
    return result;
  }

  /// Applies XOR to [bytes] using [key] and writes the result to [destination] starting at [destinationOffset].
  /// This avoids allocating a new buffer if one is already available.
  static void _applyXorToDest(List<int> bytes, List<int> key,
      Uint8List destination, int destinationOffset) {
    final int keyLength = key.length;
    final int len = bytes.length;
    final Uint8List inBytes =
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final ByteData inData = ByteData.sublistView(inBytes);
    final ByteData outData =
        ByteData.sublistView(destination, destinationOffset);

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

    // Optimization: Use Uint32List for input if aligned and little endian
    Uint32List? inWords;
    if (Endian.host == Endian.little && inBytes.offsetInBytes % 4 == 0) {
      inWords = inBytes.buffer.asUint32List(inBytes.offsetInBytes, blockCount);
    }

    if (inWords != null) {
      // Fast path
      for (int j = 0; j < blockCount; j++) {
        int i = j * 4;
        int r = i % keyLength;
        int keyWord = keyWordCache[r];
        int inputWord = inWords[j];
        outData.setUint32(i, inputWord ^ keyWord, Endian.little);
      }
    } else {
      // Slow path (unaligned or big endian)
      for (int j = 0; j < blockCount; j++) {
        int i = j * 4;
        int r = i % keyLength;
        int keyWord = keyWordCache[r];
        int inputWord = inData.getUint32(i, Endian.little);
        outData.setUint32(i, inputWord ^ keyWord, Endian.little);
      }
    }

    // Process any remaining bytes
    for (int i = blockCount * 4; i < len; i++) {
      destination[destinationOffset + i] = inBytes[i] ^ key[i % keyLength];
    }
  }

  /// Check if utf8 data is encoded with our method
  static bool isEncoded(Uint8List bytes) {
    return _hasPrefix(bytes, _utf8PrefixBytes) ||
        _hasPrefix(bytes, _rawPrefixBytes) ||
        _hasPrefix(bytes, _chacha20PrefixBytes) ||
        _hasPrefix(bytes, _aesPrefixBytes);
  }

  // encoding method, encoding version, keyId, for example 'ToB64_v1_k0_'
  static String _buildHeader(String basePrefix, int keyId) {
    return '${basePrefix}v${_encodingVersion}_k${keyId}_';
  }

  /// Get key ID
  static int getCurrentKeyId() {
    return _currentKeyId;
  }

  /// Get current complete encoding state, for isolate thread passing
  static EncoderConfig getCurrentEncodingState() {
    return EncoderConfig(
      activeKey: _activeKey,
      keyId: _currentKeyId,
      fallbackKeys: _fallbackKeys,
      encryptionType: _encryptionType,
    );
  }

  /// set complete encoding state, for isolate thread passing
  static void setEncodingState(EncoderConfig config) {
    _activeKey = config.activeKey;
    _currentKeyId = config.keyId;
    _encryptionType = config.encryptionType;
    if (config.fallbackKeys != null) {
      _fallbackKeys = config.fallbackKeys;
    }
  }

  /// Check if encoding is enabled
  static bool get isEncodingEnabled => _encryptionType != EncryptionType.none;
}
