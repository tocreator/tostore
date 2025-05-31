import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import '../handler/sha256.dart';

// ChaCha20-Poly1305
class ChaCha20Poly1305 {
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

  /// generate 32-byte key from user string
  /// use SHA256 hash to ensure output is always 32 bytes
  static Uint8List generateKeyFromString(String userKey) {
    if (userKey.isEmpty) return defaultKey;
    // use SHA256 to generate 32-byte key
    return SHA256.stringToBytes(userKey);
  }

  // Encrypts plaintext with key, Key: 32 bytes
  static Uint8List encrypt({
    required String plaintext,
    Uint8List? key,
    Uint8List? aad,
  }) {
    aad ??= Uint8List(0);
    key ??= defaultKey;
    if (key.length != 32) throw ArgumentError('Key must be 32 bytes');
    // Generate a random 12-byte nonce internally
    final nonce = _generateNonce();

    // Step 1: Generate Poly1305 key by encrypting 64 zero bytes with counter = 0
    final polyKeyBlock = _chacha20Block(key, 0, nonce);
    // Use first 32 bytes as Poly1305 key
    final polyKey = polyKeyBlock.sublist(0, 32);

    // Step 2: Encrypt plaintext using ChaCha20 with counter starting at 1
    final ciphertext = _chacha20Encrypt(key, nonce, 1, utf8.encode(plaintext));

    // Step 3: Compute MAC over AAD || padding || ciphertext || padding || lengths
    final List<int> macData = [];
    macData.addAll(aad);
    int aadPad = (16 - (aad.length % 16)) % 16;
    macData.addAll(List.filled(aadPad, 0));

    macData.addAll(ciphertext);
    int ctPad = (16 - (ciphertext.length % 16)) % 16;
    macData.addAll(List.filled(ctPad, 0));

    final aadLenBytes = _int64ToBytes(aad.length);
    final ctLenBytes = _int64ToBytes(ciphertext.length);
    macData.addAll(aadLenBytes);
    macData.addAll(ctLenBytes);

    final tag = Poly1305.mac(Uint8List.fromList(macData), polyKey);

    final encryptedData = Uint8List.fromList(ciphertext + tag);

    // Prepend the nonce to the encryptedData and return
    return Uint8List.fromList(nonce + encryptedData);
  }

  // Decrypts the input which is encryptedData
  static String decrypt({
    required Uint8List encryptedData,
    Uint8List? key,
    Uint8List? aad,
  }) {
    aad ??= Uint8List(0);
    key ??= defaultKey;
    if (key.length != 32) throw ArgumentError('Key must be 32 bytes');
    if (encryptedData.length < 12 + 16) {
      throw ArgumentError('Invalid input length');
    }

    // Extract nonce from the beginning
    final nonce = encryptedData.sublist(0, 12);
    final actualCipherAndTag = encryptedData.sublist(12);
    if (actualCipherAndTag.length < 16) {
      throw ArgumentError('Invalid input length');
    }

    // Split actualCipherAndTag into ciphertext and tag
    final tag = actualCipherAndTag.sublist(actualCipherAndTag.length - 16);
    final ciphertext =
        actualCipherAndTag.sublist(0, actualCipherAndTag.length - 16);

    final polyKeyBlock = _chacha20Block(key, 0, nonce);
    final polyKey = polyKeyBlock.sublist(0, 32);

    final List<int> macData = [];
    macData.addAll(aad);
    int aadPad = (16 - (aad.length % 16)) % 16;
    macData.addAll(List.filled(aadPad, 0));

    macData.addAll(ciphertext);
    int ctPad = (16 - (ciphertext.length % 16)) % 16;
    macData.addAll(List.filled(ctPad, 0));

    final aadLenBytes = _int64ToBytes(aad.length);
    final ctLenBytes = _int64ToBytes(ciphertext.length);
    macData.addAll(aadLenBytes);
    macData.addAll(ctLenBytes);

    final computedTag = Poly1305.mac(Uint8List.fromList(macData), polyKey);

    if (!_constantTimeEqual(Uint8List.fromList(tag), computedTag)) {
      throw ArgumentError('Authentication failed');
    }

    final plaintext = _chacha20Encrypt(key, nonce, 1, ciphertext);
    return utf8.decode(plaintext);
  }

  static Uint8List _generateNonce() {
    const int nonceLength = 12;
    final rng = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(nonceLength, (_) => rng.nextInt(256)));
  }
}

// Helper: Convert int (64-bit) to 8 bytes little-endian
List<int> _int64ToBytes(int x) {
  final bytes = List<int>.filled(8, 0);
  for (int i = 0; i < 8; i++) {
    bytes[i] = (x >> (8 * i)) & 0xff;
  }
  return bytes;
}

// Constant-time comparison for Uint8List
bool _constantTimeEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// Rotate left 32-bit
int _rotate(int x, int n) {
  return ((x << n) | (x >> (32 - n))) & 0xffffffff;
}

// ChaCha20 quarter round operation
void _quarterRound(Uint32List state, int a, int b, int c, int d) {
  state[a] = (state[a] + state[b]) & 0xffffffff;
  state[d] = _rotate(state[d] ^ state[a], 16);

  state[c] = (state[c] + state[d]) & 0xffffffff;
  state[b] = _rotate(state[b] ^ state[c], 12);

  state[a] = (state[a] + state[b]) & 0xffffffff;
  state[d] = _rotate(state[d] ^ state[a], 8);

  state[c] = (state[c] + state[d]) & 0xffffffff;
  state[b] = _rotate(state[b] ^ state[c], 7);
}

// ChaCha20 block function
Uint8List _chacha20Block(Uint8List key, int counter, Uint8List nonce) {
  // Key length must be 32 bytes, nonce length 12 bytes
  if (key.length != 32) throw ArgumentError('Key must be 32 bytes');
  if (nonce.length != 12) throw ArgumentError('Nonce must be 12 bytes');

  // constants: "expand 32-byte k"
  final constants =
      Uint32List.fromList([0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]);

  // Initialize state (16 words)
  final state = Uint32List(16);
  state.setAll(0, constants);

  // load key into state[4..11]
  for (int i = 0; i < 8; i++) {
    state[4 + i] = key.buffer.asByteData().getUint32(i * 4, Endian.little);
  }

  state[12] = counter;

  // load nonce (12 bytes) into state[13..15]
  for (int i = 0; i < 3; i++) {
    state[13 + i] = nonce.buffer.asByteData().getUint32(i * 4, Endian.little);
  }

  // copy state for working
  final working = Uint32List.fromList(state);

  // 20 rounds (10 double rounds)
  for (int i = 0; i < 10; i++) {
    // Column rounds
    _quarterRound(working, 0, 4, 8, 12);
    _quarterRound(working, 1, 5, 9, 13);
    _quarterRound(working, 2, 6, 10, 14);
    _quarterRound(working, 3, 7, 11, 15);
    // Diagonal rounds
    _quarterRound(working, 0, 5, 10, 15);
    _quarterRound(working, 1, 6, 11, 12);
    _quarterRound(working, 2, 7, 8, 13);
    _quarterRound(working, 3, 4, 9, 14);
  }

  // Add the original state
  for (int i = 0; i < 16; i++) {
    working[i] = (working[i] + state[i]) & 0xffffffff;
  }

  // Convert working state to bytes (little-endian)
  final output = Uint8List(64);
  final outData = output.buffer.asByteData();
  for (int i = 0; i < 16; i++) {
    outData.setUint32(i * 4, working[i], Endian.little);
  }

  return output;
}

// ChaCha20 stream cipher
Uint8List _chacha20Encrypt(
    Uint8List key, Uint8List nonce, int counter, Uint8List input) {
  final output = Uint8List(input.length);
  int blocks = (input.length / 64).ceil();

  for (int block = 0; block < blocks; block++) {
    final keystream = _chacha20Block(key, counter + block, nonce);
    int offset = block * 64;
    int blockSize = min(64, input.length - offset);
    for (int i = 0; i < blockSize; i++) {
      output[offset + i] = input[offset + i] ^ keystream[i];
    }
  }
  return output;
}

// Poly1305 MAC implementation
class Poly1305 {
  // Compute 16-byte Poly1305 authenticator for a message using a 32-byte key
  static Uint8List mac(Uint8List message, Uint8List key) {
    if (key.length != 32) throw ArgumentError('Poly1305 key must be 32 bytes');

    // r and s
    final r = Uint8List.view(key.buffer, key.offsetInBytes, 16);
    final s = Uint8List.view(key.buffer, key.offsetInBytes + 16, 16);

    // Clamp r as per spec
    final rClamped = Uint8List.fromList(r);
    rClamped[3] &= 15;
    rClamped[7] &= 15;
    rClamped[11] &= 15;
    rClamped[15] &= 15;
    rClamped[4] &= 252;
    rClamped[8] &= 252;
    rClamped[12] &= 252;

    // Convert rClamped to BigInt (little-endian)
    BigInt rNum = BigInt.zero;
    for (int i = 0; i < 16; i++) {
      rNum += BigInt.from(rClamped[i]) << (8 * i);
    }

    // s as BigInt
    BigInt sNum = BigInt.zero;
    for (int i = 0; i < 16; i++) {
      sNum += BigInt.from(s[i]) << (8 * i);
    }

    BigInt p = (BigInt.one << 130) - BigInt.from(5);
    BigInt acc = BigInt.zero;

    int offset = 0;
    while (offset < message.length) {
      int chunkSize = min(16, message.length - offset);
      BigInt n = BigInt.zero;
      for (int i = 0; i < chunkSize; i++) {
        n += BigInt.from(message[offset + i]) << (8 * i);
      }
      // Append the 1 bit
      n += BigInt.one << (8 * chunkSize);
      acc = (acc + n) % p;
      acc = (acc * rNum) % p;
      offset += chunkSize;
    }

    // Final tag = (acc + s) mod 2^128
    BigInt tagNum = (acc + sNum) % (BigInt.one << 128);
    // Output tag as 16 bytes little-endian
    final tag = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      tag[i] = (tagNum >> (8 * i)).toInt() & 0xff;
    }
    return tag;
  }
}
