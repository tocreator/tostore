import 'dart:convert';
import 'dart:typed_data';

import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/encoder_config.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'aes_gcm.dart';
import 'chacha20_poly1305.dart';

/// Per-instance data encryption and obfuscation manager.
///
/// Holds key material, active keyId, fallback history keys, encryption type/scope,
/// and instance-scoped key precomputation caches so multiple database instances
/// and isolate workers never share mutable global encryption state.
class EncryptionManager {
  /// encryption version
  static const int _encodingVersion = 1;

  // default xor key
  static final Uint8List _defaultXorKey =
      Uint8List.fromList([42, 127, 89, 13, 71, 240, 23, 190, 119, 63]);

  // High-performance encryption: UTF8 encryption with XOR obfuscation (binary data)
  static const String _encodeUtf8Prefix = "ToU8_";

  // Raw encryption: plain UTF8 encryption without obfuscation (binary data)
  static const String _encodeRawPrefix = "ToUr_";

  // ChaCha20-Poly1305 encrypted binary data prefix
  static const String _encodeChaCha20Prefix = "ToCh_";

  // AES-256-GCM encrypted binary data prefix
  static const String _encodeAesPrefix = "ToAe_";

  // Instance encryption type
  EncryptionType _encryptionType;

  // Instance encryption scope
  EncryptionScope _encryptionScope;

  // Instance active key
  Uint8List _activeKey;

  // Fallback keys, mapping keyId to the key.
  Map<int, Uint8List>? _fallbackKeys;

  int _currentKeyId;

  // Instance-scoped caches for key precomputation and derivation
  List<int>? _cachedKey;
  List<int>? _cachedKeyWordCache;
  Uint8List? _cachedDeriveInputKey;
  Uint8List? _cachedDerivedKey32;
  Map<int, Uint8List>? _cachedFallbackMap;
  List<int>? _cachedSortedFallbackIds;

  EncryptionManager({
    EncryptionType encryptionType = EncryptionType.xorObfuscation,
    EncryptionScope encryptionScope = EncryptionScope.standard,
    Uint8List? activeKey,
    int keyId = 0,
    Map<int, Uint8List>? fallbackKeys,
  })  : _encryptionType = encryptionType,
        _encryptionScope = encryptionScope,
        _activeKey = (activeKey != null && activeKey.isNotEmpty)
            ? Uint8List.fromList(activeKey)
            : _defaultXorKey,
        _currentKeyId = keyId,
        _fallbackKeys = _copyFallbackMap(fallbackKeys);

  factory EncryptionManager.fromConfig(EncoderConfig config) {
    return EncryptionManager(
      encryptionType: config.encryptionType,
      encryptionScope: config.encryptionScope,
      activeKey: config.activeKey,
      keyId: config.keyId,
      fallbackKeys: config.fallbackKeys,
    );
  }

  /// Builds an isolated instance from static [DataStoreConfig] only
  /// (intended for pure in-memory mode where [KeyManager.initialize] does not run
  /// and there is no persisted key history on disk).
  factory EncryptionManager.fromDataStoreConfig(DataStoreConfig? config) {
    final ec = config?.encryptionConfig;
    if (ec == null || ec.encryptionType == EncryptionType.none) {
      return EncryptionManager(
        encryptionType: EncryptionType.none,
        encryptionScope: ec?.encryptionScope ?? EncryptionScope.standard,
        activeKey: _defaultXorKey,
        keyId: 0,
      );
    }
    final activeKey = generateKey(ec.resolveEncodingKey());
    return EncryptionManager(
      encryptionType: ec.encryptionType,
      encryptionScope: ec.encryptionScope,
      activeKey: activeKey,
      keyId: 1,
      fallbackKeys: <int, Uint8List>{1: activeKey},
    );
  }

  static Map<int, Uint8List>? _copyFallbackMap(Map<int, Uint8List>? keys) {
    if (keys == null) return null;
    if (keys.isEmpty) return const <int, Uint8List>{};
    return Map<int, Uint8List>.unmodifiable(
      keys.map((k, v) => MapEntry(k, Uint8List.fromList(v))),
    );
  }

  /// Set encryption type (recommended API)
  void setEncryptionType(EncryptionType type) {
    _encryptionType = type;
  }

  /// Get current encryption type
  EncryptionType getEncryptionType() {
    return _encryptionType;
  }

  /// Set encryption scope
  void setEncryptionScope(EncryptionScope scope) {
    _encryptionScope = scope;
  }

  /// Get current encryption scope
  EncryptionScope getEncryptionScope() {
    return _encryptionScope;
  }

  /// Sets the fallback keys. This is used to provide older keys for decoding data
  /// that might have been encrypted with a previous key.
  void setFallbackKeys(Map<int, Uint8List>? keys) {
    _fallbackKeys = _copyFallbackMap(keys);
    _cachedFallbackMap = null;
    _cachedSortedFallbackIds = null;
  }

  void setCurrentKey(String key, int keyId) {
    _activeKey = generateKey(key);
    _currentKeyId = keyId;
  }

  /// The key should be a Uint8List, each byte representing a value (0-255)
  void setKey(Uint8List customKey) {
    if (customKey.isNotEmpty) {
      _activeKey = Uint8List.fromList(customKey);
    } else {
      _activeKey = _defaultXorKey;
    }
  }

  /// Reset to default key
  void resetToDefaultKey() {
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
  Uint8List _deriveKey32(Uint8List key) {
    final effectiveKey = key.isEmpty ? _defaultXorKey : key;
    if (effectiveKey.length == 32) {
      return effectiveKey; // Already correct size, no conversion needed!
    }

    final cachedIn = _cachedDeriveInputKey;
    final cachedOut = _cachedDerivedKey32;
    if (cachedIn != null &&
        cachedOut != null &&
        _bytesEqual(cachedIn, effectiveKey)) {
      return cachedOut;
    }

    // Simple key derivation: repeat and XOR to get 32 bytes
    final result = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      result[i] = effectiveKey[i % effectiveKey.length];
      // Add some mixing to avoid simple patterns
      if (i > 0) {
        result[i] ^= result[i - 1];
      }
    }
    _cachedDeriveInputKey = Uint8List.fromList(effectiveKey);
    _cachedDerivedKey32 = result;
    return result;
  }

  static Uint8List? _normalizeCustomKey(Uint8List? customKey) {
    if (customKey == null || customKey.isEmpty) return null;
    return customKey;
  }

  static Uint8List _buildAad(Uint8List headerBytes, Uint8List? aad) {
    if (aad == null || aad.isEmpty) {
      return headerBytes;
    }
    final combined = Uint8List(headerBytes.length + aad.length);
    combined.setAll(0, headerBytes);
    combined.setAll(headerBytes.length, aad);
    return combined;
  }

  /// Encode binary data directly (without string conversion)
  /// Suitable for pre-serialized binary data (e.g., MessagePack)
  /// Returns: [header][encrypted binary data]
  ///
  /// [aad] - Additional Authenticated Data for AEAD algorithms.
  /// Should include context like partition index, entry seq, etc.
  /// If not provided, only the header will be used as AAD (less secure).
  Uint8List encodeBytes(Uint8List input,
      {Uint8List? customKey,
      int? keyId,
      EncryptionType? encryptionType,
      Uint8List? aad}) {
    if (_encryptionType == EncryptionType.none && encryptionType == null) {
      return input;
    }

    if (input.isEmpty) return Uint8List(0);
    final usedKey = _normalizeCustomKey(customKey) ?? _activeKey;
    final usedKeyId = keyId ?? _currentKeyId;

    // Determine encryption type (priority: parameter > instance setting)
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
        final aadBytes = _buildAad(headerBytes, aad);
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
        final aadBytes = _buildAad(headerBytes, aad);
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

  /// Decode binary data (reverse of encodeBytes).
  /// Returns decrypted binary data (without header), or passes through raw
  /// unencrypted bytes when no recognized encryption header prefix is present.
  ///
  /// Throws [DbException] on decryption, authentication, key lookup, or
  /// malformed/truncated encrypted payload failures (never returns ciphertext or
  /// silent empty bytes for headered data).
  ///
  /// [aad] - Additional Authenticated Data for AEAD algorithms.
  /// Must match the AAD used during encryption.
  Uint8List decodeBytes(Uint8List encoded,
      {Uint8List? customKey, int? keyId, Uint8List? aad}) {
    if (encoded.isEmpty) return Uint8List(0);

    final parsed = _tryParseHeader(encoded);
    if (parsed == null) {
      // No encryption header, return unencrypted payload as-is.
      return encoded;
    }

    return _decryptWithHeaderBytes(
      encoded,
      parsed,
      customKey: _normalizeCustomKey(customKey),
      keyId: keyId,
      aad: aad,
    );
  }

  Uint8List _decryptWithHeaderBytes(
    Uint8List encoded,
    ({
      EncryptionType encType,
      int? version,
      int headerEndIndex,
      int? keyId
    }) parsed, {
    Uint8List? customKey,
    int? keyId,
    Uint8List? aad,
  }) {
    _validateParsedHeaderVersion(parsed.version, parsed.encType);
    if (parsed.headerEndIndex >= encoded.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message:
              'Encrypted binary payload is empty or truncated (encType=${parsed.encType.name})',
        ),
      ]);
    }

    if (parsed.encType == EncryptionType.none) {
      return encoded.sublist(parsed.headerEndIndex);
    }

    final headerView = Uint8List.sublistView(encoded, 0, parsed.headerEndIndex);
    final dataView = Uint8List.sublistView(encoded, parsed.headerEndIndex);
    final candidates = _resolveKeyCandidates(
      parsed.encType,
      parsed.keyId,
      customKey: customKey,
      keyId: keyId,
      forUtf8String: false,
    );

    Object? lastError;
    for (int i = 0; i < candidates.length; i++) {
      try {
        return _decryptBytesWithKey(
          parsed.encType,
          headerView,
          dataView,
          candidates[i],
          aad,
        );
      } catch (e) {
        lastError = e;
      }
    }

    throw _wrapDecryptionError(
      lastError,
      'Failed to decrypt payload (encType=${parsed.encType.name}, headerKeyId=${parsed.keyId})',
    );
  }

  /// Highest performance encryption: returns UTF-8 bytes, optionally encrypted
  /// Returns complete binary data with header bytes, suitable for direct storage in files or binary dataspaces
  Uint8List encode(String input,
      {Uint8List? customKey, int? keyId, EncryptionType? encryptionType}) {
    if (_encryptionType == EncryptionType.none && encryptionType == null) {
      return Uint8List.fromList(utf8.encode(input));
    }

    if (input.isEmpty) return Uint8List(0);
    final usedKey = _normalizeCustomKey(customKey) ?? _activeKey;
    final usedKeyId = keyId ?? _currentKeyId;
    final bytes = utf8.encode(input);

    // Determine encryption type (priority: parameter > instance setting)
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

  /// Decode string from binary data with header information.
  ///
  /// Throws [DbException] if decryption, key resolution, or UTF-8 decoding fails.
  String decode(Uint8List encoded, {Uint8List? customKey, int? keyId}) {
    if (encoded.isEmpty) return '';

    final parsed = _tryParseHeader(encoded);
    if (parsed == null) {
      // Fallback for legacy unencrypted plain UTF-8 files
      try {
        return utf8.decode(encoded, allowMalformed: false);
      } catch (e) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysInvalidDataFormat,
            message: 'Failed to decode plain UTF-8 data: $e',
          ),
        ]);
      }
    }

    return _decryptWithHeaderToString(
      encoded,
      parsed,
      customKey: _normalizeCustomKey(customKey),
      keyId: keyId,
    );
  }

  String _decryptWithHeaderToString(
    Uint8List encoded,
    ({
      EncryptionType encType,
      int? version,
      int headerEndIndex,
      int? keyId
    }) parsed, {
    Uint8List? customKey,
    int? keyId,
  }) {
    _validateParsedHeaderVersion(parsed.version, parsed.encType);
    if (parsed.headerEndIndex >= encoded.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message:
              'Encrypted string payload is empty or truncated (encType=${parsed.encType.name})',
        ),
      ]);
    }

    final headerView = Uint8List.sublistView(encoded, 0, parsed.headerEndIndex);
    final dataView = Uint8List.sublistView(encoded, parsed.headerEndIndex);

    if (parsed.encType == EncryptionType.none) {
      try {
        return utf8.decode(dataView, allowMalformed: false);
      } catch (e) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysInvalidDataFormat,
            message: 'Failed to decode raw headered UTF-8 payload: $e',
          ),
        ]);
      }
    }

    final candidates = _resolveKeyCandidates(
      parsed.encType,
      parsed.keyId,
      customKey: customKey,
      keyId: keyId,
      forUtf8String: true,
    );

    Object? lastError;
    for (int i = 0; i < candidates.length; i++) {
      try {
        final plainBytes = _decryptBytesWithKey(
          parsed.encType,
          headerView,
          dataView,
          candidates[i],
          null,
        );
        return utf8.decode(plainBytes, allowMalformed: false);
      } catch (e) {
        lastError = e;
      }
    }

    throw _wrapDecryptionError(
      lastError,
      'Failed to decrypt string payload (encType=${parsed.encType.name}, headerKeyId=${parsed.keyId})',
    );
  }

  static void _validateParsedHeaderVersion(
      int? version, EncryptionType encType) {
    if (version != null && version != _encodingVersion) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message:
              'Unsupported encryption header version v$version for ${encType.name} (expected v$_encodingVersion)',
        ),
      ]);
    }
  }

  List<int> _sortedFallbackIds(Map<int, Uint8List> fb) {
    final cached = _cachedSortedFallbackIds;
    if (cached != null && identical(_cachedFallbackMap, fb)) {
      return cached;
    }
    final sorted = fb.keys.toList()..sort();
    _cachedFallbackMap = fb;
    _cachedSortedFallbackIds = sorted;
    return sorted;
  }

  List<Uint8List> _resolveKeyCandidates(
    EncryptionType encType,
    int? headerKeyId, {
    required Uint8List? customKey,
    required int? keyId,
    required bool forUtf8String,
  }) {
    // Explicit standalone customKey override without keyId scope: never fall back
    // to instance keys so callers testing/using a specific key fail cleanly.
    if (customKey != null && keyId == null) {
      return <Uint8List>[customKey];
    }

    final int expectedKeyId = keyId ?? _currentKeyId;
    final candidates = <Uint8List>[];

    void addCandidate(Uint8List? k) {
      if (k == null || k.isEmpty) return;
      for (int i = 0; i < candidates.length; i++) {
        if (_bytesEqual(candidates[i], k)) return;
      }
      candidates.add(k);
    }

    if (headerKeyId != null) {
      if (headerKeyId == expectedKeyId) {
        addCandidate(customKey ?? _activeKey);
        if (customKey == null &&
            headerKeyId == 0 &&
            (encType == EncryptionType.chacha20Poly1305 ||
                encType == EncryptionType.aes256Gcm)) {
          addCandidate(_fallbackKeys?[0]);
          addCandidate(_defaultXorKey);
        }
      } else {
        final fallback = _fallbackKeys?[headerKeyId];
        if (fallback != null) {
          addCandidate(fallback);
        } else if (headerKeyId == 0) {
          addCandidate(_defaultXorKey);
        } else {
          throw DbException([
            GeneralStatus(
              type: ResultType.sysIoDataCorrupted,
              message:
                  'Missing decryption key for keyId=$headerKeyId (expectedKeyId=$expectedKeyId)',
            ),
          ]);
        }
      }
      return candidates;
    }

    // Legacy header without keyId (e.g. ToU8_v1_<payload> or ToU8_<payload>).
    if (encType == EncryptionType.xorObfuscation) {
      final preferred = customKey ??
          _fallbackKeys?[0] ??
          (_currentKeyId == 0 ? _activeKey : _defaultXorKey);
      addCandidate(preferred);
      if (forUtf8String && customKey == null) {
        addCandidate(_defaultXorKey);
        addCandidate(_activeKey);
        final fb = _fallbackKeys;
        if (fb != null && fb.isNotEmpty) {
          for (final id in _sortedFallbackIds(fb)) {
            addCandidate(fb[id]);
          }
        }
      }
      return candidates;
    }

    // AEAD without keyId: MAC prevents false positives, so try active then history.
    addCandidate(customKey ?? _activeKey);
    if (customKey == null) {
      addCandidate(_fallbackKeys?[0]);
      addCandidate(_defaultXorKey);
      final fb = _fallbackKeys;
      if (fb != null && fb.isNotEmpty) {
        for (final id in _sortedFallbackIds(fb)) {
          addCandidate(fb[id]);
        }
      }
    }
    return candidates;
  }

  Uint8List _decryptBytesWithKey(
    EncryptionType encType,
    Uint8List headerBytes,
    Uint8List dataBytes,
    Uint8List key,
    Uint8List? aad,
  ) {
    switch (encType) {
      case EncryptionType.none:
        return dataBytes;

      case EncryptionType.xorObfuscation:
        return _applyXor(dataBytes, key);

      case EncryptionType.chacha20Poly1305:
        final key32 = _deriveKey32(key);
        final aadBytes = _buildAad(headerBytes, aad);
        return ChaCha20Poly1305.decryptBytes(
          encryptedData: dataBytes,
          key: key32,
          aad: aadBytes,
          allowLegacyJsMac: true,
        );

      case EncryptionType.aes256Gcm:
        final key32 = _deriveKey32(key);
        final aadBytes = _buildAad(headerBytes, aad);
        return AESGCM.decryptBytes(
          encryptedData: dataBytes,
          key: key32,
          aad: aadBytes,
        );
    }
  }

  static DbException _wrapDecryptionError(Object? error, String context) {
    if (error is DbException) {
      return error;
    }
    return DbException([
      GeneralStatus(
        type: ResultType.sysIoDataCorrupted,
        message: error == null ? context : '$context: $error',
      ),
    ]);
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static EncryptionType? _matchHeaderType(Uint8List bytes) {
    if (bytes.length < 5 ||
        bytes[0] != 84 ||
        bytes[1] != 111 ||
        bytes[4] != 95) {
      return null;
    }
    final int b2 = bytes[2];
    final int b3 = bytes[3];
    if (b2 == 85 && b3 == 56) return EncryptionType.xorObfuscation; // ToU8_
    if (b2 == 85 && b3 == 114) return EncryptionType.none; // ToUr_
    if (b2 == 67 && b3 == 104) return EncryptionType.chacha20Poly1305; // ToCh_
    if (b2 == 65 && b3 == 101) return EncryptionType.aes256Gcm; // ToAe_
    return null;
  }

  /// Parse `<digits>_` right at [start] (bounded by [maxDigits]).
  static ({int value, int nextIndex})? _tryParseTaggedUint(
    Uint8List bytes,
    int start,
    int maxDigits,
  ) {
    int value = 0;
    int digits = 0;
    int i = start;
    while (i < bytes.length && digits < maxDigits) {
      final int b = bytes[i];
      if (b < 48 || b > 57) break;
      value = value * 10 + (b - 48);
      digits++;
      i++;
    }
    if (digits == 0 || i >= bytes.length || bytes[i] != 95) {
      return null;
    }
    return (value: value, nextIndex: i + 1);
  }

  /// Parse header at offset 0:
  /// - Standard: `<prefix>v<ver>_k<keyId>_`
  /// - Legacy versioned without keyId: `<prefix>v<ver>_`
  /// - Earliest prefix-only: `<prefix>`
  static ({
    EncryptionType encType,
    int? version,
    int headerEndIndex,
    int? keyId,
  })? _tryParseHeader(Uint8List bytes) {
    final encType = _matchHeaderType(bytes);
    if (encType == null) return null;

    int pos = 5;
    if (pos + 2 < bytes.length && bytes[pos] == 118) {
      // 'v'
      final ver = _tryParseTaggedUint(bytes, pos + 1, 4);
      if (ver != null) {
        final int verEnd = ver.nextIndex;
        if (verEnd + 2 < bytes.length && bytes[verEnd] == 107) {
          // 'k'
          final key = _tryParseTaggedUint(bytes, verEnd + 1, 10);
          if (key != null) {
            return (
              encType: encType,
              version: ver.value,
              headerEndIndex: key.nextIndex,
              keyId: key.value,
            );
          }
        }
        return (
          encType: encType,
          version: ver.value,
          headerEndIndex: verEnd,
          keyId: null,
        );
      }
    }

    return (
      encType: encType,
      version: null,
      headerEndIndex: pos,
      keyId: null,
    );
  }

  /* Further optimized _applyXor implementation using precomputed keyWordCache with instance caching */
  Uint8List _applyXor(List<int> bytes, List<int> key) {
    final int len = bytes.length;
    final Uint8List result = Uint8List(len);
    _applyXorToDest(bytes, key, result, 0);
    return result;
  }

  /// Applies XOR to [bytes] using [key] and writes the result to [destination] starting at [destinationOffset].
  /// This avoids allocating a new buffer if one is already available.
  void _applyXorToDest(List<int> bytes, List<int> key, Uint8List destination,
      int destinationOffset) {
    if (key.isEmpty) {
      key = _defaultXorKey;
    }
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
      useCache = identical(_cachedKey, key);
      if (!useCache) {
        useCache = true;
        for (int i = 0; i < keyLength; i++) {
          if (_cachedKey![i] != key[i]) {
            useCache = false;
            break;
          }
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

  /// Check if data carries one of our recognized encryption header prefixes.
  static bool isEncoded(Uint8List bytes) {
    return _matchHeaderType(bytes) != null;
  }

  // encryption method, encryption version, keyId, for example 'ToB64_v1_k0_'
  static String _buildHeader(String basePrefix, int keyId) {
    return '${basePrefix}v${_encodingVersion}_k${keyId}_';
  }

  /// Get key ID
  int getCurrentKeyId() {
    return _currentKeyId;
  }

  /// Parse the keyId from encoded bytes header.
  /// Returns null if the data is not encoded with any of our methods, or has no keyId (e.g. legacy header).
  static int? parseKeyId(Uint8List bytes) {
    return _tryParseHeader(bytes)?.keyId;
  }

  /// Get current complete encryption state snapshot for isolate/worker passing.
  EncoderConfig getCurrentEncodingState() {
    final fb = _fallbackKeys;
    return EncoderConfig(
      activeKey: Uint8List.fromList(_activeKey),
      keyId: _currentKeyId,
      fallbackKeys: _copyFallbackMap(fb),
      encryptionType: _encryptionType,
      encryptionScope: _encryptionScope,
    );
  }

  /// Set complete encryption state
  void setEncodingState(EncoderConfig config) {
    _activeKey = config.activeKey.isNotEmpty
        ? Uint8List.fromList(config.activeKey)
        : _defaultXorKey;
    _currentKeyId = config.keyId;
    _encryptionType = config.encryptionType;
    _encryptionScope = config.encryptionScope;
    _fallbackKeys = _copyFallbackMap(config.fallbackKeys);
    _cachedFallbackMap = null;
    _cachedSortedFallbackIds = null;
  }

  /// Check if encryption is enabled
  bool get isEncodingEnabled => _encryptionType != EncryptionType.none;
}
