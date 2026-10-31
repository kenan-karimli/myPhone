import 'package:flutter/services.dart';

/// Android only. Safe to call from the background service isolate too.
class PhoneNative {
  static const _c = MethodChannel('phone_native');
  static Future<void> setClipboard(String text) => _c.invokeMethod('setClipboard', {'text': text});
  /// Only works while the app is in front (Android 10+ rule).
  static Future<String?> getClipboard() => _c.invokeMethod<String>('getClipboard');
  /// Loud alarm sound, even on silent, until [stopRing] or [seconds] pass.
  static Future<void> ring({int seconds = 30}) => _c.invokeMethod('ring', {'seconds': seconds});
  static Future<void> stopRing() => _c.invokeMethod('stopRing');

  /// Text the user sent with the "Send clipboard" Quick Settings tile.
  static void onSendClip(void Function(String text) f) => _c.setMethodCallHandler((call) async {
        if (call.method == 'sendClip') f(call.arguments as String);
      });
}
