import 'dart:async';
import 'dart:isolate';

// A private class to bundle the arguments for the isolate
class _IsolateRequest {
  final Function function;
  final dynamic message;
  final SendPort sendPort;
  _IsolateRequest(this.function, this.message, this.sendPort);
}

// The entry point for the new isolate
void _isolateEntry(_IsolateRequest request) async {
  try {
    final result = await request.function(request.message);
    request.sendPort.send(result);
  } catch (e, stack) {
    // Pass error and stack trace back to the main isolate
    request.sendPort.send({'error': e, 'stackTrace': stack});
  }
}

/// Runs a function in a separate isolate and returns the result.
/// This is useful for CPU-intensive tasks that could block the main UI thread.
///
/// The [function] must be a top-level function or a static method.
/// The [message] is the argument passed to the [function].
Future<R> compute<Q, R>(FutureOr<R> Function(Q) function, Q message) async {
  final receivePort = ReceivePort();
  final request = _IsolateRequest(function, message, receivePort.sendPort);
  final isolate = await Isolate.spawn(
    _isolateEntry,
    request,
    debugName: function.toString(),
    errorsAreFatal: false, // Allow us to handle errors
  );

  final completer = Completer<R>();

  receivePort.listen((data) {
    if (!completer.isCompleted) {
      if (data is Map && data.containsKey('error')) {
        completer.completeError(data['error'], data['stackTrace']);
      } else {
        completer.complete(data as R);
      }
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  });

  return completer.future;
}
