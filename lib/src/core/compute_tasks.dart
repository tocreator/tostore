import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../handler/encryption.dart';
import '../handler/logger.dart';
import '../handler/value_matcher.dart';
import '../handler/wal_encoder.dart';
import '../model/buffer_entry.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/encoder_config.dart';
import '../model/migration_task.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../model/wal_pointer.dart';
import 'btree_page.dart';
import 'page_redo_log_codec.dart';
import 'yield_controller.dart';

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
    final y1 = yieldController.maybeYield();
    if (y1 != null) await y1;
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
    final y2 = yieldController.maybeYield();
    if (y2 != null) await y2;
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

  /// Target schema version
  final String targetSchemaVersion;

  MigrationRecordProcessRequest({
    required this.records,
    required this.operations,
    this.oldSchema,
    this.yieldDurationMs,
    required this.targetSchemaVersion,
  });
}

/// Table record migration processing result
class MigrationRecordProcessResult {
  /// Processed records wrapped in BufferEntries for immediate queuing
  final List<BufferEntry> migratedEntries;

  /// Processing result status
  final bool success;

  /// Error message (if any)
  final String? errorMessage;

  MigrationRecordProcessResult({
    required this.migratedEntries,
    this.success = true,
    this.errorMessage,
  });
}

/// Apply forward migration operations to a single record synchronously.
///
/// This is used both for background batch migration and for runtime
/// record normalization during the online migration period.
Map<String, dynamic> applyMigrationOperationsSync(
  Map<String, dynamic> record,
  List<MigrationOperation> operations,
  TableSchema? oldSchema,
) {
  for (final operation in operations) {
    switch (operation.type) {
      case MigrationType.addField:
        final field = operation.field;
        if (field != null && !record.containsKey(field.name)) {
          record[field.name] = field.getDefaultValue();
        }
        break;
      case MigrationType.removeField:
        final name = operation.fieldName;
        if (name != null) {
          record.remove(name);
        }
        break;
      case MigrationType.renameField:
        final oldName = operation.fieldName;
        final newName = operation.newName;
        if (oldName != null &&
            newName != null &&
            record.containsKey(oldName) &&
            !record.containsKey(newName)) {
          record[newName] = record[oldName];
          record.remove(oldName);
        }
        break;
      case MigrationType.modifyField:
        final update = operation.fieldUpdate;
        if (update != null && record.containsKey(update.name)) {
          FieldSchema? oldField;
          if (oldSchema != null) {
            try {
              oldField =
                  oldSchema.fields.firstWhere((f) => f.name == update.name);
            } catch (_) {
              oldField = null;
            }
          }
          applyFieldModification(
            record,
            update,
            oldFieldSchema: oldField,
            tableName: oldSchema?.name ?? '',
          );
        }
        break;
      case MigrationType.setPrimaryKeyConfig:
        final oldPk = operation.oldPrimaryKeyConfig;
        final newPk = operation.primaryKeyConfig;
        if (oldPk != null &&
            newPk != null &&
            oldPk.name != newPk.name &&
            record.containsKey(oldPk.name) &&
            !record.containsKey(newPk.name)) {
          record[newPk.name] = record[oldPk.name];
          record.remove(oldPk.name);
        }
        break;
      case MigrationType.promoteFieldToPrimaryKey:
        // Handled by transformPromoteOldToNewInPlace (dual-write / backfill);
        // no in-place rewrite on the old working table.
        break;
      default:
        // Other operations (indexes, renameTable, TTL, etc.) do not affect record payload directly
        break;
    }
  }
  return record;
}

/// Apply reverse migration operations to a single record synchronously.
///
/// This is used to "downgrade" a record written in new logical format back
/// to the legacy format, typically when writing to a storage space that
/// has not been physically migrated yet.
Map<String, dynamic> applyMigrationReverseOperationsSync(
  Map<String, dynamic> record,
  List<MigrationOperation> operations,
  TableSchema oldSchema,
) {
  final oldFieldByName = <String, FieldSchema>{
    for (final field in oldSchema.fields) field.name: field,
  };

  // Process operations in REVERSE order to unwind changes correctly.
  for (int i = operations.length - 1; i >= 0; i--) {
    final operation = operations[i];
    switch (operation.type) {
      case MigrationType.addField:
        final added = operation.field?.name;
        if (added != null) {
          record.remove(added);
        }
        break;
      case MigrationType.removeField:
        final removed = operation.fieldName;
        if (removed == null || record.containsKey(removed)) {
          break;
        }
        final oldField = oldFieldByName[removed];
        record[removed] = oldField?.getDefaultValue();
        break;
      case MigrationType.renameField:
        final oldName = operation.fieldName;
        final newName = operation.newName;
        if (oldName != null &&
            newName != null &&
            record.containsKey(newName) &&
            !record.containsKey(oldName)) {
          record[oldName] = record[newName];
          record.remove(newName);
        }
        break;
      case MigrationType.modifyField:
        final update = operation.fieldUpdate;
        if (update != null && record.containsKey(update.name)) {
          final oldField = oldFieldByName[update.name];
          if (oldField != null) {
            _revertFieldModificationSync(
                record, update.name, oldField, oldSchema.name);
          }
        }
        break;
      case MigrationType.setPrimaryKeyConfig:
        final oldPk = operation.oldPrimaryKeyConfig;
        final newPk = operation.primaryKeyConfig;
        if (oldPk != null &&
            newPk != null &&
            oldPk.name != newPk.name &&
            record.containsKey(newPk.name) &&
            !record.containsKey(oldPk.name)) {
          record[oldPk.name] = record[newPk.name];
          record.remove(newPk.name);
        }
        break;
      default:
        break;
    }
  }
  return record;
}

void _revertFieldModificationSync(
  Map<String, dynamic> record,
  String fieldName,
  FieldSchema oldField,
  String tableName,
) {
  if (!record.containsKey(fieldName)) return;

  dynamic value = record[fieldName];
  try {
    value = oldField.convertValue(value);
  } catch (_) {
    value = oldField.getDefaultValue();
  }

  if (!oldField.nullable && value == null) {
    value = oldField.getDefaultValue();
  }

  // Basic constraint recovery
  if (value is String) {
    if (oldField.maxLength != null && value.length > oldField.maxLength!) {
      value = value.substring(0, oldField.maxLength!);
    }
  } else if (value is num) {
    if (oldField.minValue != null && value < oldField.minValue!) {
      value = oldField.minValue;
    } else if (oldField.maxValue != null && value > oldField.maxValue!) {
      value = oldField.maxValue;
    }
  }

  if (!oldField.validateValue(value, tableName: tableName)) {
    value = oldField.getDefaultValue();
  }

  record[fieldName] = value;
}

/// Process record migration
Future<MigrationRecordProcessResult> processMigrationRecords(
    MigrationRecordProcessRequest request) async {
  try {
    if (request.records.isEmpty) {
      return MigrationRecordProcessResult(
        migratedEntries: [],
        success: true,
      );
    }

    final yieldController = YieldController('ProcessMigrationRecords',
        budgetMs: request.yieldDurationMs);

    final migratedEntries = <BufferEntry>[];
    final timestamp = DateTime.now();

    for (final record in request.records) {
      final y3 = yieldController.maybeYield();
      if (y3 != null) await y3;

      final transformed = applyMigrationOperationsSync(
        Map<String, dynamic>.from(record),
        request.operations,
        request.oldSchema,
      );

      migratedEntries.add(BufferEntry(
        operation: BufferOperationType.update,
        data: transformed,
        timestamp: timestamp,
        walPointer: const WalPointer(partitionIndex: -1, entrySeq: 0),
        schemaVersion: request.targetSchemaVersion,
      ));
    }

    return MigrationRecordProcessResult(
      migratedEntries: migratedEntries,
      success: true,
    );
  } catch (e) {
    Logger.error('Failed to process migration records', rawError: e);
    return MigrationRecordProcessResult(
      migratedEntries: [],
      success: false,
      errorMessage: e.toString(),
    );
  }
}

/// Apply field modification to a single record.
///
/// Constraint/type adjustments are applied silently on the hot path — logging
/// every row can freeze the UI on large tables. Callers that need a notice
/// should emit a single summary warn before bulk rewrite.
Map<String, dynamic> applyFieldModification(
    Map<String, dynamic> record, FieldSchemaUpdate fieldUpdate,
    {FieldSchema? oldFieldSchema, String tableName = ''}) {
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
    } catch (_) {
      record[fieldUpdate.name] = fieldSchema.getDefaultValue();
    }
  }

  // 2. Process null constraint changes
  if (fieldUpdate.nullable != null &&
      !fieldUpdate.nullable! &&
      record[fieldUpdate.name] == null) {
    record[fieldUpdate.name] = fieldSchema.getDefaultValue();
  }

  // 3. Process default value changes
  if (fieldUpdate.isExplicitlySet('defaultValue') &&
      record[fieldUpdate.name] == null) {
    record[fieldUpdate.name] = fieldUpdate.defaultValue;
  }

  // 4. Process length constraint changes
  if ((fieldUpdate.isExplicitlySet('maxLength') ||
          fieldUpdate.isExplicitlySet('minLength')) &&
      record[fieldUpdate.name] is String) {
    String value = record[fieldUpdate.name];
    if (fieldUpdate.isExplicitlySet('maxLength') &&
        fieldUpdate.maxLength != null &&
        value.length > fieldUpdate.maxLength!) {
      record[fieldUpdate.name] = value.substring(0, fieldUpdate.maxLength!);
    }
    if (fieldUpdate.isExplicitlySet('minLength') &&
        fieldUpdate.minLength != null &&
        value.length < fieldUpdate.minLength!) {
      record[fieldUpdate.name] = fieldSchema.getDefaultValue();
    }
  }

  // 5. Process value range constraint changes
  if ((fieldUpdate.isExplicitlySet('minValue') ||
          fieldUpdate.isExplicitlySet('maxValue')) &&
      record[fieldUpdate.name] is num) {
    num value = record[fieldUpdate.name];

    if (fieldUpdate.isExplicitlySet('minValue') &&
        fieldUpdate.minValue != null &&
        value < fieldUpdate.minValue!) {
      record[fieldUpdate.name] = fieldUpdate.minValue;
    }

    if (fieldUpdate.isExplicitlySet('maxValue') &&
        fieldUpdate.maxValue != null &&
        value > fieldUpdate.maxValue!) {
      record[fieldUpdate.name] = fieldUpdate.maxValue;
    }
  }

  // 6. Final validation
  final validationErr = fieldSchema.getValidationError(
    record[fieldUpdate.name],
    tableName: tableName,
  );
  if (validationErr != null) {
    record[fieldUpdate.name] = fieldSchema.getDefaultValue();
  }

  return record;
}

/// Time-based ID generation request (for isolate)
class TimeBasedIdGenerateRequest {
  /// ID type
  final PrimaryKeyType keyType;

  /// Node configuration
  final DistributedNodeConfig nodeConfig;

  /// Table unique identifier
  final TableUid tableUid;

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
    required this.tableUid,
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
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'Base62 encoding does not support negative numbers',
          parameterName: 'value',
          passedValue: value.toString(),
        )
      ]);
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
    // Create necessary constants and caches
    const int maxSequence = 99999; // Sequence number limit
    const int epochStartSeconds = 441763200; // Timestamp start point

    Future<int> waitNextTimestamp(int lastTimestamp) async {
      await Future.delayed(const Duration(milliseconds: 1));
      int timestamp =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) - epochStartSeconds;

      if (timestamp > lastTimestamp) {
        return timestamp;
      }

      int attempts = 1;
      int delayMs = 1;
      while (timestamp <= lastTimestamp && attempts < 200) {
        attempts++;
        delayMs = min(delayMs + 1, 50);
        await Future.delayed(Duration(milliseconds: delayMs));
        timestamp =
            (DateTime.now().millisecondsSinceEpoch ~/ 1000) - epochStartSeconds;
      }

      return timestamp > lastTimestamp ? timestamp : lastTimestamp + 1;
    }

    Future<String> waitNextSecond(String lastDate) async {
      await Future.delayed(const Duration(milliseconds: 1));

      String buildNowDateString() {
        final now = DateTime.now();
        return '${now.year}'
            '${now.month.toString().padLeft(2, '0')}'
            '${now.day.toString().padLeft(2, '0')}'
            '${now.hour.toString().padLeft(2, '0')}'
            '${now.minute.toString().padLeft(2, '0')}'
            '${now.second.toString().padLeft(2, '0')}';
      }

      String dateString = buildNowDateString();
      if (dateString.compareTo(lastDate) > 0) {
        return dateString;
      }

      int attempts = 1;
      int delayMs = 1;
      while (dateString.compareTo(lastDate) <= 0 && attempts < 200) {
        attempts++;
        delayMs = min(delayMs + 1, 50);
        await Future.delayed(Duration(milliseconds: delayMs));
        dateString = buildNowDateString();
      }

      if (dateString.compareTo(lastDate) > 0) {
        return dateString;
      }

      try {
        final fmt =
            '${lastDate.substring(0, 8)}T${lastDate.substring(8, 10)}:${lastDate.substring(10, 12)}:${lastDate.substring(12, 14)}';
        final dt = DateTime.parse(fmt).add(const Duration(seconds: 1));
        return '${dt.year}'
            '${dt.month.toString().padLeft(2, '0')}'
            '${dt.day.toString().padLeft(2, '0')}'
            '${dt.hour.toString().padLeft(2, '0')}'
            '${dt.minute.toString().padLeft(2, '0')}'
            '${dt.second.toString().padLeft(2, '0')}';
      } catch (_) {
        return buildNowDateString();
      }
    }

    // Create new random number seed for Random
    final random = Random(DateTime.now().millisecondsSinceEpoch);

    // Initialize basic parameters
    final List<String> result = [];
    final List<BigInt> numericIds = [];

    // Set current state
    dynamic currentValue = request.startValue;
    int sequence = request.startSequence;
    dynamic workingValue = currentValue;

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
          final y4 = yieldController.maybeYield();
          if (y4 != null) await y4;
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
          final y5 = yieldController.maybeYield();
          if (y5 != null) await y5;
          // Increase sequence number
          sequence +=
              request.useRandomStep && step > 1 ? random.nextInt(step) + 1 : 1;

          // Check if sequence number exceeds limit
          if (sequence > maxSequence) {
            // Sequence number insufficient, move to a strictly newer timestamp.
            workingValue = await waitNextTimestamp(workingValue as int);
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
      currentValue = workingValue;
    } else if (request.keyType == PrimaryKeyType.datePrefixed) {
      // Date prefixed ID generation logic
      String dateString = workingValue as String;

      // Efficient generation strategy
      if (request.isHighGeneration && sequence + request.count <= maxSequence) {
        // Efficient batch generation method
        for (int i = 0; i < request.count; i++) {
          final y6 = yieldController.maybeYield();
          if (y6 != null) await y6;
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
          final y7 = yieldController.maybeYield();
          if (y7 != null) await y7;
          // Increase sequence number
          sequence +=
              request.useRandomStep && step > 1 ? random.nextInt(step) + 1 : 1;

          // Check if sequence number exceeds limit
          if (sequence > maxSequence) {
            // Sequence number insufficient, move to a strictly newer second.
            dateString = await waitNextSecond(dateString);
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
  EncryptionManager.setEncodingState(request.encoderConfig);

  final results = <Uint8List>[];
  final yieldController =
      YieldController('ComputeTasks.batchEncodeWal', checkInterval: 100);

  // 2. Encode each entry
  for (final entry in request.entries) {
    final y8 = yieldController.maybeYield();
    if (y8 != null) await y8;
    // WalEncoder.encodeAsLine checks partition 'p' inside the entry
    final encoded = WalEncoder.encodeAsLine(entry);
    results.add(encoded);
  }

  return BatchWalEncodeResult(results);
}

/// One B+Tree page encode unit for isolate/off-main-thread execution.
///
/// NOTE:
/// - This object must remain isolate-sendable (primitives, typed data, and
///   B+Tree page DTOs composed from those values).
/// - Do NOT use `TransferableTypedData` here to keep web / non-isolate platforms compatible.
final class BTreePageEncodeItem {
  /// Index into [BTreePageType.values].
  final int typeIndex;
  final int partitionNo;
  final int pageNo;

  /// Plaintext payload bytes (NOT encrypted), when the caller already encoded it.
  final Uint8List? payload;

  /// Optional raw page objects. When present, payload encoding is also done by
  /// the compute worker so large dirty-page batches do less work on the caller.
  final LeafPage? leafPage;
  final InternalPage? internalPage;

  const BTreePageEncodeItem({
    required this.typeIndex,
    required this.partitionNo,
    required this.pageNo,
    required this.payload,
  })  : leafPage = null,
        internalPage = null;

  BTreePageEncodeItem.leaf({
    required this.partitionNo,
    required this.pageNo,
    required LeafPage page,
  })  : typeIndex = BTreePageType.leaf.index,
        payload = null,
        leafPage = page,
        internalPage = null;

  BTreePageEncodeItem.internal({
    required this.partitionNo,
    required this.pageNo,
    required InternalPage page,
  })  : typeIndex = BTreePageType.internal.index,
        payload = null,
        leafPage = null,
        internalPage = page;
}

/// Batch request for encoding multiple B+Tree pages.
final class BatchBTreePageEncodeRequest {
  final int pageSize;

  /// Null means: DataStoreConfig.encryptionConfig == null -> do NOT wrap with EncoderHandler header.
  final int? encryptionTypeIndex;

  /// Full encoder state so isolates can use the same active key / keyId.
  final EncoderConfig encoderConfig;

  /// Optional per-call key override (mirrors `BTreePageCodec.encodePayload`).
  final Uint8List? customKey;
  final int? customKeyId;

  final List<BTreePageEncodeItem> pages;

  /// When non-null, isolate also builds page redo log bytes to avoid main-thread encode.
  ///
  /// Note:
  /// - Redo records store logical identity (table/index + partitionNo + pageNo), not absolute paths,
  ///   so recovery can rebuild paths even if directory layout changes across restart.
  final int? pageRedoTreeKindIndex; // PageRedoTreeKind.indexTree
  final TableUid? pageRedoTableUid;
  final IndexUid? pageRedoIndexUid; // required when treeKind == index

  const BatchBTreePageEncodeRequest({
    required this.pageSize,
    required this.encryptionTypeIndex,
    required this.encoderConfig,
    required this.pages,
    this.customKey,
    this.customKeyId,
    this.pageRedoTreeKindIndex,
    this.pageRedoTableUid,
    this.pageRedoIndexUid,
  });
}

/// Batch encode result (aligned with request order).
final class BatchBTreePageEncodeResult {
  final List<Uint8List> pageBytes;

  /// Present when request had [pageRedoTreeKindIndex] and [pageRedoTableUid]; encoded in isolate.
  final Uint8List? pageRedoBytes;

  const BatchBTreePageEncodeResult(this.pageBytes, [this.pageRedoBytes]);
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
  EncryptionManager.setEncodingState(request.encoderConfig);

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
    final y9 = yieldController.maybeYield();
    if (y9 != null) await y9;
    final p = pages[i];
    if (p.typeIndex < 0 || p.typeIndex >= BTreePageType.values.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Invalid BTree page type index: ${p.typeIndex}',
        )
      ]);
    }
    final pageType = BTreePageType.values[p.typeIndex];
    final plainPayload = _resolveBTreePagePayload(p, pageType);

    final Uint8List encodedPayload;
    if (encType == null) {
      // No encryption config: keep payload as-is (no header).
      encodedPayload = plainPayload;
    } else {
      encodedPayload = EncryptionManager.encodeBytes(
        plainPayload,
        customKey: request.customKey,
        keyId: request.customKeyId,
        encryptionType: encType,
        aad: aadBytes(p.partitionNo, p.pageNo, p.typeIndex),
      );
    }

    // Extra guardrail: provide full context if caller's sizing/splitting is wrong.
    final int totalLen = BTreePageHeader.size + encodedPayload.length;
    if (totalLen > pageSize) {
      final int keyId =
          request.customKeyId ?? EncryptionManager.getCurrentKeyId();
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'BTree page overflow (pre-build): total=$totalLen > pageSize=$pageSize '
              '(header=${BTreePageHeader.size}, encodedPayload=${encodedPayload.length}, '
              'plainPayload=${plainPayload.length}, typeIndex=${p.typeIndex}, '
              'partitionNo=${p.partitionNo}, pageNo=${p.pageNo}, '
              'encryptionTypeIndex=${request.encryptionTypeIndex}, keyId=$keyId).',
        )
      ]);
    }

    final pageBytes = BTreePageIO.buildPageBytes(
      type: pageType,
      encodedPayload: encodedPayload,
      pageSize: pageSize,
    );

    out[i] = pageBytes;
  }

  Uint8List? pageRedoBytes;
  final kindIdx = request.pageRedoTreeKindIndex;
  final tableUid = request.pageRedoTableUid;
  if (kindIdx != null &&
      tableUid != null &&
      kindIdx >= 0 &&
      kindIdx < PageRedoTreeKind.values.length) {
    final treeKind = PageRedoTreeKind.values[kindIdx];
    final indexUid = request.pageRedoIndexUid;
    final records = <Uint8List>[];
    for (int i = 0; i < out.length; i++) {
      final p = pages[i];
      records.add(PageRedoLogCodec.encodePageRecord(
        treeKind: treeKind,
        tableUid: tableUid,
        indexUid: (treeKind == PageRedoTreeKind.indexTree ||
                treeKind == PageRedoTreeKind.ngh)
            ? indexUid
            : null,
        partitionNo: p.partitionNo,
        pageNo: p.pageNo,
        payload: out[i],
      ));
    }
    final total = records.fold<int>(0, (s, r) => s + r.length);
    final combined = Uint8List(total);
    int pos = 0;
    for (final r in records) {
      combined.setRange(pos, pos + r.length, r);
      pos += r.length;
    }
    pageRedoBytes = combined;
  }

  return BatchBTreePageEncodeResult(out, pageRedoBytes);
}

Uint8List _resolveBTreePagePayload(
  BTreePageEncodeItem item,
  BTreePageType pageType,
) {
  final payload = item.payload;
  if (payload != null) return payload;

  switch (pageType) {
    case BTreePageType.leaf:
      final page = item.leafPage;
      if (page == null) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'Leaf page encode item is missing leafPage',
          )
        ]);
      }
      return page.encodePayload();
    case BTreePageType.internal:
      final page = item.internalPage;
      if (page == null) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'Internal page encode item is missing internalPage',
          )
        ]);
      }
      return page.encodePayload();
    case BTreePageType.meta:
    case BTreePageType.free:
    case BTreePageType.overflow:
    case BTreePageType.nghMeta:
    case BTreePageType.nghPosting:
    case BTreePageType.nghNavGraph:
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'BTree page encode item for $pageType requires a prebuilt payload',
        )
      ]);
  }
}

// ============================================================================
