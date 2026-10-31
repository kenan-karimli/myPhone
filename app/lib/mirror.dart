import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'net.dart';
import 'screen.dart';
import 'store.dart';

/// Phone screen on the PC, with mouse/keyboard control.
///
/// The phone (MirrorService.kt) connects to the PC on port 4749 after the user allowed
/// screen capture on the phone. Frames both ways: [type 1 B][length 4 B BE][payload]:
///   phone → PC: 0 hello {id}, 1 info {w,h,control}, 2 H.264 Annex-B
///   PC → phone: 10 input {a: tap|long|swipe|scroll|back|home|recents|notifications|text|backspace|enter, …}
/// ffmpeg decodes H.264 to JPEG frames for display.
const mirrorPort = 4749;

bool get _hasGst => (Platform.environment['PATH'] ?? '').split(':').any((d) => File('$d/gst-launch-1.0').existsSync());

class MirrorSession {
  final Device dev;
  final Socket _sock;
  Process? _ffmpeg;
  int w = 0, h = 0;
  bool control = false;
  final frames = StreamController<Uint8List>.broadcast();
  Uint8List? last;
  bool closed = false;
  final void Function() _changed;
  List<Uint8List>? _early = []; // video that arrives before ffmpeg is up (SPS/PPS come only once)

  MirrorSession(this.dev, this._sock, this._changed);

  Future<void> _startDecoder() async {
    try {
      // GStreamer decodes each frame as soon as it arrives (~1 frame behind);
      // ffmpeg's CLI pipeline holds ~5 frames, so it's only the fallback.
      final p = _hasGst
          ? await Process.start('gst-launch-1.0', ['-q', 'fdsrc', 'fd=0', '!', 'h264parse', '!', 'avdec_h264', 'max-threads=1', '!', 'videoconvert', '!', 'jpegenc', 'quality=80', '!', 'fdsink', 'fd=1', 'sync=false'])
          : await Process.start('ffmpeg', [
              '-loglevel', 'error', '-flags', 'low_delay', // note: '-fflags nobuffer' makes this ffmpeg output nothing for raw H.264
              '-probesize', '32', '-analyzeduration', '0',
              '-threads', '1', // frame threading adds a frame of delay per thread
              '-f', 'h264', '-i', 'pipe:0', '-pix_fmt', 'yuvj420p', '-q:v', '5', '-f', 'mjpeg', 'pipe:1',
            ]);
      _ffmpeg = p;
      for (final d in _early!) {
        p.stdin.add(d);
      }
      _early = null;
      final split = JpegSplitter();
      p.stdout.listen((chunk) {
        for (final f in split.add(chunk)) {
          last = f;
          if (!frames.isClosed) frames.add(f);
        }
      });
      p.stderr.drain();
      p.exitCode.then((_) => close());
    } catch (_) {
      frames.addError(const OSError('GStreamer or ffmpeg is needed to show the phone screen (sudo apt install gstreamer1.0-libav).'));
      close();
    }
  }

  void _video(Uint8List data) {
    if (_early != null) {
      _early!.add(Uint8List.fromList(data)); // payload is a view into a reused buffer
      return;
    }
    try {
      _ffmpeg?.stdin.add(data);
    } catch (_) {}
  }

  /// Send one input event; coordinates normalized 0..1.
  void input(Map<String, dynamic> ev) {
    if (closed) return;
    final p = utf8.encode(jsonEncode(ev));
    final head = ByteData(5)
      ..setUint8(0, 10)
      ..setUint32(1, p.length);
    try {
      _sock.add(head.buffer.asUint8List());
      _sock.add(p);
    } catch (_) {}
  }

  void close() {
    if (closed) return;
    closed = true;
    _sock.destroy(); // the phone stops sharing when the connection ends
    _ffmpeg?.kill();
    frames.close();
    _changed();
  }
}

class MirrorHost extends ChangeNotifier {
  final Store store;
  final sessions = <String, MirrorSession>{};
  ServerSocket? _server;
  MirrorHost(this.store);

  Future<void> start({int port = mirrorPort}) async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv6, port, v6Only: false);
    _server!.listen(_accept);
  }

  Future<void> stop() async {
    await _server?.close();
    for (final s in sessions.values.toList()) {
      s.close();
    }
  }

  void _accept(Socket sock) {
    if (!allowedPeer(sock.remoteAddress) || !store.get('phoneControlEnabled', true)) {
      sock.destroy();
      return;
    }
    sock.setOption(SocketOption.tcpNoDelay, true);
    MirrorSession? session;
    var buf = Uint8List(0);
    final hello = Timer(const Duration(seconds: 5), () => session == null ? sock.destroy() : null);
    sock.listen((chunk) {
      final data = Uint8List(buf.length + chunk.length)
        ..setAll(0, buf)
        ..setAll(buf.length, chunk);
      var off = 0;
      while (data.length - off >= 5) {
        final bd = ByteData.sublistView(data, off);
        final type = bd.getUint8(0), len = bd.getUint32(1);
        if (len > 8 << 20) return sock.destroy(); // nonsense length
        if (data.length - off - 5 < len) break;
        final payload = Uint8List.sublistView(data, off + 5, off + 5 + len);
        off += 5 + len;
        if (session == null) {
          // First frame must say which of my devices this is.
          final dev = type == 0 ? store.devices[(jsonDecode(utf8.decode(payload)) as Map)['id']] : null;
          if (dev == null) return sock.destroy();
          hello.cancel();
          sessions[dev.id]?.close();
          session = sessions[dev.id] = MirrorSession(dev, sock, () {
            if (sessions[dev.id]?.closed == true) sessions.remove(dev.id);
            notifyListeners();
          });
          session!._startDecoder();
          notifyListeners();
        } else if (type == 1) {
          final j = jsonDecode(utf8.decode(payload)) as Map;
          session!
            ..w = j['w']
            ..h = j['h']
            ..control = j['control'] == true;
          notifyListeners();
        } else if (type == 2) {
          session!._video(payload);
        }
      }
      buf = Uint8List.fromList(data.sublist(off));
    }, onDone: () => _end(session, sock), onError: (_) => _end(session, sock), cancelOnError: true);
  }

  void _end(MirrorSession? s, Socket sock) {
    if (s != null) {
      s.close();
    } else {
      sock.destroy();
    }
  }
}

// ---------------- phone side ----------------

const _channel = MethodChannel('myphone/mirror');

/// Asks Android for screen-capture consent, then streams to [pc]. False if the user declined.
Future<bool> startSharingTo(Device pc, String myId) async {
  final host = (pc.addr.isNotEmpty ? pc.addr : pc.host).split(':').first;
  return await _channel.invokeMethod<bool>('start', {'host': host, 'port': mirrorPort, 'id': myId}) ?? false;
}

Future<void> stopSharing() => _channel.invokeMethod('stop');

/// {control: accessibility enabled, sharing: session running}
Future<Map> mirrorStatus() async => Map.from(await _channel.invokeMethod('status') ?? const {});

Future<void> openControlSettings() => _channel.invokeMethod('openControlSettings');
