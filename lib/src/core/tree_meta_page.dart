import 'dart:typed_data';

import '../handler/binary_codec.dart';
import '../handler/meta_binary_codec.dart';
import 'btree_page.dart';
import 'ngh_page.dart';

/// Stable field IDs for [TreeMetaPagePayload]. Reserved: 3..127, 128..255 extension.
abstract final class TreeMetaPageFieldId {
  static const int partitionLocal = 1;
  static const int treeGlobalMeta = 2;
}

/// Extensible page-0 payload for B+Tree / NGH partition files.
///
/// Every partition file stores [partitionLocal] (field 1) — see
/// [PartitionLocalStats] for the append-only blob evolution rules.
/// Partition 0 additionally stores [treeGlobalMeta] (field 2).
final class TreeMetaPagePayload {
  static const int payloadMagic = 0x31504D54; // 'TMP1'
  static const int schemaVersion = 1;

  final PartitionLocalStats partitionLocal;
  final Uint8List? treeGlobalMeta;

  const TreeMetaPagePayload({
    required this.partitionLocal,
    this.treeGlobalMeta,
  });

  Uint8List encodePlainPayload() {
    final w = BinaryWriter(initialCapacity: 128);
    w.writeFixed32(payloadMagic);
    w.writeFieldTag(
        TreeMetaPageFieldId.partitionLocal, WireType.lengthDelimited);
    w.writeBytes(partitionLocal.encode());
    if (treeGlobalMeta != null && treeGlobalMeta!.isNotEmpty) {
      w.writeFieldTag(
          TreeMetaPageFieldId.treeGlobalMeta, WireType.lengthDelimited);
      w.writeBytes(treeGlobalMeta!);
    }
    return w.view;
  }

  /// Decode a plain (post-decryption) page-0 payload.
  ///
  /// Hot path: [payloadMagic] (`TMP1`) match → decode fields. O(1) reject of
  /// legacy pages without probing fixed layouts first.
  /// Miss → [_tryDecodeLegacyPayload] (PartitionMetaPage / NghPartitionMetaPage).
  static TreeMetaPagePayload? tryDecodePlainPayload(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final reader = BinaryReader(bytes);
    final magic = reader.readFixed32();
    if (magic != payloadMagic) {
      return _tryDecodeLegacyPayload(bytes);
    }

    PartitionLocalStats? local;
    Uint8List? global;
    while (!reader.isEOF) {
      final (fieldId, wireType) = reader.readFieldTag();
      switch (fieldId) {
        case TreeMetaPageFieldId.partitionLocal:
          local = PartitionLocalStats.tryDecode(reader.readBytes());
          break;
        case TreeMetaPageFieldId.treeGlobalMeta:
          global = reader.readBytes();
          break;
        default:
          reader.skipField(wireType);
      }
    }

    if (local == null) return null;
    return TreeMetaPagePayload(
      partitionLocal: local,
      treeGlobalMeta: global,
    );
  }

  /// Lazy compat when page0 is still a fixed [PartitionMetaPage] /
  /// [NghPartitionMetaPage] (not rewritten during v3 for non-zero partitions).
  static TreeMetaPagePayload? _tryDecodeLegacyPayload(Uint8List bytes) {
    final legacy = PartitionMetaPage.tryDecodePayload(bytes);
    if (legacy != null) {
      return TreeMetaPagePayload(
        partitionLocal: PartitionLocalStats.fromLegacyPartitionMetaPage(legacy),
      );
    }
    final nghLegacy = NghPartitionMetaPage.tryDecodePayload(bytes);
    if (nghLegacy != null) {
      return TreeMetaPagePayload(
        partitionLocal:
            PartitionLocalStats.fromLegacyNghPartitionMetaPage(nghLegacy),
      );
    }
    return null;
  }
}
