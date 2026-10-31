import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'store.dart';

const port = 4747;

/// Only my own tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48) and localhost may talk to me.
bool allowedPeer(InternetAddress a) {
  final ip = InternetAddress(_ip(a)); // unwrap IPv4-mapped (::ffff:x.x.x.x)
  if (ip.isLoopback) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) return b[0] == 100 && (b[1] & 0xC0) == 64;
  return b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0;
}

String _ip(InternetAddress a) => a.address.startsWith('::ffff:') ? a.address.substring(7) : a.address;

Uri _url(String host, String path, [Map<String, String>? q]) {
  final h = host.contains(':') ? host : '$host:$port';
  return Uri.parse('http://$h$path').replace(queryParameters: q);
}

/// Incoming side. One per device (in the Android background service, or in the app).
class Node {
  final Store store;
  final Future<Directory> Function() saveDir;
  final void Function(Device dev, Msg? msg) onIncoming;
  final void Function(List<String> paths)? onShare; // desktop "Send via myPhone"
  final Future<bool> Function(HttpRequest req, Device from)? extraRoutes; // PC: Claude agents
  final Future<bool> Function(HttpRequest req)? localRoutes; // loopback only: tools on this machine
  final void Function(Device from, Map event)? onAgent; // phone: agent alerts
  HttpServer? _server;
  Node(this.store, {required this.saveDir, required this.onIncoming, this.onShare, this.extraRoutes, this.onAgent, this.localRoutes});

  Future<void> start({int listenPort = port}) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv6, listenPort, v6Only: false);
    _server!.listen(_handle);
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final remote = req.connectionInfo!.remoteAddress;
      if (!allowedPeer(remote)) {
        res.statusCode = 403;
        return;
      }
      final path = req.uri.path;
      // Local-only: lets the file manager hand files to this app. Never from the tailnet,
      // or another device could make this PC send its own files.
      if (req.method == 'POST' && path == '/share') {
        if (!InternetAddress(_ip(remote)).isLoopback || onShare == null) {
          res.statusCode = 403;
          return;
        }
        final paths = const LineSplitter().convert(await utf8.decodeStream(req)).where((p) => p.isNotEmpty && FileSystemEntity.isFileSync(p)).toList();
        if (paths.isNotEmpty) onShare!(paths);
        return;
      }
      if (path.startsWith('/local/')) {
        if (!InternetAddress(_ip(remote)).isLoopback || localRoutes == null || !await localRoutes!(req)) res.statusCode = 403;
        return;
      }
      if (req.method == 'POST' && path == '/hello') {
        final j = jsonDecode(await utf8.decodeStream(req));
        final old = store.devices[j['id']];
        final hostHint = (j['port'] != null && j['port'] != port) ? '${_ip(remote)}:${j['port']}' : _ip(remote);
        final d = Device(id: j['id'], name: j['name'], kind: j['kind'], host: old?.host.isNotEmpty == true ? old!.host : hostHint, addr: hostHint);
        if (old == null || old.name != d.name || old.kind != d.kind || old.addr != d.addr) {
          await store.upsertDevice(d);
          if (old == null) onIncoming(d, null);
        }
        store.setPresence(d.id, true);
        store.setBattery(d.id, j['battery']);
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(store.me));
        return;
      }
      final dev = store.devices[req.headers.value('x-from')];
      if (dev == null) {
        res.statusCode = 401; // unknown device: must /hello first
        return;
      }
      store.setPresence(dev.id, true);
      if (extraRoutes != null && await extraRoutes!(req, dev)) return;
      await store.ensureChat(dev.id);
      if (req.method == 'POST' && path == '/event') {
        final ev = jsonDecode(await utf8.decodeStream(req)) as Map;
        await _event(dev, ev);
      } else if (req.method == 'PUT' && path == '/file') {
        final q = req.uri.queryParameters;
        final id = q['id']!;
        if (store.hasMsg(dev.id, id)) {
          await req.drain();
          return;
        }
        final name = _safeName(q['name'] ?? 'file');
        final dir = await saveDir();
        await dir.create(recursive: true);
        final tmp = File('${dir.path}/.$id.part');
        final sink = tmp.openWrite();
        await req.cast<List<int>>().pipe(sink);
        final expected = int.tryParse(q['size'] ?? '');
        if (expected != null && await tmp.length() != expected) {
          await tmp.delete();
          res.statusCode = 400; // truncated upload; sender retries
          return;
        }
        final dest = await _unique(dir, name);
        await tmp.rename(dest.path);
        final m = Msg(id: id, kind: kindForFile(name), mine: false, name: name, path: dest.path, size: await dest.length(), ts: int.tryParse(q['ts'] ?? '') ?? DateTime.now().millisecondsSinceEpoch, replyTo: q['reply'] != null ? jsonDecode(q['reply']!) : null, by: q['by'] ?? '');
        await store.addMsg(dev.id, m);
        onIncoming(dev, m);
      } else {
        res.statusCode = 404;
      }
    } catch (e) {
      res.statusCode = 500;
    } finally {
      try {
        await res.close();
      } catch (_) {} // detached (screen stream) or client already gone
    }
  }

  Future<void> _event(Device dev, Map ev) async {
    switch (ev['t']) {
      case 'msg':
        if (store.hasMsg(dev.id, ev['id'])) return;
        final m = Msg(id: ev['id'], kind: 'text', mine: false, text: ev['text'] ?? '', ts: ev['ts'] ?? DateTime.now().millisecondsSinceEpoch, replyTo: ev['replyTo'], by: ev['by'] ?? '');
        await store.addMsg(dev.id, m);
        onIncoming(dev, m);
      case 'agent' || 'mirror' || 'clip' || 'ring':
        onAgent?.call(dev, ev);
      case 'react':
        await store.logEvent(dev.id, {'t': 'react', 'id': ev['id'], 'e': ev['e'], 'by': 'them', 'on': ev['on'] == true});
        onIncoming(dev, null);
    }
  }

  static String _safeName(String n) {
    final s = n.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'[\x00-\x1f]'), '');
    return s.isEmpty || s == '.' || s == '..' ? 'file' : s;
  }

  static Future<File> _unique(Directory dir, String name) async {
    var f = File('${dir.path}/$name');
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; f.existsSync(); i++) {
      f = File('${dir.path}/$base ($i)$ext');
    }
    return f;
  }
}

/// Outgoing side.
class Client {
  final Store store;
  final int myPort;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  Client(this.store, {this.myPort = port});

  List<String> _hosts(Device d) => {if (d.addr.isNotEmpty) d.addr, if (d.host.isNotEmpty) d.host}.toList();

  Future<T> _try<T>(Device d, Future<T> Function(String host) f) async {
    Object? err;
    for (final h in _hosts(d)) {
      try {
        return await f(h);
      } catch (e) {
        err = e;
      }
    }
    throw err ?? StateError('no address');
  }

  /// Introduce myself to [host]; returns the device found there.
  Future<Device> hello(String host) async {
    final req = await _http.postUrl(_url(host, '/hello'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({...store.me, 'port': myPort}));
    final res = await req.close().timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) throw HttpException('hello ${res.statusCode}');
    final j = jsonDecode(await utf8.decodeStream(res));
    store.setBattery(j['id'], j['battery']);
    return Device(id: j['id'], name: j['name'], kind: j['kind'], host: host, addr: host);
  }

  Future<void> _post(Device d, Map ev) => _try(d, (h) async {
        final req = await _http.postUrl(_url(h, '/event'));
        req.headers.contentType = ContentType.json;
        req.headers.set('x-from', store.myId);
        req.write(jsonEncode(ev));
        final res = await req.close().timeout(const Duration(seconds: 10));
        await res.drain();
        if (res.statusCode != 200) throw HttpException('event ${res.statusCode}');
      });

  Future<void> _put(Device d, Msg m) => _try(d, (h) async {
        final f = File(m.path);
        final len = await f.length();
        final req = await _http.openUrl('PUT', _url(h, '/file', {'id': m.id, 'name': m.name, 'size': '$len', 'ts': '${m.ts}', if (m.replyTo != null) 'reply': jsonEncode(m.replyTo), if (m.by.isNotEmpty) 'by': m.by}));
        req.headers.set('x-from', store.myId);
        req.contentLength = len;
        var sent = 0, lastPaint = 0;
        await req.addStream(f.openRead().map((chunk) {
          sent += chunk.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastPaint > 80) {
            lastPaint = now;
            m.progress = sent / len;
            store.touch();
          }
          return chunk;
        }));
        final res = await req.close();
        await res.drain();
        if (res.statusCode != 200) throw HttpException('file ${res.statusCode}');
      });

  /// JSON request to another device (agents API). Throws with the server's error message.
  Future<Map> call(Device d, String method, String path, {Map? body, Duration timeout = const Duration(seconds: 30)}) => _try(d, (h) async {
        final req = await _http.openUrl(method, _url(h, path));
        req.headers.set('x-from', store.myId);
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close().timeout(timeout);
        final text = await utf8.decodeStream(res).timeout(timeout);
        final j = text.isEmpty ? {} : jsonDecode(text) as Map;
        if (res.statusCode != 200) throw HttpException(j['error'] ?? 'Error ${res.statusCode}');
        return j;
      });

  /// Live screen of another device: a stream of JPEG frames until cancelled.
  Stream<Uint8List> screen(Device d, String quality) {
    late StreamController<Uint8List> out;
    StreamSubscription? sub;
    out = StreamController<Uint8List>(
      onListen: () async {
        try {
          final res = await _try(d, (h) async {
            final req = await _http.getUrl(_url(h, '/screen', {'q': quality}));
            req.headers.set('x-from', store.myId);
            final r = await req.close();
            if (r.statusCode != 200) {
              final t = await utf8.decodeStream(r);
              String msg = 'Error ${r.statusCode}';
              try {
                msg = jsonDecode(t)['error'] ?? msg;
              } catch (_) {}
              throw HttpException(msg);
            }
            return r;
          });
          if (out.isClosed) return;
          var rest = Uint8List(0);
          sub = res.listen((chunk) {
            final data = Uint8List(rest.length + chunk.length)
              ..setAll(0, rest)
              ..setAll(rest.length, chunk);
            var off = 0;
            while (data.length - off >= 4) {
              final n = ByteData.sublistView(data, off, off + 4).getUint32(0);
              if (data.length - off - 4 < n) break;
              if (n > 0) out.add(Uint8List.sublistView(data, off + 4, off + 4 + n)); // 0 = keep-alive
              off += 4 + n;
            }
            rest = Uint8List.sublistView(data, off);
          }, onError: out.addError, onDone: out.close);
        } catch (e) {
          if (!out.isClosed) {
            out.addError(e);
            await out.close();
          }
        }
      },
      onCancel: () => sub?.cancel(), // closes the connection right away
    );
    return out.stream;
  }

  /// Fire-and-forget event (agent alerts).
  Future<void> sendEvent(Device d, Map ev) => _post(d, ev);

  final _inFlight = <String>{};

  /// Deliver one of my messages; leaves it pending on failure (retried later).
  Future<bool> deliver(Device d, Msg m) async {
    if (!_inFlight.add(m.id)) return false;
    try {
      if (m.kind == 'text') {
        await _post(d, {'t': 'msg', 'id': m.id, 'text': m.text, 'ts': m.ts, if (m.replyTo != null) 'replyTo': m.replyTo, if (m.by.isNotEmpty) 'by': m.by});
      } else {
        await _put(d, m);
      }
      m.progress = null;
      await store.markSent(d.id, m.id);
      store.setPresence(d.id, true);
      return true;
    } catch (_) {
      m.progress = null;
      store.touch();
      return false;
    } finally {
      _inFlight.remove(m.id);
    }
  }

  Future<Msg> sendText(Device d, String text, {Map? replyTo, String by = ''}) async {
    final m = Msg(id: newId(), kind: 'text', mine: true, text: text, ts: DateTime.now().millisecondsSinceEpoch, replyTo: replyTo, status: 'pending', by: by);
    await store.addMsg(d.id, m);
    unawaited(deliver(d, m));
    return m;
  }

  Future<Msg> sendFile(Device d, String path, {Map? replyTo, String by = ''}) async {
    final name = path.split(Platform.pathSeparator).last;
    final m = Msg(id: newId(), kind: kindForFile(name), mine: true, name: name, path: path, size: await File(path).length(), ts: DateTime.now().millisecondsSinceEpoch, replyTo: replyTo, status: 'pending', by: by)..progress = 0;
    await store.addMsg(d.id, m);
    unawaited(deliver(d, m));
    return m;
  }

  Future<void> react(Device d, String msgId, String emoji) async {
    final m = store.chat(d.id).firstWhere((m) => m.id == msgId);
    final on = !(m.reacts[emoji]?.contains('me') ?? false);
    final ev = {'t': 'react', 'id': msgId, 'e': emoji, 'on': on};
    await store.logEvent(d.id, {...ev, 'by': 'me'});
    // shortcut: reactions are fire-and-forget (not queued when the device is offline).
    unawaited(_post(d, ev).catchError((_) {}));
  }

  /// Ping every device, resend pending messages to the ones that answer.
  Future<void> sweep() async {
    await Future.wait(store.devices.values.toList().map((d) async {
      try {
        final got = await _try(d, hello);
        store.setPresence(d.id, true);
        if (got.name != d.name || got.kind != d.kind) await store.upsertDevice(d..name = got.name..kind = got.kind);
        for (final m in store.chat(d.id).where((m) => m.mine && m.status == 'pending').toList()) {
          await deliver(d, m);
        }
      } catch (_) {
        store.setPresence(d.id, false);
      }
    }));
  }

  Timer? _timer;
  void startSweeping() {
    sweep();
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => sweep());
  }

  void close() {
    _timer?.cancel();
    _http.close(force: true);
  }
}
