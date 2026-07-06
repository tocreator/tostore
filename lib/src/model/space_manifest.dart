import 'table_identity.dart';

/// Deferred, space-scoped metadata that may grow large and is loaded asynchronously.
/// a manifest holds inventory and statistics that must not block space open.
///
/// Persisted as `space_manifest.bin` per space.
class SpaceManifest {
  /// Non-global table UIDs actively used in this space.
  final List<TableUid> activeTableUids;

  const SpaceManifest({
    this.activeTableUids = const <TableUid>[],
  });

  static const empty = SpaceManifest();

  SpaceManifest copyWith({
    List<TableUid>? activeTableUids,
  }) {
    return SpaceManifest(
      activeTableUids: activeTableUids ?? this.activeTableUids,
    );
  }
}

/// Section type identifiers inside [SpaceManifestCodec].
///
/// Unknown section types are skipped on decode so new fields can be added
/// without breaking older engines.
abstract final class SpaceManifestSectionType {
  /// List of non-global table UIDs active in the space.
  static const int activeTableUids = 0x0001;
}
