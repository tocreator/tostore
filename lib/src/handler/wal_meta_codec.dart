import 'dart:typed_data';

import '../core/wal_manager.dart';
import '../model/data_store_config.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/table_identity.dart';
import '../model/table_op_meta.dart';
import '../model/wal_pointer.dart';
import 'binary_codec.dart';
import 'binary_map_codec.dart';
import 'meta_file_codec.dart';

/// Stable field IDs for [WalMeta] binary encoding. Never reuse IDs.
abstract final class WalMetaFieldId {
  static const int checkpoint = 1;
  static const int existingStartPartitionIndex = 2;
  static const int existingEndPartitionIndex = 3;
  static const int pendingBatches = 4;
  static const int largeDeletes = 5;
  static const int largeUpdates = 6;
  static const int tableOps = 7;
  static const int directoryMapping = 8;
  static const int lastRecoveredPointer = 9;
  static const int lastRecoveredTailFileSize = 10;
  // Reserved 20--31 for future top-level fields.
}

abstract final class WalPointerFieldId {
  static const int partitionIndex = 1;
  static const int entrySeq = 2;
}

abstract final class PendingBatchFieldId {
  static const int batchId = 1;
  static const int batchType = 2;
  static const int start = 3;
  static const int end = 4;
  static const int tablePlans = 5;
  static const int createdAt = 6;
}

abstract final class BatchTablePlanEntryFieldId {
  static const int tableUid = 1;
  static const int plan = 2;
}

abstract final class BatchTablePlanFieldId {
  static const int willUpdateTableDataMeta = 1;
  static const int indexes = 2;
  static const int willUpdateIndexMeta = 3;
  static const int baseTotalRecordCount = 4;
  static const int baseTotalSizeBytes = 5;
  static const int baseIndexTotalEntryCount = 6;
  static const int baseIndexTotalSizeBytes = 7;
}

abstract final class IndexIntEntryFieldId {
  static const int indexUid = 1;
  static const int value = 2;
}

abstract final class LargeDeleteFieldId {
  static const int opId = 1;
  static const int tableUid = 2;
  static const int spaceName = 3;
  static const int condition = 4;
  static const int orderBy = 5;
  static const int limit = 6;
  static const int offset = 7;
  static const int checkpointCursor = 8;
  static const int deletedSoFar = 9;
  static const int status = 10;
  static const int createdAt = 11;
}

abstract final class LargeUpdateFieldId {
  static const int opId = 1;
  static const int tableUid = 2;
  static const int spaceName = 3;
  static const int condition = 4;
  static const int updateData = 5;
  static const int orderBy = 6;
  static const int limit = 7;
  static const int offset = 8;
  static const int checkpointCursor = 9;
  static const int updatedSoFar = 10;
  static const int status = 11;
  static const int createdAt = 12;
  static const int continueOnPartialErrors = 13;
}

abstract final class TableOpFieldId {
  static const int opId = 1;
  static const int tableUid = 2;
  static const int type = 3;
  static const int cutoff = 4;
  static const int createdAt = 5;
  static const int completed = 6;
}

abstract final class DirectoryMappingFieldId {
  static const int partitionToDir = 1;
  static const int dirToFileCount = 2;
}

abstract final class IntPairFieldId {
  static const int key = 1;
  static const int value = 2;
}

/// Field-tag + TOBF codec for [WalMeta].
final class WalMetaCodec {
  WalMetaCodec._();

  static const int _batchTypeFlush = 0;
  static const int _batchTypeMaintenance = 1;

  /// Encode domain model to field-tag payload (no outer frame).
  static Uint8List encodePayload(WalMeta meta) {
    final w = BinaryWriter(initialCapacity: 256);
    w.writeMessage(WalMetaFieldId.checkpoint, (sw) {
      _writeWalPointer(sw, meta.checkpoint);
    });

    w.writeFieldTag(
        WalMetaFieldId.existingStartPartitionIndex, WireType.varint);
    w.writeZigZag64(meta.existingStartPartitionIndex);
    w.writeFieldTag(WalMetaFieldId.existingEndPartitionIndex, WireType.varint);
    w.writeZigZag64(meta.existingEndPartitionIndex);

    for (final batch in meta.pendingBatches) {
      w.writeMessage(WalMetaFieldId.pendingBatches, (sw) {
        _writePendingBatch(sw, batch);
      });
    }
    for (final op in meta.largeDeletes.values) {
      w.writeMessage(WalMetaFieldId.largeDeletes, (sw) {
        _writeLargeDelete(sw, op);
      });
    }
    for (final op in meta.largeUpdates.values) {
      w.writeMessage(WalMetaFieldId.largeUpdates, (sw) {
        _writeLargeUpdate(sw, op);
      });
    }
    for (final op in meta.tableOps.values) {
      w.writeMessage(WalMetaFieldId.tableOps, (sw) {
        _writeTableOp(sw, op);
      });
    }

    if (meta.directoryMapping != null) {
      w.writeMessage(WalMetaFieldId.directoryMapping, (sw) {
        _writeDirectoryMapping(sw, meta.directoryMapping!);
      });
    }
    if (meta.lastRecoveredPointer != null) {
      w.writeMessage(WalMetaFieldId.lastRecoveredPointer, (sw) {
        _writeWalPointer(sw, meta.lastRecoveredPointer!);
      });
    }
    if (meta.lastRecoveredTailFileSize != null) {
      w.writeFieldTag(
          WalMetaFieldId.lastRecoveredTailFileSize, WireType.varint);
      w.writeVarint(meta.lastRecoveredTailFileSize!);
    }
    return w.view;
  }

  /// Decode field-tag payload into [WalMeta].
  static WalMeta decodePayload(Uint8List bytes) {
    if (bytes.isEmpty) {
      return WalMeta.initial(startPartitionIndex: 0);
    }

    final r = BinaryReader(bytes);
    WalPointer checkpoint = const WalPointer(partitionIndex: 0, entrySeq: 0);
    var existingStart = -1;
    var existingEnd = -1;
    final pendingBatches = <PendingParallelBatch>[];
    final largeDeletes = <String, LargeDeleteMeta>{};
    final largeUpdates = <String, LargeUpdateMeta>{};
    final tableOps = <String, TableOpMeta>{};
    DirectoryMapping? directoryMapping;
    WalPointer? lastRecoveredPointer;
    int? lastRecoveredTailFileSize;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case WalMetaFieldId.checkpoint:
          r.readMessage((sr, _) {
            checkpoint = _readWalPointer(sr);
          });
          break;
        case WalMetaFieldId.existingStartPartitionIndex:
          existingStart = r.readZigZag64();
          break;
        case WalMetaFieldId.existingEndPartitionIndex:
          existingEnd = r.readZigZag64();
          break;
        case WalMetaFieldId.pendingBatches:
          r.readMessage((sr, _) {
            pendingBatches.add(_readPendingBatch(sr));
          });
          break;
        case WalMetaFieldId.largeDeletes:
          r.readMessage((sr, _) {
            final op = _readLargeDelete(sr);
            if (op.opId.isNotEmpty) largeDeletes[op.opId] = op;
          });
          break;
        case WalMetaFieldId.largeUpdates:
          r.readMessage((sr, _) {
            final op = _readLargeUpdate(sr);
            if (op.opId.isNotEmpty) largeUpdates[op.opId] = op;
          });
          break;
        case WalMetaFieldId.tableOps:
          r.readMessage((sr, _) {
            final op = _readTableOp(sr);
            if (op.opId.isNotEmpty) tableOps[op.opId] = op;
          });
          break;
        case WalMetaFieldId.directoryMapping:
          r.readMessage((sr, _) {
            directoryMapping = _readDirectoryMapping(sr);
          });
          break;
        case WalMetaFieldId.lastRecoveredPointer:
          r.readMessage((sr, _) {
            lastRecoveredPointer = _readWalPointer(sr);
          });
          break;
        case WalMetaFieldId.lastRecoveredTailFileSize:
          lastRecoveredTailFileSize = r.readVarint();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return WalMeta(
      checkpoint: checkpoint,
      existingStartPartitionIndex: existingStart,
      existingEndPartitionIndex: existingEnd,
      pendingBatches: pendingBatches,
      largeDeletes: largeDeletes,
      largeUpdates: largeUpdates,
      tableOps: tableOps,
      directoryMapping: directoryMapping,
      lastRecoveredPointer: lastRecoveredPointer,
      lastRecoveredTailFileSize: lastRecoveredTailFileSize,
    );
  }

  /// Encode full on-disk file bytes (TOBF +/- EncryptionManager).
  static Uint8List encodeFile(
    WalMeta meta, {
    required EncryptionConfig? encryptionConfig,
  }) {
    final encrypt = MetaFileCodec.shouldEncrypt(encryptionConfig);
    return MetaFileCodec.encodeFile(
      encodePayload(meta),
      encrypt: encrypt,
      aad: MetaFileCodec.walMetaAad,
    );
  }

  /// Decode full on-disk file bytes.
  static WalMeta decodeFile(Uint8List frameBytes) {
    return decodePayload(
      MetaFileCodec.decodeFile(frameBytes, aad: MetaFileCodec.walMetaAad),
    );
  }

  static void _writeWalPointer(BinaryWriter w, WalPointer p) {
    w.writeFieldTag(WalPointerFieldId.partitionIndex, WireType.varint);
    w.writeZigZag64(p.partitionIndex);
    w.writeFieldTag(WalPointerFieldId.entrySeq, WireType.varint);
    w.writeZigZag64(p.entrySeq);
  }

  static WalPointer _readWalPointer(BinaryReader r) {
    var partitionIndex = 0;
    var entrySeq = 0;
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case WalPointerFieldId.partitionIndex:
          partitionIndex = r.readZigZag64();
          break;
        case WalPointerFieldId.entrySeq:
          entrySeq = r.readZigZag64();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return WalPointer(partitionIndex: partitionIndex, entrySeq: entrySeq);
  }

  static void _writePendingBatch(BinaryWriter w, PendingParallelBatch batch) {
    w.writeFieldTag(PendingBatchFieldId.batchId, WireType.lengthDelimited);
    w.writeString(batch.batchId);
    w.writeFieldTag(PendingBatchFieldId.batchType, WireType.varint);
    w.writeVarint(batch.batchType == BatchType.maintenance
        ? _batchTypeMaintenance
        : _batchTypeFlush);
    w.writeMessage(PendingBatchFieldId.start, (sw) {
      _writeWalPointer(sw, batch.start);
    });
    w.writeMessage(PendingBatchFieldId.end, (sw) {
      _writeWalPointer(sw, batch.end);
    });
    for (final e in batch.tablePlans.entries) {
      w.writeMessage(PendingBatchFieldId.tablePlans, (sw) {
        sw.writeFieldTag(
            BatchTablePlanEntryFieldId.tableUid, WireType.lengthDelimited);
        sw.writeString(e.key.value);
        sw.writeMessage(BatchTablePlanEntryFieldId.plan, (pw) {
          _writeBatchTablePlan(pw, e.value);
        });
      });
    }
    w.writeFieldTag(PendingBatchFieldId.createdAt, WireType.lengthDelimited);
    w.writeString(batch.createdAt);
  }

  static PendingParallelBatch _readPendingBatch(BinaryReader r) {
    var batchId = '';
    var batchType = BatchType.flush;
    var start = const WalPointer(partitionIndex: -1, entrySeq: -1);
    var end = const WalPointer(partitionIndex: -1, entrySeq: -1);
    final tablePlans = <TableUid, BatchTablePlan>{};
    var createdAt = '';

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case PendingBatchFieldId.batchId:
          batchId = r.readString();
          break;
        case PendingBatchFieldId.batchType:
          batchType = r.readVarint() == _batchTypeMaintenance
              ? BatchType.maintenance
              : BatchType.flush;
          break;
        case PendingBatchFieldId.start:
          r.readMessage((sr, _) {
            start = _readWalPointer(sr);
          });
          break;
        case PendingBatchFieldId.end:
          r.readMessage((sr, _) {
            end = _readWalPointer(sr);
          });
          break;
        case PendingBatchFieldId.tablePlans:
          r.readMessage((sr, _) {
            TableUid? tableUid;
            BatchTablePlan? plan;
            while (!sr.isEOF) {
              final (fid, wt) = sr.readFieldTag();
              switch (fid) {
                case BatchTablePlanEntryFieldId.tableUid:
                  tableUid = TableUid(sr.readString());
                  break;
                case BatchTablePlanEntryFieldId.plan:
                  sr.readMessage((pr, _) {
                    plan = _readBatchTablePlan(pr);
                  });
                  break;
                default:
                  sr.skipField(wt);
                  break;
              }
            }
            if (tableUid != null && tableUid.isNotEmpty && plan != null) {
              tablePlans[tableUid] = plan!;
            }
          });
          break;
        case PendingBatchFieldId.createdAt:
          createdAt = r.readString();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    if (createdAt.isEmpty) {
      createdAt = DateTime.now().toIso8601String();
    }

    return PendingParallelBatch(
      batchId: batchId,
      batchType: batchType,
      start: start,
      end: end,
      tablePlans: tablePlans,
      createdAt: createdAt,
    );
  }

  static void _writeBatchTablePlan(BinaryWriter w, BatchTablePlan plan) {
    w.writeFieldTag(
        BatchTablePlanFieldId.willUpdateTableDataMeta, WireType.varint);
    w.writeBool(plan.willUpdateTableDataMeta);
    for (final idx in plan.indexes) {
      w.writeFieldTag(BatchTablePlanFieldId.indexes, WireType.lengthDelimited);
      w.writeString(idx.value);
    }
    w.writeFieldTag(BatchTablePlanFieldId.willUpdateIndexMeta, WireType.varint);
    w.writeBool(plan.willUpdateIndexMeta);
    if (plan.baseTotalRecordCount != null) {
      w.writeFieldTag(
          BatchTablePlanFieldId.baseTotalRecordCount, WireType.varint);
      w.writeZigZag64(plan.baseTotalRecordCount!);
    }
    if (plan.baseTotalSizeBytes != null) {
      w.writeFieldTag(
          BatchTablePlanFieldId.baseTotalSizeBytes, WireType.varint);
      w.writeZigZag64(plan.baseTotalSizeBytes!);
    }
    if (plan.baseIndexTotalEntryCount != null) {
      for (final e in plan.baseIndexTotalEntryCount!.entries) {
        w.writeMessage(BatchTablePlanFieldId.baseIndexTotalEntryCount, (sw) {
          sw.writeFieldTag(
              IndexIntEntryFieldId.indexUid, WireType.lengthDelimited);
          sw.writeString(e.key.value);
          sw.writeFieldTag(IndexIntEntryFieldId.value, WireType.varint);
          sw.writeZigZag64(e.value);
        });
      }
    }
    if (plan.baseIndexTotalSizeBytes != null) {
      for (final e in plan.baseIndexTotalSizeBytes!.entries) {
        w.writeMessage(BatchTablePlanFieldId.baseIndexTotalSizeBytes, (sw) {
          sw.writeFieldTag(
              IndexIntEntryFieldId.indexUid, WireType.lengthDelimited);
          sw.writeString(e.key.value);
          sw.writeFieldTag(IndexIntEntryFieldId.value, WireType.varint);
          sw.writeZigZag64(e.value);
        });
      }
    }
  }

  static BatchTablePlan _readBatchTablePlan(BinaryReader r) {
    var willUpdateTableDataMeta = true;
    final indexes = <IndexUid>[];
    var willUpdateIndexMeta = false;
    int? baseTotalRecordCount;
    int? baseTotalSizeBytes;
    Map<IndexUid, int>? baseIndexTotalEntryCount;
    Map<IndexUid, int>? baseIndexTotalSizeBytes;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case BatchTablePlanFieldId.willUpdateTableDataMeta:
          willUpdateTableDataMeta = r.readBool();
          break;
        case BatchTablePlanFieldId.indexes:
          indexes.add(IndexUid(r.readString()));
          break;
        case BatchTablePlanFieldId.willUpdateIndexMeta:
          willUpdateIndexMeta = r.readBool();
          break;
        case BatchTablePlanFieldId.baseTotalRecordCount:
          baseTotalRecordCount = r.readZigZag64();
          break;
        case BatchTablePlanFieldId.baseTotalSizeBytes:
          baseTotalSizeBytes = r.readZigZag64();
          break;
        case BatchTablePlanFieldId.baseIndexTotalEntryCount:
          r.readMessage((sr, _) {
            baseIndexTotalEntryCount ??= <IndexUid, int>{};
            final entry = _readIndexIntEntry(sr);
            if (entry != null) {
              baseIndexTotalEntryCount![entry.$1] = entry.$2;
            }
          });
          break;
        case BatchTablePlanFieldId.baseIndexTotalSizeBytes:
          r.readMessage((sr, _) {
            baseIndexTotalSizeBytes ??= <IndexUid, int>{};
            final entry = _readIndexIntEntry(sr);
            if (entry != null) {
              baseIndexTotalSizeBytes![entry.$1] = entry.$2;
            }
          });
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return BatchTablePlan(
      willUpdateTableDataMeta: willUpdateTableDataMeta,
      indexes: indexes,
      willUpdateIndexMeta: willUpdateIndexMeta,
      baseTotalRecordCount: baseTotalRecordCount,
      baseTotalSizeBytes: baseTotalSizeBytes,
      baseIndexTotalEntryCount: baseIndexTotalEntryCount,
      baseIndexTotalSizeBytes: baseIndexTotalSizeBytes,
    );
  }

  static (IndexUid, int)? _readIndexIntEntry(BinaryReader r) {
    IndexUid? indexUid;
    int? value;
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case IndexIntEntryFieldId.indexUid:
          indexUid = IndexUid(r.readString());
          break;
        case IndexIntEntryFieldId.value:
          value = r.readZigZag64();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    if (indexUid == null || indexUid.isEmpty || value == null) return null;
    return (indexUid, value);
  }

  static void _writeLargeDelete(BinaryWriter w, LargeDeleteMeta op) {
    w.writeFieldTag(LargeDeleteFieldId.opId, WireType.lengthDelimited);
    w.writeString(op.opId);
    w.writeFieldTag(LargeDeleteFieldId.tableUid, WireType.lengthDelimited);
    w.writeString(op.tableUid.value);
    w.writeFieldTag(LargeDeleteFieldId.spaceName, WireType.lengthDelimited);
    w.writeString(op.spaceName);
    w.writeFieldTag(LargeDeleteFieldId.condition, WireType.lengthDelimited);
    w.writeBytes(BinaryMapCodec.encodeMap(op.condition));
    if (op.orderBy != null) {
      for (final o in op.orderBy!) {
        w.writeFieldTag(LargeDeleteFieldId.orderBy, WireType.lengthDelimited);
        w.writeString(o);
      }
    }
    if (op.limit != null) {
      w.writeFieldTag(LargeDeleteFieldId.limit, WireType.varint);
      w.writeZigZag64(op.limit!);
    }
    if (op.offset != null) {
      w.writeFieldTag(LargeDeleteFieldId.offset, WireType.varint);
      w.writeZigZag64(op.offset!);
    }
    if (op.checkpointCursor != null) {
      w.writeFieldTag(
          LargeDeleteFieldId.checkpointCursor, WireType.lengthDelimited);
      w.writeString(op.checkpointCursor!);
    }
    w.writeFieldTag(LargeDeleteFieldId.deletedSoFar, WireType.varint);
    w.writeZigZag64(op.deletedSoFar);
    w.writeFieldTag(LargeDeleteFieldId.status, WireType.lengthDelimited);
    w.writeString(op.status);
    w.writeFieldTag(LargeDeleteFieldId.createdAt, WireType.lengthDelimited);
    w.writeString(op.createdAt);
  }

  static LargeDeleteMeta _readLargeDelete(BinaryReader r) {
    var opId = '';
    var tableUid = TableUid.empty;
    var spaceName = '__global__';
    var condition = <String, dynamic>{};
    List<String>? orderBy;
    int? limit;
    int? offset;
    String? checkpointCursor;
    var deletedSoFar = 0;
    var status = 'running';
    var createdAt = '';

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case LargeDeleteFieldId.opId:
          opId = r.readString();
          break;
        case LargeDeleteFieldId.tableUid:
          tableUid = TableUid(r.readString());
          break;
        case LargeDeleteFieldId.spaceName:
          spaceName = r.readString();
          break;
        case LargeDeleteFieldId.condition:
          condition =
              BinaryMapCodec.decodeMap(r.readBytes()) ?? <String, dynamic>{};
          break;
        case LargeDeleteFieldId.orderBy:
          orderBy ??= <String>[];
          orderBy.add(r.readString());
          break;
        case LargeDeleteFieldId.limit:
          limit = r.readZigZag64();
          break;
        case LargeDeleteFieldId.offset:
          offset = r.readZigZag64();
          break;
        case LargeDeleteFieldId.checkpointCursor:
          checkpointCursor = r.readString();
          break;
        case LargeDeleteFieldId.deletedSoFar:
          deletedSoFar = r.readZigZag64();
          break;
        case LargeDeleteFieldId.status:
          status = r.readString();
          break;
        case LargeDeleteFieldId.createdAt:
          createdAt = r.readString();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    if (createdAt.isEmpty) {
      createdAt = DateTime.now().toIso8601String();
    }

    return LargeDeleteMeta(
      opId: opId,
      tableUid: tableUid,
      spaceName: spaceName,
      condition: condition,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      checkpointCursor: checkpointCursor,
      deletedSoFar: deletedSoFar,
      status: status,
      createdAt: createdAt,
    );
  }

  static void _writeLargeUpdate(BinaryWriter w, LargeUpdateMeta op) {
    w.writeFieldTag(LargeUpdateFieldId.opId, WireType.lengthDelimited);
    w.writeString(op.opId);
    w.writeFieldTag(LargeUpdateFieldId.tableUid, WireType.lengthDelimited);
    w.writeString(op.tableUid.value);
    w.writeFieldTag(LargeUpdateFieldId.spaceName, WireType.lengthDelimited);
    w.writeString(op.spaceName);
    w.writeFieldTag(LargeUpdateFieldId.condition, WireType.lengthDelimited);
    w.writeBytes(BinaryMapCodec.encodeMap(op.condition));
    w.writeFieldTag(LargeUpdateFieldId.updateData, WireType.lengthDelimited);
    w.writeBytes(BinaryMapCodec.encodeMap(op.updateData));
    if (op.orderBy != null) {
      for (final o in op.orderBy!) {
        w.writeFieldTag(LargeUpdateFieldId.orderBy, WireType.lengthDelimited);
        w.writeString(o);
      }
    }
    if (op.limit != null) {
      w.writeFieldTag(LargeUpdateFieldId.limit, WireType.varint);
      w.writeZigZag64(op.limit!);
    }
    if (op.offset != null) {
      w.writeFieldTag(LargeUpdateFieldId.offset, WireType.varint);
      w.writeZigZag64(op.offset!);
    }
    if (op.checkpointCursor != null) {
      w.writeFieldTag(
          LargeUpdateFieldId.checkpointCursor, WireType.lengthDelimited);
      w.writeString(op.checkpointCursor!);
    }
    w.writeFieldTag(LargeUpdateFieldId.updatedSoFar, WireType.varint);
    w.writeZigZag64(op.updatedSoFar);
    w.writeFieldTag(LargeUpdateFieldId.status, WireType.lengthDelimited);
    w.writeString(op.status);
    w.writeFieldTag(LargeUpdateFieldId.createdAt, WireType.lengthDelimited);
    w.writeString(op.createdAt);
    w.writeFieldTag(
        LargeUpdateFieldId.continueOnPartialErrors, WireType.varint);
    w.writeBool(op.continueOnPartialErrors);
  }

  static LargeUpdateMeta _readLargeUpdate(BinaryReader r) {
    var opId = '';
    var tableUid = TableUid.empty;
    var spaceName = '__global__';
    var condition = <String, dynamic>{};
    var updateData = <String, dynamic>{};
    List<String>? orderBy;
    int? limit;
    int? offset;
    String? checkpointCursor;
    var updatedSoFar = 0;
    var status = 'running';
    var createdAt = '';
    var continueOnPartialErrors = false;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case LargeUpdateFieldId.opId:
          opId = r.readString();
          break;
        case LargeUpdateFieldId.tableUid:
          tableUid = TableUid(r.readString());
          break;
        case LargeUpdateFieldId.spaceName:
          spaceName = r.readString();
          break;
        case LargeUpdateFieldId.condition:
          condition =
              BinaryMapCodec.decodeMap(r.readBytes()) ?? <String, dynamic>{};
          break;
        case LargeUpdateFieldId.updateData:
          updateData =
              BinaryMapCodec.decodeMap(r.readBytes()) ?? <String, dynamic>{};
          break;
        case LargeUpdateFieldId.orderBy:
          orderBy ??= <String>[];
          orderBy.add(r.readString());
          break;
        case LargeUpdateFieldId.limit:
          limit = r.readZigZag64();
          break;
        case LargeUpdateFieldId.offset:
          offset = r.readZigZag64();
          break;
        case LargeUpdateFieldId.checkpointCursor:
          checkpointCursor = r.readString();
          break;
        case LargeUpdateFieldId.updatedSoFar:
          updatedSoFar = r.readZigZag64();
          break;
        case LargeUpdateFieldId.status:
          status = r.readString();
          break;
        case LargeUpdateFieldId.createdAt:
          createdAt = r.readString();
          break;
        case LargeUpdateFieldId.continueOnPartialErrors:
          continueOnPartialErrors = r.readBool();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    if (createdAt.isEmpty) {
      createdAt = DateTime.now().toIso8601String();
    }

    return LargeUpdateMeta(
      opId: opId,
      tableUid: tableUid,
      spaceName: spaceName,
      condition: condition,
      updateData: updateData,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      checkpointCursor: checkpointCursor,
      updatedSoFar: updatedSoFar,
      status: status,
      createdAt: createdAt,
      continueOnPartialErrors: continueOnPartialErrors,
    );
  }

  static void _writeTableOp(BinaryWriter w, TableOpMeta op) {
    w.writeFieldTag(TableOpFieldId.opId, WireType.lengthDelimited);
    w.writeString(op.opId);
    w.writeFieldTag(TableOpFieldId.tableUid, WireType.lengthDelimited);
    w.writeString(op.tableUid.value);
    w.writeFieldTag(TableOpFieldId.type, WireType.lengthDelimited);
    w.writeString(op.type);
    w.writeMessage(TableOpFieldId.cutoff, (sw) {
      _writeWalPointer(sw, op.cutoff);
    });
    w.writeFieldTag(TableOpFieldId.createdAt, WireType.lengthDelimited);
    w.writeString(op.createdAt);
    w.writeFieldTag(TableOpFieldId.completed, WireType.varint);
    w.writeBool(op.completed);
  }

  static TableOpMeta _readTableOp(BinaryReader r) {
    var opId = '';
    var tableUid = TableUid.empty;
    var type = 'clear';
    var cutoff = const WalPointer(partitionIndex: 0, entrySeq: 0);
    var createdAt = '';
    var completed = false;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case TableOpFieldId.opId:
          opId = r.readString();
          break;
        case TableOpFieldId.tableUid:
          tableUid = TableUid(r.readString());
          break;
        case TableOpFieldId.type:
          type = r.readString();
          break;
        case TableOpFieldId.cutoff:
          r.readMessage((sr, _) {
            cutoff = _readWalPointer(sr);
          });
          break;
        case TableOpFieldId.createdAt:
          createdAt = r.readString();
          break;
        case TableOpFieldId.completed:
          completed = r.readBool();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    if (createdAt.isEmpty) {
      createdAt = DateTime.now().toIso8601String();
    }

    return TableOpMeta(
      opId: opId,
      tableUid: tableUid,
      type: type,
      cutoff: cutoff,
      createdAt: createdAt,
      completed: completed,
    );
  }

  static void _writeDirectoryMapping(BinaryWriter w, DirectoryMapping mapping) {
    for (final e in mapping.partitionToDir.entries) {
      w.writeMessage(DirectoryMappingFieldId.partitionToDir, (sw) {
        sw.writeFieldTag(IntPairFieldId.key, WireType.varint);
        sw.writeVarint(e.key);
        sw.writeFieldTag(IntPairFieldId.value, WireType.varint);
        sw.writeVarint(e.value);
      });
    }
    for (final e in mapping.dirToFileCount.entries) {
      w.writeMessage(DirectoryMappingFieldId.dirToFileCount, (sw) {
        sw.writeFieldTag(IntPairFieldId.key, WireType.varint);
        sw.writeVarint(e.key);
        sw.writeFieldTag(IntPairFieldId.value, WireType.varint);
        sw.writeVarint(e.value);
      });
    }
  }

  static DirectoryMapping _readDirectoryMapping(BinaryReader r) {
    final partitionToDir = <int, int>{};
    final dirToFileCount = <int, int>{};
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case DirectoryMappingFieldId.partitionToDir:
          r.readMessage((sr, _) {
            final pair = _readIntPair(sr);
            if (pair != null) partitionToDir[pair.$1] = pair.$2;
          });
          break;
        case DirectoryMappingFieldId.dirToFileCount:
          r.readMessage((sr, _) {
            final pair = _readIntPair(sr);
            if (pair != null) dirToFileCount[pair.$1] = pair.$2;
          });
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return DirectoryMapping(
      partitionToDir: partitionToDir,
      dirToFileCount: dirToFileCount,
    );
  }

  static (int, int)? _readIntPair(BinaryReader r) {
    int? key;
    int? value;
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case IntPairFieldId.key:
          key = r.readVarint();
          break;
        case IntPairFieldId.value:
          value = r.readVarint();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    if (key == null || value == null) return null;
    return (key, value);
  }
}
