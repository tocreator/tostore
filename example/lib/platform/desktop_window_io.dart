import 'dart:io';

import 'package:flutter/material.dart';

bool get isDesktopWindow =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> initDesktopWindow() async {}

Widget wrapWindowDrag({required Widget child}) => child;

List<Widget> buildWindowCaptionActions() => const <Widget>[];

double get desktopLeadingWidth => Platform.isMacOS ? 78 : 0;
