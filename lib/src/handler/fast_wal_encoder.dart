import 'dart:convert';
import 'dart:typed_data';

import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_schema.dart'
    show VectorData, TableSchema, DataType, PrimaryKeyType;
import 'binary_map_codec.dart';
import 'encryption.dart';
import 'platform_byte_data.dart';

/// High-performance zero-allocation binary encoder for WAL log entries.
///
/// Faster writer of the same on-disk format as [WalEncoder] / [BinaryMapCodec].
/// Envelope layout is `[RecordLen][ToWL][ver][DataLen][MessagePack]`; payload
/// tokens match released `wal_manager` recovery (`map32`/`str32`/…).
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
    final int n = walEntries.length;
    if (n >= 16) {
      encodeEntryIntoBuffer(walEntries[0], buf);
      final int probed = buf.length;
      buf.reset();
      if (probed > 0) {
        buf.ensureAvailable(n * (probed + (probed >> 3)) + 4096);
      }
    }
    for (int i = 0; i < n; i++) {
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

  static final List<Uint8List> _partitionAadCache = List<Uint8List>.generate(
    16,
    (i) {
      final b = ByteData(4);
      b.setInt32(0, i, Endian.little);
      return b.buffer.asUint8List();
    },
    growable: false,
  );

  static Uint8List _partitionAad(int partitionIndex) {
    if (partitionIndex >= 0 && partitionIndex < 16) {
      return _partitionAadCache[partitionIndex];
    }
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
      buf.writeMsgpackInt(value);
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

    // Uint8List implements List<int> — must run before the List branch.
    if (value is Uint8List) {
      final int len = value.length;
      if (len > BinaryMapCodec.maxBinaryLength) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'FastWalEncoder: Binary length $len exceeds maximum limit of ${BinaryMapCodec.maxBinaryLength}.',
          )
        ]);
      }
      buf.writeUint8(0xC6); // bin32
      buf.writeUint32BE(len);
      buf.writeBytes(value, 0, len);
      return;
    }

    if (value is Map) {
      final int count = value.length;
      if (count > BinaryMapCodec.maxMapSize) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'FastWalEncoder: Map size $count exceeds maximum limit of ${BinaryMapCodec.maxMapSize}.',
          )
        ]);
      }
      buf.writeUint8(0xDF); // map32
      buf.writeUint32BE(count);

      for (final e in value.entries) {
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
      final int count = value.length;
      if (count > BinaryMapCodec.maxArraySize) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'FastWalEncoder: Array size $count exceeds maximum limit of ${BinaryMapCodec.maxArraySize}.',
          )
        ]);
      }
      buf.writeUint8(0xDD); // array32
      buf.writeUint32BE(count);
      for (int i = 0; i < count; i++) {
        _writeValue(buf, value[i]);
      }
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

    if (value is DateTime) {
      _writeString(buf, value.toIso8601String());
      return;
    }

    // Fallback: toString or null
    buf.writeUint8(0xC0);
  }

  static void _writeString(FastWalBuffer buf, String s) {
    buf.writeShortString(s);
  }
}

/// Ultra-fast growable byte buffer designed for direct MessagePack serialization.
class FastWalBuffer {
  Uint8List _buffer;
  late ByteData _view;
  int length = 0;

  FastWalBuffer({int capacity = 64 * 1024}) : _buffer = Uint8List(capacity) {
    _view = ByteData.sublistView(_buffer);
  }

  int get capacity => _buffer.length;

  Uint8List get bytesView => Uint8List.sublistView(_buffer, 0, length);

  Uint8List copyCurrentBytes() {
    final out = Uint8List(length);
    out.setRange(0, length, _buffer);
    return out;
  }

  /// Transfer ownership of the current payload and reset this buffer.
  ///
  /// Avoids a full memcpy when handing encoded bytes to the async WAL queue,
  /// but creates an exact-sized copy if the buffer is significantly larger
  /// than the taken length to prevent memory retention leaks.
  Uint8List takeBytes() {
    final int len = length;
    if (len == 0) {
      length = 0;
      return Uint8List(0);
    }
    if (len < (_buffer.length >> 1)) {
      final taken = Uint8List(len);
      taken.setRange(0, len, _buffer);
      length = 0;
      return taken;
    }
    final taken = Uint8List.sublistView(_buffer, 0, len);
    final int nextCap = _buffer.length < 65536 ? 65536 : _buffer.length;
    _buffer = Uint8List(nextCap);
    _view = ByteData.sublistView(_buffer);
    length = 0;
    return taken;
  }

  void reset() {
    length = 0;
  }

  void ensureAvailable(int bytesNeeded) {
    final int required = length + bytesNeeded;
    if (required <= _buffer.length) return;
    int newCap = _buffer.length * 2;
    if (newCap < required) newCap = required + 4096;
    // After the first multi-MB reserve, doubling would zero-fill another
    // 20-50MB on a few-byte overrun. Grow by 1MB slack instead.
    if (_buffer.length >= 1024 * 1024 && newCap > required + 1024 * 1024) {
      newCap = required + 1024 * 1024;
    }
    final newBuf = Uint8List(newCap);
    if (length > 0) {
      newBuf.setRange(0, length, _buffer);
    }
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
    if (length >= _buffer.length) {
      ensureAvailable(1);
    }
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
    if (length + 4 > _buffer.length) {
      ensureAvailable(4);
    }
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
    if (length + toWrite > _buffer.length) {
      ensureAvailable(toWrite);
    }
    _buffer.setRange(length, length + toWrite, bytes, start);
    length += toWrite;
  }

  @pragma('vm:prefer-inline')
  void writeUint16BE(int val) {
    ensureAvailable(2);
    _buffer[length] = (val >> 8) & 0xFF;
    _buffer[length + 1] = val & 0xFF;
    length += 2;
  }

  Uint8List get buffer => _buffer;

  /// Released on-disk map header: always map32.
  @pragma('vm:prefer-inline')
  void writeMsgpackMapHeader(int count) {
    if (length + 5 > _buffer.length) {
      ensureAvailable(5);
    }
    _buffer[length++] = 0xDF;
    _buffer[length++] = (count >> 24) & 0xFF;
    _buffer[length++] = (count >> 16) & 0xFF;
    _buffer[length++] = (count >> 8) & 0xFF;
    _buffer[length++] = count & 0xFF;
  }

  /// Hot path for short strings (field values in batchInsert are typically < 32).
  @pragma('vm:prefer-inline')
  void writeShortString(String str) {
    final int len = str.length;
    if (len < 32) {
      if (length + 1 + len > _buffer.length) {
        ensureAvailable(1 + len);
      }
      final int start = length;
      _buffer[length++] = 0xA0 | len;
      if (_tryWriteAsciiChars(str, len)) return;
      length = start;
      _writeStringUtf8Fallback(str);
      return;
    }
    writeStringSafe(str);
  }

  @pragma('vm:prefer-inline')
  void writeMsgpackInt(int val) {
    if (val >= 0 && val < 128) {
      writeUint8Fast(val);
      return;
    }
    if (val >= -32 && val < 0) {
      writeUint8Fast(0xE0 | (val + 32));
      return;
    }
    if (val >= -0x80000000 && val <= 0x7FFFFFFF) {
      writeUint8Fast(0xD2);
      writeInt32BEFast(val);
      return;
    }
    writeUint8Fast(0xD3);
    writeInt64BE(val);
  }

  @pragma('vm:prefer-inline')
  void writeTokenFast(Uint8List token) {
    final int tLen = token.length;
    if (length + tLen > _buffer.length) {
      ensureAvailable(tLen);
    }
    final int pos = length;
    final b = _buffer;
    int i = 0;
    while (i + 4 <= tLen) {
      b[pos + i] = token[i];
      b[pos + i + 1] = token[i + 1];
      b[pos + i + 2] = token[i + 2];
      b[pos + i + 3] = token[i + 3];
      i += 4;
    }
    while (i < tLen) {
      b[pos + i] = token[i];
      i++;
    }
    length = pos + tLen;
  }

  @pragma('vm:prefer-inline')
  void writeStringSafe(String str) {
    final len = str.length;
    if (len == 0) {
      ensureAvailable(1);
      _buffer[length++] = 0xA0;
      return;
    }
    if (len > BinaryMapCodec.maxStringLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'FastWalEncoder: String length $len exceeds maximum limit of ${BinaryMapCodec.maxStringLength}.',
        )
      ]);
    }

    // Optimistic ASCII path: MessagePack length == Dart length only for ASCII.
    // Non-ASCII rolls back the header and re-encodes with real UTF-8 byte length.
    // Header matches released WalEncoder (fixstr / str32).
    final int headerBytes = BinaryMapCodec.onDiskStringHeaderSize(len);
    ensureAvailable(headerBytes + len);
    final int start = length;
    length += BinaryMapCodec.writeOnDiskStringHeaderAt(_buffer, length, len);

    if (!_tryWriteAsciiChars(str, len)) {
      length = start;
      _writeStringUtf8Fallback(str);
    }
  }

  /// Copies [str] as ASCII. Returns false without committing [length] if any
  /// code unit is non-ASCII, so the caller can roll back the MessagePack header.
  @pragma('vm:prefer-inline')
  bool _tryWriteAsciiChars(String str, int len) {
    final b = _buffer;
    int pos = length;
    int i = 0;
    while (i + 4 <= len) {
      final int c0 = str.codeUnitAt(i);
      final int c1 = str.codeUnitAt(i + 1);
      final int c2 = str.codeUnitAt(i + 2);
      final int c3 = str.codeUnitAt(i + 3);
      if ((c0 | c1 | c2 | c3) > 0x7F) return false;
      b[pos] = c0;
      b[pos + 1] = c1;
      b[pos + 2] = c2;
      b[pos + 3] = c3;
      pos += 4;
      i += 4;
    }
    while (i < len) {
      final int c = str.codeUnitAt(i);
      if (c > 0x7F) return false;
      b[pos++] = c;
      i++;
    }
    length = pos;
    return true;
  }

  @pragma('vm:never-inline')
  void _writeStringUtf8Fallback(String str) {
    final encoded = utf8.encode(str);
    final int byteLen = encoded.length;
    if (byteLen > BinaryMapCodec.maxStringLength) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'FastWalEncoder: String length $byteLen exceeds maximum limit of ${BinaryMapCodec.maxStringLength}.',
        )
      ]);
    }

    final int headerBytes = BinaryMapCodec.onDiskStringHeaderSize(byteLen);
    ensureAvailable(headerBytes + byteLen);
    length +=
        BinaryMapCodec.writeOnDiskStringHeaderAt(_buffer, length, byteLen);
    _buffer.setRange(length, length + byteLen, encoded);
    length += byteLen;
  }

  @pragma('vm:prefer-inline')
  void writeAsciiStringFast(String str) {
    writeStringSafe(str);
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
  final Uint8List _aad;
  FastWalBuffer? _encryptBuf;

  FastWalBatchSession._(
    this._staticPrefix,
    this.partitionIndex,
    this.hasOldValues,
    this._isEncrypted,
    this._aad,
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
      FastWalEncoder._partitionAad(partitionIndex),
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
      _writePayload(buf, record, seq, oldValues);

      final int payloadLen = buf.length - payloadStart;
      final int recordLen = 9 + payloadLen;

      buf.setUint32LE(recordStart, recordLen);
      buf.setUint32LE(recordStart + 4, FastWalEncoder._walMagic);
      buf.setUint8(recordStart + 8, FastWalEncoder._walVersion);
      buf.setUint32LE(recordStart + 9, payloadLen);
    } else {
      final tempBuf = _encryptBuf ??= FastWalBuffer(capacity: 4096);
      tempBuf.reset();
      _writePayload(tempBuf, record, seq, oldValues);

      final encryptedPayload = EncryptionManager.encodeBytes(
        tempBuf.bytesView,
        aad: _aad,
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

  void _writePayload(
    FastWalBuffer buf,
    Map<String, dynamic> record,
    int seq,
    Map<String, dynamic>? oldValues,
  ) {
    buf.writeBytesFast(_staticPrefix);
    buf.writeBytesFast(FastWalEncoder._keySeq);
    buf.writeMsgpackInt(seq);
    buf.writeBytesFast(FastWalEncoder._keyData);
    FastWalEncoder._writeValue(buf, record);
    if (hasOldValues) {
      buf.writeBytesFast(FastWalEncoder._keyOldValues);
      FastWalEncoder._writeValue(buf, oldValues);
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
    final encoded = utf8.encode(name);
    final len = encoded.length;
    final headerSize = BinaryMapCodec.onDiskStringHeaderSize(len);
    final token = Uint8List(headerSize + len);
    BinaryMapCodec.writeOnDiskStringHeaderAt(token, 0, len);
    token.setRange(headerSize, headerSize + len, encoded);
    return FastWalTableField(
      name: name,
      type: type,
      keyToken: token,
    );
  }
}

/// Cached schema field layout and MessagePack map header.
class _SchemaWalFieldsDescriptor {
  final List<FastWalTableField> fields;
  final int estimatedFieldsBytes;

  const _SchemaWalFieldsDescriptor({
    required this.fields,
    required this.estimatedFieldsBytes,
  });
}

/// Ultra-fast schema-aware batch WAL encoder session.
///
/// Pre-compiles table schema field MessagePack key tokens and data envelope,
/// enabling zero-allocation, typed-dispatch serialization of structured records.
class FastWalTableSession {
  final Uint8List _staticPrefix;
  final List<FastWalTableField> _fields;
  final int partitionIndex;
  final bool hasOldValues;
  final bool _isEncrypted;
  final int _estimatedRecordBytes;
  final List<dynamic> _fieldScratch;
  final Uint8List _aad;
  FastWalBuffer? _encryptBuf;
  int get estimatedRecordBytes => _estimatedRecordBytes;

  static final Expando<_SchemaWalFieldsDescriptor> _schemaFieldsCache =
      Expando<_SchemaWalFieldsDescriptor>('FastWalSchemaFields');

  static _SchemaWalFieldsDescriptor _getOrCreateSchemaDescriptor(
      TableSchema schema) {
    final cached = _schemaFieldsCache[schema];
    if (cached != null) return cached;

    final fields = <FastWalTableField>[];
    DataType pkType = schema.primaryKeyConfig.type == PrimaryKeyType.sequential
        ? DataType.integer
        : DataType.text;
    for (final f in schema.fields) {
      if (f.name == schema.primaryKey) {
        pkType = f.type;
        break;
      }
    }
    // Primary key field first
    fields.add(FastWalTableField.create(schema.primaryKey, pkType));
    for (final f in schema.fields) {
      if (f.name != schema.primaryKey) {
        fields.add(FastWalTableField.create(f.name, f.type));
      }
    }

    final desc = _SchemaWalFieldsDescriptor(
      fields: List<FastWalTableField>.from(fields, growable: false),
      estimatedFieldsBytes: _estimateSchemaFieldsBytes(fields),
    );
    _schemaFieldsCache[schema] = desc;
    return desc;
  }

  static int _estimateSchemaFieldsBytes(List<FastWalTableField> fields) {
    int n = 0;
    for (int i = 0; i < fields.length; i++) {
      final f = fields[i];
      n += f.keyToken.length;
      switch (f.type) {
        case DataType.boolean:
          n += 1;
          break;
        case DataType.integer:
        case DataType.bigInt:
          n += 8;
          break;
        case DataType.double:
          n += 9;
          break;
        case DataType.datetime:
          n += 32;
          break;
        default:
          n += 24;
          break;
      }
    }
    return n;
  }

  FastWalTableSession._({
    required Uint8List staticPrefix,
    required List<FastWalTableField> fields,
    required this.partitionIndex,
    required this.hasOldValues,
    required bool isEncrypted,
    required int estimatedRecordBytes,
    required List<dynamic> fieldScratch,
    required Uint8List aad,
  })  : _staticPrefix = staticPrefix,
        _fields = fields,
        _isEncrypted = isEncrypted,
        _estimatedRecordBytes = estimatedRecordBytes,
        _fieldScratch = fieldScratch,
        _aad = aad;

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

    // 6. Pre-append "seq" key directly into staticPrefix
    prefixBuf.writeBytes(FastWalEncoder._keySeq);

    final descriptor = _getOrCreateSchemaDescriptor(schema);

    final isEncrypted =
        EncryptionManager.getEncryptionType() != EncryptionType.none;

    final estimatedRecordBytes =
        prefixBuf.length + 40 + descriptor.estimatedFieldsBytes;

    return FastWalTableSession._(
      staticPrefix: prefixBuf.copyCurrentBytes(),
      fields: descriptor.fields,
      partitionIndex: partitionIndex,
      hasOldValues: hasOldValues,
      isEncrypted: isEncrypted,
      estimatedRecordBytes: estimatedRecordBytes,
      fieldScratch: List<dynamic>.filled(
        descriptor.fields.length,
        null,
        growable: false,
      ),
      aad: FastWalEncoder._partitionAad(partitionIndex),
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
      if (!capacityPreReserved ||
          buf.length + _estimatedRecordBytes > buf.capacity) {
        buf.ensureAvailable(_estimatedRecordBytes);
      }

      final int recordStart = buf.length;
      buf.length += 13; // Header placeholder
      final int payloadStart = buf.length;

      _writePayload(buf, record, seq, oldValues);

      final int payloadLen = buf.length - payloadStart;
      final int recordLen = 9 + payloadLen;

      final b = buf.buffer;
      b[recordStart] = recordLen & 0xFF;
      b[recordStart + 1] = (recordLen >> 8) & 0xFF;
      b[recordStart + 2] = (recordLen >> 16) & 0xFF;
      b[recordStart + 3] = (recordLen >> 24) & 0xFF;

      b[recordStart + 4] = 0x4C; // 'L'
      b[recordStart + 5] = 0x57; // 'W'
      b[recordStart + 6] = 0x6F; // 'o'
      b[recordStart + 7] = 0x54; // 'T' -> 0x546F574C ("ToWL" LE)

      b[recordStart + 8] = 0x01; // Version 1

      b[recordStart + 9] = payloadLen & 0xFF;
      b[recordStart + 10] = (payloadLen >> 8) & 0xFF;
      b[recordStart + 11] = (payloadLen >> 16) & 0xFF;
      b[recordStart + 12] = (payloadLen >> 24) & 0xFF;
    } else {
      final tempBuf =
          _encryptBuf ??= FastWalBuffer(capacity: _estimatedRecordBytes);
      tempBuf.reset();
      _writePayload(tempBuf, record, seq, oldValues);

      final encryptedPayload = EncryptionManager.encodeBytes(
        tempBuf.bytesView,
        aad: _aad,
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
  void _writePayload(
    FastWalBuffer buf,
    Map<String, dynamic> record,
    int seq,
    Map<String, dynamic>? oldValues,
  ) {
    buf.writeBytesFast(_staticPrefix);
    buf.writeMsgpackInt(seq);
    if (!_writeSchemaData(buf, record)) {
      // Unknown keys must be preserved; generic map encoding keeps extras.
      buf.writeBytesFast(FastWalEncoder._keyData);
      FastWalEncoder._writeValue(buf, record);
    }
    if (hasOldValues) {
      buf.writeBytesFast(FastWalEncoder._keyOldValues);
      FastWalEncoder._writeValue(buf, oldValues);
    }
  }

  /// Writes the `data` map for schema fields using precompiled key tokens.
  ///
  /// Missing schema columns are omitted (same as generic map encoding) so
  /// batchInsert records that skip nullable-without-default fields stay fast.
  /// Returns false without writing if [record] contains unknown keys.
  bool _writeSchemaData(FastWalBuffer buf, Map<String, dynamic> record) {
    final fields = _fields;
    final int fCount = fields.length;
    final int recLen = record.length;
    if (recLen > fCount) return false;

    final vals = _fieldScratch;
    int foundNonNull = 0;
    for (int i = 0; i < fCount; i++) {
      final val = record[fields[i].name];
      vals[i] = val;
      if (val != null) foundNonNull++;
    }

    // Path A: Full schema match (every schema field is present in record)
    if (recLen == fCount) {
      if (foundNonNull != recLen) {
        int foundKeys = foundNonNull;
        for (int i = 0; i < fCount; i++) {
          if (vals[i] == null && record.containsKey(fields[i].name)) {
            foundKeys++;
          }
        }
        if (foundKeys != recLen) return false;
      }
      buf.writeBytesFast(FastWalEncoder._keyData);
      buf.writeMsgpackMapHeader(fCount);
      for (int i = 0; i < fCount; i++) {
        final f = fields[i];
        buf.writeTokenFast(f.keyToken);
        _writeFieldValue(buf, vals[i], f.type);
      }
      return true;
    }

    // Path B: Common batchInsert case: subset of fields, all present values non-null
    final bool omitMissing = foundNonNull == recLen;
    if (omitMissing) {
      buf.writeBytesFast(FastWalEncoder._keyData);
      buf.writeMsgpackMapHeader(recLen);
      for (int i = 0; i < fCount; i++) {
        final val = vals[i];
        if (val == null) continue;
        final f = fields[i];
        buf.writeTokenFast(f.keyToken);
        _writeFieldValue(buf, val, f.type);
      }
      return true;
    }

    // Path C: Subset of schema fields with explicit nulls
    int foundKeys = foundNonNull;
    for (int i = 0; i < fCount; i++) {
      if (vals[i] == null && record.containsKey(fields[i].name)) {
        foundKeys++;
      }
    }
    if (foundKeys != recLen) return false;

    buf.writeBytesFast(FastWalEncoder._keyData);
    buf.writeMsgpackMapHeader(recLen);
    for (int i = 0; i < fCount; i++) {
      final val = vals[i];
      if (val == null && !record.containsKey(fields[i].name)) continue;
      final f = fields[i];
      buf.writeTokenFast(f.keyToken);
      _writeFieldValue(buf, val, f.type);
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  static void _writeFieldValue(FastWalBuffer buf, dynamic val, DataType type) {
    if (val == null) {
      buf.writeUint8Fast(0xC0);
      return;
    }

    switch (type) {
      case DataType.integer:
        if (val is int) {
          buf.writeMsgpackInt(val);
          return;
        } else if (val is String) {
          buf.writeShortString(val);
          return;
        }
        break;

      case DataType.text:
        if (val is String) {
          buf.writeShortString(val);
          return;
        }
        break;

      case DataType.double:
        if (val is double) {
          buf.writeUint8Fast(0xCB);
          buf.writeFloat64BE(val);
          return;
        } else if (val is num) {
          buf.writeUint8Fast(0xCB);
          buf.writeFloat64BE(val.toDouble());
          return;
        }
        break;

      case DataType.boolean:
        if (val is bool) {
          buf.writeUint8Fast(val ? 0xC3 : 0xC2);
          return;
        }
        break;

      case DataType.datetime:
        if (val is String) {
          buf.writeShortString(val);
          return;
        } else if (val is DateTime) {
          buf.writeShortString(val.toIso8601String());
          return;
        }
        break;

      default:
        break;
    }

    FastWalEncoder._writeValue(buf, val);
  }
}
