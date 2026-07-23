import 'table_identity.dart';
import 'table_schema.dart';

class SystemTable {
  /// Table structure metadata system table (global, dir_index fixed at 0).
  static const String tableMetaName = '_system_table_meta';

  static const String tableMetaUidField = 'table_uid';
  static const String tableMetaNameField = 'table_name';
  static const String tableMetaIsGlobalField = 'is_global';
  static const String tableMetaSchemaField = 'schema';
  static const String tableMetaFieldLayoutField = 'field_layout';
  static const String tableMetaDirIndexField = 'dir_index';
  static const String tableMetaExtraField = 'extra';
  static const String tableMetaCreatedAtField = 'created_at';
  static const String tableMetaUpdatedAtField = 'updated_at';

  /// Fixed data directory index for [_system_table_meta] itself.
  static const int tableMetaDirIndex = 0;

  /// Bootstrap-only stable IDs (pre-generated; other system tables generate at create).
  static const TableUid tableMetaTableUid = TableUid('t00904io78tpkao');
  static const IndexUid tableMetaNameIndexUid = IndexUid('i00904io78tpkap');
  static const IndexUid tableMetaDirIndexUid = IndexUid('i00904io78tpkaq');

  /// Foreign key references system table name
  /// This table stores the reverse mapping of foreign key relationships
  /// Structure: referenced_table -> referencing_table -> foreign_key_info
  static const String _fkReferencesName = '_system_fk_references';

  /// User-facing key-value store table names.
  ///
  /// Early design: auto-increment PK + unique secondary index on [key].
  static const String _keyValueName = '_system_kv_store';
  static const String _globalKeyValueName = '_system_global_kv_store';

  /// Engine-internal key-value store table names.
  ///
  /// Used for metadata, config, stats, and other small engine state that
  /// should not live as separate tiny files. [key] is the primary key for
  /// direct B-tree lookup (no secondary unique index on key).
  static const String _internalKeyValueName = '_system_internal_kv_store';
  static const String _internalGlobalKeyValueName =
      '_system_internal_global_kv_store';

  /// Key-value store field names
  static const String keyValueKeyField = 'key';
  static const String keyValueValueField = 'value';
  static const String keyValueUpdatedAtField = 'updated_at';
  static const String keyValueExpiresAtField = 'expires_at';
  static const String keyValueExpiryIndexName = '_system_kv_expiry';

  /// Stable uid for the engine-managed KV expiry index (immutable across renames).
  /// Pre-generated opaque id — do not use semantic names in paths.
  static const IndexUid keyValueExpiryIndexUid = IndexUid('i00907llpssrl6q');

  /// get user-facing key-value store table name
  static String getKeyValueName(bool isGlobal) {
    return isGlobal ? _globalKeyValueName : _keyValueName;
  }

  /// get engine-internal key-value store table name
  static String getInternalKeyValueName(bool isGlobal) {
    return isGlobal ? _internalGlobalKeyValueName : _internalKeyValueName;
  }

  static bool isKeyValueTable(String tableName) {
    return tableName == _keyValueName || tableName == _globalKeyValueName;
  }

  static bool isInternalKeyValueTable(String tableName) {
    return tableName == _internalKeyValueName ||
        tableName == _internalGlobalKeyValueName;
  }

  /// get foreign key references system table name
  static String getFkReferencesName() {
    return _fkReferencesName;
  }

  /// Key migration per-table progress (global table).
  static const String keyMigrationProgressTableName = '_system_key_migration';

  /// Stable table identity (immutable across renames). Do not store logical names.
  static const String keyMigrationTableUidField = 'table_uid';
  static const String keyMigrationSpaceNameField = 'space_name';
  static const String keyMigrationStatusField = 'status';
  static const String keyMigrationCheckpointField = 'checkpoint_key';
  static const String keyMigrationProgressKeyField = 'progress_key';

  /// Scope marker for global tables in key migration progress rows.
  static const String globalMigrationScope = '__global__';

  static const Set<String> _systemTableNames = {
    tableMetaName,
    _fkReferencesName,
    _keyValueName,
    _globalKeyValueName,
    _internalKeyValueName,
    _internalGlobalKeyValueName,
    keyMigrationProgressTableName,
    // Legacy system table names (append when a system table is removed):
    'system_fk_references',
    'kv_store',
    'global_kv_store',
  };

  /// True if [tableName] is a system table (current or legacy).
  static bool isSystemTable(String tableName) =>
      _systemTableNames.contains(tableName);

  /// All known system table names (current + deprecated).
  /// This is a const set and must remain stable across versions.
  static Set<String> get systemTableNames => _systemTableNames;

  /// get all table schemas
  static List<TableSchema> gettableSchemas = [
    tableMetaTable(),
    internalKVTable(false),
    internalKVTable(true),
    _fkReferencesTable(),
    _kVTable(false),
    _kVTable(true),
    _keyMigrationProgressTable(),
  ];

  /// Whether [tableName] is the table-meta system table.
  static bool isTableMetaTable(String tableName) => tableName == tableMetaName;

  /// Table structure metadata store (binary schema + layout per table).
  ///
  /// Uses fixed [tableMetaTableUid] / index UIDs so bootstrap can construct
  /// [TableContext] without reading this table first.
  static TableSchema tableMetaTable() => TableSchema(
        name: tableMetaName,
        tableId: tableMetaName,
        isGlobal: true,
        primaryKeyConfig: const PrimaryKeyConfig(
          name: tableMetaUidField,
          type: PrimaryKeyType.none,
        ),
        fields: const [
          FieldSchema(
            name: tableMetaNameField,
            fieldId: tableMetaNameField,
            type: DataType.text,
            nullable: false,
            unique: true,
          ),
          FieldSchema(
            name: tableMetaIsGlobalField,
            fieldId: tableMetaIsGlobalField,
            type: DataType.boolean,
            nullable: false,
          ),
          FieldSchema(
            name: tableMetaSchemaField,
            fieldId: tableMetaSchemaField,
            type: DataType.blob,
            nullable: false,
          ),
          FieldSchema(
            name: tableMetaFieldLayoutField,
            fieldId: tableMetaFieldLayoutField,
            type: DataType.blob,
            nullable: false,
          ),
          FieldSchema(
            name: tableMetaDirIndexField,
            fieldId: tableMetaDirIndexField,
            type: DataType.integer,
            nullable: false,
          ),
          FieldSchema(
            name: tableMetaExtraField,
            fieldId: tableMetaExtraField,
            type: DataType.blob,
          ),
          FieldSchema(
            name: tableMetaCreatedAtField,
            fieldId: tableMetaCreatedAtField,
            type: DataType.datetime,
            nullable: false,
            defaultValueType: DefaultValueType.currentTimestamp,
          ),
          FieldSchema(
            name: tableMetaUpdatedAtField,
            fieldId: tableMetaUpdatedAtField,
            type: DataType.datetime,
            nullable: false,
            defaultValueType: DefaultValueType.currentTimestamp,
          ),
        ],
        indexes: [
          IndexSchema(
            fields: const [tableMetaNameField],
            unique: true,
          ).copyWith(indexUid: tableMetaNameIndexUid),
          IndexSchema(
            fields: const [tableMetaIsGlobalField, tableMetaDirIndexField],
          ).copyWith(indexUid: tableMetaDirIndexUid),
        ],
      ).copyWith(tableUid: tableMetaTableUid);

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
        tableId: 'system_fk_references',
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

  /// Per-table key migration checkpoint storage (global).
  static TableSchema _keyMigrationProgressTable() => TableSchema(
        name: keyMigrationProgressTableName,
        tableId: keyMigrationProgressTableName,
        isGlobal: true,
        primaryKeyConfig: const PrimaryKeyConfig(
          name: keyMigrationProgressKeyField,
          type: PrimaryKeyType.none,
        ),
        fields: const [
          FieldSchema(
            name: keyMigrationTableUidField,
            fieldId: keyMigrationTableUidField,
            type: DataType.text,
            nullable: false,
          ),
          FieldSchema(
            name: keyMigrationSpaceNameField,
            fieldId: keyMigrationSpaceNameField,
            type: DataType.text,
            nullable: false,
          ),
          FieldSchema(
            name: keyMigrationStatusField,
            fieldId: keyMigrationStatusField,
            type: DataType.text,
            nullable: false,
          ),
          FieldSchema(
            name: keyMigrationCheckpointField,
            fieldId: keyMigrationCheckpointField,
            type: DataType.text,
          ),
        ],
        indexes: const [
          IndexSchema(
            fields: [keyMigrationTableUidField, keyMigrationSpaceNameField],
            unique: true,
          ),
          IndexSchema(fields: [keyMigrationStatusField]),
        ],
      );

  /// User-facing key-value store table.
  ///
  /// Uses auto-increment PK with a unique secondary index on [key]
  /// (legacy layout; keep unchanged for compatibility).
  static TableSchema _kVTable(bool isGlobal) => TableSchema(
        name: getKeyValueName(isGlobal),
        tableId: isGlobal ? 'global_kv_store' : 'kv_store',
        isGlobal: isGlobal,
        primaryKeyConfig: const PrimaryKeyConfig(),
        fields: [
          const FieldSchema(
              name: keyValueKeyField,
              fieldId: keyValueKeyField,
              type: DataType.text,
              nullable: false,
              unique: true),
          const FieldSchema(
              name: keyValueValueField,
              fieldId: keyValueValueField,
              type: DataType.text),
          const FieldSchema(
              name: keyValueUpdatedAtField,
              fieldId: keyValueUpdatedAtField,
              type: DataType.datetime,
              defaultValueType: DefaultValueType.currentTimestamp),
          const FieldSchema(
            name: keyValueExpiresAtField,
            fieldId: keyValueExpiresAtField,
            type: DataType.datetime,
          ),
        ],
        indexes: const [
          IndexSchema(fields: [keyValueKeyField], unique: true),
          IndexSchema(fields: [keyValueUpdatedAtField]),
        ],
      );

  /// Engine-internal key-value store table.
  ///
  /// [key] is the primary key ([PrimaryKeyType.none]) so point lookups hit the
  /// primary B-tree directly — no secondary unique index on key.
  /// No TTL fields: intended for durable engine metadata / config / stats.
  static TableSchema internalKVTable(bool isGlobal) => TableSchema(
        name: getInternalKeyValueName(isGlobal),
        tableId: getInternalKeyValueName(isGlobal),
        isGlobal: isGlobal,
        primaryKeyConfig: const PrimaryKeyConfig(
          name: keyValueKeyField,
          type: PrimaryKeyType.none,
        ),
        fields: const [
          FieldSchema(
            name: keyValueValueField,
            fieldId: keyValueValueField,
            type: DataType.blob,
          ),
          FieldSchema(
            name: keyValueUpdatedAtField,
            fieldId: keyValueUpdatedAtField,
            type: DataType.datetime,
            defaultValueType: DefaultValueType.currentTimestamp,
          ),
        ],
      );
}
