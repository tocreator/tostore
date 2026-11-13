import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'sha256.dart';

/// Optimized Manual ChaCha20-Poly1305 Implementation
/// Compliant with RFC 7539
class ChaCha20Poly1305 {
  static const bool _isJs = identical(0, 0.0);
  static final Uint8List defaultKey = Uint8List.fromList([
    41,
    66,
    98,
    230,
    134,
    113,
    127,
    81,
    83,
    121,
    84,
    110,
    52,
    216,
    240,
    231,
    94,
    133,
    106,
    61,
    52,
    145,
    67,
    247,
    100,
    6,
    196,
    233,
    114,
    67,
    210,
    54
  ]);

  static Uint8List encrypt({
    required String plaintext,
    Uint8List? key,
    Uint8List? aad,
  }) {
    return encryptBytes(
      plaintext: utf8.encode(plaintext),
      key: key,
      aad: aad,
    );
  }

  static Uint8List encryptBytes({
    required Uint8List plaintext,
    Uint8List? key,
    Uint8List? aad,
  }) {
    key ??= defaultKey;
    if (key.length != 32) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'Key must be 32 bytes',
          parameterName: 'key',
          passedValue: key.length.toString(),
        )
      ]);
    }
    // asUint32List requires 4-byte-aligned offsets; copy when needed.
    // Aligned inputs keep the same buffer (bit-identical online path).
    if (key.offsetInBytes % 4 != 0) {
      key = Uint8List.fromList(key);
    }
    aad ??= Uint8List(0);

    final input = plaintext;
    final int totalLength = 12 + input.length + 16;
    final result = Uint8List(totalLength);

    // 1. Generate Nonce directly into result (0..12)
    final nonce = Uint8List.view(result.buffer, result.offsetInBytes, 12);
    _generateNonceInto(nonce);

    // 2. Generate Poly1305 Key (Counter 0)
    final polyKey = Uint8List(32);
    _chacha20Block0(key, nonce, polyKey);

    // 3. Encrypt Data directly into result (12..12+len)
    // Create a view for the ciphertext part
    final ciphertext =
        Uint8List.view(result.buffer, result.offsetInBytes + 12, input.length);
    _chacha20Process(key, nonce, 1, input, ciphertext);

    // 4. Compute MAC and write directly to result (end)
    final tag = _poly1305Mac(ciphertext, aad, polyKey);
    // Copy tag to the end
    // Optimization: _poly1305Mac could write directly too, but let's keep it simple for now.
    // The tag is small (16 bytes), copy is cheap.
    result.setAll(12 + input.length, tag);

    return result;
  }

  static String decrypt({
    required Uint8List encryptedData,
    Uint8List? key,
    Uint8List? aad,
    bool allowLegacyJsMac = false,
    void Function()? onLegacyJsMacUsed,
  }) {
    final plaintextBytes = decryptBytes(
      encryptedData: encryptedData,
      key: key,
      aad: aad,
      allowLegacyJsMac: allowLegacyJsMac,
      onLegacyJsMacUsed: onLegacyJsMacUsed,
    );
    return utf8.decode(plaintextBytes);
  }

  static Uint8List decryptBytes({
    required Uint8List encryptedData,
    Uint8List? key,
    Uint8List? aad,
    bool allowLegacyJsMac = false,
    void Function()? onLegacyJsMacUsed,
  }) {
    key ??= defaultKey;
    if (key.length != 32) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'Key must be 32 bytes',
          parameterName: 'key',
          passedValue: key.length.toString(),
        )
      ]);
    }
    if (encryptedData.length < 12 + 16) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'Invalid input length',
          parameterName: 'encryptedData',
          passedValue: encryptedData.length.toString(),
        )
      ]);
    }
    // asUint32List requires 4-byte-aligned offsets; copy when needed.
    // Aligned inputs keep the same buffer (bit-identical online path).
    if (key.offsetInBytes % 4 != 0) {
      key = Uint8List.fromList(key);
    }
    if (encryptedData.offsetInBytes % 4 != 0) {
      encryptedData = Uint8List.fromList(encryptedData);
    }
    aad ??= Uint8List(0);

    final nonce = Uint8List.view(
        encryptedData.buffer, encryptedData.offsetInBytes + 0, 12);
    final ciphertext = Uint8List.view(encryptedData.buffer,
        encryptedData.offsetInBytes + 12, encryptedData.length - 28);
    final tag = Uint8List.view(encryptedData.buffer,
        encryptedData.offsetInBytes + encryptedData.length - 16, 16);

    // 1. Generate Poly1305 Key
    final polyKey = Uint8List(32);
    _chacha20Block0(key, nonce, polyKey);

    // 2. Verify MAC (fast RFC 7539 path first; fallback only when enabled & mismatched)
    final computedTag = _poly1305Mac(ciphertext, aad, polyKey);
    if (!_constantTimeEqual(tag, computedTag)) {
      if (allowLegacyJsMac) {
        final legacyTag = _poly1305MacLegacyJs(ciphertext, aad, polyKey);
        if (_constantTimeEqual(tag, legacyTag)) {
          onLegacyJsMacUsed?.call();
        } else {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message: 'Authentication failed',
            )
          ]);
        }
      } else {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'Authentication failed',
          )
        ]);
      }
    }

    // 3. Decrypt
    final plaintextBytes = Uint8List(ciphertext.length);
    _chacha20Process(key, nonce, 1, ciphertext, plaintextBytes);

    return plaintextBytes;
  }

  static void _generateNonceInto(Uint8List output) {
    final rng = Random.secure();
    for (int i = 0; i < 12; i++) {
      output[i] = rng.nextInt(256);
    }
  }

  /// Generate a 32-byte key from a string using the unified SHA-256 KDF.
  ///
  /// Prefer [SHA256.stringToBytes] at call sites that are not ChaCha-specific.
  static Uint8List generateKeyFromString(String userKey) {
    if (userKey.isEmpty) return defaultKey;
    return SHA256.stringToBytes(userKey);
  }

  static bool _constantTimeEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int res = 0;
    for (int i = 0; i < a.length; i++) {
      res |= a[i] ^ b[i];
    }
    return res == 0;
  }

  // --- ChaCha20 Core (Optimized) ---

  /// Generates the first block (counter 0) specifically for Poly1305 key.
  /// Only writes first 32 bytes.
  static void _chacha20Block0(
      Uint8List key, Uint8List nonce, Uint8List output32) {
    final k = key.buffer.asUint32List(key.offsetInBytes, 8);
    final n = nonce.buffer.asUint32List(nonce.offsetInBytes, 3);

    var x0 = 0x61707865;
    var x1 = 0x3320646e;
    var x2 = 0x79622d32;
    var x3 = 0x6b206574;
    var x4 = k[0];
    var x5 = k[1];
    var x6 = k[2];
    var x7 = k[3];
    var x8 = k[4];
    var x9 = k[5];
    var x10 = k[6];
    var x11 = k[7];
    var x12 = 0; // Counter 0
    var x13 = n[0];
    var x14 = n[1];
    var x15 = n[2];

    var w0 = x0;
    var w1 = x1;
    var w2 = x2;
    var w3 = x3;
    var w4 = x4;
    var w5 = x5;
    var w6 = x6;
    var w7 = x7;
    var w8 = x8;
    var w9 = x9;
    var w10 = x10;
    var w11 = x11;
    var w12 = x12;
    var w13 = x13;
    var w14 = x14;
    var w15 = x15;

    // Unrolled loop (10 iterations)
    for (int i = 0; i < 10; i++) {
      w0 = (w0 + w4) & 0xFFFFFFFF;
      w12 ^= w0;
      w12 = ((w12 << 16) | (w12 >> 16)) & 0xFFFFFFFF;
      w8 = (w8 + w12) & 0xFFFFFFFF;
      w4 ^= w8;
      w4 = ((w4 << 12) | (w4 >> 20)) & 0xFFFFFFFF;
      w0 = (w0 + w4) & 0xFFFFFFFF;
      w12 ^= w0;
      w12 = ((w12 << 8) | (w12 >> 24)) & 0xFFFFFFFF;
      w8 = (w8 + w12) & 0xFFFFFFFF;
      w4 ^= w8;
      w4 = ((w4 << 7) | (w4 >> 25)) & 0xFFFFFFFF;

      w1 = (w1 + w5) & 0xFFFFFFFF;
      w13 ^= w1;
      w13 = ((w13 << 16) | (w13 >> 16)) & 0xFFFFFFFF;
      w9 = (w9 + w13) & 0xFFFFFFFF;
      w5 ^= w9;
      w5 = ((w5 << 12) | (w5 >> 20)) & 0xFFFFFFFF;
      w1 = (w1 + w5) & 0xFFFFFFFF;
      w13 ^= w1;
      w13 = ((w13 << 8) | (w13 >> 24)) & 0xFFFFFFFF;
      w9 = (w9 + w13) & 0xFFFFFFFF;
      w5 ^= w9;
      w5 = ((w5 << 7) | (w5 >> 25)) & 0xFFFFFFFF;

      w2 = (w2 + w6) & 0xFFFFFFFF;
      w14 ^= w2;
      w14 = ((w14 << 16) | (w14 >> 16)) & 0xFFFFFFFF;
      w10 = (w10 + w14) & 0xFFFFFFFF;
      w6 ^= w10;
      w6 = ((w6 << 12) | (w6 >> 20)) & 0xFFFFFFFF;
      w2 = (w2 + w6) & 0xFFFFFFFF;
      w14 ^= w2;
      w14 = ((w14 << 8) | (w14 >> 24)) & 0xFFFFFFFF;
      w10 = (w10 + w14) & 0xFFFFFFFF;
      w6 ^= w10;
      w6 = ((w6 << 7) | (w6 >> 25)) & 0xFFFFFFFF;

      w3 = (w3 + w7) & 0xFFFFFFFF;
      w15 ^= w3;
      w15 = ((w15 << 16) | (w15 >> 16)) & 0xFFFFFFFF;
      w11 = (w11 + w15) & 0xFFFFFFFF;
      w7 ^= w11;
      w7 = ((w7 << 12) | (w7 >> 20)) & 0xFFFFFFFF;
      w3 = (w3 + w7) & 0xFFFFFFFF;
      w15 ^= w3;
      w15 = ((w15 << 8) | (w15 >> 24)) & 0xFFFFFFFF;
      w11 = (w11 + w15) & 0xFFFFFFFF;
      w7 ^= w11;
      w7 = ((w7 << 7) | (w7 >> 25)) & 0xFFFFFFFF;

      w0 = (w0 + w5) & 0xFFFFFFFF;
      w15 ^= w0;
      w15 = ((w15 << 16) | (w15 >> 16)) & 0xFFFFFFFF;
      w10 = (w10 + w15) & 0xFFFFFFFF;
      w5 ^= w10;
      w5 = ((w5 << 12) | (w5 >> 20)) & 0xFFFFFFFF;
      w0 = (w0 + w5) & 0xFFFFFFFF;
      w15 ^= w0;
      w15 = ((w15 << 8) | (w15 >> 24)) & 0xFFFFFFFF;
      w10 = (w10 + w15) & 0xFFFFFFFF;
      w5 ^= w10;
      w5 = ((w5 << 7) | (w5 >> 25)) & 0xFFFFFFFF;

      w1 = (w1 + w6) & 0xFFFFFFFF;
      w12 ^= w1;
      w12 = ((w12 << 16) | (w12 >> 16)) & 0xFFFFFFFF;
      w11 = (w11 + w12) & 0xFFFFFFFF;
      w6 ^= w11;
      w6 = ((w6 << 12) | (w6 >> 20)) & 0xFFFFFFFF;
      w1 = (w1 + w6) & 0xFFFFFFFF;
      w12 ^= w1;
      w12 = ((w12 << 8) | (w12 >> 24)) & 0xFFFFFFFF;
      w11 = (w11 + w12) & 0xFFFFFFFF;
      w6 ^= w11;
      w6 = ((w6 << 7) | (w6 >> 25)) & 0xFFFFFFFF;

      w2 = (w2 + w7) & 0xFFFFFFFF;
      w13 ^= w2;
      w13 = ((w13 << 16) | (w13 >> 16)) & 0xFFFFFFFF;
      w8 = (w8 + w13) & 0xFFFFFFFF;
      w7 ^= w8;
      w7 = ((w7 << 12) | (w7 >> 20)) & 0xFFFFFFFF;
      w2 = (w2 + w7) & 0xFFFFFFFF;
      w13 ^= w2;
      w13 = ((w13 << 8) | (w13 >> 24)) & 0xFFFFFFFF;
      w8 = (w8 + w13) & 0xFFFFFFFF;
      w7 ^= w8;
      w7 = ((w7 << 7) | (w7 >> 25)) & 0xFFFFFFFF;

      w3 = (w3 + w4) & 0xFFFFFFFF;
      w14 ^= w3;
      w14 = ((w14 << 16) | (w14 >> 16)) & 0xFFFFFFFF;
      w9 = (w9 + w14) & 0xFFFFFFFF;
      w4 ^= w9;
      w4 = ((w4 << 12) | (w4 >> 20)) & 0xFFFFFFFF;
      w3 = (w3 + w4) & 0xFFFFFFFF;
      w14 ^= w3;
      w14 = ((w14 << 8) | (w14 >> 24)) & 0xFFFFFFFF;
      w9 = (w9 + w14) & 0xFFFFFFFF;
      w4 ^= w9;
      w4 = ((w4 << 7) | (w4 >> 25)) & 0xFFFFFFFF;
    }

    final out = output32.buffer.asByteData();
    out.setUint32(0, (w0 + x0) & 0xFFFFFFFF, Endian.little);
    out.setUint32(4, (w1 + x1) & 0xFFFFFFFF, Endian.little);
    out.setUint32(8, (w2 + x2) & 0xFFFFFFFF, Endian.little);
    out.setUint32(12, (w3 + x3) & 0xFFFFFFFF, Endian.little);
    out.setUint32(16, (w4 + x4) & 0xFFFFFFFF, Endian.little);
    out.setUint32(20, (w5 + x5) & 0xFFFFFFFF, Endian.little);
    out.setUint32(24, (w6 + x6) & 0xFFFFFFFF, Endian.little);
    out.setUint32(28, (w7 + x7) & 0xFFFFFFFF, Endian.little);
  }

  static void _chacha20Process(Uint8List key, Uint8List nonce, int counter,
      List<int> input, Uint8List output) {
    final k = key.buffer.asUint32List(key.offsetInBytes, 8);
    final n = nonce.buffer.asUint32List(nonce.offsetInBytes, 3);

    // Initial state
    var x0 = 0x61707865;
    var x1 = 0x3320646e;
    var x2 = 0x79622d32;
    var x3 = 0x6b206574;
    var x4 = k[0];
    var x5 = k[1];
    var x6 = k[2];
    var x7 = k[3];
    var x8 = k[4];
    var x9 = k[5];
    var x10 = k[6];
    var x11 = k[7];
    var x12 = counter;
    var x13 = n[0];
    var x14 = n[1];
    var x15 = n[2];

    int len = input.length;
    int offset = 0;

    // Check alignment
    bool aligned = false;
    Uint32List? in32;
    Uint32List? out32;
    ByteData? inBd;
    ByteData? outBd;

    if (input is Uint8List) {
      if (input.offsetInBytes % 4 == 0 && output.offsetInBytes % 4 == 0) {
        aligned = true;
        in32 = input.buffer.asUint32List(input.offsetInBytes);
        out32 = output.buffer.asUint32List(output.offsetInBytes);
      } else {
        // Use ByteData for unaligned access
        inBd = ByteData.sublistView(input);
        outBd = ByteData.sublistView(output);
      }
    } else {
      // Fallback for List<int> which is not Uint8List?
      // Should not happen in this context, but if so, we use byte loop.
    }

    while (len > 0) {
      var w0 = x0;
      var w1 = x1;
      var w2 = x2;
      var w3 = x3;
      var w4 = x4;
      var w5 = x5;
      var w6 = x6;
      var w7 = x7;
      var w8 = x8;
      var w9 = x9;
      var w10 = x10;
      var w11 = x11;
      var w12 = x12;
      var w13 = x13;
      var w14 = x14;
      var w15 = x15;

      // 10 rounds unrolled
      for (int i = 0; i < 10; i++) {
        w0 = (w0 + w4) & 0xFFFFFFFF;
        w12 ^= w0;
        w12 = ((w12 << 16) | (w12 >> 16)) & 0xFFFFFFFF;
        w8 = (w8 + w12) & 0xFFFFFFFF;
        w4 ^= w8;
        w4 = ((w4 << 12) | (w4 >> 20)) & 0xFFFFFFFF;
        w0 = (w0 + w4) & 0xFFFFFFFF;
        w12 ^= w0;
        w12 = ((w12 << 8) | (w12 >> 24)) & 0xFFFFFFFF;
        w8 = (w8 + w12) & 0xFFFFFFFF;
        w4 ^= w8;
        w4 = ((w4 << 7) | (w4 >> 25)) & 0xFFFFFFFF;

        w1 = (w1 + w5) & 0xFFFFFFFF;
        w13 ^= w1;
        w13 = ((w13 << 16) | (w13 >> 16)) & 0xFFFFFFFF;
        w9 = (w9 + w13) & 0xFFFFFFFF;
        w5 ^= w9;
        w5 = ((w5 << 12) | (w5 >> 20)) & 0xFFFFFFFF;
        w1 = (w1 + w5) & 0xFFFFFFFF;
        w13 ^= w1;
        w13 = ((w13 << 8) | (w13 >> 24)) & 0xFFFFFFFF;
        w9 = (w9 + w13) & 0xFFFFFFFF;
        w5 ^= w9;
        w5 = ((w5 << 7) | (w5 >> 25)) & 0xFFFFFFFF;

        w2 = (w2 + w6) & 0xFFFFFFFF;
        w14 ^= w2;
        w14 = ((w14 << 16) | (w14 >> 16)) & 0xFFFFFFFF;
        w10 = (w10 + w14) & 0xFFFFFFFF;
        w6 ^= w10;
        w6 = ((w6 << 12) | (w6 >> 20)) & 0xFFFFFFFF;
        w2 = (w2 + w6) & 0xFFFFFFFF;
        w14 ^= w2;
        w14 = ((w14 << 8) | (w14 >> 24)) & 0xFFFFFFFF;
        w10 = (w10 + w14) & 0xFFFFFFFF;
        w6 ^= w10;
        w6 = ((w6 << 7) | (w6 >> 25)) & 0xFFFFFFFF;

        w3 = (w3 + w7) & 0xFFFFFFFF;
        w15 ^= w3;
        w15 = ((w15 << 16) | (w15 >> 16)) & 0xFFFFFFFF;
        w11 = (w11 + w15) & 0xFFFFFFFF;
        w7 ^= w11;
        w7 = ((w7 << 12) | (w7 >> 20)) & 0xFFFFFFFF;
        w3 = (w3 + w7) & 0xFFFFFFFF;
        w15 ^= w3;
        w15 = ((w15 << 8) | (w15 >> 24)) & 0xFFFFFFFF;
        w11 = (w11 + w15) & 0xFFFFFFFF;
        w7 ^= w11;
        w7 = ((w7 << 7) | (w7 >> 25)) & 0xFFFFFFFF;

        w0 = (w0 + w5) & 0xFFFFFFFF;
        w15 ^= w0;
        w15 = ((w15 << 16) | (w15 >> 16)) & 0xFFFFFFFF;
        w10 = (w10 + w15) & 0xFFFFFFFF;
        w5 ^= w10;
        w5 = ((w5 << 12) | (w5 >> 20)) & 0xFFFFFFFF;
        w0 = (w0 + w5) & 0xFFFFFFFF;
        w15 ^= w0;
        w15 = ((w15 << 8) | (w15 >> 24)) & 0xFFFFFFFF;
        w10 = (w10 + w15) & 0xFFFFFFFF;
        w5 ^= w10;
        w5 = ((w5 << 7) | (w5 >> 25)) & 0xFFFFFFFF;

        w1 = (w1 + w6) & 0xFFFFFFFF;
        w12 ^= w1;
        w12 = ((w12 << 16) | (w12 >> 16)) & 0xFFFFFFFF;
        w11 = (w11 + w12) & 0xFFFFFFFF;
        w6 ^= w11;
        w6 = ((w6 << 12) | (w6 >> 20)) & 0xFFFFFFFF;
        w1 = (w1 + w6) & 0xFFFFFFFF;
        w12 ^= w1;
        w12 = ((w12 << 8) | (w12 >> 24)) & 0xFFFFFFFF;
        w11 = (w11 + w12) & 0xFFFFFFFF;
        w6 ^= w11;
        w6 = ((w6 << 7) | (w6 >> 25)) & 0xFFFFFFFF;

        w2 = (w2 + w7) & 0xFFFFFFFF;
        w13 ^= w2;
        w13 = ((w13 << 16) | (w13 >> 16)) & 0xFFFFFFFF;
        w8 = (w8 + w13) & 0xFFFFFFFF;
        w7 ^= w8;
        w7 = ((w7 << 12) | (w7 >> 20)) & 0xFFFFFFFF;
        w2 = (w2 + w7) & 0xFFFFFFFF;
        w13 ^= w2;
        w13 = ((w13 << 8) | (w13 >> 24)) & 0xFFFFFFFF;
        w8 = (w8 + w13) & 0xFFFFFFFF;
        w7 ^= w8;
        w7 = ((w7 << 7) | (w7 >> 25)) & 0xFFFFFFFF;

        w3 = (w3 + w4) & 0xFFFFFFFF;
        w14 ^= w3;
        w14 = ((w14 << 16) | (w14 >> 16)) & 0xFFFFFFFF;
        w9 = (w9 + w14) & 0xFFFFFFFF;
        w4 ^= w9;
        w4 = ((w4 << 12) | (w4 >> 20)) & 0xFFFFFFFF;
        w3 = (w3 + w4) & 0xFFFFFFFF;
        w14 ^= w3;
        w14 = ((w14 << 8) | (w14 >> 24)) & 0xFFFFFFFF;
        w9 = (w9 + w14) & 0xFFFFFFFF;
        w4 ^= w9;
        w4 = ((w4 << 7) | (w4 >> 25)) & 0xFFFFFFFF;
      }

      // Add to state
      w0 = (w0 + x0) & 0xFFFFFFFF;
      w1 = (w1 + x1) & 0xFFFFFFFF;
      w2 = (w2 + x2) & 0xFFFFFFFF;
      w3 = (w3 + x3) & 0xFFFFFFFF;
      w4 = (w4 + x4) & 0xFFFFFFFF;
      w5 = (w5 + x5) & 0xFFFFFFFF;
      w6 = (w6 + x6) & 0xFFFFFFFF;
      w7 = (w7 + x7) & 0xFFFFFFFF;
      w8 = (w8 + x8) & 0xFFFFFFFF;
      w9 = (w9 + x9) & 0xFFFFFFFF;
      w10 = (w10 + x10) & 0xFFFFFFFF;
      w11 = (w11 + x11) & 0xFFFFFFFF;
      w12 = (w12 + x12) & 0xFFFFFFFF;
      w13 = (w13 + x13) & 0xFFFFFFFF;
      w14 = (w14 + x14) & 0xFFFFFFFF;
      w15 = (w15 + x15) & 0xFFFFFFFF;

      if (len >= 64) {
        if (aligned && Endian.host == Endian.little) {
          // Fast path: XOR 32-bit words directly
          int off32 = offset >> 2;
          out32![off32 + 0] = in32![off32 + 0] ^ w0;
          out32[off32 + 1] = in32[off32 + 1] ^ w1;
          out32[off32 + 2] = in32[off32 + 2] ^ w2;
          out32[off32 + 3] = in32[off32 + 3] ^ w3;
          out32[off32 + 4] = in32[off32 + 4] ^ w4;
          out32[off32 + 5] = in32[off32 + 5] ^ w5;
          out32[off32 + 6] = in32[off32 + 6] ^ w6;
          out32[off32 + 7] = in32[off32 + 7] ^ w7;
          out32[off32 + 8] = in32[off32 + 8] ^ w8;
          out32[off32 + 9] = in32[off32 + 9] ^ w9;
          out32[off32 + 10] = in32[off32 + 10] ^ w10;
          out32[off32 + 11] = in32[off32 + 11] ^ w11;
          out32[off32 + 12] = in32[off32 + 12] ^ w12;
          out32[off32 + 13] = in32[off32 + 13] ^ w13;
          out32[off32 + 14] = in32[off32 + 14] ^ w14;
          out32[off32 + 15] = in32[off32 + 15] ^ w15;
        } else if (inBd != null && outBd != null) {
          // Unaligned using ByteData
          outBd.setUint32(offset + 0,
              inBd.getUint32(offset + 0, Endian.little) ^ w0, Endian.little);
          outBd.setUint32(offset + 4,
              inBd.getUint32(offset + 4, Endian.little) ^ w1, Endian.little);
          outBd.setUint32(offset + 8,
              inBd.getUint32(offset + 8, Endian.little) ^ w2, Endian.little);
          outBd.setUint32(offset + 12,
              inBd.getUint32(offset + 12, Endian.little) ^ w3, Endian.little);
          outBd.setUint32(offset + 16,
              inBd.getUint32(offset + 16, Endian.little) ^ w4, Endian.little);
          outBd.setUint32(offset + 20,
              inBd.getUint32(offset + 20, Endian.little) ^ w5, Endian.little);
          outBd.setUint32(offset + 24,
              inBd.getUint32(offset + 24, Endian.little) ^ w6, Endian.little);
          outBd.setUint32(offset + 28,
              inBd.getUint32(offset + 28, Endian.little) ^ w7, Endian.little);
          outBd.setUint32(offset + 32,
              inBd.getUint32(offset + 32, Endian.little) ^ w8, Endian.little);
          outBd.setUint32(offset + 36,
              inBd.getUint32(offset + 36, Endian.little) ^ w9, Endian.little);
          outBd.setUint32(offset + 40,
              inBd.getUint32(offset + 40, Endian.little) ^ w10, Endian.little);
          outBd.setUint32(offset + 44,
              inBd.getUint32(offset + 44, Endian.little) ^ w11, Endian.little);
          outBd.setUint32(offset + 48,
              inBd.getUint32(offset + 48, Endian.little) ^ w12, Endian.little);
          outBd.setUint32(offset + 52,
              inBd.getUint32(offset + 52, Endian.little) ^ w13, Endian.little);
          outBd.setUint32(offset + 56,
              inBd.getUint32(offset + 56, Endian.little) ^ w14, Endian.little);
          outBd.setUint32(offset + 60,
              inBd.getUint32(offset + 60, Endian.little) ^ w15, Endian.little);
        } else {
          // Fallback (should not happen if input is Uint8List)
          _xorBlockBytes(input, output, offset, w0, w1, w2, w3, w4, w5, w6, w7,
              w8, w9, w10, w11, w12, w13, w14, w15);
        }
        len -= 64;
        offset += 64;
      } else {
        // Partial block (last block < 64 bytes)
        int todo = len;
        for (int i = 0; i < todo; i++) {
          int kVal;
          switch (i >> 2) {
            case 0:
              kVal = w0;
              break;
            case 1:
              kVal = w1;
              break;
            case 2:
              kVal = w2;
              break;
            case 3:
              kVal = w3;
              break;
            case 4:
              kVal = w4;
              break;
            case 5:
              kVal = w5;
              break;
            case 6:
              kVal = w6;
              break;
            case 7:
              kVal = w7;
              break;
            case 8:
              kVal = w8;
              break;
            case 9:
              kVal = w9;
              break;
            case 10:
              kVal = w10;
              break;
            case 11:
              kVal = w11;
              break;
            case 12:
              kVal = w12;
              break;
            case 13:
              kVal = w13;
              break;
            case 14:
              kVal = w14;
              break;
            case 15:
              kVal = w15;
              break;
            default:
              kVal = 0;
          }
          int byteVal = (kVal >> ((i & 3) * 8)) & 0xFF;
          output[offset + i] = input[offset + i] ^ byteVal;
        }
        len = 0; // Done
      }

      x12++; // Increment counter
    }
  }

  static void _xorBlockBytes(
      List<int> input,
      Uint8List output,
      int offset,
      int w0,
      int w1,
      int w2,
      int w3,
      int w4,
      int w5,
      int w6,
      int w7,
      int w8,
      int w9,
      int w10,
      int w11,
      int w12,
      int w13,
      int w14,
      int w15) {
    // Helper to write 4 bytes
    void xorWord(int word, int off) {
      output[off] = input[off] ^ (word & 0xFF);
      output[off + 1] = input[off + 1] ^ ((word >> 8) & 0xFF);
      output[off + 2] = input[off + 2] ^ ((word >> 16) & 0xFF);
      output[off + 3] = input[off + 3] ^ ((word >> 24) & 0xFF);
    }

    xorWord(w0, offset);
    xorWord(w1, offset + 4);
    xorWord(w2, offset + 8);
    xorWord(w3, offset + 12);
    xorWord(w4, offset + 16);
    xorWord(w5, offset + 20);
    xorWord(w6, offset + 24);
    xorWord(w7, offset + 28);
    xorWord(w8, offset + 32);
    xorWord(w9, offset + 36);
    xorWord(w10, offset + 40);
    xorWord(w11, offset + 44);
    xorWord(w12, offset + 48);
    xorWord(w13, offset + 52);
    xorWord(w14, offset + 56);
    xorWord(w15, offset + 60);
  }

  // --- Poly1305 Core (Optimized) ---

  static Uint8List _poly1305Mac(Uint8List msg, Uint8List aad, Uint8List key) {
    if (_isJs) {
      return _poly1305MacWeb(msg, aad, key);
    }
    return _poly1305MacVm(msg, aad, key);
  }

  /// Portable RFC 7539 Poly1305 using 10x 13-bit limbs for Web JS (`dart2js`/DDC).
  ///
  /// All products and sums remain strictly `< 2^34` (well within JS Number's `2^53`
  /// exact integer range), and carry propagation uses integer division instead of
  /// `>> 26` so 32-bit JS shifts never truncate upper bits.
  static Uint8List _poly1305MacWeb(
      Uint8List msg, Uint8List aad, Uint8List key) {
    final k = ByteData.sublistView(key);
    final k0 = k.getUint32(0, Endian.little);
    final k1 = k.getUint32(4, Endian.little);
    final k2 = k.getUint32(8, Endian.little);
    final k3 = k.getUint32(12, Endian.little);

    final r26_0 = k0 & 0x03FFFFFF;
    final r26_1 = ((k0 >>> 26) | (k1 << 6)) & 0x03FFFF03;
    final r26_2 = ((k1 >>> 20) | (k2 << 12)) & 0x03FFC0FF;
    final r26_3 = ((k2 >>> 14) | (k3 << 18)) & 0x03F03FFF;
    final r26_4 = (k3 >>> 8) & 0x000FFFFF;

    final r0 = r26_0 & 0x1FFF;
    final r1 = (r26_0 >>> 13) & 0x1FFF;
    final r2 = r26_1 & 0x1FFF;
    final r3 = (r26_1 >>> 13) & 0x1FFF;
    final r4 = r26_2 & 0x1FFF;
    final r5 = (r26_2 >>> 13) & 0x1FFF;
    final r6 = r26_3 & 0x1FFF;
    final r7 = (r26_3 >>> 13) & 0x1FFF;
    final r8 = r26_4 & 0x1FFF;
    final r9 = (r26_4 >>> 13) & 0x1FFF;

    final s1 = r1 * 5;
    final s2 = r2 * 5;
    final s3 = r3 * 5;
    final s4 = r4 * 5;
    final s5 = r5 * 5;
    final s6 = r6 * 5;
    final s7 = r7 * 5;
    final s8 = r8 * 5;
    final s9 = r9 * 5;

    int h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0;
    int h5 = 0, h6 = 0, h7 = 0, h8 = 0, h9 = 0;

    void feedBlock(int t0, int t1, int t2, int t3) {
      final v0 = t0 & 0x03FFFFFF;
      final v1 = ((t0 >>> 26) | (t1 << 6)) & 0x03FFFFFF;
      final v2 = ((t1 >>> 20) | (t2 << 12)) & 0x03FFFFFF;
      final v3 = ((t2 >>> 14) | (t3 << 18)) & 0x03FFFFFF;
      final v4 = ((t3 >>> 8) | (1 << 24)) & 0x03FFFFFF;

      h0 += v0 & 0x1FFF;
      h1 += (v0 >>> 13) & 0x1FFF;
      h2 += v1 & 0x1FFF;
      h3 += (v1 >>> 13) & 0x1FFF;
      h4 += v2 & 0x1FFF;
      h5 += (v2 >>> 13) & 0x1FFF;
      h6 += v3 & 0x1FFF;
      h7 += (v3 >>> 13) & 0x1FFF;
      h8 += v4 & 0x1FFF;
      h9 += (v4 >>> 13) & 0x1FFF;

      int d = h0 * r0 +
          h1 * s9 +
          h2 * s8 +
          h3 * s7 +
          h4 * s6 +
          h5 * s5 +
          h6 * s4 +
          h7 * s3 +
          h8 * s2 +
          h9 * s1;
      final nh0 = d & 0x1FFF;
      int c = d ~/ 8192;

      d = h0 * r1 +
          h1 * r0 +
          h2 * s9 +
          h3 * s8 +
          h4 * s7 +
          h5 * s6 +
          h6 * s5 +
          h7 * s4 +
          h8 * s3 +
          h9 * s2 +
          c;
      final nh1 = d & 0x1FFF;
      c = d ~/ 8192;

      d = h0 * r2 +
          h1 * r1 +
          h2 * r0 +
          h3 * s9 +
          h4 * s8 +
          h5 * s7 +
          h6 * s6 +
          h7 * s5 +
          h8 * s4 +
          h9 * s3 +
          c;
      final nh2 = d & 0x1FFF;
      c = d ~/ 8192;

      d = h0 * r3 +
          h1 * r2 +
          h2 * r1 +
          h3 * r0 +
          h4 * s9 +
          h5 * s8 +
          h6 * s7 +
          h7 * s6 +
          h8 * s5 +
          h9 * s4 +
          c;
      final nh3 = d & 0x1FFF;
      c = d ~/ 8192;

      d = h0 * r4 +
          h1 * r3 +
          h2 * r2 +
          h3 * r1 +
          h4 * r0 +
          h5 * s9 +
          h6 * s8 +
          h7 * s7 +
          h8 * s6 +
          h9 * s5 +
          c;
      final nh4 = d & 0x1FFF;
      c = d ~/ 8192;

      d = h0 * r5 +
          h1 * r4 +
          h2 * r3 +
          h3 * r2 +
          h4 * r1 +
          h5 * r0 +
          h6 * s9 +
          h7 * s8 +
          h8 * s7 +
          h9 * s6 +
          c;
      final nh5 = d & 0x1FFF;
      c = d ~/ 8192;

      d = h0 * r6 +
          h1 * r5 +
          h2 * r4 +
          h3 * r3 +
          h4 * r2 +
          h5 * r1 +
          h6 * r0 +
          h7 * s9 +
          h8 * s8 +
          h9 * s7 +
          c;
      final nh6 = d & 0x1FFF;
      c = d ~/ 8192;

      d = h0 * r7 +
          h1 * r6 +
          h2 * r5 +
          h3 * r4 +
          h4 * r3 +
          h5 * r2 +
          h6 * r1 +
          h7 * r0 +
          h8 * s9 +
          h9 * s8 +
          c;
      final nh7 = d & 0x1FFF;
      c = d ~/ 8192;

      d = h0 * r8 +
          h1 * r7 +
          h2 * r6 +
          h3 * r5 +
          h4 * r4 +
          h5 * r3 +
          h6 * r2 +
          h7 * r1 +
          h8 * r0 +
          h9 * s9 +
          c;
      final nh8 = d & 0x1FFF;
      c = d ~/ 8192;

      d = h0 * r9 +
          h1 * r8 +
          h2 * r7 +
          h3 * r6 +
          h4 * r5 +
          h5 * r4 +
          h6 * r3 +
          h7 * r2 +
          h8 * r1 +
          h9 * r0 +
          c;
      h9 = d & 0x1FFF;
      c = d ~/ 8192;

      h0 = nh0 + c * 5;
      h1 = nh1 + (h0 ~/ 8192);
      h0 &= 0x1FFF;
      h2 = nh2;
      h3 = nh3;
      h4 = nh4;
      h5 = nh5;
      h6 = nh6;
      h7 = nh7;
      h8 = nh8;
    }

    void feedData(Uint8List data) {
      int pos = 0;
      final bd = ByteData.sublistView(data);
      while (pos < data.length) {
        final rem = data.length - pos;
        if (rem >= 16) {
          feedBlock(
            bd.getUint32(pos, Endian.little),
            bd.getUint32(pos + 4, Endian.little),
            bd.getUint32(pos + 8, Endian.little),
            bd.getUint32(pos + 12, Endian.little),
          );
          pos += 16;
        } else {
          final tmp = Uint8List(16);
          for (int i = 0; i < rem; i++) {
            tmp[i] = data[pos + i];
          }
          final tbd = ByteData.sublistView(tmp);
          feedBlock(
            tbd.getUint32(0, Endian.little),
            tbd.getUint32(4, Endian.little),
            tbd.getUint32(8, Endian.little),
            tbd.getUint32(12, Endian.little),
          );
          pos += rem;
        }
      }
    }

    feedData(aad);
    feedData(msg);

    final aadLen = aad.length;
    final msgLen = msg.length;
    feedBlock(
      aadLen & 0xFFFFFFFF,
      (aadLen / 0x100000000).floor() & 0xFFFFFFFF,
      msgLen & 0xFFFFFFFF,
      (msgLen / 0x100000000).floor() & 0xFFFFFFFF,
    );

    // Final carry propagation into canonical 13-bit limbs
    h1 += h0 ~/ 8192;
    h0 &= 0x1FFF;
    h2 += h1 ~/ 8192;
    h1 &= 0x1FFF;
    h3 += h2 ~/ 8192;
    h2 &= 0x1FFF;
    h4 += h3 ~/ 8192;
    h3 &= 0x1FFF;
    h5 += h4 ~/ 8192;
    h4 &= 0x1FFF;
    h6 += h5 ~/ 8192;
    h5 &= 0x1FFF;
    h7 += h6 ~/ 8192;
    h6 &= 0x1FFF;
    h8 += h7 ~/ 8192;
    h7 &= 0x1FFF;
    h9 += h8 ~/ 8192;
    h8 &= 0x1FFF;
    h0 += (h9 ~/ 8192) * 5;
    h9 &= 0x1FFF;
    h1 += h0 ~/ 8192;
    h0 &= 0x1FFF;

    // Compute h - p = (h + 5) - 2^130
    int g0 = h0 + 5;
    int b = g0 ~/ 8192;
    g0 &= 0x1FFF;
    int g1 = h1 + b;
    b = g1 ~/ 8192;
    g1 &= 0x1FFF;
    int g2 = h2 + b;
    b = g2 ~/ 8192;
    g2 &= 0x1FFF;
    int g3 = h3 + b;
    b = g3 ~/ 8192;
    g3 &= 0x1FFF;
    int g4 = h4 + b;
    b = g4 ~/ 8192;
    g4 &= 0x1FFF;
    int g5 = h5 + b;
    b = g5 ~/ 8192;
    g5 &= 0x1FFF;
    int g6 = h6 + b;
    b = g6 ~/ 8192;
    g6 &= 0x1FFF;
    int g7 = h7 + b;
    b = g7 ~/ 8192;
    g7 &= 0x1FFF;
    int g8 = h8 + b;
    b = g8 ~/ 8192;
    g8 &= 0x1FFF;
    int g9 = h9 + b - 8192;

    if (g9 >= 0) {
      h0 = g0;
      h1 = g1;
      h2 = g2;
      h3 = g3;
      h4 = g4;
      h5 = g5;
      h6 = g6;
      h7 = g7;
      h8 = g8;
      h9 = g9;
    }

    final f0 = (h0 | (h1 << 13) | ((h2 & 0x3F) << 26)) & 0xFFFFFFFF;
    final f1 = ((h2 >>> 6) | (h3 << 7) | ((h4 & 0xFFF) << 20)) & 0xFFFFFFFF;
    final f2 = ((h4 >>> 12) | (h5 << 1) | (h6 << 14) | ((h7 & 0x1F) << 27)) &
        0xFFFFFFFF;
    final f3 = ((h7 >>> 5) | (h8 << 8) | ((h9 & 0x7FF) << 21)) & 0xFFFFFFFF;

    final s_0 = k.getUint32(16, Endian.little);
    final s_1 = k.getUint32(20, Endian.little);
    final s_2 = k.getUint32(24, Endian.little);
    final s_3 = k.getUint32(28, Endian.little);

    int sum = f0 + s_0;
    final r_0 = sum & 0xFFFFFFFF;
    int carry = sum >= 0x100000000 ? 1 : 0;

    sum = f1 + s_1 + carry;
    final r_1 = sum & 0xFFFFFFFF;
    carry = sum >= 0x100000000 ? 1 : 0;

    sum = f2 + s_2 + carry;
    final r_2 = sum & 0xFFFFFFFF;
    carry = sum >= 0x100000000 ? 1 : 0;

    sum = f3 + s_3 + carry;
    final r_3 = sum & 0xFFFFFFFF;

    final tag = Uint8List(16);
    final tagBd = tag.buffer.asByteData();
    tagBd.setUint32(0, r_0, Endian.little);
    tagBd.setUint32(4, r_1, Endian.little);
    tagBd.setUint32(8, r_2, Endian.little);
    tagBd.setUint32(12, r_3, Endian.little);
    return tag;
  }

  /// Reproduces the pre-fix Web JS (`dart2js`) Poly1305 MAC calculation for
  /// decrypt-only backward compatibility across JS, Wasm, and Native VM.
  ///
  /// Uses IEEE-754 [double] accumulators and explicit low-32-bit shifts (`>>> 26`)
  /// so VM/Wasm can also decode ciphertexts created by older Web JS builds.
  static Uint8List _poly1305MacLegacyJs(
      Uint8List msg, Uint8List aad, Uint8List key) {
    final k = ByteData.sublistView(key);
    final k0 = k.getUint32(0, Endian.little);
    final k1 = k.getUint32(4, Endian.little);
    final k2 = k.getUint32(8, Endian.little);
    final k3 = k.getUint32(12, Endian.little);

    final r0 = k0 & 0x03FFFFFF;
    final r1 = ((k0 >>> 26) | (k1 << 6)) & 0x03FFFF03;
    final r2 = ((k1 >>> 20) | (k2 << 12)) & 0x03FFC0FF;
    final r3 = ((k2 >>> 14) | (k3 << 18)) & 0x03F03FFF;
    final r4 = (k3 >>> 8) & 0x000FFFFF;

    final s1 = r1 * 5;
    final s2 = r2 * 5;
    final s3 = r3 * 5;
    final s4 = r4 * 5;

    int h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0;

    int jsU32(double v) => v.truncate() & 0xFFFFFFFF;

    void accumWords(int t0, int t1, int t2, int t3) {
      h0 += t0 & 0x03FFFFFF;
      h1 += ((t0 >>> 26) | (t1 << 6)) & 0x03FFFFFF;
      h2 += ((t1 >>> 20) | (t2 << 12)) & 0x03FFFFFF;
      h3 += ((t2 >>> 14) | (t3 << 18)) & 0x03FFFFFF;
      h4 += ((t3 >>> 8) | (1 << 24)) & 0xFFFFFFFF;

      final double d0 = h0.toDouble() * r0 +
          h1.toDouble() * s4 +
          h2.toDouble() * s3 +
          h3.toDouble() * s2 +
          h4.toDouble() * s1;
      final double d1 = h0.toDouble() * r1 +
          h1.toDouble() * r0 +
          h2.toDouble() * s4 +
          h3.toDouble() * s3 +
          h4.toDouble() * s2 +
          (jsU32(d0) >>> 26);
      final double d2 = h0.toDouble() * r2 +
          h1.toDouble() * r1 +
          h2.toDouble() * r0 +
          h3.toDouble() * s4 +
          h4.toDouble() * s3 +
          (jsU32(d1) >>> 26);
      final nh2 = jsU32(d2) & 0x03FFFFFF;
      final double d3 = h0.toDouble() * r3 +
          h1.toDouble() * r2 +
          h2.toDouble() * r1 +
          h3.toDouble() * r0 +
          h4.toDouble() * s4 +
          (jsU32(d2) >>> 26);
      final nh3 = jsU32(d3) & 0x03FFFFFF;
      final double d4 = h0.toDouble() * r4 +
          h1.toDouble() * r3 +
          h2.toDouble() * r2 +
          h3.toDouble() * r1 +
          h4.toDouble() * r0 +
          (jsU32(d3) >>> 26);
      h4 = jsU32(d4) & 0x03FFFFFF;
      h0 = (jsU32(d0) & 0x03FFFFFF) + (jsU32(d4) >>> 26) * 5;
      h1 = (jsU32(d1) & 0x03FFFFFF) + ((h0 & 0xFFFFFFFF) >>> 26);
      h0 &= 0x03FFFFFF;
      h2 = nh2;
      h3 = nh3;
    }

    void accumData(Uint8List data) {
      int pos = 0;
      final bd = ByteData.sublistView(data);
      while (pos < data.length) {
        final len = data.length - pos;
        if (len >= 16) {
          accumWords(
            bd.getUint32(pos, Endian.little),
            bd.getUint32(pos + 4, Endian.little),
            bd.getUint32(pos + 8, Endian.little),
            bd.getUint32(pos + 12, Endian.little),
          );
          pos += 16;
        } else {
          final tmp = Uint8List(16);
          for (int i = 0; i < len; i++) {
            tmp[i] = data[pos + i];
          }
          final tbd = ByteData.sublistView(tmp);
          accumWords(
            tbd.getUint32(0, Endian.little),
            tbd.getUint32(4, Endian.little),
            tbd.getUint32(8, Endian.little),
            tbd.getUint32(12, Endian.little),
          );
          pos += len;
        }
      }
    }

    accumData(aad);
    accumData(msg);

    // Lengths block matching dart2js compiled output (lines 3798-3826 of JS output)
    final aadLen = aad.length;
    final msgLen = msg.length;
    final lt0 = aadLen & 0xFFFFFFFF;
    final lt1 = (aadLen / 0x100000000).floor() & 0xFFFFFFFF;
    final lt2 = msgLen & 0xFFFFFFFF;
    final lt3 = (msgLen / 0x100000000).floor() & 0xFFFFFFFF;

    h0 += lt0 & 0x03FFFFFF;
    h1 += ((lt0 >>> 26) | (lt1 << 6)) & 0x03FFFFFF;
    h2 += ((lt1 >>> 20) | (lt2 << 12)) & 0x03FFFFFF;
    h3 += ((lt2 >>> 14) | (lt3 << 18)) & 0x03FFFFFF;
    h4 += ((lt3 >>> 8) | (1 << 24)) & 0xFFFFFFFF;

    final double ld0 = h0.toDouble() * r0 +
        h1.toDouble() * s4 +
        h2.toDouble() * s3 +
        h3.toDouble() * s2 +
        h4.toDouble() * s1;
    final double ld1 = h0.toDouble() * r1 +
        h1.toDouble() * r0 +
        h2.toDouble() * s4 +
        h3.toDouble() * s3 +
        h4.toDouble() * s2 +
        (jsU32(ld0) >>> 26);
    final double ld2 = h0.toDouble() * r2 +
        h1.toDouble() * r1 +
        h2.toDouble() * r0 +
        h3.toDouble() * s4 +
        h4.toDouble() * s3 +
        (jsU32(ld1) >>> 26);
    final double ld3 = h0.toDouble() * r3 +
        h1.toDouble() * r2 +
        h2.toDouble() * r1 +
        h3.toDouble() * r0 +
        h4.toDouble() * s4 +
        (jsU32(ld2) >>> 26);
    final double ld4 = h0.toDouble() * r4 +
        h1.toDouble() * r3 +
        h2.toDouble() * r2 +
        h3.toDouble() * r1 +
        h4.toDouble() * r0 +
        (jsU32(ld3) >>> 26);

    h0 = (jsU32(ld0) & 0x03FFFFFF) + (jsU32(ld4) >>> 26) * 5;
    final h00 = h0 & 0x03FFFFFF;
    h1 = (jsU32(ld1) & 0x03FFFFFF) + ((h0 & 0xFFFFFFFF) >>> 26) + (h00 >>> 26);
    h2 = (jsU32(ld2) & 0x03FFFFFF) + ((h1 & 0xFFFFFFFF) >>> 26);
    h3 = (jsU32(ld3) & 0x03FFFFFF) + ((h2 & 0xFFFFFFFF) >>> 26);
    h2 &= 0x03FFFFFF;
    h4 = (jsU32(ld4) & 0x03FFFFFF) + ((h3 & 0xFFFFFFFF) >>> 26);
    h3 &= 0x03FFFFFF;
    h0 = h00 + ((h4 & 0xFFFFFFFF) >>> 26) * 5;
    h4 &= 0x03FFFFFF;
    h1 = (h1 & 0x03FFFFFF) + ((h0 & 0xFFFFFFFF) >>> 26);
    h0 &= 0x03FFFFFF;

    final int g0 = h0 + 5;
    final int g1 = h1 + ((g0 & 0xFFFFFFFF) >>> 26);
    final int g2 = h2 + ((g1 & 0xFFFFFFFF) >>> 26);
    final int g3 = h3 + ((g2 & 0xFFFFFFFF) >>> 26);
    final int g4 = h4 + ((g3 & 0xFFFFFFFF) >>> 26) - (1 << 26);

    final int mask = g4 < 0 ? 0 : 0xFFFFFFFF;
    final int invMask = ~mask & 0xFFFFFFFF;

    final int fh0 = (h0 & invMask) | (g0 & 0x03FFFFFF & mask);
    final int fh1 = (h1 & invMask) | (g1 & 0x03FFFFFF & mask);
    final int fh2 = (h2 & invMask) | (g2 & 0x03FFFFFF & mask);
    final int fh3 = (h3 & invMask) | (g3 & 0x03FFFFFF & mask);
    final int fh4 = (h4 & invMask) | (g4 & mask);

    final s_0 = k.getUint32(16, Endian.little);
    final s_1 = k.getUint32(20, Endian.little);
    final s_2 = k.getUint32(24, Endian.little);
    final s_3 = k.getUint32(28, Endian.little);

    final int f0 = (fh0 | (fh1 << 26)) & 0xFFFFFFFF;
    final int f1 = ((fh1 >>> 6) | (fh2 << 20)) & 0xFFFFFFFF;
    final int f2 = ((fh2 >>> 12) | (fh3 << 14)) & 0xFFFFFFFF;
    final int f3 = ((fh3 >>> 18) | (fh4 << 8)) & 0xFFFFFFFF;

    int r_0 = f0 + s_0;
    int c = (r_0 / 0x100000000).floor();
    r_0 &= 0xFFFFFFFF;
    int r_1 = f1 + s_1 + c;
    c = (r_1 / 0x100000000).floor();
    r_1 &= 0xFFFFFFFF;
    int r_2 = f2 + s_2 + c;
    c = (r_2 / 0x100000000).floor();
    r_2 &= 0xFFFFFFFF;
    int r_3 = (f3 + s_3 + c) & 0xFFFFFFFF;

    final tag = Uint8List(16);
    final tagBd = tag.buffer.asByteData();
    tagBd.setUint32(0, r_0, Endian.little);
    tagBd.setUint32(4, r_1, Endian.little);
    tagBd.setUint32(8, r_2, Endian.little);
    tagBd.setUint32(12, r_3, Endian.little);
    return tag;
  }

  static Uint8List _poly1305MacVm(Uint8List msg, Uint8List aad, Uint8List key) {
    final k = ByteData.sublistView(key);
    int r0 = k.getUint32(0, Endian.little) & 0x03FFFFFF;
    int r1 = ((k.getUint32(0, Endian.little) >> 26) |
            (k.getUint32(4, Endian.little) << 6)) &
        0x03FFFF03;
    int r2 = ((k.getUint32(4, Endian.little) >> 20) |
            (k.getUint32(8, Endian.little) << 12)) &
        0x03FFC0FF;
    int r3 = ((k.getUint32(8, Endian.little) >> 14) |
            (k.getUint32(12, Endian.little) << 18)) &
        0x03F03FFF;
    int r4 = (k.getUint32(12, Endian.little) >> 8) & 0x000FFFFF;

    int s1 = r1 * 5;
    int s2 = r2 * 5;
    int s3 = r3 * 5;
    int s4 = r4 * 5;

    int h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0;

    // Process AAD
    int pos = 0;
    bool aadAligned = (aad.offsetInBytes % 4 == 0);
    Uint32List? aad32;
    ByteData? aadBd;
    if (aadAligned) {
      aad32 = aad.buffer.asUint32List(aad.offsetInBytes);
    } else {
      aadBd = ByteData.sublistView(aad);
    }

    while (pos < aad.length) {
      int len = aad.length - pos;
      if (len >= 16) {
        int t0, t1, t2, t3;
        if (aadAligned) {
          int idx = pos >> 2;
          if (Endian.host == Endian.little) {
            t0 = aad32![idx];
            t1 = aad32[idx + 1];
            t2 = aad32[idx + 2];
            t3 = aad32[idx + 3];
          } else {
            t0 = _swap32(aad32![idx]);
            t1 = _swap32(aad32[idx + 1]);
            t2 = _swap32(aad32[idx + 2]);
            t3 = _swap32(aad32[idx + 3]);
          }
        } else if (aadBd != null) {
          t0 = aadBd.getUint32(pos, Endian.little);
          t1 = aadBd.getUint32(pos + 4, Endian.little);
          t2 = aadBd.getUint32(pos + 8, Endian.little);
          t3 = aadBd.getUint32(pos + 12, Endian.little);
        } else {
          t0 = aad[pos] |
              (aad[pos + 1] << 8) |
              (aad[pos + 2] << 16) |
              (aad[pos + 3] << 24);
          t1 = aad[pos + 4] |
              (aad[pos + 5] << 8) |
              (aad[pos + 6] << 16) |
              (aad[pos + 7] << 24);
          t2 = aad[pos + 8] |
              (aad[pos + 9] << 8) |
              (aad[pos + 10] << 16) |
              (aad[pos + 11] << 24);
          t3 = aad[pos + 12] |
              (aad[pos + 13] << 8) |
              (aad[pos + 14] << 16) |
              (aad[pos + 15] << 24);
        }

        h0 += t0 & 0x03FFFFFF;
        h1 += ((t0 >> 26) | (t1 << 6)) & 0x03FFFFFF;
        h2 += ((t1 >> 20) | (t2 << 12)) & 0x03FFFFFF;
        h3 += ((t2 >> 14) | (t3 << 18)) & 0x03FFFFFF;
        h4 += (t3 >> 8) | (1 << 24);

        int d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
        int d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
        int d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
        int d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
        int d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;

        h0 = d0 & 0x03FFFFFF;
        d1 += (d0 >> 26);
        h1 = d1 & 0x03FFFFFF;
        d2 += (d1 >> 26);
        h2 = d2 & 0x03FFFFFF;
        d3 += (d2 >> 26);
        h3 = d3 & 0x03FFFFFF;
        d4 += (d3 >> 26);
        h4 = d4 & 0x03FFFFFF;
        h0 += (d4 >> 26) * 5;
        h1 += (h0 >> 26);
        h0 &= 0x03FFFFFF;

        pos += 16;
      } else {
        final tmp = Uint8List(16);
        for (int i = 0; i < len; i++) {
          tmp[i] = aad[pos + i];
        }
        int t0 = tmp[0] | (tmp[1] << 8) | (tmp[2] << 16) | (tmp[3] << 24);
        int t1 = tmp[4] | (tmp[5] << 8) | (tmp[6] << 16) | (tmp[7] << 24);
        int t2 = tmp[8] | (tmp[9] << 8) | (tmp[10] << 16) | (tmp[11] << 24);
        int t3 = tmp[12] | (tmp[13] << 8) | (tmp[14] << 16) | (tmp[15] << 24);

        h0 += t0 & 0x03FFFFFF;
        h1 += ((t0 >> 26) | (t1 << 6)) & 0x03FFFFFF;
        h2 += ((t1 >> 20) | (t2 << 12)) & 0x03FFFFFF;
        h3 += ((t2 >> 14) | (t3 << 18)) & 0x03FFFFFF;
        h4 += (t3 >> 8) | (1 << 24);

        int d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
        int d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
        int d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
        int d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
        int d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;

        h0 = d0 & 0x03FFFFFF;
        d1 += (d0 >> 26);
        h1 = d1 & 0x03FFFFFF;
        d2 += (d1 >> 26);
        h2 = d2 & 0x03FFFFFF;
        d3 += (d2 >> 26);
        h3 = d3 & 0x03FFFFFF;
        d4 += (d3 >> 26);
        h4 = d4 & 0x03FFFFFF;
        h0 += (d4 >> 26) * 5;
        h1 += (h0 >> 26);
        h0 &= 0x03FFFFFF;

        pos += len;
      }
    }

    // Process Msg
    pos = 0;
    bool msgAligned = (msg.offsetInBytes % 4 == 0);
    Uint32List? msg32;
    ByteData? msgBd;
    if (msgAligned) {
      msg32 = msg.buffer.asUint32List(msg.offsetInBytes);
    } else {
      msgBd = ByteData.sublistView(msg);
    }

    while (pos < msg.length) {
      int len = msg.length - pos;
      if (len >= 16) {
        int t0, t1, t2, t3;
        if (msgAligned) {
          int idx = pos >> 2;
          if (Endian.host == Endian.little) {
            t0 = msg32![idx];
            t1 = msg32[idx + 1];
            t2 = msg32[idx + 2];
            t3 = msg32[idx + 3];
          } else {
            t0 = _swap32(msg32![idx]);
            t1 = _swap32(msg32[idx + 1]);
            t2 = _swap32(msg32[idx + 2]);
            t3 = _swap32(msg32[idx + 3]);
          }
        } else if (msgBd != null) {
          t0 = msgBd.getUint32(pos, Endian.little);
          t1 = msgBd.getUint32(pos + 4, Endian.little);
          t2 = msgBd.getUint32(pos + 8, Endian.little);
          t3 = msgBd.getUint32(pos + 12, Endian.little);
        } else {
          t0 = msg[pos] |
              (msg[pos + 1] << 8) |
              (msg[pos + 2] << 16) |
              (msg[pos + 3] << 24);
          t1 = msg[pos + 4] |
              (msg[pos + 5] << 8) |
              (msg[pos + 6] << 16) |
              (msg[pos + 7] << 24);
          t2 = msg[pos + 8] |
              (msg[pos + 9] << 8) |
              (msg[pos + 10] << 16) |
              (msg[pos + 11] << 24);
          t3 = msg[pos + 12] |
              (msg[pos + 13] << 8) |
              (msg[pos + 14] << 16) |
              (msg[pos + 15] << 24);
        }

        h0 += t0 & 0x03FFFFFF;
        h1 += ((t0 >> 26) | (t1 << 6)) & 0x03FFFFFF;
        h2 += ((t1 >> 20) | (t2 << 12)) & 0x03FFFFFF;
        h3 += ((t2 >> 14) | (t3 << 18)) & 0x03FFFFFF;
        h4 += (t3 >> 8) | (1 << 24);

        int d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
        int d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
        int d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
        int d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
        int d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;

        h0 = d0 & 0x03FFFFFF;
        d1 += (d0 >> 26);
        h1 = d1 & 0x03FFFFFF;
        d2 += (d1 >> 26);
        h2 = d2 & 0x03FFFFFF;
        d3 += (d2 >> 26);
        h3 = d3 & 0x03FFFFFF;
        d4 += (d3 >> 26);
        h4 = d4 & 0x03FFFFFF;
        h0 += (d4 >> 26) * 5;
        h1 += (h0 >> 26);
        h0 &= 0x03FFFFFF;

        pos += 16;
      } else {
        final tmp = Uint8List(16);
        for (int i = 0; i < len; i++) {
          tmp[i] = msg[pos + i];
        }
        int t0 = tmp[0] | (tmp[1] << 8) | (tmp[2] << 16) | (tmp[3] << 24);
        int t1 = tmp[4] | (tmp[5] << 8) | (tmp[6] << 16) | (tmp[7] << 24);
        int t2 = tmp[8] | (tmp[9] << 8) | (tmp[10] << 16) | (tmp[11] << 24);
        int t3 = tmp[12] | (tmp[13] << 8) | (tmp[14] << 16) | (tmp[15] << 24);

        h0 += t0 & 0x03FFFFFF;
        h1 += ((t0 >> 26) | (t1 << 6)) & 0x03FFFFFF;
        h2 += ((t1 >> 20) | (t2 << 12)) & 0x03FFFFFF;
        h3 += ((t2 >> 14) | (t3 << 18)) & 0x03FFFFFF;
        h4 += (t3 >> 8) | (1 << 24);

        int d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
        int d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
        int d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
        int d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
        int d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;

        h0 = d0 & 0x03FFFFFF;
        d1 += (d0 >> 26);
        h1 = d1 & 0x03FFFFFF;
        d2 += (d1 >> 26);
        h2 = d2 & 0x03FFFFFF;
        d3 += (d2 >> 26);
        h3 = d3 & 0x03FFFFFF;
        d4 += (d3 >> 26);
        h4 = d4 & 0x03FFFFFF;
        h0 += (d4 >> 26) * 5;
        h1 += (h0 >> 26);
        h0 &= 0x03FFFFFF;

        pos += len;
      }
    }

    // Lengths
    int aadLen = aad.length;
    int msgLen = msg.length;

    int t0 = aadLen & 0xFFFFFFFF;
    int t1 = (aadLen >>> 32) & 0xFFFFFFFF; // Unsigned shift just in case
    int t2 = msgLen & 0xFFFFFFFF;
    int t3 = (msgLen >>> 32) & 0xFFFFFFFF;

    h0 += t0 & 0x03FFFFFF;
    h1 += ((t0 >> 26) | (t1 << 6)) & 0x03FFFFFF;
    h2 += ((t1 >> 20) | (t2 << 12)) & 0x03FFFFFF;
    h3 += ((t2 >> 14) | (t3 << 18)) & 0x03FFFFFF;
    h4 += (t3 >> 8) | (1 << 24);

    int d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
    int d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
    int d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
    int d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
    int d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;

    h0 = d0 & 0x03FFFFFF;
    d1 += (d0 >> 26);
    h1 = d1 & 0x03FFFFFF;
    d2 += (d1 >> 26);
    h2 = d2 & 0x03FFFFFF;
    d3 += (d2 >> 26);
    h3 = d3 & 0x03FFFFFF;
    d4 += (d3 >> 26);
    h4 = d4 & 0x03FFFFFF;
    h0 += (d4 >> 26) * 5;
    h1 += (h0 >> 26);
    h0 &= 0x03FFFFFF;

    // Finalize
    h1 += (h0 >> 26);
    h0 &= 0x03FFFFFF;
    h2 += (h1 >> 26);
    h1 &= 0x03FFFFFF;
    h3 += (h2 >> 26);
    h2 &= 0x03FFFFFF;
    h4 += (h3 >> 26);
    h3 &= 0x03FFFFFF;
    h0 += (h4 >> 26) * 5;
    h4 &= 0x03FFFFFF;
    h1 += (h0 >> 26);
    h0 &= 0x03FFFFFF;

    int g0 = h0 + 5;
    int b = g0 >> 26;
    g0 &= 0x03FFFFFF;
    int g1 = h1 + b;
    b = g1 >> 26;
    g1 &= 0x03FFFFFF;
    int g2 = h2 + b;
    b = g2 >> 26;
    g2 &= 0x03FFFFFF;
    int g3 = h3 + b;
    b = g3 >> 26;
    g3 &= 0x03FFFFFF;
    int g4 = h4 + b - (1 << 26);

    int mask = ~(g4 >> 63);

    h0 = (h0 & ~mask) | (g0 & mask);
    h1 = (h1 & ~mask) | (g1 & mask);
    h2 = (h2 & ~mask) | (g2 & mask);
    h3 = (h3 & ~mask) | (g3 & mask);
    h4 = (h4 & ~mask) | (g4 & mask);

    int s_0 = k.getUint32(16, Endian.little);
    int s_1 = k.getUint32(20, Endian.little);
    int s_2 = k.getUint32(24, Endian.little);
    int s_3 = k.getUint32(28, Endian.little);

    int f0 = (h0 | (h1 << 26)) & 0xFFFFFFFF;
    int f1 = ((h1 >> 6) | (h2 << 20)) & 0xFFFFFFFF;
    int f2 = ((h2 >> 12) | (h3 << 14)) & 0xFFFFFFFF;
    int f3 = ((h3 >> 18) | (h4 << 8)) & 0xFFFFFFFF;

    int c = 0;
    int r_0 = f0 + s_0;
    c = r_0 >> 32;
    r_0 &= 0xFFFFFFFF;
    int r_1 = f1 + s_1 + c;
    c = r_1 >> 32;
    r_1 &= 0xFFFFFFFF;
    int r_2 = f2 + s_2 + c;
    c = r_2 >> 32;
    r_2 &= 0xFFFFFFFF;
    int r_3 = f3 + s_3 + c;
    r_3 &= 0xFFFFFFFF;

    final tag = Uint8List(16);
    final tagBd = tag.buffer.asByteData();
    tagBd.setUint32(0, r_0, Endian.little);
    tagBd.setUint32(4, r_1, Endian.little);
    tagBd.setUint32(8, r_2, Endian.little);
    tagBd.setUint32(12, r_3, Endian.little);

    return tag;
  }

  static int _swap32(int val) {
    return ((val & 0xFF) << 24) |
        ((val & 0xFF00) << 8) |
        ((val & 0xFF0000) >> 8) |
        ((val >> 24) & 0xFF);
  }
}
