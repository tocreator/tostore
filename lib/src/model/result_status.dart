import 'dart:convert';
import 'dart:typed_data';

import 'result_type.dart';

/// Base class for all database operation status results.
/// Provides basic status parameters and supports machine-friendly error diagnostic fields.
abstract class ResultStatus {
  /// Leaf result status type
  final ResultType type;

  /// Human-readable description message
  final String message;

  /// Sequence index in batch operations (0 for single operation)
  final int index;

  /// Numeric status code
  int get code => type.code;

  /// Semantic state identifier key
  String get codeKey => type.codeKey;

  /// Optional primary key of the record associated with this status
  String? get primaryKey => null;

  /// Whether this status is a Business Error
  bool get isBusinessError => type.isBusinessError;

  /// Whether this status is a Developer Error
  bool get isDeveloperError => type.isDeveloperError;

  /// Whether this status is a System Error
  bool get isSystemError => type.isSystemError;

  /// Whether this status is an Engine Error
  bool get isEngineError => type.isEngineError;

  ResultStatus({
    required this.type,
    required this.message,
    this.index = 0,
  });

  /// Convert result status to a Map for serialization
  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'code': code,
      'codeKey': codeKey,
      'message': message,
    };
  }

  /// Create a specific ResultStatus instance from JSON
  factory ResultStatus.fromJson(Map<String, dynamic> json,
      {int? indexOverride}) {
    final codeValue = json['code'] as int? ?? 99001;
    final type = ResultType.fromCode(codeValue);
    final message = json['message'] as String? ?? '';
    final index = indexOverride ?? json['index'] as int? ?? 0;

    if (type == ResultType.success) {
      return SuccessStatus(
        message: message,
        index: index,
        primaryKey: json['primaryKey']?.toString(),
      );
    } else if (type.code == 10001 ||
        type.code == 12002 ||
        (type.code >= 11000 && type.code < 12000)) {
      return ConstraintStatus(
        type: type,
        message: message,
        index: index,
        tableName: json['tableName'] as String? ?? '',
        constraintName: json['constraintName'] as String?,
        fields: List<String>.from(json['fields'] as List? ?? []),
        conflictingKeys:
            List<dynamic>.from(json['conflictingKeys'] as List? ?? []),
        primaryKey: json['primaryKey']?.toString(),
        referencedTable: json['referencedTable']?.toString(),
      );
    } else if (type.code >= 30000 && type.code < 31000) {
      return SchemaValidationStatus(
        type: type,
        message: message,
        index: index,
        tableName: json['tableName'] as String? ?? '',
        field: json['field'] as String?,
        wrongValue: json['wrongValue'],
      );
    } else if ((type.code >= 20000 &&
            type.code < 21000 &&
            type.code != 20006 &&
            type.code != 20007 &&
            type.code != 20008 &&
            type.code != 20009) ||
        type.code == 22005) {
      return InvalidArgumentStatus(
        type: type,
        message: message,
        index: index,
        parameterName: json['parameterName'] as String? ?? '',
        passedValue: json['passedValue'],
        primaryKey: json['primaryKey']?.toString(),
      );
    } else if (type.code >= 50000 && type.code < 51000) {
      return TransactionOperationStatus(
        type: type,
        message: message,
        index: index,
        txId: json['txId'] as String? ?? '',
      );
    } else {
      return GeneralStatus(
        type: type,
        message: message,
        index: index,
        primaryKey: json['primaryKey']?.toString(),
        target: json['target']?.toString(),
        operation: json['operation']?.toString(),
      );
    }
  }
}

/// Status detail for successful database operations.
class SuccessStatus extends ResultStatus {
  /// The primary key of the successfully created/modified record
  @override
  final String? primaryKey;

  SuccessStatus({
    required super.message,
    super.index,
    this.primaryKey,
  }) : super(
          type: ResultType.success,
        );

  @override
  Map<String, dynamic> toJson() {
    final map = super.toJson();
    if (primaryKey != null) {
      map['primaryKey'] = primaryKey;
    }
    return map;
  }
}

/// Status detail for database integrity and constraint violations.
class ConstraintStatus extends ResultStatus {
  /// The table where the constraint violation occurred
  final String tableName;

  /// Optional constraint name
  final String? constraintName;

  /// The list of fields involved in the constraint
  final List<String> fields;

  /// The conflicting keys/values
  final List<dynamic> conflictingKeys;

  /// Optional primary key associated with this constraint violation
  @override
  final String? primaryKey;

  /// Optional referenced table name (specifically for foreign key constraints)
  final String? referencedTable;

  ConstraintStatus({
    required super.type,
    required super.message,
    required this.tableName,
    super.index,
    this.constraintName,
    this.fields = const [],
    this.conflictingKeys = const [],
    this.primaryKey,
    this.referencedTable,
  });

  @override
  Map<String, dynamic> toJson() {
    final map = super.toJson();
    map['tableName'] = tableName;
    if (constraintName != null) {
      map['constraintName'] = constraintName;
    }
    map['fields'] = fields;
    map['conflictingKeys'] = conflictingKeys;
    if (primaryKey != null) {
      map['primaryKey'] = primaryKey;
    }
    if (referencedTable != null) {
      map['referencedTable'] = referencedTable;
    }
    return map;
  }
}

/// Status detail for table schema validation and format failures.
class SchemaValidationStatus extends ResultStatus {
  /// The table whose schema is invalid
  final String tableName;

  /// Optional specific field name that caused validation failure
  final String? field;

  /// The incorrect configuration or schema definition value
  final dynamic wrongValue;

  SchemaValidationStatus({
    required super.type,
    required super.message,
    required this.tableName,
    super.index,
    this.field,
    this.wrongValue,
  });

  @override
  Map<String, dynamic> toJson() {
    final map = super.toJson();
    map['tableName'] = tableName;
    if (field != null) {
      map['field'] = field;
    }
    if (wrongValue != null) {
      map['wrongValue'] = jsonSafeDiagnosticValue(wrongValue);
    }
    return map;
  }
}

/// Status detail for invalid argument errors.
class InvalidArgumentStatus extends ResultStatus {
  /// The parameter name that is invalid
  final String parameterName;

  /// The value passed to the parameter
  final dynamic passedValue;

  /// Optional primary key of the record associated with this argument error
  @override
  final String? primaryKey;

  InvalidArgumentStatus({
    required super.type,
    required super.message,
    required this.parameterName,
    super.index,
    this.passedValue,
    this.primaryKey,
  });

  @override
  Map<String, dynamic> toJson() {
    final map = super.toJson();
    map['parameterName'] = parameterName;
    if (passedValue != null) {
      map['passedValue'] = jsonSafeDiagnosticValue(passedValue);
    }
    if (primaryKey != null) {
      map['primaryKey'] = primaryKey;
    }
    return map;
  }
}

/// Status detail for transaction failures.
class TransactionOperationStatus extends ResultStatus {
  /// The ID of the transaction
  final String txId;

  TransactionOperationStatus({
    required super.type,
    required super.message,
    required this.txId,
    super.index,
  });

  @override
  Map<String, dynamic> toJson() {
    final map = super.toJson();
    map['txId'] = txId;
    return map;
  }
}

/// Generic status detail for other errors without custom diagnostics (e.g. timeouts, system, IO).
class GeneralStatus extends ResultStatus {
  /// Optional primary key associated with this general status error
  @override
  final String? primaryKey;

  /// Optional physical target resource associated with this status (e.g. file path, lock resource)
  final String? target;

  /// Optional operation type executed (e.g. 'readAsString', 'acquire')
  final String? operation;

  GeneralStatus({
    required super.type,
    required super.message,
    super.index,
    this.primaryKey,
    this.target,
    this.operation,
  });

  @override
  Map<String, dynamic> toJson() {
    final map = super.toJson();
    if (primaryKey != null) {
      map['primaryKey'] = primaryKey;
    }
    if (target != null) {
      map['target'] = target;
    }
    if (operation != null) {
      map['operation'] = operation;
    }
    return map;
  }
}

/// Convert a diagnostic field value into a JSON-serializable representation.
///
/// Construction of [InvalidArgumentStatus] / [DbException] never calls this;
/// it is used when serializing or logging so exotic [passedValue] types cannot
/// cause secondary failures after the original error was thrown.
dynamic jsonSafeDiagnosticValue(dynamic value) {
  if (value == null) return null;
  if (value is String) {
    if (value.length > 1000) {
      return '${value.substring(0, 1000)}... (truncated, total length: ${value.length})';
    }
    return value;
  }
  if (value is num || value is bool) return value;
  if (value is TypedData) {
    return '${value.runtimeType}(${value.lengthInBytes} bytes)';
  }
  if (value is List) {
    if (value.length > 100) {
      final sub = value.take(100).toList();
      return [...sub, '... (truncated, total length: ${value.length})'];
    }
    try {
      jsonEncode(value);
      return value;
    } catch (_) {
      return value.map((e) => jsonSafeDiagnosticValue(e)).toList();
    }
  }
  if (value is Map) {
    if (value.length > 100) {
      final sub = Map.fromEntries(value.entries.take(100));
      sub['...'] = '(truncated, total size: ${value.length})';
      return sub
          .map((k, v) => MapEntry(k.toString(), jsonSafeDiagnosticValue(v)));
    }
    try {
      jsonEncode(value);
      return value;
    } catch (_) {
      return value
          .map((k, v) => MapEntry(k.toString(), jsonSafeDiagnosticValue(v)));
    }
  }
  try {
    final str = value.toString();
    if (str.length > 1000) {
      return '${str.substring(0, 1000)}... (truncated, total length: ${str.length})';
    }
    return str;
  } catch (_) {
    return value.runtimeType.toString();
  }
}
