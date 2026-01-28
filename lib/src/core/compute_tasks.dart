import 'dart:async';
import 'dart:math';

import '../model/table_schema.dart';
import '../model/data_store_config.dart';
import '../model/migration_task.dart';
import '../handler/value_matcher.dart';
import '../handler/logger.dart';
import 'btree_page.dart';
import 'table_data_manager.dart';
import 'yield_controller.dart';
import '../handler/wal_encoder.dart';
import '../handler/encoder.dart';
import '../model/encoder_config.dart';
import 'dart:typed_data';

/// Table similarity calculation request
class TableSimilarityRequest {
  /// Old table schema
  final TableSchema oldSchema;

  /// New table schema
  final TableSchema newSchema;

  /// Old table index
  final int oldTableIndex;

  /// New table index
  final int newTableIndex;

  /// Old table count
  final int oldTablesCount;

  /// New table count
  final int newTablesCount;

  /// Yield budget in milliseconds
  final int? yieldDurationMs;

  TableSimilarityRequest({
    required this.oldSchema,
    required this.newSchema,
    required this.oldTableIndex,
    required this.newTableIndex,
    required this.oldTablesCount,
    required this.newTablesCount,
    this.yieldDurationMs,
  });
}

/// Table similarity calculation result
class TableSimilarityResult {
  /// Old table name
  final String oldTableName;

  /// New table schema
  final TableSchema newSchema;

  /// Similarity (0-1)
  final double similarity;

  TableSimilarityResult({
    required this.oldTableName,
    required this.newSchema,
    required this.similarity,
  });
}

/// Table similarity batch calculation request
class BatchTableSimilarityRequest {
  /// List of similarity requests to process
  final List<TableSimilarityRequest> requests;

  /// Yield budget in milliseconds
  final int? yieldDurationMs;

  BatchTableSimilarityRequest({
    required this.requests,
    this.yieldDurationMs,
  });
}

/// Table similarity batch calculation result
class BatchTableSimilarityResult {
  /// List of similarity results
  final List<TableSimilarityResult> results;

  BatchTableSimilarityResult({
    required this.results,
  });
}

/// Field similarity calculation request
class FieldSimilarityRequest {
  /// Old field
  final FieldSchema oldField;

  /// New field
  final FieldSchema newField;

  /// Old field index
  final int oldFieldIndex;

  /// New field index
  final int newFieldIndex;

  /// Old table field count
  final int oldFieldsCount;

  /// New table field count
  final int newFieldsCount;

  /// Old table schema
  final TableSchema oldSchema;

  /// New table schema
  final TableSchema newSchema;

  FieldSimilarityRequest({
    required this.oldField,
    required this.newField,
    required this.oldFieldIndex,
    required this.newFieldIndex,
    required this.oldFieldsCount,
    required this.newFieldsCount,
    required this.oldSchema,
    required this.newSchema,
  });
}

/// Field similarity calculation result
class FieldSimilarityResult {
  /// Old field name
  final String oldFieldName;

  /// New field
  final FieldSchema newField;

  /// Similarity (0-1)
  final double similarity;

  FieldSimilarityResult({
    required this.oldFieldName,
    required this.newField,
    required this.similarity,
  });
}

/// Field similarity batch calculation request
class BatchFieldSimilarityRequest {
  /// List of similarity requests to process
  final List<FieldSimilarityRequest> requests;

  /// Yield budget in milliseconds
  final int? yieldDurationMs;

  BatchFieldSimilarityRequest({
    required this.requests,
    this.yieldDurationMs,
  });
}

/// Field similarity batch calculation result
class BatchFieldSimilarityResult {
  /// List of similarity results
  final List<FieldSimilarityResult> results;

  BatchFieldSimilarityResult({
    required this.results,
  });
}

/// Calculate similarity between two tables
Future<TableSimilarityResult> calculateTableSimilarity(
    TableSimilarityRequest request) async {
  double score = 0.0;
  double totalWeight = 0.0;

  // 1. First check table name similarity (medium weight)
  const nameWeight = 10.0;
  totalWeight += nameWeight;
  double nameScore =
      _calculateNameSimilarity(request.oldSchema.name, request.newSchema.name);
  score += nameWeight * nameScore;

  // 2. Check primary key (high weight)
  const primaryKeyWeight = 20.0;
  totalWeight += primaryKeyWeight;
  if (request.oldSchema.primaryKey == request.newSchema.primaryKey) {
    score += primaryKeyWeight;
  } else {
    // Primary key mismatch is a strong negative signal
    score -= primaryKeyWeight * 0.5;
  }

  // 3. Check isGlobal property (medium weight)
  const globalWeight = 10.0;
  totalWeight += globalWeight;
  if (request.oldSchema.isGlobal == request.newSchema.isGlobal) {
    score += globalWeight;
  } else {
    // isGlobal mismatch is an important signal
    score -= globalWeight * 0.3;
  }

  // 4. Check field matching (highest weight)
  const fieldsWeight = 50.0;
  totalWeight += fieldsWeight;

  // 4.1 Field count comparison
  double fieldsScore = 0.0;
  if (request.oldSchema.fields.isEmpty || request.newSchema.fields.isEmpty) {
    fieldsScore = 0.0;
  } else {
    // Check common field count
    int matchingFields = 0;
    Set<String> oldFieldNames =
        request.oldSchema.fields.map((f) => f.name).toSet();
    Set<String> newFieldNames =
        request.newSchema.fields.map((f) => f.name).toSet();

    // Calculate common field count
    for (final name in oldFieldNames) {
      if (newFieldNames.contains(name)) {
        matchingFields++;
      }
    }

    // Calculate field match rate
    final matchingFieldsRatio = request.oldSchema.fields.isEmpty ||
            request.newSchema.fields.isEmpty
        ? 0.0
        : (2 * matchingFields) / (oldFieldNames.length + newFieldNames.length);

    fieldsScore = matchingFieldsRatio;
  }

  score += fieldsWeight * fieldsScore;

  // 5. Index match rate (medium weight)
  const indexWeight = 15.0;
  totalWeight += indexWeight;

  double indexScore = 0.0;
  if (request.oldSchema.indexes.isEmpty && request.newSchema.indexes.isEmpty) {
    // Both have no indexes, perfect match
    indexScore = 1.0;
  } else if (request.oldSchema.indexes.isEmpty ||
      request.newSchema.indexes.isEmpty) {
    // One has index, one doesn't, not a good match
    indexScore = 0.1;
  } else {
    // Check index field matching
    int matchingIndexes = 0;

    for (final oldIndex in request.oldSchema.indexes) {
      for (final newIndex in request.newSchema.indexes) {
        if (_areFieldListsEqual(oldIndex.fields, newIndex.fields)) {
          matchingIndexes++;
          break;
        }
      }
    }

    // Calculate index match rate
    final totalIndexes =
        request.oldSchema.indexes.length + request.newSchema.indexes.length;
    indexScore = totalIndexes > 0 ? (2 * matchingIndexes) / totalIndexes : 0.0;
  }

  score += indexWeight * indexScore;

  // 6. Table position matching (low weight)
  const positionWeight = 5.0;
  totalWeight += positionWeight;

  // Calculate relative position difference
  double positionDiff;
  if (request.oldTablesCount <= 1 || request.newTablesCount <= 1) {
    positionDiff = 0;
  } else {
    positionDiff = (request.oldTableIndex / (request.oldTablesCount - 1) -
            request.newTableIndex / (request.newTablesCount - 1))
        .abs();
  }

  score += positionWeight * (1 - positionDiff);

  // Calculate final score
  double finalScore = totalWeight > 0 ? score / totalWeight : 0.0;

  return TableSimilarityResult(
    oldTableName: request.oldSchema.name,
    newSchema: request.newSchema,
    similarity: finalScore,
  );
}

/// Batch calculate table similarity
Future<BatchTableSimilarityResult> calculateBatchTableSimilarity(
    BatchTableSimilarityRequest request) async {
  final results = <TableSimilarityResult>[];
  final yieldController = YieldController(
      'ComputeTasks.calculateBatchTableSimilarity',
      checkInterval: 1,
      budgetMs: request.yieldDurationMs);

  for (final req in request.requests) {
    await yieldController.maybeYield();
    final result = await calculateTableSimilarity(req);
    results.add(result);
  }

  return BatchTableSimilarityResult(results: results);
}

/// Calculate similarity between two fields
Future<FieldSimilarityResult> calculateFieldSimilarity(
    FieldSimilarityRequest request) async {
  double score = 0.0;
  double totalWeight = 0.0;

  // 1. Basic type matching (high weight)
  const typeWeight = 20.0;
  totalWeight += typeWeight;
  if (request.oldField.type == request.newField.type) {
    score += typeWeight;
  } else {
    // Type mismatch, reduce some weight
    score -= typeWeight * 0.7;
  }

  // 2. Default value matching (if not basic empty value)
  const defaultValueWeight = 15.0;
  totalWeight += defaultValueWeight;
  if (request.oldField.defaultValue != null &&
      request.newField.defaultValue != null) {
    if (request.oldField.defaultValue == request.newField.defaultValue) {
      score += defaultValueWeight;
    } else {
      // Default value mismatch is a strong negative signal
      score -= defaultValueWeight * 0.5;
    }
  } else if (request.oldField.defaultValue == null &&
      request.newField.defaultValue == null) {
    // Both are empty, also considered partial match
    score += defaultValueWeight * 0.5;
  }

  // 3. Comment matching (high weight for non-empty and meaningful comments)
  const commentWeight = 20.0;
  if (request.oldField.comment != null &&
      request.newField.comment != null &&
      request.oldField.comment!.length > 1 &&
      request.newField.comment!.length > 1) {
    totalWeight += commentWeight;
    if (request.oldField.comment == request.newField.comment) {
      score += commentWeight;
    } else {
      // Different meaningful comments are strong negative signals
      score -= commentWeight * 0.5;
    }
  }

  // 4. Nullable and unique property matching
  const nullableWeight = 10.0;
  totalWeight += nullableWeight;
  if (request.oldField.nullable == request.newField.nullable) {
    score += nullableWeight;
  } else {
    // Nullable mismatch is a negative signal
    score -= nullableWeight * 0.3;
  }

  const uniqueWeight = 10.0;
  totalWeight += uniqueWeight;
  if (request.oldField.unique == request.newField.unique) {
    score += uniqueWeight;
  } else {
    // Unique mismatch is a negative signal
    score -= uniqueWeight * 0.3;
  }

  // 5. Length and value range constraint matching
  const constraintWeight = 5.0;
  double constraintsChecked = 0;
  double constraintsMatched = 0;

  // maxLength check
  if (request.oldField.maxLength != null ||
      request.newField.maxLength != null) {
    constraintsChecked++;
    if (request.oldField.maxLength == request.newField.maxLength) {
      constraintsMatched++;
    }
  }

  // minLength check
  if (request.oldField.minLength != null ||
      request.newField.minLength != null) {
    constraintsChecked++;
    if (request.oldField.minLength == request.newField.minLength) {
      constraintsMatched++;
    }
  }

  // minValue check
  if (request.oldField.minValue != null || request.newField.minValue != null) {
    constraintsChecked++;
    if (request.oldField.minValue == request.newField.minValue) {
      constraintsMatched++;
    }
  }

  // maxValue check
  if (request.oldField.maxValue != null || request.newField.maxValue != null) {
    constraintsChecked++;
    if (request.oldField.maxValue == request.newField.maxValue) {
      constraintsMatched++;
    }
  }

  if (constraintsChecked > 0) {
    totalWeight += constraintWeight;
    score += (constraintsMatched / constraintsChecked) * constraintWeight;
  }

  // 6. Field position matching (high weight)
  const positionWeight = 25.0;
  totalWeight += positionWeight;

  // Calculate relative position difference (0-1 value, 0 means perfect match)
  double positionDiff;
  if (request.oldFieldsCount == 1 || request.newFieldsCount == 1) {
    // If there is only one field, position is not important
    positionDiff = 0;
  } else {
    // Normalize position difference to 0-1
    positionDiff = (request.oldFieldIndex / (request.oldFieldsCount - 1) -
            request.newFieldIndex / (request.newFieldsCount - 1))
        .abs();
  }

  // The closer the position, the higher the score
  score += positionWeight * (1 - positionDiff);

  // 7. Field name similarity check
  const nameWeight = 15.0;
  totalWeight += nameWeight;

  // Field name string similarity
  double nameScore =
      _calculateNameSimilarity(request.oldField.name, request.newField.name);
  score += nameWeight * nameScore;

  // 8. Index position check
  const indexWeight = 5.0;
  bool oldFieldInIndex =
      _isFieldInIndex(request.oldField.name, request.oldSchema.indexes);
  bool newFieldInIndex =
      _isFieldInIndex(request.newField.name, request.newSchema.indexes);

  if (oldFieldInIndex && newFieldInIndex) {
    totalWeight += indexWeight;
    score += indexWeight;
  } else if (!oldFieldInIndex && !newFieldInIndex) {
    // Both are not in index, also considered match
    totalWeight += indexWeight;
    score += indexWeight * 0.5;
  }

  // 9. Field count similarity (extra factor)
  if (request.oldFieldsCount == request.newFieldsCount) {
    // Field count is consistent, add a small extra score
    score += 5.0;
    totalWeight += 5.0;
  }

  // Calculate final percentage score (0-1)
  double finalScore = totalWeight > 0 ? score / totalWeight : 0.0;

  return FieldSimilarityResult(
    oldFieldName: request.oldField.name,
    newField: request.newField,
    similarity: finalScore,
  );
}

/// Batch calculate field similarity
Future<BatchFieldSimilarityResult> calculateBatchFieldSimilarity(
    BatchFieldSimilarityRequest request) async {
  final results = <FieldSimilarityResult>[];
  final yieldController = YieldController(
      'ComputeTasks.calculateBatchFieldSimilarity',
      checkInterval: 1,
      budgetMs: request.yieldDurationMs);

  for (final req in request.requests) {
    await yieldController.maybeYield();
    final result = await calculateFieldSimilarity(req);
    results.add(result);
  }

  return BatchFieldSimilarityResult(results: results);
}

/// Check if field is in any index
bool _isFieldInIndex(String fieldName, List<IndexSchema> indexes) {
  for (var index in indexes) {
    if (index.fields.contains(fieldName)) {
      return true;
    }
  }
  return false;
}

/// Calculate if two lists contain the same elements, ignoring order
bool _areFieldListsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final setA = Set<String>.from(a);
  final setB = Set<String>.from(b);
  return setA.difference(setB).isEmpty;
}

/// Calculate similarity between two names
double _calculateNameSimilarity(String oldName, String newName) {
  // 1. Normalize processing: convert to lowercase
  final oldNameLower = oldName.toLowerCase();
  final newNameLower = newName.toLowerCase();

  if (oldNameLower == newNameLower) {
    return 1.0; // Perfect match
  }

  // 2. Camel case and underscore conversion comparison
  String oldNameNormalized = _normalizeFieldName(oldNameLower);
  String newNameNormalized = _normalizeFieldName(newNameLower);

  if (oldNameNormalized == newNameNormalized) {
    return 0.9; // Very close
  }

  // 3. Calculate longest common subsequence
  int lcsLength =
      _getLongestCommonSubsequenceLength(oldNameNormalized, newNameNormalized);
  int maxLength = oldNameNormalized.length > newNameNormalized.length
      ? oldNameNormalized.length
      : newNameNormalized.length;

  // Return similarity score between 0 and 1
  return maxLength > 0 ? lcsLength / maxLength : 0.0;
}

/// Normalize field name: handle camel case and underscore
String _normalizeFieldName(String name) {
  // Camel case to underscore
  String result = name.replaceAllMapped(
      RegExp(r'[A-Z]'), (match) => '_${match.group(0)!.toLowerCase()}');

  // Handle consecutive underscores
  result = result.replaceAll(RegExp(r'_+'), '_');

  // Delete leading underscore
  if (result.startsWith('_')) {
    result = result.substring(1);
  }

  return result;
}

/// Get longest common subsequence length
int _getLongestCommonSubsequenceLength(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;

  List<List<int>> dp =
      List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));

  for (int i = 1; i <= a.length; i++) {
    for (int j = 1; j <= b.length; j++) {
      if (a[i - 1] == b[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1] + 1;
      } else {
        dp[i][j] = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
      }
    }
  }

  return dp[a.length][b.length];
}

/// Table record migration processing request
class MigrationRecordProcessRequest {
  /// Records to migrate
  final List<Map<String, dynamic>> records;

  /// Table operations
  final List<MigrationOperation> operations;

  /// Old table schema (optional)
  final TableSchema? oldSchema;

  /// Yield budget in milliseconds
  final int? yieldDurationMs;

  MigrationRecordProcessRequest({
    required this.records,
    required this.operations,
    this.oldSchema,
    this.yieldDurationMs,
  });
}

/// Table record migration processing result
class MigrationRecordProcessResult {
  /// Processed records
  final List<Map<String, dynamic>> migratedRecords;

  /// Processing result status
  final bool success;

  /// Error message (if any)
  final String? errorMessage;

  MigrationRecordProcessResult({
    required this.migratedRecords,
    this.success = true,
    this.errorMessage,
  });
}

/// Process record migration
Future<MigrationRecordProcessResult> processMigrationRecords(
    MigrationRecordProcessRequest request) async {
  try {
    if (request.records.isEmpty || request.operations.isEmpty) {
      return MigrationRecordProcessResult(
        migratedRecords: request.records,
        success: true,
      );
    }

    var modifiedRecords = List<Map<String, dynamic>>.from(request.records);

    // Create YieldController for async loop processing
    // Create YieldController for async loop processing
    final yieldController = YieldController('ProcessMigrationRecords',
        budgetMs: request.yieldDurationMs);

    // Use sorted operations, no need to reorder
    for (var operation in request.operations) {
      switch (operation.type) {
        case MigrationType.addField:
          final field = operation.field!;
          final newRecords = <Map<String, dynamic>>[];
          for (var record in modifiedRecords) {
            await yieldController.maybeYield();
            // Skip processing deleted records
            if (isDeletedRecord(record)) {
              newRecords.add(record);
              continue;
            }
            if (!record.containsKey(field.name)) {
              record[field.name] = field.getDefaultValue();
            }
            newRecords.add(record);
          }
          modifiedRecords = newRecords;
          break;

        case MigrationType.removeField:
          final fieldName = operation.fieldName!;
          final newRecords = <Map<String, dynamic>>[];
          for (var record in modifiedRecords) {
            await yieldController.maybeYield();
            // Skip processing deleted records
            if (isDeletedRecord(record)) {
              newRecords.add(record);
              continue;
            }
            record.remove(fieldName);
            newRecords.add(record);
          }
          modifiedRecords = newRecords;
          break;

        case MigrationType.renameField:
          final oldName = operation.fieldName!;
          final newName = operation.newName!;
          final newRecords = <Map<String, dynamic>>[];
          for (var record in modifiedRecords) {
            await yieldController.maybeYield();
            // Skip processing deleted records
            if (isDeletedRecord(record)) {
              newRecords.add(record);
              continue;
            }
            if (record.containsKey(oldName)) {
              record[newName] = record[oldName];
              record.remove(oldName);
            }
            newRecords.add(record);
          }
          modifiedRecords = newRecords;
          break;

        case MigrationType.modifyField:
          final fieldUpdate = operation.fieldUpdate!;
          // Get old field information
          FieldSchema? oldFieldSchema;
          if (request.oldSchema != null) {
            try {
              oldFieldSchema = request.oldSchema!.fields
                  .firstWhere((f) => f.name == fieldUpdate.name);
            } catch (e) {
              oldFieldSchema = null;
            }
          }
          final newRecords = <Map<String, dynamic>>[];
          for (var record in modifiedRecords) {
            await yieldController.maybeYield();
            // Skip processing deleted records
            if (isDeletedRecord(record)) {
              newRecords.add(record);
              continue;
            }
            if (record.containsKey(fieldUpdate.name)) {
              // Call the method to process field modification, pass old field information
              record = _applyFieldModification(record, fieldUpdate,
                  oldFieldSchema: oldFieldSchema);
            }
            newRecords.add(record);
          }
          modifiedRecords = newRecords;
          break;

        case MigrationType.addIndex:
          // Index operation does not affect record data
          break;

        case MigrationType.removeIndex:
          break;

        case MigrationType.modifyIndex:
          break;

        case MigrationType.renameTable:
          // Table rename operation does not affect current record data, but needs to be handled at a higher level
          break;

        case MigrationType.dropTable:
          // Delete table operation does not affect record data
          break;

        case MigrationType.setPrimaryKeyConfig:
          // Process primary key configuration changes, especially handle primary key name changes and data type changes
          if (operation.oldPrimaryKeyConfig != null &&
              operation.primaryKeyConfig != null) {
            final oldConfig = operation.oldPrimaryKeyConfig!;
            final newConfig = operation.primaryKeyConfig!;

            // Process primary key name changes
            if (oldConfig.name != newConfig.name) {
              final newRecords = <Map<String, dynamic>>[];
              for (var record in modifiedRecords) {
                await yieldController.maybeYield();
                // Skip processing deleted records
                if (isDeletedRecord(record)) {
                  newRecords.add(record);
                  continue;
                }
                if (record.containsKey(oldConfig.name)) {
                  // Copy old primary key field value to new primary key field
                  record[newConfig.name] = record[oldConfig.name];
                  // Delete old primary key field
                  record.remove(oldConfig.name);
                }
                newRecords.add(record);
              }
              modifiedRecords = newRecords;
            }
          }
          break;

        case MigrationType.addForeignKey:
          // Foreign key addition does not affect record data
          // Data validation for foreign key constraints is handled at migration execution level
          // (in MigrationManager._executeSchemaOperation)
          break;

        case MigrationType.removeForeignKey:
          // Foreign key removal does not affect record data
          // It only removes the constraint, existing data remains unchanged
          break;

        case MigrationType.modifyForeignKey:
          // Foreign key modification (onDelete, onUpdate, enabled, etc.) does not affect record data
          // It only changes cascade behavior, existing data remains unchanged
          // Note: Core definition changes (fields, referencedTable, referencedFields)
          // are not allowed and will throw exception during schema comparison
          break;
      }
    }

    return MigrationRecordProcessResult(
      migratedRecords: modifiedRecords,
      success: true,
    );
  } catch (e) {
    Logger.error('Failed to process migration records: $e',
        label: 'processMigrationRecords');
    return MigrationRecordProcessResult(
      migratedRecords: request.records,
      success: false,
      errorMessage: e.toString(),
    );
  }
}

/// Apply field modification to a single record
Map<String, dynamic> _applyFieldModification(
    Map<String, dynamic> record, FieldSchemaUpdate fieldUpdate,
    {FieldSchema? oldFieldSchema}) {
  // Create field schema for validation and get default value
  final fieldSchema = FieldSchema(
    name: fieldUpdate.name,
    type: fieldUpdate.type ?? (oldFieldSchema?.type ?? DataType.text),
    nullable: fieldUpdate.nullable ?? (oldFieldSchema?.nullable ?? true),
    defaultValue: fieldUpdate.isExplicitlySet('defaultValue')
        ? fieldUpdate.defaultValue
        : oldFieldSchema?.defaultValue,
    unique: fieldUpdate.unique ?? (oldFieldSchema?.unique ?? false),
    maxLength: fieldUpdate.isExplicitlySet('maxLength')
        ? fieldUpdate.maxLength
        : oldFieldSchema?.maxLength,
    minLength: fieldUpdate.isExplicitlySet('minLength')
        ? fieldUpdate.minLength
        : oldFieldSchema?.minLength,
    minValue: fieldUpdate.isExplicitlySet('minValue')
        ? fieldUpdate.minValue
        : oldFieldSchema?.minValue,
    maxValue: fieldUpdate.isExplicitlySet('maxValue')
        ? fieldUpdate.maxValue
        : oldFieldSchema?.maxValue,
    comment: fieldUpdate.isExplicitlySet('comment')
        ? fieldUpdate.comment
        : oldFieldSchema?.comment,
    defaultValueType: fieldUpdate.isExplicitlySet('defaultValueType')
        ? (fieldUpdate.defaultValueType ?? DefaultValueType.none)
        : (oldFieldSchema?.defaultValueType ?? DefaultValueType.none),
  );

  // 1. Process type changes
  if (fieldUpdate.type != null) {
    try {
      record[fieldUpdate.name] = fieldSchema.convertValue(
        record[fieldUpdate.name],
      );
    } catch (e) {
      record[fieldUpdate.name] = fieldSchema.getDefaultValue();
      Logger.warn(
        'Failed to convert field ${fieldUpdate.name} to type ${fieldUpdate.type}, using default value: $e',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }
  }

  // 2. Process null constraint changes
  if (fieldUpdate.nullable != null &&
      !fieldUpdate.nullable! &&
      record[fieldUpdate.name] == null) {
    record[fieldUpdate.name] = fieldSchema.getDefaultValue();
    Logger.debug(
      'Field ${fieldUpdate.name} is now non-nullable, applied default value',
      label: 'processMigrationRecords._applyFieldModification',
    );
  }

  // 3. Process default value changes
  if (fieldUpdate.isExplicitlySet('defaultValue') &&
      record[fieldUpdate.name] == null) {
    record[fieldUpdate.name] = fieldUpdate.defaultValue;
    Logger.debug(
      'Field ${fieldUpdate.name} has new default value, applied to null value',
      label: 'processMigrationRecords._applyFieldModification',
    );
  }

  // 4. Process unique constraint changes (only log, do not directly process data itself)
  if (fieldUpdate.unique != null && fieldUpdate.unique!) {
    Logger.debug(
      'Field ${fieldUpdate.name} now has unique constraint, further validation may be needed',
      label: 'processMigrationRecords._applyFieldModification',
    );
  }

  // 5. Process length constraint changes (only log, do not directly process data itself)
  if ((fieldUpdate.isExplicitlySet('maxLength') ||
          fieldUpdate.isExplicitlySet('minLength')) &&
      record[fieldUpdate.name] is String) {
    String value = record[fieldUpdate.name];
    if (fieldUpdate.isExplicitlySet('maxLength') &&
        fieldUpdate.maxLength != null &&
        value.length > fieldUpdate.maxLength!) {
      record[fieldUpdate.name] = value.substring(0, fieldUpdate.maxLength!);
      Logger.warn(
        'Field ${fieldUpdate.name} exceeds max length of ${fieldUpdate.maxLength}, truncated',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }
    if (fieldUpdate.isExplicitlySet('minLength') &&
        fieldUpdate.minLength != null &&
        value.length < fieldUpdate.minLength!) {
      record[fieldUpdate.name] = fieldSchema.getDefaultValue();
      Logger.warn(
        'Field ${fieldUpdate.name} is shorter than min length of ${fieldUpdate.minLength}, using default value',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }
  }

  // 6. Process value range constraint changes (only log, do not directly process data itself)
  if ((fieldUpdate.isExplicitlySet('minValue') ||
          fieldUpdate.isExplicitlySet('maxValue')) &&
      record[fieldUpdate.name] is num) {
    num value = record[fieldUpdate.name];

    if (fieldUpdate.isExplicitlySet('minValue') &&
        fieldUpdate.minValue != null &&
        value < fieldUpdate.minValue!) {
      record[fieldUpdate.name] = fieldUpdate.minValue;
      Logger.warn(
        'Field ${fieldUpdate.name} below min value of ${fieldUpdate.minValue}, set to min',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }

    if (fieldUpdate.isExplicitlySet('maxValue') &&
        fieldUpdate.maxValue != null &&
        value > fieldUpdate.maxValue!) {
      record[fieldUpdate.name] = fieldUpdate.maxValue;
      Logger.warn(
        'Field ${fieldUpdate.name} exceeds max value of ${fieldUpdate.maxValue}, set to max',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }
  }

  // 7. Final validation
  if (!fieldSchema.validateValue(record[fieldUpdate.name])) {
    record[fieldUpdate.name] = fieldSchema.getDefaultValue();
    Logger.warn(
      'Field ${fieldUpdate.name} value does not meet constraints after updates, using default value',
      label: 'processMigrationRecords._applyFieldModification',
    );
  }

  return record;
}

/// Time-based ID generation request (for isolate)
class TimeBasedIdGenerateRequest {
  /// ID type
  final PrimaryKeyType keyType;

  /// Node configuration
  final DistributedNodeConfig nodeConfig;

  /// Table name
  final String tableName;

  /// Generation count
  final int count;

  /// Start time or date value
  final dynamic startValue;

  /// Start sequence number
  final int startSequence;

  /// Whether to use new timestamp
  final bool useNewTimestamp;

  /// Whether to use random step
  final bool useRandomStep;

  /// High generation mode
  final bool isHighGeneration;

  TimeBasedIdGenerateRequest({
    required this.keyType,
    required this.nodeConfig,
    required this.tableName,
    required this.count,
    required this.startValue,
    required this.startSequence,
    this.useNewTimestamp = false,
    this.useRandomStep = false,
    this.isHighGeneration = false,
  });
}

/// Time-based ID generation result (isolate return)
class TimeBasedIdGenerateResult {
  /// List of generated IDs
  final List<String> ids;

  /// Latest time value
  final dynamic lastValue;

  /// Latest sequence number
  final int lastSequence;

  /// Whether generation is successful
  final bool success;

  /// Error message
  final String? errorMessage;

  TimeBasedIdGenerateResult({
    required this.ids,
    required this.lastValue,
    required this.lastSequence,
    this.success = true,
    this.errorMessage,
  });
}

/// Base62 encoder copied to avoid class reference issues in isolate
class _IsolateBase62Encoder {
  static const String _charset =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  /// Encode BigInt to Base62 string
  static String encode(BigInt value) {
    if (value < BigInt.zero) {
      throw ArgumentError('Base62 encoding does not support negative numbers');
    }
    if (value == BigInt.zero) {
      return '0';
    }

    String result = '';
    BigInt base = BigInt.from(62);
    BigInt remainder;

    while (value > BigInt.zero) {
      remainder = value % base;
      value = value ~/ base;
      result = _charset[remainder.toInt()] + result;
    }

    return result;
  }
}

/// Generate timestamp or date prefixed ID in isolate
Future<TimeBasedIdGenerateResult> generateTimeBasedIds(
    TimeBasedIdGenerateRequest request) async {
  try {
    // Create new random number seed for Random
    final random = Random(DateTime.now().millisecondsSinceEpoch);

    // Initialize basic parameters
    final List<String> result = [];
    final List<BigInt> numericIds = [];

    // Set current state
    dynamic currentValue = request.startValue;
    int sequence = request.startSequence;
    dynamic workingValue = currentValue;

    // Create necessary constants and caches
    const int maxSequence = 99999; // Sequence number limit
    const int epochStartSeconds = 441763200; // Timestamp start point

    // Calculate nodeId digits
    int nodeIdDigits = 1;
    if (request.nodeConfig.nodeId > 0) {
      int temp = request.nodeConfig.nodeId;
      nodeIdDigits = 0;
      while (temp > 0) {
        temp ~/= 10;
        nodeIdDigits++;
      }
    }

    // Precompute commonly used BigInt values
    final sequenceFactor = BigInt.from(100000); // 10^5
    BigInt powerFactor;
    BigInt? nodeIdBig;

    if (request.nodeConfig.enableDistributed) {
      powerFactor = BigInt.from(10).pow(nodeIdDigits + 5);
      final nodeId =
          request.nodeConfig.nodeId > 0 ? request.nodeConfig.nodeId : 1;
      nodeIdBig = BigInt.from(nodeId);
    } else {
      powerFactor = sequenceFactor; // Use 10^5 in non-distributed mode
      nodeIdBig = BigInt.from(1);
    }

    final yieldController =
        YieldController("_IsolateBase62Encoder.generateTimeBasedIds");

    // Select different generation logic based on ID type
    if (request.keyType == PrimaryKeyType.timestampBased ||
        request.keyType == PrimaryKeyType.shortCode) {
      // Timestamp ID generation or short code ID generation

      // Efficient generation strategy: generate all IDs in order when sequence number space is sufficient
      if (request.isHighGeneration && sequence + request.count <= maxSequence) {
        // Efficient batch generation method
        for (int i = 0; i < request.count; i++) {
          await yieldController.maybeYield();
          sequence += 1;

          // Calculate timestamp ID
          final BigInt timestampBig = BigInt.from(workingValue);
          final BigInt sequenceBig = BigInt.from(sequence);

          BigInt idValue;
          if (request.nodeConfig.enableDistributed) {
            // Algorithm with node ID: timestamp * 10^(nodeIdDigits+5) + nodeId * 10^5 + sequence
            idValue = timestampBig * powerFactor +
                nodeIdBig * sequenceFactor +
                sequenceBig;
          } else {
            // Simplified algorithm: timestamp * 10^5 + sequence
            idValue = timestampBig * sequenceFactor + sequenceBig;
          }

          numericIds.add(idValue);
        }
      } else {
        // Regular generation method: consider step and sequence number limit
        int step = 1;
        if (!request.isHighGeneration) {
          // Calculate average step
          step = maxSequence ~/ max(request.count, 100);
        } else if (request.useNewTimestamp) {
          // If new timestamp is used, reset sequence number
          sequence = random.nextInt(1000) + 1;
        }

        // Generate ID
        for (int i = 0; i < request.count; i++) {
          await yieldController.maybeYield();
          // Increase sequence number
          sequence +=
              request.useRandomStep && step > 1 ? random.nextInt(step) + 1 : 1;

          // Check if sequence number exceeds limit
          if (sequence > maxSequence) {
            // Sequence number insufficient, wait for next timestamp
            workingValue = (DateTime.now().millisecondsSinceEpoch ~/ 1000) -
                epochStartSeconds;
            sequence = random.nextInt(1000) + 1;
          }

          // Calculate ID
          final BigInt timestampBig = BigInt.from(workingValue);
          final BigInt sequenceBig = BigInt.from(sequence);

          BigInt idValue;
          if (request.nodeConfig.enableDistributed) {
            // Algorithm with node ID
            idValue = timestampBig * powerFactor +
                nodeIdBig * sequenceFactor +
                sequenceBig;
          } else {
            // Simplified algorithm
            idValue = timestampBig * sequenceFactor + sequenceBig;
          }

          numericIds.add(idValue);
        }
      }
    } else if (request.keyType == PrimaryKeyType.datePrefixed) {
      // Date prefixed ID generation logic
      String dateString = workingValue as String;

      // Efficient generation strategy
      if (request.isHighGeneration && sequence + request.count <= maxSequence) {
        // Efficient batch generation method
        for (int i = 0; i < request.count; i++) {
          await yieldController.maybeYield();
          sequence += 1;

          // Calculate date prefixed ID
          BigInt dateValue;
          try {
            dateValue = BigInt.parse(dateString);
          } catch (e) {
            // Use timestamp as fallback
            dateValue = BigInt.from(
                (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 10000000000);
          }

          final BigInt sequenceBig = BigInt.from(sequence);
          BigInt idValue;

          if (request.nodeConfig.enableDistributed) {
            // Algorithm with node ID
            idValue = dateValue * powerFactor +
                nodeIdBig * sequenceFactor +
                sequenceBig;
          } else {
            // Simplified algorithm
            idValue = dateValue * sequenceFactor + sequenceBig;
          }

          numericIds.add(idValue);
        }
      } else {
        // Regular generation method
        int step = 1;
        if (!request.isHighGeneration) {
          // Calculate average step
          step = maxSequence ~/ max(request.count, 100);
        } else if (request.useNewTimestamp) {
          // If new date is used, reset sequence number
          sequence = random.nextInt(1000) + 1;
        }

        // Generate ID
        for (int i = 0; i < request.count; i++) {
          await yieldController.maybeYield();
          // Increase sequence number
          sequence +=
              request.useRandomStep && step > 1 ? random.nextInt(step) + 1 : 1;

          // Check if sequence number exceeds limit
          if (sequence > maxSequence) {
            // Sequence number insufficient, use current date
            final now = DateTime.now();
            dateString = '${now.year}'
                '${now.month.toString().padLeft(2, '0')}'
                '${now.day.toString().padLeft(2, '0')}'
                '${now.hour.toString().padLeft(2, '0')}'
                '${now.minute.toString().padLeft(2, '0')}'
                '${now.second.toString().padLeft(2, '0')}';
            sequence = random.nextInt(1000) + 1;
          }

          // Calculate ID
          BigInt dateValue;
          try {
            dateValue = BigInt.parse(dateString);
          } catch (e) {
            // Use timestamp as fallback
            dateValue = BigInt.from(
                (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 10000000000);
          }

          final BigInt sequenceBig = BigInt.from(sequence);
          BigInt idValue;

          if (request.nodeConfig.enableDistributed) {
            // Algorithm with node ID
            idValue = dateValue * powerFactor +
                nodeIdBig * sequenceFactor +
                sequenceBig;
          } else {
            // Simplified algorithm
            idValue = dateValue * sequenceFactor + sequenceBig;
          }

          numericIds.add(idValue);
        }
      }

      // Update current value
      currentValue = dateString;
    }

    // Format ID (based on ID type)
    if (request.keyType == PrimaryKeyType.shortCode) {
      // Short code ID needs Base62 encoding
      for (final numericId in numericIds) {
        result.add(_IsolateBase62Encoder.encode(numericId));
      }
    } else {
      // Timestamp ID and date prefixed ID directly converted to string
      for (final numericId in numericIds) {
        result.add(numericId.toString());
      }
    }

    // Return generation result
    return TimeBasedIdGenerateResult(
      ids: result,
      lastValue: currentValue,
      lastSequence: sequence,
      success: true,
    );
  } catch (e) {
    // Record error and return empty result
    return TimeBasedIdGenerateResult(
      ids: [],
      lastValue: request.startValue,
      lastSequence: request.startSequence,
      success: false,
      errorMessage: 'ID generation failed: $e',
    );
  }
}

/// Request data for building a B+ tree from multiple partition contents.
class BuildTreeRequest {
  final List<String> partitionsContent;
  final bool isUnique;
  final MatcherType matcherType;

  BuildTreeRequest(
      {required this.partitionsContent,
      required this.isUnique,
      required this.matcherType});
}

/// Request for searching an index partition.
class SearchTaskRequest {
  final String content;
  final dynamic key;
  final bool isUnique;
  final MatcherType matcherType;

  SearchTaskRequest(
      {required this.content,
      required this.key,
      required this.isUnique,
      required this.matcherType});
}

/// Request for batch searching an index partition.
class BatchSearchTaskRequest {
  final String content;
  final List<dynamic> keys;
  final bool isUnique;
  final MatcherType matcherType;

  BatchSearchTaskRequest(
      {required this.content,
      required this.keys,
      required this.isUnique,
      required this.matcherType});
}

/// Result from batch searching an index partition.
class BatchSearchTaskResult {
  final Map<dynamic, List<dynamic>> found;
  BatchSearchTaskResult({required this.found});
}

/// Request: find index keys for a batch of record pointers by scanning partition contents.
class FindKeysByPointersRequest {
  /// Serialized B+Tree contents of all partitions for an index
  final List<String> partitionContents;

  /// Target record pointer strings to search for (StoreIndex.toString())
  final List<String> pointerStrings;

  FindKeysByPointersRequest({
    required this.partitionContents,
    required this.pointerStrings,
  });
}

/// Request for batch WAL encoding
class BatchWalEncodeRequest {
  /// List of raw WAL entries
  final List<Map<String, dynamic>> entries;

  /// Encoder state configuration
  final EncoderConfig encoderConfig;

  BatchWalEncodeRequest({
    required this.entries,
    required this.encoderConfig,
  });
}

/// Result of batch WAL encoding
class BatchWalEncodeResult {
  /// Encoded binary data chunks corresponding to input entries
  final List<Uint8List> encodedChunks;

  BatchWalEncodeResult(this.encodedChunks);
}

/// Batch encode WAL entries
Future<BatchWalEncodeResult> batchEncodeWal(
    BatchWalEncodeRequest request) async {
  // 1. Sync encoder state
  EncoderHandler.setEncodingState(request.encoderConfig);

  final results = <Uint8List>[];
  final yieldController =
      YieldController('ComputeTasks.batchEncodeWal', checkInterval: 100);

  // 2. Encode each entry
  for (final entry in request.entries) {
    await yieldController.maybeYield();
    // WalEncoder.encodeAsLine checks partition 'p' inside the entry
    final encoded = WalEncoder.encodeAsLine(entry);
    results.add(encoded);
  }

  return BatchWalEncodeResult(results);
}

/// One B+Tree page encode unit for isolate/off-main-thread execution.
///
/// NOTE:
/// - This object must remain isolate-sendable (only primitives + typed data).
/// - Do NOT use `TransferableTypedData` here to keep web / non-isolate platforms compatible.
final class BTreePageEncodeItem {
  /// `BTreePageType.index`
  final int typeIndex;
  final int partitionNo;
  final int pageNo;

  /// Plaintext payload bytes (NOT encrypted).
  final Uint8List payload;

  const BTreePageEncodeItem({
    required this.typeIndex,
    required this.partitionNo,
    required this.pageNo,
    required this.payload,
  });
}

/// Batch request for encoding multiple B+Tree pages.
final class BatchBTreePageEncodeRequest {
  final int pageSize;

  /// Null means: DataStoreConfig.encryptionConfig == null → do NOT wrap with EncoderHandler header.
  final int? encryptionTypeIndex;

  /// Full encoder state so isolates can use the same active key / keyId.
  final EncoderConfig encoderConfig;

  /// Optional per-call key override (mirrors `BTreePageCodec.encodePayload`).
  final Uint8List? customKey;
  final int? customKeyId;

  final List<BTreePageEncodeItem> pages;

  const BatchBTreePageEncodeRequest({
    required this.pageSize,
    required this.encryptionTypeIndex,
    required this.encoderConfig,
    required this.pages,
    this.customKey,
    this.customKeyId,
  });
}

/// Batch encode result (aligned with request order).
final class BatchBTreePageEncodeResult {
  final List<Uint8List> pageBytes;
  const BatchBTreePageEncodeResult(this.pageBytes);
}

/// Batch encode B+Tree pages to fixed-size page bytes.
///
/// Heavy CPU work:
/// - (optional) encryption + header wrapping
/// - CRC32 over encoded payload
/// - fixed-size page assembly
///
/// Can run on:
/// - isolate (native) via `ComputeManager.run`
/// - main isolate (web / no-isolate platforms) via stub compute
Future<BatchBTreePageEncodeResult> batchEncodeBTreePages(
    BatchBTreePageEncodeRequest request) async {
  final int pageSize = request.pageSize;
  if (pageSize <= 0) return const BatchBTreePageEncodeResult(<Uint8List>[]);

  final pages = request.pages;
  if (pages.isEmpty) return const BatchBTreePageEncodeResult(<Uint8List>[]);

  // Ensure isolate has the same encoder state as main isolate.
  EncoderHandler.setEncodingState(request.encoderConfig);

  final int? encTypeIndex = request.encryptionTypeIndex;
  final EncryptionType? encType = encTypeIndex == null
      ? null
      : EncryptionTypeExtension.fromInt(encTypeIndex);

  Uint8List aadBytes(int partitionNo, int pageNo, int typeIndex) {
    final bd = ByteData(9);
    bd.setInt32(0, partitionNo, Endian.little);
    bd.setInt32(4, pageNo, Endian.little);
    bd.setUint8(8, typeIndex);
    return bd.buffer.asUint8List();
  }

  final out =
      List<Uint8List>.filled(pages.length, Uint8List(0), growable: false);

  // Yielding is important when running on platforms without isolates (web).
  final yieldController = YieldController(
    'ComputeTasks.batchEncodeBTreePages',
    checkInterval: 200,
  );

  for (int i = 0; i < pages.length; i++) {
    await yieldController.maybeYield();
    final p = pages[i];

    final Uint8List encodedPayload;
    if (encType == null) {
      // No encryption config: keep payload as-is (no header).
      encodedPayload = p.payload;
    } else {
      encodedPayload = EncoderHandler.encodeBytes(
        p.payload,
        customKey: request.customKey,
        keyId: request.customKeyId,
        encryptionType: encType,
        aad: aadBytes(p.partitionNo, p.pageNo, p.typeIndex),
      );
    }

    final pageBytes = BTreePageIO.buildPageBytes(
      type: BTreePageType.values[p.typeIndex],
      encodedPayload: encodedPayload,
      pageSize: pageSize,
    );

    out[i] = pageBytes;
  }

  return BatchBTreePageEncodeResult(out);
}
