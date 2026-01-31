import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'platform_byte_data.dart';

/// Optimized Manual AES-GCM Implementation
/// Compliant with NIST SP 800-38D
class AESGCM {
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
      throw ArgumentError('Key must be 32 bytes for AES-256');
    }
    aad ??= Uint8List(0);

    final input = plaintext;
    final int totalLength = 12 + input.length + 16;
    final result = Uint8List(totalLength);

    // 1. Prepare AES
    _initTables();
    final expandedKey = _keyExpansion(key);

    // 2. Calculate H = E(K, 0^128)
    final h = Uint32List(4); // 0 initialized
    final hBlock = Uint32List(4);
    _cipher(h, expandedKey, hBlock);

    // Precompute GHASH table for H (4-bit window)
    final hTable = _precomputeGhashTable(hBlock);

    // 3. Prepare J0 (Pre-counter block)
    // For 96-bit nonce: J0 = IV || 0^31 || 1
    // Generate nonce directly into result (0..12)
    final nonce = Uint8List.view(result.buffer, result.offsetInBytes, 12);
    _generateNonceInto(nonce);

    final j0 = Uint32List(4);
    final nonceData = nonce.buffer.asByteData();
    j0[0] = nonceData.getUint32(0);
    j0[1] = nonceData.getUint32(4);
    j0[2] = nonceData.getUint32(8);
    j0[3] = 1;

    // 4. GCTR Encrypt
    // First block of keystream is E(K, J0) - used for tag encryption later
    final tagMask = Uint32List(4);
    _cipher(j0, expandedKey, tagMask);

    // Inc 32 for data encryption
    final counter = Uint32List.fromList(j0);
    counter[3]++; // inc32

    // Encrypt directly into result
    final ciphertext =
        Uint8List.view(result.buffer, result.offsetInBytes + 12, input.length);
    _gctr(expandedKey, counter, input, ciphertext);

    // 5. Calculate GHASH(H, AAD, Ciphertext)
    final s = _ghash(hTable, aad, ciphertext);

    // 6. Generate Tag
    // Tag = GHASH ^ E(K, J0)
    // Write directly to result
    final tagBd = ByteData.view(
        result.buffer, result.offsetInBytes + 12 + input.length, 16);

    tagBd.setUint32(0, s[0] ^ tagMask[0]);
    tagBd.setUint32(4, s[1] ^ tagMask[1]);
    tagBd.setUint32(8, s[2] ^ tagMask[2]);
    tagBd.setUint32(12, s[3] ^ tagMask[3]);

    return result;
  }

  static String decrypt({
    required Uint8List encryptedData,
    Uint8List? key,
    Uint8List? aad,
  }) {
    final plaintextBytes = decryptBytes(
      encryptedData: encryptedData,
      key: key,
      aad: aad,
    );
    return utf8.decode(plaintextBytes);
  }

  static Uint8List decryptBytes({
    required Uint8List encryptedData,
    Uint8List? key,
    Uint8List? aad,
  }) {
    key ??= defaultKey;
    if (key.length != 32) throw ArgumentError('Key must be 32 bytes');
    if (encryptedData.length < 12 + 16) {
      throw ArgumentError('Invalid input length');
    }
    aad ??= Uint8List(0);

    final nonce =
        Uint8List.view(encryptedData.buffer, encryptedData.offsetInBytes, 12);
    final ciphertext = Uint8List.view(encryptedData.buffer,
        encryptedData.offsetInBytes + 12, encryptedData.length - 28);
    final tag = Uint8List.view(encryptedData.buffer,
        encryptedData.offsetInBytes + encryptedData.length - 16, 16);

    // 1. Prepare AES
    _initTables();
    final expandedKey = _keyExpansion(key);

    // 2. Calculate H
    final h = Uint32List(4);
    final hBlock = Uint32List(4);
    _cipher(h, expandedKey, hBlock);
    final hTable = _precomputeGhashTable(hBlock);

    // 3. Calculate GHASH
    final s = _ghash(hTable, aad, ciphertext);

    // 4. Verify Tag
    final j0 = Uint32List(4);
    final nonceData = nonce.buffer.asByteData();
    j0[0] = nonceData.getUint32(0);
    j0[1] = nonceData.getUint32(4);
    j0[2] = nonceData.getUint32(8);
    j0[3] = 1;

    final tagMask = Uint32List(4);
    _cipher(j0, expandedKey, tagMask);

    final computedTag = Uint8List(16);
    final ctBd = computedTag.buffer.asByteData();
    ctBd.setUint32(0, s[0] ^ tagMask[0]);
    ctBd.setUint32(4, s[1] ^ tagMask[1]);
    ctBd.setUint32(8, s[2] ^ tagMask[2]);
    ctBd.setUint32(12, s[3] ^ tagMask[3]);

    if (!_constantTimeEqual(tag, computedTag)) {
      throw ArgumentError('Authentication failed');
    }

    // 5. Decrypt
    final counter = Uint32List.fromList(j0);
    counter[3]++;

    final plaintextBytes = Uint8List(ciphertext.length);
    // _gctr handles input as List<int>
    _gctr(expandedKey, counter, ciphertext, plaintextBytes);

    return plaintextBytes;
  }

  static void _generateNonceInto(Uint8List output) {
    final rng = Random.secure();
    for (int i = 0; i < 12; i++) {
      output[i] = rng.nextInt(256);
    }
  }

  static bool _constantTimeEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int res = 0;
    for (int i = 0; i < a.length; i++) {
      res |= a[i] ^ b[i];
    }
    return res == 0;
  }

  // --- GCM Core ---

  static void _gctr(Uint32List expandedKey, Uint32List counter, List<int> input,
      Uint8List output) {
    final keystream = Uint32List(4);
    int numBlocks = (input.length + 15) ~/ 16;

    // Use ByteData for correct Endianness handling (AES is Big Endian)
    final inBd = input is Uint8List ? ByteData.sublistView(input) : null;
    final outBd = ByteData.sublistView(output);

    for (int i = 0; i < numBlocks; i++) {
      _cipher(counter, expandedKey, keystream);

      int offset = i * 16;
      int remaining = input.length - offset;

      if (remaining >= 16) {
        if (inBd != null) {
          // ByteData defaults to Big Endian, matching AES keystream
          outBd.setUint32(offset, inBd.getUint32(offset) ^ keystream[0]);
          outBd.setUint32(
              offset + 4, inBd.getUint32(offset + 4) ^ keystream[1]);
          outBd.setUint32(
              offset + 8, inBd.getUint32(offset + 8) ^ keystream[2]);
          outBd.setUint32(
              offset + 12, inBd.getUint32(offset + 12) ^ keystream[3]);
        } else {
          // Fallback for List<int>
          for (int j = 0; j < 16; j++) {
            int wordIdx = j >> 2;
            int byteShift = 24 - (j & 3) * 8;
            int kByte = (keystream[wordIdx] >> byteShift) & 0xFF;
            output[offset + j] = input[offset + j] ^ kByte;
          }
        }
      } else {
        // Partial block
        for (int j = 0; j < remaining; j++) {
          int wordIdx = j >> 2;
          int byteShift = 24 - (j & 3) * 8;
          int kByte = (keystream[wordIdx] >> byteShift) & 0xFF;
          output[offset + j] = input[offset + j] ^ kByte;
        }
      }

      counter[3]++;
    }
  }

  // --- GHASH (Optimized 4-bit Table) ---

  static final Uint32List _ghashRedTable = Uint32List(16);

  static void _initGcmTables() {
    if (_ghashRedTable[1] != 0) return; // Already initialized

    // Precompute reduction table for 4-bit right shift
    for (int i = 0; i < 16; i++) {
      int r = i;
      int m = 0;
      for (int k = 0; k < 4; k++) {
        bool lsb = (r & 1) != 0;
        r >>>= 1;
        m >>>= 1;
        if (lsb) m ^= 0xE1000000;
      }
      _ghashRedTable[i] = m;
    }
  }

  static List<Uint32List> _precomputeGhashTable(Uint32List h) {
    // Table M[0..15]. M[i] = i * H.
    final table = List<Uint32List>.generate(16, (_) => Uint32List(4));

    // M[8] = H (MSB bit of nibble corresponds to H)
    table[8].setAll(0, h);

    // M[4] = H / 2
    _shiftRight(table[8], table[4]);
    // M[2] = H / 4
    _shiftRight(table[4], table[2]);
    // M[1] = H / 8
    _shiftRight(table[2], table[1]);

    // Fill others
    for (int i = 1; i < 16; i++) {
      if ((i & (i - 1)) != 0) {
        // Not power of 2
        int bit = 1;
        while ((i & bit) == 0) {
          bit <<= 1;
        }
        final base = table[bit];
        final rest = table[i ^ bit];
        final dest = table[i];
        dest[0] = base[0] ^ rest[0];
        dest[1] = base[1] ^ rest[1];
        dest[2] = base[2] ^ rest[2];
        dest[3] = base[3] ^ rest[3];
      }
    }

    return table;
  }

  static void _shiftRight(Uint32List src, Uint32List dst) {
    int v0 = src[0];
    int v1 = src[1];
    int v2 = src[2];
    int v3 = src[3];

    bool lsbSet = (v3 & 1) != 0;

    v3 = (v3 >>> 1) | ((v2 & 1) << 31);
    v2 = (v2 >>> 1) | ((v1 & 1) << 31);
    v1 = (v1 >>> 1) | ((v0 & 1) << 31);
    v0 = (v0 >>> 1);

    if (lsbSet) {
      v0 ^= 0xE1000000;
    }

    dst[0] = v0;
    dst[1] = v1;
    dst[2] = v2;
    dst[3] = v3;
  }

  static Uint32List _ghash(
      List<Uint32List> hTable, Uint8List aad, Uint8List ciphertext) {
    final y = Uint32List(4); // Accumulator

    void processBlock(Uint8List data, int offset) {
      // XOR block into Y (Big Endian load)
      y[0] ^= (data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3];
      y[1] ^= (data[offset + 4] << 24) |
          (data[offset + 5] << 16) |
          (data[offset + 6] << 8) |
          data[offset + 7];
      y[2] ^= (data[offset + 8] << 24) |
          (data[offset + 9] << 16) |
          (data[offset + 10] << 8) |
          data[offset + 11];
      y[3] ^= (data[offset + 12] << 24) |
          (data[offset + 13] << 16) |
          (data[offset + 14] << 8) |
          data[offset + 15];

      // Compute Y = Y * H using 4-bit table
      // Process Y from LSB to MSB to match _gf128Mul logic
      // (MSB of Y is multiplied by H, LSB by H * alpha^-127)
      // With right-shift logic, the value added LAST gets shifted LEAST.
      // So we must add the LSB part FIRST (so it gets shifted 31 times? No).
      // Wait.
      // _gf128Mul:
      // Iter 0 (MSB): Add Y. Shift.
      // Iter 127 (LSB): Add Y. Shift.
      // Result: MSB * Y * alpha^-127? No.
      // Let's trace:
      // Z = 0.
      // i=0 (MSB): Z ^= Y. Z >>>= 1. (Z is Y alpha^-1)
      // i=1: Z ^= Y. Z >>>= 1. (Z is (Y alpha^-1 + Y) alpha^-1 = Y alpha^-2 + Y alpha^-1)
      // ...
      // This accumulates: MSB * Y * alpha^-128 + ...
      // This means MSB is shifted MOST.

      // My Table Logic:
      // Z = 0.
      // Step 0: Z ^= M[n]. Z >>>= 4.
      // ...
      // Step 31: Z ^= M[n].
      // Result: Step0 * alpha^-124 + ... + Step31.
      // So Step 0 is shifted MOST.

      // So Step 0 should be the MSB!
      // So my ORIGINAL order (MSB to LSB) was correct??

      // Let's re-read _gf128Mul carefully.
      /*
       for (int i = 0; i < 128; i++) {
         // Check bit i of X (from MSB)
         if (bitSet) z ^= v;
         // Shift V right
         v = (v >>> 1) ...
       }
       */
      // Here `v` is shifted. `z` is NOT shifted.
      // `v` starts as `y`.
      // i=0 (MSB): z ^= y. v becomes y*alpha^-1.
      // i=1: z ^= y*alpha^-1. v becomes y*alpha^-2.
      // So MSB is multiplied by Y.
      // LSB is multiplied by Y*alpha^-127.

      // My Table Logic:
      // I am shifting Z (the accumulator).
      // This is Shoup's method.
      // Shoup:
      // Z = 0.
      // For i = 0 to 15:
      //   Z = Z * P^8 (Shift left 8 bits / right 8 bits)
      //   Z = Z ^ Table[x_i]

      // If we shift Z, then the value added FIRST gets shifted MOST.
      // If we want MSB to be multiplied by Y (H).
      // And LSB to be multiplied by Y*alpha^-127.
      // Then MSB should be added LAST?
      // If MSB is added last, it is shifted 0 times.
      // If MSB is added first, it is shifted 31 times.

      // In `_gf128Mul`, MSB is multiplied by `v` (which is `y`).
      // `v` is NOT shifted yet for the first bit.
      // So MSB * Y.

      // In my Table logic:
      // If I want MSB * H.
      // And `M[MSB]` is `H`.
      // Then I want `M[MSB]` to be shifted 0 times.
      // So `M[MSB]` must be added LAST.

      // So I must process LSB to MSB.
      // Step 0 (LSB): Add M[LSB]. Shift Z.
      // ...
      // Step 31 (MSB): Add M[MSB]. (No shift after loop? Or shift before?)

      // Loop:
      // for ...
      //   Shift Z.
      //   Add M.

      // Iteration 0: Shift Z (0). Add M[n0]. Z = M[n0].
      // Iteration 1: Shift Z (M[n0] >> 4). Add M[n1]. Z = M[n0]>>4 ^ M[n1].
      // ...
      // Last Iteration: Z = ... ^ M[n_last].
      // So M[n_last] is NOT shifted.
      // M[n_first] is shifted MOST.

      // We want MSB to be shifted 0 times (to match `_gf128Mul` MSB * Y).
      // So MSB must be processed LAST.
      // So we must process LSB to MSB.

      // Correct Order: LSB to MSB.

      int z0 = 0, z1 = 0, z2 = 0, z3 = 0;

      // Process Y from LSB to MSB.
      // Y[3] is LSB word.
      for (int i = 3; i >= 0; i--) {
        int word = y[i];
        // Process nibbles LSB to MSB
        for (int s = 0; s <= 28; s += 4) {
          int nibble = (word >>> s) & 0xF;

          // Shift Z right by 4
          int rem = z3 & 0xF;
          z3 = (z3 >>> 4) | ((z2 & 0xF) << 28);
          z2 = (z2 >>> 4) | ((z1 & 0xF) << 28);
          z1 = (z1 >>> 4) | ((z0 & 0xF) << 28);
          z0 = (z0 >>> 4);
          z0 ^= _ghashRedTable[rem];

          // XOR M[nibble]
          final m = hTable[nibble];
          z0 ^= m[0];
          z1 ^= m[1];
          z2 ^= m[2];
          z3 ^= m[3];
        }
      }

      y[0] = z0;
      y[1] = z1;
      y[2] = z2;
      y[3] = z3;
    }

    // AAD
    int pos = 0;
    while (pos + 16 <= aad.length) {
      processBlock(aad, pos);
      pos += 16;
    }
    if (pos < aad.length) {
      final tmp = Uint8List(16);
      for (int i = 0; i < aad.length - pos; i++) {
        tmp[i] = aad[pos + i];
      }
      processBlock(tmp, 0);
    }

    // Ciphertext
    pos = 0;
    while (pos + 16 <= ciphertext.length) {
      processBlock(ciphertext, pos);
      pos += 16;
    }
    if (pos < ciphertext.length) {
      final tmp = Uint8List(16);
      for (int i = 0; i < ciphertext.length - pos; i++) {
        tmp[i] = ciphertext[pos + i];
      }
      processBlock(tmp, 0);
    }

    // Lengths
    final lenBlock = Uint8List(16);
    final lenBd = lenBlock.buffer.asByteData();
    PlatformByteData.setUint64(lenBd, 0, aad.length * 8, Endian.big);
    PlatformByteData.setUint64(lenBd, 8, ciphertext.length * 8, Endian.big);
    processBlock(lenBlock, 0);

    return y;
  }

  // --- AES Core (Unrolled) ---

  // ignore: non_constant_identifier_names
  static final Uint32List _Te0 = Uint32List(256);
  // ignore: non_constant_identifier_names
  static final Uint32List _Te1 = Uint32List(256);
  // ignore: non_constant_identifier_names
  static final Uint32List _Te2 = Uint32List(256);
  // ignore: non_constant_identifier_names
  static final Uint32List _Te3 = Uint32List(256);
  static final Uint8List _sbox = Uint8List(256);
  static final Uint32List _rcon = Uint32List(15);
  static bool _tablesInitialized = false;

  static void _initTables() {
    if (_tablesInitialized) return;
    _initGcmTables(); // Init GCM tables too

    final log = Uint8List(256);
    final alog = Uint8List(256);

    int p = 1;
    for (int i = 0; i < 256; i++) {
      alog[i] = p;
      log[p] = i;
      p = p ^ ((p << 1) ^ ((p & 0x80) != 0 ? 0x11b : 0));
      p &= 0xff;
    }

    _sbox[0] = 0x63;
    for (int i = 1; i < 256; i++) {
      int y = alog[255 - log[i]];
      int z = y;
      z = (z << 1) | (z >> 7);
      y ^= z;
      z = (z << 1) | (z >> 7);
      y ^= z;
      z = (z << 1) | (z >> 7);
      y ^= z;
      z = (z << 1) | (z >> 7);
      y ^= z;
      _sbox[i] = (y ^ 0x63) & 0xff;
    }

    for (int i = 0; i < 256; i++) {
      int s = _sbox[i];
      int x2 = (s << 1) ^ ((s & 0x80) != 0 ? 0x11b : 0);
      int x3 = x2 ^ s;
      int t = (x2 << 24) | (s << 16) | (s << 8) | x3;
      _Te0[i] = t;
      _Te1[i] = (t << 24) | (t >>> 8);
      _Te2[i] = (t << 16) | (t >>> 16);
      _Te3[i] = (t << 8) | (t >>> 24);
    }

    int r = 1;
    for (int i = 0; i < 15; i++) {
      _rcon[i] = r << 24;
      r = (r << 1) ^ ((r & 0x80) != 0 ? 0x11b : 0);
    }

    _tablesInitialized = true;
  }

  static Uint32List _keyExpansion(Uint8List key) {
    int nk = key.length ~/ 4;
    int nr = nk + 6;
    int nb = 4;
    final w = Uint32List(nb * (nr + 1));

    final keyData = key.buffer.asByteData();
    for (int i = 0; i < nk; i++) {
      w[i] = keyData.getUint32(i * 4);
    }

    for (int i = nk; i < nb * (nr + 1); i++) {
      int temp = w[i - 1];
      if (i % nk == 0) {
        int t = (temp << 8) | (temp >>> 24);
        temp = (_sbox[(t >>> 24) & 0xff] << 24) ^
            (_sbox[(t >>> 16) & 0xff] << 16) ^
            (_sbox[(t >>> 8) & 0xff] << 8) ^
            (_sbox[t & 0xff]) ^
            _rcon[(i ~/ nk) - 1];
      } else if (nk > 6 && (i % nk == 4)) {
        temp = (_sbox[(temp >>> 24) & 0xff] << 24) ^
            (_sbox[(temp >>> 16) & 0xff] << 16) ^
            (_sbox[(temp >>> 8) & 0xff] << 8) ^
            (_sbox[temp & 0xff]);
      }
      w[i] = w[i - nk] ^ temp;
    }
    return w;
  }

  static void _cipher(Uint32List input, Uint32List w, Uint32List output) {
    // Unrolled AES-256 (14 rounds)
    int s0 = input[0] ^ w[0];
    int s1 = input[1] ^ w[1];
    int s2 = input[2] ^ w[2];
    int s3 = input[3] ^ w[3];

    int t0, t1, t2, t3;

    // Round 1
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[4];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[5];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[6];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[7];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 2
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[8];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[9];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[10];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[11];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 3
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[12];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[13];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[14];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[15];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 4
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[16];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[17];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[18];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[19];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 5
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[20];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[21];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[22];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[23];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 6
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[24];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[25];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[26];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[27];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 7
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[28];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[29];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[30];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[31];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 8
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[32];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[33];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[34];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[35];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 9
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[36];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[37];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[38];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[39];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 10
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[40];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[41];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[42];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[43];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 11
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[44];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[45];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[46];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[47];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 12
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[48];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[49];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[50];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[51];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Round 13
    t0 = _Te0[(s0 >>> 24) & 0xff] ^
        _Te1[(s1 >>> 16) & 0xff] ^
        _Te2[(s2 >>> 8) & 0xff] ^
        _Te3[s3 & 0xff] ^
        w[52];
    t1 = _Te0[(s1 >>> 24) & 0xff] ^
        _Te1[(s2 >>> 16) & 0xff] ^
        _Te2[(s3 >>> 8) & 0xff] ^
        _Te3[s0 & 0xff] ^
        w[53];
    t2 = _Te0[(s2 >>> 24) & 0xff] ^
        _Te1[(s3 >>> 16) & 0xff] ^
        _Te2[(s0 >>> 8) & 0xff] ^
        _Te3[s1 & 0xff] ^
        w[54];
    t3 = _Te0[(s3 >>> 24) & 0xff] ^
        _Te1[(s0 >>> 16) & 0xff] ^
        _Te2[(s1 >>> 8) & 0xff] ^
        _Te3[s2 & 0xff] ^
        w[55];
    s0 = t0;
    s1 = t1;
    s2 = t2;
    s3 = t3;

    // Final Round (14)
    output[0] = ((_sbox[(s0 >>> 24) & 0xff] << 24) ^
            (_sbox[(s1 >>> 16) & 0xff] << 16) ^
            (_sbox[(s2 >>> 8) & 0xff] << 8) ^
            (_sbox[s3 & 0xff])) ^
        w[56];
    output[1] = ((_sbox[(s1 >>> 24) & 0xff] << 24) ^
            (_sbox[(s2 >>> 16) & 0xff] << 16) ^
            (_sbox[(s3 >>> 8) & 0xff] << 8) ^
            (_sbox[s0 & 0xff])) ^
        w[57];
    output[2] = ((_sbox[(s2 >>> 24) & 0xff] << 24) ^
            (_sbox[(s3 >>> 16) & 0xff] << 16) ^
            (_sbox[(s0 >>> 8) & 0xff] << 8) ^
            (_sbox[s1 & 0xff])) ^
        w[58];
    output[3] = ((_sbox[(s3 >>> 24) & 0xff] << 24) ^
            (_sbox[(s0 >>> 16) & 0xff] << 16) ^
            (_sbox[(s1 >>> 8) & 0xff] << 8) ^
            (_sbox[s2 & 0xff])) ^
        w[59];
  }
}
