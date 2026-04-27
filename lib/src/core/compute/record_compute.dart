import '../../handler/logger.dart';
import '../../model/business_error.dart';
import '../../model/expr.dart';
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
  required String tableName,
  bool skipPrimaryKeyFormatCheck = false,
  List<String>? validationErrors,
  Map<String, FieldSchema>? fieldMap,
  bool hasResolvedPrimaryKey = false,
  Object? resolvedPrimaryKey,
}) {
  try {
    final primaryKey = schema.primaryKey;
    final result = <String, dynamic>{};

    // 1. Primary key handling.
    if (!data.containsKey(primaryKey) || data[primaryKey] == null) {
      if (hasResolvedPrimaryKey) {
        result[primaryKey] = resolvedPrimaryKey;
      } else {
        throw const BusinessError(
          'Primary key value cannot be null',
          type: BusinessErrorType.invalidData,
        );
      }
    } else {
      final providedId = data[primaryKey];

      if (providedId != null &&
          !skipPrimaryKeyFormatCheck &&
          !schema.validatePrimaryKeyFormat(providedId)) {
        throw BusinessError(
          'The provided primary key value $providedId does not meet the format requirements for type ${schema.primaryKeyConfig.type}',
          type: BusinessErrorType.invalidData,
        );
      }

      result[primaryKey] =
          schema.primaryKeyConfig.convertPrimaryKey(providedId);
    }

    // 2. Defaults, expressions, and type conversion.
    for (final field in schema.fields) {
      if (field.name == primaryKey) continue;

      final raw = data[field.name];
      dynamic value = raw;
      if (raw is ExprNode) {
        if (raw is TimestampExpr) {
          value = DateTime.now().toIso8601String();
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
              'Failed to evaluate expression for insert on field ${field.name}: $e. Using 0 as default.',
              label: 'RecordCompute.validateAndProcessRecordPure',
            );
            value = 0;
          }
        }
      }

      result[field.name] = field.convertValue(value);
    }

    // 3. Schema validation and constraint application.
    final validatedResult = schema.validateData(
      result,
      applyConstraints: true,
      errors: validationErrors,
      trustedConvertedValues: true,
      fieldMap: fieldMap,
    );
    if (validatedResult == null) {
      Logger.warn(
        'Data validation failed for table $tableName',
        label: 'RecordCompute.validateAndProcessRecordPure',
      );
      return null;
    }

    return validatedResult;
  } catch (e) {
    Logger.error(
      'Data validation failed: $e',
      label: 'RecordCompute.validateAndProcessRecordPure',
    );
    if (validationErrors != null) {
      if (e is BusinessError &&
          e.type == BusinessErrorType.invalidData &&
          e.message.isNotEmpty) {
        validationErrors.add(e.message);
      } else {
        validationErrors.add(e.toString());
      }
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
  required String tableName,
}) {
  try {
    final result = <String, dynamic>{};
    final primaryKey = schema.primaryKey;

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

      if (!field.validateUpdateValue(value)) {
        Logger.warn(
          'Field ${field.name} value does not meet constraints: $value',
          label: 'RecordCompute.validateAndProcessUpdateDataPure',
        );
        return null;
      }

      result[field.name] = field.convertValue(value);
      if (result[field.name] != null &&
          field.maxLength != null &&
          result[field.name] is String &&
          (result[field.name] as String).length > field.maxLength!) {
        Logger.warn(
          'Warning: field ${field.name} exceeds max length',
          label: 'RecordCompute.validateAndProcessUpdateDataPure',
        );
        result[field.name] =
            (result[field.name] as String).substring(0, field.maxLength!);
      }
    }

    return result;
  } catch (e) {
    Logger.error(
      'Update data validation failed: $e',
      label: 'RecordCompute.validateAndProcessUpdateDataPure',
    );
    return null;
  }
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
      throw ArgumentError(
        'Invalid field reference: "${node.fieldName}". '
        'Field must exist in the table schema.',
      );
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
      label: 'RecordCompute.evaluateExpressionForRecord',
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
            label: 'RecordCompute.evaluateExpressionForRecord',
          );
          return 0;
        }
        return left / right;
      case BinaryOperator.modulo:
        if (right == 0) {
          Logger.warn(
            'Modulo by zero in expression. Returning 0.',
            label: 'RecordCompute.evaluateExpressionForRecord',
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
          throw ArgumentError('min() requires exactly 2 arguments');
        }
        return args[0] < args[1] ? args[0] : args[1];
      case 'max':
        if (args.length != 2) {
          throw ArgumentError('max() requires exactly 2 arguments');
        }
        return args[0] > args[1] ? args[0] : args[1];
      case 'round':
        if (args.length != 1) {
          throw ArgumentError('round() requires exactly 1 argument');
        }
        return args[0].round();
      case 'floor':
        if (args.length != 1) {
          throw ArgumentError('floor() requires exactly 1 argument');
        }
        return args[0].floor();
      case 'ceil':
        if (args.length != 1) {
          throw ArgumentError('ceil() requires exactly 1 argument');
        }
        return args[0].ceil();
      case 'abs':
        if (args.length != 1) {
          throw ArgumentError('abs() requires exactly 1 argument');
        }
        return args[0].abs();
      default:
        throw ArgumentError(
          'Unknown function: ${node.functionName}. '
          'Supported functions: min, max, round, floor, ceil, abs.',
        );
    }
  }

  throw ArgumentError('Unknown expression node type: ${node.runtimeType}');
}
