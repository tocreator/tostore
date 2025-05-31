import 'result_code.dart';

/// query result class
class QueryResult<T> {
  /// whether the operation is successful
  final bool success;

  /// query result data
  final List<T> data;

  /// current batch return data count
  final int count;

  /// operation status code
  final ResultCode code;

  /// operation message
  final String message;

  QueryResult({
    required this.success,
    required this.data,
    int? count,
    this.code = ResultCode.success,
    this.message = '',
  }) : count = count ?? data.length;

  /// create a success result
  factory QueryResult.success({
    required List<T> data,
    ResultCode code = ResultCode.success,
    String message = '',
  }) {
    return QueryResult(
      success: true,
      data: data,
      code: code,
      message: message.isNotEmpty ? message : code.message,
    );
  }

  /// create an error result
  factory QueryResult.error({
    ResultCode code = ResultCode.dbError,
    String message = '',
  }) {
    return QueryResult(
      success: false,
      data: [],
      code: code,
      message: message.isNotEmpty ? message : code.message,
    );
  }

  /// whether there is data
  bool get isEmpty => data.isEmpty;

  /// whether there is data
  bool get isNotEmpty => data.isNotEmpty;

  /// get the status code value
  int get codeValue => code.code;

  /// for serialization
  Map<String, dynamic> toJson() {
    return {
      'success': success,
      'code': code.code,
      'message': message,
      'count': count,
      'data': data is List<Map<String, dynamic>>
          ? data
          : null, // only serialize data when T is Map<String, dynamic>
    };
  }

  /// create an instance from json (only for T is Map<String, dynamic>)
  static QueryResult<Map<String, dynamic>> fromJson(Map<String, dynamic> json) {
    return QueryResult<Map<String, dynamic>>(
      success: json['success'] as bool,
      code: ResultCode.fromCode(json['code'] as int),
      message: json['message'] as String,
      data: (json['data'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      count: json['count'] as int? ?? 0,
    );
  }
}
