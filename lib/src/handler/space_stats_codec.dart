import 'dart:typed_data';

import '../model/space_stats.dart';
import 'binary_codec.dart';

/// Stable field IDs for [SpaceStats] KV payload. Never reuse IDs.
abstract final class SpaceStatsFieldId {
  static const int totalRecordCount = 1;
  static const int totalTableDataSizeBytes = 2;
  static const int totalIndexDataSizeBytes = 3;
  static const int lastStatisticsTime = 4;
}

/// Binary payload codec for [SpaceStats] (InternalKv value, no file shell).
final class SpaceStatsCodec {
  SpaceStatsCodec._();

  static Uint8List encode(SpaceStats stats) {
    final w = BinaryWriter(initialCapacity: 48);

    w.writeFieldTag(SpaceStatsFieldId.totalRecordCount, WireType.varint);
    w.writeVarint(stats.totalRecordCount);
    w.writeFieldTag(SpaceStatsFieldId.totalTableDataSizeBytes, WireType.varint);
    w.writeVarint(stats.totalTableDataSizeBytes);
    w.writeFieldTag(SpaceStatsFieldId.totalIndexDataSizeBytes, WireType.varint);
    w.writeVarint(stats.totalIndexDataSizeBytes);

    if (stats.lastStatisticsTime != null) {
      w.writeFieldTag(SpaceStatsFieldId.lastStatisticsTime, WireType.fixed64);
      w.writeFixed64(stats.lastStatisticsTime!.millisecondsSinceEpoch);
    }

    return w.view;
  }

  static SpaceStats decode(Uint8List bytes) {
    var totalRecordCount = 0;
    var totalTableDataSizeBytes = 0;
    var totalIndexDataSizeBytes = 0;
    DateTime? lastStatisticsTime;

    if (bytes.isNotEmpty) {
      final r = BinaryReader(bytes);
      while (!r.isEOF) {
        final (fieldId, wireType) = r.readFieldTag();
        switch (fieldId) {
          case SpaceStatsFieldId.totalRecordCount:
            totalRecordCount = r.readVarint();
            break;
          case SpaceStatsFieldId.totalTableDataSizeBytes:
            totalTableDataSizeBytes = r.readVarint();
            break;
          case SpaceStatsFieldId.totalIndexDataSizeBytes:
            totalIndexDataSizeBytes = r.readVarint();
            break;
          case SpaceStatsFieldId.lastStatisticsTime:
            lastStatisticsTime =
                DateTime.fromMillisecondsSinceEpoch(r.readFixed64());
            break;
          default:
            r.skipField(wireType);
            break;
        }
      }
    }

    return SpaceStats(
      totalRecordCount: totalRecordCount,
      totalTableDataSizeBytes: totalTableDataSizeBytes,
      totalIndexDataSizeBytes: totalIndexDataSizeBytes,
      lastStatisticsTime: lastStatisticsTime,
    );
  }
}
