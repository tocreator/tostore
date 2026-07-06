import 'dart:convert';
import 'dart:typed_data';

import '../model/space_manifest.dart';
import '../model/table_identity.dart';

/// Binary encoder/decoder for per-space deferred metadata ([SpaceManifest]).
///
/// Format (little-endian):
/// ```
/// [magic:u32='SpMf'][formatVersion:u8][flags:u8][headerSize:u16]
/// [sectionType:u16][sectionLen:u32][sectionPayload]...
/// ```
///
/// - Unknown sections are skipped by length, so new section types can be added
///   without a format migration.
/// - [flags] bit0 is reserved for optional payload encryption at the storage layer.
class SpaceManifestCodec {
  /// 'SpMf' in little-endian byte order.
  static const int _magic = 0x664D7053;

  static const int formatVersion = 1;

  /// Minimum header size; future versions may increase [headerSize].
  static const int _headerSize = 8;

  /// bit0: entire file payload after header is encrypted (reserved).
  static const int flagEncryptedPayload = 1 << 0;

  static const int maxSectionCount = 256;
  static const int maxSectionPayloadBytes = 256 * 1024 * 1024; // 256 MB
  static const int maxActiveTableUidCount = 1000000;
  static const int maxUidByteLength = 256;

  static Uint8List encode(SpaceManifest manifest) {
    final builder = BytesBuilder(copy: false);
    final header = ByteData(_headerSize);
    header.setUint32(0, _magic, Endian.little);
    header.setUint8(4, formatVersion);
    header.setUint8(5, 0); // flags
    header.setUint16(6, _headerSize, Endian.little);
    builder.add(header.buffer.asUint8List());

    _writeSection(
      builder,
      SpaceManifestSectionType.activeTableUids,
      _encodeActiveTableUids(manifest.activeTableUids),
    );

    return builder.toBytes();
  }

  static SpaceManifest decode(Uint8List bytes) {
    if (bytes.length < _headerSize) return SpaceManifest.empty;

    final header = ByteData.sublistView(bytes);
    if (header.getUint32(0, Endian.little) != _magic) {
      return SpaceManifest.empty;
    }

    final version = header.getUint8(4);
    if (version != formatVersion) {
      return SpaceManifest.empty;
    }

    final headerSize = header.getUint16(6, Endian.little);
    if (headerSize < _headerSize || headerSize > bytes.length) {
      return SpaceManifest.empty;
    }

    var activeTableUids = const <TableUid>[];
    var offset = headerSize;

    while (offset + 6 <= bytes.length) {
      final sectionView = ByteData.sublistView(bytes, offset);
      final sectionType = sectionView.getUint16(0, Endian.little);
      final sectionLen = sectionView.getUint32(2, Endian.little);
      offset += 6;

      if (sectionLen > maxSectionPayloadBytes ||
          offset + sectionLen > bytes.length) {
        break;
      }

      final payload = bytes.sublist(offset, offset + sectionLen);
      offset += sectionLen;

      switch (sectionType) {
        case SpaceManifestSectionType.activeTableUids:
          activeTableUids = _decodeActiveTableUids(payload);
          break;
        default:
          // Unknown section: already skipped by length.
          break;
      }
    }

    return SpaceManifest(activeTableUids: activeTableUids);
  }

  static void _writeSection(
    BytesBuilder builder,
    int sectionType,
    Uint8List payload,
  ) {
    final header = ByteData(6);
    header.setUint16(0, sectionType, Endian.little);
    header.setUint32(2, payload.length, Endian.little);
    builder.add(header.buffer.asUint8List());
    builder.add(payload);
  }

  static Uint8List _encodeActiveTableUids(List<TableUid> uids) {
    final builder = BytesBuilder(copy: false);
    final count = uids.length.clamp(0, maxActiveTableUidCount);
    builder.add(_u32le(count));

    for (int i = 0; i < count; i++) {
      final uidBytes = utf8.encode(uids[i].value);
      final len = uidBytes.length.clamp(0, maxUidByteLength);
      builder.add(_u32le(len));
      if (len > 0) {
        builder.add(uidBytes.sublist(0, len));
      }
    }

    return builder.toBytes();
  }

  static List<TableUid> _decodeActiveTableUids(Uint8List bytes) {
    if (bytes.length < 4) return const <TableUid>[];
    final reader = _Reader(bytes);
    final count = reader.u32le();
    if (count > maxActiveTableUidCount) return const <TableUid>[];

    final list = <TableUid>[];
    for (int i = 0; i < count; i++) {
      final len = reader.u32le();
      if (len > maxUidByteLength) break;
      final uidBytes = reader.bytes(len);
      if (uidBytes == null) break;
      list.add(TableUid(utf8.decode(uidBytes)));
    }
    return list;
  }

  static Uint8List _u32le(int value) {
    final bd = ByteData(4)..setUint32(0, value, Endian.little);
    return bd.buffer.asUint8List();
  }
}

class _Reader {
  final Uint8List _data;
  int _offset = 0;

  _Reader(this._data);

  int u32le() {
    if (_offset + 4 > _data.length) return 0;
    final value = ByteData.sublistView(_data, _offset).getUint32(0, Endian.little);
    _offset += 4;
    return value;
  }

  Uint8List? bytes(int length) {
    if (length < 0 || _offset + length > _data.length) return null;
    final slice = _data.sublist(_offset, _offset + length);
    _offset += length;
    return slice;
  }
}
