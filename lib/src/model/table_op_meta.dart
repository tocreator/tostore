import '../model/wal_pointer.dart';

/// Table-level WAL-tracked maintenance operation (e.g., clear / drop table).
///
/// This is stored in WAL metadata so that:
/// - On crash/restart, we re-apply only **pending** (completed=false) clear/drop
///   operations before WAL replay; completed ops are not re-executed.
/// - During WAL replay, we skip entries that logically precede the clear/drop
///   cutoff (using all ops, completed or not).
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

  /// True after the physical clear/drop has finished successfully.
  /// Only ops with [completed]==false are re-executed on startup; completed ops
  /// remain in meta only for WAL cutoff semantics until pruned by checkpoint.
  final bool completed;

  TableOpMeta({
    required this.opId,
    required this.table,
    required this.type,
    required this.cutoff,
    required this.createdAt,
    this.completed = false,
  });

  TableOpMeta copyWith({bool? completed}) => TableOpMeta(
        opId: opId,
        table: table,
        type: type,
        cutoff: cutoff,
        createdAt: createdAt,
        completed: completed ?? this.completed,
      );

  Map<String, dynamic> toJson() => {
        'opId': opId,
        'table': table,
        'type': type,
        'cutoff': cutoff.toJson(),
        'createdAt': createdAt,
        'completed': completed,
      };

  static TableOpMeta fromJson(Map<String, dynamic> json) => TableOpMeta(
        opId: (json['opId'] as String?) ?? '',
        table: (json['table'] as String?) ?? '',
        type: (json['type'] as String?) ?? 'clear',
        cutoff: WalPointer.fromJson((json['cutoff'] as Map<String, dynamic>)),
        createdAt:
            (json['createdAt'] as String?) ?? DateTime.now().toIso8601String(),
        completed: (json['completed'] as bool?) ?? false,
      );
}
