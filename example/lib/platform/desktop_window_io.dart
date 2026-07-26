import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

bool get isDesktopWindow =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> initDesktopWindow() async {
  if (!isDesktopWindow) return;

  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'ToStore Demo',
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

Widget wrapWindowDrag({required Widget child}) {
  if (!isDesktopWindow) return child;
  return DragToMoveArea(child: child);
}

List<Widget> buildWindowCaptionActions() {
  if (!isDesktopWindow || Platform.isMacOS) return const <Widget>[];
  return const <Widget>[
    SizedBox(
      width: 138,
      height: kToolbarHeight,
      child: WindowCaption(
        backgroundColor: Colors.transparent,
        brightness: Brightness.light,
      ),
    ),
  ];
}

double get desktopLeadingWidth => Platform.isMacOS ? 78 : 0;
