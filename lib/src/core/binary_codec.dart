import 'dart:convert';
import 'dart:typed_data';

import '../handler/platform_byte_data.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';

/// A fast Binary Writer with auto-growing buffer and Zero-Allocation optimizations.
class BinaryWriter {
  Uint8List _buf;
  ByteData _bd;
  int _len = 0;

  /// Reusable sub-writers pool to eliminate allocation during nested message serialization.
  static final List<BinaryWriter> _pool = [];

  BinaryWriter({int initialCapacity = 256})
      : _buf = Uint8List(initialCapacity),
        _bd = ByteData(initialCapacity) {
    _bd = ByteData.sublistView(_buf);
  }

  /// Get a subview of the currently written bytes. No copying is performed.
  Uint8List get view => Uint8List.sublistView(_buf, 0, _len);

  /// Current written length.
  int get length => _len;

  /// Reset the writer state for reuse.
  void reset() {
    _len = 0;
  }

  void _ensureCapacity(int needed) {
    if (_len + needed > _buf.length) {
      int newCap = _buf.isEmpty ? 256 : _buf.length * 2;
      while (_len + needed > newCap) {
        newCap *= 2;
      }
      final newBuf = Uint8List(newCap);
      newBuf.setRange(0, _len, _buf);
      _buf = newBuf;
      _bd = ByteData.sublistView(_buf);
    }
  }

  /// Writes the Tag consisting of FieldID and WireType.
  void writeFieldTag(int fieldId, int wireType) {
    writeVarint((fieldId << 3) | wireType);
  }

  /// Writes an unsigned Varint (up to 64-bit).
  void writeVarint(int value) {
    _ensureCapacity(10);
    // Treat negative values or large integers properly
    int val = value & 0xFFFFFFFFFFFFFFFF;
    while (true) {
      if ((val & ~0x7F) == 0) {
        _buf[_len++] = val;
        break;
      } else {
        _buf[_len++] = (val & 0x7F) | 0x80;
        val >>>= 7;
      }
    }
  }

  /// Writes a signed 32-bit integer using ZigZag encoding.
  void writeZigZag32(int value) {
    final zz = (value << 1) ^ (value >> 31);
    writeVarint(zz & 0xFFFFFFFF);
  }

  /// Writes a signed 64-bit integer using ZigZag encoding.
  void writeZigZag64(int value) {
    final zz = (value << 1) ^ (value >> 63);
    writeVarint(zz);
  }

  /// Writes a fixed 64-bit unsigned/signed integer.
  void writeFixed64(int value) {
    _ensureCapacity(8);
    PlatformByteData.setInt64(_bd, _len, value, Endian.little);
    _len += 8;
  }

  /// Writes a fixed 32-bit unsigned/signed integer.
  void writeFixed32(int value) {
    _ensureCapacity(4);
    _bd.setUint32(_len, value, Endian.little);
    _len += 4;
  }

  /// Writes a double precision float (8 bytes).
  void writeDouble(double value) {
    _ensureCapacity(8);
    _bd.setFloat64(_len, value, Endian.little);
    _len += 8;
  }

  /// Writes a single precision float (4 bytes).
  void writeFloat(double value) {
    _ensureCapacity(4);
    _bd.setFloat32(_len, value, Endian.little);
    _len += 4;
  }

  /// Writes a raw sequence of bytes preceded by its length.
  void writeBytes(Uint8List bytes) {
    writeVarint(bytes.length);
    _ensureCapacity(bytes.length);
    _buf.setRange(_len, _len + bytes.length, bytes);
    _len += bytes.length;
  }

  /// Writes a UTF-8 string preceded by its length.
  void writeString(String value) {
    final bytes = utf8.encode(value);
    writeBytes(bytes);
  }

  /// Writes a boolean value as a Varint (1 or 0).
  void writeBool(bool value) {
    writeVarint(value ? 1 : 0);
  }

  /// High-performance nested message writer utilizing static pool.
  void writeMessage(int fieldId, void Function(BinaryWriter writer) writeFn) {
    final subWriter = _acquire();
    try {
      writeFn(subWriter);
      writeFieldTag(fieldId, WireType.lengthDelimited);
      writeBytes(subWriter.view);
    } finally {
      _release(subWriter);
    }
  }

  static BinaryWriter _acquire() {
    if (_pool.isEmpty) {
      return BinaryWriter(initialCapacity: 256);
    }
    return _pool.removeLast();
  }

  static void _release(BinaryWriter writer) {
    writer.reset();
    // Buffer Blowup Prevention: if buffer size exceeds 64KB, discard it from pool
    if (writer._buf.length > 65536) {
      return;
    }
    if (_pool.length < 16) {
      _pool.add(writer);
    }
  }
}

/// A fast Binary Reader with Zero-Copy subview features.
class BinaryReader {
  final Uint8List _buf;
  final ByteData _bd;
  int _pos = 0;

  /// Maximum single payload limit (e.g. 64MB) to prevent Denial of Service (DoS) memory blowup.
  static const int maxPayloadLimit = 67108864;

  /// Limit stack to enforce boundary limit checks during nested message reads.
  final List<int> _limits = [];

  BinaryReader(Uint8List buffer)
      : _buf = buffer,
        _bd = ByteData.sublistView(buffer);

  /// Current cursor position.
  int get position => _pos;

  /// Check if Reader has reached EOF.
  bool get isEOF => _pos >= _buf.length;

  /// Safely positions the reading cursor, checking boundary limits.
  void positionTo(int newPos) {
    if (newPos < _pos) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TOBF: Seeking backwards is not supported',
        )
      ]);
    }
    _checkLimit(newPos - _pos);
    _pos = newPos;
  }

  /// Internal bounds helper ensuring the requested byte read size doesn't cross limits or EOF.
  void _checkLimit(int bytesNeeded) {
    if (_limits.isNotEmpty && _pos + bytesNeeded > _limits.last) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TOBF: Reading exceeded nested message limit',
        )
      ]);
    }
    if (_pos + bytesNeeded > _buf.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TOBF: Unexpected EOF',
        )
      ]);
    }
  }

  /// Reads and unpacks the Field Tag into FieldID and WireType.
  /// Uses Dart 3.0 Record (Tuple) for zero heap allocation optimizations on the hot path.
  (int fieldId, int wireType) readFieldTag() {
    final tag = readVarint();
    return (tag >> 3, tag & 0x07);
  }

  /// Reads a Varint with strict 64-bit bounds and overflow prevention.
  int readVarint() {
    int result = 0;
    int shift = 0;
    while (shift < 64) {
      _checkLimit(1);
      final b = _buf[_pos++];

      // Strict 64-bit check on the 10th byte (shift == 63)
      if (shift == 63) {
        if ((b & ~1) != 0) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message: 'TOBF: Varint 64-bit overflow detected on 10th byte',
            )
          ]);
        }
      }

      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) {
        return result;
      }
      shift += 7;
    }
    throw DbException([
      GeneralStatus(
        type: ResultType.engError,
        message: 'TOBF: Varint overflow (> 10 bytes)',
      )
    ]);
  }

  /// Reads a signed 32-bit ZigZag integer with precise truncation.
  int readZigZag32() {
    final raw = readVarint();
    final val = (raw >>> 1) ^ -(raw & 1);
    return val.toSigned(32);
  }

  /// Reads a signed 64-bit ZigZag integer with precise truncation.
  int readZigZag64() {
    final raw = readVarint();
    final val = (raw >>> 1) ^ -(raw & 1);
    return val.toSigned(64);
  }

  /// Reads a fixed 64-bit integer.
  int readFixed64() {
    _checkLimit(8);
    final val = PlatformByteData.getInt64(_bd, _pos, Endian.little);
    _pos += 8;
    return val;
  }

  /// Reads a fixed 32-bit integer.
  int readFixed32() {
    _checkLimit(4);
    final val = _bd.getUint32(_pos, Endian.little);
    _pos += 4;
    return val;
  }

  /// Reads a double.
  double readDouble() {
    _checkLimit(8);
    final val = _bd.getFloat64(_pos, Endian.little);
    _pos += 8;
    return val;
  }

  /// Reads a float.
  double readFloat() {
    _checkLimit(4);
    final val = _bd.getFloat32(_pos, Endian.little);
    _pos += 4;
    return val;
  }

  /// Reads bytes in Zero-Copy fashion using sublist views. Protections against DoS added.
  Uint8List readBytes({int? maxLimit}) {
    final len = readVarint();
    final allowedLimit = maxLimit ?? maxPayloadLimit;
    if (len < 0 || len > allowedLimit) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'TOBF: readBytes length $len exceeds DoS limit $allowedLimit or is negative',
        )
      ]);
    }
    _checkLimit(len);
    final view = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return view;
  }

  /// Reads raw bytes without Varint prefix, featuring DoS protection.
  Uint8List readRawBytes(int len, {int? maxLimit}) {
    final allowedLimit = maxLimit ?? maxPayloadLimit;
    if (len < 0 || len > allowedLimit) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'TOBF: readRawBytes length $len exceeds DoS limit $allowedLimit or is negative',
        )
      ]);
    }
    _checkLimit(len);
    final view = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return view;
  }

  /// Reads a UTF-8 string.
  String readString() {
    final bytes = readBytes();
    return utf8.decode(bytes);
  }

  /// Reads a boolean value.
  bool readBool() {
    return readVarint() != 0;
  }

  /// Skips the field according to its [wireType] to support forward compatibility.
  void skipField(int wireType) {
    switch (wireType) {
      case WireType.varint:
        readVarint();
        break;
      case WireType.fixed64:
        _checkLimit(8);
        _pos += 8;
        break;
      case WireType.lengthDelimited:
        final len = readVarint();
        if (len < 0 || len > maxPayloadLimit) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'TOBF: skipField length $len exceeds DoS limit $maxPayloadLimit or is negative',
            )
          ]);
        }
        _checkLimit(len);
        _pos += len;
        break;
      case WireType.fixed32:
        _checkLimit(4);
        _pos += 4;
        break;
      default:
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'TOBF: Unknown WireType $wireType encountered during skip',
          )
        ]);
    }
  }

  /// High-performance nested message reader with limit boundary enforcement.
  void readMessage(void Function(BinaryReader reader, int limit) readFn) {
    final len = readVarint();
    if (len < 0 || len > maxPayloadLimit) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'TOBF: Nested message length $len exceeds DoS limit $maxPayloadLimit or is negative',
        )
      ]);
    }
    final limit = _pos + len;

    // Nesting security boundary validations
    if (_limits.isNotEmpty && limit > _limits.last) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TOBF: Child message limit exceeds parent limit',
        )
      ]);
    }
    if (limit > _buf.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TOBF: Child message limit exceeds EOF',
        )
      ]);
    }

    _limits.add(limit);
    try {
      readFn(this, limit);
    } finally {
      _limits.removeLast();
      // Safe boundary alignment even under exceptions, preserving forward-compatibility skipping
      _pos = limit;
    }
  }
}

/// Representation of the 22-byte TOBF Frame Header.
/// Unified using Little-Endian byte-ordering for performance and platform parity.
class TOBFHeader {
  static const int length = 22;

  final int version;
  final int headerLen;
  final int flags;
  final int bodyLen;
  final int checksum;

  const TOBFHeader({
    required this.version,
    required this.headerLen,
    required this.flags,
    required this.bodyLen,
    required this.checksum,
  });

  /// Encodes parameters into a 22-byte header.
  static Uint8List encode({
    int version = 1,
    int flags = 0,
    required int bodyLen,
    required int checksum,
  }) {
    final bytes = Uint8List(length);
    final bd = ByteData.sublistView(bytes);

    // Magic: "TOBF"
    bytes[0] = 0x54; // T
    bytes[1] = 0x4F; // O
    bytes[2] = 0x42; // B
    bytes[3] = 0x46; // F

    bd.setUint16(4, version, Endian.little);
    bd.setUint16(6, length, Endian.little);
    bd.setUint16(8, flags, Endian.little);
    bd.setUint32(10, bodyLen, Endian.little);
    PlatformByteData.setUint64(bd, 14, checksum, Endian.little);

    return bytes;
  }

  /// Decodes and validates a 22-byte header.
  static TOBFHeader decode(Uint8List bytes) {
    if (bytes.length < length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TOBFHeader: Buffer too short (${bytes.length})',
        )
      ]);
    }

    // Magic validation
    if (bytes[0] != 0x54 ||
        bytes[1] != 0x4F ||
        bytes[2] != 0x42 ||
        bytes[3] != 0x46) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TOBFHeader: Magic header verification failed',
        )
      ]);
    }

    final bd = ByteData.sublistView(bytes);
    final version = bd.getUint16(4, Endian.little);
    final headerLen = bd.getUint16(6, Endian.little);
    final flags = bd.getUint16(8, Endian.little);
    final bodyLen = bd.getUint32(10, Endian.little);
    final checksum = PlatformByteData.getUint64(bd, 14, Endian.little);

    if (headerLen < length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'TOBFHeader: Invalid headerLen $headerLen (must be >= $length)',
        )
      ]);
    }

    return TOBFHeader(
      version: version,
      headerLen: headerLen,
      flags: flags,
      bodyLen: bodyLen,
      checksum: checksum,
    );
  }

  /// High-performance helper that encodes a body payload and returns a full TOBF frame (Header + Body).
  static Uint8List encodeFrame(Uint8List body,
      {int version = 1, int flags = 0}) {
    final checksum = XXHash64.hash(body);
    final header = encode(
        version: version,
        flags: flags,
        bodyLen: body.length,
        checksum: checksum);
    final frame = Uint8List(length + body.length);
    frame.setRange(0, length, header);
    frame.setRange(length, frame.length, body);
    return frame;
  }

  /// High-performance helper that decodes a full TOBF frame (Header + Body).
  /// Safely resolves future header extensions using headerLen forward seek,
  /// and performs checksum validation with DoS protection.
  static Uint8List decodeFrame(Uint8List frameBytes, {int? maxBodyLimit}) {
    if (frameBytes.length < length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TOBFFrame: Frame bytes too short',
        )
      ]);
    }

    // Decode Header (min 22 bytes)
    final headerBytes = Uint8List.sublistView(frameBytes, 0, length);
    final header = decode(headerBytes);

    if (frameBytes.length < header.headerLen + header.bodyLen) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'TOBFFrame: Incomplete frame (expected ${header.headerLen + header.bodyLen} bytes)',
        )
      ]);
    }

    final reader = BinaryReader(frameBytes);

    // Jump over any potential future header extension fields (headerLen)
    reader.positionTo(header.headerLen);

    // Read body payload (Zero-Copy subview)
    final body = reader.readRawBytes(header.bodyLen, maxLimit: maxBodyLimit);

    // Verify xxHash64 checksum
    final computedHash = XXHash64.hash(body);
    if (computedHash != header.checksum) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TOBFFrame: Checksum validation failed',
        )
      ]);
    }

    return body;
  }
}

/// Wire types for the ToStore Binary Format (TOBF).
/// Must remain stable for dozens of years to ensure backward/forward compatibility.
class WireType {
  /// Varint encoding: int32, int64, uint32, uint64, sint32, sint64, bool, enum.
  static const int varint = 0;

  /// 64-bit fixed size: double, fixed64, sfixed64.
  static const int fixed64 = 1;

  /// Length-delimited: String, Uint8List, nested Messages, packed repeated fields.
  static const int lengthDelimited = 2;

  /// 32-bit fixed size: float, fixed32, sfixed32.
  static const int fixed32 = 5;
}

/// A highly-optimized 64-bit non-cryptographic hash algorithm (xxHash64)
/// implemented in pure Dart for VM environments, compatible with Web platforms.
class XXHash64 {
  static const int _prime1 = -7046029254386353025; // 0x9E3779B185EBCA87
  static const int _prime2 = -8796128691651817923; // 0x85EBCA77C2B2AE3D
  static const int _prime3 = -4417253597405721777; // 0xC2B2AE3D27D4EB4F
  static const int _prime4 = 2870177450012600261; // 0x27D4EB2F165667C5
  static const int _prime5 = 1609587929392839123; // 0x165667C57D37B0D3

  static int _rotl64(int val, int shift) {
    val &= 0xFFFFFFFFFFFFFFFF;
    return ((val << shift) | (val >>> (64 - shift))) & 0xFFFFFFFFFFFFFFFF;
  }

  static int _round(int acc, int input) {
    acc = (acc + (input * _prime2)) & 0xFFFFFFFFFFFFFFFF;
    acc = _rotl64(acc, 31);
    acc = (acc * _prime1) & 0xFFFFFFFFFFFFFFFF;
    return acc;
  }

  static int _mergeRound(int acc, int val) {
    val = _round(0, val);
    acc ^= val;
    acc = (acc * _prime1) & 0xFFFFFFFFFFFFFFFF;
    acc = (acc + _prime4) & 0xFFFFFFFFFFFFFFFF;
    return acc;
  }

  /// Calculates the 64-bit xxHash of the given [data].
  static int hash(Uint8List data, [int seed = 0]) {
    final int len = data.length;
    int h64 = 0;
    int pos = 0;

    if (len >= 32) {
      int v1 = (seed + _prime1 + _prime2) & 0xFFFFFFFFFFFFFFFF;
      int v2 = (seed + _prime2) & 0xFFFFFFFFFFFFFFFF;
      int v3 = (seed + 0) & 0xFFFFFFFFFFFFFFFF;
      int v4 = (seed - _prime1) & 0xFFFFFFFFFFFFFFFF;

      final bd = ByteData.sublistView(data);
      final int limit = len - 32;
      while (pos <= limit) {
        final int p1 = PlatformByteData.getUint64(bd, pos, Endian.little);
        v1 = _round(v1, p1);
        pos += 8;

        final int p2 = PlatformByteData.getUint64(bd, pos, Endian.little);
        v2 = _round(v2, p2);
        pos += 8;

        final int p3 = PlatformByteData.getUint64(bd, pos, Endian.little);
        v3 = _round(v3, p3);
        pos += 8;

        final int p4 = PlatformByteData.getUint64(bd, pos, Endian.little);
        v4 = _round(v4, p4);
        pos += 8;
      }

      h64 = (_rotl64(v1, 1) +
              _rotl64(v2, 7) +
              _rotl64(v3, 12) +
              _rotl64(v4, 18)) &
          0xFFFFFFFFFFFFFFFF;
      h64 = _mergeRound(h64, v1);
      h64 = _mergeRound(h64, v2);
      h64 = _mergeRound(h64, v3);
      h64 = _mergeRound(h64, v4);
    } else {
      h64 = (seed + _prime5) & 0xFFFFFFFFFFFFFFFF;
    }

    h64 = (h64 + len) & 0xFFFFFFFFFFFFFFFF;

    // Remaining 8-byte blocks
    final bd = ByteData.sublistView(data);
    while (pos + 8 <= len) {
      final int p = PlatformByteData.getUint64(bd, pos, Endian.little);
      final int val = _round(0, p);
      h64 ^= val;
      h64 = (_rotl64(h64, 27) * _prime1) & 0xFFFFFFFFFFFFFFFF;
      h64 = (h64 + _prime4) & 0xFFFFFFFFFFFFFFFF;
      pos += 8;
    }

    // Remaining 4-byte blocks
    if (pos + 4 <= len) {
      final int p = bd.getUint32(pos, Endian.little);
      h64 ^= (p * _prime1) & 0xFFFFFFFFFFFFFFFF;
      h64 = (_rotl64(h64, 23) * _prime2) & 0xFFFFFFFFFFFFFFFF;
      h64 = (h64 + _prime3) & 0xFFFFFFFFFFFFFFFF;
      pos += 4;
    }

    // Remaining 1-byte blocks
    while (pos < len) {
      final int b = data[pos];
      h64 ^= (b * _prime5) & 0xFFFFFFFFFFFFFFFF;
      h64 = (_rotl64(h64, 11) * _prime1) & 0xFFFFFFFFFFFFFFFF;
      pos++;
    }

    // Avalanche
    h64 ^= h64 >>> 33;
    h64 = (h64 * _prime2) & 0xFFFFFFFFFFFFFFFF;
    h64 ^= h64 >>> 29;
    h64 = (h64 * _prime3) & 0xFFFFFFFFFFFFFFFF;
    h64 ^= h64 >>> 32;

    return h64 & 0xFFFFFFFFFFFFFFFF;
  }
}
