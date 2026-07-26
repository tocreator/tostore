import 'package:flutter/widgets.dart';

import 'desktop_window_stub.dart' if (dart.library.io) 'desktop_window_io.dart'
    as impl;

/// Whether this build should hide the native title bar and host window controls.
bool get isDesktopWindow => impl.isDesktopWindow;

Future<void> initDesktopWindow() => impl.initDesktopWindow();

/// Enables dragging the window from [child] on desktop; no-op elsewhere.
Widget wrapWindowDrag({required Widget child}) =>
    impl.wrapWindowDrag(child: child);

/// Native min/max/close controls for Windows/Linux when title bar is hidden.
List<Widget> buildWindowCaptionActions() => impl.buildWindowCaptionActions();

/// Leading inset so macOS traffic lights do not overlap the brand mark.
double get desktopLeadingWidth => impl.desktopLeadingWidth;
