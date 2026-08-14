import 'dart:typed_data';

import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_identity.dart';
import '../model/transaction_models.dart';
import 'binary_codec.dart';
import 'binary_map_codec.dart';
import 'binary_schema_codec.dart';
import 'encryption.dart';

/// Schema context required to encode/decode a table row in a txn plan.
class TxnTableCodecContext {
  final String primaryKeyField;
  final List<FieldStructure> fieldStructure;

  const TxnTableCodecContext({
    required this.primaryKeyField,
    required this.fieldStructure,
  });

  bool get hasSchemaSlots => fieldStructure.isNotEmpty;
}

/// One append-only transaction log record (status or plan).
class TxnLogEvent {
  final String transactionId;
  final TxnLogEventType event;
  final int timestampMs;
  final TransactionCommitPlan? plan;
  final int? nextPartitionIndex;
  final int? continuedTo;
  final Map<String, int>? insertsApplied;
  final Map<String, int>? updatesApplied;
  final Map<String, int>? deletesApplied;

  const TxnLogEvent({
    required this.transactionId,
    required this.event,
    required this.timestampMs,
    this.plan,
    this.nextPartitionIndex,
    this.continuedTo,
    this.insertsApplied,
    this.updatesApplied,
    this.deletesApplied,
  });

  factory TxnLogEvent.simple({
    required String transactionId,
    required TxnLogEventType event,
    DateTime? timestamp,
    int? nextPartitionIndex,
    int? continuedTo,
    Map<String, int>? insertsApplied,
    Map<String, int>? updatesApplied,
    Map<String, int>? deletesApplied,
    TransactionCommitPlan? plan,
  }) {
    return TxnLogEvent(
      transactionId: transactionId,
      event: event,
      timestampMs: (timestamp ?? DateTime.now()).millisecondsSinceEpoch,
      plan: plan,
      nextPartitionIndex: nextPartitionIndex,
      continuedTo: continuedTo,
      insertsApplied: insertsApplied,
      updatesApplied: updatesApplied,
      deletesApplied: deletesApplied,
    );
  }
}

/// Resolver for table schema encoding context (by tableUid / legacy name key).
typedef TxnTableCodecResolver = Future<TxnTableCodecContext?> Function(
  String tableUid,
);

/// High-performance binary encoder for transaction partition logs.
///
/// Record layout (length-prefixed on disk):
/// `[Length:4B LE][Magic:4B][Version:1B][BodyLen:4B][EncryptedBody]`
///
/// Magic: `ToTX` (0x546F5458). Body is a [BinaryWriter] tagged message;
/// table rows use [BinarySchemaCodec], sparse maps use [BinaryMapCodec].
class TxnEncoder {
  /// Magic number: "ToTX" in ASCII
  static const int txnMagic = 0x546F5458;

  /// Binary format version
  static const int txnVersion = 0x01;

  static const int _minRecordSize = 9;
  static const int maxRecordSize = 10 * 1024 * 1024; // 10MB

  // Row encoding kinds inside an op message
  static const int _rowEncodingSchema = 0;
  static const int _rowEncodingMap = 1;

  // ---- Event body field ids ----
  static const int _fEvent = 1;
  static const int _fTxId = 2;
  static const int _fTimestampMs = 3;
  static const int _fPlan = 4;
  static const int _fNextPartition = 5;
  static const int _fContinuedTo = 6;
  static const int _fInsertsApplied = 7;
  static const int _fUpdatesApplied = 8;
  static const int _fDeletesApplied = 9;

  // ---- Plan body field ids ----
  static const int _fPlanTxId = 1;
  static const int _fInserts = 2;
  static const int _fUpdates = 3;
  static const int _fDeletes = 4;
  static const int _fHeavyDeletes = 5;
  static const int _fHeavyUpdates = 6;

  // ---- Table group ----
  static const int _fTableUid = 1;
  static const int _fOp = 2;

  // ---- Op ----
  static const int _fRowEncoding = 1;
  static const int _fPk = 2;
  static const int _fRowBytes = 3;
  static const int _fUniqueKey = 4;
  static const int _fOldValues = 5;

  // ---- Unique key ----
  static const int _fIndexUid = 1;
  static const int _fCompositeKey = 2;

  // ---- Heavy delete/update ----
  static const int _fHeavyTableUid = 1;
  static const int _fCondition = 2;
  static const int _fOrderBy = 3;
  static const int _fLimit = 4;
  static const int _fOffset = 5;
  static const int _fUpdateData = 6;

  // ---- String->int map entry ----
  static const int _fMapEntry = 1;
  static const int _fMapKey = 1;
  static const int _fMapValue = 2;

  /// Quick magic check (payload without length prefix).
  static bool isBinaryFormat(Uint8List data) {
    if (data.length < 4) return false;
    return ByteData.sublistView(data).getUint32(0, Endian.little) == txnMagic;
  }

  /// Quick magic check for a length-prefixed record starting at offset 0.
  ///
  /// Prefer [isCompleteBinaryFile] when deciding whether migration can skip.
  static bool looksLikeBinaryFile(Uint8List fileBytes) {
    if (fileBytes.length < 8) return false;
    final len =
        ByteData.sublistView(fileBytes, 0, 4).getUint32(0, Endian.little);
    if (len < _minRecordSize || len > maxRecordSize) return false;
    if (4 + len > fileBytes.length) return false;
    return ByteData.sublistView(fileBytes, 4, 8).getUint32(0, Endian.little) ==
        txnMagic;
  }

  /// True when every byte is consumed by valid ToTX length-prefixed records.
  ///
  /// Returns false for truncated or mixed JSON/binary files so migration can
  /// rewrite instead of skipping a half-written log.
  static bool isCompleteBinaryFile(Uint8List fileBytes) {
    if (fileBytes.isEmpty) return true;
    int offset = 0;
    while (offset < fileBytes.length) {
      if (offset + 4 > fileBytes.length) return false;
      final recordLength = ByteData.sublistView(fileBytes, offset, offset + 4)
          .getUint32(0, Endian.little);
      if (recordLength < _minRecordSize ||
          recordLength > maxRecordSize ||
          offset + 4 + recordLength > fileBytes.length) {
        return false;
      }
      final magic = ByteData.sublistView(fileBytes, offset + 4, offset + 8)
          .getUint32(0, Endian.little);
      if (magic != txnMagic) return false;
      offset += 4 + recordLength;
    }
    return offset == fileBytes.length;
  }

  /// Encode event as length-prefixed disk record.
  static Future<Uint8List> encodeAsRecord(
    TxnLogEvent event,
    int partitionIndex, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    final entry =
        await encode(event, partitionIndex, resolveTable: resolveTable);
    final result = Uint8List(4 + entry.length);
    ByteData.sublistView(result, 0, 4)
        .setUint32(0, entry.length, Endian.little);
    result.setAll(4, entry);
    return result;
  }

  /// Encode event (without outer length prefix).
  static Future<Uint8List> encode(
    TxnLogEvent event,
    int partitionIndex, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    final body = await _encodeBody(event, resolveTable: resolveTable);

    final aadData = ByteData(4);
    aadData.setInt32(0, partitionIndex, Endian.little);
    final encrypted =
        EncryptionManager.encodeBytes(body, aad: aadData.buffer.asUint8List());

    final header = ByteData(9);
    header.setUint32(0, txnMagic, Endian.little);
    header.setUint8(4, txnVersion);
    header.setUint32(5, encrypted.length, Endian.little);

    final result = Uint8List(9 + encrypted.length);
    result.setAll(0, header.buffer.asUint8List());
    result.setAll(9, encrypted);
    return result;
  }

  /// Decode all length-prefixed records from a file.
  static Future<List<TxnLogEvent>> decodeFile(
    Uint8List fileBytes,
    int partitionIndex, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    final events = <TxnLogEvent>[];
    int offset = 0;
    while (offset < fileBytes.length) {
      if (offset + 4 > fileBytes.length) break;
      final recordLength = ByteData.sublistView(fileBytes, offset, offset + 4)
          .getUint32(0, Endian.little);
      offset += 4;
      if (recordLength == 0 ||
          recordLength > maxRecordSize ||
          offset + recordLength > fileBytes.length) {
        break;
      }
      final recordData =
          Uint8List.sublistView(fileBytes, offset, offset + recordLength);
      offset += recordLength;
      try {
        final ev = await decodeSingle(recordData, partitionIndex,
            resolveTable: resolveTable);
        if (ev != null) events.add(ev);
      } on DbException {
        rethrow;
      } catch (_) {
        continue;
      }
    }
    return events;
  }

  /// Decode a single record (payload without length prefix).
  static Future<TxnLogEvent?> decodeSingle(
    Uint8List data,
    int partitionIndex, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    if (data.length < 9) return null;
    final header = ByteData.sublistView(data, 0, 9);
    if (header.getUint32(0, Endian.little) != txnMagic) return null;
    if (header.getUint8(4) != txnVersion) return null;
    final dataLen = header.getUint32(5, Endian.little);
    if (data.length < 9 + dataLen) return null;

    final encryptedData = Uint8List.sublistView(data, 9, 9 + dataLen);
    final aadData = ByteData(4);
    aadData.setInt32(0, partitionIndex, Endian.little);
    final decrypted = EncryptionManager.decodeBytes(
      encryptedData,
      aad: aadData.buffer.asUint8List(),
    );
    return _decodeBody(decrypted, resolveTable: resolveTable);
  }

  // ---------------------------------------------------------------------------
  // Body encode / decode
  // ---------------------------------------------------------------------------

  static Future<Uint8List> _encodeBody(
    TxnLogEvent event, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    final w = BinaryWriter(initialCapacity: 512);
    w.writeFieldTag(_fEvent, WireType.varint);
    w.writeVarint(event.event.wireId);
    w.writeFieldTag(_fTxId, WireType.lengthDelimited);
    w.writeString(event.transactionId);
    w.writeFieldTag(_fTimestampMs, WireType.fixed64);
    w.writeFixed64(event.timestampMs);

    if (event.plan != null) {
      final planBytes =
          await _encodePlan(event.plan!, resolveTable: resolveTable);
      w.writeFieldTag(_fPlan, WireType.lengthDelimited);
      w.writeBytes(planBytes);
    }
    if (event.nextPartitionIndex != null) {
      w.writeFieldTag(_fNextPartition, WireType.varint);
      w.writeVarint(event.nextPartitionIndex!);
    }
    if (event.continuedTo != null) {
      w.writeFieldTag(_fContinuedTo, WireType.varint);
      w.writeVarint(event.continuedTo!);
    }
    if (event.insertsApplied != null && event.insertsApplied!.isNotEmpty) {
      w.writeFieldTag(_fInsertsApplied, WireType.lengthDelimited);
      w.writeBytes(_encodeStringIntMap(event.insertsApplied!));
    }
    if (event.updatesApplied != null && event.updatesApplied!.isNotEmpty) {
      w.writeFieldTag(_fUpdatesApplied, WireType.lengthDelimited);
      w.writeBytes(_encodeStringIntMap(event.updatesApplied!));
    }
    if (event.deletesApplied != null && event.deletesApplied!.isNotEmpty) {
      w.writeFieldTag(_fDeletesApplied, WireType.lengthDelimited);
      w.writeBytes(_encodeStringIntMap(event.deletesApplied!));
    }
    return Uint8List.fromList(w.view);
  }

  static Future<TxnLogEvent?> _decodeBody(
    Uint8List body, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    final r = BinaryReader(body);
    TxnLogEventType? event;
    String? txId;
    int timestampMs = 0;
    TransactionCommitPlan? plan;
    int? nextPartitionIndex;
    int? continuedTo;
    Map<String, int>? insertsApplied;
    Map<String, int>? updatesApplied;
    Map<String, int>? deletesApplied;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case _fEvent:
          event = TxnLogEventType.fromWireId(r.readVarint());
          break;
        case _fTxId:
          txId = r.readString();
          break;
        case _fTimestampMs:
          timestampMs = r.readFixed64();
          break;
        case _fPlan:
          final planBytes = r.readBytes();
          plan = await _decodePlan(planBytes, resolveTable: resolveTable);
          break;
        case _fNextPartition:
          nextPartitionIndex = r.readVarint();
          break;
        case _fContinuedTo:
          continuedTo = r.readVarint();
          break;
        case _fInsertsApplied:
          insertsApplied = _decodeStringIntMap(r.readBytes());
          break;
        case _fUpdatesApplied:
          updatesApplied = _decodeStringIntMap(r.readBytes());
          break;
        case _fDeletesApplied:
          deletesApplied = _decodeStringIntMap(r.readBytes());
          break;
        default:
          r.skipField(wireType);
      }
    }

    if (event == null || txId == null) return null;
    return TxnLogEvent(
      transactionId: txId,
      event: event,
      timestampMs: timestampMs,
      plan: plan,
      nextPartitionIndex: nextPartitionIndex,
      continuedTo: continuedTo,
      insertsApplied: insertsApplied,
      updatesApplied: updatesApplied,
      deletesApplied: deletesApplied,
    );
  }

  static Future<Uint8List> _encodePlan(
    TransactionCommitPlan plan, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    final w = BinaryWriter(initialCapacity: 1024);
    w.writeFieldTag(_fPlanTxId, WireType.lengthDelimited);
    w.writeString(plan.transactionId);

    for (final e in plan.inserts.entries) {
      final group =
          await _encodeTableGroup(e.key, e.value, resolveTable: resolveTable);
      w.writeFieldTag(_fInserts, WireType.lengthDelimited);
      w.writeBytes(group);
    }
    for (final e in plan.updates.entries) {
      final group =
          await _encodeTableGroup(e.key, e.value, resolveTable: resolveTable);
      w.writeFieldTag(_fUpdates, WireType.lengthDelimited);
      w.writeBytes(group);
    }
    for (final e in plan.deletes.entries) {
      final group =
          await _encodeTableGroup(e.key, e.value, resolveTable: resolveTable);
      w.writeFieldTag(_fDeletes, WireType.lengthDelimited);
      w.writeBytes(group);
    }
    for (final hd in plan.heavyDeletes) {
      w.writeFieldTag(_fHeavyDeletes, WireType.lengthDelimited);
      w.writeBytes(_encodeHeavyDelete(hd));
    }
    for (final hu in plan.heavyUpdates) {
      w.writeFieldTag(_fHeavyUpdates, WireType.lengthDelimited);
      w.writeBytes(_encodeHeavyUpdate(hu));
    }
    return Uint8List.fromList(w.view);
  }

  static Future<TransactionCommitPlan?> _decodePlan(
    Uint8List data, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    final r = BinaryReader(data);
    String? txId;
    final inserts = <String, List<Map<String, dynamic>>>{};
    final updates = <String, List<Map<String, dynamic>>>{};
    final deletes = <String, List<Map<String, dynamic>>>{};
    final heavyDeletes = <HeavyDeletePlan>[];
    final heavyUpdates = <HeavyUpdatePlan>[];

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case _fPlanTxId:
          txId = r.readString();
          break;
        case _fInserts:
          final g = await _decodeTableGroup(r.readBytes(),
              resolveTable: resolveTable);
          if (g != null) {
            inserts.putIfAbsent(g.$1, () => []).addAll(g.$2);
          }
          break;
        case _fUpdates:
          final g = await _decodeTableGroup(r.readBytes(),
              resolveTable: resolveTable);
          if (g != null) {
            updates.putIfAbsent(g.$1, () => []).addAll(g.$2);
          }
          break;
        case _fDeletes:
          final g = await _decodeTableGroup(r.readBytes(),
              resolveTable: resolveTable);
          if (g != null) {
            deletes.putIfAbsent(g.$1, () => []).addAll(g.$2);
          }
          break;
        case _fHeavyDeletes:
          final hd = _decodeHeavyDelete(r.readBytes());
          if (hd != null) heavyDeletes.add(hd);
          break;
        case _fHeavyUpdates:
          final hu = _decodeHeavyUpdate(r.readBytes());
          if (hu != null) heavyUpdates.add(hu);
          break;
        default:
          r.skipField(wireType);
      }
    }

    if (txId == null) return null;
    return TransactionCommitPlan(
      transactionId: txId,
      inserts: inserts,
      updates: updates,
      deletes: deletes,
      heavyDeletes: heavyDeletes,
      heavyUpdates: heavyUpdates,
    );
  }

  static Future<Uint8List> _encodeTableGroup(
    String tableUid,
    List<Map<String, dynamic>> records, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    final ctx = await resolveTable(tableUid);
    final w = BinaryWriter(initialCapacity: 256);
    w.writeFieldTag(_fTableUid, WireType.lengthDelimited);
    w.writeString(tableUid);
    for (final rec in records) {
      w.writeFieldTag(_fOp, WireType.lengthDelimited);
      w.writeBytes(_encodeOp(rec, ctx));
    }
    return Uint8List.fromList(w.view);
  }

  static Future<(String, List<Map<String, dynamic>>)?> _decodeTableGroup(
    Uint8List data, {
    required TxnTableCodecResolver resolveTable,
  }) async {
    final r = BinaryReader(data);
    String? tableUid;
    final opsBytes = <Uint8List>[];
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case _fTableUid:
          tableUid = r.readString();
          break;
        case _fOp:
          opsBytes.add(Uint8List.fromList(r.readBytes()));
          break;
        default:
          r.skipField(wireType);
      }
    }
    if (tableUid == null) return null;
    final ctx = await resolveTable(tableUid);
    final records = <Map<String, dynamic>>[];
    for (final opBytes in opsBytes) {
      final rec = _decodeOp(opBytes, ctx);
      if (rec != null) records.add(rec);
    }
    return (tableUid, records);
  }

  static Uint8List _encodeOp(
    Map<String, dynamic> record,
    TxnTableCodecContext? ctx,
  ) {
    // One ownership copy to strip meta keys without mutating caller's map.
    final rec = Map<String, dynamic>.from(record);
    final uniqueKeys = rec.remove('_uniqueKeys');
    final oldValues = rec.remove('_oldValues');

    final w = BinaryWriter(initialCapacity: 128);
    final pkName = ctx?.primaryKeyField ?? 'id';
    final pk = rec[pkName];

    if (ctx != null && ctx.hasSchemaSlots) {
      // Nullify PK in encode (stored separately) -- no second Map.from.
      final rowBytes = BinarySchemaCodec.encodeRecord(
        rec,
        ctx.fieldStructure,
        nullifyField: pkName,
      );
      w.writeFieldTag(_fRowEncoding, WireType.varint);
      w.writeVarint(_rowEncodingSchema);
      w.writeFieldTag(_fPk, WireType.lengthDelimited);
      w.writeBytes(BinaryMapCodec.encodeValue(pk));
      w.writeFieldTag(_fRowBytes, WireType.lengthDelimited);
      w.writeBytes(rowBytes);
    } else {
      w.writeFieldTag(_fRowEncoding, WireType.varint);
      w.writeVarint(_rowEncodingMap);
      w.writeFieldTag(_fPk, WireType.lengthDelimited);
      w.writeBytes(BinaryMapCodec.encodeValue(pk));
      w.writeFieldTag(_fRowBytes, WireType.lengthDelimited);
      w.writeBytes(BinaryMapCodec.encodeMap(rec));
    }

    if (uniqueKeys is List && uniqueKeys.isNotEmpty) {
      for (final uk in uniqueKeys) {
        if (uk is! Map) continue;
        final map = uk.cast<String, dynamic>();
        w.writeFieldTag(_fUniqueKey, WireType.lengthDelimited);
        w.writeBytes(_encodeUniqueKey(map));
      }
    }

    if (oldValues is Map<String, dynamic>) {
      w.writeFieldTag(_fOldValues, WireType.lengthDelimited);
      // encodeMap is read-only -- no defensive copy.
      w.writeBytes(BinaryMapCodec.encodeMap(oldValues));
    } else if (oldValues is Map) {
      w.writeFieldTag(_fOldValues, WireType.lengthDelimited);
      w.writeBytes(
          BinaryMapCodec.encodeMap(Map<String, dynamic>.from(oldValues)));
    }

    return Uint8List.fromList(w.view);
  }

  static Map<String, dynamic>? _decodeOp(
    Uint8List data,
    TxnTableCodecContext? ctx,
  ) {
    final r = BinaryReader(data);
    int rowEncoding = _rowEncodingMap;
    dynamic pk;
    Uint8List? rowBytes;
    final uniqueKeys = <Map<String, dynamic>>[];
    Map<String, dynamic>? oldValues;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case _fRowEncoding:
          rowEncoding = r.readVarint();
          break;
        case _fPk:
          pk = BinaryMapCodec.decodeValue(r.readBytes());
          break;
        case _fRowBytes:
          rowBytes = Uint8List.fromList(r.readBytes());
          break;
        case _fUniqueKey:
          final uk = _decodeUniqueKey(r.readBytes());
          if (uk != null) uniqueKeys.add(uk);
          break;
        case _fOldValues:
          oldValues = BinaryMapCodec.decodeMap(r.readBytes());
          break;
        default:
          r.skipField(wireType);
      }
    }

    if (rowBytes == null) return null;

    Map<String, dynamic> record;
    if (rowEncoding == _rowEncodingSchema) {
      // Fail closed: never reinterpret schema payloads as MessagePack maps.
      if (ctx == null || !ctx.hasSchemaSlots) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysInvalidDataFormat,
            message:
                'Missing FieldStructure for schema-encoded txn row (pk=$pk)',
          ),
        ]);
      }
      final decoded =
          BinarySchemaCodec.decodeRecord(rowBytes, ctx.fieldStructure);
      if (decoded == null) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysInvalidDataFormat,
            message:
                'Failed to decode schema-encoded txn row (pk=$pk, fields=${ctx.fieldStructure.length})',
          ),
        ]);
      }
      record = Map<String, dynamic>.from(decoded);
      record[ctx.primaryKeyField] = pk;
    } else {
      final decoded = BinaryMapCodec.decodeMap(rowBytes);
      if (decoded == null) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysInvalidDataFormat,
            message: 'Failed to decode map-encoded txn row',
          ),
        ]);
      }
      record = Map<String, dynamic>.from(decoded);
      final pkName = ctx?.primaryKeyField;
      if (pkName != null && pk != null && !record.containsKey(pkName)) {
        record[pkName] = pk;
      }
    }

    if (uniqueKeys.isNotEmpty) {
      record['_uniqueKeys'] = uniqueKeys;
    }
    if (oldValues != null) {
      record['_oldValues'] = oldValues;
    }
    return record;
  }

  static Uint8List _encodeUniqueKey(Map<String, dynamic> uk) {
    final w = BinaryWriter(initialCapacity: 64);
    final indexUid = (uk['indexUid'] ?? uk['indexName'] ?? '').toString();
    w.writeFieldTag(_fIndexUid, WireType.lengthDelimited);
    w.writeString(indexUid);
    w.writeFieldTag(_fCompositeKey, WireType.lengthDelimited);
    w.writeBytes(BinaryMapCodec.encodeValue(uk['compositeKey']));
    return Uint8List.fromList(w.view);
  }

  static Map<String, dynamic>? _decodeUniqueKey(Uint8List data) {
    final r = BinaryReader(data);
    String? indexUid;
    dynamic compositeKey;
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case _fIndexUid:
          indexUid = r.readString();
          break;
        case _fCompositeKey:
          compositeKey = BinaryMapCodec.decodeValue(r.readBytes());
          break;
        default:
          r.skipField(wireType);
      }
    }
    if (indexUid == null) return null;
    return {
      'indexUid': indexUid,
      'compositeKey': compositeKey,
    };
  }

  static Uint8List _encodeHeavyDelete(HeavyDeletePlan hd) {
    final w = BinaryWriter(initialCapacity: 128);
    w.writeFieldTag(_fHeavyTableUid, WireType.lengthDelimited);
    w.writeString(hd.tableUid.value);
    w.writeFieldTag(_fCondition, WireType.lengthDelimited);
    w.writeBytes(BinaryMapCodec.encodeMap(hd.condition));
    if (hd.orderBy != null) {
      for (final col in hd.orderBy!) {
        w.writeFieldTag(_fOrderBy, WireType.lengthDelimited);
        w.writeString(col);
      }
    }
    if (hd.limit != null) {
      w.writeFieldTag(_fLimit, WireType.varint);
      w.writeZigZag64(hd.limit!);
    }
    if (hd.offset != null) {
      w.writeFieldTag(_fOffset, WireType.varint);
      w.writeZigZag64(hd.offset!);
    }
    return Uint8List.fromList(w.view);
  }

  static HeavyDeletePlan? _decodeHeavyDelete(Uint8List data) {
    final r = BinaryReader(data);
    String? tableUid;
    Map<String, dynamic>? condition;
    final orderBy = <String>[];
    int? limit;
    int? offset;
    bool hasLimit = false;
    bool hasOffset = false;
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case _fHeavyTableUid:
          tableUid = r.readString();
          break;
        case _fCondition:
          condition = BinaryMapCodec.decodeMap(r.readBytes());
          break;
        case _fOrderBy:
          orderBy.add(r.readString());
          break;
        case _fLimit:
          limit = r.readZigZag64();
          hasLimit = true;
          break;
        case _fOffset:
          offset = r.readZigZag64();
          hasOffset = true;
          break;
        default:
          r.skipField(wireType);
      }
    }
    if (tableUid == null || condition == null) return null;
    return HeavyDeletePlan(
      tableUid: TableUid(tableUid),
      condition: condition,
      orderBy: orderBy.isEmpty ? null : orderBy,
      limit: hasLimit ? limit : null,
      offset: hasOffset ? offset : null,
    );
  }

  static Uint8List _encodeHeavyUpdate(HeavyUpdatePlan hu) {
    final w = BinaryWriter(initialCapacity: 128);
    w.writeFieldTag(_fHeavyTableUid, WireType.lengthDelimited);
    w.writeString(hu.tableUid.value);
    w.writeFieldTag(_fCondition, WireType.lengthDelimited);
    w.writeBytes(BinaryMapCodec.encodeMap(hu.condition));
    w.writeFieldTag(_fUpdateData, WireType.lengthDelimited);
    w.writeBytes(BinaryMapCodec.encodeMap(hu.updateData));
    if (hu.orderBy != null) {
      for (final col in hu.orderBy!) {
        w.writeFieldTag(_fOrderBy, WireType.lengthDelimited);
        w.writeString(col);
      }
    }
    if (hu.limit != null) {
      w.writeFieldTag(_fLimit, WireType.varint);
      w.writeZigZag64(hu.limit!);
    }
    if (hu.offset != null) {
      w.writeFieldTag(_fOffset, WireType.varint);
      w.writeZigZag64(hu.offset!);
    }
    return Uint8List.fromList(w.view);
  }

  static HeavyUpdatePlan? _decodeHeavyUpdate(Uint8List data) {
    final r = BinaryReader(data);
    String? tableUid;
    Map<String, dynamic>? condition;
    Map<String, dynamic>? updateData;
    final orderBy = <String>[];
    int? limit;
    int? offset;
    bool hasLimit = false;
    bool hasOffset = false;
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case _fHeavyTableUid:
          tableUid = r.readString();
          break;
        case _fCondition:
          condition = BinaryMapCodec.decodeMap(r.readBytes());
          break;
        case _fUpdateData:
          updateData = BinaryMapCodec.decodeMap(r.readBytes());
          break;
        case _fOrderBy:
          orderBy.add(r.readString());
          break;
        case _fLimit:
          limit = r.readZigZag64();
          hasLimit = true;
          break;
        case _fOffset:
          offset = r.readZigZag64();
          hasOffset = true;
          break;
        default:
          r.skipField(wireType);
      }
    }
    if (tableUid == null || condition == null || updateData == null) {
      return null;
    }
    return HeavyUpdatePlan(
      tableUid: TableUid(tableUid),
      condition: condition,
      updateData: updateData,
      orderBy: orderBy.isEmpty ? null : orderBy,
      limit: hasLimit ? limit : null,
      offset: hasOffset ? offset : null,
    );
  }

  static Uint8List _encodeStringIntMap(Map<String, int> map) {
    final w = BinaryWriter(initialCapacity: 64);
    for (final e in map.entries) {
      w.writeMessage(_fMapEntry, (sub) {
        sub.writeFieldTag(_fMapKey, WireType.lengthDelimited);
        sub.writeString(e.key);
        sub.writeFieldTag(_fMapValue, WireType.varint);
        sub.writeVarint(e.value);
      });
    }
    return Uint8List.fromList(w.view);
  }

  static Map<String, int> _decodeStringIntMap(Uint8List data) {
    final r = BinaryReader(data);
    final out = <String, int>{};
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      if (fieldId != _fMapEntry) {
        r.skipField(wireType);
        continue;
      }
      r.readMessage((sub, _) {
        String? key;
        int? value;
        while (!sub.isEOF) {
          final (fid, wt) = sub.readFieldTag();
          switch (fid) {
            case _fMapKey:
              key = sub.readString();
              break;
            case _fMapValue:
              value = sub.readVarint();
              break;
            default:
              sub.skipField(wt);
          }
        }
        if (key != null && value != null) {
          out[key] = value;
        }
      });
    }
    return out;
  }
}
