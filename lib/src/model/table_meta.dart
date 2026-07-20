import 'dart:typed_data';

import 'meta_info.dart';
import 'table_identity.dart';
import 'table_schema.dart';

/// In-memory table metadata (mirrors one `_system_table_meta` row).
///
/// [schema], [fieldLayout], and [extra] are full models in memory; they are
/// serialized to binary blobs only when persisting to the system table.
class TableMeta {
  final TableUid tableUid;
  final TableName tableName;
  final bool isGlobal;
  final TableSchema schema;
  final FieldStorageLayout fieldLayout;
  final int dirIndex;
  final TableMetaExtra? extra;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TableMeta({
    required this.tableUid,
    required this.tableName,
    required this.isGlobal,
    required this.schema,
    required this.fieldLayout,
    required this.dirIndex,
    this.extra,
    required this.createdAt,
    required this.updatedAt,
  });

  TableMeta copyWith({
    TableUid? tableUid,
    TableName? tableName,
    bool? isGlobal,
    TableSchema? schema,
    FieldStorageLayout? fieldLayout,
    int? dirIndex,
    TableMetaExtra? extra,
    bool clearExtra = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TableMeta(
      tableUid: tableUid ?? this.tableUid,
      tableName: tableName ?? this.tableName,
      isGlobal: isGlobal ?? this.isGlobal,
      schema: schema ?? this.schema,
      fieldLayout: fieldLayout ?? this.fieldLayout,
      dirIndex: dirIndex ?? this.dirIndex,
      extra: clearExtra ? null : (extra ?? this.extra),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Extensible binary bag for infrequent / future TableMeta fields.
///
/// Unknown field tags are preserved on round-trip so older engines can keep
/// data written by newer versions. Empty bags serialize to null / omit column.
class TableMetaExtra {
  /// Raw field-tag payload (TOBF body without outer framing).
  final Uint8List raw;

  const TableMetaExtra(this.raw);

  bool get isEmpty => raw.isEmpty;

  static TableMetaExtra? fromBytes(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    return TableMetaExtra(bytes);
  }

  Uint8List? toBytesOrNull() => isEmpty ? null : raw;
}
