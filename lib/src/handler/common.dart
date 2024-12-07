import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'logger.dart';

/// 内部配置项
class InternalConfig {
  /// 是否显示Logger具体标签
  static const bool showLoggerInternalLabel = false;

  /// 对外显示的统一标签
  static const String publicLabel = 'tostore';
}

/// 将任何对象类型转为字符串
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
    Logger.error('无法将对象 ${object.runtimeType} 转换：$e', label: 'toStringWithAll');
  }
  return value;
}

/// 获取app保存目录，用于数据、配置等永久保存
Future<String> getPathApp() async {
  var cachePath =
      Directory("${(await getApplicationDocumentsDirectory()).path}/common");
  if (!cachePath.existsSync()) {
    cachePath.create();
  }
  return cachePath.path;
}
