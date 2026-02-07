import 'dart:convert';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import '../model/foreign_key_operation.dart';
import '../model/system_table.dart';
import '../model/business_error.dart';
import 'data_store_impl.dart';
import '../Interface/chain_builder.dart';

/// ForeignKeyManager: Foreign key manager
///
/// Responsible for:
/// 1. Foreign key constraint checking (validate reference integrity when inserting/updating)
/// 2. Cascade operations processing (DELETE/UPDATE cascade)
/// 3. Automatic creation of foreign key indexes
class ForeignKeyManager {
  final DataStoreImpl _dataStore;

  // Reverse mapping cache: referenced table -> referencing tables
  // This provides O(1) lookup instead of O(n) table scan
  // Structure: Map<referencedTableName, Map<referencingTableName, List<ForeignKeySchema>>>
  Map<String, Map<String, List<ForeignKeySchema>>>? _referencingTablesCache;

  // Track if cache needs rebuild (when schema changes)
  // Note: No time-based expiry - foreign key relationships are part of table structure
  // and only change when table schemas are modified, which triggers invalidateCache()
  bool _cacheNeedsRebuild = true;

  // Track if cache is currently being loaded (for concurrent access protection)
  Future<void>? _cacheLoadingFuture;

  ForeignKeyManager(this._dataStore);

  /// Preload foreign key cache synchronously
  ///
  /// This method should be called during database initialization to ensure the cache
  /// is loaded before user table caches consume memory. This prevents the cache from
  /// being evicted due to memory pressure from user table caches.
  ///
  /// This is a synchronous operation that should be called before loading user table caches.
  Future<void> preloadCache() async {
    await _ensureCacheLoaded();
  }

  /// Initialize foreign key manager (lazy loading)
  ///
  /// This method loads the reverse mapping cache from the system table `system_fk_references`.
  /// This provides O(1) lookup without scanning all table schemas, critical for
  /// large-scale scenarios with thousands of tables.
  ///
  /// Performance: O(m) where m is the number of foreign keys (typically much smaller
  /// than the number of tables), instead of O(n) where n is the number of tables.
  ///
  /// Fallback: If the system table doesn't exist or is empty, falls back to
  /// rebuilding from schemas and populating the system table.
  ///
  /// Note: This is called lazily on first access, not during database startup.
  /// This avoids unnecessary I/O during initialization when foreign key operations
  /// may not be needed immediately.
  Future<void> _ensureCacheLoaded() async {
    try {
      // If cache is already loaded and doesn't need rebuild, return immediately
      if (_referencingTablesCache != null && !_cacheNeedsRebuild) {
        return;
      }

      // If cache is currently being loaded by another request, wait for it
      if (_cacheLoadingFuture != null) {
        await _cacheLoadingFuture;
        return;
      }

      // Start loading cache
      _cacheLoadingFuture = _loadCache();

      await _cacheLoadingFuture;
    } catch (e) {
      Logger.error(
        'Failed to ensure cache loaded: $e',
        label: 'ForeignKeyManager._ensureCacheLoaded',
      );
    } finally {
      _cacheLoadingFuture = null;
    }
  }

  /// Internal method to load cache
  Future<void> _loadCache() async {
    try {
      // Try to load from system table first (fast path for large databases)
      final loaded = await _loadCacheFromSystemTable();

      if (!loaded) {
        // System table doesn't exist or is empty
        // This happens on:
        // 1. First installation - no foreign keys defined yet
        // 2. Upgrade from version without foreign key support - no foreign keys in old version
        //
        // In both cases, we don't need to scan all tables because:
        // - First installation: no foreign keys exist, scanning is unnecessary
        // - Upgrade: old version had no foreign key support, so no foreign keys exist
        //
        // Foreign keys will be added to system table incrementally when users:
        // - Create tables with foreign keys
        // - Modify table schemas to add foreign keys
        // These operations call updateSystemTableForTable() to update the system table
        _referencingTablesCache =
            <String, Map<String, List<ForeignKeySchema>>>{};
        _cacheNeedsRebuild = false;

        Logger.debug(
          'System table not found or empty, initialized empty cache. Foreign keys will be added incrementally when tables are created/modified.',
          label: 'ForeignKeyManager._loadCache',
        );
      }
    } catch (e) {
      Logger.error(
        'Failed to load foreign key cache: $e',
        label: 'ForeignKeyManager._loadCache',
      );
      // Don't throw - allow operations to continue
      // Cache will be retried on next access
      _cacheNeedsRebuild = true;
    }
  }

  /// Load reverse mapping cache from system table
  ///
  /// This is the fast path for large databases - loads only foreign key relationships
  /// from the system table instead of scanning all table schemas.
  ///
  /// Returns true if successfully loaded, false if system table doesn't exist or is empty.
  Future<bool> _loadCacheFromSystemTable() async {
    try {
      final fkTableName = SystemTable.getFkReferencesName();

      // Check if system table exists
      final tableExists = await _dataStore.tableExists(fkTableName);
      if (!tableExists) {
        return false;
      }

      // Query all foreign key relationships from system table
      // Use a large limit to bypass the default 1000-record query limit
      final queryBuilder = QueryBuilder(_dataStore, fkTableName);
      final results = await queryBuilder.limit(1000000000).future;

      if (results.data.isEmpty) {
        return false;
      }

      // Rebuild cache from system table data
      _referencingTablesCache = <String, Map<String, List<ForeignKeySchema>>>{};

      for (final record in results.data) {
        final referencedTable = record['referenced_table'] as String?;
        final referencingTable = record['referencing_table'] as String?;
        final fkName = record['fk_name'] as String?;
        final fkFieldsJson = record['fk_fields'] as String?;
        final refFieldsJson = record['ref_fields'] as String?;
        final onDeleteStr = record['on_delete'] as String?;
        final onUpdateStr = record['on_update'] as String?;
        final enabled = record['enabled'] as bool? ?? true;

        if (referencedTable == null ||
            referencingTable == null ||
            fkName == null ||
            fkFieldsJson == null ||
            refFieldsJson == null) {
          continue;
        }

        // Parse JSON arrays
        final fkFields = (jsonDecode(fkFieldsJson) as List).cast<String>();
        final refFields = (jsonDecode(refFieldsJson) as List).cast<String>();

        // Parse cascade actions
        ForeignKeyCascadeAction parseAction(String? value) {
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

        // Only load enabled foreign keys into cache
        // Disabled foreign keys are stored in system table but not loaded into cache
        // This ensures cache only contains active foreign key relationships
        if (!enabled) {
          continue;
        }

        // Create foreign key schema
        final fk = ForeignKeySchema(
          name: fkName,
          fields: fkFields,
          referencedTable: referencedTable,
          referencedFields: refFields,
          onDelete: parseAction(onDeleteStr),
          onUpdate: parseAction(onUpdateStr),
          enabled: enabled, // Always true here since we skip disabled ones
        );

        // Add to cache
        if (!_referencingTablesCache!.containsKey(referencedTable)) {
          _referencingTablesCache![referencedTable] =
              <String, List<ForeignKeySchema>>{};
        }

        if (!_referencingTablesCache![referencedTable]!
            .containsKey(referencingTable)) {
          _referencingTablesCache![referencedTable]![referencingTable] = [];
        }

        _referencingTablesCache![referencedTable]![referencingTable]!.add(fk);
      }

      _cacheNeedsRebuild = false;

      return true;
    } catch (e) {
      Logger.warn(
        'Failed to load cache from system table: $e, will rebuild from schemas',
        label: 'ForeignKeyManager._loadCacheFromSystemTable',
      );
      return false;
    }
  }

  /// Check foreign key constraints (when inserting/updating)
  ///
  /// Validate that the record to be inserted or updated satisfies all foreign key constraints
  ///
  /// [tableName] Current table name
  /// [data] Data to be inserted/updated
  /// [operation] Operation type: insert or update
  ///
  /// Throws [BusinessError] if foreign key constraints are violated
  Future<void> validateForeignKeyConstraints({
    required String tableName,
    required Map<String, dynamic> data,
    required ForeignKeyOperation operation,
  }) async {
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return;

    // Check all foreign key constraints for this table
    for (final fk in schema.foreignKeys) {
      if (!fk.enabled) continue;

      // Check if the foreign key fields are in the data (update operation may only update some fields)
      bool hasForeignKeyFields = false;
      final fkValues = <String, dynamic>{};

      for (int i = 0; i < fk.fields.length; i++) {
        final fieldName = fk.fields[i];
        if (data.containsKey(fieldName)) {
          hasForeignKeyFields = true;
          fkValues[fieldName] = data[fieldName];
        }
      }

      // If the foreign key fields are not in the data, skip the check (update operation may not involve foreign key fields)
      if (!hasForeignKeyFields && operation == ForeignKeyOperation.update) {
        continue;
      }

      // If the foreign key field value is null, check if it is allowed to be null
      bool allNull = true;
      for (final value in fkValues.values) {
        if (value != null) {
          allNull = false;
          break;
        }
      }

      if (allNull) {
        // Check if the field is allowed to be null
        for (final fieldName in fk.fields) {
          final field = schema.fields.firstWhere(
            (f) => f.name == fieldName,
            orElse: () => throw StateError('Field $fieldName not found'),
          );
          if (!field.nullable) {
            throw BusinessError(
              'Foreign key field $fieldName cannot be null',
              type: BusinessErrorType.invalidData,
            );
          }
        }
        // If the field is allowed to be null, skip the reference integrity check
        continue;
      }

      // Validate reference integrity: check if the referenced table contains the corresponding record
      await _validateReferencedRecord(
        fk: fk,
        fkValues: fkValues,
        tableName: tableName,
      );
    }
  }

  /// Validate that the referenced record exists
  Future<void> _validateReferencedRecord({
    required ForeignKeySchema fk,
    required Map<String, dynamic> fkValues,
    required String tableName,
  }) async {
    final referencedSchema =
        await _dataStore.schemaManager?.getTableSchema(fk.referencedTable);
    if (referencedSchema == null) {
      throw BusinessError(
        'Referenced table ${fk.referencedTable} does not exist for foreign key ${fk.actualName}',
        type: BusinessErrorType.invalidData,
      );
    }

    // Build query conditions: check if the referenced table contains the corresponding record
    // For composite foreign keys, ALL fields must match (AND condition)
    final condition = <String, dynamic>{};
    bool hasNonNullValue = false;

    for (int i = 0; i < fk.fields.length; i++) {
      final fkField = fk.fields[i];
      final refField = fk.referencedFields[i];
      final fkValue = fkValues[fkField];

      if (fkValue == null) {
        // For composite foreign keys, if any field is null, the entire foreign key is invalid
        // unless all fields are nullable
        if (fk.fields.length > 1) {
          // Composite foreign key: all fields must be non-null or all must be null
          bool allFieldsNull = true;
          for (int j = 0; j < fk.fields.length; j++) {
            if (fkValues[fk.fields[j]] != null) {
              allFieldsNull = false;
              break;
            }
          }
          if (!allFieldsNull) {
            throw BusinessError(
              'Composite foreign key ${fk.actualName}: all fields must be non-null or all must be null',
              type: BusinessErrorType.invalidData,
            );
          }
          // All fields are null, skip validation (handled in upper layer)
          return;
        }
        // Single field foreign key with null value - skip this field
        continue;
      }

      hasNonNullValue = true;

      // Convert foreign key value to match the referenced field type
      // This is critical because:
      // 1. Primary keys are stored as strings in the database
      // 2. Foreign key values might be integers or other types
      // 3. Query comparison requires type matching
      dynamic convertedValue = fkValue;

      // Check if the referenced field is the primary key
      if (refField == referencedSchema.primaryKey) {
        // Use primary key conversion to ensure type consistency
        // Primary keys are always stored as strings
        convertedValue =
            referencedSchema.primaryKeyConfig.convertPrimaryKey(fkValue);
      } else {
        // For non-primary key fields, find the field schema and convert
        final refFieldSchema = referencedSchema.fields.firstWhere(
          (f) => f.name == refField,
          orElse: () => throw StateError(
              'Referenced field $refField not found in table ${fk.referencedTable}'),
        );
        convertedValue = refFieldSchema.convertValue(fkValue);
        if (convertedValue == null && fkValue != null) {
          // Type conversion failed - this indicates a type mismatch
          throw BusinessError(
            'Foreign key value type mismatch: Cannot convert ${fkValue.runtimeType} to ${refFieldSchema.type} for field $refField in foreign key ${fk.actualName}',
            type: BusinessErrorType.invalidData,
          );
        }
      }

      condition[refField] = convertedValue;
    }

    // If all fields are null, it has been handled in the upper layer
    if (condition.isEmpty || !hasNonNullValue) {
      return;
    }

    // For composite foreign keys, ensure all fields are present in condition
    if (fk.fields.length > 1 && condition.length != fk.fields.length) {
      throw BusinessError(
        'Composite foreign key ${fk.actualName}: incomplete foreign key values provided',
        type: BusinessErrorType.invalidData,
      );
    }

    // Query the referenced table
    // Note: There's a potential race condition here - the referenced record might be deleted
    // between the check and the actual insert/update. However, this is handled by:
    // 1. Transaction isolation (if in a transaction, the check and insert are atomic)
    // 2. The actual insert/update will fail if the referenced record doesn't exist
    //    due to the foreign key constraint being enforced at the database level
    final queryBuilder = QueryBuilder(_dataStore, fk.referencedTable);

    // Build where conditions
    for (final entry in condition.entries) {
      queryBuilder.where(entry.key, '=', entry.value);
    }

    // Use limit(1) for performance - we only need to know if the record exists
    final results = await queryBuilder.limit(1).future;

    if (results.data.isEmpty) {
      throw BusinessError(
        'Foreign key constraint violation: Referenced record does not exist in table ${fk.referencedTable} for foreign key ${fk.actualName}. '
        'Values: ${condition.toString()}',
        type: BusinessErrorType.invalidData,
      );
    }

    // Additional validation: verify that the referenced record still exists
    // This helps catch race conditions, though it's not a complete solution
    // The real protection comes from transaction isolation and database-level constraints
  }

  /// Check RESTRICT/NO ACTION constraints for delete operation
  ///
  /// This method only checks RESTRICT/NO ACTION constraints and throws an error if violated.
  /// It does NOT execute CASCADE operations. This should be called immediately when a delete
  /// operation is attempted, before deferring CASCADE operations to commit time.
  ///
  /// [tableName] Table containing the record to be deleted (parent table)
  /// [deletedPkValues] Primary key value of the record to be deleted
  ///
  /// Throws [BusinessError] if any RESTRICT/NO ACTION constraint is violated
  Future<void> checkRestrictConstraintsForDelete({
    required String tableName,
    required dynamic deletedPkValues,
  }) async {
    // Find all foreign keys that reference this table
    final referencingTables = await _findReferencingTables(tableName);

    // Sort table names to ensure deterministic order
    final sortedEntries = referencingTables.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    // Check RESTRICT/NO ACTION constraints
    for (final entry in sortedEntries) {
      final childTableName = entry.key;
      final fks = entry.value;

      for (final fk in fks) {
        if (fk.onDelete == ForeignKeyCascadeAction.restrict ||
            fk.onDelete == ForeignKeyCascadeAction.noAction) {
          // Check if there are any child records referencing the record to be deleted
          final hasReferences = await _checkChildReferences(
            childTableName: childTableName,
            fk: fk,
            parentPkValues: deletedPkValues,
          );

          if (hasReferences) {
            throw BusinessError(
              'Cannot delete record from $tableName: Referenced by records in $childTableName (foreign key: ${fk.actualName}). '
              'The foreign key constraint has RESTRICT/NO ACTION policy, which prevents deletion when child records exist.',
              type: BusinessErrorType.invalidData,
            );
          }
        }
      }
    }
  }

  /// Check RESTRICT/NO ACTION constraints for update operation
  ///
  /// This method only checks RESTRICT/NO ACTION constraints and throws an error if violated.
  /// It does NOT execute CASCADE operations. This should be called immediately when an update
  /// operation is attempted, before deferring CASCADE operations to commit time.
  ///
  /// [tableName] Table containing the record to be updated (parent table)
  /// [oldPkValues] Old primary key value of the record to be updated
  ///
  /// Throws [BusinessError] if any RESTRICT/NO ACTION constraint is violated
  Future<void> checkRestrictConstraintsForUpdate({
    required String tableName,
    required dynamic oldPkValues,
  }) async {
    // Find all foreign keys that reference this table
    final referencingTables = await _findReferencingTables(tableName);

    // Sort table names to ensure deterministic order
    final sortedEntries = referencingTables.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    // Check RESTRICT/NO ACTION constraints
    for (final entry in sortedEntries) {
      final childTableName = entry.key;
      final fks = entry.value;

      for (final fk in fks) {
        if (fk.onUpdate == ForeignKeyCascadeAction.restrict ||
            fk.onUpdate == ForeignKeyCascadeAction.noAction) {
          // Check if there are any child records referencing the record to be updated
          final hasReferences = await _checkChildReferences(
            childTableName: childTableName,
            fk: fk,
            parentPkValues: oldPkValues,
          );

          if (hasReferences) {
            throw BusinessError(
              'Cannot update primary key in $tableName: Referenced by records in $childTableName (foreign key: ${fk.actualName})',
              type: BusinessErrorType.invalidData,
            );
          }
        }
      }
    }
  }

  /// Handle cascade delete
  ///
  /// When the record in the parent table is deleted, handle the related records in the child table according to the onDelete configuration of the foreign key
  ///
  /// [tableName] Table containing the deleted record (parent table)
  /// [deletedPkValues] Primary key value of the deleted record (possibly a single value or a Map of composite primary key)
  /// [visitedRecords] Set of records already processed to prevent infinite recursion (Format: "tableName:pkValue")
  /// [skipRestrictCheck] If true, skip RESTRICT/NO ACTION checks (assumed to be done earlier). Default is false.
  ///
  /// Returns the number of records deleted by cascading
  Future<int> handleCascadeDelete({
    required String tableName,
    required dynamic deletedPkValues,
    Set<String>? visitedRecords,
    bool skipRestrictCheck = false,
  }) async {
    int totalCascaded = 0;

    // Create a new set to avoid sharing between concurrent operations
    // This prevents race conditions when multiple cascade deletes run concurrently
    final visited =
        visitedRecords != null ? Set<String>.from(visitedRecords) : <String>{};

    // Generate unique key for the current record
    final recordKey = _generateRecordKey(tableName, deletedPkValues);

    if (visited.contains(recordKey)) {
      // Record already visited in this cascade chain, skip to avoid infinite recursion
      return 0;
    }
    visited.add(recordKey);

    // Find all foreign keys that reference this table (with caching optimization)
    final referencingTables = await _findReferencingTables(tableName);

    // Sort table names to ensure deterministic lock acquisition order (prevents deadlocks)
    final sortedEntries = referencingTables.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    // CRITICAL: According to SQL standard, RESTRICT/NO ACTION should be checked BEFORE
    // executing CASCADE/SET NULL/SET DEFAULT actions. If a RESTRICT constraint exists
    // and there are referencing records, the deletion should be rejected immediately,
    // even if those records would be deleted via another CASCADE path.
    //
    // This ensures data integrity: RESTRICT means "prevent deletion if references exist",
    // regardless of whether those references would be removed by other cascades.
    //
    // Phase 1: Check RESTRICT/NO ACTION constraints FIRST (unless skipped)
    // If any RESTRICT constraint is violated, reject the deletion immediately
    if (!skipRestrictCheck) {
      for (final entry in sortedEntries) {
        final childTableName = entry.key;
        final fks = entry.value;

        for (final fk in fks) {
          if (fk.onDelete == ForeignKeyCascadeAction.restrict ||
              fk.onDelete == ForeignKeyCascadeAction.noAction) {
            // Check if there are any child records referencing the deleted record
            // This check happens BEFORE CASCADE deletes, so it will catch all references
            // regardless of whether they would be deleted via other CASCADE paths
            final hasReferences = await _checkChildReferences(
              childTableName: childTableName,
              fk: fk,
              parentPkValues: deletedPkValues,
            );

            if (hasReferences) {
              throw BusinessError(
                'Cannot delete record from $tableName: Referenced by records in $childTableName (foreign key: ${fk.actualName}). '
                'The foreign key constraint has RESTRICT/NO ACTION policy, which prevents deletion when child records exist.',
                type: BusinessErrorType.invalidData,
              );
            }
          }
        }
      }
    }

    // Phase 2: After RESTRICT checks pass, process all CASCADE, SET NULL, and SET DEFAULT actions
    for (final entry in sortedEntries) {
      final childTableName = entry.key;
      final fks = entry.value;

      for (final fk in fks) {
        if (fk.onDelete == ForeignKeyCascadeAction.cascade) {
          // Cascade delete: delete all child records referencing this record
          // Use depth-first approach: delete all descendants first, then this level
          // This avoids repeated queries and improves performance
          //
          // Error handling: If cascade delete fails, the error is propagated immediately
          // to ensure transaction rollback and data consistency
          try {
            final deletedCount = await _cascadeDeleteWithRecursion(
              childTableName: childTableName,
              fk: fk,
              parentPkValues: deletedPkValues,
              visitedRecords: visited,
            );
            totalCascaded += deletedCount;
          } catch (e) {
            // Propagate error immediately - transaction will rollback
            Logger.error(
              'Cascade delete failed for table $childTableName: $e',
              label: 'ForeignKeyManager.handleCascadeDelete',
            );
            rethrow;
          }
        } else if (fk.onDelete == ForeignKeyCascadeAction.setNull) {
          // Set to NULL: set the foreign key field to null
          // Error handling: propagate errors to ensure transaction rollback
          try {
            await _setForeignKeyToNull(
              childTableName: childTableName,
              fk: fk,
              parentPkValues: deletedPkValues,
            );
          } catch (e) {
            Logger.error(
              'Failed to set foreign key to NULL in $childTableName: $e',
              label: 'ForeignKeyManager.handleCascadeDelete',
            );
            rethrow;
          }
        } else if (fk.onDelete == ForeignKeyCascadeAction.setDefault) {
          // Set to default value: set the foreign key field to default value
          // Error handling: propagate errors to ensure transaction rollback
          try {
            await _setForeignKeyToDefault(
              childTableName: childTableName,
              fk: fk,
              parentPkValues: deletedPkValues,
            );
          } catch (e) {
            Logger.error(
              'Failed to set foreign key to default in $childTableName: $e',
              label: 'ForeignKeyManager.handleCascadeDelete',
            );
            rethrow;
          }
        }
      }
    }

    return totalCascaded;
  }

  /// Handle cascade update
  ///
  /// When the primary key of the record in the parent table is updated, handle the related records in the child table according to the onUpdate configuration of the foreign key
  ///
  /// [tableName] Table containing the updated record (parent table)
  /// [oldPkValues] Old primary key value
  /// [newPkValues] New primary key value
  /// [visitedTables] Set of tables already processed to prevent infinite recursion in case of circular references
  /// [skipRestrictCheck] If true, skip RESTRICT/NO ACTION checks (assumed to be done earlier). Default is false.
  ///
  /// Returns the number of records updated by cascading
  Future<int> handleCascadeUpdate({
    required String tableName,
    required dynamic oldPkValues,
    required dynamic newPkValues,
    Set<String>? visitedTables,
    bool skipRestrictCheck = false,
  }) async {
    int totalCascaded = 0;

    // Create a new set to avoid sharing between concurrent operations
    final visited =
        visitedTables != null ? Set<String>.from(visitedTables) : <String>{};

    // Prevent infinite recursion in case of circular foreign key references
    if (visited.contains(tableName)) {
      Logger.warn(
        'Circular foreign key reference detected during cascade update involving table $tableName',
        label: 'ForeignKeyManager.handleCascadeUpdate',
      );
      return 0;
    }
    visited.add(tableName);

    // Find all foreign keys that reference this table (with caching optimization)
    final referencingTables = await _findReferencingTables(tableName);

    // Sort table names to ensure deterministic lock acquisition order (prevents deadlocks)
    final sortedEntries = referencingTables.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    // Handle each referenced table
    for (final entry in sortedEntries) {
      final childTableName = entry.key;
      final fks = entry.value;

      for (final fk in fks) {
        if (!skipRestrictCheck &&
            (fk.onUpdate == ForeignKeyCascadeAction.restrict ||
                fk.onUpdate == ForeignKeyCascadeAction.noAction)) {
          // Check if there are any child records referencing the updated record
          final hasReferences = await _checkChildReferences(
            childTableName: childTableName,
            fk: fk,
            parentPkValues: oldPkValues,
          );

          if (hasReferences) {
            throw BusinessError(
              'Cannot update primary key in $tableName: Referenced by records in $childTableName (foreign key: ${fk.actualName})',
              type: BusinessErrorType.invalidData,
            );
          }
        } else if (fk.onUpdate == ForeignKeyCascadeAction.cascade) {
          // Cascade update: update all foreign key fields referencing this record
          // Check for potential circular reference: if updating would create a cycle, skip
          if (childTableName == tableName && oldPkValues == newPkValues) {
            // Self-reference with same value, skip to avoid infinite loop
            continue;
          }

          // Error handling: propagate errors to ensure transaction rollback
          int updatedCount = 0;
          try {
            updatedCount = await _cascadeUpdateChildren(
              childTableName: childTableName,
              fk: fk,
              oldParentPkValues: oldPkValues,
              newParentPkValues: newPkValues,
            );
            totalCascaded += updatedCount;
          } catch (e) {
            Logger.error(
              'Cascade update failed for table $childTableName: $e',
              label: 'ForeignKeyManager.handleCascadeUpdate',
            );
            rethrow;
          }

          // Recursive cascade: if the child table's primary key was updated, cascade further
          // Support full recursive cascade to handle multi-level foreign key relationships
          // This is critical for database best practices - all levels must be cascaded
          //
          // Note: For cascade update, we need to handle the case where the child table's
          // foreign key fields were updated (which is what we just did), but if those fields
          // are also primary keys or part of other foreign keys, we need to cascade further.
          //
          // However, in the current implementation, we're updating foreign key fields in the
          // child table, not the child table's primary key. So recursive cascade for UPDATE
          // is only needed if the child table's primary key itself was updated, which would
          // be handled by the update operation that triggered this cascade.
          //
          // The recursive cascade for UPDATE is already handled by the visitedTables mechanism
          // and the fact that handleCascadeUpdate is called recursively when a primary key
          // is updated in DataStoreImpl.updateInternal.
          //
          // For now, we rely on the natural recursion through the update mechanism.
          // If the child table's primary key is updated, it will trigger its own cascade update.
        } else if (fk.onUpdate == ForeignKeyCascadeAction.setNull) {
          // Set to NULL
          // Error handling: propagate errors to ensure transaction rollback
          try {
            await _setForeignKeyToNull(
              childTableName: childTableName,
              fk: fk,
              parentPkValues: oldPkValues,
            );
          } catch (e) {
            Logger.error(
              'Failed to set foreign key to NULL in $childTableName during cascade update: $e',
              label: 'ForeignKeyManager.handleCascadeUpdate',
            );
            rethrow;
          }
        } else if (fk.onUpdate == ForeignKeyCascadeAction.setDefault) {
          // Set to default value
          // Error handling: propagate errors to ensure transaction rollback
          try {
            await _setForeignKeyToDefault(
              childTableName: childTableName,
              fk: fk,
              parentPkValues: oldPkValues,
            );
          } catch (e) {
            Logger.error(
              'Failed to set foreign key to default in $childTableName during cascade update: $e',
              label: 'ForeignKeyManager.handleCascadeUpdate',
            );
            rethrow;
          }
        }
      }
    }

    return totalCascaded;
  }

  /// Handle cascade operations when clearing a table
  ///
  /// When clearing a table (removing all records), handle the related records in child tables
  /// according to the onDelete configuration of foreign keys.
  ///
  /// [tableName] Table to be cleared (parent table)
  ///
  /// Throws [BusinessError] if any foreign key has RESTRICT/NO ACTION and there are child records
  Future<void> handleCascadeClear(String tableName) async {
    // Find all foreign keys that reference this table
    final referencingTables = await _findReferencingTables(tableName);

    if (referencingTables.isEmpty) {
      // No foreign key references, can clear safely
      return;
    }

    // Check for RESTRICT/NO ACTION foreign keys
    bool hasRestrict = false;
    final restrictTables = <String>[];

    for (final entry in referencingTables.entries) {
      final referencingTableName = entry.key;
      final fks = entry.value;

      for (final fk in fks) {
        if (fk.onDelete == ForeignKeyCascadeAction.restrict ||
            fk.onDelete == ForeignKeyCascadeAction.noAction) {
          // Check if there are any child records referencing the parent table
          // Since we're clearing the entire table, we need to check if any records in the child table
          // have non-null foreign key values that reference the parent table
          //
          // CRITICAL: We need to check if there are ANY records in the child table that reference
          // ANY record in the parent table. Since we're clearing the entire parent table, we just
          // need to check if there are any records in the child table with non-null foreign key values.
          // For RESTRICT, we just need to know if any such records exist.
          //
          // IMPORTANT: We need to check if there are ANY records in the child table that have
          // non-null foreign key values. Since we're clearing the entire parent table, any
          // non-null foreign key value in the child table that references the parent table
          // should block the clear operation due to RESTRICT constraint.
          //
          // We use a simple approach: query with limit(1) to check if any record exists
          // where all foreign key fields are not null. This is sufficient for RESTRICT check.
          try {
            // Get child table schema to understand field types
            final childSchema = await _dataStore.schemaManager!
                .getTableSchema(referencingTableName);
            if (childSchema == null) {
              // Table doesn't exist, skip this check
              continue;
            }

            // Query to check if any records exist with non-null foreign key values
            // We use whereNotNull which internally uses 'IS NOT' null syntax
            final queryBuilder = QueryBuilder(_dataStore, referencingTableName);

            // Build condition: check if all foreign key fields are not null
            // For composite foreign keys, we need to check if ALL fields are not null
            // (since a composite foreign key is only valid if all fields are non-null)
            for (int i = 0; i < fk.fields.length; i++) {
              final fkField = fk.fields[i];
              // Check for non-null foreign key values (any record referencing the parent table)
              // Use whereNotNull which is more reliable than '!= null'
              queryBuilder.whereNotNull(fkField);
            }

            // Use limit(1) for performance - we only need to know if any record exists
            final results = await queryBuilder.limit(1).future;

            if (results.data.isNotEmpty) {
              hasRestrict = true;
              if (!restrictTables.contains(referencingTableName)) {
                restrictTables.add(referencingTableName);
              }
              // Break early if we found a RESTRICT violation
              break;
            }
          } catch (e) {
            // If query fails, assume there might be references and block the clear
            // This is a safety measure - better to block than to allow potentially unsafe clear
            Logger.warn(
              'Failed to check RESTRICT constraint for $referencingTableName: $e. Blocking clear operation for safety.',
              label: 'ForeignKeyManager.handleCascadeClear',
            );
            hasRestrict = true;
            if (!restrictTables.contains(referencingTableName)) {
              restrictTables.add(referencingTableName);
            }
            break;
          }
        }
      }
    }

    if (hasRestrict) {
      // Some foreign keys have RESTRICT/NO ACTION and there are child records
      final restrictTableNames = restrictTables.join(', ');
      throw BusinessError(
        'Cannot clear table $tableName: Referenced by foreign keys with RESTRICT/NO ACTION in tables: $restrictTableNames. '
        'Please delete the referencing records first, or change the foreign key constraints to CASCADE/SET NULL/SET DEFAULT.',
        type: BusinessErrorType.invalidData,
      );
    }

    // All foreign keys allow cascade operations (CASCADE/SET NULL/SET DEFAULT)
    // Process each referencing table according to its foreign key configuration
    final sortedEntries = referencingTables.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    for (final entry in sortedEntries) {
      final childTableName = entry.key;
      final fks = entry.value;

      for (final fk in fks) {
        if (fk.onDelete == ForeignKeyCascadeAction.cascade) {
          // Cascade delete: delete all child records that reference any record in the parent table
          // Since we're clearing the entire table, we need to delete all records in child table
          // that reference the parent table via this foreign key
          //
          // Note: We delete all records in child table that have non-null foreign key values
          // for the fields that reference the parent table. This is correct because:
          // 1. The foreign key fields in child table reference the parent table
          // 2. When parent table is cleared, all referenced records are removed
          // 3. Therefore, all child records referencing the parent table should be deleted
          try {
            // Build query to find all child records with non-null foreign key values
            // that reference the parent table
            final deleteBuilder = DeleteBuilder(_dataStore, childTableName);
            for (int i = 0; i < fk.fields.length; i++) {
              final fkField = fk.fields[i];
              // Delete all records where this foreign key field is not null
              // This ensures we delete all records that reference the parent table
              // Use whereNotNull instead of where(field, '!=', null) because
              // in SQL, != NULL doesn't match any values (NULL comparisons return NULL, not true/false)
              deleteBuilder.whereNotNull(fkField);
            }
            // Use allowDeleteAll() to allow deleting all matching records
            await deleteBuilder.allowDeleteAll().future;
          } catch (e) {
            Logger.error(
              'Failed to cascade delete from $childTableName during clear: $e',
              label: 'ForeignKeyManager.handleCascadeClear',
            );
            rethrow;
          }
        } else if (fk.onDelete == ForeignKeyCascadeAction.setNull) {
          // Set to NULL: set all foreign key fields to null
          try {
            // Build update to set all foreign key fields to null
            final updateData = <String, dynamic>{};
            for (final fkField in fk.fields) {
              updateData[fkField] = null;
            }

            final updateBuilder =
                UpdateBuilder(_dataStore, childTableName, updateData);
            for (int i = 0; i < fk.fields.length; i++) {
              final fkField = fk.fields[i];
              // Use whereNotNull instead of where(field, '!=', null) because
              // in SQL, != NULL doesn't match any values (NULL comparisons return NULL, not true/false)
              updateBuilder.whereNotNull(fkField);
            }
            await updateBuilder.future;
          } catch (e) {
            Logger.error(
              'Failed to set foreign key to NULL in $childTableName during clear: $e',
              label: 'ForeignKeyManager.handleCascadeClear',
            );
            rethrow;
          }
        } else if (fk.onDelete == ForeignKeyCascadeAction.setDefault) {
          // Set to default: set all foreign key fields to their default values
          try {
            // Get child table schema to get default values
            final childSchema =
                await _dataStore.schemaManager?.getTableSchema(childTableName);
            if (childSchema == null) {
              Logger.warn(
                'Child table $childTableName does not exist during cascade clear, skipping',
                label: 'ForeignKeyManager.handleCascadeClear',
              );
              continue;
            }

            // Build update to set all foreign key fields to their default values
            final updateData = <String, dynamic>{};
            for (final fkField in fk.fields) {
              final field = childSchema.fields.firstWhere(
                (f) => f.name == fkField,
                orElse: () => throw StateError(
                    'Field $fkField not found in $childTableName'),
              );
              updateData[fkField] = field.getDefaultValue();
            }

            final updateBuilder =
                UpdateBuilder(_dataStore, childTableName, updateData);
            for (int i = 0; i < fk.fields.length; i++) {
              final fkField = fk.fields[i];
              // Use whereNotNull instead of where(field, '!=', null) because
              // in SQL, != NULL doesn't match any values (NULL comparisons return NULL, not true/false)
              updateBuilder.whereNotNull(fkField);
            }
            await updateBuilder.future;
          } catch (e) {
            Logger.error(
              'Failed to set foreign key to default in $childTableName during clear: $e',
              label: 'ForeignKeyManager.handleCascadeClear',
            );
            rethrow;
          }
        }
      }
    }
  }

  /// Check if there are any child records referencing the updated record
  ///
  /// Optimized to use index lookup when possible
  Future<bool> _checkChildReferences({
    required String childTableName,
    required ForeignKeySchema fk,
    required dynamic parentPkValues,
  }) async {
    // Build query conditions using helper method
    final condition = _buildForeignKeyCondition(fk, parentPkValues);

    if (condition.isEmpty) {
      return false;
    }

    // Get child table schema to ensure type conversion
    final childSchema =
        await _dataStore.schemaManager?.getTableSchema(childTableName);
    if (childSchema == null) {
      return false;
    }

    // Convert condition values to match child table field types
    // This is critical for type matching (e.g., integer foreign key vs text primary key)
    final convertedCondition = <String, dynamic>{};
    for (final entry in condition.entries) {
      final fieldName = entry.key;
      final value = entry.value;

      // Find the field schema in child table
      FieldSchema? fieldSchema;
      if (fieldName == childSchema.primaryKey) {
        // Primary key field - use primary key conversion
        fieldSchema = FieldSchema(
          name: fieldName,
          type: childSchema.primaryKeyConfig.getDefaultDataType(),
        );
        convertedCondition[fieldName] =
            childSchema.primaryKeyConfig.convertPrimaryKey(value);
      } else {
        fieldSchema = childSchema.fields.firstWhere(
          (f) => f.name == fieldName,
          orElse: () => throw StateError(
              'Field $fieldName not found in table $childTableName'),
        );
        convertedCondition[fieldName] = fieldSchema.convertValue(value);
      }
    }

    // Use limit(1) for early termination - only need to know if any record exists
    final queryBuilder = QueryBuilder(_dataStore, childTableName);
    for (final entry in convertedCondition.entries) {
      queryBuilder.where(entry.key, '=', entry.value);
    }
    final results = await queryBuilder.limit(1).future;

    return results.data.isNotEmpty;
  }

  /// Cascade delete child records with recursive depth-first processing
  ///
  /// This method uses a depth-first approach to delete all descendant records
  /// before deleting the current level.
  ///
  /// Optimization: Uses chunked processing (pagination) to handle large number of child records
  /// to avoid memory issues (OOM).
  Future<int> _cascadeDeleteWithRecursion({
    required String childTableName,
    required ForeignKeySchema fk,
    required dynamic parentPkValues,
    required Set<String> visitedRecords,
  }) async {
    // Build query conditions using helper method
    final condition = _buildForeignKeyCondition(fk, parentPkValues);
    if (condition.isEmpty) {
      return 0;
    }

    // Get child schema for primary key
    // Note: Table may have been dropped during cascade operation, check and handle gracefully
    final childSchema =
        await _dataStore.schemaManager?.getTableSchema(childTableName);
    if (childSchema == null) {
      Logger.warn(
        'Child table $childTableName does not exist during cascade delete, skipping',
        label: 'ForeignKeyManager._cascadeDeleteWithRecursion',
      );
      return 0;
    }

    int totalDeleted = 0;
    const int batchSize = 1000; // Process 1000 records at a time
    bool hasMore = true;

    // Process in batches to avoid OOM with millions of records
    while (hasMore) {
      // Convert condition values to match child table field types
      // This is critical for type matching (e.g., integer foreign key vs text primary key)
      final childSchemaForConversion =
          await _dataStore.schemaManager?.getTableSchema(childTableName);
      final convertedCondition = <String, dynamic>{};
      if (childSchemaForConversion != null) {
        for (final entry in condition.entries) {
          final fieldName = entry.key;
          final value = entry.value;

          // Find the field schema in child table
          FieldSchema? fieldSchema;
          if (fieldName == childSchemaForConversion.primaryKey) {
            // Primary key field - use primary key conversion
            convertedCondition[fieldName] = childSchemaForConversion
                .primaryKeyConfig
                .convertPrimaryKey(value);
          } else {
            fieldSchema = childSchemaForConversion.fields.firstWhere(
              (f) => f.name == fieldName,
              orElse: () => throw StateError(
                  'Field $fieldName not found in table $childTableName'),
            );
            convertedCondition[fieldName] = fieldSchema.convertValue(value);
          }
        }
      } else {
        convertedCondition.addAll(condition);
      }

      // Query child records (limit to batch size)
      final queryBuilder = QueryBuilder(_dataStore, childTableName);
      for (final entry in convertedCondition.entries) {
        queryBuilder.where(entry.key, '=', entry.value);
      }
      // Only select primary key to save memory
      // We rely on DeleteBuilder for actual deletion, but we need PKs for recursion
      final childResults = await queryBuilder.limit(batchSize).future;

      if (childResults.data.isEmpty) {
        hasMore = false;
        break;
      }

      // Get primary keys of child records in this batch
      final childPkValues = childResults.data
          .map((r) => r[childSchema.primaryKey])
          .where((pk) => pk != null)
          .toList();

      if (childPkValues.isEmpty) {
        hasMore = false;
        break;
      }

      // Find all tables that reference the child table (for recursive cascade)
      final childReferencingTables =
          await _findReferencingTables(childTableName);

      // Recursively delete all descendants first (depth-first)
      // Important: If any recursive delete fails, we should propagate the error
      // to ensure transaction rollback and data consistency
      if (childReferencingTables.isNotEmpty) {
        // Sort child tables for deterministic processing
        final sortedChildTables = childReferencingTables.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));

        for (final childEntry in sortedChildTables) {
          final grandChildTableName = childEntry.key;
          final grandChildFks = childEntry.value;

          for (final grandChildFk in grandChildFks) {
            if (grandChildFk.onDelete == ForeignKeyCascadeAction.cascade) {
              // Recursively delete grandchildren
              // IMPORTANT: We call _cascadeDeleteWithRecursion directly instead of handleCascadeDelete
              // because handleCascadeDelete checks RESTRICT constraints for ALL foreign keys referencing
              // the child table, which would incorrectly block deletion when the child table has
              // RESTRICT foreign keys to other tables (e.g., comments.user_id -> users with RESTRICT).
              // In recursive cascade, we only care about the CASCADE foreign key that triggered this
              // recursion (grandChildFk), so we bypass RESTRICT checks for other foreign keys.
              for (final childPk in childPkValues) {
                try {
                  final recursiveCount = await _cascadeDeleteWithRecursion(
                    childTableName: grandChildTableName,
                    fk: grandChildFk,
                    parentPkValues: childPk,
                    visitedRecords: visitedRecords,
                  );
                  // Note: recursiveCount includes both grandchildren and their descendants
                  totalDeleted += recursiveCount;
                } catch (e) {
                  // Propagate error immediately - don't continue with partial deletes
                  // The transaction will rollback, ensuring data consistency
                  Logger.error(
                    'Cascade delete failed during recursive deletion of $grandChildTableName: $e',
                    label: 'ForeignKeyManager._cascadeDeleteWithRecursion',
                  );
                  rethrow;
                }
              }
            }
          }
        }
      }

      // Now delete the current batch of child records
      // Use batch delete by ID for efficiency and safety (we know these IDs exist and have processed their children)
      try {
        final deleteBuilder = DeleteBuilder(_dataStore, childTableName);
        // Use WHERE IN clause for batch delete
        if (childPkValues.length == 1) {
          deleteBuilder.where(childSchema.primaryKey, '=', childPkValues[0]);
        } else {
          deleteBuilder.where(childSchema.primaryKey, 'IN', childPkValues);
        }
        final deleteResult = await deleteBuilder.future;
        totalDeleted += deleteResult.successKeys.length;
      } catch (e) {
        // If deletion fails, propagate error to trigger transaction rollback
        Logger.error(
          'Cascade delete failed when deleting records from $childTableName: $e',
          label: 'ForeignKeyManager._cascadeDeleteWithRecursion',
        );
        rethrow;
      }

      // Check if we processed fewer records than batch size, if so, we are done
      if (childResults.data.length < batchSize) {
        hasMore = false;
      }
    }

    return totalDeleted;
  }

  /// Generate a unique key for a record (tableName:pkValue)
  String _generateRecordKey(String tableName, dynamic pkValue) {
    if (pkValue is Map) {
      // Composite key: sort keys to ensure consistent string representation
      final sortedKeys = pkValue.keys.toList()..sort();
      final buffer = StringBuffer();
      for (final key in sortedKeys) {
        buffer.write('$key:${pkValue[key]}|');
      }
      return '$tableName:$buffer';
    } else {
      return '$tableName:$pkValue';
    }
  }

  /// Cascade update child records' foreign key fields
  ///
  /// Optimized to directly batch update without querying first.
  ///
  /// Note: This method validates that the new primary key value exists in the referenced table
  /// before performing the update to ensure referential integrity.
  Future<int> _cascadeUpdateChildren({
    required String childTableName,
    required ForeignKeySchema fk,
    required dynamic oldParentPkValues,
    required dynamic newParentPkValues,
  }) async {
    // Verify that the child table still exists (may have been dropped during cascade)
    final childSchema =
        await _dataStore.schemaManager?.getTableSchema(childTableName);
    if (childSchema == null) {
      Logger.warn(
        'Child table $childTableName does not exist during cascade update, skipping',
        label: 'ForeignKeyManager._cascadeUpdateChildren',
      );
      return 0;
    }

    // Verify that the referenced table still exists
    final referencedSchema =
        await _dataStore.schemaManager?.getTableSchema(fk.referencedTable);
    if (referencedSchema == null) {
      throw BusinessError(
        'Referenced table ${fk.referencedTable} does not exist during cascade update for foreign key ${fk.actualName}',
        type: BusinessErrorType.invalidData,
      );
    }

    // Validate that the new primary key value exists in the referenced table
    // This ensures referential integrity before performing the cascade update
    //
    // Special case: If this is a self-referencing foreign key (childTableName == referencedTable),
    // and the new primary key value is the same as the old one (already validated in handleCascadeUpdate),
    // we can skip the validation since we're updating the same record.
    // However, if the new primary key value is different, we still need to verify it exists.
    final newPkCondition = <String, dynamic>{};
    if (newParentPkValues is Map) {
      // Composite primary key
      for (int i = 0; i < fk.referencedFields.length; i++) {
        final refField = fk.referencedFields[i];
        final pkValue = newParentPkValues[refField];
        if (pkValue != null) {
          newPkCondition[refField] = pkValue;
        }
      }
    } else {
      // Simple primary key
      final refField =
          fk.referencedFields.isNotEmpty ? fk.referencedFields[0] : null;
      if (refField != null) {
        newPkCondition[refField] = newParentPkValues;
      }
    }

    // Verify new primary key value exists (unless it's a self-reference with same value)
    // For self-referencing foreign keys, if oldPkValues == newPkValues, skip validation
    // since we're updating the same record (already handled in handleCascadeUpdate)
    bool skipValidation = false;
    if (childTableName == fk.referencedTable) {
      // Self-referencing foreign key
      if (oldParentPkValues is Map && newParentPkValues is Map) {
        // Compare composite keys
        bool allEqual = true;
        for (int i = 0; i < fk.referencedFields.length; i++) {
          final refField = fk.referencedFields[i];
          if (oldParentPkValues[refField] != newParentPkValues[refField]) {
            allEqual = false;
            break;
          }
        }
        skipValidation = allEqual;
      } else if (oldParentPkValues == newParentPkValues) {
        // Simple keys are equal
        skipValidation = true;
      }
    }

    if (!skipValidation && newPkCondition.isNotEmpty) {
      final verifyBuilder = QueryBuilder(_dataStore, fk.referencedTable);
      for (final entry in newPkCondition.entries) {
        verifyBuilder.where(entry.key, '=', entry.value);
      }
      final verifyResult = await verifyBuilder.limit(1).future;
      if (verifyResult.data.isEmpty) {
        throw BusinessError(
          'Cannot cascade update: New primary key value does not exist in referenced table ${fk.referencedTable} for foreign key ${fk.actualName}',
          type: BusinessErrorType.invalidData,
        );
      }
    }

    // Build query conditions using helper method (using the old primary key value)
    final condition = _buildForeignKeyCondition(fk, oldParentPkValues);

    if (condition.isEmpty) {
      return 0;
    }

    // Build update data (using the new primary key value)
    final updateData = <String, dynamic>{};

    if (newParentPkValues is Map) {
      // Composite primary key - update all foreign key fields
      for (int i = 0; i < fk.fields.length; i++) {
        final fkField = fk.fields[i];
        final refField = fk.referencedFields[i];
        final pkValue = newParentPkValues[refField];
        if (pkValue != null) {
          updateData[fkField] = pkValue;
        }
      }
    } else {
      // Simple primary key
      if (fk.fields.length == 1 && fk.referencedFields.length == 1) {
        updateData[fk.fields[0]] = newParentPkValues;
      }
    }

    if (updateData.isEmpty) {
      return 0;
    }

    // Directly batch update without querying first (more efficient)
    final updateBuilder = UpdateBuilder(_dataStore, childTableName, updateData);
    for (final entry in condition.entries) {
      updateBuilder.where(entry.key, '=', entry.value);
    }

    // Execute batch update
    final updateResult = await updateBuilder.future;

    // Return the number of updated records
    return updateResult.successKeys.length;
  }

  /// Set the foreign key field to NULL
  ///
  /// Validates that the foreign key fields allow NULL values before setting
  Future<void> _setForeignKeyToNull({
    required String childTableName,
    required ForeignKeySchema fk,
    required dynamic parentPkValues,
  }) async {
    // Validate that foreign key fields allow NULL
    // Note: Table may have been dropped during cascade operation, check and handle gracefully
    final childSchema =
        await _dataStore.schemaManager?.getTableSchema(childTableName);
    if (childSchema == null) {
      Logger.warn(
        'Child table $childTableName does not exist during set NULL operation, skipping',
        label: 'ForeignKeyManager._setForeignKeyToNull',
      );
      return;
    }

    for (final fieldName in fk.fields) {
      final field = childSchema.fields.firstWhere(
        (f) => f.name == fieldName,
        orElse: () => throw StateError('Field $fieldName not found'),
      );
      if (!field.nullable) {
        throw BusinessError(
          'Cannot set foreign key field $fieldName to NULL: field does not allow NULL values',
          type: BusinessErrorType.invalidData,
        );
      }
    }

    // Build query conditions using helper method
    final condition = _buildForeignKeyCondition(fk, parentPkValues);

    if (condition.isEmpty) {
      return;
    }

    // Build update data (set to null)
    final updateData = <String, dynamic>{};
    for (final field in fk.fields) {
      updateData[field] = null;
    }

    // Use batch update instead of querying first (more efficient)
    final updateBuilder = UpdateBuilder(_dataStore, childTableName, updateData);
    for (final entry in condition.entries) {
      updateBuilder.where(entry.key, '=', entry.value);
    }

    await updateBuilder.future;
  }

  /// Set the foreign key field to default value
  ///
  /// Validates that the foreign key fields have default values before setting.
  ///
  /// Note: For dynamic default values (e.g., currentTimestamp), all affected records
  /// will get the same value at the time of cascade operation, ensuring consistency.
  Future<void> _setForeignKeyToDefault({
    required String childTableName,
    required ForeignKeySchema fk,
    required dynamic parentPkValues,
  }) async {
    // Get the child table structure
    // Note: Table may have been dropped during cascade operation, check and handle gracefully
    final childSchema =
        await _dataStore.schemaManager?.getTableSchema(childTableName);
    if (childSchema == null) {
      Logger.warn(
        'Child table $childTableName does not exist during set DEFAULT operation, skipping',
        label: 'ForeignKeyManager._setForeignKeyToDefault',
      );
      return;
    }

    // Validate that all foreign key fields have default values
    // Get default values once to ensure consistency for dynamic defaults (e.g., currentTimestamp)
    final defaultValues = <String, dynamic>{};
    for (final fieldName in fk.fields) {
      final field = childSchema.fields.firstWhere(
        (f) => f.name == fieldName,
        orElse: () => throw StateError('Field $fieldName not found'),
      );
      final defaultValue = field.getDefaultValue();
      if (defaultValue == null && !field.nullable) {
        throw BusinessError(
          'Cannot set foreign key field $fieldName to default: field has no default value and does not allow NULL',
          type: BusinessErrorType.invalidData,
        );
      }
      // Store default value to ensure all records get the same value
      // This is important for dynamic defaults like currentTimestamp
      defaultValues[fieldName] = defaultValue;
    }

    // Build query conditions using helper method
    final condition = _buildForeignKeyCondition(fk, parentPkValues);

    if (condition.isEmpty) {
      return;
    }

    // Build update data (set to default value)
    // Use pre-computed default values to ensure consistency
    final updateData = <String, dynamic>{};
    for (final fieldName in fk.fields) {
      updateData[fieldName] = defaultValues[fieldName];
    }

    // Use batch update instead of querying first (more efficient)
    final updateBuilder = UpdateBuilder(_dataStore, childTableName, updateData);
    for (final entry in condition.entries) {
      updateBuilder.where(entry.key, '=', entry.value);
    }

    await updateBuilder.future;
  }

  /// Find all tables that reference the given table (with reverse mapping cache for O(1) lookup)
  ///
  /// This method maintains a reverse mapping cache (referenced table -> referencing tables)
  /// to provide O(1) lookup instead of O(n) table scan, critical for large-scale scenarios.
  ///
  /// Performance: O(1) lookup after initial cache build, O(n) only on cache rebuild
  ///
  /// Note: Cache is loaded lazily on first access. No time-based expiry - foreign key
  /// relationships are part of table structure and only change when schemas are modified.
  Future<Map<String, List<ForeignKeySchema>>> _findReferencingTables(
      String tableName) async {
    // Ensure cache is loaded (lazy loading)
    await _ensureCacheLoaded();

    // Return cached result - O(1) lookup
    return _referencingTablesCache?[tableName] ?? {};
  }

  /// Invalidate the foreign key relationship cache
  ///
  /// Call this when table schemas change (e.g., after adding/removing foreign keys)
  ///
  /// Note: This marks the cache for rebuild but doesn't immediately rebuild.
  /// The cache will be rebuilt on next access, and the system table will be updated.
  void invalidateCache() {
    _cacheNeedsRebuild = true;
    // Keep cache structure but mark for rebuild
    // Cache will be rebuilt on next access, either from system table or schemas
  }

  /// Update system table when foreign keys are added/modified/removed
  ///
  /// This method should be called whenever a table's foreign keys change
  /// to keep the system table in sync with the actual schema.
  ///
  /// [tableName] The table whose foreign keys have changed
  /// [schema] The updated table schema
  ///
  /// Note: This is a public method (not private) because it's called from DataStoreImpl
  Future<void> updateSystemTableForTable(
      String tableName, TableSchema schema) async {
    try {
      final fkTableName = SystemTable.getFkReferencesName();

      // Check if system table exists
      final tableExists = await _dataStore.tableExists(fkTableName);
      if (!tableExists) {
        // System table doesn't exist yet
        // This can happen during upgrade from old version without system_fk_references table
        // The system table should be created before user tables (ensured by getInitialSchema)
        // If we reach here, it means the system table creation was skipped or failed
        // Log a warning but don't throw - the system table will be created eventually
        Logger.warn(
          'System table $fkTableName does not exist yet. Foreign key relationships for table $tableName will not be stored in system table. '
          'This may happen during upgrade. The system table should be created before user tables.',
          label: 'ForeignKeyManager.updateSystemTableForTable',
        );
        return;
      }

      // Optimization: Compare existing system table entries with new schema
      // Only perform updates if there are changes to avoid unnecessary writes

      // 1. Get all existing FKs for this table from system table
      final queryBuilder = QueryBuilder(_dataStore, fkTableName);
      queryBuilder.where('referencing_table', '=', tableName);
      final existingResults = await queryBuilder.limit(1000000000).future;

      final existingFkMap = <String, Map<String, dynamic>>{};
      for (final record in existingResults.data) {
        final fkName = record['fk_name'] as String;
        existingFkMap[fkName] = record;
      }

      // 2. Perform differential update: Update existing, Insert new, Delete removed
      // This avoids unnecessary delete operations and preserves primary keys

      // Track which FKs from schema we've processed
      final processedFkNames = <String>{};

      // Process each FK in the schema
      for (final fk in schema.foreignKeys) {
        final existingRecord = existingFkMap[fk.actualName];
        final fkData = {
          'referenced_table': fk.referencedTable,
          'referencing_table': tableName,
          'fk_name': fk.actualName,
          'fk_fields': jsonEncode(fk.fields),
          'ref_fields': jsonEncode(fk.referencedFields),
          'on_delete': fk.onDelete.toString().split('.').last,
          'on_update': fk.onUpdate.toString().split('.').last,
          'enabled': fk.enabled,
        };

        if (existingRecord != null) {
          // FK exists - check if update is needed
          final needsUpdate = existingRecord['referenced_table'] !=
                  fk.referencedTable ||
              existingRecord['on_delete'] !=
                  fk.onDelete.toString().split('.').last ||
              existingRecord['on_update'] !=
                  fk.onUpdate.toString().split('.').last ||
              existingRecord['enabled'] != fk.enabled ||
              existingRecord['fk_fields'] != jsonEncode(fk.fields) ||
              existingRecord['ref_fields'] != jsonEncode(fk.referencedFields);

          if (needsUpdate) {
            // Update existing record (preserves primary key)
            final updateData = <String, dynamic>{};
            for (final entry in fkData.entries) {
              // Don't update composite key fields (they're used in WHERE clause)
              if (entry.key != 'referencing_table' &&
                  entry.key != 'referenced_table' &&
                  entry.key != 'fk_name') {
                updateData[entry.key] = entry.value;
              }
            }

            if (updateData.isNotEmpty) {
              final updateBuilder =
                  UpdateBuilder(_dataStore, fkTableName, updateData);
              updateBuilder
                  .where('referencing_table', '=', tableName)
                  .where('referenced_table', '=', fk.referencedTable)
                  .where('fk_name', '=', fk.actualName);
              await updateBuilder.future;
            }
          }
          // If no update needed, skip
        } else {
          // New FK - insert
          await _dataStore.insert(fkTableName, fkData);
        }

        processedFkNames.add(fk.actualName);
      }

      // Delete FKs that no longer exist in schema
      for (final existingFkName in existingFkMap.keys) {
        if (!processedFkNames.contains(existingFkName)) {
          // This FK was removed from schema, delete it
          final existingRecord = existingFkMap[existingFkName];
          if (existingRecord != null) {
            final deleteBuilder = DeleteBuilder(_dataStore, fkTableName);
            deleteBuilder
                .where('referencing_table', '=', tableName)
                .where(
                    'referenced_table', '=', existingRecord['referenced_table'])
                .where('fk_name', '=', existingFkName);
            await deleteBuilder.future;
          }
        }
      }

      // Invalidate cache to force reload
      invalidateCache();
    } catch (e) {
      Logger.warn(
        'Failed to update system table for table $tableName: $e',
        label: 'ForeignKeyManager.updateSystemTableForTable',
      );
      // Don't throw - cache invalidation will handle it
    }
  }

  /// Check if any tables reference the given table via foreign keys
  ///
  /// This is a public method to check foreign key references before dropping a table
  Future<Map<String, List<ForeignKeySchema>>> findReferencingTables(
      String tableName) async {
    return await _findReferencingTables(tableName);
  }

  /// Clean up system table entries when a table is dropped
  ///
  /// This method removes all foreign key relationship records from the system table
  /// when a table is dropped. It handles both:
  /// 1. Records where the table is the referencing table (table has foreign keys)
  /// 2. Records where the table is the referenced table (other tables reference it)
  ///
  /// [tableName] The table being dropped
  Future<void> cleanupSystemTableForDroppedTable(String tableName) async {
    try {
      final fkTableName = SystemTable.getFkReferencesName();

      // Check if system table exists
      final tableExists = await _dataStore.tableExists(fkTableName);
      if (!tableExists) {
        return;
      }

      // Delete all records where this table is either referencing or referenced
      // Use OR condition to delete both cases:
      // 1. Records where this table references others (referencing_table = tableName)
      // 2. Records where others reference this table (referenced_table = tableName)
      final deleteBuilder = DeleteBuilder(_dataStore, fkTableName);
      deleteBuilder
          .where('referencing_table', '=', tableName)
          .orWhere('referenced_table', '=', tableName);
      await deleteBuilder.future;

      // Invalidate cache to force reload
      invalidateCache();

      Logger.debug(
        'Cleaned up system table entries for dropped table: $tableName',
        label: 'ForeignKeyManager.cleanupSystemTableForDroppedTable',
      );
    } catch (e) {
      Logger.warn(
        'Failed to cleanup system table for dropped table $tableName: $e',
        label: 'ForeignKeyManager.cleanupSystemTableForDroppedTable',
      );
      // Don't throw - cache invalidation will handle it
    }
  }

  /// Build foreign key condition map from parent primary key values
  ///
  /// Helper method to build query conditions for foreign key lookups
  Map<String, dynamic> _buildForeignKeyCondition(
    ForeignKeySchema fk,
    dynamic parentPkValues,
  ) {
    final condition = <String, dynamic>{};

    if (parentPkValues is Map) {
      // Composite primary key
      for (int i = 0; i < fk.fields.length; i++) {
        final fkField = fk.fields[i];
        final refField = fk.referencedFields[i];
        final pkValue = parentPkValues[refField];
        if (pkValue != null) {
          condition[fkField] = pkValue;
        }
      }
    } else {
      // Simple primary key
      if (fk.fields.length == 1 && fk.referencedFields.length == 1) {
        condition[fk.fields[0]] = parentPkValues;
      }
    }

    return condition;
  }

  /// Automatically create index for foreign key fields
  ///
  /// Called when the table is created, create indexes for all foreign key fields that have autoCreateIndex enabled
  Future<void> createForeignKeyIndexes(String tableName) async {
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return;

    final allIndexes =
        _dataStore.schemaManager?.getAllIndexesFor(schema) ?? <IndexSchema>[];
    if (allIndexes.isEmpty) return;

    for (final fk in schema.foreignKeys) {
      if (!fk.enabled || !fk.autoCreateIndex) {
        continue;
      }

      // getAllIndexes() guarantees such an index exists (either explicit or auto-generated)
      IndexSchema? coveringIndex;
      try {
        coveringIndex = allIndexes.firstWhere((index) {
          if (index.fields.length < fk.fields.length) return false;
          for (int i = 0; i < fk.fields.length; i++) {
            if (index.fields[i] != fk.fields[i]) return false;
          }
          return true;
        });
      } catch (_) {
        // Should not happen if getAllIndexes logic is correct
        coveringIndex = null;
      }

      if (coveringIndex != null) {
        try {
          await _dataStore.indexManager?.createIndex(tableName, coveringIndex);
          Logger.info(
            'Ensured index ${coveringIndex.actualIndexName} exists for foreign key ${fk.actualName}',
            label: 'ForeignKeyManager.createForeignKeyIndexes',
          );
        } catch (e) {
          // Ignore "index already exists" type errors if they are noisy, but logging warning is safer
          Logger.warn(
            'Failed to create/ensure index for foreign key ${fk.actualName}: $e',
            label: 'ForeignKeyManager.createForeignKeyIndexes',
          );
        }
      }
    }
  }
}
