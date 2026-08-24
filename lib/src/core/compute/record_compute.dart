import '../../handler/logger.dart';
import '../../model/db_exception.dart';
import '../../model/expr.dart';
import '../../model/result_status.dart';
import '../../model/result_type.dart';
import '../../model/table_identity.dart';
import '../../model/table_schema.dart';

/// Pure record validation + conversion path that is safe to run in an isolate.
///
/// Notes:
/// - No file I/O, locks, WAL, transactions, or cache lookups.
/// - Callers must resolve auto-generated primary keys before invoking this helper,
///   or pass them through [resolvedPrimaryKey].
Map<String, dynamic>? validateAndProcessRecordPure({
  required TableSchema schema,
  required Map<String, dynamic> data,
  required TableName tableName,
  bool skipPrimaryKeyFormatCheck = false,
  List<String>? validationErrors,
  Map<String, FieldSchema>? fieldMap,
  bool hasResolvedPrimaryKey = false,
  Object? resolvedPrimaryKey,
  bool ignoreUnknownFields = true,

  /// Shared batch timestamp for [DefaultValueType.currentTimestamp] defaults.
  /// Avoids Nx DateTime.now() in large batchInsert prepares.
  DateTime? batchTimestamp,

  /// When non-null, skips the per-record length/range constraint scan.
  /// Pass the chunk-level result from the caller for batchInsert prepare.
  bool? schemaNeedsConstraintPass,

  /// When true, mutate [data] in place instead of allocating a result map.
  /// Safe when the caller owns the record map (batchInsert hot path).
  bool mutateInPlace = false,
}) {
  try {
    final primaryKey = schema.primaryKey;
    final fields = schema.fields;
    final fieldMapLocal = fieldMap ?? {for (final f in fields) f.name: f};

    if (!ignoreUnknownFields) {
      for (final key in data.keys) {
        if (key != primaryKey && !fieldMapLocal.containsKey(key)) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devFieldNotFound,
              message: 'Unknown field $key in table $tableName',
              parameterName: key,
              passedValue: data[key],
            )
          ]);
        }
      }
    }

    // Most app schemas only use nullable + type conversion. Skip the second
    // validateData pass when no length/range constraints are configured.
    final bool needsConstraintPass;
    if (schemaNeedsConstraintPass != null) {
      needsConstraintPass = schemaNeedsConstraintPass;
    } else {
      var needs = false;
      for (final field in fields) {
        if (field.maxLength != null ||
            field.minLength != null ||
            field.minValue != null ||
            field.maxValue != null) {
          needs = true;
          break;
        }
      }
      needsConstraintPass = needs;
    }

    final result = mutateInPlace ? data : <String, dynamic>{};
    final errors = validationErrors;

    // 1. Primary key handling.
    if (!data.containsKey(primaryKey) || data[primaryKey] == null) {
      if (hasResolvedPrimaryKey) {
        result[primaryKey] = resolvedPrimaryKey;
      } else {
        throw DbException([
          ConstraintStatus(
            type: ResultType.bizNotNullViolation,
            message: 'Primary key value cannot be null (table $tableName)',
            tableName: tableName,
            fields: [primaryKey],
          )
        ]);
      }
    } else {
      final providedId = data[primaryKey];

      if (providedId != null &&
          !skipPrimaryKeyFormatCheck &&
          !schema.validatePrimaryKeyFormat(providedId)) {
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidPrimaryKeyFormat,
            message:
                'The provided primary key value $providedId for table $tableName does not meet the format requirements for type ${schema.primaryKeyConfig.type}',
            parameterName: primaryKey,
            passedValue: providedId,
          )
        ]);
      }

      // Auto-generated PKs are already strings from the ID pool -- avoid
      // convertPrimaryKey overhead on the batchInsert hot path.
      if (!(skipPrimaryKeyFormatCheck && providedId is String)) {
        result[primaryKey] = schema.primaryKeyConfig
            .convertPrimaryKey(providedId, tableName: tableName);
      } else if (!mutateInPlace) {
        result[primaryKey] = providedId;
      }
    }

    // Lazily materialize shared timestamp strings/ints once per record batch.
    String? sharedNowIso;
    int? sharedNowMs;
    String resolveNowIso() =>
        sharedNowIso ??= (batchTimestamp ?? DateTime.now()).toIso8601String();
    int resolveNowMs() => sharedNowMs ??=
        (batchTimestamp ?? DateTime.now()).millisecondsSinceEpoch;

    // 2. Defaults, expressions, type conversion, and not-null in one pass.
    for (final field in fields) {
      if (field.name == primaryKey) continue;

      final raw = data[field.name];
      dynamic value = raw;
      if (raw is ExprNode) {
        if (raw is TimestampExpr) {
          value = resolveNowIso();
        } else if (raw is Constant) {
          value = raw.value;
        } else if (raw is FieldRef) {
          value = 0;
        } else {
          final emptyRecord = <String, dynamic>{};
          try {
            value = evaluateExpressionForRecord(raw, emptyRecord, schema);
          } catch (e) {
            Logger.warn(
                'Failed to evaluate expression for insert on field ${field.name}. Using 0 as default.',
                rawError: e);
            value = 0;
          }
        }
      } else if (value == null &&
          field.defaultValueType == DefaultValueType.currentTimestamp) {
        if (field.type == DataType.integer) {
          value = resolveNowMs();
        } else if (field.type == DataType.bigInt) {
          value = BigInt.from(resolveNowMs());
        } else {
          value = resolveNowIso();
        }
      } else if (value == null && field.defaultValue != null) {
        value = field.getDefaultValue();
      }

      final converted = field.convertValue(value);
      if (mutateInPlace) {
        // Typed app records usually already match storage form -- skip map write only if raw was identical.
        if (!identical(converted, raw) ||
            (converted != null && !data.containsKey(field.name))) {
          data[field.name] = converted;
        }
      } else {
        result[field.name] = converted;
      }

      if (converted == null && !field.nullable) {
        final msg =
            'Field ${field.name} is required and cannot be null (table $tableName)';
        if (errors != null) {
          errors.add(msg);
          return null;
        }
        throw DbException([
          ConstraintStatus(
            type: ResultType.bizNotNullViolation,
            message: msg,
            tableName: tableName,
            fields: [field.name],
          )
        ]);
      }
    }

    if (!needsConstraintPass) {
      return result;
    }

    // 3. Full constraint pass only when schema declares length/range limits.
    final validatedResult = schema.validateData(
      result,
      applyConstraints: true,
      errors: validationErrors,
      trustedConvertedValues: true,
      fieldMap: fieldMapLocal,
      ignoreUnknownFields: ignoreUnknownFields,
      mutateInPlace: true,
    );
    if (validatedResult == null) {
      Logger.debug(
        'Data validation failed for table $tableName',
      );
      return null;
    }

    return validatedResult;
  } on DbException {
    rethrow;
  } catch (e) {
    Logger.error('Data validation failed', rawError: e);
    if (validationErrors != null) {
      validationErrors.add(e.toString());
    }
    return null;
  }
}

/// Validate whether a record contains enough information to identify itself.
///
/// Mirrors the mature main-thread identifier checks used by upsert/update
/// flows, but keeps the logic isolate-safe.
String? validateRecordIdentifierPure({
  required TableSchema schema,
  required Map<String, dynamic> data,
  required List<IndexSchema> uniqueIndexes,
  bool checkRequiredFields = false,
}) {
  final pk = schema.primaryKey;
  if (checkRequiredFields) {
    for (final field in schema.fields) {
      if (field.name == pk) continue;
      if (!field.nullable &&
          (!data.containsKey(field.name) || data[field.name] == null)) {
        return 'Field ${field.name} is required (nullable=false) for this operation';
      }
    }
  }

  final hasPk = data.containsKey(pk) && data[pk] != null;
  if (hasPk) return null;

  if (uniqueIndexes.isEmpty) {
    return 'Record has no primary key and table has no unique constraints; '
        'a unique identifier is required.';
  }

  for (final index in uniqueIndexes) {
    final hasCompleteUniqueKey = index.fields.every(
      (fieldName) =>
          data.containsKey(fieldName) &&
          data[fieldName] != null &&
          data[fieldName].toString().trim().isNotEmpty,
    );
    if (hasCompleteUniqueKey) {
      return null;
    }
  }

  return 'Record has no primary key; provide all fields of at least one '
      'unique index: ${uniqueIndexes.map((i) => i.fields.join(",")).join(" or ")}';
}

/// Pure update-field validation + conversion path that is safe to run in an isolate.
Map<String, dynamic>? validateAndProcessUpdateDataPure({
  required TableSchema schema,
  required Map<String, dynamic> data,
  required TableName tableName,
  bool ignoreUnknownFields = true,
}) {
  try {
    final primaryKey = schema.primaryKey;
    final fieldMap = {for (final f in schema.fields) f.name: f};

    if (!ignoreUnknownFields) {
      for (final key in data.keys) {
        if (key != primaryKey && !fieldMap.containsKey(key)) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devFieldNotFound,
              message: 'Unknown field $key in table $tableName',
              parameterName: key,
              passedValue: data[key],
            )
          ]);
        }
      }
    }

    final result = <String, dynamic>{};

    for (final field in schema.fields) {
      if (field.name == primaryKey) {
        continue;
      }

      if (!data.containsKey(field.name)) {
        continue;
      }

      final value = data[field.name];
      if (value is ExprNode) {
        result[field.name] = value;
        continue;
      }

      field.checkConstraints(
        value,
        tableName: tableName,
        skipMaxLengthCheck: true,
      );

      result[field.name] = field.convertValue(value);
      if (result[field.name] != null &&
          field.maxLength != null &&
          result[field.name] is String &&
          (result[field.name] as String).length > field.maxLength!) {
        Logger.warn(
          'Warning: field ${field.name} exceeds max length',
        );
        result[field.name] =
            (result[field.name] as String).substring(0, field.maxLength!);
      }
    }

    return result;
  } on DbException {
    rethrow;
  } catch (e) {
    Logger.error('Update data validation failed', rawError: e);
    return null;
  }
}

/// Pure synchronous computation to apply a uniform validated update payload to an existing record.
Map<String, dynamic> applyUniformUpdatePure({
  required TableSchema schema,
  required Map<String, dynamic> validData,
  required Map<String, dynamic> existingRecord,
}) {
  final primaryKey = schema.primaryKey;
  final updatedRecord = <String, dynamic>{};
  updatedRecord[primaryKey] = existingRecord[primaryKey];

  for (final field in schema.fields) {
    if (field.name == primaryKey) {
      continue;
    }

    final fieldName = field.name;
    final proposed =
        validData.containsKey(fieldName) ? validData[fieldName] : null;

    if (proposed is ExprNode) {
      try {
        final result = evaluateExpressionForRecord(
          proposed,
          existingRecord,
          schema,
          isUpdate: true,
        );
        updatedRecord[fieldName] = field.convertValue(result);
      } catch (e) {
        Logger.error('Failed to evaluate expression for field $fieldName',
            rawError: e);
        updatedRecord[fieldName] = existingRecord[fieldName];
      }
    } else if (validData.containsKey(fieldName)) {
      updatedRecord[fieldName] = proposed;
    } else {
      updatedRecord[fieldName] = existingRecord[fieldName];
    }
  }

  return updatedRecord;
}

/// Evaluates an expression AST using current record values.
dynamic evaluateExpressionForRecord(
  ExprNode expression,
  Map<String, dynamic> record,
  TableSchema schema, {
  bool isUpdate = false,
}) {
  final validFieldNames = <String>{
    ...schema.fields.map((f) => f.name),
    schema.primaryKey,
  };
  return _evaluateExprNode(
    expression,
    record,
    validFieldNames,
    isUpdate: isUpdate,
  );
}

bool _toBool(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  return true;
}

dynamic _evaluateExprNode(
  ExprNode node,
  Map<String, dynamic> record,
  Set<String> validFieldNames, {
  bool isUpdate = false,
}) {
  if (node is IsUpdate) {
    return isUpdate;
  } else if (node is IsInsert) {
    return !isUpdate;
  } else if (node is IfElse) {
    final cond = _evaluateExprNode(
      node.condition,
      record,
      validFieldNames,
      isUpdate: isUpdate,
    );
    final branch = _toBool(cond) ? node.thenValue : node.elseValue;
    if (branch is ExprNode) {
      return _evaluateExprNode(
        branch,
        record,
        validFieldNames,
        isUpdate: isUpdate,
      );
    }
    return branch;
  } else if (node is When) {
    final cond = _evaluateExprNode(
      node.condition,
      record,
      validFieldNames,
      isUpdate: isUpdate,
    );
    if (_toBool(cond)) {
      final v = node.value;
      if (v is ExprNode) {
        return _evaluateExprNode(
          v,
          record,
          validFieldNames,
          isUpdate: isUpdate,
        );
      }
      return v;
    }
    final o = node.otherwise;
    if (o is ExprNode) {
      return _evaluateExprNode(
        o,
        record,
        validFieldNames,
        isUpdate: isUpdate,
      );
    }
    return o;
  } else if (node is TimestampExpr) {
    return DateTime.now().toIso8601String();
  } else if (node is FieldRef) {
    if (!validFieldNames.contains(node.fieldName)) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devFieldNotFound,
          message:
              'Invalid field reference: "${node.fieldName}". Field must exist in the table schema.',
          parameterName: 'fieldName',
          passedValue: node.fieldName,
        )
      ]);
    }

    final value = record[node.fieldName];
    if (value == null) return 0;
    if (value is num) return value;
    if (value is String) {
      final parsed = num.tryParse(value);
      if (parsed != null) return parsed;
    }

    Logger.warn(
      'Field "${node.fieldName}" has non-numeric value: $value. Treating as 0.',
    );
    return 0;
  } else if (node is Constant) {
    return node.value;
  } else if (node is BinaryOp) {
    final left = _evaluateExprNode(
      node.left,
      record,
      validFieldNames,
      isUpdate: isUpdate,
    );
    final right = _evaluateExprNode(
      node.right,
      record,
      validFieldNames,
      isUpdate: isUpdate,
    );

    switch (node.op) {
      case BinaryOperator.add:
        return left + right;
      case BinaryOperator.subtract:
        return left - right;
      case BinaryOperator.multiply:
        return left * right;
      case BinaryOperator.divide:
        if (right == 0) {
          Logger.warn(
            'Division by zero in expression. Returning 0.',
          );
          return 0;
        }
        return left / right;
      case BinaryOperator.modulo:
        if (right == 0) {
          Logger.warn(
            'Modulo by zero in expression. Returning 0.',
          );
          return 0;
        }
        return left % right;
      case BinaryOperator.min:
        return left < right ? left : right;
      case BinaryOperator.max:
        return left > right ? left : right;
    }
  } else if (node is UnaryOp) {
    final operand = _evaluateExprNode(
      node.operand,
      record,
      validFieldNames,
      isUpdate: isUpdate,
    );

    switch (node.op) {
      case UnaryOperator.negate:
        return -operand;
      case UnaryOperator.abs:
        return operand.abs();
    }
  } else if (node is FunctionCall) {
    final args = node.arguments
        .map((arg) => _evaluateExprNode(
              arg,
              record,
              validFieldNames,
              isUpdate: isUpdate,
            ))
        .toList(growable: false);

    switch (node.functionName) {
      case 'min':
        if (args.length != 2) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devInvalidArgumentFormat,
              message: 'min() requires exactly 2 arguments',
              parameterName: 'arguments',
              passedValue: args.length,
            )
          ]);
        }
        return args[0] < args[1] ? args[0] : args[1];
      case 'max':
        if (args.length != 2) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devInvalidArgumentFormat,
              message: 'max() requires exactly 2 arguments',
              parameterName: 'arguments',
              passedValue: args.length,
            )
          ]);
        }
        return args[0] > args[1] ? args[0] : args[1];
      case 'round':
        if (args.length != 1) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devInvalidArgumentFormat,
              message: 'round() requires exactly 1 argument',
              parameterName: 'arguments',
              passedValue: args.length,
            )
          ]);
        }
        return args[0].round();
      case 'floor':
        if (args.length != 1) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devInvalidArgumentFormat,
              message: 'floor() requires exactly 1 argument',
              parameterName: 'arguments',
              passedValue: args.length,
            )
          ]);
        }
        return args[0].floor();
      case 'ceil':
        if (args.length != 1) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devInvalidArgumentFormat,
              message: 'ceil() requires exactly 1 argument',
              parameterName: 'arguments',
              passedValue: args.length,
            )
          ]);
        }
        return args[0].ceil();
      case 'abs':
        if (args.length != 1) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devInvalidArgumentFormat,
              message: 'abs() requires exactly 1 argument',
              parameterName: 'arguments',
              passedValue: args.length,
            )
          ]);
        }
        return args[0].abs();
      default:
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message:
                'Unknown function: ${node.functionName}. Supported functions: min, max, round, floor, ceil, abs.',
            parameterName: 'functionName',
            passedValue: node.functionName,
          )
        ]);
    }
  }

  throw DbException([
    InvalidArgumentStatus(
      type: ResultType.devInvalidArgumentFormat,
      message: 'Unknown expression node type: ${node.runtimeType}',
      parameterName: 'node',
      passedValue: node.runtimeType.toString(),
    )
  ]);
}
