/// Strongly typed string identities for tables, indexes, and foreign keys.
///
/// Use [TableUid] / [IndexUid] / [ForeignKeyUid] for stable engine keys:
/// paths, buffers, map keys, persistence, and WAL metadata.
///
/// Use [TableName] / [IndexName] for user-facing surfaces:
/// public API parameters, exceptions, logs, and query/FK DSL literals.
///
/// Both underlying representations are [String], but extension types prevent
/// accidentally passing a logical name where a stable uid is required.
library;

import 'db_exception.dart';
import 'result_status.dart';
import 'result_type.dart';

Never _throwEmptyIdentity(String identityType) {
  throw DbException([
    GeneralStatus(
      type: ResultType.engError,
      message: '$identityType cannot be empty.',
    ),
  ]);
}

/// Stable unique identifier of a table (immutable across renames).
extension type const TableUid(String value) implements String {
  /// Sentinel for schemas not yet assigned a stable uid.
  static const empty = TableUid('');

  bool get isEmpty => value.isEmpty;
  bool get isNotEmpty => value.isNotEmpty;

  String toJson() => value;

  static TableUid? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return TableUid(raw);
  }

  static TableUid parse(String raw) {
    if (raw.isEmpty) {
      _throwEmptyIdentity('TableUid');
    }
    return TableUid(raw);
  }
}

/// Logical table name exposed to database users (mutable on rename).
extension type TableName(String value) implements String {
  bool get isEmpty => value.isEmpty;
  bool get isNotEmpty => value.isNotEmpty;

  String toJson() => value;

  static TableName? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return TableName(raw);
  }

  static TableName parse(String raw) {
    if (raw.isEmpty) {
      _throwEmptyIdentity('TableName');
    }
    return TableName(raw);
  }
}

/// Stable unique identifier of an index (immutable across renames).
extension type const IndexUid(String value) implements String {
  static const empty = IndexUid('');

  bool get isEmpty => value.isEmpty;
  bool get isNotEmpty => value.isNotEmpty;

  String toJson() => value;

  static IndexUid? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return IndexUid(raw);
  }

  static IndexUid parse(String raw) {
    if (raw.isEmpty) {
      _throwEmptyIdentity('IndexUid');
    }
    return IndexUid(raw);
  }

  /// Whether [value] matches engine-issued stable index uid shape.
  ///
  /// Stable ids are `GlobalIdGenerator.
  /// body (length 15)  Logical names fromgenerate("i")` — `'i'` + 14-char Base36
  /// `IndexSchema.actualIndexName` always use `idx_` / `uniq_` and are excluded.
  bool get looksLikeStableUid {
    if (isEmpty) return false;
    if (value == 'pk') return true;
    if (!value.startsWith('i')) return false;
    if (value.startsWith('idx_')) return false; // logical non-unique name
    // uniq_* starts with 'u', already outside the 'i' path below.
    return value.length == 15;
  }
}

/// Logical index name exposed to database users (mutable on rename).
extension type IndexName(String value) implements String {
  bool get isEmpty => value.isEmpty;
  bool get isNotEmpty => value.isNotEmpty;

  String toJson() => value;

  static IndexName? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return IndexName(raw);
  }

  static IndexName parse(String raw) {
    if (raw.isEmpty) {
      _throwEmptyIdentity('IndexName');
    }
    return IndexName(raw);
  }
}

/// Stable unique identifier of a foreign key constraint.
extension type ForeignKeyUid(String value) implements String {
  bool get isEmpty => value.isEmpty;
  bool get isNotEmpty => value.isNotEmpty;

  String toJson() => value;

  static ForeignKeyUid? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return ForeignKeyUid(raw);
  }

  static ForeignKeyUid parse(String raw) {
    if (raw.isEmpty) {
      _throwEmptyIdentity('ForeignKeyUid');
    }
    return ForeignKeyUid(raw);
  }
}
