import 'table_schema.dart';

class SystemTable {
  /// Foreign key references system table name
  /// This table stores the reverse mapping of foreign key relationships
  /// Structure: referenced_table -> referencing_table -> foreign_key_info
  static const String _fkReferencesName = 'system_fk_references';

  /// Key-value store table name
  static const String _keyValueName = 'kv_store';
  static const String _globalKeyValueName = 'global_kv_store';

  /// get key-value store table name
  static String getKeyValueName(bool isGlobal) {
    return isGlobal ? _globalKeyValueName : _keyValueName;
  }

  /// get foreign key references system table name
  static String getFkReferencesName() {
    return _fkReferencesName;
  }

  // is a system table
  static bool isSystemTable(String tableName) {
    return tableName == _keyValueName ||
        tableName == _globalKeyValueName ||
        tableName == _fkReferencesName;
  }

  /// get all table schemas
  static List<TableSchema> gettableSchemas = [
    _fkReferencesTable(),
    _kVTable(false),
    _kVTable(true),
  ];

  /// Foreign key references system table
  ///
  /// This table stores the reverse mapping of foreign key relationships for O(1) lookup.
  /// Structure:
  /// - referenced_table: The table being referenced (parent table)
  /// - referencing_table: The table that references (child table)
  /// - fk_name: Foreign key constraint name
  /// - fk_fields: JSON array of foreign key field names
  /// - ref_fields: JSON array of referenced field names
  /// - on_delete: Cascade action on delete
  /// - on_update: Cascade action on update
  /// - enabled: Whether the foreign key is enabled
  ///
  /// Indexes:
  /// - Primary key: (referenced_table, referencing_table, fk_name) for O(1) lookup
  /// - Index on referenced_table: For fast lookup of all tables referencing a given table
  static TableSchema _fkReferencesTable() => TableSchema(
        name: _fkReferencesName,
        tableId: _fkReferencesName,
        isGlobal: true, // System table, always global
        primaryKeyConfig: const PrimaryKeyConfig(),
        fields: [
          const FieldSchema(
            name: 'referenced_table',
            fieldId: 'referenced_table',
            type: DataType.text,
            nullable: false,
          ),
          const FieldSchema(
            name: 'referencing_table',
            fieldId: 'referencing_table',
            type: DataType.text,
            nullable: false,
          ),
          const FieldSchema(
            name: 'fk_name',
            fieldId: 'fk_name',
            type: DataType.text,
            nullable: false,
          ),
          const FieldSchema(
            name: 'fk_fields',
            fieldId: 'fk_fields',
            type: DataType.text, // JSON array
            nullable: false,
          ),
          const FieldSchema(
            name: 'ref_fields',
            fieldId: 'ref_fields',
            type: DataType.text, // JSON array
            nullable: false,
          ),
          const FieldSchema(
            name: 'on_delete',
            fieldId: 'on_delete',
            type: DataType.text,
            nullable: false,
          ),
          const FieldSchema(
            name: 'on_update',
            fieldId: 'on_update',
            type: DataType.text,
            nullable: false,
          ),
          const FieldSchema(
            name: 'enabled',
            fieldId: 'enabled',
            type: DataType.boolean,
            nullable: false,
          ),
        ],
        indexes: const [
          // Composite unique index: (referenced_table, referencing_table, fk_name)
          // This ensures no duplicate foreign key entries
          IndexSchema(
            fields: ['referenced_table', 'referencing_table', 'fk_name'],
            unique: true,
          ),
          // Index on referenced_table for fast lookup of all referencing tables
          IndexSchema(fields: ['referenced_table']),
          // Index on referencing_table for reverse lookup (optional, for completeness)
          IndexSchema(fields: ['referencing_table']),
        ],
      );

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
