import 'result_type.dart';

/// query result class
class QueryResult<T> {
  /// Whether the operation is successful
  bool get isSuccess => type == ResultType.success;

  /// query result data
  final List<T> data;

  /// operation status type
  final ResultType type;

  /// operation message
  final String message;

  QueryResult({
    required this.type,
    required this.data,
    this.message = '',
  });

  /// Get the status code value
  int get code => type.code;

  /// create a success result
  factory QueryResult.success({
    required List<T> data,
    String message = '',
  }) {
    return QueryResult(
      data: data,
      type: ResultType.success,
      message: message.isNotEmpty ? message : ResultType.success.message,
    );
  }

  /// create an error result
  factory QueryResult.error({
    ResultType type = ResultType.unknown,
    String message = '',
  }) {
    return QueryResult(
      data: [],
      type: type,
      message: message.isNotEmpty ? message : type.message,
    );
  }

  /// get the length of data
  int get length => data.length;

  /// whether there is data
  bool get isEmpty => data.isEmpty;

  /// whether there is data
  bool get isNotEmpty => data.isNotEmpty;

  /// Override toString for easy debugging
  @override
  String toString() {
    return 'QueryResult{code: $code, message: $message, data: $data}';
  }

  /// for serialization
  Map<String, dynamic> toJson() {
    return {
      'code': type.code,
      'message': message,
      'data': data is List<Map<String, dynamic>>
          ? data
          : null, // only serialize data when T is Map<String, dynamic>
    };
  }

  /// create an instance from json
  static QueryResult<Map<String, dynamic>> fromJson(Map<String, dynamic> json) {
    return QueryResult<Map<String, dynamic>>(
      type: ResultType.fromCode(json['code'] as int),
      message: json['message'] as String,
      data: (json['data'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
