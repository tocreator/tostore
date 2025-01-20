import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'logger.dart';

/// internal configuration
class InternalConfig {
  /// whether to show Logger specific label
  static const bool showLoggerInternalLabel = false;

  /// public label
  static const String publicLabel = 'tostore';
}

/// convert any object type to string
String toStringWithAll(Object? object) {
  String value = '';
  try {
    if (object is String) {
      value = object;
    } else if (object is Map || object is List) {
      value = jsonEncode(object);
    } else {
      value = object.toString();
    }
  } catch (e) {
    Logger.error('cannot convert ${object.runtimeType} to string: $e',
        label: 'toStringWithAll');
  }
  return value;
}

/// handling file paths across platforms
String pathJoin(
  String part1, [
  String? part2,
  String? part3,
  String? part4,
  String? part5,
  String? part6,
  String? part7,
  String? part8,
  String? part9,
  String? part10,
  String? part11,
  String? part12,
  String? part13,
  String? part14,
  String? part15,
  String? part16,
]) {
  return p.join(
    part1,
    part2,
    part3,
    part4,
    part5,
    part6,
    part7,
    part8,
    part9,
    part10,
    part11,
    part12,
    part13,
    part14,
    part15,
    part16,
  );
}

/// get app save directory, for data, config, etc.
Future<String> getPathApp() async {
  final docDir = await getApplicationDocumentsDirectory();
  final cachePath = Directory(pathJoin(docDir.path, 'common'));
  if (!cachePath.existsSync()) {
    cachePath.create();
  }
  return cachePath.path;
}
