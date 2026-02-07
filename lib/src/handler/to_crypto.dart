// ToCrypto: value-level encode/decode with Base64 output. Cipher format: magic(3)+version(1)+type(1)+[nonce(12)+ciphertext+tag(16)].

import 'dart:convert';
import 'dart:typed_data';

import 'aes_gcm.dart';
import 'chacha20_poly1305.dart';
import 'sha256.dart';

/// Encryption type for [ToCrypto]. Specified in [ToCrypto.encode]; [ToCrypto.decode] reads it from the cipher header.
enum ToCryptoType {
  /// ChaCha20-Poly1305 AEAD
  chacha20Poly1305,

  /// AES-256-GCM AEAD
  aes256Gcm,
}

/// Value-level encode/decode. Output is Base64 and can be stored in JSON or a TEXT column.
///
/// Use [ToCryptoType] for the [type] parameter. The key is managed by the caller; [key] is required and must be [String] or [Uint8List].
///
/// Example:
/// ```dart
/// final b64 = ToCrypto.encode('plain', key: key);
/// final plain = ToCrypto.decode(b64, key: key);
/// ```
class ToCrypto {
  ToCrypto._();

  static const List<int> _magic = [0x54, 0x66, 0x43]; // "TfC"
  static const int _formatVersion = 0;
  static const int _typeByteChaCha20 = 0;
  static const int _typeByteAesGcm = 1;
  static const int _headerLen = 5; // magic(3) + version(1) + type(1)
  static const int _minCipherLen = _headerLen + 12 + 16; // + nonce + tag

  /// Normalizes [key] to 32 bytes: String via UTF-8 then SHA-256; Uint8List of length 32 used as-is, otherwise SHA-256 derived.
  static Uint8List _normalizeKey(Object key) {
    if (key is String) {
      if (key.isEmpty) {
        throw ArgumentError('ToCrypto: key must not be empty');
      }
      final keyBytes = Uint8List.fromList(utf8.encode(key));
      return keyBytes.length == 32 ? keyBytes : SHA256.hash(keyBytes);
    }
    if (key is Uint8List) {
      if (key.isEmpty) {
        throw ArgumentError('ToCrypto: key must not be empty');
      }
      return key.length == 32 ? key : SHA256.hash(key);
    }
    throw ArgumentError(
      'ToCrypto: key must be String or Uint8List, got ${key.runtimeType}',
    );
  }

  static Uint8List _aadOrEmpty(Uint8List? aad) => aad ?? Uint8List(0);

  /// Encodes a string and returns Base64.
  ///
  /// [plainText] Plain text; may be empty.
  /// [key] Secret key, [String] or [Uint8List] (SHA-256 derived if not 32 bytes).
  /// [type] Encryption type, default [ToCryptoType.chacha20Poly1305].
  /// [aad] Optional additional authenticated data; must match at decode.
  static String encode(
    String plainText, {
    required Object key,
    ToCryptoType type = ToCryptoType.chacha20Poly1305,
    Uint8List? aad,
  }) {
    final plainBytes = Uint8List.fromList(utf8.encode(plainText));
    final raw = _encodeBytes(
      plainBytes,
      key: key,
      type: type,
      aad: aad,
    );
    return base64Encode(raw);
  }

  /// Decodes Base64 cipher and returns plain string.
  ///
  /// [cipherBase64] Base64 string returned by [encode].
  /// [key] Secret key; must match the key used at encode.
  /// [aad] Must match encode if AAD was used at encode.
  /// Throws [ArgumentError] if key is wrong or data is corrupted.
  static String decode(
    String cipherBase64, {
    required Object key,
    Uint8List? aad,
  }) {
    if (cipherBase64.isEmpty) {
      throw ArgumentError('ToCrypto: cipherBase64 must not be empty');
    }
    List<int> decoded;
    try {
      decoded = base64Decode(cipherBase64);
    } catch (e) {
      throw ArgumentError('ToCrypto: invalid base64: $e');
    }
    final raw = Uint8List.fromList(decoded);
    final plain = _decodeBytes(raw, key: key, aad: aad);
    return utf8.decode(plain);
  }

  /// Encodes raw bytes and returns Base64.
  static String encodeBytes(
    Uint8List plainBytes, {
    required Object key,
    ToCryptoType type = ToCryptoType.chacha20Poly1305,
    Uint8List? aad,
  }) {
    return base64Encode(
        _encodeBytes(plainBytes, key: key, type: type, aad: aad));
  }

  /// Decodes Base64 cipher to raw plain bytes.
  static Uint8List decodeBytes(
    String cipherBase64, {
    required Object key,
    Uint8List? aad,
  }) {
    if (cipherBase64.isEmpty) {
      throw ArgumentError('ToCrypto: cipherBase64 must not be empty');
    }
    List<int> decoded;
    try {
      decoded = base64Decode(cipherBase64);
    } catch (e) {
      throw ArgumentError('ToCrypto: invalid base64: $e');
    }
    final raw = Uint8List.fromList(decoded);
    return _decodeBytes(raw, key: key, aad: aad);
  }

  /// Encodes to raw cipher bytes (e.g. for BLOB storage). Decode with [decodeFromBytes].
  static Uint8List encodeToBytes(
    String plainText, {
    required Object key,
    ToCryptoType type = ToCryptoType.chacha20Poly1305,
    Uint8List? aad,
  }) {
    return _encodeBytes(
      Uint8List.fromList(utf8.encode(plainText)),
      key: key,
      type: type,
      aad: aad,
    );
  }

  /// Decodes from raw cipher bytes (e.g. from BLOB) and returns plain string.
  static String decodeFromBytes(
    Uint8List cipherBytes, {
    required Object key,
    Uint8List? aad,
  }) {
    final plain = _decodeBytes(cipherBytes, key: key, aad: aad);
    return utf8.decode(plain);
  }

  static Uint8List _encodeBytes(
    Uint8List plainBytes, {
    required Object key,
    required ToCryptoType type,
    Uint8List? aad,
  }) {
    final key32 = _normalizeKey(key);
    final aadBytes = _aadOrEmpty(aad);

    Uint8List payload;
    switch (type) {
      case ToCryptoType.chacha20Poly1305:
        payload = ChaCha20Poly1305.encryptBytes(
          plaintext: plainBytes,
          key: key32,
          aad: aadBytes,
        );
        break;
      case ToCryptoType.aes256Gcm:
        payload = AESGCM.encryptBytes(
          plaintext: plainBytes,
          key: key32,
          aad: aadBytes,
        );
        break;
    }

    final typeByte = type == ToCryptoType.chacha20Poly1305
        ? _typeByteChaCha20
        : _typeByteAesGcm;
    final out = Uint8List(_headerLen + payload.length);
    out[0] = _magic[0];
    out[1] = _magic[1];
    out[2] = _magic[2];
    out[3] = _formatVersion;
    out[4] = typeByte;
    out.setRange(_headerLen, _headerLen + payload.length, payload);
    return out;
  }

  static Uint8List _decodeBytes(
    Uint8List cipherBytes, {
    required Object key,
    Uint8List? aad,
  }) {
    if (cipherBytes.length < _minCipherLen) {
      throw ArgumentError(
        'ToCrypto: cipher too short (expected header + nonce + tag)',
      );
    }
    if (cipherBytes[0] != _magic[0] ||
        cipherBytes[1] != _magic[1] ||
        cipherBytes[2] != _magic[2]) {
      throw ArgumentError('ToCrypto: invalid cipher (bad magic)');
    }
    final version = cipherBytes[3];
    if (version != _formatVersion) {
      throw ArgumentError(
        'ToCrypto: unsupported format version $version',
      );
    }
    final typeByte = cipherBytes[4];
    // Copy payload so buffer offset is 0; AES/ChaCha20 require 4-byte-aligned views internally.
    final payload = Uint8List.fromList(
      cipherBytes.sublist(_headerLen, cipherBytes.length),
    );
    final key32 = _normalizeKey(key);
    final aadBytes = _aadOrEmpty(aad);

    try {
      switch (typeByte) {
        case _typeByteChaCha20:
          return ChaCha20Poly1305.decryptBytes(
            encryptedData: payload,
            key: key32,
            aad: aadBytes,
          );
        case _typeByteAesGcm:
          return AESGCM.decryptBytes(
            encryptedData: payload,
            key: key32,
            aad: aadBytes,
          );
        default:
          throw ArgumentError(
            'ToCrypto: unknown type byte $typeByte',
          );
      }
    } catch (e) {
      throw ArgumentError(
        'ToCrypto: decryption failed (wrong key, wrong AAD, or corrupted data): $e',
      );
    }
  }
}
