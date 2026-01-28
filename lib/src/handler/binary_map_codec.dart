import 'dart:convert';
import 'dart:typed_data';

import 'platform_byte_data.dart';

/// A compact binary codec for Map<String, dynamic>.
///
/// This is a MessagePack-compatible subset with a small custom extension:
/// - BigInt is encoded as MessagePack ext (type=1) with decimal string payload.
///
/// Goals:
/// - Avoid JSON for hot data paths (partition blocks, WAL payloads)
/// - Deterministic, fast, and safe (DoS size limits)
class BinaryMapCodec {
  // Maximum sizes to prevent DoS attacks via large arrays/maps
  static const int maxArraySize = 1000000; // 1M elements
  static const int maxMapSize = 1000000; // 1M entries
  static const int maxStringLength = 100 * 1024 * 1024; // 100MB per string
  static const int maxBinaryLength = 256 * 1024 * 1024; // 256MB per binary blob

  // MessagePack ext type for BigInt
  static const int _extTypeBigInt = 1;

  static Uint8List encodeMap(Map<String, dynamic> map) {
    final buffer = BytesBuilder(copy: false);

    final entries = map.entries.take(maxMapSize).toList(growable: false);

    // map32
    buffer.addByte(0xDF);
    buffer.add(_u32be(entries.length));

    for (final e in entries) {
      _writeString(buffer, e.key);
      _writeValue(buffer, e.value);
    }

    return buffer.toBytes();
  }

  static Map<String, dynamic>? decodeMap(Uint8List data) {
    if (data.isEmpty) return null;
    try {
      final r = _Reader(data);
      final v = _readValue(r);
      if (v is Map<String, dynamic>) return v;
      return null;
    } catch (_) {
      return null;
    }
  }

  static void _writeValue(BytesBuilder b, dynamic value) {
    if (value == null) {
      b.addByte(0xC0);
      return;
    }

    if (value is bool) {
      b.addByte(value ? 0xC3 : 0xC2);
      return;
    }

    if (value is int) {
      // Prefer smallest forms, but keep implementation simple.
      if (value >= 0 && value < 128) {
        b.addByte(value); // positive fixint
        return;
      }
      if (value >= -32 && value < 0) {
        b.addByte(0xE0 | (value & 0x1F)); // negative fixint
        return;
      }
      // int32
      if (value >= -0x80000000 && value <= 0x7FFFFFFF) {
        b.addByte(0xD2);
        b.add(_i32be(value));
        return;
      }
      // int64 (MessagePack)
      if (value >= -0x8000000000000000 && value < 0x8000000000000000) {
        b.addByte(0xD3);
        b.add(_i64be(value));
        return;
      }
      // Fallback for VM big ints: encode as BigInt ext
      _writeBigIntExt(b, BigInt.from(value));
      return;
    }

    if (value is BigInt) {
      _writeBigIntExt(b, value);
      return;
    }

    if (value is double) {
      b.addByte(0xCB);
      b.add(_f64be(value));
      return;
    }

    if (value is String) {
      _writeString(b, value);
      return;
    }

    if (value is Uint8List) {
      _writeBinary(b, value);
      return;
    }

    if (value is List) {
      final length = value.length > maxArraySize ? maxArraySize : value.length;
      b.addByte(0xDD); // array32
      b.add(_u32be(length));
      for (int i = 0; i < length; i++) {
        _writeValue(b, value[i]);
      }
      return;
    }

    if (value is Map) {
      final entries = value.entries.take(maxMapSize).toList(growable: false);
      b.addByte(0xDF); // map32
      b.add(_u32be(entries.length));
      for (final e in entries) {
        _writeString(b, e.key.toString());
        _writeValue(b, e.value);
      }
      return;
    }

    // Unsupported
    b.addByte(0xC0);
  }

  static void _writeString(BytesBuilder b, String s) {
    final bytes = utf8.encode(s);
    final len = bytes.length > maxStringLength ? maxStringLength : bytes.length;
    final out = (len < bytes.length) ? bytes.sublist(0, len) : bytes;

    if (len < 32) {
      b.addByte(0xA0 | len); // fixstr
    } else {
      b.addByte(0xDB); // str32
      b.add(_u32be(len));
    }
    b.add(out);
  }

  static void _writeBinary(BytesBuilder b, Uint8List bytes) {
    final len = bytes.length > maxBinaryLength ? maxBinaryLength : bytes.length;
    final out = (len < bytes.length) ? bytes.sublist(0, len) : bytes;
    b.addByte(0xC6); // bin32
    b.add(_u32be(len));
    b.add(out);
  }

  static void _writeBigIntExt(BytesBuilder b, BigInt v) {
    final payload = utf8.encode(v.toString());
    final len = payload.length;
    // ext32
    b.addByte(0xC9);
    b.add(_u32be(len));
    b.addByte(_extTypeBigInt);
    b.add(payload);
  }

  static dynamic _readValue(_Reader r) {
    final byte = r.u8();

    // positive fixint
    if (byte < 0x80) return byte;

    // negative fixint
    if (byte >= 0xE0) return (byte & 0x1F) - 32;

    // fixstr
    if (byte >= 0xA0 && byte < 0xC0) {
      final len = byte & 0x1F;
      return _readString(r, len);
    }

    switch (byte) {
      case 0xC0:
        return null;
      case 0xC2:
        return false;
      case 0xC3:
        return true;
      case 0xCB:
        return r.f64be();
      case 0xD2:
        return r.i32be();
      case 0xD3:
        return r.i64be();
      case 0xDB:
        return _readString(r, r.u32be());
      case 0xC6:
        return _readBinary(r, r.u32be());
      case 0xDD:
        return _readArray32(r);
      case 0xDF:
        return _readMap32(r);
      case 0xC7: // ext8
        return _readExt(r, r.u8());
      case 0xC8: // ext16
        return _readExt(r, r.u16be());
      case 0xC9: // ext32
        return _readExt(r, r.u32be());
      default:
        throw FormatException(
            'Unsupported MessagePack type: 0x${byte.toRadixString(16)}');
    }
  }

  static String _readString(_Reader r, int len) {
    if (len > maxStringLength) {
      throw FormatException(
          'String length $len exceeds maximum $maxStringLength');
    }
    final bytes = r.bytes(len);
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Uint8List _readBinary(_Reader r, int len) {
    if (len > maxBinaryLength) {
      throw FormatException(
          'Binary length $len exceeds maximum $maxBinaryLength');
    }
    return r.bytes(len);
  }

  static List<dynamic> _readArray32(_Reader r) {
    final count = r.u32be();
    if (count > maxArraySize) {
      throw FormatException('Array size $count exceeds maximum $maxArraySize');
    }
    final out = <dynamic>[];
    out.length = count;
    for (int i = 0; i < count; i++) {
      out[i] = _readValue(r);
    }
    return out;
  }

  static Map<String, dynamic> _readMap32(_Reader r) {
    final count = r.u32be();
    if (count > maxMapSize) {
      throw FormatException('Map size $count exceeds maximum $maxMapSize');
    }
    final out = <String, dynamic>{};
    for (int i = 0; i < count; i++) {
      final k = _readValue(r);
      if (k is! String) {
        throw FormatException('Map key must be string, got ${k.runtimeType}');
      }
      out[k] = _readValue(r);
    }
    return out;
  }

  static dynamic _readExt(_Reader r, int len) {
    final type = r.u8();
    final payload = r.bytes(len);
    if (type == _extTypeBigInt) {
      final s = utf8.decode(payload, allowMalformed: true);
      return BigInt.tryParse(s) ?? BigInt.zero;
    }
    // Unknown extension: return raw bytes.
    return payload;
  }

  // MessagePack uses big-endian for multi-byte integers and floats
  static Uint8List _u32be(int v) =>
      (ByteData(4)..setUint32(0, v, Endian.big)).buffer.asUint8List();

  static Uint8List _i32be(int v) =>
      (ByteData(4)..setInt32(0, v, Endian.big)).buffer.asUint8List();

  static Uint8List _i64be(int v) => (ByteData(8)
        ..apply((bd) => PlatformByteData.setInt64(bd, 0, v, Endian.big)))
      .buffer
      .asUint8List();

  static Uint8List _f64be(double v) =>
      (ByteData(8)..setFloat64(0, v, Endian.big)).buffer.asUint8List();
}

extension _Apply<T> on T {
  T apply(void Function(T) f) {
    f(this);
    return this;
  }
}

final class _Reader {
  final Uint8List b;
  int off = 0;
  _Reader(this.b);

  int u8() {
    if (off + 1 > b.length) throw RangeError('Read beyond buffer');
    return b[off++];
  }

  int u16be() {
    if (off + 2 > b.length) throw RangeError('Read beyond buffer');
    final v = ByteData.sublistView(b, off, off + 2).getUint16(0, Endian.big);
    off += 2;
    return v;
  }

  int u32be() {
    if (off + 4 > b.length) throw RangeError('Read beyond buffer');
    final v = ByteData.sublistView(b, off, off + 4).getUint32(0, Endian.big);
    off += 4;
    return v;
  }

  int i32be() {
    if (off + 4 > b.length) throw RangeError('Read beyond buffer');
    final v = ByteData.sublistView(b, off, off + 4).getInt32(0, Endian.big);
    off += 4;
    return v;
  }

  int i64be() {
    if (off + 8 > b.length) throw RangeError('Read beyond buffer');
    final v = PlatformByteData.getInt64(
        ByteData.sublistView(b, off, off + 8), 0, Endian.big);
    off += 8;
    return v;
  }

  double f64be() {
    if (off + 8 > b.length) throw RangeError('Read beyond buffer');
    final v = ByteData.sublistView(b, off, off + 8).getFloat64(0, Endian.big);
    off += 8;
    return v;
  }

  Uint8List bytes(int len) {
    if (len <= 0) return Uint8List(0);
    if (off + len > b.length) throw RangeError('Read beyond buffer');
    final out = b.sublist(off, off + len);
    off += len;
    return out;
  }
}
