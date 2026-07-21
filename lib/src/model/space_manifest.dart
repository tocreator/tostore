import 'table_identity.dart';

/// Deferred, space-scoped metadata that may grow large and is loaded asynchronously.
/// A manifest holds inventory and statistics that must not block space open.
///
/// Persisted in `_system_internal_kv_store` (`isGlobal: false`) under
/// [SpaceManifestCodec.internalKvKey] as a TOBF blob.
class SpaceManifest {
  /// Non-global table UIDs actively used in this space.
  final Set<TableUid> activeTableUids;

  const SpaceManifest({
    this.activeTableUids = const <TableUid>{},
  });

  static const empty = SpaceManifest();

  SpaceManifest copyWith({
    Set<TableUid>? activeTableUids,
  }) {
    return SpaceManifest(
      activeTableUids: activeTableUids ?? this.activeTableUids,
    );
  }
}
