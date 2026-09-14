import 'dart:convert';
import 'dart:typed_data';

import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_schema.dart' show VectorData;
import 'platform_byte_data.dart';

/// A compact high-performance binary codec for `Map<String, dynamic>`.
///
/// This is a MessagePack-compatible format with custom extensions:
/// - BigInt is encoded as MessagePack ext (type=1) with decimal string payload.
/// - VectorData is encoded as MessagePack ext (type=2) with Float64 binary payload.
///
/// On-disk contract is the released [WalEncoder] / table-file format:
/// encode and decode `map32`, `array32`, `str32`, `bin32`, `fixint`, `fixstr`,
/// `int32`/`int64`, `float64`, `bool`, `nil`, `ext8`/`ext16`/`ext32`.
/// [FastWalEncoder] is a faster writer of this same format, not a new one.
///
/// Design guarantees:
/// - Hot paths (int, String, null, bool, double) are evaluated first.
/// - Zero silent truncation: oversized data triggers a descriptive [DbException].
/// - Full Unicode/Emoji fidelity across all global language scripts.
/// - Allocation-free [ByteData] operations on decoding.
class BinaryMapCodec {
  // Maximum sizes to prevent DoS attacks via excessively large payloads
  static const int maxArraySize = 1000000; // 1M elements
  static const int maxMapSize = 1000000; // 1M entries
  static const int maxStringLength = 100 * 1024 * 1024; // 100MB per string
  static const int maxBinaryLength = 256 * 1024 * 1024; // 256MB per binary blob

  // MessagePack ext types
  static const int _extTypeBigInt = 1;
  static const int _extTypeVector = 2;

  /// String header matching released [WalEncoder] / [BinaryMapCodec]:
  /// fixstr if UTF-8 length &lt; 32, otherwise str32.
  static int onDiskStringHeaderSize(int utf8Length) => utf8Length < 32 ? 1 : 5;

  static void writeOnDiskStringHeader(BytesBuilder b, int utf8Length) {
    if (utf8Length < 32) {
      b.addByte(0xA0 | utf8Length);
      return;
    }
    b.addByte(0xDB);
    _writeU32be(b, utf8Length);
  }

  /// Writes the released string header at [offset]. Returns 1 or 5.
  static int writeOnDiskStringHeaderAt(
    Uint8List dest,
    int offset,
    int utf8Length,
  ) {
    if (utf8Length < 32) {
      dest[offset] = 0xA0 | utf8Length;
      return 1;
    }
    dest[offset] = 0xDB;
    dest[offset + 1] = (utf8Length >> 24) & 0xFF;
    dest[offset + 2] = (utf8Length >> 16) & 0xFF;
    dest[offset + 3] = (utf8Length >> 8) & 0xFF;
    dest[offset + 4] = utf8Length & 0xFF;
    return 5;
  }

  // Pre-allocated scratch buffer for 64-bit numbers (per isolate)
  static final Uint8List _scratch8 = Uint8List(8);
  static final ByteData _scratch8Bd = ByteData.sublistView(_scratch8);

  static Uint8List encodeMap(Map<String, dynamic> map) {
    final int count = map.length;
    if (count > maxMapSize) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Map size $count exceeds maximum limit of $maxMapSize.',
        )
      ]);
    }

    final buffer = BytesBuilder(copy: false);
    buffer.addByte(0xDF); // map32
    _writeU32be(buffer, count);

    for (final e in map.entries) {
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

  /// MessagePack value serializer writing directly to [BytesBuilder].
  ///
  /// Hot path optimized: evaluates the most frequent database column types first
  /// (int -> String -> null -> bool -> double -> Uint8List -> List -> Map -> extensions).
  static void _writeValue(BytesBuilder b, dynamic value) {
    // 1. int (dominant in IDs, foreign keys, flags, timestamps)
    if (value is int) {
      if (value >= 0 && value < 128) {
        b.addByte(value); // positive fixint
        return;
      }
      if (value >= -32 && value < 0) {
        b.addByte(0xE0 | (value & 0x1F)); // negative fixint
        return;
      }
      if (value >= -0x80000000 && value <= 0x7FFFFFFF) {
        b.addByte(0xD2); // int32
        _writeI32be(b, value);
        return;
      }
      b.addByte(0xD3); // int64
      _writeI64be(b, value);
      return;
    }

    // 2. String (dominant in text, UUIDs, identifiers, status, JSON payload)
    if (value is String) {
      _writeString(b, value);
      return;
    }

    // 3. null (frequent in nullable fields)
    if (value == null) {
      b.addByte(0xC0);
      return;
    }

    // 4. bool
    if (value is bool) {
      b.addByte(value ? 0xC3 : 0xC2);
      return;
    }

    // 5. double (numeric metrics, currencies, coordinates)
    if (value is double) {
      b.addByte(0xCB);
      _writeF64be(b, value);
      return;
    }

    // 6. Uint8List (binary blobs, encrypted payloads)
    if (value is Uint8List) {
      _writeBinary(b, value);
      return;
    }

    // 7. List
    if (value is List) {
      final int length = value.length;
      if (length > maxArraySize) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Binary map codec: Array size $length exceeds maximum limit of $maxArraySize.',
          )
        ]);
      }
      b.addByte(0xDD); // array32
      _writeU32be(b, length);
      for (int i = 0; i < length; i++) {
        _writeValue(b, value[i]);
      }
      return;
    }

    // 8. Map
    if (value is Map) {
      final int count = value.length;
      if (count > maxMapSize) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Binary map codec: Map size $count exceeds maximum limit of $maxMapSize.',
          )
        ]);
      }
      b.addByte(0xDF); // map32
      _writeU32be(b, count);
      for (final e in value.entries) {
        _writeString(b, e.key.toString());
        _writeValue(b, e.value);
      }
      return;
    }

    // 9. Infrequent extensions: BigInt & VectorData
    if (value is BigInt) {
      _writeBigIntExt(b, value);
      return;
    }

    if (value is VectorData) {
      _writeVectorExt(b, value);
      return;
    }

    if (value is DateTime) {
      _writeString(b, value.toIso8601String());
      return;
    }

    // Unsupported fallback: encode as null
    b.addByte(0xC0);
  }

  /// Encodes a string into standard MessagePack bytes.
  ///
  /// Supports ASCII fast-path without intermediate utf8 allocation, and encodes
  /// full multi-byte Unicode (Emoji, CJK, Cyrillic, Arabic, Latin-extended, etc.)
  /// using standard MessagePack format tokens without silent truncation.
  static void _writeString(BytesBuilder b, String s) {
    final int len = s.length;
    if (len == 0) {
      b.addByte(0xA0); // fixstr of length 0
      return;
    }
    if (len > maxStringLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: String length $len exceeds maximum limit of $maxStringLength.',
        )
      ]);
    }

    // Fast-path for short pure-ASCII strings (common for table names, field names, enum values)
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

    // Full UTF-8 encode for multi-byte Unicode and strings >= 32 chars
    final bytes = utf8.encode(s);
    final int encLen = bytes.length;
    if (encLen > maxStringLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: String length $encLen exceeds maximum limit of $maxStringLength.',
        )
      ]);
    }

    writeOnDiskStringHeader(b, encLen);
    b.add(bytes);
  }

  static void _writeBinary(BytesBuilder b, Uint8List bytes) {
    final int len = bytes.length;
    if (len > maxBinaryLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary map codec: Binary length $len exceeds maximum limit of $maxBinaryLength.',
        )
      ]);
    }
    b.addByte(0xC6); // bin32
    _writeU32be(b, len);
    b.add(bytes);
  }

  static void _writeBigIntExt(BytesBuilder b, BigInt v) {
    final payload = utf8.encode(v.toString());
    final int len = payload.length;
    b.addByte(0xC9); // ext 32
    _writeU32be(b, len);
    b.addByte(_extTypeBigInt);
    b.add(payload);
  }

  static void _writeVectorExt(BytesBuilder b, VectorData v) {
    final payload = v.toBytes();
    final int len = payload.length;
    b.addByte(0xC9); // ext 32
    _writeU32be(b, len);
    b.addByte(_extTypeVector);
    b.add(payload);
  }

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
    _addScratch8(b);
  }

  static void _writeF64be(BytesBuilder b, double v) {
    _scratch8Bd.setFloat64(0, v, Endian.big);
    _addScratch8(b);
  }

  /// Copy scratch bytes into the builder. [BytesBuilder] is constructed with
  /// `copy: false`, so adding [_scratch8] by reference would alias every
  /// subsequent int64/float64 write onto the same 8-byte buffer.
  static void _addScratch8(BytesBuilder b) {
    b.addByte(_scratch8[0]);
    b.addByte(_scratch8[1]);
    b.addByte(_scratch8[2]);
    b.addByte(_scratch8[3]);
    b.addByte(_scratch8[4]);
    b.addByte(_scratch8[5]);
    b.addByte(_scratch8[6]);
    b.addByte(_scratch8[7]);
  }

  /// Decode MessagePack value with branch optimization for dominant data types.
  static dynamic _readValue(_Reader r) {
    final byte = r.u8();

    // 1. positive fixint (0x00 ~ 0x7F) - extremely hot
    if (byte < 0x80) return byte;

    // 2. fixstr (0xA0 ~ 0xBF) - extremely hot
    if (byte >= 0xA0 && byte < 0xC0) {
      return _readString(r, byte & 0x1F);
    }

    // 3. negative fixint (0xE0 ~ 0xFF)
    if (byte >= 0xE0) return (byte & 0x1F) - 32;

    switch (byte) {
      case 0xC0: // nil
        return null;
      case 0xC2: // false
        return false;
      case 0xC3: // true
        return true;
      case 0xCB: // float 64
        return r.f64be();
      case 0xD2: // int 32
        return r.i32be();
      case 0xD3: // int 64
        return r.i64be();
      case 0xDB: // str 32
        return _readString(r, r.u32be());
      case 0xC6: // bin 32
        return _readBinary(r, r.u32be());
      case 0xDD: // array 32
        return _readArray(r, r.u32be());
      case 0xDF: // map 32
        return _readMap(r, r.u32be());
      case 0xC7: // ext 8
        return _readExt(r, r.u8());
      case 0xC8: // ext 16
        return _readExt(r, r.u16be());
      case 0xC9: // ext 32
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
    final view = r.bytesView(len);
    return _decodeUtf8(view);
  }

  /// ASCII strings (short keys, IDs, enums <= 64 bytes) skip the UTF-8 state machine.
  /// Longer texts directly delegate to utf8.decode to leverage VM-native SIMD acceleration
  /// and avoid Dart-level double-scan overhead.
  static String _decodeUtf8(Uint8List view) {
    final int n = view.length;
    if (n <= 64) {
      for (int i = 0; i < n; i++) {
        if (view[i] > 0x7F) {
          return utf8.decode(view, allowMalformed: true);
        }
      }
      return String.fromCharCodes(view);
    }
    return utf8.decode(view, allowMalformed: true);
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
    return r.bytesCopy(len);
  }

  static List<dynamic> _readArray(_Reader r, int count) {
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

  static Map<String, dynamic> _readMap(_Reader r, int count) {
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
    final payload = r.bytesCopy(len);
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

/// Zero-allocation Reader for MessagePack decoding.
final class _Reader {
  final Uint8List b;
  late final ByteData _bd;
  int off = 0;

  _Reader(this.b) {
    _bd = ByteData.sublistView(b);
  }

  @pragma('vm:prefer-inline')
  int u8() {
    if (off >= b.length) _throwBufferOverflow();
    return b[off++];
  }

  @pragma('vm:prefer-inline')
  int u16be() {
    if (off + 2 > b.length) _throwBufferOverflow();
    final v = (b[off] << 8) | b[off + 1];
    off += 2;
    return v;
  }

  @pragma('vm:prefer-inline')
  int u32be() {
    if (off + 4 > b.length) _throwBufferOverflow();
    // dart2js bitwise << is signed 32-bit; getUint32 stays in 0..2^32-1.
    final v = _bd.getUint32(off, Endian.big);
    off += 4;
    return v;
  }

  @pragma('vm:prefer-inline')
  int i32be() {
    if (off + 4 > b.length) _throwBufferOverflow();
    final v = _bd.getInt32(off, Endian.big);
    off += 4;
    return v;
  }

  @pragma('vm:prefer-inline')
  int i64be() {
    if (off + 8 > b.length) _throwBufferOverflow();
    final v = PlatformByteData.getInt64(_bd, off, Endian.big);
    off += 8;
    return v;
  }

  @pragma('vm:prefer-inline')
  double f64be() {
    if (off + 8 > b.length) _throwBufferOverflow();
    final v = _bd.getFloat64(off, Endian.big);
    off += 8;
    return v;
  }

  /// Zero-copy read-only view of slice.
  @pragma('vm:prefer-inline')
  Uint8List bytesView(int len) {
    if (len <= 0) return Uint8List(0);
    if (off + len > b.length) _throwBufferOverflow();
    final out = Uint8List.sublistView(b, off, off + len);
    off += len;
    return out;
  }

  /// Owned copy of slice when callers retain or mutate the bytes.
  Uint8List bytesCopy(int len) {
    if (len <= 0) return Uint8List(0);
    if (off + len > b.length) _throwBufferOverflow();
    final out = b.sublist(off, off + len);
    off += len;
    return out;
  }

  Never _throwBufferOverflow() {
    throw DbException([
      GeneralStatus(
        type: ResultType.engError,
        message:
            'Binary map codec: Read beyond buffer. Offset: $off, Buffer length: ${b.length}.',
      )
    ]);
  }
}
