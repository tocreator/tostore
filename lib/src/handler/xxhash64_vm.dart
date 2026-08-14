import 'dart:typed_data';

/// Official XXH64 -- VM / native backend (64-bit `int` arithmetic).
///
/// Primes and the uint64 mask may appear as negative [int] values when the
/// high bit is set (Dart fixed-width / two's-complement literals). Arithmetic
/// still matches unsigned 64-bit XXH64 because add/mul/xor wrap identically
/// in the low 64 bits; right shifts use `>>>`.
class XXHash64 {
  XXHash64._();

  // Official primes from xxHash spec (XXH64).
  static const int _prime1 = 0x9E3779B185EBCA87;
  static const int _prime2 = 0xC2B2AE3D27D4EB4F;
  static const int _prime3 = 0x165667B19E3779F9;
  static const int _prime4 = 0x85EBCA77C2B2AE63;
  static const int _prime5 = 0x27D4EB2F165667C5;
  static const int _mask64 = 0xFFFFFFFFFFFFFFFF;

  static int _rotl64(int val, int shift) {
    val &= _mask64;
    return ((val << shift) | (val >>> (64 - shift))) & _mask64;
  }

  static int _round(int acc, int input) {
    acc = (acc + (input * _prime2)) & _mask64;
    acc = _rotl64(acc, 31);
    return (acc * _prime1) & _mask64;
  }

  static int _mergeRound(int acc, int val) {
    val = _round(0, val);
    acc ^= val;
    acc = (acc * _prime1) & _mask64;
    return (acc + _prime4) & _mask64;
  }

  static int _readLE64(ByteData bd, int offset) =>
      bd.getUint64(offset, Endian.little);

  /// XXH64 digest as an unsigned 64-bit value in a Dart [int].
  static int hash(Uint8List data, [int seed = 0]) {
    final int len = data.length;
    seed &= _mask64;
    int h64;
    int pos = 0;
    final bd = ByteData.sublistView(data);

    if (len >= 32) {
      int v1 = (seed + _prime1 + _prime2) & _mask64;
      int v2 = (seed + _prime2) & _mask64;
      int v3 = seed & _mask64;
      int v4 = (seed - _prime1) & _mask64;

      final int limit = len - 32;
      while (pos <= limit) {
        v1 = _round(v1, _readLE64(bd, pos));
        pos += 8;
        v2 = _round(v2, _readLE64(bd, pos));
        pos += 8;
        v3 = _round(v3, _readLE64(bd, pos));
        pos += 8;
        v4 = _round(v4, _readLE64(bd, pos));
        pos += 8;
      }

      h64 = (_rotl64(v1, 1) +
              _rotl64(v2, 7) +
              _rotl64(v3, 12) +
              _rotl64(v4, 18)) &
          _mask64;
      h64 = _mergeRound(h64, v1);
      h64 = _mergeRound(h64, v2);
      h64 = _mergeRound(h64, v3);
      h64 = _mergeRound(h64, v4);
    } else {
      h64 = (seed + _prime5) & _mask64;
    }

    h64 = (h64 + len) & _mask64;

    while (pos + 8 <= len) {
      final int lane = _readLE64(bd, pos);
      h64 ^= _round(0, lane);
      h64 = (_rotl64(h64, 27) * _prime1) & _mask64;
      h64 = (h64 + _prime4) & _mask64;
      pos += 8;
    }

    if (pos + 4 <= len) {
      final int lane = bd.getUint32(pos, Endian.little);
      h64 ^= (lane * _prime1) & _mask64;
      h64 = (_rotl64(h64, 23) * _prime2) & _mask64;
      h64 = (h64 + _prime3) & _mask64;
      pos += 4;
    }

    while (pos < len) {
      final int lane = data[pos];
      h64 ^= (lane * _prime5) & _mask64;
      h64 = (_rotl64(h64, 11) * _prime1) & _mask64;
      pos++;
    }

    h64 ^= h64 >>> 33;
    h64 = (h64 * _prime2) & _mask64;
    h64 ^= h64 >>> 29;
    h64 = (h64 * _prime3) & _mask64;
    h64 ^= h64 >>> 32;
    return h64 & _mask64;
  }

  /// Writes the XXH64 digest as 8 little-endian bytes (bit-exact on all platforms).
  ///
  /// Prefer this for on-disk checksums so dart2js cannot corrupt the digest via
  /// JS Number round-trips through [PlatformByteData.setUint64].
  static void writeHashLE(Uint8List data, ByteData out, int offset,
      [int seed = 0]) {
    final h = hash(data, seed);
    out.setUint64(offset, h, Endian.little);
  }
}
