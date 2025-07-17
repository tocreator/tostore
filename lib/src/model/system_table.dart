import 'table_schema.dart';

class SystemTable {
  /// Key-value store table name
  static const String _keyValueName = 'kv_store';
  static const String _globalKeyValueName = 'global_kv_store';

  /// get key-value store table name
  static String getKeyValueName(bool isGlobal) {
    return isGlobal ? _globalKeyValueName : _keyValueName;
  }

  // is a system table
  static bool isSystemTable(String tableName) {
    return tableName == _keyValueName || tableName == _globalKeyValueName;
  }

  /// get all table schemas
  static List<TableSchema> gettableSchemas = [
    _kVTable(false),
    _kVTable(true),
  ];

  /// Key-value store table
  static TableSchema _kVTable(bool isGlobal) => TableSchema(
        name: getKeyValueName(isGlobal),
        tableId: getKeyValueName(isGlobal),
        isGlobal: isGlobal,
        primaryKeyConfig: const PrimaryKeyConfig(),
        fields: [
          const FieldSchema(
              name: 'key',
              fieldId: 'key',
              type: DataType.text,
              nullable: false,
              unique: true),
          const FieldSchema(
              name: 'value', fieldId: 'value', type: DataType.text),
          const FieldSchema(
              name: 'updated_at',
              fieldId: 'updated_at',
              type: DataType.datetime,
              defaultValueType: DefaultValueType.currentTimestamp),
        ],
        indexes: const [
          IndexSchema(fields: ['key'], unique: true),
          IndexSchema(fields: ['updated_at']),
        ],
      );
}
