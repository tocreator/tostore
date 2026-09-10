import 'dart:convert';
import 'dart:typed_data';

import '../model/data_store_config.dart';
import '../model/table_schema.dart'
    show VectorData, TableSchema, DataType, PrimaryKeyType;
import 'binary_map_codec.dart';
import 'encryption.dart';
import 'platform_byte_data.dart';

/// High-performance zero-allocation binary encoder for WAL log entries.
///
/// Fully binary compatible with `WalEncoder` and `BinaryMapCodec`.
/// Eliminates intermediate object allocations (`Uint8List(5)`, `Uint8List(9)`),
/// avoids multi-stage copying, and pre-compiles MessagePack tokens for known
/// envelope keys (`op`, `table`, `data`, `ts`, `p`, `seq`, `txId`, `oldValues`).
class FastWalEncoder {
  static const int _walMagic = 0x546F574C; // "ToWL"
  static const int _walVersion = 0x01;

  // Ext types compatible with BinaryMapCodec
  static const int _extTypeBigInt = 1;
  static const int _extTypeVector = 2;

  // Pre-compiled MessagePack fixstr tokens for top-level WAL envelope keys
  // "op" -> len 2: 0xA2, 'o', 'p'
  static final Uint8List _keyOp = Uint8List.fromList(const [0xA2, 0x6F, 0x70]);
  // "table" -> len 5: 0xA5, 't', 'a', 'b', 'l', 'e'
  static final Uint8List _keyTable =
      Uint8List.fromList(const [0xA5, 0x74, 0x61, 0x62, 0x6C, 0x65]);
  // "data" -> len 4: 0xA4, 'd', 'a', 't', 'a'
  static final Uint8List _keyData =
      Uint8List.fromList(const [0xA4, 0x64, 0x61, 0x74, 0x61]);
  // "ts" -> len 2: 0xA2, 't', 's'
  static final Uint8List _keyTs = Uint8List.fromList(const [0xA2, 0x74, 0x73]);
  // "p" -> len 1: 0xA1, 'p'
  static final Uint8List _keyP = Uint8List.fromList(const [0xA1, 0x70]);
  // "seq" -> len 3: 0xA3, 's', 'e', 'q'
  static final Uint8List _keySeq =
      Uint8List.fromList(const [0xA3, 0x73, 0x65, 0x71]);
  // "txId" -> len 4: 0xA4, 't', 'x', 'I', 'd'
  static final Uint8List _keyTxId =
      Uint8List.fromList(const [0xA4, 0x74, 0x78, 0x49, 0x64]);
  // "oldValues" -> len 9: 0xA9, 'o', 'l', 'd', 'V', 'a', 'l', 'u', 'e', 's'
  static final Uint8List _keyOldValues = Uint8List.fromList(
      const [0xA9, 0x6F, 0x6C, 0x64, 0x56, 0x61, 0x6C, 0x75, 0x65, 0x73]);

  /// Reusable thread-local buffer for single-entry and batch encodes.
  static final FastWalBuffer _sharedBuffer =
      FastWalBuffer(capacity: 256 * 1024);

  /// Encodes a single WAL entry into a self-contained length-prefixed line.
  ///
  /// Format:
  /// `[RecordLen: 4B LE][Magic: 4B LE][Version: 1B][DataLen: 4B LE][MessagePack Payload]`
  /// RecordLen = 9 + DataLen.
  static Uint8List encodeEntry(
    Map<String, dynamic> walEntry, {
    FastWalBuffer? buffer,
  }) {
    final buf = buffer ?? _sharedBuffer;
    buf.reset();
    encodeEntryIntoBuffer(walEntry, buf);
    return buf.copyCurrentBytes();
  }

  /// Encodes a single WAL entry directly appending into [buf].
  ///
  /// Does not clear [buf], allowing multi-entry chaining in a single memory block.
  static void encodeEntryIntoBuffer(
    Map<String, dynamic> walEntry,
    FastWalBuffer buf,
  ) {
    final int partitionIndex = (walEntry['p'] as int?) ?? 0;
    final isEncrypted =
        EncryptionManager.getEncryptionType() != EncryptionType.none;

    if (!isEncrypted) {
      // Direct in-place encode path: write header placeholder, serialize payload, fill header
      final int recordStart = buf.length;
      buf.ensureAvailable(13);
      buf.length +=
          13; // Reserve 4B (RecordLen) + 4B (Magic) + 1B (Ver) + 4B (DataLen)

      final int payloadStart = buf.length;
      _writeWalEnvelope(buf, walEntry);
      final int payloadLen = buf.length - payloadStart;

      final int recordLen = 9 + payloadLen;
      // Write header at recordStart
      buf.setUint32LE(recordStart, recordLen);
      buf.setUint32LE(recordStart + 4, _walMagic);
      buf.setUint8(recordStart + 8, _walVersion);
      buf.setUint32LE(recordStart + 9, payloadLen);
    } else {
      // Encrypted path: serialize to temporary payload, encrypt, then write envelope
      final tempBuf = FastWalBuffer(capacity: 4096);
      _writeWalEnvelope(tempBuf, walEntry);
      final rawPayload = tempBuf.bytesView;

      final encryptedPayload = EncryptionManager.encodeBytes(
        rawPayload,
        aad: _partitionAad(partitionIndex),
      );

      final int recordLen = 9 + encryptedPayload.length;
      buf.ensureAvailable(13 + encryptedPayload.length);
      buf.writeUint32LE(recordLen);
      buf.writeUint32LE(_walMagic);
      buf.writeUint8(_walVersion);
      buf.writeUint32LE(encryptedPayload.length);
      buf.writeBytes(encryptedPayload);
    }
  }

  /// Encodes a single WAL entry directly appending into [buf] without allocating an intermediate Map.
  static void encodeDirectEntryIntoBuffer(
    FastWalBuffer buf, {
    required int op,
    required String tableUid,
    required Map<String, dynamic> data,
    required String tsIso,
    required int partitionIndex,
    required int seq,
    String? txId,
    Map<String, dynamic>? oldValues,
  }) {
    final isEncrypted =
        EncryptionManager.getEncryptionType() != EncryptionType.none;

    if (!isEncrypted) {
      final int recordStart = buf.length;
      buf.ensureAvailable(13);
      buf.length +=
          13; // Reserve 4B (RecordLen) + 4B (Magic) + 1B (Ver) + 4B (DataLen)

      final int payloadStart = buf.length;
      _writeWalEnvelopeDirect(
        buf,
        op: op,
        tableUid: tableUid,
        data: data,
        tsIso: tsIso,
        partitionIndex: partitionIndex,
        seq: seq,
        txId: txId,
        oldValues: oldValues,
      );
      final int payloadLen = buf.length - payloadStart;

      final int recordLen = 9 + payloadLen;
      buf.setUint32LE(recordStart, recordLen);
      buf.setUint32LE(recordStart + 4, _walMagic);
      buf.setUint8(recordStart + 8, _walVersion);
      buf.setUint32LE(recordStart + 9, payloadLen);
    } else {
      final tempBuf = FastWalBuffer(capacity: 4096);
      _writeWalEnvelopeDirect(
        tempBuf,
        op: op,
        tableUid: tableUid,
        data: data,
        tsIso: tsIso,
        partitionIndex: partitionIndex,
        seq: seq,
        txId: txId,
        oldValues: oldValues,
      );
      final rawPayload = tempBuf.bytesView;

      final encryptedPayload = EncryptionManager.encodeBytes(
        rawPayload,
        aad: _partitionAad(partitionIndex),
      );

      final int recordLen = 9 + encryptedPayload.length;
      buf.ensureAvailable(13 + encryptedPayload.length);
      buf.writeUint32LE(recordLen);
      buf.writeUint32LE(_walMagic);
      buf.writeUint8(_walVersion);
      buf.writeUint32LE(encryptedPayload.length);
      buf.writeBytes(encryptedPayload);
    }
  }

  /// Encodes a batch of WAL entries sequentially into a single contiguous byte buffer.
  ///
  /// Returns the view of the buffer containing all length-prefixed records.
  static Uint8List encodeBatch(
    List<Map<String, dynamic>> walEntries, {
    FastWalBuffer? buffer,
  }) {
    if (walEntries.isEmpty) return Uint8List(0);
    final buf = buffer ?? _sharedBuffer;
    buf.reset();
    for (int i = 0; i < walEntries.length; i++) {
      encodeEntryIntoBuffer(walEntries[i], buf);
    }
    return buf.copyCurrentBytes();
  }

  /// Encodes batch into [buf] without allocating an extra copy.
  static void encodeBatchInto(
    List<Map<String, dynamic>> walEntries,
    FastWalBuffer buf,
  ) {
    for (int i = 0; i < walEntries.length; i++) {
      encodeEntryIntoBuffer(walEntries[i], buf);
    }
  }

  /// Creates a [FastWalBatchSession] for streaming direct batch encoding.
  static FastWalBatchSession createBatchSession({
    required int op,
    required String tableUid,
    required String tsIso,
    required int partitionIndex,
    String? txId,
    bool hasOldValues = false,
  }) {
    return FastWalBatchSession.create(
      op: op,
      tableUid: tableUid,
      tsIso: tsIso,
      partitionIndex: partitionIndex,
      txId: txId,
      hasOldValues: hasOldValues,
    );
  }

  /// Creates a [FastWalTableSession] for streaming direct batch encoding using table schema.
  static FastWalTableSession createTableSession({
    required int op,
    required String tableUid,
    required String tsIso,
    required int partitionIndex,
    required TableSchema schema,
    String? txId,
    bool hasOldValues = false,
  }) {
    return FastWalTableSession.create(
      op: op,
      tableUid: tableUid,
      tsIso: tsIso,
      partitionIndex: partitionIndex,
      schema: schema,
      txId: txId,
      hasOldValues: hasOldValues,
    );
  }

  static Uint8List _partitionAad(int partitionIndex) {
    final aadData = ByteData(4);
    aadData.setInt32(0, partitionIndex, Endian.little);
    return aadData.buffer.asUint8List();
  }

  /// Writes top-level WAL envelope Map directly to [buf].
  static void _writeWalEnvelope(FastWalBuffer buf, Map<String, dynamic> entry) {
    // Count entries: op, table, data, ts, p, seq always present.
    // txId and oldValues are optional.
    int fieldCount = 6;
    final txId = entry['txId'];
    if (txId != null) fieldCount++;
    final oldValues = entry['oldValues'];
    if (oldValues != null) fieldCount++;

    // Write map32 header: 0xDF + count (4 bytes big-endian)
    buf.writeUint8(0xDF);
    buf.writeUint32BE(fieldCount);

    // 1. "op"
    buf.writeBytes(_keyOp);
    _writeValue(buf, entry['op']);

    // 2. "table"
    buf.writeBytes(_keyTable);
    _writeValue(buf, entry['table']);

    // 3. "ts"
    buf.writeBytes(_keyTs);
    _writeValue(buf, entry['ts']);

    // 4. "data"
    buf.writeBytes(_keyData);
    _writeValue(buf, entry['data']);

    // 5. "p"
    buf.writeBytes(_keyP);
    _writeValue(buf, entry['p']);

    // 6. "seq"
    buf.writeBytes(_keySeq);
    _writeValue(buf, entry['seq']);

    // 7. "txId" (optional)
    if (txId != null) {
      buf.writeBytes(_keyTxId);
      _writeValue(buf, txId);
    }

    // 8. "oldValues" (optional)
    if (oldValues != null) {
      buf.writeBytes(_keyOldValues);
      _writeValue(buf, oldValues);
    }
  }

  /// Writes top-level WAL envelope Map directly to [buf] from scalar arguments.
  static void _writeWalEnvelopeDirect(
    FastWalBuffer buf, {
    required int op,
    required String tableUid,
    required Map<String, dynamic> data,
    required String tsIso,
    required int partitionIndex,
    required int seq,
    String? txId,
    Map<String, dynamic>? oldValues,
  }) {
    int fieldCount = 6;
    if (txId != null) fieldCount++;
    if (oldValues != null) fieldCount++;

    // Write map32 header: 0xDF + count (4 bytes big-endian)
    buf.writeUint8(0xDF);
    buf.writeUint32BE(fieldCount);

    // 1. "op"
    buf.writeBytes(_keyOp);
    _writeValue(buf, op);

    // 2. "table"
    buf.writeBytes(_keyTable);
    _writeString(buf, tableUid);

    // 3. "ts"
    buf.writeBytes(_keyTs);
    _writeString(buf, tsIso);

    // 4. "data"
    buf.writeBytes(_keyData);
    _writeValue(buf, data);

    // 5. "p"
    buf.writeBytes(_keyP);
    _writeValue(buf, partitionIndex);

    // 6. "seq"
    buf.writeBytes(_keySeq);
    _writeValue(buf, seq);

    // 7. "txId" (optional)
    if (txId != null) {
      buf.writeBytes(_keyTxId);
      _writeString(buf, txId);
    }

    // 8. "oldValues" (optional)
    if (oldValues != null) {
      buf.writeBytes(_keyOldValues);
      _writeValue(buf, oldValues);
    }
  }

  /// MessagePack value serializer writing directly into contiguous buffer.
  static void _writeValue(FastWalBuffer buf, dynamic value) {
    if (value == null) {
      buf.writeUint8(0xC0);
      return;
    }

    if (value is bool) {
      buf.writeUint8(value ? 0xC3 : 0xC2);
      return;
    }

    if (value is int) {
      // positive fixint: 0x00 - 0x7F
      if (value >= 0 && value < 128) {
        buf.writeUint8(value);
        return;
      }
      // negative fixint: 0xE0 - 0xFF (-32 to -1)
      if (value >= -32 && value < 0) {
        buf.writeUint8(0xE0 | (value + 32));
        return;
      }
      // int32: 0xD2 + 4 bytes BE
      if (value >= -0x80000000 && value <= 0x7FFFFFFF) {
        buf.writeUint8(0xD2);
        buf.writeInt32BE(value);
        return;
      }
      // int64: 0xD3 + 8 bytes BE
      buf.writeUint8(0xD3);
      buf.writeInt64BE(value);
      return;
    }

    if (value is double) {
      buf.writeUint8(0xCB);
      buf.writeFloat64BE(value);
      return;
    }

    if (value is String) {
      _writeString(buf, value);
      return;
    }

    if (value is Map) {
      final int count = value.length > BinaryMapCodec.maxMapSize
          ? BinaryMapCodec.maxMapSize
          : value.length;
      buf.writeUint8(0xDF); // map32
      buf.writeUint32BE(count);

      int written = 0;
      for (final e in value.entries) {
        if (++written > BinaryMapCodec.maxMapSize) break;
        final k = e.key;
        if (k is String) {
          _writeString(buf, k);
        } else {
          _writeString(buf, k.toString());
        }
        _writeValue(buf, e.value);
      }
      return;
    }

    if (value is List) {
      final int count = value.length > BinaryMapCodec.maxArraySize
          ? BinaryMapCodec.maxArraySize
          : value.length;
      buf.writeUint8(0xDD); // array32
      buf.writeUint32BE(count);
      for (int i = 0; i < count; i++) {
        _writeValue(buf, value[i]);
      }
      return;
    }

    if (value is Uint8List) {
      final int len = value.length > BinaryMapCodec.maxBinaryLength
          ? BinaryMapCodec.maxBinaryLength
          : value.length;
      buf.writeUint8(0xC6); // bin32
      buf.writeUint32BE(len);
      buf.writeBytes(value, 0, len);
      return;
    }

    if (value is BigInt) {
      final payload = utf8.encode(value.toString());
      final int len = payload.length;
      buf.writeUint8(0xC9); // ext32
      buf.writeUint32BE(len);
      buf.writeUint8(_extTypeBigInt);
      buf.writeBytes(payload);
      return;
    }

    if (value is VectorData) {
      final payload = value.toBytes();
      final int len = payload.length;
      buf.writeUint8(0xC9); // ext32
      buf.writeUint32BE(len);
      buf.writeUint8(_extTypeVector);
      buf.writeBytes(payload);
      return;
    }

    // Fallback: toString or null
    buf.writeUint8(0xC0);
  }

  static void _writeString(FastWalBuffer buf, String s) {
    final int len = s.length;
    if (len == 0) {
      buf.writeUint8(0xA0); // empty fixstr
      return;
    }

    // Fast-path for short ASCII strings (very common for field keys & values)
    if (len < 32) {
      bool isAscii = true;
      for (int i = 0; i < len; i++) {
        if (s.codeUnitAt(i) > 0x7F) {
          isAscii = false;
          break;
        }
      }
      if (isAscii) {
        buf.writeUint8(0xA0 | len);
        buf.ensureAvailable(len);
        for (int i = 0; i < len; i++) {
          buf.writeUint8Fast(s.codeUnitAt(i));
        }
        return;
      }
    }

    // UTF-8 fallback
    final encoded = utf8.encode(s);
    final int encLen = encoded.length > BinaryMapCodec.maxStringLength
        ? BinaryMapCodec.maxStringLength
        : encoded.length;

    if (encLen < 32) {
      buf.writeUint8(0xA0 | encLen);
      buf.writeBytes(encoded, 0, encLen);
    } else {
      buf.writeUint8(0xDB); // str32
      buf.writeUint32BE(encLen);
      buf.writeBytes(encoded, 0, encLen);
    }
  }
}

/// Ultra-fast growable byte buffer designed for direct MessagePack serialization.
class FastWalBuffer {
  Uint8List _buffer;
  ByteData _view;
  int length = 0;

  FastWalBuffer({int capacity = 64 * 1024})
      : _buffer = Uint8List(capacity),
        _view = ByteData.sublistView(Uint8List(capacity)) {
    _view = ByteData.sublistView(_buffer);
  }

  int get capacity => _buffer.length;

  Uint8List get bytesView => Uint8List.sublistView(_buffer, 0, length);

  Uint8List copyCurrentBytes() {
    final out = Uint8List(length);
    out.setRange(0, length, _buffer);
    return out;
  }

  void reset() {
    length = 0;
  }

  void ensureAvailable(int bytesNeeded) {
    final int required = length + bytesNeeded;
    if (required <= _buffer.length) return;
    int newCap = _buffer.length * 2;
    if (newCap < required) newCap = required + 4096;
    final newBuf = Uint8List(newCap);
    newBuf.setRange(0, length, _buffer);
    _buffer = newBuf;
    _view = ByteData.sublistView(_buffer);
  }

  @pragma('vm:prefer-inline')
  void writeUint8(int byte) {
    ensureAvailable(1);
    _buffer[length++] = byte;
  }

  @pragma('vm:prefer-inline')
  void writeUint8Fast(int byte) {
    _buffer[length++] = byte;
  }

  @pragma('vm:prefer-inline')
  void writeUint32LE(int val) {
    ensureAvailable(4);
    _buffer[length] = val & 0xFF;
    _buffer[length + 1] = (val >> 8) & 0xFF;
    _buffer[length + 2] = (val >> 16) & 0xFF;
    _buffer[length + 3] = (val >> 24) & 0xFF;
    length += 4;
  }

  @pragma('vm:prefer-inline')
  void setUint32LE(int offset, int val) {
    _buffer[offset] = val & 0xFF;
    _buffer[offset + 1] = (val >> 8) & 0xFF;
    _buffer[offset + 2] = (val >> 16) & 0xFF;
    _buffer[offset + 3] = (val >> 24) & 0xFF;
  }

  @pragma('vm:prefer-inline')
  void setUint8(int offset, int val) {
    _buffer[offset] = val & 0xFF;
  }

  @pragma('vm:prefer-inline')
  void writeUint32BE(int val) {
    ensureAvailable(4);
    _buffer[length] = (val >> 24) & 0xFF;
    _buffer[length + 1] = (val >> 16) & 0xFF;
    _buffer[length + 2] = (val >> 8) & 0xFF;
    _buffer[length + 3] = val & 0xFF;
    length += 4;
  }

  @pragma('vm:prefer-inline')
  void writeInt32BE(int val) {
    ensureAvailable(4);
    _buffer[length] = (val >> 24) & 0xFF;
    _buffer[length + 1] = (val >> 16) & 0xFF;
    _buffer[length + 2] = (val >> 8) & 0xFF;
    _buffer[length + 3] = val & 0xFF;
    length += 4;
  }

  @pragma('vm:prefer-inline')
  void writeInt32BEFast(int val) {
    _buffer[length] = (val >> 24) & 0xFF;
    _buffer[length + 1] = (val >> 16) & 0xFF;
    _buffer[length + 2] = (val >> 8) & 0xFF;
    _buffer[length + 3] = val & 0xFF;
    length += 4;
  }

  @pragma('vm:prefer-inline')
  void writeInt64BE(int val) {
    ensureAvailable(8);
    PlatformByteData.setInt64(_view, length, val, Endian.big);
    length += 8;
  }

  @pragma('vm:prefer-inline')
  void writeFloat64BE(double val) {
    ensureAvailable(8);
    _view.setFloat64(length, val, Endian.big);
    length += 8;
  }

  void writeBytes(List<int> bytes, [int start = 0, int? end]) {
    final int toWrite = (end ?? bytes.length) - start;
    if (toWrite <= 0) return;
    ensureAvailable(toWrite);
    _buffer.setRange(length, length + toWrite, bytes, start);
    length += toWrite;
  }

  @pragma('vm:prefer-inline')
  void writeBytesFast(List<int> bytes, [int start = 0, int? end]) {
    final int toWrite = (end ?? bytes.length) - start;
    if (toWrite <= 0) return;
    _buffer.setRange(length, length + toWrite, bytes, start);
    length += toWrite;
  }

  @pragma('vm:prefer-inline')
  void writeAsciiStringFast(String str) {
    final len = str.length;
    if (len < 32) {
      _buffer[length++] = 0xA0 | len;
    } else if (len <= 255) {
      _buffer[length++] = 0xD9;
      _buffer[length++] = len;
    } else if (len <= 65535) {
      _buffer[length++] = 0xDA;
      _buffer[length++] = (len >> 8) & 0xFF;
      _buffer[length++] = len & 0xFF;
    } else {
      _buffer[length++] = 0xDB;
      _buffer[length++] = (len >> 24) & 0xFF;
      _buffer[length++] = (len >> 16) & 0xFF;
      _buffer[length++] = (len >> 8) & 0xFF;
      _buffer[length++] = len & 0xFF;
    }
    int i = 0;
    while (i + 4 <= len) {
      _buffer[length] = str.codeUnitAt(i);
      _buffer[length + 1] = str.codeUnitAt(i + 1);
      _buffer[length + 2] = str.codeUnitAt(i + 2);
      _buffer[length + 3] = str.codeUnitAt(i + 3);
      length += 4;
      i += 4;
    }
    while (i < len) {
      _buffer[length++] = str.codeUnitAt(i++);
    }
  }
}

/// High-throughput streaming batch encoder session.
///
/// Pre-compiles the invariant envelope fields (`op`, `tableUid`, `tsIso`, `p`, `txId`)
/// into a contiguous byte chunk, avoiding per-record Map allocations, key lookups,
/// and redundant string/integer encodings.
class FastWalBatchSession {
  final Uint8List _staticPrefix;
  final int partitionIndex;
  final bool hasOldValues;
  final bool _isEncrypted;

  FastWalBatchSession._(
    this._staticPrefix,
    this.partitionIndex,
    this.hasOldValues,
    this._isEncrypted,
  );

  factory FastWalBatchSession.create({
    required int op,
    required String tableUid,
    required String tsIso,
    required int partitionIndex,
    String? txId,
    bool hasOldValues = false,
  }) {
    final prefixBuf = FastWalBuffer(capacity: 256);
    int fieldCount = 6;
    if (txId != null) fieldCount++;
    if (hasOldValues) fieldCount++;

    prefixBuf.writeUint8(0xDF);
    prefixBuf.writeUint32BE(fieldCount);

    // 1. "op"
    prefixBuf.writeBytes(FastWalEncoder._keyOp);
    FastWalEncoder._writeValue(prefixBuf, op);

    // 2. "table"
    prefixBuf.writeBytes(FastWalEncoder._keyTable);
    FastWalEncoder._writeString(prefixBuf, tableUid);

    // 3. "ts"
    prefixBuf.writeBytes(FastWalEncoder._keyTs);
    FastWalEncoder._writeString(prefixBuf, tsIso);

    // 4. "p"
    prefixBuf.writeBytes(FastWalEncoder._keyP);
    FastWalEncoder._writeValue(prefixBuf, partitionIndex);

    // 5. "txId" (optional)
    if (txId != null) {
      prefixBuf.writeBytes(FastWalEncoder._keyTxId);
      FastWalEncoder._writeString(prefixBuf, txId);
    }

    final isEncrypted =
        EncryptionManager.getEncryptionType() != EncryptionType.none;

    return FastWalBatchSession._(
      prefixBuf.copyCurrentBytes(),
      partitionIndex,
      hasOldValues,
      isEncrypted,
    );
  }

  /// Encodes a single record directly appending into [buf].
  void encodeRecordDirect(
    FastWalBuffer buf,
    Map<String, dynamic> record,
    int seq, [
    Map<String, dynamic>? oldValues,
  ]) {
    if (!_isEncrypted) {
      final int recordStart = buf.length;
      buf.ensureAvailable(13);
      buf.length += 13;

      final int payloadStart = buf.length;

      // 1. Write pre-compiled static prefix (op, table, ts, p, txId)
      buf.writeBytes(_staticPrefix);

      // 2. "seq"
      buf.writeBytes(FastWalEncoder._keySeq);
      FastWalEncoder._writeValue(buf, seq);

      // 3. "data"
      buf.writeBytes(FastWalEncoder._keyData);
      FastWalEncoder._writeValue(buf, record);

      // 4. "oldValues" (if present)
      if (hasOldValues && oldValues != null) {
        buf.writeBytes(FastWalEncoder._keyOldValues);
        FastWalEncoder._writeValue(buf, oldValues);
      }

      final int payloadLen = buf.length - payloadStart;
      final int recordLen = 9 + payloadLen;

      buf.setUint32LE(recordStart, recordLen);
      buf.setUint32LE(recordStart + 4, FastWalEncoder._walMagic);
      buf.setUint8(recordStart + 8, FastWalEncoder._walVersion);
      buf.setUint32LE(recordStart + 9, payloadLen);
    } else {
      final tempBuf = FastWalBuffer(capacity: 4096);
      tempBuf.writeBytes(_staticPrefix);
      tempBuf.writeBytes(FastWalEncoder._keySeq);
      FastWalEncoder._writeValue(tempBuf, seq);
      tempBuf.writeBytes(FastWalEncoder._keyData);
      FastWalEncoder._writeValue(tempBuf, record);
      if (hasOldValues && oldValues != null) {
        tempBuf.writeBytes(FastWalEncoder._keyOldValues);
        FastWalEncoder._writeValue(tempBuf, oldValues);
      }

      final encryptedPayload = EncryptionManager.encodeBytes(
        tempBuf.bytesView,
        aad: FastWalEncoder._partitionAad(partitionIndex),
      );

      final int recordLen = 9 + encryptedPayload.length;
      buf.ensureAvailable(13 + encryptedPayload.length);
      buf.writeUint32LE(recordLen);
      buf.writeUint32LE(FastWalEncoder._walMagic);
      buf.writeUint8(FastWalEncoder._walVersion);
      buf.writeUint32LE(encryptedPayload.length);
      buf.writeBytes(encryptedPayload);
    }
  }
}

/// Pre-compiled field descriptor for schema-aware direct WAL encoding.
class FastWalTableField {
  final String name;
  final DataType type;
  final Uint8List keyToken;

  FastWalTableField({
    required this.name,
    required this.type,
    required this.keyToken,
  });

  factory FastWalTableField.create(String name, DataType type) {
    final len = name.length;
    final buf = <int>[];
    if (len < 32) {
      buf.add(0xA0 | len);
    } else {
      buf.add(0xDB);
      buf.add((len >> 24) & 0xFF);
      buf.add((len >> 16) & 0xFF);
      buf.add((len >> 8) & 0xFF);
      buf.add(len & 0xFF);
    }
    buf.addAll(name.codeUnits);
    return FastWalTableField(
      name: name,
      type: type,
      keyToken: Uint8List.fromList(buf),
    );
  }
}

/// Ultra-fast schema-aware batch WAL encoder session.
///
/// Pre-compiles table schema field MessagePack key tokens and data envelope,
/// enabling zero-allocation, typed-dispatch serialization of structured records.
class FastWalTableSession {
  final Uint8List _staticPrefix;
  final List<FastWalTableField> _fields;
  final Uint8List _mapHeader;
  final int partitionIndex;
  final bool hasOldValues;
  final bool _isEncrypted;
  final int _estimatedRecordBytes;
  int get estimatedRecordBytes => _estimatedRecordBytes;

  FastWalTableSession._({
    required Uint8List staticPrefix,
    required List<FastWalTableField> fields,
    required Uint8List mapHeader,
    required this.partitionIndex,
    required this.hasOldValues,
    required bool isEncrypted,
    required int estimatedRecordBytes,
  })  : _staticPrefix = staticPrefix,
        _fields = fields,
        _mapHeader = mapHeader,
        _isEncrypted = isEncrypted,
        _estimatedRecordBytes = estimatedRecordBytes;

  factory FastWalTableSession.create({
    required int op,
    required String tableUid,
    required String tsIso,
    required int partitionIndex,
    required TableSchema schema,
    String? txId,
    bool hasOldValues = false,
  }) {
    final prefixBuf = FastWalBuffer(capacity: 256);
    int fieldCount = 6;
    if (txId != null) fieldCount++;
    if (hasOldValues) fieldCount++;

    prefixBuf.writeUint8(0xDF);
    prefixBuf.writeUint32BE(fieldCount);

    // 1. "op"
    prefixBuf.writeBytes(FastWalEncoder._keyOp);
    FastWalEncoder._writeValue(prefixBuf, op);

    // 2. "table"
    prefixBuf.writeBytes(FastWalEncoder._keyTable);
    FastWalEncoder._writeString(prefixBuf, tableUid);

    // 3. "ts"
    prefixBuf.writeBytes(FastWalEncoder._keyTs);
    FastWalEncoder._writeString(prefixBuf, tsIso);

    // 4. "p"
    prefixBuf.writeBytes(FastWalEncoder._keyP);
    FastWalEncoder._writeValue(prefixBuf, partitionIndex);

    // 5. "txId" (optional)
    if (txId != null) {
      prefixBuf.writeBytes(FastWalEncoder._keyTxId);
      FastWalEncoder._writeString(prefixBuf, txId);
    }

    final fields = <FastWalTableField>[];
    // Primary key field first
    fields.add(FastWalTableField.create(
      schema.primaryKey,
      schema.primaryKeyConfig.type == PrimaryKeyType.sequential
          ? DataType.integer
          : DataType.text,
    ));
    for (final f in schema.fields) {
      if (f.name != schema.primaryKey) {
        fields.add(FastWalTableField.create(f.name, f.type));
      }
    }

    final mapBuf = <int>[
      0xDF,
      (fields.length >> 24) & 0xFF,
      (fields.length >> 16) & 0xFF,
      (fields.length >> 8) & 0xFF,
      fields.length & 0xFF,
    ];

    final isEncrypted =
        EncryptionManager.getEncryptionType() != EncryptionType.none;

    final estimatedRecordBytes = prefixBuf.length + 30 + fields.length * 48;

    return FastWalTableSession._(
      staticPrefix: prefixBuf.copyCurrentBytes(),
      fields: fields,
      mapHeader: Uint8List.fromList(mapBuf),
      partitionIndex: partitionIndex,
      hasOldValues: hasOldValues,
      isEncrypted: isEncrypted,
      estimatedRecordBytes: estimatedRecordBytes,
    );
  }

  /// Encodes a single record using schema-aware field layout directly into [buf].
  void encodeRecordDirect(
    FastWalBuffer buf,
    Map<String, dynamic> record,
    int seq, [
    Map<String, dynamic>? oldValues,
    bool capacityPreReserved = false,
  ]) {
    if (!_isEncrypted) {
      if (!capacityPreReserved) {
        buf.ensureAvailable(_estimatedRecordBytes);
      }

      final int recordStart = buf.length;
      buf.length += 13; // Header placeholder
      final int payloadStart = buf.length;

      // 1. Static prefix
      buf.writeBytesFast(_staticPrefix);

      // 2. "seq"
      buf.writeBytesFast(FastWalEncoder._keySeq);
      if (seq < 128) {
        buf.writeUint8Fast(seq);
      } else if (seq <= 0x7FFFFFFF) {
        buf.writeUint8Fast(0xD2);
        buf.writeInt32BE(seq);
      } else {
        buf.writeUint8Fast(0xD3);
        buf.writeInt64BE(seq);
      }

      // 3. "data"
      buf.writeBytesFast(FastWalEncoder._keyData);

      final int fCount = _fields.length;
      if (record.length != fCount) {
        // Fallback for dynamic/extra fields not in pre-compiled schema
        FastWalEncoder._writeValue(buf, record);
      } else {
        buf.writeBytesFast(_mapHeader);
        for (int i = 0; i < fCount; i++) {
          final f = _fields[i];
          buf.writeBytesFast(f.keyToken);
          final val = record[f.name];
          _writeFieldValue(buf, val, f.type);
        }
      }

      // 4. "oldValues" (if present)
      if (hasOldValues) {
        buf.writeBytesFast(FastWalEncoder._keyOldValues);
        FastWalEncoder._writeValue(buf, oldValues);
      }

      final int payloadLen = buf.length - payloadStart;
      final int recordLen = 9 + payloadLen;

      buf.setUint32LE(recordStart, recordLen);
      buf.setUint32LE(recordStart + 4, FastWalEncoder._walMagic);
      buf.setUint8(recordStart + 8, FastWalEncoder._walVersion);
      buf.setUint32LE(recordStart + 9, payloadLen);
    } else {
      final tempBuf = FastWalBuffer(capacity: _estimatedRecordBytes);
      tempBuf.writeBytes(_staticPrefix);
      tempBuf.writeBytes(FastWalEncoder._keySeq);
      FastWalEncoder._writeValue(tempBuf, seq);
      tempBuf.writeBytes(FastWalEncoder._keyData);

      final int fCount = _fields.length;
      if (record.length != fCount) {
        FastWalEncoder._writeValue(tempBuf, record);
      } else {
        tempBuf.writeBytes(_mapHeader);
        for (int i = 0; i < fCount; i++) {
          final f = _fields[i];
          tempBuf.writeBytes(f.keyToken);
          final val = record[f.name];
          _writeFieldValue(tempBuf, val, f.type);
        }
      }

      if (hasOldValues) {
        tempBuf.writeBytes(FastWalEncoder._keyOldValues);
        FastWalEncoder._writeValue(tempBuf, oldValues);
      }

      final encryptedPayload = EncryptionManager.encodeBytes(
        tempBuf.bytesView,
        aad: FastWalEncoder._partitionAad(partitionIndex),
      );

      final int recordLen = 9 + encryptedPayload.length;
      buf.ensureAvailable(13 + encryptedPayload.length);
      buf.writeUint32LE(recordLen);
      buf.writeUint32LE(FastWalEncoder._walMagic);
      buf.writeUint8(FastWalEncoder._walVersion);
      buf.writeUint32LE(encryptedPayload.length);
      buf.writeBytes(encryptedPayload);
    }
  }

  @pragma('vm:prefer-inline')
  static void _writeFieldValue(FastWalBuffer buf, dynamic val, DataType type) {
    if (val == null) {
      buf.writeUint8(0xC0);
      return;
    }

    switch (type) {
      case DataType.integer:
        if (val is int) {
          if (val >= 0 && val < 128) {
            buf.writeUint8Fast(val);
          } else if (val >= -32 && val < 0) {
            buf.writeUint8Fast(0xE0 | (val + 32));
          } else if (val >= -0x80000000 && val <= 0x7FFFFFFF) {
            buf.writeUint8Fast(0xD2);
            buf.writeInt32BEFast(val);
          } else {
            buf.writeUint8Fast(0xD3);
            buf.writeInt64BE(val);
          }
          return;
        } else if (val is String) {
          buf.writeAsciiStringFast(val);
          return;
        }
        break;

      case DataType.text:
        if (val is String) {
          buf.writeAsciiStringFast(val);
          return;
        }
        break;

      case DataType.double:
        if (val is double) {
          buf.writeUint8(0xCB);
          buf.writeFloat64BE(val);
          return;
        } else if (val is num) {
          buf.writeUint8(0xCB);
          buf.writeFloat64BE(val.toDouble());
          return;
        }
        break;

      case DataType.boolean:
        if (val is bool) {
          buf.writeUint8(val ? 0xC3 : 0xC2);
          return;
        }
        break;

      case DataType.datetime:
        if (val is String) {
          final len = val.length;
          if (len < 32) {
            buf.writeUint8(0xA0 | len);
            for (int i = 0; i < len; i++) {
              buf.writeUint8Fast(val.codeUnitAt(i));
            }
          } else {
            buf.writeUint8(0xDB);
            buf.writeUint32BE(len);
            for (int i = 0; i < len; i++) {
              buf.writeUint8Fast(val.codeUnitAt(i));
            }
          }
          return;
        } else if (val is DateTime) {
          final s = val.toIso8601String();
          final len = s.length;
          buf.writeUint8(0xA0 | len);
          for (int i = 0; i < len; i++) {
            buf.writeUint8Fast(s.codeUnitAt(i));
          }
          return;
        }
        break;

      default:
        break;
    }

    FastWalEncoder._writeValue(buf, val);
  }
}
