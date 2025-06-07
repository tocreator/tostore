import 'result_code.dart';

/// query result class
class QueryResult<T> {
  /// Whether the operation is successful
  bool get isSuccess => code == ResultCode.success;

  /// query result data
  final List<T> data;

  /// operation status code
  final ResultCode code;

  /// operation message
  final String message;

  QueryResult({
    required this.code,
    required this.data,
    this.message = '',
  });

  /// create a success result
  factory QueryResult.success({
    required List<T> data,
    String message = '',
  }) {
    return QueryResult(
      data: data,
      code: ResultCode.success,
      message: message.isNotEmpty ? message : ResultCode.success.message,
    );
  }

  /// create an error result
  factory QueryResult.error({
    ResultCode code = ResultCode.unknown,
    String message = '',
  }) {
    return QueryResult(
      data: [],
      code: code,
      message: message.isNotEmpty ? message : code.message,
    );
  }

  /// get the length of data
  int get length => data.length;

  /// whether there is data
  bool get isEmpty => data.isEmpty;

  /// whether there is data
  bool get isNotEmpty => data.isNotEmpty;

  /// get the status code value
  int get codeValue => code.code;

  /// for serialization
  Map<String, dynamic> toJson() {
    return {
      'code': code.code,
      'message': message,
      'data': data is List<Map<String, dynamic>>
          ? data
          : null, // only serialize data when T is Map<String, dynamic>
    };
  }

  /// create an instance from json
  static QueryResult<Map<String, dynamic>> fromJson(Map<String, dynamic> json) {
    return QueryResult<Map<String, dynamic>>(
      code: ResultCode.fromCode(json['code'] as int),
      message: json['message'] as String,
      data: (json['data'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
