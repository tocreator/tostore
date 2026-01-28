import 'dart:convert';
import 'dart:typed_data';

import 'platform_byte_data.dart';

/// MemComparable key encoding for high-performance binary comparison.
///
/// Format per component: [Type:1B][Len:4B little-endian][Data:Len]
/// A composite key is a concatenation of one or more components.
///
/// Notes:
/// - Comparison is done directly on encoded bytes (no JSON decoding).
/// - String ordering supports two modes:
///   - lexicographic (dictionary) order
///   - length-first order (for numeric-string and Base62 short-code monotonic order)
/// - Numeric types are encoded to be byte-wise order-preserving.
class MemComparableKey {
  // ---------- Type tags (keep small) ----------
  static const int typeNull = 0x00;
  static const int typeTextLex = 0x01;
  static const int typeTextLenFirst = 0x02;
  static const int typeInt64 = 0x03;
  static const int typeFloat64 = 0x04;
  static const int typeBool = 0x05;
  static const int typeBytes = 0x06;

  static const int _lenBytes = 4;

  /// Encode a null value.
  ///
  /// Null sorts before any non-null component because [typeNull] is the smallest
  /// type tag.
  static Uint8List encodeNull() {
    return _encode(typeNull, Uint8List(0));
  }

  /// Encode a UTF-8 string with lexicographic (dictionary) ordering.
  static Uint8List encodeTextLex(String value) {
    final data = utf8.encode(value);
    return _encode(typeTextLex, Uint8List.fromList(data));
  }

  /// Encode a UTF-8 string with length-first ordering.
  ///
  /// This is useful for numeric-string and Base62 short-code IDs
  /// where lexicographic by length then bytes matches numeric order.
  static Uint8List encodeTextLenFirst(String value) {
    final data = utf8.encode(value);
    return _encode(typeTextLenFirst, Uint8List.fromList(data));
  }

  /// Encode int64 as an order-preserving 8-byte big-endian payload.
  ///
  /// Implementation: write signed int64 big-endian, then flip the sign bit
  /// so that byte-wise lexicographic order matches numeric order.
  static Uint8List encodeInt64(int value) {
    final payload = Uint8List(8);
    final bd = ByteData.sublistView(payload);
    PlatformByteData.setInt64(bd, 0, value, Endian.big);
    payload[0] ^= 0x80; // sign-bit flip
    return _encode(typeInt64, payload);
  }

  /// Encode float64 as an order-preserving 8-byte big-endian payload.
  ///
  /// Standard IEEE754 sortable transform:
  /// - negative: invert all bits
  /// - positive: flip sign bit
  static Uint8List encodeFloat64(double value) {
    final payload = Uint8List(8);
    final bd = ByteData.sublistView(payload);
    bd.setFloat64(0, value, Endian.big);
    final negative = (payload[0] & 0x80) != 0;
    if (negative) {
      for (int i = 0; i < payload.length; i++) {
        payload[i] = (~payload[i]) & 0xFF;
      }
    } else {
      payload[0] ^= 0x80;
    }
    return _encode(typeFloat64, payload);
  }

  /// Encode boolean.
  static Uint8List encodeBool(bool value) {
    return _encode(typeBool, Uint8List.fromList([value ? 1 : 0]));
  }

  /// Encode raw bytes.
  static Uint8List encodeBytes(Uint8List value) {
    return _encode(typeBytes, value);
  }

  /// Concatenate encoded components to form a composite key.
  static Uint8List encodeTuple(List<Uint8List> components) {
    if (components.isEmpty) return Uint8List(0);
    if (components.length == 1) return components.first;
    final b = BytesBuilder(copy: false);
    for (final c in components) {
      if (c.isNotEmpty) b.add(c);
    }
    return b.toBytes();
  }

  /// Compare two encoded keys.
  ///
  /// This compares component-by-component and supports keys with different
  /// number of components (shorter key sorts before longer if all shared
  /// components are equal).
  static int compare(Uint8List a, Uint8List b) {
    int ia = 0;
    int ib = 0;

    while (ia < a.length && ib < b.length) {
      final typeA = a[ia++];
      final typeB = b[ib++];
      if (typeA != typeB) return typeA < typeB ? -1 : 1;

      if (ia + _lenBytes > a.length || ib + _lenBytes > b.length) {
        // Corrupted encoding; fall back to raw length compare to remain deterministic.
        return a.length.compareTo(b.length);
      }

      final lenA = _readU32LE(a, ia);
      final lenB = _readU32LE(b, ib);
      ia += _lenBytes;
      ib += _lenBytes;

      // Bounds check.
      final endA = ia + lenA;
      final endB = ib + lenB;
      if (endA > a.length || endB > b.length) {
        return a.length.compareTo(b.length);
      }

      final cmp = _compareComponent(typeA, a, ia, lenA, b, ib, lenB);
      if (cmp != 0) return cmp;

      ia = endA;
      ib = endB;
    }

    if (ia == a.length && ib == b.length) return 0;
    return ia == a.length ? -1 : 1;
  }

  /// Decode the last component as UTF-8 text.
  ///
  /// Supports both [typeTextLex] and [typeTextLenFirst].
  /// Returns null if the encoding is invalid or the last component is not text.
  static String? decodeLastText(Uint8List key) {
    final res = splitLastComponent(key);
    return res.lastText;
  }

  /// Split the composite key into (prefix, lastComponentText).
  ///
  /// This is useful for non-unique indexes which are encoded as [fields..., PK].
  /// Returns a record with [prefix] as the bytes before the last component,
  /// and [lastText] if the last component is text.
  static ({Uint8List prefix, String? lastText}) splitLastComponent(
      Uint8List key) {
    if (key.isEmpty) return (prefix: Uint8List(0), lastText: null);

    int off = 0;
    int lastType = -1;
    int lastDataOff = 0;
    int lastDataLen = 0;
    int lastComponentStart = 0;

    while (off < key.length) {
      lastComponentStart = off;
      final type = key[off++];
      if (off + _lenBytes > key.length) break;
      final len = _readU32LE(key, off);
      off += _lenBytes;
      final end = off + len;
      if (end > key.length) break;

      lastType = type;
      lastDataOff = off;
      lastDataLen = len;
      off = end;
    }

    final prefix = key.sublist(0, lastComponentStart);
    String? lastText;
    if (lastType == typeTextLex || lastType == typeTextLenFirst) {
      final data = key.sublist(lastDataOff, lastDataOff + lastDataLen);
      lastText = utf8.decode(data, allowMalformed: true);
    }

    return (prefix: prefix, lastText: lastText);
  }

  static Uint8List _encode(int type, Uint8List data) {
    final out = Uint8List(1 + _lenBytes + data.length);
    out[0] = type;
    _writeU32LE(out, 1, data.length);
    out.setAll(1 + _lenBytes, data);
    return out;
  }

  static int _compareComponent(
    int type,
    Uint8List a,
    int aOff,
    int aLen,
    Uint8List b,
    int bOff,
    int bLen,
  ) {
    switch (type) {
      case typeTextLenFirst:
        // Compare length first, then bytes.
        if (aLen != bLen) return aLen < bLen ? -1 : 1;
        return _compareBytesLex(a, aOff, aLen, b, bOff, bLen);

      case typeTextLex:
        // Compare bytes lexicographically, then length (prefix rule).
        final minLen = aLen < bLen ? aLen : bLen;
        final cmp = _compareBytesLex(a, aOff, minLen, b, bOff, minLen);
        if (cmp != 0) return cmp;
        if (aLen == bLen) return 0;
        return aLen < bLen ? -1 : 1;

      case typeInt64:
      case typeFloat64:
      case typeBool:
      case typeBytes:
      default:
        // For order-preserving numeric payloads and raw bytes, use lexicographic compare.
        final minLen = aLen < bLen ? aLen : bLen;
        final cmp = _compareBytesLex(a, aOff, minLen, b, bOff, minLen);
        if (cmp != 0) return cmp;
        if (aLen == bLen) return 0;
        return aLen < bLen ? -1 : 1;
    }
  }

  static int _compareBytesLex(
    Uint8List a,
    int aOff,
    int aLen,
    Uint8List b,
    int bOff,
    int bLen,
  ) {
    final n = aLen < bLen ? aLen : bLen;
    for (int i = 0; i < n; i++) {
      final av = a[aOff + i];
      final bv = b[bOff + i];
      if (av != bv) return av < bv ? -1 : 1;
    }
    if (aLen == bLen) return 0;
    return aLen < bLen ? -1 : 1;
  }

  static int _readU32LE(Uint8List b, int off) {
    return (b[off]) |
        (b[off + 1] << 8) |
        (b[off + 2] << 16) |
        (b[off + 3] << 24);
  }

  static void _writeU32LE(Uint8List b, int off, int v) {
    b[off] = v & 0xFF;
    b[off + 1] = (v >> 8) & 0xFF;
    b[off + 2] = (v >> 16) & 0xFF;
    b[off + 3] = (v >> 24) & 0xFF;
  }

  static List<Object?> decodeTuple(Uint8List key) {
    var values = <Object?>[];
    int off = 0;
    while (off < key.length) {
      if (off + 1 + _lenBytes > key.length) break;
      final type = key[off++];
      final len = _readU32LE(key, off);
      off += _lenBytes;
      if (off + len > key.length) break;

      final data = key.sublist(off, off + len);
      off += len;

      switch (type) {
        case typeNull:
          values.add(null);
          break;
        case typeTextLex:
        case typeTextLenFirst:
          values.add(utf8.decode(data, allowMalformed: true));
          break;
        case typeInt64:
          values.add(_decodeInt64(data));
          break;
        case typeFloat64:
          values.add(_decodeFloat64(data));
          break;
        case typeBool:
          values.add(data[0] != 0);
          break;
        case typeBytes:
          values.add(data);
          break;
        default:
          // Unknown type, keep as bytes or null?
          // For safety, store null or the raw bytes?
          // Assuming index only contains known types for now.
          values.add(data);
          break;
      }
    }
    return values;
  }

  static int _decodeInt64(Uint8List data) {
    if (data.length != 8) return 0;
    // Copy to avoid modifying the input view if simpler,
    // but here we can modify a temporary buffer or use a mask.
    // Encode logic: payload[0] ^= 0x80;
    // Decode logic: same! (x ^ y ^ y = x)
    final temp = Uint8List.fromList(data);
    temp[0] ^= 0x80;
    final bd = ByteData.sublistView(temp);
    return PlatformByteData.getInt64(bd, 0, Endian.big);
  }

  static double _decodeFloat64(Uint8List data) {
    if (data.length != 8) return 0.0;
    final temp = Uint8List.fromList(data);

    // Enc Logic:
    // negative (orig sign 1): invert all
    // positive (orig sign 0): flip sign (0->1)

    // Dec Logic:
    // If first byte has 0x80 (1xxxxxxx) -> Was Positive.
    // If first byte has 0x00 (0xxxxxxx) -> Was Negative.

    if ((temp[0] & 0x80) != 0) {
      // Was positive. Flip sign bit back.
      temp[0] ^= 0x80;
    } else {
      // Was negative. Invert all bits.
      for (int i = 0; i < temp.length; i++) {
        temp[i] = (~temp[i]) & 0xFF; // Bitwise NOT
      }
    }

    final bd = ByteData.sublistView(temp);
    return bd.getFloat64(0, Endian.big);
  }

  /// Encode a single component based on runtime type.
  /// Throws if type is unsupported.
  static Uint8List encodeComponent(Object? value) {
    if (value is String) return encodeTextLex(value);
    if (value is int) return encodeInt64(value);
    if (value is double) return encodeFloat64(value);
    if (value is bool) return encodeBool(value);
    if (value is Uint8List) return encodeBytes(value);
    // Explicitly handle null?
    // If null is not supported, throw.
    throw ArgumentError(
        'Unsupported type for MemComparableKey: ${value.runtimeType}');
  }
}
