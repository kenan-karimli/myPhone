import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36) + Random().nextInt(1 << 30).toRadixString(36);

class Device {
  String id, name, kind, host, addr;
  Device({required this.id, required this.name, required this.kind, required this.host, this.addr = ''});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'kind': kind, 'host': host, 'addr': addr};
  factory Device.fromJson(Map j) => Device(id: j['id'], name: j['name'] ?? j['id'], kind: j['kind'] ?? 'desktop', host: j['host'] ?? '', addr: j['addr'] ?? '');
}

class Msg {
  final String id, kind; // kind: text | file | image
  final bool mine;
  final String text, name, path;
  final int size, ts;
  final Map? replyTo; // {who, text}
  final String by; // '' = the person; 'claude' = written/sent by Claude
  final Map<String, Set<String>> reacts = {}; // emoji -> {'me','them'}
  String status; // pending | sent (mine only)
  double? progress; // in-memory, while a file uploads
  Msg({required this.id, required this.kind, required this.mine, this.text = '', this.name = '', this.path = '', this.size = 0, required this.ts, this.replyTo, this.status = 'sent', this.by = ''});

  Map<String, dynamic> toJson() => {'t': 'msg', 'id': id, 'kind': kind, 'mine': mine, 'text': text, 'name': name, 'path': path, 'size': size, 'ts': ts, if (replyTo != null) 'replyTo': replyTo, 'status': status, if (by.isNotEmpty) 'by': by};
  factory Msg.fromJson(Map j) => Msg(id: j['id'], kind: j['kind'] ?? 'text', mine: j['mine'] == true, text: j['text'] ?? '', name: j['name'] ?? '', path: j['path'] ?? '', size: j['size'] ?? 0, ts: j['ts'] ?? 0, replyTo: j['replyTo'], status: j['status'] ?? 'sent', by: j['by'] ?? '');

  String get preview => kind == 'text' ? text : kind == 'image' ? 'Photo · $name' : name;
}

const imageExt = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'};
String kindForFile(String name) => imageExt.contains(name.split('.').last.toLowerCase()) ? 'image' : 'file';

String fmtSize(int b) => b < 1024 * 1024 ? '${max(1, (b / 1024).round())} KB' : b < 1024 * 1024 * 1024 ? '${(b / 1048576).toStringAsFixed(1)} MB' : '${(b / 1073741824).toStringAsFixed(2)} GB';

/// All persistent state. Chats and devices are append-only JSONL logs so the
/// Android background service and the UI isolate can both write without clobbering.
/// shortcut: logs are replayed in full on load and never compacted; fine for years of personal chat, compact if a log passes ~50 MB.
class Store extends ChangeNotifier {
  final Directory dir;
  Map<String, dynamic> settings = {};
  final Map<String, Device> devices = {};
  final Map<String, List<Msg>> _chats = {};
  final Map<String, int> _readTs = {};
  final Map<String, bool> online = {};
  final Map<String, DateTime> lastSeen = {};

  Store(this.dir);

  static Future<Store> open(Directory dir) async {
    await dir.create(recursive: true);
    final s = Store(dir);
    await s.reloadAll();
    return s;
  }

  File get _settingsFile => File('${dir.path}/settings.json');
  File get _devicesFile => File('${dir.path}/devices.jsonl');
  File _chatFile(String id) => File('${dir.path}/chat_${Uri.encodeComponent(id)}.jsonl');

  String get myId => settings['id'];
  String get myName => settings['name'];
  String get myKind => settings['kind'];
  Map<String, dynamic> get me => {'id': myId, 'name': myName, 'kind': myKind, if (myBattery != null) 'battery': myBattery};

  /// This device's battery ({level, charging}), refreshed by watchBattery(); null without one.
  Map<String, dynamic>? myBattery;
  final Map<String, Map> battery = {};
  void Function(String devId, Map b)? onLowBattery;

  void setBattery(String devId, Object? b) {
    if (b is! Map || b['level'] is! int) return;
    final old = battery[devId];
    battery[devId] = b;
    final low = b['level'] <= 15 && b['charging'] != true;
    final wasLow = old != null && old['level'] <= 15 && old['charging'] != true;
    if (low && !wasLow) onLowBattery?.call(devId, b);
    if (old == null || old['level'] != b['level'] || old['charging'] != b['charging']) notifyListeners();
  }

  Future<void> reloadAll() async {
    settings = _settingsFile.existsSync() ? jsonDecode(await _settingsFile.readAsString()) : {};
    if (settings['id'] == null) {
      settings.addAll({'id': newId(), 'name': Platform.localHostname, 'kind': _guessKind()});
      await saveSettings();
    }
    await reloadDevices();
    _chats.clear();
    notifyListeners();
  }

  static String _guessKind() {
    if (Platform.isAndroid || Platform.isIOS) return 'phone';
    return Directory('/sys/class/power_supply/BAT0').existsSync() ? 'laptop' : 'desktop';
  }

  /// Re-read settings written by the other isolate (UI vs background service).
  Future<void> reloadSettings() async {
    if (_settingsFile.existsSync()) settings = jsonDecode(await _settingsFile.readAsString());
  }

  Future<void> saveSettings() async {
    await _settingsFile.writeAsString(jsonEncode(settings));
    notifyListeners();
  }

  void set(String k, Object? v) {
    settings[k] = v;
    saveSettings();
  }

  T get<T>(String k, T def) => (settings[k] as T?) ?? def;

  Future<void> reloadDevices() async {
    devices.clear();
    for (final j in await _readLog(_devicesFile)) {
      if (j['t'] == 'removed') {
        devices.remove(j['id']);
      } else {
        devices[j['id']] = Device.fromJson(j);
      }
    }
    notifyListeners();
  }

  Future<void> upsertDevice(Device d) async {
    devices[d.id] = d;
    await _append(_devicesFile, d.toJson());
    notifyListeners();
  }

  Future<void> removeDevice(String id) async {
    devices.remove(id);
    await _append(_devicesFile, {'t': 'removed', 'id': id});
    notifyListeners();
  }

  Future<List<Map>> _readLog(File f) async {
    if (!f.existsSync()) return [];
    final out = <Map>[];
    for (final line in await f.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(jsonDecode(line));
      } catch (_) {} // a torn last line after a crash: skip it, keep the rest
    }
    return out;
  }

  Future<void> _append(File f, Map j) => f.writeAsString('${jsonEncode(j)}\n', mode: FileMode.append, flush: true);

  /// Chat for a device; loads from disk on first use.
  List<Msg> chat(String devId) => _chats[devId] ?? const [];

  Future<List<Msg>> loadChat(String devId) async {
    final list = <Msg>[];
    final byId = <String, Msg>{};
    var read = 0;
    for (final j in await _readLog(_chatFile(devId))) {
      switch (j['t']) {
        case 'msg':
          if (byId.containsKey(j['id'])) break;
          final m = Msg.fromJson(j);
          byId[m.id] = m;
          list.add(m);
        case 'react':
          final m = byId[j['id']];
          if (m == null) break;
          final set = m.reacts.putIfAbsent(j['e'], () => {});
          j['on'] == true ? set.add(j['by']) : set.remove(j['by']);
          if (set.isEmpty) m.reacts.remove(j['e']);
        case 'del':
          list.removeWhere((m) => m.id == j['id']);
          byId.remove(j['id']);
        case 'sent':
          byId[j['id']]?.status = 'sent';
        case 'read':
          read = max(read, j['ts'] as int);
      }
    }
    list.sort((a, b) => a.ts.compareTo(b.ts));
    _chats[devId] = list;
    _readTs[devId] = read;
    notifyListeners();
    return list;
  }

  Future<void> loadAllChats() async {
    for (final id in devices.keys.toList()) {
      await loadChat(id);
    }
  }

  Future<void> ensureChat(String devId) async {
    if (!_chats.containsKey(devId)) await loadChat(devId);
  }

  bool hasMsg(String devId, String msgId) => chat(devId).any((m) => m.id == msgId);

  Future<void> addMsg(String devId, Msg m) async {
    if (hasMsg(devId, m.id)) return;
    (_chats[devId] ??= []).add(m);
    await _append(_chatFile(devId), m.toJson());
    notifyListeners();
  }

  Future<void> logEvent(String devId, Map ev) async {
    await _append(_chatFile(devId), ev);
    await loadChat(devId);
  }

  Future<void> markSent(String devId, String msgId) async {
    final m = chat(devId).where((m) => m.id == msgId).firstOrNull;
    if (m == null || m.status == 'sent') return;
    m.status = 'sent';
    await _append(_chatFile(devId), {'t': 'sent', 'id': msgId});
    notifyListeners();
  }

  int unread(String devId) {
    final r = _readTs[devId] ?? 0;
    return chat(devId).where((m) => !m.mine && m.ts > r).length;
  }

  Future<void> markRead(String devId) async {
    if (unread(devId) == 0) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _readTs[devId] = ts;
    await _append(_chatFile(devId), {'t': 'read', 'ts': ts});
    notifyListeners();
  }

  void setPresence(String devId, bool on) {
    if (on) lastSeen[devId] = DateTime.now();
    if (online[devId] == on) return;
    online[devId] = on;
    notifyListeners();
  }

  void touch() => notifyListeners();
}
