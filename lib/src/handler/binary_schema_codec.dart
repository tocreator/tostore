import 'dart:convert';
import 'dart:typed_data';

import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_schema.dart' show VectorData;
import '../model/value_ref.dart';
import 'binary_map_codec.dart';
import 'platform_byte_data.dart';

/// A compact binary codec for records using schema-based encoding.
///
/// This codec stores values in field order without field names, saving 20-40% space.
/// The field structure is stored in PartitionFooter.
///
/// Format: [fieldCount:u16][value1][value2]...[valueN]
/// Each value uses the same released MessagePack tokens as [BinaryMapCodec]
/// (map32 / array32 / str32 / bin32 + fixint/fixstr).
class BinarySchemaCodec {
  // Maximum sizes to prevent DoS attacks
  static const int maxArraySize = 1000000; // 1M elements
  static const int maxStringLength = 100 * 1024 * 1024; // 100MB per string
  static const int maxBinaryLength = 256 * 1024 * 1024; // 256MB per binary blob
  static const int maxFieldCount = 10000; // Maximum fields per record

  // MessagePack ext type for BigInt
  static const int _extTypeBigInt = 1;

  /// MessagePack ext type for field-level overflow ValueRef (v1/v2).
  static const int extTypeOverflowRef = 3;

  /// Encode a record using field structure (values only, no field names).
  ///
  /// [record] - The record map to encode
  /// [fieldStructure] - Ordered list of fields (from schema)
  static Uint8List encodeRecord(
    Map<String, dynamic> record,
    List<FieldStructure> fieldStructure, {
    String? nullifyField,
  }) {
    final buffer = BytesBuilder(copy: false);
    final fieldCount = fieldStructure.length;
    if (fieldCount > maxFieldCount) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary schema codec: Field count $fieldCount exceeds maximum limit of $maxFieldCount.',
        )
      ]);
    }
    _writeU16be(buffer, fieldCount);

    // Encode values in field order
    for (int i = 0; i < fieldCount; i++) {
      final field = fieldStructure[i];
      final value = field.deleted
          ? null
          : (nullifyField != null && field.name == nullifyField)
              ? null
              : record[field.name];
      _writeValue(buffer, value);
    }

    return buffer.toBytes();
  }

  /// Encode a single field value to MessagePack bytes (no fieldCount header).
  static Uint8List encodeFieldValue(dynamic value) {
    final buffer = BytesBuilder(copy: false);
    _writeValue(buffer, value);
    return buffer.toBytes();
  }

  /// Encode record where some slots are already [ValueRef] (field overflow).
  ///
  /// [slotOverrides] maps field name → ValueRef or raw value replacement.
  static Uint8List encodeRecordWithSlotOverrides(
    Map<String, dynamic> record,
    List<FieldStructure> fieldStructure, {
    Map<String, dynamic>? slotOverrides,
    String? nullifyField,
  }) {
    final buffer = BytesBuilder(copy: false);
    final fieldCount = fieldStructure.length;
    if (fieldCount > maxFieldCount) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary schema codec: Field count $fieldCount exceeds maximum limit of $maxFieldCount.',
        )
      ]);
    }
    _writeU16be(buffer, fieldCount);
    for (int i = 0; i < fieldCount; i++) {
      final field = fieldStructure[i];
      if (field.deleted) {
        _writeValue(buffer, null);
        continue;
      }
      if (nullifyField != null && field.name == nullifyField) {
        _writeValue(buffer, null);
        continue;
      }
      final override = slotOverrides?[field.name];
      if (override != null) {
        _writeValue(buffer, override);
      } else {
        _writeValue(buffer, record[field.name]);
      }
    }
    return buffer.toBytes();
  }

  /// Collect field-level overflow refs from a spine payload (for delete/GC).
  static List<ValueRef> collectFieldOverflowRefs(
    Uint8List data,
    List<FieldStructure> fieldStructure,
  ) {
    final out = <ValueRef>[];
    if (data.isEmpty) return out;
    try {
      final r = _Reader(data);
      final fieldCount = r.u16be();
      if (fieldCount != fieldStructure.length) return out;
      for (int i = 0; i < fieldCount; i++) {
        final raw = _readValue(r);
        if (raw is ValueRef) out.add(raw);
      }
    } catch (_) {}
    return out;
  }

  /// Decode a record using field structure.
  ///
  /// Returns null if decoding fails.
  /// When [neededFields] is non-null, only those fields are returned; field
  /// overflow refs for other slots are skipped without calling [resolveOverflow].
  /// Unresolved overflow refs (when [resolveOverflow] is null) are omitted.
  static Map<String, dynamic>? decodeRecord(
    Uint8List data,
    List<FieldStructure> fieldStructure, {
    Set<String>? neededFields,
    dynamic Function(ValueRef ref)? resolveOverflowSync,
  }) {
    if (data.isEmpty) return null;
    try {
      final r = _Reader(data);
      final fieldCount = r.u16be();
      if (fieldCount > maxFieldCount) {
        return null;
      }
      // Require exact slot-count match. A shorter payload must NOT be mapped
      // onto a longer structure prefix -- that silently shifts values into
      // deleted/leading slots (e.g. promote swap layout mismatch).
      if (fieldCount != fieldStructure.length) {
        // Caller may retry with a historic layout or active-slot-only structure.
        return null;
      }

      final result = <String, dynamic>{};
      for (int i = 0; i < fieldCount; i++) {
        final field = fieldStructure[i];
        final raw = _readValue(r);
        // Deleted slots keep positional alignment only — never expose to callers.
        if (field.deleted || raw == null) continue;
        if (neededFields != null && !neededFields.contains(field.name)) {
          continue; // skip overflow IO for unselected fields
        }
        if (raw is ValueRef) {
          if (resolveOverflowSync == null) continue;
          final resolved = resolveOverflowSync(raw);
          if (resolved == null) continue;
          result[field.name] = _coerceByTypeIndex(field.typeIndex, resolved);
          continue;
        }
        result[field.name] = _coerceByTypeIndex(field.typeIndex, raw);
      }

      return result;
    } catch (_) {
      return null;
    }
  }

  /// Async decode with field-overflow resolution and optional projection.
  ///
  /// When [neededFields] is non-null, overflow IO is skipped for fields not
  /// in the set (same contract as [decodeRecord]).
  static Future<Map<String, dynamic>?> decodeRecordAsync(
    Uint8List data,
    List<FieldStructure> fieldStructure, {
    Set<String>? neededFields,
    required Future<Uint8List?> Function(ValueRef ref) resolveOverflow,
  }) async {
    if (data.isEmpty) return null;
    try {
      final r = _Reader(data);
      final fieldCount = r.u16be();
      if (fieldCount > maxFieldCount) return null;
      if (fieldCount != fieldStructure.length) return null;

      final result = <String, dynamic>{};
      for (int i = 0; i < fieldCount; i++) {
        final field = fieldStructure[i];
        final raw = _readValue(r);
        if (field.deleted || raw == null) continue;
        if (neededFields != null && !neededFields.contains(field.name)) {
          continue; // skip overflow IO for unselected fields
        }
        if (raw is ValueRef) {
          final bytes = await resolveOverflow(raw);
          if (bytes == null) continue;
          // Field overflow stores encodeFieldValue bytes.
          final inner = _Reader(bytes);
          final value = _readValue(inner);
          result[field.name] = _coerceByTypeIndex(field.typeIndex, value);
          continue;
        }
        result[field.name] = _coerceByTypeIndex(field.typeIndex, raw);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

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
        b.addByte(0xD2);
        _writeI32be(b, value);
        return;
      }
      b.addByte(0xD3);
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

    // 7. VectorData: encode as binary (Float64List bytes) for compact storage.
    if (value is VectorData) {
      final f64 = Float64List.fromList(value.values);
      _writeBinary(b, f64.buffer.asUint8List());
      return;
    }

    // 8. List
    if (value is List) {
      final length = value.length;
      if (length > maxArraySize) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Binary schema codec: Array size $length exceeds maximum limit of $maxArraySize.',
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

    // 9. Map
    if (value is Map) {
      final int count = value.length;
      if (count > maxArraySize) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Binary schema codec: Map size $count exceeds maximum limit of $maxArraySize.',
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

    // 10. BigInt
    if (value is BigInt) {
      if (value.isValidInt) {
        _writeValue(b, value.toInt());
        return;
      }
      _writeBigIntExt(b, value);
      return;
    }

    // 11. Field-level overflow pointer
    if (value is ValueRef) {
      _writeOverflowRefExt(b, value);
      return;
    }

    if (value is DateTime) {
      _writeString(b, value.toIso8601String());
      return;
    }

    // Unsupported - encode as null
    b.addByte(0xC0);
  }

  static void _writeString(BytesBuilder b, String s) {
    final int len = s.length;
    if (len == 0) {
      b.addByte(0xA0);
      return;
    }
    if (len > maxStringLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary schema codec: String length $len exceeds maximum limit of $maxStringLength.',
        )
      ]);
    }

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
    final encLen = bytes.length;
    if (encLen > maxStringLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary schema codec: String length $encLen exceeds maximum limit of $maxStringLength.',
        )
      ]);
    }

    BinaryMapCodec.writeOnDiskStringHeader(b, encLen);
    b.add(bytes);
  }

  static void _writeBinary(BytesBuilder b, Uint8List bytes) {
    final len = bytes.length;
    if (len > maxBinaryLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary schema codec: Binary length $len exceeds maximum limit of $maxBinaryLength.',
        )
      ]);
    }
    b.addByte(0xC6); // bin32
    _writeU32be(b, len);
    b.add(bytes);
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

  static void _writeOverflowRefExt(BytesBuilder b, ValueRef ref) {
    final payload = ref.encode();
    final len = payload.length;
    if (len <= 0xff) {
      b.addByte(0xC7); // ext8
      b.addByte(len);
      b.addByte(extTypeOverflowRef);
      b.add(payload);
      return;
    }
    if (len <= 0xffff) {
      b.addByte(0xC8); // ext16
      _writeU16be(b, len);
      b.addByte(extTypeOverflowRef);
      b.add(payload);
      return;
    }
    b.addByte(0xC9); // ext32
    _writeU32be(b, len);
    b.addByte(extTypeOverflowRef);
    b.add(payload);
  }

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
                'Binary schema codec: Unsupported MessagePack type: 0x${byte.toRadixString(16)}',
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
              'Binary schema codec: String length $len exceeds maximum limit of $maxStringLength.',
        )
      ]);
    }
    final view = r.bytesView(len);
    return _decodeUtf8(view);
  }

  /// ASCII strings (short field names, enums <= 64 bytes) skip the UTF-8 state machine.
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
              'Binary schema codec: Binary length $len exceeds maximum limit of $maxBinaryLength.',
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
              'Binary schema codec: Array size $count exceeds maximum limit of $maxArraySize.',
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
    if (count > maxArraySize) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Binary schema codec: Map size $count exceeds maximum limit of $maxArraySize.',
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
                'Binary schema codec: Map key must be string, got: ${k.runtimeType}.',
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
    if (type == extTypeOverflowRef) {
      return ValueRef.tryDecode(payload) ?? payload;
    }
    // Unknown extension: return raw bytes.
    return payload;
  }

  static final BigInt _int64Min = BigInt.parse('-9223372036854775808'); // -2^63
  static final BigInt _int64Max =
      BigInt.parse('9223372036854775807'); // 2^63 - 1

  /// Coerce decoded value to match the table field type when safe.
  ///
  /// - Only handles numeric normalization between integer / bigInt.
  /// - For all other types, or when coercion is unsafe (e.g. BigInt out of 64-bit
  ///   range for integer fields), the original value is returned to avoid data loss.
  ///
  /// DataType enum indices (from model/table_schema.dart):
  ///   0: integer, 1: bigInt, 2: double, 3: text, 4: blob,
  ///   5: boolean, 6: datetime, 7: array, 8: vector, 9: json.
  static dynamic _coerceByTypeIndex(int typeIndex, dynamic value) {
    switch (typeIndex) {
      // DataType.integer
      case 0:
        if (value is BigInt) {
          // Only downcast when within signed 64-bit range to avoid silent overflow.
          if (value >= _int64Min && value <= _int64Max) {
            return value.toInt();
          }
          // Keep BigInt if out of range; caller can decide how to handle it.
          return value;
        }
        return value;

      // DataType.bigInt
      case 1:
        if (value is int) return BigInt.from(value);
        return value;

      // DataType.double
      case 2:
        if (value is double) return value;
        if (value is int) return value.toDouble();
        if (value is BigInt) {
          try {
            return value.toDouble();
          } catch (_) {
            return value;
          }
        }
        return value;

      // DataType.vector
      case 8:
        if (value is Uint8List) {
          return VectorData.fromBytes(value);
        }
        if (value is VectorData) return value;
        return value;

      default:
        return value;
    }
  }

  // MessagePack uses big-endian for multi-byte integers and floats.
  // Write directly into [BytesBuilder] to avoid per-value ByteData/Uint8List allocs.
  static final Uint8List _scratch8 = Uint8List(8);
  static final ByteData _scratch8Bd = ByteData.sublistView(_scratch8);

  static void _writeU16be(BytesBuilder b, int v) {
    b.addByte((v >> 8) & 0xFF);
    b.addByte(v & 0xFF);
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

  /// Copy scratch bytes. [BytesBuilder] uses `copy: false`; sharing
  /// [_scratch8] by reference would overwrite earlier int64/float64 values.
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
            'Binary schema codec: Read beyond buffer. Offset: $off, Buffer length: ${b.length}.',
      )
    ]);
  }
}

/// Field structure for schema-based encoding (saves space by omitting field names in records)
final class FieldStructure {
  final String name;
  final int typeIndex; // DataType enum index

  /// Deleted storage slot: still occupies a positional decode/encode slot, but
  /// must not appear in logical record maps (encode writes null).
  final bool deleted;

  const FieldStructure({
    required this.name,
    required this.typeIndex,
    this.deleted = false,
  });
}
