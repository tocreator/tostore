import 'dart:convert';
import 'dart:typed_data';

import '../model/table_identity.dart';

/// Binary encoder and decoder for the list of table UIDs inside a space.
///
/// Prevents the overhead of JSON maps or string parsing when loading table lists
/// for spaces on startup.
class SpaceTablesCodec {
  static Uint8List encode(List<TableUid> uids) {
    final builder = BytesBuilder(copy: false);
    final bd = ByteData(4)..setUint32(0, uids.length, Endian.big);
    builder.add(bd.buffer.asUint8List());
    for (final uid in uids) {
      final bytes = utf8.encode(uid.value);
      final lenBd = ByteData(4)..setUint32(0, bytes.length, Endian.big);
      builder.add(lenBd.buffer.asUint8List());
      builder.add(bytes);
    }
    return builder.toBytes();
  }

  static List<TableUid> decode(Uint8List bytes) {
    if (bytes.isEmpty) return const <TableUid>[];
    final list = <TableUid>[];
    final bd = ByteData.sublistView(bytes);
    int offset = 0;
    if (offset + 4 > bytes.length) return const <TableUid>[];
    final count = bd.getUint32(offset, Endian.big);
    offset += 4;
    for (int i = 0; i < count; i++) {
      if (offset + 4 > bytes.length) break;
      final len = bd.getUint32(offset, Endian.big);
      offset += 4;
      if (offset + len > bytes.length) break;
      final stringBytes = bytes.sublist(offset, offset + len);
      offset += len;
      list.add(TableUid(utf8.decode(stringBytes)));
    }
    return list;
  }
}
