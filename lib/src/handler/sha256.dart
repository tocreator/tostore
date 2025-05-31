import 'dart:convert';
import 'dart:typed_data';

/// SHA256 standard implementation
class SHA256 {
  // 64 constant words for the SHA-256 algorithm, taken from the standard.
  static final List<int> _k = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  // Initial hash values.
  static final List<int> _hInitial = [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];

  /// Computes the SHA-256 hash of the given [message] and returns a 32-byte hash as Uint8List.
  static Uint8List hash(Uint8List message) {
    int messageLength = message.length;
    int bitLength = messageLength * 8;
    // Copy message to a list for padding
    List<int> padded = List<int>.from(message);
    // Append 0x80
    padded.add(0x80);
    // Pad with zeros until length % 64 == 56
    while ((padded.length % 64) != 56) {
      padded.add(0);
    }
    // Append length in bits as a 64-bit big-endian integer
    for (int i = 7; i >= 0; i--) {
      padded.add((bitLength >> (i * 8)) & 0xff);
    }

    int numChunks = padded.length ~/ 64;
    List<int> h = List<int>.from(_hInitial);

    // Process each 64-byte chunk
    for (int i = 0; i < numChunks; i++) {
      int chunkStart = i * 64;
      // Prepare message schedule
      List<int> w = List<int>.filled(64, 0);
      for (int j = 0; j < 16; j++) {
        int index = chunkStart + j * 4;
        w[j] = ((padded[index] << 24) |
                (padded[index + 1] << 16) |
                (padded[index + 2] << 8) |
                (padded[index + 3])) &
            0xffffffff;
      }
      for (int j = 16; j < 64; j++) {
        int s0 = _rotr(w[j - 15], 7) ^ _rotr(w[j - 15], 18) ^ (w[j - 15] >> 3);
        int s1 = _rotr(w[j - 2], 17) ^ _rotr(w[j - 2], 19) ^ (w[j - 2] >> 10);
        w[j] = (w[j - 16] + s0 + w[j - 7] + s1) & 0xffffffff;
      }

      // Initialize working variables
      int a = h[0];
      int b = h[1];
      int c = h[2];
      int d = h[3];
      int e = h[4];
      int f = h[5];
      int g = h[6];
      int hTemp = h[7];

      // Main loop: 64 rounds
      for (int j = 0; j < 64; j++) {
        int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        int ch = (e & f) ^ ((~e) & g);
        int temp1 = (hTemp + s1 + ch + _k[j] + w[j]) & 0xffffffff;
        int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        int maj = (a & b) ^ (a & c) ^ (b & c);
        int temp2 = (s0 + maj) & 0xffffffff;
        hTemp = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }

      // Add this chunk's hash to result so far
      h[0] = (h[0] + a) & 0xffffffff;
      h[1] = (h[1] + b) & 0xffffffff;
      h[2] = (h[2] + c) & 0xffffffff;
      h[3] = (h[3] + d) & 0xffffffff;
      h[4] = (h[4] + e) & 0xffffffff;
      h[5] = (h[5] + f) & 0xffffffff;
      h[6] = (h[6] + g) & 0xffffffff;
      h[7] = (h[7] + hTemp) & 0xffffffff;
    }

    // Convert hash values to 32-byte result (big-endian)
    final result = Uint8List(32);
    for (int i = 0; i < 8; i++) {
      result[i * 4] = (h[i] >> 24) & 0xff;
      result[i * 4 + 1] = (h[i] >> 16) & 0xff;
      result[i * 4 + 2] = (h[i] >> 8) & 0xff;
      result[i * 4 + 3] = h[i] & 0xff;
    }
    return result;
  }

  static int _rotr(int x, int n) {
    return ((x >> n) | (x << (32 - n))) & 0xffffffff;
  }

  /// Convert a string to a SHA-256 hash.
  static Uint8List stringToBytes(String input) {
    final bytes = utf8.encode(input);
    return hash(Uint8List.fromList(bytes));
  }

  /// Convert a SHA-256 hash to a hexadecimal string.
  static String stringToHex(String input) {
    return stringToBytes(input)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Convert a Uint8List to string
  static String bytesToHex(Uint8List input) {
    final bytes = hash(input);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Convert a hexadecimal string to a Uint8List.
  static Uint8List hexToBytes(String hex) {
    if (hex.length % 2 != 0) {
      throw ArgumentError("Hex string must have an even length");
    }
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }
}
