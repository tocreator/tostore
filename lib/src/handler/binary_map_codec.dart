import 'dart:convert';
import 'dart:typed_data';

import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_schema.dart' show VectorData;
import 'platform_byte_data.dart';

/// A compact binary codec for `Map<String, dynamic>`.
///
/// This is a MessagePack-compatible subset with a small custom extension:
/// - BigInt is encoded as MessagePack ext (type=1) with decimal string payload.
/// - VectorData is encoded as MessagePack ext (type=2) with Float64 binary payload.
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
  // MessagePack ext type for VectorData
  static const int _extTypeVector = 2;

  static Uint8List encodeMap(Map<String, dynamic> map) {
    final buffer = BytesBuilder(copy: false);
    final int count = map.length > maxMapSize ? maxMapSize : map.length;

    // map32
    buffer.addByte(0xDF);
    _writeU32be(buffer, count);

    int written = 0;
    for (final e in map.entries) {
      if (++written > maxMapSize) break;
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

  /// Encode a single MessagePack-compatible value (no map wrapper).
  static Uint8List encodeValue(dynamic value) {
    final buffer = BytesBuilder(copy: false);
    _writeValue(buffer, value);
    return buffer.toBytes();
  }

  /// Decode a single MessagePack-compatible value.
  ///
  /// Returns null only when [data] is empty or decoding fails.
  /// A legitimate MessagePack null (`0xC0`) also yields null.
  static dynamic decodeValue(Uint8List data) {
    if (data.isEmpty) return null;
    try {
      final r = _Reader(data);
      return _readValue(r);
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
        _writeI32be(b, value);
        return;
      }
      // int64 (MessagePack)
      // value is int, and didn't fit in smaller types, so use int64.
      b.addByte(0xD3);
      _writeI64be(b, value);
      return;
    }

    if (value is BigInt) {
      _writeBigIntExt(b, value);
      return;
    }

    if (value is VectorData) {
      _writeVectorExt(b, value);
      return;
    }

    if (value is double) {
      b.addByte(0xCB);
      _writeF64be(b, value);
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
      _writeU32be(b, length);
      for (int i = 0; i < length; i++) {
        _writeValue(b, value[i]);
      }
      return;
    }

    if (value is Map) {
      final int count = value.length > maxMapSize ? maxMapSize : value.length;
      b.addByte(0xDF); // map32
      _writeU32be(b, count);
      int written = 0;
      for (final e in value.entries) {
        if (++written > maxMapSize) break;
        _writeString(b, e.key.toString());
        _writeValue(b, e.value);
      }
      return;
    }

    // Unsupported
    b.addByte(0xC0);
  }

  static void _writeString(BytesBuilder b, String s) {
    if (s.isEmpty) {
      b.addByte(0xA0);
      return;
    }

    final int len = s.length;
    if (len < 32) {
      bool isAscii = true;
      for (int i = 0; i < len; i++) {
        if (s.codeUnitAt(i) > 0x7F) {
          isAscii = false;
          break;
        }
      }
      if (isAscii) {
        b.addByte(0xA0 | len);
        for (int i = 0; i < len; i++) {
          b.addByte(s.codeUnitAt(i));
        }
        return;
      }
    }

    final bytes = utf8.encode(s);
    final encLen =
        bytes.length > maxStringLength ? maxStringLength : bytes.length;
    final out = (encLen < bytes.length) ? bytes.sublist(0, encLen) : bytes;

    if (encLen < 32) {
      b.addByte(0xA0 | encLen); // fixstr
    } else {
      b.addByte(0xDB); // str32
      _writeU32be(b, encLen);
    }
    b.add(out);
  }

  static void _writeBinary(BytesBuilder b, Uint8List bytes) {
    final len = bytes.length > maxBinaryLength ? maxBinaryLength : bytes.length;
    final out = (len < bytes.length) ? bytes.sublist(0, len) : bytes;
    b.addByte(0xC6); // bin32
    _writeU32be(b, len);
    b.add(out);
  }

  static void _writeBigIntExt(BytesBuilder b, BigInt v) {
    final payload = utf8.encode(v.toString());
    final len = payload.length;
    // ext32
    b.addByte(0xC9);
    _writeU32be(b, len);
    b.addByte(_extTypeBigInt);
    b.add(payload);
  }

  static void _writeVectorExt(BytesBuilder b, VectorData v) {
    final payload = v.toBytes();
    final len = payload.length;
    // ext32
    b.addByte(0xC9);
    _writeU32be(b, len);
    b.addByte(_extTypeVector);
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
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Binary map codec: Unsupported MessagePack type: 0x${byte.toRadixString(16)}',
          )
        ]);
    }
  }

  static String _readString(_Reader r, int len) {
    if (len > maxStringLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: String length $len exceeds maximum limit of $maxStringLength.',
        )
      ]);
    }
    final bytes = r.bytes(len);
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Uint8List _readBinary(_Reader r, int len) {
    if (len > maxBinaryLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Binary length $len exceeds maximum limit of $maxBinaryLength.',
        )
      ]);
    }
    return r.bytes(len);
  }

  static List<dynamic> _readArray32(_Reader r) {
    final count = r.u32be();
    if (count > maxArraySize) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Array size $count exceeds maximum limit of $maxArraySize.',
        )
      ]);
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
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Map size $count exceeds maximum limit of $maxMapSize.',
        )
      ]);
    }
    final out = <String, dynamic>{};
    for (int i = 0; i < count; i++) {
      final k = _readValue(r);
      if (k is! String) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Binary map codec: Map key must be string, got: ${k.runtimeType}.',
          )
        ]);
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
    if (type == _extTypeVector) {
      try {
        return VectorData.fromBytes(payload);
      } catch (_) {
        return null;
      }
    }
    // Unknown extension: return raw bytes.
    return payload;
  }

  // MessagePack uses big-endian for multi-byte integers and floats.
  // Write directly into [BytesBuilder] to avoid per-value ByteData/Uint8List allocs.
  static final Uint8List _scratch8 = Uint8List(8);
  static final ByteData _scratch8Bd = ByteData.sublistView(_scratch8);

  static void _writeU32be(BytesBuilder b, int v) {
    b.addByte((v >> 24) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte(v & 0xFF);
  }

  static void _writeI32be(BytesBuilder b, int v) {
    b.addByte((v >> 24) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte(v & 0xFF);
  }

  static void _writeI64be(BytesBuilder b, int v) {
    PlatformByteData.setInt64(_scratch8Bd, 0, v, Endian.big);
    b.add(_scratch8);
  }

  static void _writeF64be(BytesBuilder b, double v) {
    _scratch8Bd.setFloat64(0, v, Endian.big);
    b.add(_scratch8);
  }
}

final class _Reader {
  final Uint8List b;
  int off = 0;
  _Reader(this.b);

  int u8() {
    if (off + 1 > b.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Read beyond buffer. Offset: $off, Buffer length: ${b.length}.',
        )
      ]);
    }
    return b[off++];
  }

  int u16be() {
    if (off + 2 > b.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Read beyond buffer. Offset: $off, Buffer length: ${b.length}.',
        )
      ]);
    }
    final v = ByteData.sublistView(b, off, off + 2).getUint16(0, Endian.big);
    off += 2;
    return v;
  }

  int u32be() {
    if (off + 4 > b.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Read beyond buffer. Offset: $off, Buffer length: ${b.length}.',
        )
      ]);
    }
    final v = ByteData.sublistView(b, off, off + 4).getUint32(0, Endian.big);
    off += 4;
    return v;
  }

  int i32be() {
    if (off + 4 > b.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Read beyond buffer. Offset: $off, Buffer length: ${b.length}.',
        )
      ]);
    }
    final v = ByteData.sublistView(b, off, off + 4).getInt32(0, Endian.big);
    off += 4;
    return v;
  }

  int i64be() {
    if (off + 8 > b.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Read beyond buffer. Offset: $off, Buffer length: ${b.length}.',
        )
      ]);
    }
    final v = PlatformByteData.getInt64(
        ByteData.sublistView(b, off, off + 8), 0, Endian.big);
    off += 8;
    return v;
  }

  double f64be() {
    if (off + 8 > b.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Read beyond buffer. Offset: $off, Buffer length: ${b.length}.',
        )
      ]);
    }
    final v = ByteData.sublistView(b, off, off + 8).getFloat64(0, Endian.big);
    off += 8;
    return v;
  }

  Uint8List bytes(int len) {
    if (len <= 0) return Uint8List(0);
    if (off + len > b.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Read beyond buffer. Offset: $off, Buffer length: ${b.length}.',
        )
      ]);
    }
    final out = b.sublist(off, off + len);
    off += len;
    return out;
  }
}
