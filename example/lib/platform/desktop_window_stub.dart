import 'package:flutter/widgets.dart';

bool get isDesktopWindow => false;

Future<void> initDesktopWindow() async {}

Widget wrapWindowDrag({required Widget child}) => child;

List<Widget> buildWindowCaptionActions() => const <Widget>[];

double get desktopLeadingWidth => 0;
