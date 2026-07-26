import 'dart:typed_data';

/// Official XXH64 — Web backend.
///
/// Uses [BigInt] so dart2js never sees non-representable integer literals, while
/// still producing bit-exact XXH64 digests. Performance is secondary on Web.
class XXHash64 {
  XXHash64._();

  static final BigInt _prime1 = BigInt.parse('9E3779B185EBCA87', radix: 16);
  static final BigInt _prime2 = BigInt.parse('C2B2AE3D27D4EB4F', radix: 16);
  static final BigInt _prime3 = BigInt.parse('165667B19E3779F9', radix: 16);
  static final BigInt _prime4 = BigInt.parse('85EBCA77C2B2AE63', radix: 16);
  static final BigInt _prime5 = BigInt.parse('27D4EB2F165667C5', radix: 16);
  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;
  static final BigInt _mask32 = BigInt.from(0xFFFFFFFF);

  static BigInt _u64(BigInt v) => v & _mask64;

  static BigInt _rotl64(BigInt val, int shift) {
    val = _u64(val);
    return _u64((val << shift) | (val >> (64 - shift)));
  }

  static BigInt _round(BigInt acc, BigInt input) {
    acc = _u64(acc + input * _prime2);
    acc = _rotl64(acc, 31);
    return _u64(acc * _prime1);
  }

  static BigInt _mergeRound(BigInt acc, BigInt val) {
    val = _round(BigInt.zero, val);
    acc ^= val;
    acc = _u64(acc * _prime1);
    return _u64(acc + _prime4);
  }

  static BigInt _readLE64(ByteData bd, int offset) {
    final lo = BigInt.from(bd.getUint32(offset, Endian.little));
    final hi = BigInt.from(bd.getUint32(offset + 4, Endian.little));
    return lo | (hi << 32);
  }

  /// Same mapping as [PlatformByteData.getUint64] on Web (dart2js).
  static int _bigToHashInt(BigInt v) {
    v = _u64(v);
    final lo = (v & _mask32).toInt();
    final hi = ((v >> 32) & _mask32).toInt();
    return hi * 0x100000000 + lo;
  }

  static BigInt _seedToU64(int seed) {
    // Match Web setUint64 / getUint64 bit splitting for the seed value.
    final lo = seed & 0xFFFFFFFF;
    final hi = (seed / 0x100000000).floor() & 0xFFFFFFFF;
    return BigInt.from(lo) | (BigInt.from(hi) << 32);
  }

  static BigInt _digest(Uint8List data, int seed) {
    final len = data.length;
    final seedU = _seedToU64(seed);
    final bd = ByteData.sublistView(data);
    var pos = 0;
    late BigInt h64;

    if (len >= 32) {
      var v1 = _u64(seedU + _prime1 + _prime2);
      var v2 = _u64(seedU + _prime2);
      var v3 = seedU;
      var v4 = _u64(seedU - _prime1);

      final limit = len - 32;
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

      h64 = _u64(
          _rotl64(v1, 1) + _rotl64(v2, 7) + _rotl64(v3, 12) + _rotl64(v4, 18));
      h64 = _mergeRound(h64, v1);
      h64 = _mergeRound(h64, v2);
      h64 = _mergeRound(h64, v3);
      h64 = _mergeRound(h64, v4);
    } else {
      h64 = _u64(seedU + _prime5);
    }

    h64 = _u64(h64 + BigInt.from(len));

    while (pos + 8 <= len) {
      final lane = _readLE64(bd, pos);
      h64 ^= _round(BigInt.zero, lane);
      h64 = _u64(_rotl64(h64, 27) * _prime1);
      h64 = _u64(h64 + _prime4);
      pos += 8;
    }

    if (pos + 4 <= len) {
      final lane = BigInt.from(bd.getUint32(pos, Endian.little));
      h64 ^= _u64(lane * _prime1);
      h64 = _u64(_rotl64(h64, 23) * _prime2);
      h64 = _u64(h64 + _prime3);
      pos += 4;
    }

    while (pos < len) {
      final lane = BigInt.from(data[pos]);
      h64 ^= _u64(lane * _prime5);
      h64 = _u64(_rotl64(h64, 11) * _prime1);
      pos++;
    }

    h64 ^= h64 >> 33;
    h64 = _u64(h64 * _prime2);
    h64 ^= h64 >> 29;
    h64 = _u64(h64 * _prime3);
    h64 ^= h64 >> 32;
    return _u64(h64);
  }

  /// XXH64 digest as [int], using the same mapping as Web [getUint64].
  static int hash(Uint8List data, [int seed = 0]) =>
      _bigToHashInt(_digest(data, seed));

  /// Writes the XXH64 digest as 8 little-endian bytes (bit-exact).
  static void writeHashLE(Uint8List data, ByteData out, int offset,
      [int seed = 0]) {
    final h = _digest(data, seed);
    final lo = (h & _mask32).toInt();
    final hi = ((h >> 32) & _mask32).toInt();
    out.setUint32(offset, lo, Endian.little);
    out.setUint32(offset + 4, hi, Endian.little);
  }
}
