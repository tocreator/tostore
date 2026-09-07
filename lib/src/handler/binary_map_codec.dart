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

  // Pre-allocated immutable singletons for 1-byte MessagePack tokens
  static final List<Uint8List> _posFixInt =
      List.generate(128, (i) => Uint8List.fromList([i]), growable: false);
  static final List<Uint8List> _negFixInt = List.generate(
      32, (i) => Uint8List.fromList([0xE0 | (i & 0x1F)]),
      growable: false);
  static final Uint8List _tokenNull = Uint8List.fromList([0xC0]);
  static final Uint8List _tokenTrue = Uint8List.fromList([0xC3]);
  static final Uint8List _tokenFalse = Uint8List.fromList([0xC2]);
  static final Uint8List _tokenEmptyStr = Uint8List.fromList([0xA0]);

  static Uint8List encodeMap(Map<String, dynamic> map) {
    final buffer = BytesBuilder(copy: false);
    final int count = map.length > maxMapSize ? maxMapSize : map.length;

    // map32
    final hdr = Uint8List(5);
    hdr[0] = 0xDF;
    hdr[1] = (count >> 24) & 0xFF;
    hdr[2] = (count >> 16) & 0xFF;
    hdr[3] = (count >> 8) & 0xFF;
    hdr[4] = count & 0xFF;
    buffer.add(hdr);

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
      b.add(_tokenNull);
      return;
    }

    if (value is bool) {
      b.add(value ? _tokenTrue : _tokenFalse);
      return;
    }

    if (value is int) {
      // Prefer smallest forms, but keep implementation simple.
      if (value >= 0 && value < 128) {
        b.add(_posFixInt[value]);
        return;
      }
      if (value >= -32 && value < 0) {
        b.add(_negFixInt[value + 32]);
        return;
      }
      // int32
      if (value >= -0x80000000 && value <= 0x7FFFFFFF) {
        final out = Uint8List(5);
        out[0] = 0xD2;
        out[1] = (value >> 24) & 0xFF;
        out[2] = (value >> 16) & 0xFF;
        out[3] = (value >> 8) & 0xFF;
        out[4] = value & 0xFF;
        b.add(out);
        return;
      }
      // int64 (MessagePack)
      // value is int, and didn't fit in smaller types, so use int64.
      final out = Uint8List(9);
      out[0] = 0xD3;
      final bd = ByteData.sublistView(out, 1, 9);
      PlatformByteData.setInt64(bd, 0, value, Endian.big);
      b.add(out);
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
      final out = Uint8List(9);
      out[0] = 0xCB;
      final bd = ByteData.sublistView(out, 1, 9);
      bd.setFloat64(0, value, Endian.big);
      b.add(out);
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
      final int length =
          value.length > maxArraySize ? maxArraySize : value.length;
      final hdr = Uint8List(5);
      hdr[0] = 0xDD; // array32
      hdr[1] = (length >> 24) & 0xFF;
      hdr[2] = (length >> 16) & 0xFF;
      hdr[3] = (length >> 8) & 0xFF;
      hdr[4] = length & 0xFF;
      b.add(hdr);
      for (int i = 0; i < length; i++) {
        _writeValue(b, value[i]);
      }
      return;
    }

    if (value is Map) {
      final int count = value.length > maxMapSize ? maxMapSize : value.length;
      final hdr = Uint8List(5);
      hdr[0] = 0xDF; // map32
      hdr[1] = (count >> 24) & 0xFF;
      hdr[2] = (count >> 16) & 0xFF;
      hdr[3] = (count >> 8) & 0xFF;
      hdr[4] = count & 0xFF;
      b.add(hdr);
      int written = 0;
      for (final e in value.entries) {
        if (++written > maxMapSize) break;
        _writeString(b, e.key.toString());
        _writeValue(b, e.value);
      }
      return;
    }

    // Unsupported
    b.add(_tokenNull);
  }

  static void _writeString(BytesBuilder b, String s) {
    if (s.isEmpty) {
      b.add(_tokenEmptyStr);
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
        final chunk = Uint8List(1 + len);
        chunk[0] = 0xA0 | len;
        for (int i = 0; i < len; i++) {
          chunk[i + 1] = s.codeUnitAt(i);
        }
        b.add(chunk);
        return;
      }
    }

    final bytes = utf8.encode(s);
    final int encLen =
        bytes.length > maxStringLength ? maxStringLength : bytes.length;
    final out = (encLen < bytes.length) ? bytes.sublist(0, encLen) : bytes;

    if (encLen < 32) {
      final chunk = Uint8List(1 + encLen);
      chunk[0] = 0xA0 | encLen; // fixstr
      chunk.setRange(1, 1 + encLen, out);
      b.add(chunk);
    } else {
      final hdr = Uint8List(5);
      hdr[0] = 0xDB; // str32
      hdr[1] = (encLen >> 24) & 0xFF;
      hdr[2] = (encLen >> 16) & 0xFF;
      hdr[3] = (encLen >> 8) & 0xFF;
      hdr[4] = encLen & 0xFF;
      b.add(hdr);
      b.add(out);
    }
  }

  static void _writeBinary(BytesBuilder b, Uint8List bytes) {
    final int len =
        bytes.length > maxBinaryLength ? maxBinaryLength : bytes.length;
    final out = (len < bytes.length) ? bytes.sublist(0, len) : bytes;
    final hdr = Uint8List(5);
    hdr[0] = 0xC6; // bin32
    hdr[1] = (len >> 24) & 0xFF;
    hdr[2] = (len >> 16) & 0xFF;
    hdr[3] = (len >> 8) & 0xFF;
    hdr[4] = len & 0xFF;
    b.add(hdr);
    b.add(out);
  }

  static void _writeBigIntExt(BytesBuilder b, BigInt v) {
    final payload = utf8.encode(v.toString());
    final int len = payload.length;
    final hdr = Uint8List(6);
    hdr[0] = 0xC9; // ext32
    hdr[1] = (len >> 24) & 0xFF;
    hdr[2] = (len >> 16) & 0xFF;
    hdr[3] = (len >> 8) & 0xFF;
    hdr[4] = len & 0xFF;
    hdr[5] = _extTypeBigInt;
    b.add(hdr);
    b.add(payload);
  }

  static void _writeVectorExt(BytesBuilder b, VectorData v) {
    final payload = v.toBytes();
    final int len = payload.length;
    final hdr = Uint8List(6);
    hdr[0] = 0xC9; // ext32
    hdr[1] = (len >> 24) & 0xFF;
    hdr[2] = (len >> 16) & 0xFF;
    hdr[3] = (len >> 8) & 0xFF;
    hdr[4] = len & 0xFF;
    hdr[5] = _extTypeVector;
    b.add(hdr);
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
