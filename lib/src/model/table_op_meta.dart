import '../model/wal_pointer.dart';

/// Table-level WAL-tracked maintenance operation (e.g., clear / drop table).
///
/// This is stored in WAL metadata so that:
/// - On crash/restart, we can re-apply pending clear/drop operations before WAL replay;
/// - During WAL replay, we can skip entries that logically precede the clear/drop cutoff.
class TableOpMeta {
  /// Unique operation id (generated via GlobalIdGenerator).
  final String opId;

  /// Target table name.
  final String table;

  /// Operation type: 'clear' | 'drop'.
  final String type;

  /// WAL pointer at which this operation logically takes effect.
  ///
  /// All WAL entries for [table] at or before this pointer should be skipped
  /// during recovery, because the clear/drop operation rewrites the table
  /// state at this boundary.
  final WalPointer cutoff;

  /// ISO8601 created time, for diagnostics only.
  final String createdAt;

  TableOpMeta({
    required this.opId,
    required this.table,
    required this.type,
    required this.cutoff,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'opId': opId,
        'table': table,
        'type': type,
        'cutoff': cutoff.toJson(),
        'createdAt': createdAt,
      };

  static TableOpMeta fromJson(Map<String, dynamic> json) => TableOpMeta(
        opId: (json['opId'] as String?) ?? '',
        table: (json['table'] as String?) ?? '',
        type: (json['type'] as String?) ?? 'clear',
        cutoff: WalPointer.fromJson((json['cutoff'] as Map<String, dynamic>)),
        createdAt:
            (json['createdAt'] as String?) ?? DateTime.now().toIso8601String(),
      );
}
