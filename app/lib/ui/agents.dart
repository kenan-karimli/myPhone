import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import '../store.dart';
import '../tokens.dart';
import 'screen_view.dart';
import 'widgets.dart';

const _mono = 'monospace';

String _ago(int ts) {
  final m = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts)).inMinutes;
  return m < 1 ? 'now' : m < 60 ? '${m}m' : m < 1440 ? '${m ~/ 60}h' : timeLabel(ts);
}

(String, bool) _statusLabel(String s) => switch (s) {
      'working' => ('Working', true),
      'approval' => ('Needs approval', true),
      'terminal' => ('In terminal', false),
      'error' => ('Stopped', false),
      _ => ('Idle', false),
    };

Route<T> agentRoute<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: Motion.d(380),
      reverseTransitionDuration: Motion.d(300),
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, a, _, child) {
        final c = CurvedAnimation(parent: a, curve: Motion.curve);
        return FadeTransition(opacity: c, child: SlideTransition(position: Tween(begin: const Offset(.06, 0), end: Offset.zero).animate(c), child: child));
      },
    );

/// All Claude Code sessions on a PC: running ones first, then recent.
class AgentsPage extends StatefulWidget {
  final Device pc;
  const AgentsPage({super.key, required this.pc});
  @override
  State<AgentsPage> createState() => _AgentsPageState();
}

class _AgentsPageState extends State<AgentsPage> {
  Map? _data;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await client.call(widget.pc, 'GET', '/agents');
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is HttpException ? e.message : '${widget.pc.name} isn’t reachable right now.');
    }
  }

  void _open(Map s) => Navigator.of(context).push(agentRoute(AgentSessionPage(pc: widget.pc, id: s['id'], title: s['title'] ?? 'Session')));

  Future<void> _new() async {
    final id = await showNewAgentSheet(context, widget.pc, List<Map>.from(_data?['projects'] ?? const []));
    if (id != null && mounted) {
      _load();
      Navigator.of(context).push(agentRoute(AgentSessionPage(pc: widget.pc, id: id.$1, title: id.$2)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final sessions = List<Map>.from(_data?['sessions'] ?? const []);
    final active = sessions.where((s) => s['status'] != 'idle' && s['status'] != 'error' || s['live'] == true).toList();
    final recent = sessions.where((s) => !active.contains(s)).toList();

    Widget body;
    if (_data == null && _error == null) {
      body = Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: c.text, strokeCap: StrokeCap.round)));
    } else if (_data == null) {
      body = _Empty(icon: 'error', title: 'Can’t reach ${widget.pc.name}', text: _error!);
    } else if (_data!['available'] != true) {
      body = _Empty(icon: 'assistant', title: 'Claude Code isn’t installed', text: 'Install Claude Code on ${widget.pc.name} and sign in once. Then come back here.');
    } else {
      body = RefreshIndicator(
        color: c.text,
        backgroundColor: c.surface,
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 24), children: [
          if (active.isNotEmpty) ...[const _Label('Active'), for (final s in active) _AgentRow(s, onTap: () => _open(s))],
          const _Label('Recent'),
          if (recent.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text('No sessions yet. Start one with +.', style: mpStyle(context, color: c.text2))),
          for (final s in recent) _AgentRow(s, onTap: () => _open(s)),
        ]),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: Row(children: [
              IconBtn('back', iconSize: 24, onTap: () => Navigator.pop(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Claude', style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
                  Text('on ${widget.pc.name}', style: mpStyle(context, size: MpText.meta, color: c.text2)),
                ]),
              ),
              IconBtn('add', bg: c.text, color: c.bg, onTap: _data?['available'] == true ? _new : null, tip: 'New agent'),
            ]),
          ),
          Expanded(child: AnimatedSwitcher(duration: Motion.d(260), child: KeyedSubtree(key: ValueKey(_data == null ? _error : 'list'), child: body))),
        ]),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String t;
  const _Label(this.t);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Text(t.toUpperCase(), style: mpStyle(context, size: MpText.meta, w: FontWeight.w700, color: MpColors.of(context).text2).copyWith(letterSpacing: .8)),
      );
}

class _Empty extends StatelessWidget {
  final String icon, title, text;
  const _Empty({required this.icon, required this.title, required this.text});
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    return Center(
      child: EnterAnim(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 0, 40, 64),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 72, height: 72, decoration: BoxDecoration(color: c.surface2, shape: BoxShape.circle), alignment: Alignment.center, child: MpIcon(icon, size: 30, stroke: 1.4)),
            const SizedBox(height: 20),
            Text(title, textAlign: TextAlign.center, style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center, style: mpStyle(context, color: c.text2)),
          ]),
        ),
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  final Map s;
  final VoidCallback onTap;
  const _AgentRow(this.s, {required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final (label, hot) = _statusLabel(s['status'] ?? 'idle');
    final approval = s['status'] == 'approval';
    return EnterAnim(
      key: ValueKey(s['id']),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Pressable(
          onTap: onTap,
          pressScale: .98,
          radius: BorderRadius.circular(MpRadius.bubble),
          hover: c.surface,
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            AnimatedContainer(
              duration: Motion.d(300),
              width: 44, height: 44,
              decoration: BoxDecoration(color: approval ? c.accent : c.surface2, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: MpIcon('assistant', size: 20, color: approval ? c.onAccent : c.text),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s['title'] ?? 'Session', maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, w: FontWeight.w700)),
                Text('${s['project']} · ${_ago(s['ts'] ?? 0)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, size: MpText.meta, color: c.text2)),
              ]),
            ),
            if (hot || s['status'] == 'terminal')
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: approval ? c.accent : c.surface2, borderRadius: BorderRadius.circular(999)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (s['status'] == 'working') ...[_Pulse(color: c.dot), const SizedBox(width: 6)],
                  Text(label, style: mpStyle(context, size: 12, w: FontWeight.w700, color: approval ? c.onAccent : c.text)),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Soft breathing dot for "working".
class _Pulse extends StatefulWidget {
  final Color color;
  const _Pulse({required this.color});
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: .35, end: 1.0).animate(CurvedAnimation(parent: _a, curve: Curves.easeInOut)),
        child: Container(width: 8, height: 8, decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle)),
      );
}

/// Pick a project folder and write the first prompt. Returns (session id, title).
Future<(String, String)?> showNewAgentSheet(BuildContext context, Device pc, List<Map> projects, {List<Msg> attach = const [], String initial = ''}) {
  final c = MpColors.of(context);
  return showModalBottomSheet<(String, String)>(
    context: context,
    isScrollControlled: true,
    backgroundColor: c.surface,
    barrierColor: c.scrim,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(MpRadius.sheet))),
    sheetAnimationStyle: AnimationStyle(duration: Motion.d(360), reverseDuration: Motion.d(240), curve: Motion.curve),
    builder: (ctx) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom), child: _NewAgent(pc: pc, projects: projects, attach: attach, initial: initial)),
  );
}

class _NewAgent extends StatefulWidget {
  final Device pc;
  final List<Map> projects;
  final List<Msg> attach;
  final String initial;
  const _NewAgent({required this.pc, required this.projects, this.attach = const [], this.initial = ''});
  @override
  State<_NewAgent> createState() => _NewAgentState();
}

class _NewAgentState extends State<_NewAgent> {
  late final _prompt = TextEditingController(text: widget.initial);
  late String? _cwd = widget.projects.isEmpty ? null : widget.projects.first['path'];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final text = _prompt.text.trim();
    if ((text.isEmpty && widget.attach.isEmpty) || _cwd == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await client.call(widget.pc, 'POST', '/agents/start', body: {'cwd': _cwd, 'prompt': text, 'attach': [for (final m in widget.attach) m.id]});
      if (mounted) Navigator.pop(context, (r['id'] as String, text.split('\n').first));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is HttpException ? e.message : '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 20), decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(999)))),
          Text('New agent', style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Runs Claude Code on ${widget.pc.name}. You approve every change it wants to make.', style: mpStyle(context, size: MpText.meta, color: c.text2)),
          const SizedBox(height: 16),
          Text('Project', style: mpStyle(context, size: MpText.meta, w: FontWeight.w500, color: c.text2)),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final p in widget.projects)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Pressable(
                    onTap: () => setState(() => _cwd = p['path']),
                    pressScale: .94,
                    child: AnimatedContainer(
                      duration: Motion.d(220),
                      curve: Motion.curve,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: _cwd == p['path'] ? c.text : c.surface2, borderRadius: BorderRadius.circular(999)),
                      child: Text(p['name'], style: mpStyle(context, size: MpText.meta, w: FontWeight.w700, color: _cwd == p['path'] ? c.bg : c.text)),
                    ),
                  ),
                ),
            ]),
          ),
          if (_cwd != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_cwd!, style: mpStyle(context, size: 12, color: c.text2).copyWith(fontFamily: _mono))),
          const SizedBox(height: 16),
          if (widget.attach.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in widget.attach)
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                    decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      MpIcon(m.kind == 'image' ? 'image' : 'file', size: 16),
                      const SizedBox(width: 6),
                      ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, size: MpText.meta, w: FontWeight.w500))),
                    ]),
                  ),
              ]),
            ),
          TextField(
            controller: _prompt,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            style: mpStyle(context),
            decoration: InputDecoration(
              hintText: widget.attach.isEmpty ? 'What should Claude do?' : 'What should Claude do with ${widget.attach.length == 1 ? 'it' : 'them'}?',
              hintStyle: mpStyle(context, color: c.text2.withValues(alpha: .7)),
              filled: true,
              fillColor: c.bg,
              contentPadding: const EdgeInsets.all(16),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.line)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.text2, width: 1.4)),
            ),
          ),
          AnimatedSize(
            duration: Motion.d(200),
            child: _error == null ? const SizedBox(width: double.infinity) : Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: mpStyle(context, size: MpText.meta, color: c.text2))),
          ),
          const SizedBox(height: 16),
          PillButton(_busy ? 'Starting…' : 'Start agent', icon: 'assistant', height: 52, expand: true, onTap: _busy ? null : _start),
        ]),
      ),
    );
  }
}

/// A live agent conversation: Claude's messages, tool calls, and approval cards.
class AgentSessionPage extends StatefulWidget {
  final Device pc;
  final String id, title;
  const AgentSessionPage({super.key, required this.pc, required this.id, required this.title});
  @override
  State<AgentSessionPage> createState() => _AgentSessionPageState();
}

class _AgentSessionPageState extends State<AgentSessionPage> {
  final _events = <int, Map>{};
  final _draft = TextEditingController();
  final _seen = <int>{};
  late final String _id = widget.id;
  int _next = 0, _v = 0;
  String _status = 'idle';
  String? _error, _title;
  bool _alive = true, _loaded = false;
  late bool _screen = store.get('agentScreen', false); // live PC screen above the chat

  @override
  void initState() {
    super.initState();
    setVisibleAgent(_id);
    _poll();
  }

  @override
  void dispose() {
    _alive = false;
    if (visibleAgent == _id) setVisibleAgent(null);
    _draft.dispose();
    super.dispose();
  }

  /// Long-poll: the PC answers as soon as something changes (or after ~20 s).
  Future<void> _poll() async {
    while (_alive) {
      try {
        final r = await client.call(widget.pc, 'GET', '/agents/s/$_id/events?after=$_next&v=$_v', timeout: const Duration(seconds: 30));
        if (!_alive) return;
        setState(() {
          for (final e in (r['events'] as List)) {
            _events[e['n']] = e;
          }
          if (!_loaded) _seen.addAll(_events.keys);
          _loaded = true;
          _next = r['next'];
          _v = r['v'];
          _status = r['status'];
          _title = r['title'];
          _error = null;
        });
      } catch (e) {
        if (!_alive) return;
        setState(() => _error = '${widget.pc.name} isn’t reachable. Retrying…');
        await Future.delayed(const Duration(seconds: 3));
      }
    }
  }

  Future<void> _send() async {
    final t = _draft.text.trim();
    if (t.isEmpty) return;
    _draft.clear();
    HapticFeedback.lightImpact();
    try {
      await client.call(widget.pc, 'POST', '/agents/s/$_id/send', body: {'text': t});
    } catch (e) {
      if (mounted) showToast(context, (e is HttpException ? e.message : '$e'));
    }
  }

  Future<void> _decide(Map e, bool allow) async {
    HapticFeedback.mediumImpact();
    setState(() => e['state'] = allow ? 'allowed' : 'denied');
    try {
      await client.call(widget.pc, 'POST', '/agents/s/$_id/approve', body: {'rid': e['rid'], 'allow': allow});
    } catch (_) {
      if (mounted) setState(() => e['state'] = 'pending');
    }
  }

  Future<void> _stop() => client.call(widget.pc, 'POST', '/agents/s/$_id/stop').catchError((_) => {});

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final evs = (_events.keys.toList()..sort()).map((k) => _events[k]!).where((e) => e['k'] != 'decided').toList();
    final results = {for (final e in evs) if (e['k'] == 'tool_result') e['id']: e};
    final shown = evs.where((e) => e['k'] != 'tool_result').toList();
    final (label, _) = _statusLabel(_status);
    final working = _status == 'working' || _status == 'approval';

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
            child: Row(children: [
              IconBtn('back', iconSize: 24, onTap: () => Navigator.pop(context)),
              const SizedBox(width: 4),
              Container(width: 40, height: 40, decoration: BoxDecoration(color: c.surface2, shape: BoxShape.circle), alignment: Alignment.center, child: const MpIcon('assistant', size: 20)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_title ?? widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, w: FontWeight.w700)),
                  AnimatedSwitcher(
                    duration: Motion.d(200),
                    child: Row(key: ValueKey(_status + (_error ?? '')), children: [
                      if (_status == 'working' && _error == null) ...[_Pulse(color: c.dot), const SizedBox(width: 6)],
                      Flexible(child: Text(_error ?? '$label · ${widget.pc.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, size: MpText.meta, color: c.text2))),
                    ]),
                  ),
                ]),
              ),
              AnimatedScale(
                scale: working ? 1 : 0,
                duration: Motion.d(220),
                curve: Motion.pop,
                child: IconBtn('close', iconSize: 20, color: c.text2, onTap: working ? _stop : null, tip: 'Stop'),
              ),
              IconBtn('screen', iconSize: 22, color: _screen ? c.text : c.text2, bg: _screen ? c.surface2 : null, tip: 'Live screen', onTap: () {
                setState(() => _screen = !_screen);
                store.set('agentScreen', _screen);
              }),
            ]),
          ),
          AnimatedSize(
            duration: Motion.d(320),
            curve: Motion.curve,
            child: _screen ? ScreenPanel(pc: widget.pc) : const SizedBox(width: double.infinity),
          ),
          Expanded(
            child: !_loaded
                ? Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: c.text, strokeCap: StrokeCap.round)))
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final e = shown[shown.length - 1 - i];
                      final fresh = _seen.add(e['n']);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: EnterAnim(key: ValueKey(e['n']), animate: fresh, origin: e['k'] == 'user' ? Alignment.bottomRight : Alignment.bottomLeft, child: _event(e, results, c)),
                      );
                    },
                  ),
          ),
          if (_status == 'terminal')
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text('This session is open in a terminal on ${widget.pc.name}. You can watch it here; continue it once it’s closed there.', textAlign: TextAlign.center, style: mpStyle(context, size: MpText.meta, color: c.text2)),
            )
          else
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: c.line)),
                      child: TextField(
                        controller: _draft,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        style: mpStyle(context),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: working ? 'Add to what Claude is doing…' : 'Message Claude',
                          hintStyle: mpStyle(context, color: c.text2.withValues(alpha: .8)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconBtn('send', size: 48, bg: c.accent, color: c.onAccent, onTap: _send, tip: 'Send'),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _event(Map e, Map results, MpColors c) {
    switch (e['k']) {
      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .8),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              decoration: BoxDecoration(color: c.accent, borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20), bottomLeft: Radius.circular(20), bottomRight: Radius.circular(6))),
              child: Text(e['text'] ?? '', style: mpStyle(context, color: c.onAccent)),
            ),
          ),
        );
      case 'text':
        return _ClaudeText(e['text'] ?? '');
      case 'tool':
        return _ToolRow(e, results[e['id']]);
      case 'approve':
        return _ApprovalCard(e, onDecide: (allow) => _decide(e, allow));
      case 'result':
        final secs = ((e['ms'] ?? 0) / 1000).round();
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('${e['ok'] == true ? 'Done' : 'Ended with an error'}${secs > 0 ? ' · ${secs}s' : ''}', style: mpStyle(context, size: MpText.meta, color: c.text2)),
          ),
        );
      case 'error':
        return Center(child: Text(e['text'] ?? '', textAlign: TextAlign.center, style: mpStyle(context, size: MpText.meta, color: c.text2)));
    }
    return const SizedBox.shrink();
  }
}

/// Claude's reply: plain text, with ``` code blocks in a mono box.
class _ClaudeText extends StatelessWidget {
  final String text;
  const _ClaudeText(this.text);
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final parts = text.split('```');
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .88),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(color: c.surface2, borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20), bottomLeft: Radius.circular(6), bottomRight: Radius.circular(20))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < parts.length; i++)
              if (parts[i].trim().isNotEmpty)
                i.isOdd
                    ? Container(
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(10)),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(parts[i].replaceFirst(RegExp(r'^[a-zA-Z0-9_+-]*\n'), '').trimRight(), style: mpStyle(context, size: 12.5).copyWith(fontFamily: _mono, height: 1.4)),
                        ),
                      )
                    : SelectableText(parts[i].trim(), style: mpStyle(context)),
          ]),
        ),
      ),
    );
  }
}

/// "Bash  git status" — tap to see the output.
class _ToolRow extends StatefulWidget {
  final Map e;
  final Map? result;
  const _ToolRow(this.e, this.result);
  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final r = widget.result;
    final dot = r == null ? null : (r['ok'] == true ? c.dot : const Color(0xFFE5484D));
    return Pressable(
      onTap: r == null ? null : () => setState(() => _open = !_open),
      pressScale: .99,
      radius: BorderRadius.circular(14),
      color: c.surface,
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: AnimatedSize(
        duration: Motion.d(240),
        curve: Motion.curve,
        alignment: Alignment.topCenter,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AnimatedSwitcher(
              duration: Motion.d(200),
              child: dot == null ? SizedBox(key: const ValueKey('run'), width: 8, height: 8, child: _Pulse(color: c.text2)) : Container(key: const ValueKey('done'), width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            ),
            const SizedBox(width: 10),
            Text(widget.e['name'] ?? '', style: mpStyle(context, size: MpText.meta, w: FontWeight.w700)),
            const SizedBox(width: 8),
            Expanded(child: Text(widget.e['summary'] ?? '', maxLines: _open ? 6 : 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, size: 12.5, color: c.text2).copyWith(fontFamily: _mono))),
          ]),
          if (_open && (r?['preview'] ?? '').toString().trim().isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(10)),
              child: Text(r!['preview'], style: mpStyle(context, size: 12, color: c.text2).copyWith(fontFamily: _mono, height: 1.4)),
            ),
        ]),
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  final Map e;
  final void Function(bool allow) onDecide;
  const _ApprovalCard(this.e, {required this.onDecide});
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final pending = e['state'] == 'pending';
    return AnimatedContainer(
      duration: Motion.d(300),
      curve: Motion.curve,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(MpRadius.bubble), border: Border.all(color: pending ? c.accent : c.line, width: pending ? 1.6 : 1)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          MpIcon('assistant', size: 16, color: pending ? c.accent : c.text2),
          const SizedBox(width: 8),
          Expanded(child: Text('Claude wants to use ${e['name']}', style: mpStyle(context, size: MpText.meta, w: FontWeight.w700))),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(10)),
          child: Text(e['summary'] ?? '', maxLines: 8, overflow: TextOverflow.ellipsis, style: mpStyle(context, size: 12.5).copyWith(fontFamily: _mono, height: 1.4)),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: Motion.d(240),
          transitionBuilder: (w, a) => FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: .95, end: 1.0).animate(a), child: w)),
          child: pending
              ? Row(key: const ValueKey('ask'), children: [
                  Expanded(child: PillButton('Deny', solid: false, height: 44, expand: true, onTap: () => onDecide(false))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Pressable(
                      onTap: () => onDecide(true),
                      color: c.accent,
                      child: SizedBox(height: 44, child: Center(child: Text('Allow', style: mpStyle(context, w: FontWeight.w700, color: c.onAccent)))),
                    ),
                  ),
                ])
              : Row(key: ValueKey(e['state']), children: [
                  MpIcon(e['state'] == 'allowed' ? 'check' : 'close', size: 16, color: c.text2),
                  const SizedBox(width: 6),
                  Text(e['state'] == 'allowed' ? 'Allowed' : 'Denied', style: mpStyle(context, size: MpText.meta, w: FontWeight.w500, color: c.text2)),
                ]),
        ),
      ]),
    );
  }
}


/// Phone "Share → Claude on `PC`": send the files to the PC, then start an agent with them attached.
Future<void> shareToClaude(BuildContext context, Device pc, List<String> paths, String text) async {
  final msgs = [for (final p in paths) await client.sendFile(pc, p)];
  if (msgs.isNotEmpty) {
    if (context.mounted) showToast(context, 'Sending to ${pc.name}…');
    for (var i = 0; i < 600 && msgs.any((m) => m.status != 'sent'); i++) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (msgs.any((m) => m.status != 'sent')) {
      if (context.mounted) showToast(context, 'Couldn’t send the files to ${pc.name}');
      return;
    }
  }
  Map list;
  try {
    list = await client.call(pc, 'GET', '/agents');
  } catch (e) {
    if (context.mounted) showToast(context, e is HttpException ? e.message : '${pc.name} isn’t reachable');
    return;
  }
  if (!context.mounted) return;
  final r = await showNewAgentSheet(context, pc, List<Map>.from(list['projects'] ?? const []), attach: msgs, initial: text);
  if (r != null && context.mounted) Navigator.of(context).push(agentRoute(AgentSessionPage(pc: pc, id: r.$1, title: r.$2)));
}
