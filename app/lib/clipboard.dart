import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:phone_native/phone_native.dart';

import 'net.dart';
import 'store.dart';

/// Clipboard sync between my devices. Off unless 'clipSync' is on (Settings → Sync).
/// Text only. Android only lets apps *read* the clipboard while in front, so phone → PC
/// happens when myPhone is opened; PC → phone works any time.
String _last = '';
Process? _watch;

Future<void> receiveClip(Store s, String text, {bool force = false}) async {
  if ((!force && !s.get('clipSync', false)) || text.isEmpty || text == _last) return;
  _last = text;
  if (Platform.isAndroid) {
    await PhoneNative.setClipboard(text);
  } else if (Platform.isLinux) {
    final p = await Process.start('wl-copy', []);
    p.stdin.write(text);
    await p.stdin.close();
  }
}

/// [force]: an explicit "send clipboard" tap, regardless of the auto-sync switch.
void sendClip(Store s, Client c, String text, {bool force = false}) {
  if ((!force && !s.get('clipSync', false)) || text.trim().isEmpty || (!force && text == _last) || text.length > 200000) return;
  _last = text;
  for (final d in s.devices.values) {
    if (s.online[d.id] == true) c.sendEvent(d, {'t': 'clip', 'text': text, if (force) 'force': true}).catchError((_) {});
  }
}

/// PC: follow the clipboard with wl-paste (works without focus on wlroots/Hyprland).
Future<void> syncClipWatcher(Store s, Client c) async {
  final on = s.get('clipSync', false) && Platform.isLinux;
  if (!on) {
    _watch?.kill();
    _watch = null;
    return;
  }
  if (_watch != null) return;
  try {
    // One base64 line per change, so any text (newlines included) survives.
    final p = await Process.start('wl-paste', ['--no-newline', '--type', 'text', '--watch', 'sh', '-c', 'base64 -w0; echo']);
    _watch = p;
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      try {
        sendClip(s, c, utf8.decode(base64.decode(l.trim()), allowMalformed: true));
      } catch (_) {}
    });
    p.stderr.drain();
  } catch (_) {} // no wl-paste (X11/GNOME): sync from this PC is off, receiving still works
}

/// Phone: called when the app comes to the front.
Future<void> phoneClipOnResume(Store s, Client c) async {
  if (!Platform.isAndroid || !s.get('clipSync', false)) return;
  final t = await PhoneNative.getClipboard().catchError((_) => null);
  if (t != null) sendClip(s, c, t);
}
