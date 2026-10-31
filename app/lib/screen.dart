import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'store.dart';

/// Live view of this PC's screen for paired devices.
///
/// wf-recorder (wlroots / Hyprland / Sway) encodes the screen as a stream of JPEG frames
/// and only produces a frame when something changed. Frames are sent length-prefixed
/// (4-byte big-endian size + JPEG). Slow viewers get the newest frame, never a backlog.
/// shortcut: MJPEG (~3 Mbit/s at 1280 px); switch to H.264 if mobile data use becomes a problem.

const screenQualities = {
  'low': (width: 960, q: 12, fps: 8),
  'medium': (width: 1280, q: 8, fps: 12),
  'high': (width: 1920, q: 4, fps: 20),
};

/// Splits a concatenated MJPEG byte stream into whole JPEG frames.
class JpegSplitter {
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  List<Uint8List> add(List<int> chunk) {
    _buf.add(_pending);
    _buf.add(chunk);
    final data = _buf.takeBytes();
    final out = <Uint8List>[];
    var start = -1;
    for (var i = 0; i + 1 < data.length; i++) {
      if (data[i] != 0xFF) continue;
      final m = data[i + 1];
      if (m == 0xD8 && start < 0) start = i;
      if (m == 0xD9 && start >= 0) {
        // FFD9 only appears as end-of-image: inside JPEG data 0xFF is always escaped as FF00.
        out.add(Uint8List.sublistView(data, start, i + 2));
        start = -1;
      }
    }
    // Keep an unfinished frame, or a lone trailing FF that may be half of the next start marker.
    _pending = start >= 0
        ? Uint8List.fromList(data.sublist(start))
        : (data.isNotEmpty && data.last == 0xFF ? Uint8List.fromList([0xFF]) : Uint8List(0));
    return out;
  }
}

class ScreenHost {
  final Store store;
  /// Builds the recorder command; tests swap in a fake.
  final List<String> Function(String quality, String? output) command;
  ScreenHost(this.store, {List<String> Function(String, String?)? command}) : command = command ?? _wfRecorder;

  final _frames = StreamController<Uint8List>.broadcast();
  Uint8List? _last;
  Process? _proc;
  String? _quality;
  int _viewers = 0;
  Timer? _stopTimer;

  static List<String> _wfRecorder(String quality, String? output) {
    final p = screenQualities[quality] ?? screenQualities['medium']!;
    return [
      'wf-recorder', '-y', '-c', 'mjpeg', '-m', 'mjpeg', '-x', 'yuvj420p',
      '-F', 'scale=${p.width}:-2', '-p', 'q=${p.q}', '-r', '${p.fps}',
      if (output != null) ...['-o', output],
      '-f', '/dev/stdout',
    ];
  }

  static bool get available => Platform.isLinux && (Platform.environment['PATH'] ?? '').split(':').any((d) => File('$d/wf-recorder').existsSync());

  /// The monitor that has focus (Hyprland), so multi-monitor setups don't prompt.
  static Future<String?> _focusedOutput() async {
    try {
      final r = await Process.run('hyprctl', ['monitors', '-j']);
      final l = jsonDecode(r.stdout as String) as List;
      return (l.firstWhere((m) => m['focused'] == true, orElse: () => l.first))['name'];
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensure(String quality) async {
    _stopTimer?.cancel();
    if (_proc != null && _quality == quality) return;
    _proc?.kill(ProcessSignal.sigint);
    _quality = quality;
    final cmd = command(quality, await _focusedOutput());
    final p = await Process.start(cmd.first, cmd.sublist(1));
    _proc = p;
    final split = JpegSplitter();
    p.stdout.listen((chunk) {
      for (final f in split.add(chunk)) {
        _last = f;
        _frames.add(f);
      }
    });
    p.stderr.drain();
    p.exitCode.then((_) {
      if (_proc == p) _proc = null;
    });
  }

  void _release() {
    if (--_viewers > 0) return;
    // Grace period: switching quality or a quick reconnect shouldn't restart capture.
    _stopTimer = Timer(const Duration(seconds: 3), () {
      final p = _proc;
      _proc = null;
      _last = null;
      p?.kill(ProcessSignal.sigint);
      Timer(const Duration(seconds: 2), () => p?.kill(ProcessSignal.sigkill)); // no-op if it already exited
    });
  }

  Future<bool> handle(HttpRequest req, Device from) async {
    if (req.uri.path != '/screen') return false;
    final res = req.response;
    if (!store.get('screenEnabled', true)) {
      res.statusCode = 403;
      res.write('{"error":"Screen view is turned off on this PC."}');
      return true;
    }
    if (!available) {
      res.statusCode = 501;
      res.write('{"error":"Screen view needs wf-recorder on a wlroots desktop (Hyprland, Sway)."}');
      return true;
    }
    final quality = screenQualities.containsKey(req.uri.queryParameters['q']) ? req.uri.queryParameters['q']! : 'medium';
    res.headers.contentType = ContentType('application', 'x-myphone-frames');
    // Raw connection for the stream: unlike HttpResponse it reliably tells us when the viewer leaves.
    res.headers.set(HttpHeaders.connectionHeader, 'close');
    res.headers.chunkedTransferEncoding = false;
    final sock = await res.detachSocket();
    _viewers++;
    final done = Completer<void>();
    void finish() => done.isCompleted ? null : done.complete();
    sock.listen((_) {}, onDone: finish, onError: (_) => finish(), cancelOnError: true);
    var busy = false;
    Uint8List? waiting;

    Future<void> send(Uint8List f) async {
      if (busy) {
        waiting = f; // keep only the newest
        return;
      }
      busy = true;
      try {
        final len = ByteData(4)..setUint32(0, f.length);
        sock.add(len.buffer.asUint8List());
        sock.add(f);
        await sock.flush();
      } catch (_) {
        finish();
      }
      busy = false;
      final next = waiting;
      waiting = null;
      if (next != null && !done.isCompleted) send(next);
    }

    final sub = _frames.stream.listen(send);
    // Static screens send nothing; a tiny keep-alive also surfaces dead connections.
    final ping = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!busy) send(Uint8List(0));
    });
    try {
      await _ensure(quality);
      if (_last != null) send(_last!); // static screen: show something right away
      await done.future;
    } finally {
      ping.cancel();
      await sub.cancel();
      sock.destroy();
      _release();
    }
    return true;
  }

  bool get capturing => _proc != null;

  void dispose() {
    _proc?.kill(ProcessSignal.sigint);
    _frames.close();
  }
}
