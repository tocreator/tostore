import 'table_schema.dart';

/// Table context, mainly used to pass resolved table info conveniently across the engine path.
class TableContext {
  final String tableUid; // Table unique identifier
  String tableName; // Table name (can be updated on renaming in memory context)
  final bool isGlobal; // Whether it is a global table
  final int dataDirIndex; // Data directory index
  final TableSchema schema; // Schema snapshot

  TableContext({
    required this.tableUid,
    required this.tableName,
    required this.isGlobal,
    required this.dataDirIndex,
    required this.schema,
  });

  @override
  String toString() =>
      'TableContext(uid: $tableUid, name: $tableName, isGlobal: $isGlobal, dir: $dataDirIndex, schemaVersion: ${schema.schemaVersion})';
}

/// Index context, used for index operations.
class IndexContext {
  final String indexUid;
  final String indexName;
  final IndexSchema schema;
  final TableContext table;

  IndexContext({
    required this.indexUid,
    required this.indexName,
    required this.schema,
    required this.table,
  });

  @override
  String toString() =>
      'IndexContext(uid: $indexUid, name: $indexName, table: ${table.tableName})';
}
