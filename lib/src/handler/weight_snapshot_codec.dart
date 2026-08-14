import 'dart:typed_data';

import '../model/table_identity.dart';
import '../model/weight_data.dart';
import 'binary_codec.dart';

/// Stable field IDs for cache-weight snapshot. Never reuse IDs.
abstract final class WeightSnapshotFieldId {
  static const int tableRecord = 1;
  static const int indexData = 2;
  static const int lastDecayTime = 3;
  static const int indexDataKeyFormat = 4;
  // Reserved 20--31.
}

abstract final class WeightEntryFieldId {
  static const int id = 1;
  static const int data = 2;
}

abstract final class WeightDataFieldId {
  static const int weight = 1;
  static const int accessCount = 2;
  static const int lastUpdateTime = 3;
  static const int neverDecay = 4;
  static const int customWeight = 5;
}

/// Decoded in-memory weight snapshot (`access_weights.tobf` payload).
final class WeightSnapshot {
  final Map<TableUid, WeightData> tableRecord;
  final Map<String, WeightData> indexData;
  final int lastDecayTime;
  final bool indexDataKeyFormatIsUid;

  const WeightSnapshot({
    required this.tableRecord,
    required this.indexData,
    required this.lastDecayTime,
    this.indexDataKeyFormatIsUid = true,
  });

  factory WeightSnapshot.empty() => const WeightSnapshot(
        tableRecord: {},
        indexData: {},
        lastDecayTime: 0,
        indexDataKeyFormatIsUid: true,
      );
}

/// Field-tag codec for [WeightSnapshot] (space file payload; no outer TOBF frame).
abstract final class WeightSnapshotCodec {
  WeightSnapshotCodec._();

  /// Space-local file name under `spaces/{space}/`.
  static const String fileName = 'access_weights.tobf';

  /// Marker value for [WeightSnapshotFieldId.indexDataKeyFormat].
  static const int indexUidKeyFormat = 1;

  static Uint8List encode(WeightSnapshot snapshot) {
    final w = BinaryWriter(initialCapacity: 256);

    snapshot.tableRecord.forEach((uid, data) {
      w.writeMessage(WeightSnapshotFieldId.tableRecord, (sw) {
        sw.writeFieldTag(WeightEntryFieldId.id, WireType.lengthDelimited);
        sw.writeString(uid.value);
        sw.writeMessage(WeightEntryFieldId.data, (dw) {
          _writeWeightData(dw, data);
        });
      });
    });

    snapshot.indexData.forEach((id, data) {
      w.writeMessage(WeightSnapshotFieldId.indexData, (sw) {
        sw.writeFieldTag(WeightEntryFieldId.id, WireType.lengthDelimited);
        sw.writeString(id);
        sw.writeMessage(WeightEntryFieldId.data, (dw) {
          _writeWeightData(dw, data);
        });
      });
    });

    w.writeFieldTag(WeightSnapshotFieldId.lastDecayTime, WireType.fixed64);
    w.writeFixed64(snapshot.lastDecayTime);

    if (snapshot.indexDataKeyFormatIsUid) {
      w.writeFieldTag(
          WeightSnapshotFieldId.indexDataKeyFormat, WireType.varint);
      w.writeVarint(indexUidKeyFormat);
    }

    return Uint8List.fromList(w.view);
  }

  static WeightSnapshot decode(Uint8List bytes) {
    if (bytes.isEmpty) return WeightSnapshot.empty();

    final r = BinaryReader(bytes);
    final tableRecord = <TableUid, WeightData>{};
    final indexData = <String, WeightData>{};
    var lastDecayTime = 0;
    var indexDataKeyFormatIsUid = false;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case WeightSnapshotFieldId.tableRecord:
          r.readMessage((nr, _) {
            String? id;
            WeightData? data;
            while (!nr.isEOF) {
              final (fid, wt) = nr.readFieldTag();
              switch (fid) {
                case WeightEntryFieldId.id:
                  id = nr.readString();
                  break;
                case WeightEntryFieldId.data:
                  nr.readMessage((dr, _) {
                    data = _readWeightData(dr);
                  });
                  break;
                default:
                  nr.skipField(wt);
                  break;
              }
            }
            if (id != null && data != null) {
              tableRecord[TableUid(id)] = data!;
            }
          });
          break;
        case WeightSnapshotFieldId.indexData:
          r.readMessage((nr, _) {
            String? id;
            WeightData? data;
            while (!nr.isEOF) {
              final (fid, wt) = nr.readFieldTag();
              switch (fid) {
                case WeightEntryFieldId.id:
                  id = nr.readString();
                  break;
                case WeightEntryFieldId.data:
                  nr.readMessage((dr, _) {
                    data = _readWeightData(dr);
                  });
                  break;
                default:
                  nr.skipField(wt);
                  break;
              }
            }
            if (id != null && data != null) {
              indexData[id] = data!;
            }
          });
          break;
        case WeightSnapshotFieldId.lastDecayTime:
          lastDecayTime = r.readFixed64();
          break;
        case WeightSnapshotFieldId.indexDataKeyFormat:
          indexDataKeyFormatIsUid = r.readVarint() == indexUidKeyFormat;
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return WeightSnapshot(
      tableRecord: tableRecord,
      indexData: indexData,
      lastDecayTime: lastDecayTime,
      indexDataKeyFormatIsUid: indexDataKeyFormatIsUid,
    );
  }

  static void _writeWeightData(BinaryWriter w, WeightData data) {
    w.writeFieldTag(WeightDataFieldId.weight, WireType.varint);
    w.writeVarint(data.weight);
    w.writeFieldTag(WeightDataFieldId.accessCount, WireType.varint);
    w.writeVarint(data.accessCount);
    w.writeFieldTag(WeightDataFieldId.lastUpdateTime, WireType.fixed64);
    w.writeFixed64(data.lastUpdateTime);
    if (data.neverDecay) {
      w.writeFieldTag(WeightDataFieldId.neverDecay, WireType.varint);
      w.writeBool(true);
    }
    if (data.customWeight != null) {
      w.writeFieldTag(WeightDataFieldId.customWeight, WireType.varint);
      w.writeZigZag64(data.customWeight!);
    }
  }

  static WeightData _readWeightData(BinaryReader r) {
    var weight = 0;
    var accessCount = 0;
    var lastUpdateTime = 0;
    var neverDecay = false;
    int? customWeight;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case WeightDataFieldId.weight:
          weight = r.readVarint();
          break;
        case WeightDataFieldId.accessCount:
          accessCount = r.readVarint();
          break;
        case WeightDataFieldId.lastUpdateTime:
          lastUpdateTime = r.readFixed64();
          break;
        case WeightDataFieldId.neverDecay:
          neverDecay = r.readBool();
          break;
        case WeightDataFieldId.customWeight:
          customWeight = r.readZigZag64();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return WeightData(
      weight: weight,
      accessCount: accessCount,
      lastUpdateTime: lastUpdateTime,
      neverDecay: neverDecay,
      customWeight: customWeight,
    );
  }
}
