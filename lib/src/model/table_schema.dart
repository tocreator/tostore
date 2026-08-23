import 'dart:convert';
import 'dart:math' show sqrt;
import 'dart:typed_data';

import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../handler/sha256.dart';
import '../handler/value_matcher.dart';
import 'db_exception.dart';
import 'id_generator.dart';
import 'result_status.dart';
import 'result_type.dart';
import 'table_identity.dart';

/// table schema
class TableSchema {
  /// Internal prefix reserved for engine-level/system tables and fields.
  /// Business projects may use `system_` as a prefix; only `_system_` is treated
  /// as reserved by the engine.
  static const String internalSystemPrefix = '_system_';

  /// Internal virtual field name for TTL ingest-time source.
  static const String internalTtlIngestTsMsField = '_system_ingest_ts_ms';

  /// Table name
  final String name;

  /// Primary key configuration
  final PrimaryKeyConfig primaryKeyConfig;

  /// Field list
  final List<FieldSchema> fields;

  /// Index list
  final List<IndexSchema> indexes;

  /// Foreign key constraints list
  final List<ForeignKeySchema> foreignKeys;

  /// Whether it's a global table
  final bool isGlobal;

  /// Table unique identifier, used for rename detection
  final String? tableId;

  /// Stable internal unique identifier for routing and buffers
  final TableUid tableUid;

  /// Schema structure version tracking migration tasks
  final String? schemaVersion;

  /// Whether this is a system metadata table
  final bool isSystemTable;

  /// Table-level TTL config.
  /// - null: TTL disabled
  /// - sourceField == null: use internal `_system_ingest_ts_ms`
  final TableTtlConfig? ttlConfig;

  /// List of automatically generated / implicit indexes
  final List<IndexSchema>? autoIndexes;

  // Public constructor
  const TableSchema({
    required this.name,
    required this.primaryKeyConfig,
    required this.fields,
    this.indexes = const [],
    this.foreignKeys = const [],
    this.isGlobal = false,
    this.tableId,
    this.ttlConfig,
  })  : tableUid = TableUid.empty,
        schemaVersion = null,
        isSystemTable = false,
        autoIndexes = null;

  // Private constructor for internal copyWith / fromJson
  const TableSchema._internal({
    required this.name,
    required this.primaryKeyConfig,
    required this.fields,
    required this.indexes,
    required this.foreignKeys,
    required this.isGlobal,
    this.tableId,
    this.ttlConfig,
    this.tableUid = TableUid.empty,
    this.schemaVersion,
    required this.isSystemTable,
    this.autoIndexes,
  });

  /// Reconstruct a fully persisted schema snapshot (binary codec / migration).
  factory TableSchema.rehydrate({
    required String name,
    required PrimaryKeyConfig primaryKeyConfig,
    required List<FieldSchema> fields,
    List<IndexSchema> indexes = const [],
    List<ForeignKeySchema> foreignKeys = const [],
    bool isGlobal = false,
    String? tableId,
    TableTtlConfig? ttlConfig,
    TableUid tableUid = TableUid.empty,
    String? schemaVersion,
    bool isSystemTable = false,
    List<IndexSchema>? autoIndexes,
  }) {
    return TableSchema._internal(
      name: name,
      primaryKeyConfig: primaryKeyConfig,
      fields: fields,
      indexes: indexes,
      foreignKeys: foreignKeys,
      isGlobal: isGlobal,
      tableId: tableId,
      ttlConfig: ttlConfig,
      tableUid: tableUid,
      schemaVersion: schemaVersion,
      isSystemTable: isSystemTable,
      autoIndexes: autoIndexes,
    );
  }

  /// Get primary key name
  String get primaryKey => primaryKeyConfig.name;

  /// Prepare a caller-defined schema for first-time table creation.
  TableSchema materializeForCreate({bool isSystemTable = false}) {
    final schemaVersion = GlobalIdGenerator.generate('s');
    if (isSystemTable) {
      return TableSchema._internal(
        name: name,
        primaryKeyConfig: primaryKeyConfig,
        fields: fields,
        indexes: indexes,
        foreignKeys: foreignKeys,
        isGlobal: isGlobal,
        tableId: tableId,
        ttlConfig: ttlConfig,
        tableUid: tableUid.isNotEmpty
            ? tableUid
            : TableUid(GlobalIdGenerator.generate('t')),
        schemaVersion: schemaVersion,
        isSystemTable: true,
        autoIndexes: autoIndexes,
      );
    }

    final cleaned = cleanInternalFields();
    return TableSchema._internal(
      name: cleaned.name,
      primaryKeyConfig: cleaned.primaryKeyConfig,
      fields: cleaned.fields,
      indexes: cleaned.indexes,
      foreignKeys: cleaned.foreignKeys,
      isGlobal: cleaned.isGlobal,
      tableId: cleaned.tableId,
      ttlConfig: cleaned.ttlConfig,
      tableUid: TableUid(GlobalIdGenerator.generate('t')),
      schemaVersion: schemaVersion,
      isSystemTable: false,
    );
  }

  /// Returns a clean copy of the schema with all internal/metadata fields stripped.
  /// Used at user-schema input boundaries so definitions cannot inject engine fields.
  TableSchema cleanInternalFields() {
    return TableSchema._internal(
      name: name,
      primaryKeyConfig: primaryKeyConfig,
      fields: fields,
      indexes:
          indexes.map((i) => i.copyWith(indexUid: IndexUid.empty)).toList(),
      foreignKeys: foreignKeys,
      isGlobal: isGlobal,
      tableId: tableId,
      ttlConfig: ttlConfig,
      tableUid: TableUid.empty,
      schemaVersion: null,
      isSystemTable: false,
      autoIndexes: null,
    );
  }

  /// Returns a new map with primary key first, then other fields in original order.
  /// Use when returning rows from storage so display/serialization shows PK first.
  static Map<String, dynamic> rowWithPrimaryKeyFirst(
    String primaryKeyName,
    dynamic primaryKeyValue,
    Map<String, dynamic> row,
  ) {
    final out = <String, dynamic>{};
    out[primaryKeyName] = primaryKeyValue;
    for (final e in row.entries) {
      if (e.key == primaryKeyName) continue;
      out[e.key] = e.value;
    }
    return out;
  }

  /// Get all indexes (Consolidated list of Explicit, Unique, and FK indexes)
  List<IndexSchema> getAllIndexes() {
    if (autoIndexes != null) {
      return [
        ...indexes,
        ...autoIndexes!,
      ];
    }

    final allIndexes = <IndexSchema>[];
    for (final index in indexes) {
      if (_isPrimaryKeyOnlyIndex(index)) {
        Logger.warn(
          'Table $name contains redundant primary-key index ${index.actualIndexName}; table data is already range-partitioned by PK, ignoring this index.',
        );
        continue;
      }
      allIndexes.add(index);
    }
    allIndexes.addAll(_computeRawImplicitIndexes());
    return allIndexes;
  }

  /// Dynamically generate implicit indexes and inherit indexUids from oldSchema if matches are found.
  TableSchema generateAutoIndexes({
    TableSchema? oldSchema,
    Map<String, String>? fieldRenames,
    Map<String, String>? indexRenames,
  }) {
    final usedIndexUids = <String>{};
    final claimedOldIndexUids = <String>{};

    IndexUid nextUniqueIndexUid() {
      const maxAttempts = 8;
      for (var i = 0; i < maxAttempts; i++) {
        final uid = IndexUid(GlobalIdGenerator.generate('i'));
        if (uid.isEmpty) continue;
        if (usedIndexUids.add(uid.value)) return uid;
      }
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Failed to allocate a unique indexUid after $maxAttempts attempts',
        ),
      ]);
    }

    IndexUid claimOrAllocate(IndexUid existing) {
      if (existing.isEmpty) return nextUniqueIndexUid();
      if (usedIndexUids.add(existing.value)) return existing;
      return nextUniqueIndexUid();
    }

    // Build effective field rename map
    final effectiveFieldRenames = <String, String>{};
    if (fieldRenames != null) {
      effectiveFieldRenames.addAll(fieldRenames);
    }
    if (oldSchema != null) {
      for (final newField in fields) {
        if (effectiveFieldRenames.containsValue(newField.name)) continue;
        for (final oldField in oldSchema.fields) {
          if (oldField.name == newField.name) continue;
          if (newField.fieldId != null &&
              oldField.fieldId != null &&
              newField.fieldId == oldField.fieldId) {
            effectiveFieldRenames[oldField.name] = newField.name;
            break;
          }
        }
      }
    }

    final allOldIndexes = oldSchema != null
        ? [
            ...oldSchema.indexes,
            if (oldSchema.autoIndexes != null) ...oldSchema.autoIndexes!,
          ]
        : const <IndexSchema>[];

    IndexSchema? findMatchingOldIndex(IndexSchema candidate) {
      if (allOldIndexes.isEmpty) return null;

      // 1. Exact indexUid match (if candidate already has a non-empty indexUid)
      if (candidate.indexUid.isNotEmpty) {
        for (final oldIdx in allOldIndexes) {
          if (oldIdx.indexUid == candidate.indexUid &&
              !claimedOldIndexUids.contains(oldIdx.indexUid.value)) {
            return oldIdx;
          }
        }
      }

      // 2. Explicit index rename match via indexRenames
      if (indexRenames != null && indexRenames.isNotEmpty) {
        for (final entry in indexRenames.entries) {
          final fromOldName = entry.key;
          final toNewName = entry.value;
          if (candidate.actualIndexName == toNewName ||
              candidate.indexName == toNewName) {
            for (final oldIdx in allOldIndexes) {
              if ((oldIdx.actualIndexName == fromOldName ||
                      oldIdx.indexName == fromOldName) &&
                  oldIdx.indexUid.isNotEmpty &&
                  !claimedOldIndexUids.contains(oldIdx.indexUid.value)) {
                return oldIdx;
              }
            }
          }
        }
      }

      // 3. Exact actualIndexName match (and same index type & uniqueness)
      for (final oldIdx in allOldIndexes) {
        if (oldIdx.actualIndexName == candidate.actualIndexName &&
            oldIdx.type == candidate.type &&
            oldIdx.unique == candidate.unique &&
            oldIdx.indexUid.isNotEmpty &&
            !claimedOldIndexUids.contains(oldIdx.indexUid.value)) {
          return oldIdx;
        }
      }

      // 4. Exact fields and types match
      for (final oldIdx in allOldIndexes) {
        if (_areIndexFieldsAndTypesEqual(oldIdx, candidate) &&
            oldIdx.indexUid.isNotEmpty &&
            !claimedOldIndexUids.contains(oldIdx.indexUid.value)) {
          return oldIdx;
        }
      }

      // 5. Rename-aware fields and types match (using effectiveFieldRenames)
      if (effectiveFieldRenames.isNotEmpty) {
        for (final oldIdx in allOldIndexes) {
          if (oldIdx.type != candidate.type ||
              oldIdx.unique != candidate.unique ||
              oldIdx.indexUid.isEmpty ||
              claimedOldIndexUids.contains(oldIdx.indexUid.value)) {
            continue;
          }

          if (oldIdx.fields.length != candidate.fields.length) continue;

          var fieldsMatch = true;
          for (int i = 0; i < oldIdx.fields.length; i++) {
            final mappedName =
                effectiveFieldRenames[oldIdx.fields[i]] ?? oldIdx.fields[i];
            if (mappedName != candidate.fields[i]) {
              fieldsMatch = false;
              break;
            }
          }

          if (fieldsMatch) {
            return oldIdx;
          }
        }
      }

      return null;
    }

    // Process explicit indexes first so declared explicit indexes take priority
    final List<IndexSchema> populatedExplicitIndexes = [];
    for (final explicit in indexes) {
      IndexSchema resolvedExplicit = explicit;
      if (oldSchema != null) {
        final matched = findMatchingOldIndex(resolvedExplicit);
        if (matched != null && matched.indexUid.isNotEmpty) {
          resolvedExplicit = explicit.copyWith(indexUid: matched.indexUid);
          claimedOldIndexUids.add(matched.indexUid.value);
        }
      }
      resolvedExplicit = resolvedExplicit.copyWith(
        indexUid: claimOrAllocate(resolvedExplicit.indexUid),
      );
      populatedExplicitIndexes.add(resolvedExplicit);
    }

    // Process implicit indexes
    final implicitIndexes = _computeRawImplicitIndexes();
    final List<IndexSchema> populatedAutoIndexes = [];
    for (final implicit in implicitIndexes) {
      IndexSchema resolvedImplicit = implicit;
      if (oldSchema != null) {
        final matched = findMatchingOldIndex(resolvedImplicit);
        if (matched != null && matched.indexUid.isNotEmpty) {
          resolvedImplicit = implicit.copyWith(indexUid: matched.indexUid);
          claimedOldIndexUids.add(matched.indexUid.value);
        }
      }
      resolvedImplicit = resolvedImplicit.copyWith(
        indexUid: claimOrAllocate(resolvedImplicit.indexUid),
      );
      populatedAutoIndexes.add(resolvedImplicit);
    }

    return copyWith(
      indexes: populatedExplicitIndexes,
      autoIndexes: populatedAutoIndexes,
    );
  }

  bool _areIndexFieldsAndTypesEqual(IndexSchema a, IndexSchema b) {
    if (a.unique != b.unique || a.type != b.type) return false;
    if (a.fields.length != b.fields.length) return false;
    for (int i = 0; i < a.fields.length; i++) {
      if (a.fields[i] != b.fields[i]) return false;
    }
    return true;
  }

  List<IndexSchema> _computeRawImplicitIndexes() {
    final implicitIndexes = <IndexSchema>[];
    final existingIndexNames = <String>{};
    for (final index in indexes) {
      if (!_isPrimaryKeyOnlyIndex(index)) {
        existingIndexNames.add(index.actualIndexName);
      }
    }

    for (final field in fields) {
      if (field.name == primaryKey) continue;
      // Complex / vector columns cannot use B+Tree implicits from unique/createIndex.
      if (field.type == DataType.vector ||
          field.type == DataType.blob ||
          field.type == DataType.json ||
          field.type == DataType.array ||
          field.type == DataType.dynamic) {
        continue;
      }

      if (field.unique) {
        final alreadyHasUniqueIndex = indexes.any((i) =>
            i.unique && i.fields.length == 1 && i.fields.first == field.name);

        if (!alreadyHasUniqueIndex) {
          final uniqueIndexSchema = IndexSchema(
            indexName: field.name,
            fields: [field.name],
            unique: true,
          );
          if (!existingIndexNames.contains(uniqueIndexSchema.actualIndexName)) {
            implicitIndexes.add(uniqueIndexSchema);
            existingIndexNames.add(uniqueIndexSchema.actualIndexName);
          }
        }
      } else if (field.createIndex) {
        final alreadyHasIndex = indexes
            .any((i) => i.fields.length == 1 && i.fields.first == field.name);

        if (!alreadyHasIndex) {
          final indexSchema = IndexSchema(
            indexName: field.name,
            fields: [field.name],
            unique: false,
          );

          if (!existingIndexNames.contains(indexSchema.actualIndexName)) {
            implicitIndexes.add(indexSchema);
            existingIndexNames.add(indexSchema.actualIndexName);
          }
        }
      }
    }

    final ttl = ttlConfig;
    final ttlField = (ttl != null)
        ? ((ttl.sourceField == null || ttl.sourceField!.isEmpty)
            ? internalTtlIngestTsMsField
            : ttl.sourceField!)
        : null;
    if (ttlField != null) {
      final alreadyCovered = indexes
              .any((i) => i.fields.isNotEmpty && i.fields.first == ttlField) ||
          implicitIndexes
              .any((i) => i.fields.isNotEmpty && i.fields.first == ttlField);
      if (!alreadyCovered) {
        final ttlIndex = IndexSchema(
          indexName: ttlField,
          fields: [ttlField],
          unique: false,
        );
        if (!existingIndexNames.contains(ttlIndex.actualIndexName)) {
          implicitIndexes.add(ttlIndex);
          existingIndexNames.add(ttlIndex.actualIndexName);
        }
      }
    }

    for (final fk in foreignKeys) {
      if (!fk.enabled || !fk.autoCreateIndex) continue;

      bool isCovered = false;
      final candidates = [...indexes, ...implicitIndexes];
      for (final index in candidates) {
        if (index.fields.length >= fk.fields.length) {
          bool match = true;
          for (int i = 0; i < fk.fields.length; i++) {
            if (index.fields[i] != fk.fields[i]) {
              match = false;
              break;
            }
          }
          if (match) {
            isCovered = true;
            break;
          }
        }
      }

      if (!isCovered) {
        final fkIndex = IndexSchema(
          indexName: fk.actualName,
          fields: fk.fields,
          unique: false,
        );
        if (!existingIndexNames.contains(fkIndex.actualIndexName)) {
          implicitIndexes.add(fkIndex);
          existingIndexNames.add(fkIndex.actualIndexName);
        }
      }
    }

    return implicitIndexes;
  }

  /// Validate table schema
  bool validateTableSchema({
    Set<String> reservedTableNames = const <String>{},
    bool allowReservedTableNames = false,
    bool allowInternalTableNamePrefix = false,
    bool allowOtherInternalFields = false,
  }) {
    // validate name format
    final tableNameRegex = allowInternalTableNamePrefix
        ? RegExp(r'^_?[a-zA-Z][a-zA-Z0-9_]*$')
        : RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');
    final fieldNameRegex =
        (allowInternalTableNamePrefix || allowOtherInternalFields)
            ? RegExp(r'^_?[a-zA-Z][a-zA-Z0-9_]*$')
            : RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');

    // validate name format
    if (name.isEmpty || !tableNameRegex.hasMatch(name)) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaTableName,
          message:
              'Invalid table name format for "$name". Table names must only contain alphanumeric characters and underscores, and must start with a letter.',
          tableName: name,
        )
      ]);
    }

    // Reserve exact table names for system tables (published names must remain stable).
    if (!allowReservedTableNames && reservedTableNames.contains(name)) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaTableName,
          message:
              'Table name "$name" is reserved for system tables and cannot be used.',
          tableName: name,
        )
      ]);
    }

    // Reserve internal prefix for engine/system tables.
    if (!allowInternalTableNamePrefix &&
        name.startsWith(internalSystemPrefix)) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaTableName,
          message:
              'Table name "$name" is reserved for internal tables (prefix: "$internalSystemPrefix").',
          tableName: name,
        )
      ]);
    }

    // validate primary key name format
    if (primaryKey.isEmpty || !fieldNameRegex.hasMatch(primaryKey)) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaPrimaryKey,
          message:
              'Invalid primary key name format "$primaryKey" in table "$name".',
          tableName: name,
          field: primaryKey,
        )
      ]);
    }

    // validate field name format
    for (final field in fields) {
      if (!fieldNameRegex.hasMatch(field.name)) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaFieldName,
            message:
                'Invalid field name format "${field.name}" in table "$name".',
            tableName: name,
            field: field.name,
          )
        ]);
      }

      // Reserve internal prefix for engine fields.
      if (field.name.startsWith(internalSystemPrefix)) {
        if (field.name == internalTtlIngestTsMsField) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaFieldName,
              message:
                  'Field "${field.name}" in table "$name" is reserved for internal TTL management and cannot be user-defined.',
              tableName: name,
              field: field.name,
            )
          ]);
        }
        if (!allowOtherInternalFields) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaFieldName,
              message:
                  'Field "${field.name}" in table "$name" is reserved for internal system fields (prefix: "$internalSystemPrefix").',
              tableName: name,
              field: field.name,
            )
          ]);
        }
      }

      // Field should not have the same name as the primary key
      if (field.name == primaryKey) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaPrimaryKey,
            message:
                'Field "${field.name}" in table "$name" has the same name as the primary key. Primary key should not be defined in the field list.',
            tableName: name,
            field: field.name,
          )
        ]);
      }
    }

    if (fields.isEmpty) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchema,
          message:
              'Table "$name" has no fields. User tables must define at least one field.',
          tableName: name,
        )
      ]);
    }

    // Validate field name uniqueness
    final seenFields = <String>{};
    final duplicateFields = <String>{};
    for (final field in fields) {
      if (!seenFields.add(field.name)) {
        duplicateFields.add(field.name);
      }
    }
    if (duplicateFields.isNotEmpty) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaDuplicateFieldName,
          message:
              'Field names in table "$name" must be unique. Duplicate fields found: ${duplicateFields.join(', ')}',
          tableName: name,
          field: duplicateFields.join(','),
        )
      ]);
    }

    // Validate field types and constraints for complex types
    for (final field in fields) {
      if (field.type == DataType.vector) {
        final dims = field.vectorConfig?.dimensions;
        if (dims == null || dims <= 0) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaIndexType,
              message:
                  'Field "${field.name}" in table "$name" is DataType.vector but must define vectorConfig.dimensions > 0.',
              tableName: name,
              field: field.name,
              wrongValue: {'dimensions': dims},
            )
          ]);
        }
      } else if (field.vectorConfig != null) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaFieldName,
            message:
                'Field "${field.name}" in table "$name" has vectorConfig but type is ${field.type.name}, not DataType.vector.',
            tableName: name,
            field: field.name,
            wrongValue: {'type': field.type.name},
          )
        ]);
      }

      if (field.type == DataType.vector ||
          field.type == DataType.blob ||
          field.type == DataType.json ||
          field.type == DataType.array ||
          field.type == DataType.dynamic) {
        if (field.unique) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaIndexType,
              message:
                  'Field "${field.name}" in table "$name" is of type ${field.type.name} and cannot have a unique constraint. Complex, binary, and vector types do not support unique constraints.',
              tableName: name,
              field: field.name,
              wrongValue: field.type.name,
            )
          ]);
        }
        if (field.createIndex) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaIndexType,
              message:
                  'Field "${field.name}" in table "$name" is of type ${field.type.name} and cannot automatically create a B-tree index. Complex, binary, and vector types do not support B-tree indexing.',
              tableName: name,
              field: field.name,
              wrongValue: field.type.name,
            )
          ]);
        }
      }
    }

    // Validate index configuration
    for (final index in indexes) {
      validateIndexFields(index);
    }

    // Validate foreign key configuration
    for (final fk in foreignKeys) {
      validateForeignKey(fk);
    }

    // Validate table TTL configuration
    final ttl = ttlConfig;
    if (ttl != null) {
      ttl.checkTtlConfig(this);
    }

    return true;
  }

  /// Validate foreign key configuration
  ///
  /// This method validates the foreign key within the current table context.
  /// For complete validation including referenced table field types, use validateForeignKeyWithReferencedTable.
  bool validateForeignKey(ForeignKeySchema fk) {
    // Validate foreign key schema itself
    if (!fk.validate()) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaForeignKey,
          message:
              'Invalid foreign key schema definition for "${fk.actualName}" in table "$name".',
          tableName: name,
          field: fk.fields.join(','),
          wrongValue: fk.referencedTable,
        )
      ]);
    }

    // Validate that foreign key fields exist in this table
    for (final fieldName in fk.fields) {
      final fieldExists = fields.any((field) => field.name == fieldName) ||
          fieldName == primaryKey;
      if (!fieldExists) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaForeignKey,
            message:
                'Foreign key "${fk.actualName}" in table "$name" references non-existent local field: "$fieldName".',
            tableName: name,
            field: fieldName,
            wrongValue: fieldName,
          )
        ]);
      }
    }

    // Validate that foreign key fields are not the same as primary key
    // (unless it's a self-referencing foreign key, which is allowed)
    if (fk.fields.length == 1 && fk.fields.first == primaryKey) {
      // Self-referencing foreign key is allowed
      return true;
    }

    return true;
  }

  /// Validate foreign key configuration with referenced table
  ///
  /// This method validates that:
  /// 1. Foreign key fields exist in this table
  /// 2. Referenced fields exist in the referenced table
  /// 3. Field types are compatible between foreign key fields and referenced fields
  ///
  /// [fk] The foreign key schema to validate
  /// [referencedSchema] The schema of the referenced table
  ///
  /// Returns true if validation passes, false otherwise
  bool validateForeignKeyWithReferencedTable(
    ForeignKeySchema fk,
    TableSchema referencedSchema,
  ) {
    // First validate within current table context
    validateForeignKey(fk);

    // Validate that referenced fields exist in the referenced table
    for (final refFieldName in fk.referencedFields) {
      final refFieldExists = referencedSchema.fields.any(
            (field) => field.name == refFieldName,
          ) ||
          refFieldName == referencedSchema.primaryKey;
      if (!refFieldExists) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaForeignKey,
            message:
                'Foreign key "${fk.actualName}" in table "$name" references non-existent field "$refFieldName" in referenced table "${fk.referencedTable}".',
            tableName: name,
            field: refFieldName,
            wrongValue: {
              'referencedTable': fk.referencedTable,
              'referencedField': refFieldName,
            },
          )
        ]);
      }
    }

    // Validate field type compatibility
    for (int i = 0; i < fk.fields.length; i++) {
      final fkFieldName = fk.fields[i];
      final refFieldName = fk.referencedFields[i];

      // Get field schemas
      FieldSchema? fkField;
      if (fkFieldName == primaryKey) {
        // Primary key field - need to check primary key type
        // For now, we'll skip type validation for primary key fields
        // as they may have special handling
        continue;
      } else {
        fkField = fields.firstWhere(
          (f) => f.name == fkFieldName,
          orElse: () => throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaForeignKey,
              message: 'Field $fkFieldName not found in table $name',
              tableName: name,
              field: fkFieldName,
            )
          ]),
        );
      }

      FieldSchema? refField;
      DataType refFieldType;
      if (refFieldName == referencedSchema.primaryKey) {
        // Referenced primary key - primary keys are always stored as text
        // Get the default data type for primary key
        refFieldType = referencedSchema.primaryKeyConfig.getDefaultDataType();
        // Create a virtual FieldSchema for type comparison
        refField = FieldSchema(
          name: refFieldName,
          type: refFieldType,
        );
      } else {
        refField = referencedSchema.fields.firstWhere(
          (f) => f.name == refFieldName,
          orElse: () => throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaForeignKey,
              message:
                  'Field $refFieldName not found in referenced table ${referencedSchema.name}',
              tableName: name,
              field: refFieldName,
            )
          ]),
        );
        refFieldType = refField.type;
      }

      // Validate type compatibility
      // Note: fkField and refField are guaranteed to be non-null here due to the logic above
      if (!_areTypesCompatible(fkField.type, refFieldType)) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaForeignKey,
            message:
                'Foreign key "${fk.actualName}" type mismatch: field "$fkFieldName" (${fkField.type.name}) in table "$name" is not compatible with referenced field "$refFieldName" (${refFieldType.name}) in table "${fk.referencedTable}".',
            tableName: name,
            field: fkFieldName,
            wrongValue: {
              'localFieldType': fkField.type.name,
              'referencedTable': fk.referencedTable,
              'referencedField': refFieldName,
              'referencedFieldType': refFieldType.name,
            },
          )
        ]);
      }
    }

    return true;
  }

  /// Check if two data types are compatible for foreign key relationships
  bool _areTypesCompatible(DataType fkType, DataType refType) {
    // Exact match is always compatible
    if (fkType == refType) {
      return true;
    }

    // Numeric types are compatible with each other (with some restrictions)
    final numericTypes = [
      DataType.integer,
      DataType.bigInt,
      DataType.double,
    ];

    if (numericTypes.contains(fkType) && numericTypes.contains(refType)) {
      // Integer and BigInt are compatible
      if ((fkType == DataType.integer || fkType == DataType.bigInt) &&
          (refType == DataType.integer || refType == DataType.bigInt)) {
        return true;
      }
      // Integer can be stored in Double, but not vice versa
      if (fkType == DataType.integer && refType == DataType.double) {
        return true;
      }
      // BigInt can be stored in Double (with precision loss warning)
      if (fkType == DataType.bigInt && refType == DataType.double) {
        return true;
      }
    }

    // Primary keys are stored as text, so numeric types can reference text primary keys
    // This is a common pattern: user_id (integer) -> users.id (text primary key)
    if (numericTypes.contains(fkType) && refType == DataType.text) {
      return true;
    }

    // Text can reference text (exact match already handled above)
    // But text cannot reference numeric types (would require parsing, which is error-prone)

    return false;
  }

  /// Validate index fields
  bool validateIndexFields(IndexSchema index) {
    final primaryKeyName = primaryKeyConfig.name;
    final bool usesInternalTtlSource = ttlConfig != null &&
        (ttlConfig!.sourceField == null || ttlConfig!.sourceField!.isEmpty);

    if (index.fields.isEmpty) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaIndexField,
          message:
              'Index "${index.actualIndexName}" in table "$name" must specify at least one field.',
          tableName: name,
          field: index.actualIndexName,
        )
      ]);
    }

    // Primary-key-only index is redundant:
    // table data itself is range-partitioned by primary key.
    if (_isPrimaryKeyOnlyIndex(index)) {
      Logger.warn(
        'Table $name contains redundant primary key-only index: ${index.actualIndexName}. Table data is already range-partitioned by primary key.',
      );
      // do not return false, because this is just a warning, should not block the table creation
    }

    // 1. Validate that all indexed fields exist
    for (final fieldName in index.fields) {
      // Check if the field is the primary key
      if (fieldName == primaryKeyName) {
        continue;
      }

      // Virtual TTL ingest-time field: may not exist in user field list.
      if (fieldName == internalTtlIngestTsMsField && usesInternalTtlSource) {
        continue;
      }

      // Check if the field exists in the field list
      final fieldExists = fields.any((field) => field.name == fieldName);
      if (!fieldExists) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaIndexField,
            message:
                'Index "${index.actualIndexName}" in table "$name" references non-existent field "$fieldName".',
            tableName: name,
            field: fieldName,
            wrongValue: fieldName,
          )
        ]);
      }
    }

    // 2. Validate index type compatibility
    if (index.type == IndexType.vector) {
      if (index.fields.length != 1) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaIndexType,
            message:
                'Vector index "${index.actualIndexName}" in table "$name" can only be created on a single field, but ${index.fields.length} fields were specified (${index.fields.join(', ')}).',
            tableName: name,
            field: index.fields.join(','),
            wrongValue: index.fields.length,
          )
        ]);
      }

      if (index.unique) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaIndexType,
            message:
                'Vector index "${index.actualIndexName}" in table "$name" cannot be unique. Vector indices do not support unique constraints.',
            tableName: name,
            field: index.fields.first,
            wrongValue: true,
          )
        ]);
      }

      final targetFieldName = index.fields.first;
      if (targetFieldName == primaryKeyName) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaIndexType,
            message:
                'Vector index "${index.actualIndexName}" in table "$name" cannot be built on the primary key "$targetFieldName".',
            tableName: name,
            field: targetFieldName,
            wrongValue: {'indexType': index.type.name},
          )
        ]);
      }

      FieldSchema? targetField;
      for (final f in fields) {
        if (f.name == targetFieldName) {
          targetField = f;
          break;
        }
      }
      if (targetField == null) {
        // Existence already checked above; keep defensive.
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaIndexField,
            message:
                'Vector index "${index.actualIndexName}" in table "$name" references non-existent field "$targetFieldName".',
            tableName: name,
            field: targetFieldName,
          )
        ]);
      }

      if (targetField.type != DataType.vector) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaIndexType,
            message:
                'Vector index "${index.actualIndexName}" in table "$name" requires field "$targetFieldName" to be of type DataType.vector, but got ${targetField.type.name}.',
            tableName: name,
            field: targetFieldName,
            wrongValue: targetField.type.name,
          )
        ]);
      }

      final fieldVectorConfig = targetField.vectorConfig;
      if (fieldVectorConfig == null || fieldVectorConfig.dimensions <= 0) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaIndexType,
            message:
                'Vector field "$targetFieldName" in table "$name" must define valid vectorConfig with dimensions > 0 to support vector indexing.',
            tableName: name,
            field: targetFieldName,
            wrongValue: fieldVectorConfig?.dimensions,
          )
        ]);
      }

      final vecIdxConfig = index.vectorConfig;
      if (vecIdxConfig != null) {
        if (vecIdxConfig.maxDegree != null && vecIdxConfig.maxDegree! <= 0) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaIndexType,
              message:
                  'Vector index "${index.actualIndexName}" in table "$name" has invalid maxDegree ${vecIdxConfig.maxDegree}. maxDegree must be greater than 0.',
              tableName: name,
              field: targetFieldName,
              wrongValue: vecIdxConfig.maxDegree,
            )
          ]);
        }
        if (vecIdxConfig.efSearch != null && vecIdxConfig.efSearch! <= 0) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaIndexType,
              message:
                  'Vector index "${index.actualIndexName}" in table "$name" has invalid efSearch ${vecIdxConfig.efSearch}. efSearch must be greater than 0.',
              tableName: name,
              field: targetFieldName,
              wrongValue: vecIdxConfig.efSearch,
            )
          ]);
        }
      }
    } else if (index.type == IndexType.btree) {
      for (final fieldName in index.fields) {
        if (fieldName == primaryKeyName ||
            (fieldName == internalTtlIngestTsMsField &&
                usesInternalTtlSource)) {
          continue;
        }
        FieldSchema? targetField;
        for (final f in fields) {
          if (f.name == fieldName) {
            targetField = f;
            break;
          }
        }
        if (targetField != null) {
          final t = targetField.type;
          if (t == DataType.vector ||
              t == DataType.blob ||
              t == DataType.json ||
              t == DataType.array ||
              t == DataType.dynamic) {
            throw DbException([
              SchemaValidationStatus(
                type: ResultType.devInvalidSchemaIndexType,
                message:
                    'B-tree index "${index.actualIndexName}" in table "$name" cannot be created on field "$fieldName" of type ${t.name}. Complex, binary, and vector types do not support B-tree indexing.',
                tableName: name,
                field: fieldName,
                wrongValue: t.name,
              )
            ]);
          }
        }
      }
    }

    return true;
  }

  TableSchema copyWith({
    String? name,
    PrimaryKeyConfig? primaryKeyConfig,
    List<FieldSchema>? fields,
    List<IndexSchema>? indexes,
    List<ForeignKeySchema>? foreignKeys,
    bool? isGlobal,
    String? tableId,
    TableTtlConfig? ttlConfig,
    TableUid? tableUid,
    String? schemaVersion,
    bool? isSystemTable,
    List<IndexSchema>? autoIndexes,
  }) {
    return TableSchema._internal(
      name: name ?? this.name,
      primaryKeyConfig: primaryKeyConfig ?? this.primaryKeyConfig,
      fields: fields ?? this.fields,
      indexes: indexes ?? this.indexes,
      foreignKeys: foreignKeys ?? this.foreignKeys,
      isGlobal: isGlobal ?? this.isGlobal,
      tableId: tableId ?? this.tableId,
      ttlConfig: ttlConfig ?? this.ttlConfig,
      tableUid: tableUid ?? this.tableUid,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      isSystemTable: isSystemTable ?? this.isSystemTable,
      autoIndexes: autoIndexes ?? this.autoIndexes,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'primaryKeyConfig': primaryKeyConfig.toJson(),
      'fields': fields.map((c) => c.toJson()).toList(),
      'indexes': indexes.map((i) => i.toJson()).toList(),
      'foreignKeys': foreignKeys.map((fk) => fk.toJson()).toList(),
      'isGlobal': isGlobal,
      if (tableId != null) 'tableId': tableId,
      if (ttlConfig != null) 'ttlConfig': ttlConfig!.toJson(),
      'tableUid': tableUid,
      if (schemaVersion != null) 'schemaVersion': schemaVersion,
      if (isSystemTable) 'isSystemTable': isSystemTable,
      if (autoIndexes != null)
        'autoIndexes': autoIndexes!.map((i) => i.toJson()).toList(),
    };
  }

  bool _isPrimaryKeyOnlyIndex(IndexSchema index) {
    return index.fields.length == 1 && index.fields.first == primaryKey;
  }

  factory TableSchema.fromJson(Map<String, dynamic> json) {
    // Backward compatibility handling
    PrimaryKeyConfig getPrimaryKeyConfig() {
      if (json['primaryKeyConfig'] != null) {
        return PrimaryKeyConfig.fromJson(
            json['primaryKeyConfig'] as Map<String, dynamic>);
      }

      // Old version compatibility handling
      if (json['primaryKey'] != null) {
        final primaryKeyName = json['primaryKey'] as String;
        final autoIncrement = json['autoIncrement'] as bool? ?? true;

        return PrimaryKeyConfig(
          name: primaryKeyName,
          type: autoIncrement ? PrimaryKeyType.sequential : PrimaryKeyType.none,
          sequentialConfig: autoIncrement ? const SequentialIdConfig() : null,
        );
      }

      return const PrimaryKeyConfig();
    }

    return TableSchema._internal(
      name: json['name'] as String,
      primaryKeyConfig: getPrimaryKeyConfig(),
      fields: (json['fields'] as List)
          .map((c) => FieldSchema.fromJson(c as Map<String, dynamic>))
          .toList(),
      indexes: (json['indexes'] as List?)
              ?.map((i) => IndexSchema.fromJson(i as Map<String, dynamic>))
              .toList() ??
          [],
      foreignKeys: (json['foreignKeys'] as List?)
              ?.map(
                  (fk) => ForeignKeySchema.fromJson(fk as Map<String, dynamic>))
              .toList() ??
          [],
      isGlobal: json['isGlobal'] as bool? ?? false,
      tableId: json['tableId'] as String?,
      ttlConfig: json['ttlConfig'] is Map<String, dynamic>
          ? TableTtlConfig.fromJson(json['ttlConfig'] as Map<String, dynamic>)
          : null,
      tableUid: TableUid((json['tableUid'] as String?) ?? ''),
      schemaVersion: json['schemaVersion'] as String?,
      isSystemTable: json['isSystemTable'] as bool? ?? false,
      autoIndexes: (json['autoIndexes'] as List?)
          ?.map((i) => IndexSchema.fromJson(i as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Validate data against table schema
  ///
  /// - When [applyConstraints] is true, it will modify the data to fit
  ///   constraints (e.g., truncate strings).
  /// - When [errors] is provided, detailed validation error messages will be
  ///   appended to it instead of only logging via [Logger].
  Map<String, dynamic>? validateData(
    Map<String, dynamic> data, {
    bool applyConstraints = false,
    List<String>? errors,
    bool trustedConvertedValues = false,
    Map<String, FieldSchema>? fieldMap,
    bool ignoreUnknownFields = true,

    /// When true, mutate [data] in place instead of copying.
    /// Safe only when the caller owns a freshly built map (e.g. insert prepare).
    bool mutateInPlace = false,
  }) {
    try {
      // In batch scenarios, callers can build and pass a shared fieldMap to avoid
      // reconstructing it for every record; for non-batch calls we build a local map here.
      final fieldMapLocal = fieldMap ?? {for (final f in fields) f.name: f};

      // Create a new result Map (or reuse caller's map to avoid a full copy).
      var result = mutateInPlace ? data : Map<String, dynamic>.from(data);

      // First handle primary key field
      final primaryKeyName = primaryKeyConfig.name;
      var primaryKeyValue = data[primaryKeyName];

      // Handle primary key value
      if (primaryKeyValue != null) {
        // Convert to string and handle leading/trailing spaces
        if (primaryKeyValue is int || primaryKeyValue is BigInt) {
          // Directly convert number types to string
          result[primaryKeyName] = primaryKeyValue.toString();
        } else if (primaryKeyValue is String) {
          // String type, remove leading/trailing spaces
          result[primaryKeyName] = primaryKeyValue.trim();
        } else {
          // Unsupported type
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devInvalidPrimaryKeyFormat,
              message:
                  'Invalid primary key $primaryKeyName value type: $primaryKeyValue (should be number or string type) (table $name)',
              parameterName: primaryKeyName,
              passedValue: primaryKeyValue,
            )
          ]);
        }
      }

      // Check required (non-nullable) fields
      for (var field in fields) {
        if (!field.nullable &&
            !data.containsKey(field.name) &&
            field.name != primaryKeyName) {
          throw DbException([
            ConstraintStatus(
              type: ResultType.bizNotNullViolation,
              message:
                  'Field ${field.name} is required but not provided for table $name',
              tableName: name,
              fields: [field.name],
              conflictingKeys:
                  primaryKeyValue != null ? [primaryKeyValue] : const [],
            )
          ]);
        }
      }

      // Validate field type and constraints
      for (var entry in data.entries) {
        // If it's the primary key field, it's already validated, skip
        if (entry.key == primaryKeyName) continue;

        // Find field definition
        final fieldSchema = fieldMapLocal[entry.key];
        if (fieldSchema == null) {
          if (ignoreUnknownFields) {
            result.remove(entry.key);
            continue;
          }
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devFieldNotFound,
              message: 'Unknown field ${entry.key} in table $name',
              parameterName: entry.key,
              passedValue: entry.value,
            )
          ]);
        }

        try {
          // Use FieldSchema's detailed validation helper to throw DbException
          fieldSchema.checkConstraints(
            entry.value,
            tableName: name,
            skipMaxLengthCheck: applyConstraints,
            trustedConvertedValue: trustedConvertedValues,
          );
        } on DbException catch (e) {
          if (primaryKeyValue != null) {
            final updatedStatuses = e.statuses.map((s) {
              if (s is ConstraintStatus) {
                return ConstraintStatus(
                  type: s.type,
                  message: s.message,
                  index: s.index,
                  tableName: s.tableName,
                  constraintName: s.constraintName,
                  fields: s.fields,
                  conflictingKeys: [primaryKeyValue],
                );
              } else if (s is InvalidArgumentStatus) {
                return InvalidArgumentStatus(
                  type: s.type,
                  message: s.message,
                  index: s.index,
                  parameterName: s.parameterName,
                  passedValue: s.passedValue,
                  primaryKey: primaryKeyValue.toString(),
                );
              }
              return s;
            }).toList();
            throw DbException(updatedStatuses);
          }
          rethrow;
        }

        // Apply constraint conditions
        if (applyConstraints && entry.value != null) {
          if (entry.value is String) {
            String stringValue = entry.value;
            if (fieldSchema.maxLength != null &&
                stringValue.length > fieldSchema.maxLength!) {
              Logger.warn(
                'Field ${fieldSchema.name} exceeds maximum length ${fieldSchema.maxLength}, will truncate',
              );
              result[entry.key] =
                  stringValue.substring(0, fieldSchema.maxLength!);
            }
          }
        }
      }

      return result;
    } on DbException catch (e) {
      if (errors != null) {
        errors.addAll(e.statuses.map((s) => s.message));
        return null;
      }
      rethrow;
    } catch (e) {
      Logger.warn('Unexpected data validation error for table $name',
          rawError: e);
      errors?.add(e.toString());
      return null;
    }
  }

  /// Validate primary key format against corresponding type requirements
  bool validatePrimaryKeyFormat(dynamic value) {
    if (value == null) return false;

    switch (primaryKeyConfig.type) {
      case PrimaryKeyType.sequential:
      case PrimaryKeyType.timestampBased:
      case PrimaryKeyType.datePrefixed:
        // Numeric format validation
        if (value is String) {
          return RegExp(r'^\d+$').hasMatch(value);
        }
        return value is int || value is BigInt;

      case PrimaryKeyType.shortCode:
        // Base62 format validation (0-9, A-Z, a-z)
        if (value is String) {
          return RegExp(r'^[0-9A-Za-z]+$').hasMatch(value);
        }
        return false;

      case PrimaryKeyType.none:
        // User-defined primary key, accept any string
        return true;
    }
  }

  /// Get MatcherType for primary key
  MatcherType getPrimaryKeyMatcherType() {
    return primaryKeyConfig.getMatcherType();
  }

  /// Get MatcherType for a field
  MatcherType getFieldMatcherType(String fieldName) {
    if (fieldName == primaryKey) {
      return getPrimaryKeyMatcherType();
    }

    // Backward compatibility: for internal TTL source field, treat it as datetime
    // even when legacy schema snapshots have not materialized this field yet.
    if (fieldName == internalTtlIngestTsMsField) {
      return MatcherType.datetime;
    }

    try {
      final field = fields.firstWhere((f) => f.name == fieldName);
      return field.getMatcherType();
    } catch (e) {
      Logger.warn('Field $fieldName not found, using unsupported matcher',
          rawError: e);
      return MatcherType.unsupported;
    }
  }

  /// Encode primary key as a MemComparable component.
  ///
  /// Primary keys are treated as strings to avoid precision overflow while still
  /// supporting monotonic ordering for numeric/base62-based PKs.
  Uint8List encodePrimaryKeyComponent(String pk) {
    switch (getPrimaryKeyMatcherType()) {
      case MatcherType.pkNumericString:
      case MatcherType.pkShortCodeString:
        return MemComparableKey.encodeTextLenFirst(pk);
      case MatcherType.pkString:
      default:
        return MemComparableKey.encodeTextLex(pk);
    }
  }

  /// Encode a field value as a MemComparable component.
  ///
  /// When [truncateText] is true, long text values are truncated to 256 chars
  /// (recommended for non-unique indexes).
  Uint8List? encodeFieldComponentToMemComparable(
    String fieldName,
    dynamic value, {
    required bool truncateText,
  }) {
    if (value == null) return null;
    final mt = getFieldMatcherType(fieldName);
    switch (mt) {
      case MatcherType.pkNumericString:
      case MatcherType.pkShortCodeString:
        return MemComparableKey.encodeTextLenFirst(value.toString());
      case MatcherType.pkString:
      case MatcherType.text:
      case MatcherType.textNullable:
      case MatcherType.datetime:
      case MatcherType.datetimeNullable:
      case MatcherType.unsupported:
        var s = value.toString();
        if (truncateText && s.length > 256) {
          s = s.substring(0, 256);
        }
        return MemComparableKey.encodeTextLex(s);
      case MatcherType.integer:
      case MatcherType.integerNullable:
        final n =
            (value is num) ? value.toInt() : int.tryParse(value.toString());
        if (n == null) return MemComparableKey.encodeTextLex(value.toString());
        return MemComparableKey.encodeInt64(n);
      case MatcherType.bigInt:
      case MatcherType.bigIntNullable:
        final s = value.toString();
        // Avoid incorrect numeric ordering for negative bigints here; fall back to lex.
        if (s.startsWith('-')) {
          return MemComparableKey.encodeTextLex(s);
        }
        final asInt = int.tryParse(s);
        if (asInt != null) return MemComparableKey.encodeInt64(asInt);
        // Length-first preserves numeric order for non-negative decimal strings.
        return MemComparableKey.encodeTextLenFirst(s);
      case MatcherType.double:
      case MatcherType.doubleNullable:
        final d = (value is num)
            ? value.toDouble()
            : double.tryParse(value.toString());
        if (d == null) return MemComparableKey.encodeTextLex(value.toString());
        return MemComparableKey.encodeFloat64(d);
      case MatcherType.boolean:
      case MatcherType.booleanNullable:
        final b = (value is bool)
            ? value
            : (value.toString().toLowerCase() == 'true'
                ? true
                : (value.toString().toLowerCase() == 'false' ? false : null));
        if (b == null) return MemComparableKey.encodeTextLex(value.toString());
        return MemComparableKey.encodeBool(b);
      case MatcherType.blob:
      case MatcherType.blobNullable:
        if (value is Uint8List) return MemComparableKey.encodeBytes(value);
        return MemComparableKey.encodeTextLex(value.toString());
    }
  }

  /// Create a delimiter-free canonical key for unique refs (buffer overlay).
  ///
  /// - Does NOT truncate values (unique indexes must preserve full value).
  dynamic createCanonicalIndexKey(
    List<String> fields,
    Map<String, dynamic> record,
  ) {
    if (fields.isEmpty) return null;
    if (fields.length == 1) return record[fields[0]];
    final values = <dynamic>[];
    for (final field in fields) {
      if (!record.containsKey(field)) return null;
      final value = record[field];
      if (value == null) return null;
      values.add(value);
    }
    return values;
  }

  /// Check if primary key is ordered type
  bool isPrimaryKeyOrdered() {
    try {
      final pkConfig = primaryKeyConfig;

      // If isOrdered is explicitly set, return directly
      if (pkConfig.isOrdered != null) {
        return pkConfig.isOrdered!;
      }

      // Determine primary key type
      switch (pkConfig.type) {
        case PrimaryKeyType.timestampBased:
        case PrimaryKeyType.datePrefixed:
        case PrimaryKeyType.shortCode:
        case PrimaryKeyType.sequential:
          // These types of primary keys are ordered
          return true;
        case PrimaryKeyType.none:
          // User-defined primary key, default to unordered
          return false;
      }
    } catch (e) {
      Logger.error('Check primary key order failed', rawError: e);
      return false;
    }
  }

  /// Get default value for a field
  dynamic getDefaultValue(String fieldName) {
    // Check if it's the primary key
    if (fieldName == primaryKey) {
      // Primary key should not have a default value because it's usually generated by the system
      return null;
    }

    final field = fields.firstWhere(
      (f) => f.name == fieldName,
      orElse: () => throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devFieldNotFound,
          message: 'Unknown field $fieldName in table $name',
          parameterName: 'fieldName',
          passedValue: fieldName,
        )
      ]),
    );
    return field.getDefaultValue();
  }

  // Check if table exists
  bool isTableExists() {
    return fields.isNotEmpty;
  }

  /// Quickly generate table structure hash for judging whether table structure has changed
  /// Avoid using JSON serialization, directly calculate hash value from table structure in memory
  static String generateSchemasHash(List<TableSchema> schemas) {
    if (schemas.isEmpty) return '';

    // Use binary buffer to optimize performance
    final byteBuffer = BytesBuilder();

    // Copy and sort tables to ensure hash value consistency
    final sortedSchemas = List<TableSchema>.from(schemas)
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final schema in sortedSchemas) {
      // Write table basic information
      _addStringToBuffer(byteBuffer, schema.name);

      // Write primary key configuration
      _addPrimaryKeyConfigToBuffer(byteBuffer, schema.primaryKeyConfig);

      byteBuffer.addByte(schema.isGlobal ? 1 : 0);

      // Write TTL config
      if (schema.ttlConfig != null) {
        byteBuffer.addByte(1);
        _addStringToBuffer(byteBuffer, schema.ttlConfig!.ttlMs.toString());
        if (schema.ttlConfig!.sourceField != null) {
          byteBuffer.addByte(1);
          _addStringToBuffer(byteBuffer, schema.ttlConfig!.sourceField!);
        } else {
          byteBuffer.addByte(0);
        }
      } else {
        byteBuffer.addByte(0);
      }

      // Write field information - Sort to ensure consistency
      final sortedFields = List<FieldSchema>.from(schema.fields)
        ..sort((a, b) => a.name.compareTo(b.name));

      byteBuffer.addByte(sortedFields.length);
      for (final field in sortedFields) {
        _addFieldSchemaToBuffer(byteBuffer, field);
      }

      // Write index information
      final sortedIndexes = List<IndexSchema>.from(schema.indexes)
        ..sort((a, b) => a.actualIndexName.compareTo(b.actualIndexName));

      byteBuffer.addByte(sortedIndexes.length);
      for (final index in sortedIndexes) {
        _addIndexSchemaToBuffer(byteBuffer, index);
      }

      // Write foreign key information
      final sortedForeignKeys = List<ForeignKeySchema>.from(schema.foreignKeys)
        ..sort((a, b) => a.actualName.compareTo(b.actualName));

      byteBuffer.addByte(sortedForeignKeys.length);
      for (final fk in sortedForeignKeys) {
        _addForeignKeySchemaToBuffer(byteBuffer, fk);
      }
    }

    // Calculate hash value
    final bytes = byteBuffer.toBytes();
    return SHA256.hashToHex(bytes);
  }

  /// Add primary key configuration to buffer
  static void _addPrimaryKeyConfigToBuffer(
      BytesBuilder buffer, PrimaryKeyConfig config) {
    _addStringToBuffer(buffer, config.name);
    buffer.addByte(config.type.index); // Primary key type

    if (config.isOrdered != null) {
      buffer.addByte(1);
      buffer.addByte(config.isOrdered! ? 1 : 0);
    } else {
      buffer.addByte(0); // isOrdered not set
    }

    // Check if it's the default configuration
    final isDefaultConfig = config.sequentialConfig != null &&
        config.sequentialConfig!.initialValue == 1 &&
        config.sequentialConfig!.increment == 1 &&
        !config.sequentialConfig!.useRandomIncrement;

    // If it's the default configuration or null, it's considered to have no configuration
    if (config.sequentialConfig != null && !isDefaultConfig) {
      buffer.addByte(1); // Has configuration
      final cfg = config.sequentialConfig!;
      _addInt32ToBuffer(buffer, cfg.initialValue);
      _addInt32ToBuffer(buffer, cfg.increment);
      buffer.addByte(cfg.useRandomIncrement ? 1 : 0);
    } else {
      buffer.addByte(0); // No configuration
    }
  }

  /// Add field schema to buffer
  static void _addFieldSchemaToBuffer(BytesBuilder buffer, FieldSchema field) {
    _addStringToBuffer(buffer, field.name);
    buffer.addByte(field.type.index);
    buffer.addByte(field.nullable ? 1 : 0);
    buffer.addByte(field.unique ? 1 : 0);
    buffer.addByte(field.createIndex ? 1 : 0);

    // Add defaultValueType
    buffer.addByte(field.defaultValueType.index);

    // Only check if defaultValue exists but DO NOT include its content
    buffer.addByte(field.defaultValue != null ? 1 : 0);

    // to ensure consistent hash values regardless of dynamic content

    // Special handling for BigInt type to ensure it can be recognized in table structure comparison
    if (field.type == DataType.bigInt) {
      buffer.addByte(255); // Special BigInt type marker
    }

    // Add field constraint information
    _addOptionalInt(buffer, field.maxLength);
    _addOptionalInt(buffer, field.minLength);

    // Add numeric range
    if (field.minValue != null) {
      buffer.addByte(1);
      _addStringToBuffer(buffer, field.minValue.toString());
    } else {
      buffer.addByte(0);
    }

    if (field.maxValue != null) {
      buffer.addByte(1);
      _addStringToBuffer(buffer, field.maxValue.toString());
    } else {
      buffer.addByte(0);
    }

    // Add field ID
    if (field.fieldId != null) {
      buffer.addByte(1);
      _addStringToBuffer(buffer, field.fieldId!);
    } else {
      buffer.addByte(0);
    }

    // Add comment information
    if (field.comment != null) {
      buffer.addByte(1);
      _addStringToBuffer(buffer, field.comment!);
    } else {
      buffer.addByte(0);
    }
  }

  /// Add index schema to buffer
  static void _addIndexSchemaToBuffer(BytesBuilder buffer, IndexSchema index) {
    _addStringToBuffer(buffer, index.actualIndexName);
    buffer.addByte(index.unique ? 1 : 0);
    buffer.addByte(index.type.index); // Keep original type index
    // Index fields
    final sortedIndexFields = List<String>.from(index.fields)..sort();
    buffer.addByte(sortedIndexFields.length);
    for (final fieldName in sortedIndexFields) {
      _addStringToBuffer(buffer, fieldName);
    }
  }

  /// Add foreign key schema to buffer
  static void _addForeignKeySchemaToBuffer(
      BytesBuilder buffer, ForeignKeySchema fk) {
    _addStringToBuffer(buffer, fk.actualName);
    _addStringToBuffer(buffer, fk.referencedTable);
    buffer.addByte(fk.fields.length);
    for (final field in fk.fields) {
      _addStringToBuffer(buffer, field);
    }
    for (final field in fk.referencedFields) {
      _addStringToBuffer(buffer, field);
    }
    buffer.addByte(fk.onDelete.index);
    buffer.addByte(fk.onUpdate.index);
    buffer.addByte(fk.autoCreateIndex ? 1 : 0); // Keep original autoCreateIndex
    buffer.addByte(fk.enabled ? 1 : 0); // Keep original enabled
    if (fk.comment != null) {
      // Keep original comment
      buffer.addByte(1);
      _addStringToBuffer(buffer, fk.comment!);
    } else {
      buffer.addByte(0);
    }
  }

  /// Add string to binary buffer
  static void _addStringToBuffer(BytesBuilder buffer, String value) {
    final bytes = utf8.encode(value);
    _addInt32ToBuffer(buffer, bytes.length);
    buffer.add(bytes);
  }

  /// Add optional integer to buffer
  static void _addOptionalInt(BytesBuilder buffer, int? value) {
    if (value != null) {
      buffer.addByte(1);
      _addInt32ToBuffer(buffer, value);
    } else {
      buffer.addByte(0);
    }
  }

  /// Add 32-bit integer to buffer
  static void _addInt32ToBuffer(BytesBuilder buffer, int value) {
    buffer.addByte((value >> 24) & 0xFF);
    buffer.addByte((value >> 16) & 0xFF);
    buffer.addByte((value >> 8) & 0xFF);
    buffer.addByte(value & 0xFF);
  }

  MatcherType getMatcherTypeForIndex(String indexName) {
    final index = indexes.firstWhere((i) => i.actualIndexName == indexName,
        orElse: () => const IndexSchema(fields: []));
    if (index.fields.isNotEmpty) {
      if (index.fields.length > 1) {
        return MatcherType.text; // Composite keys are strings
      }
      if (index.fields.length == 1) {
        return getFieldMatcherType(index.fields.first);
      }
    }

    // could be an auto-unique index
    if (indexName.startsWith('uniq_')) {
      final fieldName = indexName.substring(5);
      return getFieldMatcherType(fieldName);
    }
    return MatcherType.unsupported;
  }
}

/// field schema
class FieldSchema {
  static const _unsetValue = Object();

  final String name;
  final DataType
      type; // data type, Recommend integer primary key for efficient indexing
  final bool nullable;
  final dynamic defaultValue;
  final bool unique;
  final bool createIndex; // create index for this field
  final int? maxLength; // for text fields
  final int? minLength; // for text fields
  final num? minValue; // for numeric fields (integer, double)
  final num? maxValue; // for numeric fields (integer, double)
  final String? comment; // field comment
  final String?
      fieldId; // Unique identifier for fields, used for rename detection

  /// Default value type, used for special default value processing (e.g. timestamp)
  final DefaultValueType defaultValueType;

  /// Configuration for vector fields (only valid when type is DataType.vector)
  final VectorFieldConfig? vectorConfig;

  const FieldSchema({
    required this.name,
    required this.type,
    this.nullable = true,
    this.defaultValue,
    this.unique = false,
    this.createIndex = false,
    this.maxLength,
    this.minLength,
    this.minValue,
    this.maxValue,
    this.comment,
    this.fieldId,
    this.vectorConfig,
    this.defaultValueType = DefaultValueType.none,
  });

  /// Create copy with modifications
  FieldSchema copyWith({
    String? name,
    DataType? type,
    bool? nullable,
    dynamic defaultValue = _unsetValue,
    bool? unique,
    bool? createIndex,
    int? maxLength,
    int? minLength,
    num? minValue,
    num? maxValue,
    String? comment,
    String? fieldId,
    VectorFieldConfig? vectorConfig,
    DefaultValueType? defaultValueType,
  }) {
    return FieldSchema(
      name: name ?? this.name,
      type: type ?? this.type,
      nullable: nullable ?? this.nullable,
      defaultValue:
          defaultValue == _unsetValue ? this.defaultValue : defaultValue,
      unique: unique ?? this.unique,
      createIndex: createIndex ?? this.createIndex,
      maxLength: maxLength ?? this.maxLength,
      minLength: minLength ?? this.minLength,
      minValue: minValue ?? this.minValue,
      maxValue: maxValue ?? this.maxValue,
      comment: comment ?? this.comment,
      fieldId: fieldId ?? this.fieldId,
      vectorConfig: vectorConfig ?? this.vectorConfig,
      defaultValueType: defaultValueType ?? this.defaultValueType,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type.toString(),
      'nullable': nullable,
      'defaultValue': defaultValue,
      'maxLength': maxLength,
      'minLength': minLength,
      'minValue': minValue,
      'maxValue': maxValue,
      'unique': unique,
      'createIndex': createIndex,
      'comment': comment,
      if (fieldId != null) 'fieldId': fieldId,
      if (vectorConfig != null) 'vectorConfig': vectorConfig!.toJson(),
      // Only serialize if not none
      if (defaultValueType != DefaultValueType.none)
        'defaultValueType': defaultValueType.toString().split('.').last,
    };
  }

  /// Create from partial updates
  factory FieldSchema.fromJson(Map<String, dynamic> json) {
    DataType getType() {
      if (json['type'] == null) return DataType.text;
      if (json['type'] is DataType) return json['type'] as DataType;

      try {
        return DataType.values.firstWhere(
          (e) => e.toString() == json['type'],
        );
      } catch (_) {
        return DataType.text;
      }
    }

    // Parse default value type
    DefaultValueType getDefaultValueType() {
      final typeStr = json['defaultValueType'] as String?;
      if (typeStr == null) return DefaultValueType.none;

      switch (typeStr.toLowerCase()) {
        case 'currenttimestamp':
          return DefaultValueType.currentTimestamp;
        default:
          return DefaultValueType.none;
      }
    }

    final type = getType();

    // Parse vector configuration if it's a vector field
    VectorFieldConfig? vectorConfig;
    if (type == DataType.vector && json['vectorConfig'] != null) {
      vectorConfig = VectorFieldConfig.fromJson(
          json['vectorConfig'] as Map<String, dynamic>);
    }

    return FieldSchema(
      name: json['name'] as String,
      type: type,
      nullable: json['nullable'] as bool? ?? true,
      defaultValue: json['defaultValue'],
      unique: json['unique'] as bool? ?? false,
      createIndex: json['createIndex'] as bool? ?? false,
      maxLength: json['maxLength'] as int?,
      minLength: json['minLength'] as int?,
      minValue: json['minValue'] as num?,
      maxValue: json['maxValue'] as num?,
      comment: json['comment'] as String?,
      fieldId: json['fieldId'] as String?,
      vectorConfig: vectorConfig,
      defaultValueType: getDefaultValueType(),
    );
  }

  /// Get default value for this field
  dynamic getDefaultValue() {
    // handle special default value type
    if (defaultValueType == DefaultValueType.currentTimestamp) {
      if (type == DataType.datetime) {
        return DateTime.now().toIso8601String();
      }
      if (type == DataType.integer) {
        return DateTime.now().millisecondsSinceEpoch;
      }
      if (type == DataType.bigInt) {
        return BigInt.from(DateTime.now().millisecondsSinceEpoch);
      }
      return DateTime.now().toIso8601String();
    }

    // use static default value
    if (defaultValue != null) {
      return _convertValueInternal(defaultValue);
    }

    // allow null and no default value, return null
    return null;
  }

  /// Get field value: handle null value and execute type conversion
  dynamic convertValue(dynamic value) {
    // handle null value
    if (value == null) {
      return getDefaultValue();
    }

    // execute type conversion for non-null value
    return _convertValueInternal(value);
  }

  /// Type conversion (internal method).
  ///
  /// Hot path: values already in the declared Dart/storage form return immediately
  /// (no re-parse). This matters for batchInsert prepare where typed app records
  /// are the common case -- especially [DataType.datetime] strings, where
  /// `DateTime.parse` + `toIso8601String` previously dominated CPU.
  dynamic _convertValueInternal(dynamic value) {
    if (value == null) return null;

    switch (type) {
      case DataType.integer:
        if (value is int) return value;
        if (value is double) return value.round();
        if (value is String) return int.tryParse(value);
        if (value is bool) return value ? 1 : 0;
        if (value is DateTime) {
          return value.millisecondsSinceEpoch;
        }
        if (value is BigInt) {
          // Try to convert BigInt to int, return null or max value if out of range
          if (value <= BigInt.from(9007199254740991) &&
              value >= BigInt.from(-9007199254740991)) {
            return value.toInt();
          }
          return null; // Out of range
        }
        return null;
      case DataType.bigInt:
        if (value is BigInt) return value;
        if (value is int) return BigInt.from(value);
        if (value is String) {
          try {
            return BigInt.parse(value);
          } catch (_) {
            return null;
          }
        }
        if (value is bool) {
          return value ? BigInt.from(1) : BigInt.from(0);
        }
        if (value is DateTime) {
          return BigInt.from(value.millisecondsSinceEpoch);
        }
        return null;
      case DataType.double:
        if (value is double) return value;
        if (value is int) return value.toDouble();
        if (value is String) return double.tryParse(value);
        if (value is bool) return value ? 1.0 : 0.0;
        if (value is DateTime) {
          return value.millisecondsSinceEpoch.toDouble();
        }
        if (value is BigInt) {
          // Try to convert BigInt to double, may lose precision
          try {
            return value.toDouble();
          } catch (e) {
            return null;
          }
        }
        return null;
      case DataType.text:
        if (value is String) {
          if (value.isEmpty) return value;
          final int first = value.codeUnitAt(0);
          final int last = value.codeUnitAt(value.length - 1);
          if (first > 0x20 && last > 0x20) return value;
          return value.trim();
        }
        if (value is DateTime) {
          try {
            return value.toIso8601String();
          } catch (e) {
            Logger.warn('Failed to convert DateTime to string: $value',
                rawError: e);
            return null;
          }
        }
        final rawString = value.toString();
        return rawString.trim();
      case DataType.blob:
        if (value is Uint8List) return value;
        if (value is String) {
          return Uint8List.fromList(utf8.encode(value));
        }
        if (value is List<int>) return Uint8List.fromList(value);
        return null;
      case DataType.boolean:
        if (value is bool) return value;
        if (value is int) return value != 0;
        if (value is double) return value != 0.0;
        if (value is String) {
          final lower = value.toLowerCase();
          return lower == 'true' || lower == '1' || lower == 'yes';
        }
        if (value is BigInt) return value != BigInt.zero;
        return null;
      case DataType.datetime:
        // Storage form is ISO-8601 String. Trust already-string values:
        // re-parse+serialize is O(chars) per cell and dominated batchInsert
        // prepare when apps pass datetime strings (or shared batch timestamps).
        if (value is String) return value;
        if (value is DateTime) return value.toIso8601String();
        if (value is int) {
          try {
            return DateTime.fromMillisecondsSinceEpoch(value).toIso8601String();
          } catch (e) {
            Logger.warn('Failed to convert timestamp to DateTime: $value',
                rawError: e);
            return null;
          }
        }
        if (value is BigInt) {
          try {
            if (value <= BigInt.from(8640000000000000) &&
                value >= BigInt.from(-8640000000000000)) {
              return DateTime.fromMillisecondsSinceEpoch(value.toInt())
                  .toIso8601String();
            }
            return null; // Out of range
          } catch (e) {
            Logger.warn('Failed to convert BigInt to DateTime: $value',
                rawError: e);
            return null;
          }
        }
        return null;
      case DataType.array:
        if (value is List) return value;
        if (value is String) {
          try {
            return jsonDecode(value) as List?;
          } catch (_) {
            return [value];
          }
        }
        return value == null ? null : [value];
      case DataType.vector:
        if (value is VectorData) return value;
        if (value is List && value.every((v) => v is num)) {
          return VectorData.fromList(value.cast<num>());
        }
        if (value is Uint8List) {
          try {
            return VectorData.fromBytes(value);
          } catch (e) {
            Logger.warn('Failed to convert binary data to vector', rawError: e);
            return null;
          }
        }
        if (value is String) {
          try {
            final jsonList = jsonDecode(value);
            if (jsonList is List && jsonList.every((v) => v is num)) {
              return VectorData.fromList(jsonList.cast<num>());
            }
          } catch (e) {
            Logger.warn('Failed to parse vector from string: $value',
                rawError: e);
          }
        }
        return null;
      case DataType.json:
        if (value is Map) return value;
        if (value is String) {
          try {
            final decoded = jsonDecode(value);
            if (decoded is Map) {
              return decoded;
            }
            return null;
          } catch (_) {
            return null;
          }
        }
        return null;
      case DataType.dynamic:
        return value;
    }
  }

  /// Get detailed validation error message for a value.
  ///
  /// Validate field constraints and throw [DbException] on failure.
  void checkConstraints(
    dynamic value, {
    required String tableName,
    bool skipMaxLengthCheck = false,
    bool trustedConvertedValue = false,
  }) {
    if (value == null && !nullable) {
      throw DbException([
        ConstraintStatus(
          type: ResultType.bizNotNullViolation,
          message:
              'Field $name is required and cannot be null (table $tableName)',
          tableName: tableName,
          fields: [name],
        )
      ]);
    }

    if (value != null) {
      // Check data type.
      if (!trustedConvertedValue && !isValidDataType(value, type)) {
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentType,
            message:
                'Field $name expects type $type but got ${value.runtimeType} (table $tableName)',
            parameterName: name,
            passedValue: value,
          )
        ]);
      }

      // Check string length constraints
      if (value is String) {
        if (!skipMaxLengthCheck &&
            maxLength != null &&
            value.length > maxLength!) {
          throw DbException([
            ConstraintStatus(
              type: ResultType.bizValueExceedsMaxLength,
              message:
                  'Field $name length ${value.length} exceeds maxLength $maxLength (table $tableName)',
              tableName: tableName,
              fields: [name],
              conflictingKeys: [value],
            )
          ]);
        }
        if (minLength != null && value.length < minLength!) {
          throw DbException([
            ConstraintStatus(
              type: ResultType.bizValueLessThanMinLength,
              message:
                  'Field $name length ${value.length} is less than minLength $minLength (table $tableName)',
              tableName: tableName,
              fields: [name],
              conflictingKeys: [value],
            )
          ]);
        }
      }

      // Check numeric value constraints
      if (value is num) {
        if (minValue != null && value < minValue!) {
          throw DbException([
            ConstraintStatus(
              type: ResultType.bizValueLessThanMinValue,
              message:
                  'Field $name value $value is less than minValue $minValue (table $tableName)',
              tableName: tableName,
              fields: [name],
              conflictingKeys: [value],
            )
          ]);
        }
        if (maxValue != null && value > maxValue!) {
          throw DbException([
            ConstraintStatus(
              type: ResultType.bizValueExceedsMaxValue,
              message:
                  'Field $name value $value exceeds maxValue $maxValue (table $tableName)',
              tableName: tableName,
              fields: [name],
              conflictingKeys: [value],
            )
          ]);
        }
      }
    }
  }

  /// Returns `null` when the value is valid, otherwise returns a human-readable
  /// description of which constraint failed. This is designed for single-record
  /// validation and does not perform any table-wide scan.
  String? getValidationError(
    dynamic value, {
    bool skipMaxLengthCheck = false,
    bool trustedConvertedValue = false,
    required String tableName,
  }) {
    try {
      checkConstraints(
        value,
        tableName: tableName,
        skipMaxLengthCheck: skipMaxLengthCheck,
        trustedConvertedValue: trustedConvertedValue,
      );
      return null;
    } on DbException catch (e) {
      return e.statuses.first.message;
    }
  }

  /// Validate value against field constraints
  bool validateValue(dynamic value,
      {bool skipMaxLengthCheck = false, required String tableName}) {
    return getValidationError(
          value,
          skipMaxLengthCheck: skipMaxLengthCheck,
          tableName: tableName,
        ) ==
        null;
  }

  /// Validate value for update operation against field constraints
  bool validateUpdateValue(dynamic value, {required String tableName}) {
    try {
      checkConstraints(
        value,
        tableName: tableName,
        skipMaxLengthCheck: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Check if value matches data type
  bool isValidDataType(dynamic value, DataType type) {
    if (value == null) return true;
    switch (type) {
      case DataType.integer:
        return value is int;
      case DataType.bigInt:
        return value is BigInt ||
            (value is String && BigInt.tryParse(value) != null) ||
            value is int;
      case DataType.double:
        return value is double || value is int;
      case DataType.text:
        return value is String;
      case DataType.blob:
        return value is Uint8List;
      case DataType.boolean:
        return value is bool;
      case DataType.datetime:
        if (value is String) {
          try {
            DateTime.parse(value);
            return true;
          } catch (_) {
            return false;
          }
        }
        return false;
      case DataType.array:
        return value is List;
      case DataType.vector:
        // Accept VectorData, List of numbers, or byte representation
        return value is VectorData ||
            (value is List && value.every((v) => v is num)) ||
            value is Uint8List;
      case DataType.json:
        return value is Map;
      case DataType.dynamic:
        return true;
    }
  }

  /// Get matcher type for field
  MatcherType getMatcherType() {
    switch (type) {
      case DataType.integer:
        return nullable ? MatcherType.integerNullable : MatcherType.integer;
      case DataType.bigInt:
        return nullable ? MatcherType.bigIntNullable : MatcherType.bigInt;
      case DataType.double:
        return nullable ? MatcherType.doubleNullable : MatcherType.double;
      case DataType.text:
        return nullable ? MatcherType.textNullable : MatcherType.text;
      case DataType.boolean:
        return nullable ? MatcherType.booleanNullable : MatcherType.boolean;
      case DataType.datetime:
        return nullable ? MatcherType.datetimeNullable : MatcherType.datetime;
      case DataType.blob:
        return nullable ? MatcherType.blobNullable : MatcherType.blob;
      default:
        return MatcherType.unsupported;
    }
  }
}

/// index schema
class IndexSchema {
  final String? indexName;
  final List<String> fields;
  final bool unique;
  final IndexType type;

  /// Vector index configuration (only valid when type is IndexType.vector)
  final VectorIndexConfig? vectorConfig;

  /// Stable unique identifier (immutable across renames).
  final IndexUid indexUid;

  const IndexSchema({
    this.indexName,
    required this.fields,
    this.unique = false,
    this.type = IndexType.btree,
    this.vectorConfig,
  }) : indexUid = IndexUid.empty;

  const IndexSchema._internal({
    this.indexName,
    required this.fields,
    required this.unique,
    required this.type,
    this.vectorConfig,
    this.indexUid = IndexUid.empty,
  });

  /// Reconstruct a fully persisted index snapshot (binary codec / migration).
  factory IndexSchema.rehydrate({
    String? indexName,
    required List<String> fields,
    bool unique = false,
    IndexType type = IndexType.btree,
    VectorIndexConfig? vectorConfig,
    IndexUid indexUid = IndexUid.empty,
  }) {
    return IndexSchema._internal(
      indexName: indexName,
      fields: fields,
      unique: unique,
      type: type,
      vectorConfig: vectorConfig,
      indexUid: indexUid,
    );
  }

  /// get actual index name
  String get actualIndexName {
    final prefix = unique ? 'uniq_' : 'idx_';
    // unified prefix
    final baseName = indexName ?? fields.join('_');
    return '$prefix$baseName';
  }

  factory IndexSchema.fromJson(Map<String, dynamic> json) {
    // Parse the index type
    IndexType getIndexType() {
      final typeStr = json['type'] as String?;
      if (typeStr == null) return IndexType.btree;

      // Match using lowercase to be more forgiving
      switch (typeStr.toLowerCase()) {
        case 'hash':
        case 'bitmap':
          return IndexType.btree;
        case 'vector':
          return IndexType.vector;
        default:
          return IndexType.btree;
      }
    }

    // Parse type
    final indexType = getIndexType();

    // Parse vector configuration if it's a vector index
    VectorIndexConfig? vectorConfig;
    if (indexType == IndexType.vector && json['vectorConfig'] != null) {
      vectorConfig = VectorIndexConfig.fromJson(
          json['vectorConfig'] as Map<String, dynamic>);
    }

    return IndexSchema._internal(
      indexName: json['indexName'] as String?,
      fields: (json['fields'] as List).cast<String>(),
      unique: json['unique'] as bool? ?? false,
      type: indexType,
      vectorConfig: vectorConfig,
      indexUid:
          IndexUid.tryParse(json['indexUid'] as String?) ?? IndexUid.empty,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (indexName != null) 'indexName': indexName,
      'fields': fields,
      'unique': unique,
      'type': type.toString().split('.').last,
      if (vectorConfig != null) 'vectorConfig': vectorConfig!.toJson(),
      if (indexUid.isNotEmpty) 'indexUid': indexUid,
    };
  }

  IndexSchema copyWith({
    String? indexName,
    List<String>? fields,
    bool? unique,
    IndexType? type,
    VectorIndexConfig? vectorConfig,
    IndexUid? indexUid,
  }) {
    return IndexSchema._internal(
      indexName: indexName ?? this.indexName,
      fields: fields ?? this.fields,
      unique: unique ?? this.unique,
      type: type ?? this.type,
      vectorConfig: vectorConfig ?? this.vectorConfig,
      indexUid: indexUid ?? this.indexUid,
    );
  }
}

/// Table TTL configuration.
///
/// - [ttlMs] is the TTL duration in milliseconds and must be > 0.
/// - [sourceField] is optional:
///   - null => use internal `_system_ingest_ts_ms`
///   - non-null => must point to a non-nullable `DataType.datetime` field
///
/// Note:
/// For custom sourceField, `defaultValueType` must be
/// `DefaultValueType.currentTimestamp` to ensure automatic timestamp filling
/// when callers omit this field on insert paths.
class TableTtlConfig {
  final int ttlMs;
  final String? sourceField;

  const TableTtlConfig({
    required this.ttlMs,
    this.sourceField,
  });

  Map<String, dynamic> toJson() {
    return {
      'ttlMs': ttlMs,
      if (sourceField != null) 'sourceField': sourceField,
    };
  }

  factory TableTtlConfig.fromJson(Map<String, dynamic> json) {
    return TableTtlConfig(
      ttlMs: (json['ttlMs'] as num?)?.toInt() ?? 0,
      sourceField: json['sourceField'] as String?,
    );
  }

  TableTtlConfig copyWith({
    int? ttlMs,
    String? sourceField,
    bool clearSourceField = false,
  }) {
    return TableTtlConfig(
      ttlMs: ttlMs ?? this.ttlMs,
      sourceField: clearSourceField ? null : (sourceField ?? this.sourceField),
    );
  }

  void checkTtlConfig(TableSchema schema) {
    if (ttlMs <= 0) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaTtlConfig,
          message:
              'TTL duration for table "${schema.name}" must be greater than 0.',
          tableName: schema.name,
        )
      ]);
    }

    final field = sourceField;
    if (field == null || field.isEmpty) {
      return;
    }

    final matched = schema.fields.where((f) => f.name == field);
    if (matched.isEmpty) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaTtlConfig,
          message:
              'TTL source field "$field" does not exist in table "${schema.name}".',
          tableName: schema.name,
          field: field,
        )
      ]);
    }

    final fieldSchema = matched.first;
    if (fieldSchema.type != DataType.datetime) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaTtlConfig,
          message:
              'TTL source field "$field" must be DataType.datetime, but got ${fieldSchema.type.name} in table "${schema.name}".',
          tableName: schema.name,
          field: field,
          wrongValue: fieldSchema.type.name,
        )
      ]);
    }

    if (fieldSchema.nullable) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaTtlConfig,
          message:
              'TTL source field "$field" must be non-nullable in table "${schema.name}".',
          tableName: schema.name,
          field: field,
          wrongValue: {'nullable': true},
        )
      ]);
    }

    if (fieldSchema.defaultValueType != DefaultValueType.currentTimestamp) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devInvalidSchemaTtlConfig,
          message:
              'TTL source field "$field" must use DefaultValueType.currentTimestamp to ensure automatic ingestion timestamp filling in table "${schema.name}".',
          tableName: schema.name,
          field: field,
          wrongValue: fieldSchema.defaultValueType.name,
        )
      ]);
    }
  }
}

/// Field data type.
enum DataType {
  /// Integer. For general numeric values; use [bigInt] if values exceed 18 digits.
  integer,

  /// Big integer. For larger numeric values such as large IDs or counters.
  bigInt,

  /// Floating-point number. For decimal values like prices, scores, or measurements.
  double,

  /// Text. For strings such as names, descriptions, codes, or addresses.
  text,

  /// Binary data. For images, file contents, or other raw bytes.
  blob,

  /// Boolean. Represents true / false, e.g. toggles or flags.
  boolean,

  /// Date and time. For timestamps like created_at, updated_at, or order_time.
  datetime,

  /// Array. For storing an ordered list of values.
  array,

  /// Vector. For numerical vectors such as embeddings or feature vectors.
  vector,

  /// JSON object or structured data. For flexible or schema-less extension fields.
  json,

  /// Dynamic or untyped data. Holds arbitrary Dart objects (int, double, bool, String, Map, List, Uint8List, etc.) without forced type conversions.
  dynamic,
}

/// index type enum
enum IndexType {
  btree, // default, btree index
  vector, // vector similarity index
}

/// Field default value type
enum DefaultValueType {
  /// No special default value, use defaultValue static value
  none,

  /// Use current timestamp
  currentTimestamp,
}

/// Primary key generation method
enum PrimaryKeyType {
  /// Do not automatically generate primary key
  none,

  /// Sequential primary key  (Enabled by central server after exhaustion, then apply)
  sequential,

  /// Timestamp primary key (Based on timestamp + node + sequence number)
  timestampBased,

  /// Date prefixed primary key (Accurate to seconds, date + node + sequence number)
  datePrefixed,

  /// Short code primary key (Timestamp primary key encoded in Base62)
  shortCode,
}

/// Sequential primary key configuration
class SequentialIdConfig {
  /// Initial increment value
  final int initialValue;

  /// Increment step
  final int increment;

  /// Whether to enable random step (1 to increment)
  final bool useRandomIncrement;

  const SequentialIdConfig({
    this.initialValue = 1,
    this.increment = 1,
    this.useRandomIncrement = false,
  });

  SequentialIdConfig copyWith({
    int? initialValue,
    int? increment,
    bool? useRandomIncrement,
  }) {
    return SequentialIdConfig(
      initialValue: initialValue ?? this.initialValue,
      increment: increment ?? this.increment,
      useRandomIncrement: useRandomIncrement ?? this.useRandomIncrement,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'initialValue': initialValue,
      'increment': increment,
      'useRandomIncrement': useRandomIncrement,
    };
  }

  factory SequentialIdConfig.fromJson(Map<String, dynamic> json) {
    return SequentialIdConfig(
      initialValue: json['initialValue'] as int? ?? 1,
      increment: json['increment'] as int? ?? 1,
      useRandomIncrement: json['useRandomIncrement'] as bool? ?? false,
    );
  }
}

/// Primary key configuration
class PrimaryKeyConfig {
  /// Primary key field name
  final String name;

  /// Primary key generation method
  final PrimaryKeyType type;

  /// Sequential increment configuration (Only valid when genType is sequential)
  final SequentialIdConfig? sequentialConfig;

  /// Whether primary key is ordered
  final bool? isOrdered;

  /// When promoting a regular field to primary key with rename, the source
  /// field's stable [FieldSchema.fieldId]. Used only for declarative schema
  /// diff detection; cleared after promote cutover metadata is applied.
  final String? fromFieldId;

  const PrimaryKeyConfig({
    this.name = 'id',
    this.type = PrimaryKeyType.sequential,
    this.sequentialConfig,
    this.isOrdered,
    this.fromFieldId,
  });

  PrimaryKeyConfig copyWith({
    PrimaryKeyType? type,
    String? name,
    SequentialIdConfig? sequentialConfig,
    bool? isOrdered,
    String? fromFieldId,
    bool clearFromFieldId = false,
  }) {
    return PrimaryKeyConfig(
      type: type ?? this.type,
      name: name ?? this.name,
      sequentialConfig: sequentialConfig ?? this.sequentialConfig,
      isOrdered: isOrdered ?? this.isOrdered,
      fromFieldId: clearFromFieldId ? null : (fromFieldId ?? this.fromFieldId),
    );
  }

  /// Get matcher type for primary key
  MatcherType getMatcherType() {
    switch (type) {
      case PrimaryKeyType.sequential:
      case PrimaryKeyType.timestampBased:
      case PrimaryKeyType.datePrefixed:
        return MatcherType.pkNumericString;
      case PrimaryKeyType.shortCode:
        return MatcherType.pkShortCodeString;
      default:
        if (isOrdered == true) {
          return MatcherType.pkShortCodeString;
        }
        return MatcherType.pkString; // default
    }
  }

  /// Get default data type for primary key
  DataType getDefaultDataType() {
    // All primary key types use text type
    return DataType.text;
  }

  /// Convert value to primary key type.
  ///
  /// [tableName] is required for user-facing [ConstraintStatus] diagnostics
  /// (same pattern as [FieldSchema.checkConstraints]).
  dynamic convertPrimaryKey(dynamic value, {required String tableName}) {
    if (value == null) return null;
    if (value is String) {
      return value;
    }
    try {
      return value.toString();
    } catch (e) {
      throw DbException([
        ConstraintStatus(
          type: ResultType.bizTypeCastFailed,
          message:
              'Failed to convert value to primary key type for table "$tableName": $value',
          tableName: tableName,
          fields: [name],
          conflictingKeys: [value],
        )
      ]);
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type.toString().split('.').last,
      'name': name,
      if (sequentialConfig != null)
        'sequentialConfig': sequentialConfig!.toJson(),
      if (isOrdered != null) 'isOrdered': isOrdered,
      if (fromFieldId != null) 'fromFieldId': fromFieldId,
    };
  }

  factory PrimaryKeyConfig.fromJson(Map<String, dynamic> json) {
    PrimaryKeyType getGenType() {
      final value = json['type'] as String?;
      if (value == null) return PrimaryKeyType.sequential;

      switch (value.toLowerCase()) {
        case 'none':
          return PrimaryKeyType.none;
        case 'timestampbased':
          return PrimaryKeyType.timestampBased;
        case 'dateprefixed':
          return PrimaryKeyType.datePrefixed;
        case 'shortcode':
          return PrimaryKeyType.shortCode;
        default:
          return PrimaryKeyType.sequential;
      }
    }

    final genType = getGenType();

    return PrimaryKeyConfig(
      type: genType,
      name: json['name'] as String? ?? 'id',
      sequentialConfig: json['sequentialConfig'] != null
          ? SequentialIdConfig.fromJson(
              json['sequentialConfig'] as Map<String, dynamic>)
          : (genType == PrimaryKeyType.sequential
              ? const SequentialIdConfig()
              : null),
      isOrdered: json['isOrdered'] as bool?,
      fromFieldId: json['fromFieldId'] as String?,
    );
  }
}

/// Represents vector data for machine learning and similarity search operations
///
/// [VectorData] provides a specialized container for managing numerical vectors used in
/// machine learning applications, similarity searches, and other vector operations.
///
/// Key features:
/// - Supports different precision levels ([VectorPrecision])
/// - Performs basic vector operations (normalization, dot product)
/// - Ensures type safety and validation for vector operations

class VectorData {
  /// Internal storage of vector values
  final List<double> values;

  /// The number of dimensions in this vector
  int get dimensions => values.length;

  /// Creates a new vector with the given values
  ///
  /// Each element represents one dimension in the vector.
  const VectorData(this.values);

  /// Creates a vector from a list of double values
  ///
  /// This is the standard way to create a vector from application data.

  factory VectorData.fromList(List<num> list) {
    return VectorData(list.map((v) => v.toDouble()).toList(growable: false));
  }

  /// Creates a vector from binary data
  ///
  /// The binary data must be in IEEE 754 double-precision format (8 bytes per value).
  /// The total length of the data must be a multiple of 8 bytes.

  factory VectorData.fromBytes(Uint8List bytes) {
    if (bytes.length % 8 != 0) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devInvalidArgumentFormat,
          message:
              'Binary data length (${bytes.length}) must be a multiple of 8 bytes',
          parameterName: 'bytes',
          passedValue: 'Uint8List(${bytes.length} bytes)',
        )
      ]);
    }

    final buffer = bytes.buffer;
    final doubleList = Float64List.view(buffer, 0, bytes.length ~/ 8);
    return VectorData(doubleList.toList(growable: false));
  }

  /// Converts this vector to binary format
  ///
  /// Returns the vector as a list of bytes in IEEE 754 double-precision format.
  /// Each double value (8 bytes) is stored in little-endian byte order.
  ///
  /// Example:
  /// ```dart
  /// // Convert vector to binary for storage
  /// final bytes = vectorData.toBytes();
  /// await database.storeVector(fieldName, bytes);
  /// ```
  Uint8List toBytes() {
    final Float64List floatList = Float64List.fromList(values);
    return Uint8List.view(floatList.buffer);
  }

  /// Convert vector to a standard JSON representation
  List<double> toJson() {
    return List<double>.from(values);
  }

  /// Create a vector from JSON
  factory VectorData.fromJson(List<dynamic> json) {
    return VectorData(
        json.map<double>((v) => (v as num).toDouble()).toList(growable: false));
  }

  /// Get string representation of the vector
  @override
  String toString() {
    if (dimensions <= 6) {
      return 'VectorData$values';
    }
    // For long vectors, show first 3 and last 3 values
    return 'VectorData[${values[0].toStringAsFixed(4)}, ${values[1].toStringAsFixed(4)}, ${values[2].toStringAsFixed(4)}, ..., ${values[dimensions - 3].toStringAsFixed(4)}, ${values[dimensions - 2].toStringAsFixed(4)}, ${values[dimensions - 1].toStringAsFixed(4)}] (dim: $dimensions)';
  }

  /// Compare with another vector
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VectorData) return false;
    if (other.values.length != values.length) return false;

    for (int i = 0; i < values.length; i++) {
      // Use epsilon comparison for floating point values
      if ((values[i] - other.values[i]).abs() > 1e-10) {
        return false;
      }
    }

    return true;
  }

  @override
  int get hashCode => Object.hashAll(values);

  /// Creates a normalized copy of this vector (unit vector)
  ///
  /// Normalization scales the vector so its magnitude (length) equals 1,
  /// which is useful for cosine similarity calculations.

  VectorData normalize() {
    final magnitude = _magnitude();
    if (magnitude == 0) {
      return VectorData(List<double>.filled(dimensions, 0));
    }

    final normalized = List<double>.generate(
      dimensions,
      (i) => values[i] / magnitude,
    );
    return VectorData(normalized);
  }

  /// Calculates the magnitude (length) of this vector
  ///
  /// Returns the Euclidean norm (square root of the sum of squared values).
  double _magnitude() {
    double sumOfSquares = 0;
    for (final value in values) {
      sumOfSquares += value * value;
    }
    return sqrt(sumOfSquares);
  }

  /// Calculates the dot product between this vector and another
  ///
  /// The dot product is the sum of the products of corresponding elements.
  /// For normalized vectors, the dot product equals the cosine similarity.

  double dotProduct(VectorData other) {
    if (dimensions != other.dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devVectorDimensionMismatch,
          message:
              'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
          parameterName: 'other',
          passedValue: other.dimensions,
        )
      ]);
    }

    double result = 0;
    for (int i = 0; i < dimensions; i++) {
      result += values[i] * other.values[i];
    }
    return result;
  }

  /// Calculates cosine similarity between this vector and another
  ///
  /// Cosine similarity measures the cosine of the angle between two vectors,
  /// providing a value between -1 and 1 where:
  /// - 1 means vectors are identical
  /// - 0 means vectors are orthogonal (unrelated)
  /// - -1 means vectors are exactly opposite
  ///

  double cosineSimilarity(VectorData other) {
    return normalize().dotProduct(other.normalize());
  }

  /// Calculates Euclidean distance between this vector and another
  ///
  /// Euclidean distance measures the straight-line distance between two points
  /// in vector space. Lower values indicate greater similarity.

  double euclideanDistance(VectorData other) {
    if (dimensions != other.dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devVectorDimensionMismatch,
          message:
              'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
          parameterName: 'other',
          passedValue: other.dimensions,
        )
      ]);
    }

    double sumSquaredDifferences = 0;
    for (int i = 0; i < dimensions; i++) {
      final diff = values[i] - other.values[i];
      sumSquaredDifferences += diff * diff;
    }
    return sqrt(sumSquaredDifferences);
  }

  /// Adds another vector to this vector
  ///
  /// Element-wise addition of corresponding values.
  ///

  VectorData add(VectorData other) {
    if (dimensions != other.dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devVectorDimensionMismatch,
          message:
              'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
          parameterName: 'other',
          passedValue: other.dimensions,
        )
      ]);
    }

    final result = List<double>.generate(
      dimensions,
      (i) => values[i] + other.values[i],
    );
    return VectorData(result);
  }

  /// Subtracts another vector from this vector
  ///
  /// Element-wise subtraction of corresponding values.

  VectorData subtract(VectorData other) {
    if (dimensions != other.dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devVectorDimensionMismatch,
          message:
              'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
          parameterName: 'other',
          passedValue: other.dimensions,
        )
      ]);
    }

    final result = List<double>.generate(
      dimensions,
      (i) => values[i] - other.values[i],
    );
    return VectorData(result);
  }

  /// Scales this vector by a scalar value
  ///
  /// Multiplies each element by the given scale factor.

  VectorData scale(double factor) {
    final result = List<double>.generate(
      dimensions,
      (i) => values[i] * factor,
    );
    return VectorData(result);
  }

  /// Calculates the L1 (Manhattan) distance between this vector and another
  ///
  /// L1 distance is the sum of the absolute differences between corresponding elements.

  double manhattanDistance(VectorData other) {
    if (dimensions != other.dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devVectorDimensionMismatch,
          message:
              'Vector dimensions mismatch: $dimensions vs ${other.dimensions}',
          parameterName: 'other',
          passedValue: other.dimensions,
        )
      ]);
    }

    double sum = 0;
    for (int i = 0; i < dimensions; i++) {
      sum += (values[i] - other.values[i]).abs();
    }
    return sum;
  }

  /// Returns a subset of the vector with specified start and length
  ///
  /// Creates a new vector containing elements from `start` index to the index `start + length - 1`.
  ///
  /// Throws RangeError if the range is out of bounds.
  ///
  /// Example:
  /// ```dart
  /// // Get the first 128 dimensions
  /// final firstPart = embedding.subvector(0, 128);
  /// ```
  VectorData subvector(int start, int length) {
    if (start < 0 || start >= dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'Start index out of range: $start',
          parameterName: 'start',
          passedValue: start,
        )
      ]);
    }
    if (start + length > dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'End index out of range: ${start + length}',
          parameterName: 'length',
          passedValue: length,
        )
      ]);
    }

    return VectorData(values.sublist(start, start + length));
  }

  /// Creates a new vector by concatenating this vector with another
  ///
  /// The resulting vector will have dimensions equal to the sum of both vectors' dimensions.

  VectorData concat(VectorData other) {
    final result = List<double>.from(values)..addAll(other.values);
    return VectorData(result);
  }

  /// Truncates a vector to the specified number of dimensions
  ///
  /// Creates a new vector containing only the first `newDimensions` elements.
  ///
  /// Example:
  /// ```dart
  /// // Reduce a 1536-dim vector to 768 dimensions
  /// final reducedVector = fullVector.truncate(768);
  /// ```
  VectorData truncate(int newDimensions) {
    if (newDimensions > dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message:
              'New dimensions ($newDimensions) cannot be greater than current dimensions ($dimensions)',
          parameterName: 'newDimensions',
          passedValue: newDimensions,
        )
      ]);
    }
    return subvector(0, newDimensions);
  }
}

/// Vector field configuration
///
/// Configures the properties of a vector field, such as dimensions and precision.
class VectorFieldConfig {
  /// Dimension of the vector
  ///
  /// Specifies the number of dimensions (length) of the vector.
  /// Common values are 384, 512, 768, 1024, and 1536 (for OpenAI embeddings).
  final int dimensions;

  /// Precision of vector data (bits per dimension)
  ///
  /// Controls how the vector is stored and the precision of calculations.
  final VectorPrecision precision;

  /// Constructor
  const VectorFieldConfig({
    required this.dimensions,
    this.precision = VectorPrecision.float64,
  });

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'dimensions': dimensions,
      'precision': precision.toString().split('.').last,
    };
  }

  /// Create from JSON
  factory VectorFieldConfig.fromJson(Map<String, dynamic> json) {
    // Parse precision
    VectorPrecision getPrecision() {
      final precisionStr = json['precision'] as String?;
      if (precisionStr == null) return VectorPrecision.float64;

      switch (precisionStr.toLowerCase()) {
        case 'float32':
          return VectorPrecision.float32;
        case 'int8':
          return VectorPrecision.int8;
        default:
          return VectorPrecision.float64;
      }
    }

    return VectorFieldConfig(
      dimensions: json['dimensions'] as int? ?? 0,
      precision: getPrecision(),
    );
  }

  /// Copy with new values
  VectorFieldConfig copyWith({
    int? dimensions,
    VectorPrecision? precision,
  }) {
    return VectorFieldConfig(
      dimensions: dimensions ?? this.dimensions,
      precision: precision ?? this.precision,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VectorFieldConfig) return false;
    return other.dimensions == dimensions && other.precision == precision;
  }

  @override
  int get hashCode => Object.hash(dimensions, precision);
}

/// Vector precision options
///
/// Specifies the numeric precision used for storing vector values.
/// Higher precision offers better accuracy but uses more storage space.
enum VectorPrecision {
  /// 64-bit floating point (IEEE 754)
  ///
  /// Default and highest precision, uses 8 bytes per dimension
  float64,

  /// 32-bit floating point
  ///
  /// Standard single precision, uses 4 bytes per dimension
  /// Offers a good balance between precision and storage efficiency
  float32,

  /// 8-bit integer (quantized)
  ///
  /// Uses quantization to reduce storage to 1 byte per dimension
  /// Significant memory savings with some loss of precision
  int8,
}

/// Vector index type.
///
enum VectorIndexType {
  /// NGH (Node-Graph Hybrid)
  ngh,
}

/// Vector distance metric for similarity calculations
///
/// Specifies how the distance/similarity between vectors is calculated.
/// The appropriate metric depends on your application and how vectors were created.
enum VectorDistanceMetric {
  /// Euclidean distance (L2)
  ///
  /// Straight-line distance in vector space
  /// Lower values indicate greater similarity
  l2,

  /// Inner product
  ///
  /// Dot product of vectors
  /// Higher values indicate greater similarity
  /// Most efficient but requires normalized vectors for meaningful similarity
  innerProduct,

  /// Cosine similarity
  ///
  /// Measures the cosine of the angle between vectors
  /// Higher values indicate greater similarity
  /// Invariant to vector magnitude, focuses on direction
  cosine,
}

/// Vector Index Configuration for NGH (Node-Graph Hybrid) vector search.
///
/// Configures how vector indexes are built and searched.
/// This is used with [IndexSchema] when the index type is [IndexType.vector].
///
/// Example:
/// ```dart
/// VectorIndexConfig(
///   distanceMetric: VectorDistanceMetric.cosine,
///   maxDegree: 64,
///   efSearch: 64,
///   constructionEf: 128,
/// )
/// ```
class VectorIndexConfig {
  /// Type of vector index. Currently only supports [VectorIndexType.ngh].
  final VectorIndexType indexType;

  /// Distance metric for similarity search.
  ///
  /// - [VectorDistanceMetric.l2]: Euclidean distance (lower = more similar)
  /// - [VectorDistanceMetric.cosine]: Cosine similarity (higher = more similar)
  /// - [VectorDistanceMetric.innerProduct]: Dot product (higher = more similar)
  final VectorDistanceMetric distanceMetric;

  /// Maximum out-degree per graph node (R).
  ///
  /// Higher values improve recall but increase memory and construction time.
  /// Recommended: 32 for mobile/edge, 64 for desktop/server.
  final int? maxDegree;

  /// Search expansion factor (ef_search).
  ///
  /// Controls the search quality--speed trade-off. Higher values improve
  /// recall at the cost of latency. Standard ANN terminology.
  final int? efSearch;

  /// Expansion factor during graph construction (ef_construction).
  ///
  /// Higher values build a better-quality graph but take longer.
  /// Typical range: 64-256.
  final int? constructionEf;

  /// Diversity parameter for Robust Prune (alpha >= 1.0).
  ///
  /// Higher values produce more diverse neighbor selections, improving recall
  /// for high-dimensional data. Default 1.2.
  final double? pruneAlpha;

  /// Number of PQ sub-spaces (M).
  ///
  /// If null, automatically calculated as `dimensions / 8` (clamped to [8, 128]).
  /// Must evenly divide the vector dimensions.
  final int? pqSubspaces;

  /// Constructor
  const VectorIndexConfig({
    this.indexType = VectorIndexType.ngh,
    this.distanceMetric = VectorDistanceMetric.cosine,
    this.maxDegree,
    this.efSearch,
    this.constructionEf,
    this.pruneAlpha,
    this.pqSubspaces,
  });

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'indexType': indexType.name,
      'distanceMetric': distanceMetric.name,
      if (maxDegree != null) 'maxDegree': maxDegree,
      if (efSearch != null) 'efSearch': efSearch,
      if (constructionEf != null) 'constructionEf': constructionEf,
      if (pruneAlpha != null) 'pruneAlpha': pruneAlpha,
      if (pqSubspaces != null) 'pqSubspaces': pqSubspaces,
    };
  }

  /// Create from JSON
  factory VectorIndexConfig.fromJson(Map<String, dynamic> json) {
    VectorIndexType indexType = VectorIndexType.ngh;
    final typeStr = json['indexType'] as String?;
    if (typeStr != null && typeStr.toLowerCase() == 'ngh') {
      indexType = VectorIndexType.ngh;
    }

    VectorDistanceMetric distanceMetric = VectorDistanceMetric.cosine;
    final metricStr = json['distanceMetric'] as String?;
    if (metricStr != null) {
      switch (metricStr.toLowerCase()) {
        case 'l2':
          distanceMetric = VectorDistanceMetric.l2;
          break;
        case 'innerproduct':
          distanceMetric = VectorDistanceMetric.innerProduct;
          break;
      }
    }

    // Support both flat fields and legacy nested 'parameters' map
    final params = json['parameters'] as Map<String, dynamic>? ?? json;

    return VectorIndexConfig(
      indexType: indexType,
      distanceMetric: distanceMetric,
      maxDegree: (params['maxDegree'] as num?)?.toInt() ??
          (json['maxDegree'] as num?)?.toInt(),
      efSearch: (params['efSearch'] as num?)?.toInt() ??
          (json['efSearch'] as num?)?.toInt(),
      constructionEf: (params['constructionEf'] as num?)?.toInt() ??
          (json['constructionEf'] as num?)?.toInt(),
      pruneAlpha: (params['pruneAlpha'] as num?)?.toDouble() ??
          (json['pruneAlpha'] as num?)?.toDouble(),
      pqSubspaces: (params['pqSubspaces'] as num?)?.toInt() ??
          (json['pqSubspaces'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VectorIndexConfig) return false;
    return other.indexType == indexType &&
        other.distanceMetric == distanceMetric &&
        other.maxDegree == maxDegree &&
        other.efSearch == efSearch &&
        other.constructionEf == constructionEf &&
        other.pruneAlpha == pruneAlpha &&
        other.pqSubspaces == pqSubspaces;
  }

  @override
  int get hashCode => Object.hash(
        indexType,
        distanceMetric,
        maxDegree,
        efSearch,
        constructionEf,
        pruneAlpha,
        pqSubspaces,
      );
}

/// Vector utility methods extension
extension VectorMethods on VectorData {
  /// Calculate dot product with another vector
  double dotProduct(VectorData other) {
    if (dimensions != other.dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devVectorDimensionMismatch,
          message: 'Vectors must have same dimensions',
          parameterName: 'other',
          passedValue: other.dimensions,
        )
      ]);
    }

    double sum = 0;
    for (int i = 0; i < dimensions; i++) {
      sum += values[i] * other.values[i];
    }
    return sum;
  }

  /// Calculate Euclidean distance (L2) to another vector
  double l2Distance(VectorData other) {
    if (dimensions != other.dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devVectorDimensionMismatch,
          message: 'Vectors must have same dimensions',
          parameterName: 'other',
          passedValue: other.dimensions,
        )
      ]);
    }

    double sum = 0;
    for (int i = 0; i < dimensions; i++) {
      final diff = values[i] - other.values[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }

  /// Calculate cosine similarity to another vector
  double cosineSimilarity(VectorData other) {
    if (dimensions != other.dimensions) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devVectorDimensionMismatch,
          message: 'Vectors must have same dimensions',
          parameterName: 'other',
          passedValue: other.dimensions,
        )
      ]);
    }

    // Calculate dot product
    double dotProd = dotProduct(other);

    // Calculate magnitudes
    double mag1 = 0;
    double mag2 = 0;

    for (int i = 0; i < dimensions; i++) {
      mag1 += values[i] * values[i];
      mag2 += other.values[i] * other.values[i];
    }

    mag1 = sqrt(mag1);
    mag2 = sqrt(mag2);

    // Avoid division by zero
    if (mag1 == 0 || mag2 == 0) return 0;

    return dotProd / (mag1 * mag2);
  }

  /// Normalize the vector (convert to unit vector)
  VectorData normalize() {
    // Calculate magnitude
    double sumSquares = 0;
    for (final val in values) {
      sumSquares += val * val;
    }

    final magnitude = sqrt(sumSquares);

    // Avoid division by zero
    if (magnitude == 0) return this;

    // Create normalized values
    final normalizedValues =
        values.map((v) => v / magnitude).toList(growable: false);
    return VectorData(normalizedValues);
  }
}

/// ForeignKeyCascadeAction: Foreign key cascade action enum
///
/// Define how to handle related records in the child table (referenced table) when the record in the parent table (referenced table) is deleted or updated
enum ForeignKeyCascadeAction {
  /// Restrict operation (RESTRICT)
  ///
  /// If there are rows referencing this record in the child table, prohibit deleting or updating the record in the parent table
  /// This is the strictest constraint, ensuring data integrity
  restrict,

  /// Cascade delete/update (CASCADE)
  ///
  /// When the record in the parent table is deleted or updated, automatically delete or update all rows referencing this record in the child table
  /// For example: when deleting a user, automatically delete all orders of the user
  cascade,

  /// Set to null (SET NULL)
  ///
  /// When the record in the parent table is deleted or updated, set the foreign key field in the child table referencing this record to null
  /// Note: the foreign key field must allow null
  setNull,

  /// Set to default value (SET DEFAULT)
  ///
  /// When the record in the parent table is deleted or updated, set the foreign key field in the child table referencing this record to default value
  /// Note: the foreign key field must have a default value
  setDefault,

  /// No action (NO ACTION)
  ///
  /// Similar to RESTRICT, but in some database systems, the check may be delayed until the end of the transaction
  /// If the constraint is violated, the transaction will be rolled back
  noAction,
}

/// ForeignKeySchema: Foreign key constraint configuration
///
/// Define the relationship between tables, ensuring reference integrity
///
/// Example:
/// ```dart
/// // Simple foreign key: order table references user table
/// ForeignKeySchema(
///   name: 'fk_order_user',
///   fields: ['user_id'],
///   referencedTable: 'users',
///   referencedFields: ['id'],
///   onDelete: ForeignKeyCascadeAction.cascade,
///   onUpdate: ForeignKeyCascadeAction.cascade,
/// )
///
/// // Composite foreign key: order item table references order table and product table
/// ForeignKeySchema(
///   name: 'fk_order_item_order',
///   fields: ['order_id', 'product_id'],
///   referencedTable: 'orders',
///   referencedFields: ['id', 'product_id'],
///   onDelete: ForeignKeyCascadeAction.restrict,
///   onUpdate: ForeignKeyCascadeAction.cascade,
/// )
/// ```
class ForeignKeySchema {
  /// Foreign key constraint name (optional, used for identification and management)
  ///
  /// If not provided, the system will automatically generate: fk_{table name}_{field name}
  final String? name;

  /// Fields in this table (child table)
  ///
  /// For simple foreign keys, only contains one field name
  /// For composite foreign keys, contains multiple field names, the order must correspond to referencedFields
  ///
  /// Example:
  /// - Simple foreign key: `['user_id']`
  /// - Composite foreign key: `['order_id', 'product_id']`
  final List<String> fields;

  /// Referenced table name (parent table)
  final String referencedTable;

  /// Fields in the referenced table (parent table)
  ///
  /// Usually the primary key or unique index fields
  /// The order must correspond to fields, and the field types must be compatible
  ///
  /// Example:
  /// - Simple foreign key: `['id']`
  /// - Composite foreign key: `['id', 'product_id']`
  final List<String> referencedFields;

  /// Cascade action for DELETE operation
  ///
  /// When the record in the parent table is deleted, how to handle the related records in the child table
  /// Default value: restrict (prohibit deletion)
  final ForeignKeyCascadeAction onDelete;

  /// Cascade action for UPDATE operation
  ///
  /// When the record in the parent table is updated, how to handle the related records in the child table
  /// Default value: restrict (prohibit update)
  final ForeignKeyCascadeAction onUpdate;

  /// Whether to automatically create index for foreign key fields
  ///
  /// Default value: true
  /// Foreign key fields usually need indexes to improve JOIN query performance
  final bool autoCreateIndex;

  /// Whether the foreign key constraint is enabled
  ///
  /// Default value: true
  /// Can temporarily disable foreign key constraints (e.g. during data migration)
  final bool enabled;

  /// Comment for the foreign key constraint
  final String? comment;

  ForeignKeySchema({
    this.name,
    required this.fields,
    required this.referencedTable,
    required this.referencedFields,
    this.onDelete = ForeignKeyCascadeAction.restrict,
    this.onUpdate = ForeignKeyCascadeAction.restrict,
    this.autoCreateIndex = true,
    this.enabled = true,
    this.comment,
  })  : assert(
          fields.isNotEmpty,
          'Foreign key fields cannot be empty',
        ),
        assert(
          referencedFields.isNotEmpty,
          'Referenced fields cannot be empty',
        ),
        assert(
          fields.length == referencedFields.length,
          'Fields and referencedFields must have the same length',
        );

  /// Get the actual name of the foreign key constraint
  ///
  /// If name is provided, use it; otherwise, generate automatically
  String get actualName {
    if (name != null && name!.isNotEmpty) {
      return name!;
    }
    // Automatically generate name: fk_{table name}_{field name}
    final fieldNames = fields.join('_');
    return 'fk_$fieldNames';
  }

  /// Whether it is a composite foreign key (contains multiple fields)
  bool get isComposite => fields.length > 1;

  /// Create a copy and modify some properties
  ForeignKeySchema copyWith({
    String? name,
    List<String>? fields,
    String? referencedTable,
    List<String>? referencedFields,
    ForeignKeyCascadeAction? onDelete,
    ForeignKeyCascadeAction? onUpdate,
    bool? autoCreateIndex,
    bool? enabled,
    String? comment,
  }) {
    return ForeignKeySchema(
      name: name ?? this.name,
      fields: fields ?? this.fields,
      referencedTable: referencedTable ?? this.referencedTable,
      referencedFields: referencedFields ?? this.referencedFields,
      onDelete: onDelete ?? this.onDelete,
      onUpdate: onUpdate ?? this.onUpdate,
      autoCreateIndex: autoCreateIndex ?? this.autoCreateIndex,
      enabled: enabled ?? this.enabled,
      comment: comment ?? this.comment,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      if (name != null) 'name': name,
      'fields': fields,
      'referencedTable': referencedTable,
      'referencedFields': referencedFields,
      'onDelete': onDelete.toString().split('.').last,
      'onUpdate': onUpdate.toString().split('.').last,
      'autoCreateIndex': autoCreateIndex,
      'enabled': enabled,
      if (comment != null) 'comment': comment,
    };
  }

  /// Create from JSON
  factory ForeignKeySchema.fromJson(Map<String, dynamic> json) {
    // Parse cascade action
    ForeignKeyCascadeAction parseCascadeAction(String? value) {
      if (value == null) return ForeignKeyCascadeAction.restrict;
      switch (value.toLowerCase()) {
        case 'restrict':
          return ForeignKeyCascadeAction.restrict;
        case 'cascade':
          return ForeignKeyCascadeAction.cascade;
        case 'setnull':
        case 'set_null':
          return ForeignKeyCascadeAction.setNull;
        case 'setdefault':
        case 'set_default':
          return ForeignKeyCascadeAction.setDefault;
        case 'noaction':
        case 'no_action':
          return ForeignKeyCascadeAction.noAction;
        default:
          return ForeignKeyCascadeAction.restrict;
      }
    }

    return ForeignKeySchema(
      name: json['name'] as String?,
      fields: (json['fields'] as List).cast<String>(),
      referencedTable: json['referencedTable'] as String,
      referencedFields: (json['referencedFields'] as List).cast<String>(),
      onDelete: parseCascadeAction(json['onDelete'] as String?),
      onUpdate: parseCascadeAction(json['onUpdate'] as String?),
      autoCreateIndex: json['autoCreateIndex'] as bool? ?? true,
      enabled: json['enabled'] as bool? ?? true,
      comment: json['comment'] as String?,
    );
  }

  /// Validate the validity of the foreign key configuration
  ///
  /// Check the number of fields, name format, etc.
  bool validate() {
    // Validate that the field list is not empty
    if (fields.isEmpty || referencedFields.isEmpty) {
      return false;
    }

    // Validate that the number of fields matches
    if (fields.length != referencedFields.length) {
      return false;
    }

    // Validate that the field name format is valid (letters, numbers, underscores)
    final nameRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');
    for (final field in fields) {
      if (!nameRegex.hasMatch(field)) {
        return false;
      }
    }
    for (final field in referencedFields) {
      if (!nameRegex.hasMatch(field)) {
        return false;
      }
    }

    // Validate that the table name format is valid
    if (!nameRegex.hasMatch(referencedTable)) {
      return false;
    }

    // Validate that the foreign key name format is valid (if provided)
    if (name != null && name!.isNotEmpty && !nameRegex.hasMatch(name!)) {
      return false;
    }

    return true;
  }

  @override
  String toString() {
    return 'ForeignKeySchema('
        'name: $actualName, '
        'fields: $fields, '
        'referencedTable: $referencedTable, '
        'referencedFields: $referencedFields, '
        'onDelete: $onDelete, '
        'onUpdate: $onUpdate)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ForeignKeySchema) return false;
    return actualName == other.actualName &&
        fields.toString() == other.fields.toString() &&
        referencedTable == other.referencedTable &&
        referencedFields.toString() == other.referencedFields.toString();
  }

  @override
  int get hashCode {
    return Object.hash(
      actualName,
      fields.toString(),
      referencedTable,
      referencedFields.toString(),
    );
  }
}
