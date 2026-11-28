import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the workout rest timer alive while the app is minimized.
///
/// On Android this drives [RestTimerService], a short-lived foreground service
/// with a silent countdown notification and a timeout-bounded partial wake
/// lock so the OS neither freezes the Dart process nor pauses the CPU before
/// the countdown ticks and "go" cue fire. On platforms without the channel
/// (tests, iOS, desktop) every call is a safe no-op.
abstract class RestTimerBackground {
  /// Starts or updates the background keep-alive until [endAt].
  Future<void> start({required DateTime endAt});

  /// Stops the background keep-alive.
  ///
  /// When [graceMs] is positive the native service waits that long before
  /// releasing its wake lock and notification, giving the final "go" audio cue
  /// time to finish playing while the screen is off.
  Future<void> stop({int graceMs = 0});

  /// Registers a callback invoked if the user cancels the rest from the
  /// background notification itself.
  void setCancelHandler(VoidCallback? onCancelled);
}

class MethodChannelRestTimerBackground implements RestTimerBackground {
  static const MethodChannel _channel =
      MethodChannel('com.arcanegrowth.compounder/rest_timer');

  VoidCallback? _onCancelled;

  MethodChannelRestTimerBackground() {
    _channel.setMethodCallHandler(_handleCall);
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method == 'cancelled') {
      _onCancelled?.call();
    }
  }

  @override
  void setCancelHandler(VoidCallback? onCancelled) {
    _onCancelled = onCancelled;
  }

  @override
  Future<void> start({required DateTime endAt}) async {
    try {
      await _channel.invokeMethod<void>('start', <String, Object>{
        'endAtMs': endAt.millisecondsSinceEpoch,
      });
    } on MissingPluginException {
      // No native service on this platform (tests, iOS, desktop).
    } catch (error) {
      debugPrint('rest timer background start failed: $error');
    }
  }

  @override
  Future<void> stop({int graceMs = 0}) async {
    try {
      await _channel.invokeMethod<void>('stop', <String, Object>{
        'graceMs': graceMs,
      });
    } on MissingPluginException {
      // No native service on this platform.
    } catch (error) {
      debugPrint('rest timer background stop failed: $error');
    }
  }
}
