import 'dart:async';

import '../handler/logger.dart';

/// Stub implementation of dart:isolate for web platforms
///
/// This provides compatible API surface for the parts of dart:isolate used in the codebase
/// but with implementations that work in single-threaded environments.

/// A stub version of SendPort
class SendPort {
  final void Function(dynamic)? _handler;

  SendPort([this._handler]);

  void send(dynamic message) {
    _handler?.call(message);
  }
}

/// A stub version of ReceivePort
class ReceivePort {
  final _controller = StreamController<dynamic>();
  SendPort? _sendPort;

  ReceivePort() {
    _sendPort = SendPort((message) {
      _controller.add(message);
    });
  }

  /// Close the port
  void close() {
    _controller.close();
  }

  /// Get the send port for this receive port
  SendPort get sendPort => _sendPort!;

  /// Listen to messages on this port
  StreamSubscription<dynamic> listen(void Function(dynamic) onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _controller.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  /// Get the first message from this port
  Future<dynamic> get first => _controller.stream.first;
}

/// A stub version of Isolate for web platforms
class Isolate {
  /// Static method to exit an isolate
  static void exit(SendPort port, [dynamic message]) {
    if (message != null) {
      port.send(message);
    }
  }

  /// Spawn method that runs the function in the same thread (no actual isolation)
  /// This implementation accepts different function signatures for compatibility
  static Future<Isolate> spawn<T>(Function entryPoint, dynamic message) async {
    // Create a new isolate stub
    final isolate = Isolate();

    // Run the entry point function in the current thread
    // Schedule it with a Future to avoid blocking
    Future(() {
      try {
        // Handle different function signatures
        if (entryPoint is void Function(dynamic)) {
          entryPoint(message);
        } else if (entryPoint is void Function(List<dynamic>)) {
          entryPoint(message as List<dynamic>);
        } else if (entryPoint is void Function(Map<String, dynamic>)) {
          entryPoint(message as Map<String, dynamic>);
        } else {
          // Fall back to a generic approach
          Function.apply(entryPoint, [message]);
        }
      } catch (e) {
        Logger.error('Error in isolate stub: $e', label: 'Isolate');
      }
    });

    return isolate;
  }
}
