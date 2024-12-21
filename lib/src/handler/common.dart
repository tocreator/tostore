import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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

/// get app save directory, for data, config, etc.
Future<String> getPathApp() async {
  var cachePath =
      Directory("${(await getApplicationDocumentsDirectory()).path}/common");
  if (!cachePath.existsSync()) {
    cachePath.create();
  }
  return cachePath.path;
}
