import 'dart:typed_data';

import '../model/space_manifest.dart';
import '../model/table_identity.dart';
import 'binary_codec.dart';

/// Stable field IDs for [SpaceManifest] binary encoding.
abstract final class SpaceManifestFieldId {
  /// Repeated length-delimited [TableUid] strings.
  static const int activeTableUids = 1;
}

/// TOBF codec for [SpaceManifest] — no JSON intermediate structures.
final class SpaceManifestCodec {
  SpaceManifestCodec._();

  /// Internal KV key in `_system_internal_kv_store` (`isGlobal: false`).
  static const String internalKvKey = 'meta.space_manifest';

  static Uint8List encode(SpaceManifest manifest) {
    final uids = manifest.activeTableUids;
    if (uids.isEmpty) return Uint8List(0);

    final w = BinaryWriter(initialCapacity: 32 + uids.length * 24);
    for (final uid in uids) {
      if (uid.isEmpty) continue;
      w.writeFieldTag(
          SpaceManifestFieldId.activeTableUids, WireType.lengthDelimited);
      w.writeString(uid.value);
    }
    return w.view;
  }

  static SpaceManifest decode(Uint8List bytes) {
    if (bytes.isEmpty) return SpaceManifest.empty;

    final r = BinaryReader(bytes);
    final uids = <TableUid>{};
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case SpaceManifestFieldId.activeTableUids:
          final raw = r.readString();
          if (raw.isNotEmpty) {
            uids.add(TableUid(raw));
          }
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    if (uids.isEmpty) return SpaceManifest.empty;
    return SpaceManifest(activeTableUids: uids);
  }
}
