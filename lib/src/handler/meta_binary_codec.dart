import 'dart:typed_data';

import '../core/btree_page.dart';
import '../core/ngh_page.dart';
import '../model/db_exception.dart';
import '../model/meta_info.dart';
import '../model/ngh_index_meta.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import 'binary_codec.dart';
import 'common.dart';
import 'platform_byte_data.dart';

/// Stable field IDs for [TimestampsCodec]. Reserved: 3..127.
abstract final class TimestampsFieldId {
  static const int createdMs = 1;
  static const int modifiedMs = 2;
}

/// Stable field IDs for [TreePagePtrCodec]. Reserved: 3..127.
abstract final class TreePagePtrFieldId {
  static const int partitionNo = 1;
  static const int pageNo = 2;
}

/// Stable field IDs for [TableDataMetaCodec]. Reserved: 19..127.
abstract final class TableDataMetaFieldId {
  static const int version = 1;
  static const int tableUid = 2;
  static const int totalSizeBytes = 3;
  static const int totalRecordCount = 4;
  static const int timestamps = 5;
  static const int maxAutoIncrementId = 6;

  /// Legacy -- ignored; page size lives in [GlobalConfig].
  static const int btreePageSize = 10;
  static const int btreeNextPageNo = 11;
  static const int btreePartitionCount = 12;
  static const int btreeRoot = 13;
  static const int btreeFirstLeaf = 14;
  static const int btreeLastLeaf = 15;
  static const int btreeHeight = 16;
  static const int overflowPartitionCount = 17;
  static const int overflowTotalSizeBytes = 18;
}

/// Stable field IDs for [IndexMetaCodec]. Reserved: 17..127.
abstract final class IndexMetaFieldId {
  static const int version = 1;
  static const int indexUid = 2;
  static const int tableUid = 3;
  static const int isUnique = 4;
  static const int isBuilding = 5;
  static const int totalSizeBytes = 6;
  static const int totalEntryCount = 7;
  static const int timestamps = 8;

  /// Legacy -- ignored; page size lives in [GlobalConfig].
  static const int btreePageSize = 10;
  static const int btreeNextPageNo = 11;
  static const int btreePartitionCount = 12;
  static const int btreeRoot = 13;
  static const int btreeFirstLeaf = 14;
  static const int btreeLastLeaf = 15;
  static const int btreeHeight = 16;
}

/// Stable field IDs for [NghIndexMetaCodec].
abstract final class NghIndexMetaFieldId {
  static const int version = 1;
  static const int indexUid = 2;
  static const int tableUid = 3;
  static const int dimensions = 4;
  static const int distanceMetric = 5;
  static const int precision = 6;
  static const int timestamps = 7;
  static const int totalVectors = 8;
  static const int deletedCount = 9;
  static const int medoidNodeId = 10;
  static const int nextNodeId = 11;
  static const int totalSizeBytes = 12;
  static const int isBuilding = 13;
  static const int centroidCount = 14;
  static const int postingPartitionCount = 15;
  static const int postingNextPageNo = 16;
  static const int postingFreeListHeads = 17;
}

/// Discriminator for global meta blobs embedded in partition-0 page 0.
enum TreeGlobalMetaKind {
  table(0),
  indexTree(1),
  ngh(2);

  final int wireValue;
  const TreeGlobalMetaKind(this.wireValue);

  static TreeGlobalMetaKind? fromWire(int v) {
    for (final k in values) {
      if (k.wireValue == v) return k;
    }
    return null;
  }
}

final class TimestampsCodec {
  static Uint8List encode(Timestamps ts) {
    final w = BinaryWriter(initialCapacity: 32);
    w.writeFieldTag(TimestampsFieldId.createdMs, WireType.fixed64);
    w.writeFixed64(ts.created.millisecondsSinceEpoch);
    w.writeFieldTag(TimestampsFieldId.modifiedMs, WireType.fixed64);
    w.writeFixed64(ts.modified.millisecondsSinceEpoch);
    return w.view;
  }

  static Timestamps decode(Uint8List bytes) {
    final reader = BinaryReader(bytes);
    var createdMs = 0;
    var modifiedMs = 0;
    while (!reader.isEOF) {
      final (fieldId, wireType) = reader.readFieldTag();
      switch (fieldId) {
        case TimestampsFieldId.createdMs:
          createdMs = reader.readFixed64();
          break;
        case TimestampsFieldId.modifiedMs:
          modifiedMs = reader.readFixed64();
          break;
        default:
          reader.skipField(wireType);
      }
    }
    final now = DateTime.now();
    return Timestamps(
      created: createdMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(createdMs, isUtc: false)
          : now,
      modified: modifiedMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(modifiedMs, isUtc: false)
          : now,
    );
  }
}

final class TreePagePtrCodec {
  static Uint8List encode(TreePagePtr ptr) {
    final w = BinaryWriter(initialCapacity: 16);
    w.writeFieldTag(TreePagePtrFieldId.partitionNo, WireType.varint);
    w.writeZigZag32(ptr.partitionNo);
    w.writeFieldTag(TreePagePtrFieldId.pageNo, WireType.varint);
    w.writeZigZag32(ptr.pageNo);
    return w.view;
  }

  static TreePagePtr decode(Uint8List bytes) {
    final reader = BinaryReader(bytes);
    var partitionNo = -1;
    var pageNo = -1;
    while (!reader.isEOF) {
      final (fieldId, wireType) = reader.readFieldTag();
      switch (fieldId) {
        case TreePagePtrFieldId.partitionNo:
          partitionNo = reader.readZigZag32();
          break;
        case TreePagePtrFieldId.pageNo:
          pageNo = reader.readZigZag32();
          break;
        default:
          reader.skipField(wireType);
      }
    }
    return TreePagePtr(partitionNo, pageNo);
  }
}

final class TableDataMetaCodec {
  static Uint8List encode(TableDataMeta meta) {
    final w = BinaryWriter(initialCapacity: 256);
    w.writeFieldTag(TableDataMetaFieldId.version, WireType.varint);
    w.writeVarint(meta.version);
    w.writeFieldTag(TableDataMetaFieldId.tableUid, WireType.lengthDelimited);
    w.writeString(meta.tableUid.value);
    w.writeFieldTag(TableDataMetaFieldId.totalSizeBytes, WireType.varint);
    w.writeVarint(meta.totalSizeBytes);
    w.writeFieldTag(TableDataMetaFieldId.totalRecordCount, WireType.varint);
    w.writeVarint(meta.totalRecordCount);
    w.writeFieldTag(TableDataMetaFieldId.timestamps, WireType.lengthDelimited);
    w.writeBytes(TimestampsCodec.encode(meta.timestamps));
    if (meta.maxAutoIncrementId != null) {
      w.writeFieldTag(
          TableDataMetaFieldId.maxAutoIncrementId, WireType.lengthDelimited);
      w.writeString(meta.maxAutoIncrementId!);
    }
    w.writeFieldTag(TableDataMetaFieldId.btreeNextPageNo, WireType.varint);
    w.writeVarint(meta.btreeNextPageNo);
    w.writeFieldTag(TableDataMetaFieldId.btreePartitionCount, WireType.varint);
    w.writeVarint(meta.btreePartitionCount);
    w.writeFieldTag(
        TableDataMetaFieldId.overflowPartitionCount, WireType.varint);
    w.writeVarint(meta.overflowPartitionCount);
    if (meta.overflowTotalSizeBytes > 0) {
      w.writeFieldTag(
          TableDataMetaFieldId.overflowTotalSizeBytes, WireType.varint);
      w.writeVarint(meta.overflowTotalSizeBytes);
    }
    w.writeFieldTag(TableDataMetaFieldId.btreeRoot, WireType.lengthDelimited);
    w.writeBytes(TreePagePtrCodec.encode(meta.btreeRoot));
    w.writeFieldTag(
        TableDataMetaFieldId.btreeFirstLeaf, WireType.lengthDelimited);
    w.writeBytes(TreePagePtrCodec.encode(meta.btreeFirstLeaf));
    w.writeFieldTag(
        TableDataMetaFieldId.btreeLastLeaf, WireType.lengthDelimited);
    w.writeBytes(TreePagePtrCodec.encode(meta.btreeLastLeaf));
    w.writeFieldTag(TableDataMetaFieldId.btreeHeight, WireType.varint);
    w.writeVarint(meta.btreeHeight);
    return w.view;
  }

  static TableDataMeta decode(
    Uint8List bytes, {
    TableUid? tableUidFallback,
  }) {
    final reader = BinaryReader(bytes);
    int version = InternalConfig.tableDataVersion;
    TableUid? tableUid = tableUidFallback;
    int totalSizeBytes = 0;
    int totalRecordCount = 0;
    Timestamps? timestamps;
    String? maxAutoIncrementId;
    int btreeNextPageNo = TableDataMeta.firstDataPageNo;
    int btreePartitionCount = 1;
    int overflowPartitionCount = 1;
    int overflowTotalSizeBytes = 0;
    TreePagePtr btreeRoot = TreePagePtr.nullPtr;
    TreePagePtr btreeFirstLeaf = TreePagePtr.nullPtr;
    TreePagePtr btreeLastLeaf = TreePagePtr.nullPtr;
    int btreeHeight = 0;

    while (!reader.isEOF) {
      final (fieldId, wireType) = reader.readFieldTag();
      switch (fieldId) {
        case TableDataMetaFieldId.version:
          version = reader.readVarint();
          break;
        case TableDataMetaFieldId.tableUid:
          tableUid = TableUid(reader.readString());
          break;
        case TableDataMetaFieldId.totalSizeBytes:
          totalSizeBytes = reader.readVarint();
          break;
        case TableDataMetaFieldId.totalRecordCount:
          totalRecordCount = reader.readVarint();
          break;
        case TableDataMetaFieldId.timestamps:
          timestamps = TimestampsCodec.decode(reader.readBytes());
          break;
        case TableDataMetaFieldId.maxAutoIncrementId:
          maxAutoIncrementId = reader.readString();
          break;
        case TableDataMetaFieldId.btreePageSize:
          reader.readVarint(); // legacy field -- ignore
          break;
        case TableDataMetaFieldId.btreeNextPageNo:
          btreeNextPageNo = reader.readVarint();
          break;
        case TableDataMetaFieldId.btreePartitionCount:
          btreePartitionCount = reader.readVarint();
          break;
        case TableDataMetaFieldId.overflowPartitionCount:
          overflowPartitionCount = reader.readVarint();
          break;
        case TableDataMetaFieldId.overflowTotalSizeBytes:
          overflowTotalSizeBytes = reader.readVarint();
          break;
        case TableDataMetaFieldId.btreeRoot:
          btreeRoot = TreePagePtrCodec.decode(reader.readBytes());
          break;
        case TableDataMetaFieldId.btreeFirstLeaf:
          btreeFirstLeaf = TreePagePtrCodec.decode(reader.readBytes());
          break;
        case TableDataMetaFieldId.btreeLastLeaf:
          btreeLastLeaf = TreePagePtrCodec.decode(reader.readBytes());
          break;
        case TableDataMetaFieldId.btreeHeight:
          btreeHeight = reader.readVarint();
          break;
        default:
          reader.skipField(wireType);
      }
    }

    final resolvedUid = tableUid ?? tableUidFallback;
    if (resolvedUid == null || timestamps == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message: 'Incomplete TableDataMeta binary payload',
        ),
      ]);
    }

    return TableDataMeta(
      version: version,
      tableUid: resolvedUid,
      totalSizeBytes: totalSizeBytes,
      totalRecordCount: totalRecordCount,
      timestamps: timestamps,
      maxAutoIncrementId: maxAutoIncrementId,
      btreeNextPageNo: btreeNextPageNo,
      btreePartitionCount: btreePartitionCount,
      overflowPartitionCount: overflowPartitionCount,
      overflowTotalSizeBytes: overflowTotalSizeBytes,
      btreeRoot: btreeRoot,
      btreeFirstLeaf: btreeFirstLeaf,
      btreeLastLeaf: btreeLastLeaf,
      btreeHeight: btreeHeight,
    );
  }
}

final class IndexMetaCodec {
  static Uint8List encode(IndexMeta meta) {
    final w = BinaryWriter(initialCapacity: 256);
    w.writeFieldTag(IndexMetaFieldId.version, WireType.varint);
    w.writeVarint(meta.version);
    w.writeFieldTag(IndexMetaFieldId.indexUid, WireType.lengthDelimited);
    w.writeString(meta.indexUid.value);
    w.writeFieldTag(IndexMetaFieldId.tableUid, WireType.lengthDelimited);
    w.writeString(meta.tableUid.value);
    w.writeFieldTag(IndexMetaFieldId.isUnique, WireType.varint);
    w.writeBool(meta.isUnique);
    w.writeFieldTag(IndexMetaFieldId.isBuilding, WireType.varint);
    w.writeBool(meta.isBuilding);
    w.writeFieldTag(IndexMetaFieldId.totalSizeBytes, WireType.varint);
    w.writeVarint(meta.totalSizeBytes);
    w.writeFieldTag(IndexMetaFieldId.totalEntryCount, WireType.varint);
    w.writeVarint(meta.totalEntryCount);
    w.writeFieldTag(IndexMetaFieldId.timestamps, WireType.lengthDelimited);
    w.writeBytes(TimestampsCodec.encode(meta.timestamps));
    w.writeFieldTag(IndexMetaFieldId.btreeNextPageNo, WireType.varint);
    w.writeVarint(meta.btreeNextPageNo);
    w.writeFieldTag(IndexMetaFieldId.btreePartitionCount, WireType.varint);
    w.writeVarint(meta.btreePartitionCount);
    w.writeFieldTag(IndexMetaFieldId.btreeRoot, WireType.lengthDelimited);
    w.writeBytes(TreePagePtrCodec.encode(meta.btreeRoot));
    w.writeFieldTag(IndexMetaFieldId.btreeFirstLeaf, WireType.lengthDelimited);
    w.writeBytes(TreePagePtrCodec.encode(meta.btreeFirstLeaf));
    w.writeFieldTag(IndexMetaFieldId.btreeLastLeaf, WireType.lengthDelimited);
    w.writeBytes(TreePagePtrCodec.encode(meta.btreeLastLeaf));
    w.writeFieldTag(IndexMetaFieldId.btreeHeight, WireType.varint);
    w.writeVarint(meta.btreeHeight);
    return w.view;
  }

  static IndexMeta decode(
    Uint8List bytes, {
    TableUid? tableUidFallback,
    IndexUid? indexUidFallback,
  }) {
    final reader = BinaryReader(bytes);
    int version = InternalConfig.indexVersion;
    IndexUid? indexUid = indexUidFallback;
    TableUid? tableUid = tableUidFallback;
    bool isUnique = false;
    bool isBuilding = false;
    int totalSizeBytes = 0;
    int totalEntryCount = 0;
    Timestamps? timestamps;
    int btreeNextPageNo = IndexMeta.firstDataPageNo;
    int btreePartitionCount = 1;
    TreePagePtr btreeRoot = TreePagePtr.nullPtr;
    TreePagePtr btreeFirstLeaf = TreePagePtr.nullPtr;
    TreePagePtr btreeLastLeaf = TreePagePtr.nullPtr;
    int btreeHeight = 0;

    while (!reader.isEOF) {
      final (fieldId, wireType) = reader.readFieldTag();
      switch (fieldId) {
        case IndexMetaFieldId.version:
          version = reader.readVarint();
          break;
        case IndexMetaFieldId.indexUid:
          indexUid = IndexUid(reader.readString());
          break;
        case IndexMetaFieldId.tableUid:
          tableUid = TableUid(reader.readString());
          break;
        case IndexMetaFieldId.isUnique:
          isUnique = reader.readBool();
          break;
        case IndexMetaFieldId.isBuilding:
          isBuilding = reader.readBool();
          break;
        case IndexMetaFieldId.totalSizeBytes:
          totalSizeBytes = reader.readVarint();
          break;
        case IndexMetaFieldId.totalEntryCount:
          totalEntryCount = reader.readVarint();
          break;
        case IndexMetaFieldId.timestamps:
          timestamps = TimestampsCodec.decode(reader.readBytes());
          break;
        case IndexMetaFieldId.btreePageSize:
          reader.readVarint(); // legacy field -- ignore
          break;
        case IndexMetaFieldId.btreeNextPageNo:
          btreeNextPageNo = reader.readVarint();
          break;
        case IndexMetaFieldId.btreePartitionCount:
          btreePartitionCount = reader.readVarint();
          break;
        case IndexMetaFieldId.btreeRoot:
          btreeRoot = TreePagePtrCodec.decode(reader.readBytes());
          break;
        case IndexMetaFieldId.btreeFirstLeaf:
          btreeFirstLeaf = TreePagePtrCodec.decode(reader.readBytes());
          break;
        case IndexMetaFieldId.btreeLastLeaf:
          btreeLastLeaf = TreePagePtrCodec.decode(reader.readBytes());
          break;
        case IndexMetaFieldId.btreeHeight:
          btreeHeight = reader.readVarint();
          break;
        default:
          reader.skipField(wireType);
      }
    }

    final resolvedIndexUid = indexUid ?? indexUidFallback;
    final resolvedTableUid = tableUid ?? tableUidFallback;
    if (resolvedIndexUid == null ||
        resolvedTableUid == null ||
        timestamps == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message: 'Incomplete IndexMeta binary payload',
        ),
      ]);
    }

    return IndexMeta(
      version: version,
      indexUid: resolvedIndexUid,
      tableUid: resolvedTableUid,
      isUnique: isUnique,
      isBuilding: isBuilding,
      timestamps: timestamps,
      totalSizeBytes: totalSizeBytes,
      totalEntryCount: totalEntryCount,
      btreeNextPageNo: btreeNextPageNo,
      btreePartitionCount: btreePartitionCount,
      btreeRoot: btreeRoot,
      btreeFirstLeaf: btreeFirstLeaf,
      btreeLastLeaf: btreeLastLeaf,
      btreeHeight: btreeHeight,
    );
  }
}

final class NghIndexMetaCodec {
  static Uint8List encode(NghIndexMeta meta) {
    final w = BinaryWriter(initialCapacity: 512);
    w.writeFieldTag(NghIndexMetaFieldId.version, WireType.varint);
    w.writeVarint(meta.version);
    w.writeFieldTag(NghIndexMetaFieldId.indexUid, WireType.lengthDelimited);
    w.writeString(meta.indexUid.value);
    w.writeFieldTag(NghIndexMetaFieldId.tableUid, WireType.lengthDelimited);
    w.writeString(meta.tableUid.value);
    w.writeFieldTag(NghIndexMetaFieldId.dimensions, WireType.varint);
    w.writeVarint(meta.dimensions);
    w.writeFieldTag(NghIndexMetaFieldId.distanceMetric, WireType.varint);
    w.writeVarint(meta.distanceMetric.index);
    w.writeFieldTag(NghIndexMetaFieldId.precision, WireType.varint);
    w.writeVarint(meta.precision.index);
    w.writeFieldTag(NghIndexMetaFieldId.timestamps, WireType.lengthDelimited);
    w.writeBytes(TimestampsCodec.encode(meta.timestamps));
    w.writeFieldTag(NghIndexMetaFieldId.totalVectors, WireType.varint);
    w.writeVarint(meta.totalVectors);
    w.writeFieldTag(NghIndexMetaFieldId.deletedCount, WireType.varint);
    w.writeVarint(meta.deletedCount);
    w.writeFieldTag(NghIndexMetaFieldId.medoidNodeId, WireType.varint);
    w.writeZigZag32(meta.medoidNodeId);
    w.writeFieldTag(NghIndexMetaFieldId.nextNodeId, WireType.varint);
    w.writeVarint(meta.nextNodeId);
    w.writeFieldTag(NghIndexMetaFieldId.totalSizeBytes, WireType.varint);
    w.writeVarint(meta.totalSizeBytes);
    w.writeFieldTag(NghIndexMetaFieldId.isBuilding, WireType.varint);
    w.writeBool(meta.isBuilding);
    w.writeFieldTag(NghIndexMetaFieldId.centroidCount, WireType.varint);
    w.writeVarint(meta.centroidCount);
    w.writeFieldTag(NghIndexMetaFieldId.postingPartitionCount, WireType.varint);
    w.writeVarint(meta.postingPartitionCount);
    w.writeFieldTag(NghIndexMetaFieldId.postingNextPageNo, WireType.varint);
    w.writeVarint(meta.postingNextPageNo);
    _writeIntIntMap(
        w, NghIndexMetaFieldId.postingFreeListHeads, meta.postingFreeListHeads);
    return w.view;
  }

  static NghIndexMeta decode(
    Uint8List bytes, {
    TableUid? tableUidFallback,
    IndexUid? indexUidFallback,
  }) {
    final reader = BinaryReader(bytes);
    int version = InternalConfig.indexVersion;
    IndexUid? indexUid = indexUidFallback;
    TableUid? tableUid = tableUidFallback;
    int dimensions = 0;
    VectorDistanceMetric distanceMetric = VectorDistanceMetric.cosine;
    VectorPrecision precision = VectorPrecision.float32;
    Timestamps? timestamps;
    int totalVectors = 0;
    int deletedCount = 0;
    int medoidNodeId = -1;
    int nextNodeId = 0;
    int totalSizeBytes = 0;
    bool isBuilding = false;
    int centroidCount = 0;
    int postingPartitionCount = 1;
    int postingNextPageNo = NghIndexMeta.firstDataPageNo;
    Map<int, int> postingFreeListHeads = const {};

    while (!reader.isEOF) {
      final (fieldId, wireType) = reader.readFieldTag();
      switch (fieldId) {
        case NghIndexMetaFieldId.version:
          version = reader.readVarint();
          break;
        case NghIndexMetaFieldId.indexUid:
          indexUid = IndexUid(reader.readString());
          break;
        case NghIndexMetaFieldId.tableUid:
          tableUid = TableUid(reader.readString());
          break;
        case NghIndexMetaFieldId.dimensions:
          dimensions = reader.readVarint();
          break;
        case NghIndexMetaFieldId.distanceMetric:
          final idx = reader.readVarint();
          if (idx >= 0 && idx < VectorDistanceMetric.values.length) {
            distanceMetric = VectorDistanceMetric.values[idx];
          }
          break;
        case NghIndexMetaFieldId.precision:
          final idx = reader.readVarint();
          if (idx >= 0 && idx < VectorPrecision.values.length) {
            precision = VectorPrecision.values[idx];
          }
          break;
        case NghIndexMetaFieldId.timestamps:
          timestamps = TimestampsCodec.decode(reader.readBytes());
          break;
        case NghIndexMetaFieldId.totalVectors:
          totalVectors = reader.readVarint();
          break;
        case NghIndexMetaFieldId.deletedCount:
          deletedCount = reader.readVarint();
          break;
        case NghIndexMetaFieldId.medoidNodeId:
          medoidNodeId = reader.readZigZag32();
          break;
        case NghIndexMetaFieldId.nextNodeId:
          nextNodeId = reader.readVarint();
          break;
        case NghIndexMetaFieldId.totalSizeBytes:
          totalSizeBytes = reader.readVarint();
          break;
        case NghIndexMetaFieldId.isBuilding:
          isBuilding = reader.readBool();
          break;
        case NghIndexMetaFieldId.centroidCount:
          centroidCount = reader.readVarint();
          break;
        case NghIndexMetaFieldId.postingPartitionCount:
          postingPartitionCount = reader.readVarint();
          break;
        case NghIndexMetaFieldId.postingNextPageNo:
          postingNextPageNo = reader.readVarint();
          break;
        case NghIndexMetaFieldId.postingFreeListHeads:
          postingFreeListHeads = _readIntIntMap(reader);
          break;
        default:
          reader.skipField(wireType);
      }
    }

    final resolvedIndexUid = indexUid ?? indexUidFallback;
    final resolvedTableUid = tableUid ?? tableUidFallback;
    if (resolvedIndexUid == null ||
        resolvedTableUid == null ||
        timestamps == null ||
        dimensions <= 0) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message: 'Incomplete NghIndexMeta binary payload',
        ),
      ]);
    }

    return NghIndexMeta(
      version: version,
      indexUid: resolvedIndexUid,
      tableUid: resolvedTableUid,
      dimensions: dimensions,
      distanceMetric: distanceMetric,
      precision: precision,
      timestamps: timestamps,
      totalVectors: totalVectors,
      deletedCount: deletedCount,
      medoidNodeId: medoidNodeId,
      nextNodeId: nextNodeId,
      totalSizeBytes: totalSizeBytes,
      isBuilding: isBuilding,
      centroidCount: centroidCount,
      postingPartitionCount: postingPartitionCount,
      postingNextPageNo: postingNextPageNo,
      postingFreeListHeads: postingFreeListHeads,
    );
  }

  static void _writeIntIntMap(
    BinaryWriter w,
    int fieldId,
    Map<int, int> map,
  ) {
    if (map.isEmpty) return;
    w.writeMessage(fieldId, (sub) {
      for (final e in map.entries) {
        sub.writeFieldTag(1, WireType.varint);
        sub.writeZigZag32(e.key);
        sub.writeFieldTag(2, WireType.varint);
        sub.writeZigZag32(e.value);
      }
    });
  }

  static Map<int, int> _readIntIntMap(BinaryReader reader) {
    final out = <int, int>{};
    reader.readMessage((sub, _) {
      int? pendingKey;
      while (!sub.isEOF) {
        final (fieldId, wt) = sub.readFieldTag();
        switch (fieldId) {
          case 1:
            pendingKey = sub.readZigZag32();
            break;
          case 2:
            final value = sub.readZigZag32();
            if (pendingKey != null) {
              out[pendingKey] = value;
              pendingKey = null;
            }
            break;
          default:
            sub.skipField(wt);
        }
      }
    });
    return out;
  }
}

/// Wraps a global meta blob with a stable kind discriminator.
final class TreeGlobalMetaBlobCodec {
  static Uint8List encode(TreeGlobalMetaKind kind, Uint8List payload) {
    final w = BinaryWriter(initialCapacity: payload.length + 8);
    w.writeFieldTag(1, WireType.varint);
    w.writeVarint(kind.wireValue);
    w.writeFieldTag(2, WireType.lengthDelimited);
    w.writeBytes(payload);
    return w.view;
  }

  static ({TreeGlobalMetaKind kind, Uint8List payload})? decode(
      Uint8List bytes) {
    final reader = BinaryReader(bytes);
    TreeGlobalMetaKind? kind;
    Uint8List? payload;
    while (!reader.isEOF) {
      final (fieldId, wireType) = reader.readFieldTag();
      switch (fieldId) {
        case 1:
          kind = TreeGlobalMetaKind.fromWire(reader.readVarint());
          break;
        case 2:
          payload = reader.readBytes();
          break;
        default:
          reader.skipField(wireType);
      }
    }
    if (kind == null || payload == null) return null;
    return (kind: kind, payload: payload);
  }
}

/// Per-partition local statistics embedded in every partition file page 0
/// under [TreeMetaPagePayload] field 1 (length-delimited blob).
///
/// ## Wire evolution (append-only)
///
/// Fixed layout for the hot path (every partition open). Extensibility rules:
///
/// 1. **Append only** -- new fields go after [payloadSize]; never reorder,
///    shrink, or repurpose existing offsets.
/// 2. **Bump [payloadVersion]** when appending; update [payloadSize] to the
///    new encode length. Keep [minPayloadSize] at the v1 size (56) forever.
/// 3. **Readers** require `bytes.length >= minPayloadSize`, decode the known
///    prefix by offset/`version`, and **ignore trailing bytes** from newer
///    writers (forward compatible).
/// 4. **Writers** always emit exactly [payloadSize] for the current version.
/// 5. **Breaking** layout changes need a new magic (e.g. `PLS2`), not a soft
///    version bump -- avoid dual on-disk PLS layouts inside `PLS1`.
///
/// Current layout (`payloadVersion == 1`, little-endian):
///
/// | Off | Len | Field |
/// |----:|----:|-------|
/// |   0 |   4 | magic `PLS1` |
/// |   4 |   2 | payloadVersion |
/// |   6 |   1 | dataCategory |
/// |   7 |   1 | reserved |
/// |   8 |   4 | partitionNo |
/// |  12 |   4 | reserved |
/// |  16 |   8 | totalEntryCount |
/// |  24 |   8 | totalSizeBytes |
/// |  32 |   4 | freeListHeadPageNo |
/// |  36 |   4 | freePageCount |
/// |  40 |   8 | lastFlushBatchKey |
/// |  48 |   8 | lastMaintenanceBatchKey |
final class PartitionLocalStats {
  static const int payloadMagic = 0x31534C50; // 'PLS1'

  /// Current schema version written by [encode].
  static const int payloadVersion = 1;

  /// Smallest blob a reader of this library accepts (v1). Never decrease.
  static const int minPayloadSize = 56;

  /// Exact byte length produced by [encode] for [payloadVersion].
  /// When appending fields: bump [payloadVersion] and set this to the new size.
  static const int payloadSize = 56;

  /// Encoded size for a historical [version], or 0 if unknown/unsupported.
  /// Used when decoding version-gated trailing fields.
  static int encodedSizeForVersion(int version) {
    if (version >= 1) return 56;
    return 0;
  }

  final int partitionNo;
  final int totalEntryCount;
  final int totalSizeBytes;
  final int freeListHeadPageNo;
  final int freePageCount;

  /// NGH data category (0=graph, 1=pq, 2=raw, 3=codebook). B+Tree uses 0.
  final int dataCategory;

  /// FNV-1a-64 of the last flush [batchId] that durable-wrote this partition (0 = none).
  final int lastFlushBatchKey;

  /// FNV-1a-64 of the last maintenance [batchId] that durable-wrote this partition (0 = none).
  final int lastMaintenanceBatchKey;

  const PartitionLocalStats({
    required this.partitionNo,
    this.totalEntryCount = 0,
    this.totalSizeBytes = 0,
    this.freeListHeadPageNo = -1,
    this.freePageCount = 0,
    this.dataCategory = 0,
    this.lastFlushBatchKey = 0,
    this.lastMaintenanceBatchKey = 0,
  });

  static final BigInt _fnvOffset = BigInt.parse('cbf29ce484222325', radix: 16);
  static final BigInt _fnvPrime = BigInt.parse('100000001b3', radix: 16);
  static final BigInt _fnvMask64 = (BigInt.one << 64) - BigInt.one;
  static final BigInt _fnvMask32 = BigInt.from(0xFFFFFFFF);

  /// Stable 64-bit fingerprint of a batch id for partition-local durable markers.
  ///
  /// FNV-1a-64. Uses [BigInt] so dart2js never sees non-representable literals;
  /// result uses the same signed mapping as [PlatformByteData.getInt64].
  static int batchKeyFromId(String batchId) {
    if (batchId.isEmpty) return 0;
    var hash = _fnvOffset;
    for (final b in batchId.codeUnits) {
      hash = (hash ^ BigInt.from(b)) & _fnvMask64;
      hash = (hash * _fnvPrime) & _fnvMask64;
    }
    final lo = (hash & _fnvMask32).toInt();
    final hi = ((hash >> 32) & _fnvMask32).toInt();
    // Match PlatformByteData.getInt64 mapping on every platform.
    if (hi >= 0x80000000) {
      return (hi - 0x100000000) * 0x100000000 + lo;
    }
    return hi * 0x100000000 + lo;
  }

  PartitionLocalStats copyWith({
    int? partitionNo,
    int? totalEntryCount,
    int? totalSizeBytes,
    int? freeListHeadPageNo,
    int? freePageCount,
    int? dataCategory,
    int? lastFlushBatchKey,
    int? lastMaintenanceBatchKey,
  }) {
    return PartitionLocalStats(
      partitionNo: partitionNo ?? this.partitionNo,
      totalEntryCount: totalEntryCount ?? this.totalEntryCount,
      totalSizeBytes: totalSizeBytes ?? this.totalSizeBytes,
      freeListHeadPageNo: freeListHeadPageNo ?? this.freeListHeadPageNo,
      freePageCount: freePageCount ?? this.freePageCount,
      dataCategory: dataCategory ?? this.dataCategory,
      lastFlushBatchKey: lastFlushBatchKey ?? this.lastFlushBatchKey,
      lastMaintenanceBatchKey:
          lastMaintenanceBatchKey ?? this.lastMaintenanceBatchKey,
    );
  }

  /// Apply durable batch markers while preserving the opposite batch-type key.
  PartitionLocalStats withBatchMarkers({
    required bool isMaintenance,
    required String? batchId,
    required int preservedFlushKey,
    required int preservedMaintKey,
  }) {
    final key =
        (batchId == null || batchId.isEmpty) ? 0 : batchKeyFromId(batchId);
    if (key == 0) {
      return copyWith(
        lastFlushBatchKey: preservedFlushKey,
        lastMaintenanceBatchKey: preservedMaintKey,
      );
    }
    if (isMaintenance) {
      return copyWith(
        lastFlushBatchKey: preservedFlushKey,
        lastMaintenanceBatchKey: key,
      );
    }
    return copyWith(
      lastFlushBatchKey: key,
      lastMaintenanceBatchKey: preservedMaintKey,
    );
  }

  bool matchesBatchKey({required bool isMaintenance, required String batchId}) {
    if (batchId.isEmpty) return false;
    final key = batchKeyFromId(batchId);
    if (key == 0) return false;
    return isMaintenance
        ? lastMaintenanceBatchKey == key
        : lastFlushBatchKey == key;
  }

  Uint8List encode() {
    assert(payloadSize == encodedSizeForVersion(payloadVersion));
    final bd = ByteData(payloadSize);
    bd.setUint32(0, payloadMagic, Endian.little);
    bd.setUint16(4, payloadVersion, Endian.little);
    bd.setUint8(6, dataCategory);
    bd.setUint8(7, 0); // reserved
    bd.setInt32(8, partitionNo, Endian.little);
    bd.setInt32(12, 0, Endian.little); // reserved
    PlatformByteData.setInt64(bd, 16, totalEntryCount, Endian.little);
    PlatformByteData.setInt64(bd, 24, totalSizeBytes, Endian.little);
    bd.setInt32(32, freeListHeadPageNo, Endian.little);
    bd.setInt32(36, freePageCount, Endian.little);
    PlatformByteData.setInt64(bd, 40, lastFlushBatchKey, Endian.little);
    PlatformByteData.setInt64(bd, 48, lastMaintenanceBatchKey, Endian.little);
    return bd.buffer.asUint8List();
  }

  /// Decode PLS1 blob. Accepts current and newer (longer) blobs; rejects
  /// truncated or unknown-magic input. Trailing bytes past the known prefix
  /// are ignored (forward compatible with append-only writers).
  static PartitionLocalStats? tryDecode(Uint8List bytes) {
    if (bytes.length < minPayloadSize) return null;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != payloadMagic) return null;
    final version = bd.getUint16(4, Endian.little);
    if (version <= 0) return null;

    // v1 prefix (offsets 0..55). Newer versions append after this; unread.
    final v1Size = encodedSizeForVersion(1);
    if (bytes.length < v1Size) return null;

    return PartitionLocalStats(
      dataCategory: bd.getUint8(6),
      partitionNo: bd.getInt32(8, Endian.little),
      totalEntryCount: PlatformByteData.getInt64(bd, 16, Endian.little),
      totalSizeBytes: PlatformByteData.getInt64(bd, 24, Endian.little),
      freeListHeadPageNo: bd.getInt32(32, Endian.little),
      freePageCount: bd.getInt32(36, Endian.little),
      lastFlushBatchKey: PlatformByteData.getInt64(bd, 40, Endian.little),
      lastMaintenanceBatchKey: PlatformByteData.getInt64(bd, 48, Endian.little),
      // Future append example:
      // newField: (version >= 2 && bytes.length >= encodedSizeForVersion(2))
      //     ? PlatformByteData.getInt64(bd, 56, Endian.little)
      //     : 0,
    );
  }

  /// Upgrade helper: map legacy [PartitionMetaPage] into [PartitionLocalStats].
  static PartitionLocalStats fromLegacyPartitionMetaPage(
      PartitionMetaPage page) {
    return PartitionLocalStats(
      partitionNo: page.partitionNo,
      totalEntryCount: page.totalEntryCount,
      totalSizeBytes: page.totalSizeBytes,
      freeListHeadPageNo: page.freeListHeadPageNo,
      freePageCount: page.freePageCount,
    );
  }

  /// Upgrade helper: map legacy [NghPartitionMetaPage].
  static PartitionLocalStats fromLegacyNghPartitionMetaPage(
      NghPartitionMetaPage page) {
    return PartitionLocalStats(
      partitionNo: page.partitionNo,
      dataCategory: page.dataCategory,
      totalEntryCount: page.totalEntryCount,
      totalSizeBytes: page.totalSizeBytes,
      freeListHeadPageNo: page.freeListHeadPageNo,
      freePageCount: page.freePageCount,
    );
  }
}
