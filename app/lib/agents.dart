import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'store.dart';

/// Claude Code agents hosted on this PC, driven from the phone.
///
/// Each agent is the user's own `claude` CLI in headless stream-json mode. Risky tool
/// calls come back as permission requests and wait until the phone answers Allow / Deny.
/// Recent sessions are read from Claude Code's own transcripts in ~/.claude/projects.

String get _home => Platform.environment['HOME'] ?? '/';
Directory get _projectsDir => Directory('$_home/.claude/projects');

String? findClaude() {
  for (final dir in [...(Platform.environment['PATH'] ?? '').split(':'), '$_home/.local/bin', '$_home/.claude/local', '/usr/local/bin', '/usr/bin']) {
    final f = File('$dir/claude');
    if (dir.isNotEmpty && f.existsSync()) return f.path;
  }
  return null;
}

String _short(Object? v, [int max = 400]) {
  final s = v is String ? v : jsonEncode(v);
  return s.length > max ? '${s.substring(0, max)}…' : s;
}

/// One line describing a tool call: the command, the file, or the input.
String toolSummary(String name, Map input) => switch (name) {
      'Bash' => input['command'] ?? '',
      'Read' || 'Write' || 'Edit' || 'NotebookEdit' => input['file_path'] ?? input['notebook_path'] ?? '',
      'Glob' || 'Grep' => '${input['pattern'] ?? ''}${input['path'] != null ? '  in ${input['path']}' : ''}',
      'WebFetch' => input['url'] ?? '',
      'WebSearch' => input['query'] ?? '',
      'Task' || 'Agent' => input['description'] ?? input['prompt'] ?? '',
      _ => _short(input, 200),
    };

/// Converts Claude Code JSON (live stream or saved transcript) into simple chat events:
/// user / text / tool / tool_result / result.
List<Map<String, dynamic>> normalize(Map j) {
  final out = <Map<String, dynamic>>[];
  final ts = DateTime.tryParse(j['timestamp'] ?? '')?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch;
  switch (j['type']) {
    case 'user':
      if (j['isMeta'] == true || j['isSidechain'] == true) break;
      final c = j['message']?['content'];
      if (c is String) {
        if (!c.startsWith('<')) out.add({'k': 'user', 'text': c, 'ts': ts}); // skip <command-…> / <local-command…> wrappers
      } else if (c is List) {
        for (final p in c) {
          if (p is! Map) continue;
          if (p['type'] == 'text' && !(p['text'] as String? ?? '').startsWith('<')) out.add({'k': 'user', 'text': p['text'], 'ts': ts});
          if (p['type'] == 'tool_result') {
            final content = p['content'];
            final text = content is String ? content : content is List ? content.whereType<Map>().map((e) => e['text'] ?? '').join('\n') : '';
            out.add({'k': 'tool_result', 'id': p['tool_use_id'], 'ok': p['is_error'] != true, 'preview': _short(text, 600), 'ts': ts});
          }
          if (p['type'] == 'image') out.add({'k': 'user', 'text': '🖼 image', 'ts': ts});
        }
      }
    case 'assistant':
      if (j['isSidechain'] == true) break;
      for (final p in (j['message']?['content'] as List? ?? const [])) {
        if (p is! Map) continue;
        if (p['type'] == 'text' && (p['text'] as String? ?? '').trim().isNotEmpty) out.add({'k': 'text', 'text': p['text'], 'ts': ts});
        if (p['type'] == 'tool_use') out.add({'k': 'tool', 'id': p['id'], 'name': p['name'], 'summary': _short(toolSummary(p['name'] ?? '', p['input'] as Map? ?? {}), 600), 'ts': ts});
      }
    case 'result':
      out.add({'k': 'result', 'ok': j['subtype'] == 'success' && j['is_error'] != true, 'ms': j['duration_ms'], 'cost': j['total_cost_usd'], 'ts': ts});
  }
  return out;
}

class AgentSession {
  final String key; // stable id the phone uses (Claude's session id once known)
  String? sessionId;
  final String cwd;
  String title;
  String status = 'idle'; // idle | working | approval | error
  String? owner; // device that started it; gets alerts
  bool external = false; // running in a terminal on the PC: view only
  int updated = DateTime.now().millisecondsSinceEpoch;
  final events = <Map<String, dynamic>>[];
  final pending = <String, Map>{}; // request id -> can_use_tool request
  Process? proc;
  Completer<void> _changed = Completer();

  AgentSession(this.key, this.cwd, this.title, {this.sessionId});

  void add(Map<String, dynamic> e) {
    e['n'] = events.length;
    events.add(e);
    poke();
  }

  void poke() {
    updated = DateTime.now().millisecondsSinceEpoch;
    if (!_changed.isCompleted) _changed.complete();
    _changed = Completer();
  }

  Future<void> changed(Duration max) => _changed.future.timeout(max, onTimeout: () {});

  Map<String, dynamic> info() => {
        'id': key,
        'cwd': cwd,
        'project': cwd.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/',
        'title': title,
        'status': external ? 'terminal' : status,
        'ts': updated,
        'live': proc != null,
      };
}

class AgentHost {
  final Store store;
  /// Sends an alert ("needs approval" / "finished") to the device that started an agent.
  final void Function(String deviceId, Map event) alert;
  final sessions = <String, AgentSession>{};
  final String? claudePath; // tests point this at a fake CLI
  AgentHost(this.store, {required this.alert, this.claudePath});

  // ---------- discovery ----------

  /// Recent Claude Code sessions on this PC, newest first.
  Future<List<Map<String, dynamic>>> recent({int limit = 40}) async {
    if (!_projectsDir.existsSync()) return [];
    final files = <File>[];
    await for (final d in _projectsDir.list()) {
      if (d is! Directory) continue;
      await for (final f in d.list()) {
        if (f is File && f.path.endsWith('.jsonl')) files.add(f);
      }
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    final running = await _terminalSessions();
    final out = <Map<String, dynamic>>[];
    for (final f in files.take(limit)) {
      final id = f.uri.pathSegments.last.replaceAll('.jsonl', '');
      if (sessions.containsKey(id)) continue;
      final meta = await _meta(f);
      if (meta == null) continue;
      out.add({
        'id': id,
        'cwd': meta.$1,
        'project': meta.$1.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/',
        'title': meta.$2,
        'status': running.contains(meta.$1) && DateTime.now().difference(f.lastModifiedSync()).inMinutes < 30 ? 'terminal' : 'idle',
        'ts': f.lastModifiedSync().millisecondsSinceEpoch,
        'live': false,
      });
    }
    return out;
  }

  /// (cwd, title) from a transcript; reads only the first ~200 lines plus the last 64 KB.
  Future<(String, String)?> _meta(File f) async {
    String? cwd, title, firstPrompt;
    try {
      var n = 0;
      await for (final line in f.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
        if (++n > 200) break;
        if (!line.contains('"cwd"') && !line.contains('ai-title')) continue;
        final j = jsonDecode(line);
        cwd ??= j['cwd'];
        if (j['type'] == 'ai-title') title = j['aiTitle'];
        if (firstPrompt == null && j['type'] == 'user' && j['isMeta'] != true) {
          final c = j['message']?['content'];
          if (c is String && !c.startsWith('<')) firstPrompt = c;
        }
      }
      final len = await f.length();
      final tail = await f.openRead(len > 65536 ? len - 65536 : 0).transform(utf8.decoder).join();
      for (final line in tail.split('\n').reversed) {
        if (line.contains('"ai-title"')) {
          try {
            title = jsonDecode(line)['aiTitle'];
            break;
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (cwd == null) return null;
    return (cwd, (title ?? firstPrompt ?? 'Session').split('\n').first);
  }

  /// Working folders of `claude` processes started from a terminal (not by us).
  Future<Set<String>> _terminalSessions() async {
    final out = <String>{};
    final mine = sessions.values.map((s) => s.proc?.pid).whereType<int>().toSet();
    try {
      await for (final p in Directory('/proc').list()) {
        final pid = int.tryParse(p.uri.pathSegments.where((s) => s.isNotEmpty).last);
        if (pid == null || mine.contains(pid)) continue;
        try {
          final cmd = File('/proc/$pid/cmdline').readAsStringSync().split('\x00');
          if (cmd.isEmpty || !cmd.first.endsWith('claude') || cmd.contains('-p') || cmd.contains('--print')) continue;
          out.add(Link('/proc/$pid/cwd').targetSync());
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  Future<List<Map<String, dynamic>>> projects() async {
    final seen = <String, int>{};
    for (final s in await recent(limit: 200)) {
      seen[s['cwd']] = (seen[s['cwd']] ?? 0) > (s['ts'] as int) ? seen[s['cwd']]! : s['ts'];
    }
    for (final s in sessions.values.toSet()) {
      seen[s.cwd] = s.updated;
    }
    final l = seen.entries.where((e) => Directory(e.key).existsSync()).toList()..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in l) {'path': e.key, 'name': e.key == _home ? 'Home' : e.key.split('/').last, 'ts': e.value}];
  }

  Future<Map<String, dynamic>> list() async => {
        'available': (claudePath ?? findClaude()) != null,
        'sessions': [...sessions.values.toSet().map((s) => s.info()).toList()..sort((a, b) => (b['ts'] as int).compareTo(a['ts'] as int)), ...await recent()],
        'projects': await projects(),
      };

  /// Opens a session for viewing: one of ours, or a saved transcript.
  Future<AgentSession?> open(String id) async {
    final have = sessions[id];
    if (have != null) {
      if (have.external) await _reloadTranscript(have);
      return have;
    }
    final f = await _transcript(id);
    if (f == null) return null;
    final meta = await _meta(f);
    if (meta == null) return null;
    final s = AgentSession(id, meta.$1, meta.$2, sessionId: id);
    final running = await _terminalSessions();
    s.external = running.contains(meta.$1) && DateTime.now().difference(f.lastModifiedSync()).inMinutes < 30;
    sessions[id] = s;
    await _reloadTranscript(s);
    return s;
  }

  Future<File?> _transcript(String id) async {
    if (!_projectsDir.existsSync() || id.contains('/')) return null;
    await for (final d in _projectsDir.list()) {
      final f = File('${d.path}/$id.jsonl');
      if (f.existsSync()) return f;
    }
    return null;
  }

  Future<void> _reloadTranscript(AgentSession s) async {
    final f = await _transcript(s.sessionId ?? s.key);
    if (f == null) return;
    final evs = <Map<String, dynamic>>[];
    await for (final line in f.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('{"') || !(line.contains('"type":"user"') || line.contains('"type":"assistant"'))) continue;
      try {
        evs.addAll(normalize(jsonDecode(line)));
      } catch (_) {}
    }
    if (evs.length == s.events.length) return;
    s.events
      ..clear()
      ..addAll([for (var i = 0; i < evs.length; i++) evs[i]..['n'] = i]);
    s.poke();
  }

  // ---------- running ----------

  Future<AgentSession> start(String cwd, String prompt, String owner) async {
    if (!Directory(cwd).existsSync()) throw ArgumentError('No such folder: $cwd');
    final s = AgentSession('new-${newId()}', cwd, prompt.split('\n').first)..owner = owner;
    sessions[s.key] = s;
    await _spawn(s);
    _say(s, prompt);
    return s;
  }

  Future<void> send(String id, String text, String owner) async {
    final s = sessions[id] ?? await open(id);
    if (s == null) throw ArgumentError('Unknown session');
    if (s.external) throw StateError('This session is open in a terminal on the PC.');
    s.owner = owner;
    if (s.proc == null) await _spawn(s);
    _say(s, text);
  }

  void _say(AgentSession s, String text) {
    s.add({'k': 'user', 'text': text, 'ts': DateTime.now().millisecondsSinceEpoch});
    s.status = 'working';
    s.proc!.stdin.writeln(jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': text}}));
  }

  Future<void> _spawn(AgentSession s) async {
    final exe = claudePath ?? findClaude();
    if (exe == null) throw StateError('Claude Code is not installed on this PC.');
    final p = await Process.start(exe, [
      '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose',
      '--permission-prompts', 'host', '--permission-prompt-tool', 'stdio',
      '--disallowedTools', 'AskUserQuestion', // it asks in plain text instead
      if (s.sessionId != null) ...['--resume', s.sessionId!],
    ], workingDirectory: s.cwd);
    s.proc = p;
    // Must come first, or permission prompts are never sent to us.
    p.stdin.writeln(jsonEncode({'type': 'control_request', 'request_id': 'init', 'request': {'subtype': 'initialize', 'hooks': null}}));
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => _line(s, l));
    p.stderr.transform(utf8.decoder).listen((e) {
      if (e.trim().isNotEmpty) s.add({'k': 'error', 'text': _short(e.trim(), 400), 'ts': DateTime.now().millisecondsSinceEpoch});
    });
    p.exitCode.then((code) {
      if (s.proc != p) return;
      s.proc = null;
      s.pending.clear();
      if (s.status == 'working' || s.status == 'approval') s.status = code == 0 ? 'idle' : 'error';
      s.poke();
    });
  }

  void _line(AgentSession s, String line) {
    Map j;
    try {
      j = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (j['session_id'] is String && s.sessionId == null) {
      s.sessionId = j['session_id'];
      sessions[s.sessionId!] = s; // reachable by both ids
    }
    if (j['type'] == 'control_request' && j['request']?['subtype'] == 'can_use_tool') {
      final req = j['request'] as Map;
      final rid = j['request_id'] as String;
      s.pending[rid] = req;
      s.status = 'approval';
      final summary = _short(toolSummary(req['tool_name'] ?? '', req['input'] as Map? ?? {}), 600);
      s.add({'k': 'approve', 'rid': rid, 'name': req['tool_name'], 'summary': summary, 'state': 'pending', 'ts': DateTime.now().millisecondsSinceEpoch});
      if (s.owner != null) alert(s.owner!, {'t': 'agent', 'kind': 'approve', 'sid': s.key, 'rid': rid, 'title': s.title, 'text': '${req['tool_name']}: $summary'});
      return;
    }
    for (final e in normalize(j)) {
      s.add(e);
      if (e['k'] == 'result') {
        s.status = e['ok'] == true ? 'idle' : 'error';
        final last = s.events.lastWhere((x) => x['k'] == 'text', orElse: () => {'text': 'Finished'});
        if (s.owner != null) alert(s.owner!, {'t': 'agent', 'kind': 'done', 'sid': s.key, 'title': s.title, 'text': _short(last['text'], 200)});
      }
    }
  }

  void approve(String id, String rid, bool allow) {
    final s = sessions[id];
    final req = s?.pending.remove(rid);
    if (s == null || req == null || s.proc == null) return;
    s.proc!.stdin.writeln(jsonEncode({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': rid,
        'response': allow ? {'behavior': 'allow', 'updatedInput': req['input'] ?? {}} : {'behavior': 'deny', 'message': 'Denied from the phone.'},
      },
    }));
    for (final e in s.events.where((e) => e['k'] == 'approve' && e['rid'] == rid)) {
      e['state'] = allow ? 'allowed' : 'denied';
    }
    s.status = s.pending.isEmpty ? 'working' : 'approval';
    s.add({'k': 'decided', 'rid': rid, 'allow': allow, 'ts': DateTime.now().millisecondsSinceEpoch});
  }

  void stop(String id) {
    final s = sessions[id];
    if (s?.proc == null) return;
    s!.proc!.kill(ProcessSignal.sigint);
    s.status = 'idle';
    s.add({'k': 'error', 'text': 'Stopped from the phone.', 'ts': DateTime.now().millisecondsSinceEpoch});
  }

  void dispose() {
    for (final s in sessions.values) {
      s.proc?.kill();
    }
  }

  // ---------- HTTP (called by Node for known devices only) ----------

  Future<bool> handle(HttpRequest req, Device from) async {
    final seg = req.uri.pathSegments;
    if (seg.isEmpty || seg.first != 'agents') return false;
    final res = req.response;
    res.headers.contentType = ContentType.json;
    Future<Map> body() async => jsonDecode(await utf8.decodeStream(req)) as Map;
    try {
      if (!store.get('agentsEnabled', true)) {
        res.statusCode = 403;
        res.write(jsonEncode({'error': 'Claude agents are turned off in this PC\'s settings.'}));
        return true;
      }
      if (seg.length == 1 && req.method == 'GET') {
        res.write(jsonEncode(await list()));
      } else if (seg.length == 2 && seg[1] == 'start' && req.method == 'POST') {
        final b = await body();
        var prompt = (b['prompt'] as String?) ?? '';
        // Files the phone just sent: tell Claude where they are on this PC.
        final ids = List<String>.from(b['attach'] ?? const []);
        if (ids.isNotEmpty) {
          await store.ensureChat(from.id);
          final paths = [for (final m in store.chat(from.id)) if (ids.contains(m.id) && m.path.isNotEmpty) m.path];
          if (paths.isNotEmpty) prompt = '${prompt.trim().isEmpty ? 'Take a look at these files.' : prompt.trim()}\n\nFiles I sent from my phone (on this PC):\n${paths.map((p) => '- $p').join('\n')}';
        }
        final s = await start(b['cwd'], prompt, from.id);
        res.write(jsonEncode({'id': s.key}));
      } else if (seg.length >= 3 && seg[1] == 's') {
        final id = seg[2];
        final action = seg.length > 3 ? seg[3] : '';
        if (action == 'events' && req.method == 'GET') {
          final s = await open(id);
          if (s == null) {
            res.statusCode = 404;
            res.write(jsonEncode({'error': 'Session not found'}));
            return true;
          }
          final after = int.tryParse(req.uri.queryParameters['after'] ?? '') ?? 0;
          final sinceUpdate = int.tryParse(req.uri.queryParameters['v'] ?? '') ?? 0;
          if (s.events.length <= after && s.updated <= sinceUpdate) await s.changed(const Duration(seconds: 20));
          if (s.external) await _reloadTranscript(s);
          // Approval cards change state in place, so resend those too.
          final out = [for (final e in s.events) if ((e['n'] as int) >= after || e['k'] == 'approve') e];
          res.write(jsonEncode({'events': out, 'next': s.events.length, 'v': s.updated, ...s.info()}));
        } else if (action == 'send' && req.method == 'POST') {
          await send(id, (await body())['text'], from.id);
          res.write('{}');
        } else if (action == 'approve' && req.method == 'POST') {
          final b = await body();
          approve(id, b['rid'], b['allow'] == true);
          res.write('{}');
        } else if (action == 'stop' && req.method == 'POST') {
          stop(id);
          res.write('{}');
        } else {
          res.statusCode = 404;
        }
      } else {
        res.statusCode = 404;
      }
    } catch (e) {
      res.statusCode = 400;
      res.write(jsonEncode({'error': e is ArgumentError ? e.message : e.toString()}));
    }
    return true;
  }
}
