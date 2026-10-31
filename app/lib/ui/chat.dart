import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../core.dart';
import '../store.dart';
import '../tokens.dart';
import 'agents.dart';
import 'mirror_view.dart';
import 'screen_view.dart';
import 'widgets.dart';

const quickEmoji = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
const moreEmoji = ['🔥', '🎉', '👀', '✅', '💯', '🤔', '👏', '😅', '🙌', '💡', '📌', '🚀'];

void openFile(BuildContext context, Msg m) async {
  if (!File(m.path).existsSync()) return showToast(context, 'File is no longer on this device');
  await OpenFilex.open(m.path);
}

void showInFolder(Msg m) => Process.run('xdg-open', [File(m.path).parent.path]);

class ChatView extends StatefulWidget {
  final Device dev;
  final bool desktop, infoOpen;
  final VoidCallback? onBack, onInfo;
  const ChatView({super.key, required this.dev, this.desktop = false, this.infoOpen = false, this.onBack, this.onInfo});
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _draft = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Map? _reply; // {id, who, text}
  late Set<String> _seen;
  bool _dragging = false;
  String? _query; // null: not searching
  final _search = TextEditingController();

  Device get dev => widget.dev;

  @override
  void initState() {
    super.initState();
    _enter();
    _draft.addListener(() => setState(() {}));
  }

  void _enter() {
    setVisibleChat(dev.id);
    _seen = store.chat(dev.id).map((m) => m.id).toSet();
  }

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    if (old.dev.id != dev.id) {
      _enter();
      _reply = null;
      _draft.clear();
    }
  }

  @override
  void dispose() {
    if (visibleChat == dev.id) setVisibleChat(null);
    _draft.dispose();
    _search.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    if (_scroll.hasClients) _scroll.animateTo(0, duration: Motion.d(320), curve: Motion.curve);
  }

  Future<void> _send() async {
    final t = _draft.text.trim();
    if (t.isEmpty) return;
    _draft.clear();
    final r = _reply;
    setState(() => _reply = null);
    await client.sendText(dev, t, replyTo: r == null ? null : {'who': r['who'], 'text': r['text']});
    _toBottom();
  }

  Future<void> _sendPaths(Iterable<String> paths) async {
    final r = _reply;
    setState(() => _reply = null);
    for (final p in paths) {
      await client.sendFile(dev, p, replyTo: r == null ? null : {'who': r['who'], 'text': r['text']});
    }
    _toBottom();
  }

  Future<void> _attach() async {
    final files = await FilePicker.pickFiles();
    await _sendPaths(files.map((f) => f.path).whereType<String>());
  }

  void _startReply(Msg m) {
    setState(() => _reply = {'id': m.id, 'who': m.mine ? 'You' : dev.name, 'text': m.preview});
    _focus.requestFocus();
  }

  Future<void> _delete(Msg m) async {
    await store.logEvent(dev.id, {'t': 'del', 'id': m.id});
    if (mounted) showToast(context, 'Message deleted');
  }

  void _copy(Msg m) {
    Clipboard.setData(ClipboardData(text: m.kind == 'text' ? m.text : m.path));
    showToast(context, 'Copied');
  }

  /// Phone long-press (and desktop "more reactions"): focused message menu.
  void _openMenu(Msg m) {
    HapticFeedback.mediumImpact();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: MpColors.of(context).scrim,
      transitionDuration: Motion.d(240),
      pageBuilder: (ctx, _, _) => _MsgMenu(
        m: m,
        desktop: widget.desktop,
        onReact: (e) => client.react(dev, m.id, e),
        onReply: () => _startReply(m),
        onCopy: () => _copy(m),
        onDelete: () => _delete(m),
        onOpen: () => openFile(context, m),
      ),
      transitionBuilder: (ctx, a, _, child) => popTransition(a, child, origin: m.mine ? Alignment.centerRight : Alignment.centerLeft),
    );
  }

  /// Desktop right-click menu at the pointer.
  void _contextMenu(Msg m, Offset at) {
    final c = MpColors.of(context);
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.transparent,
      transitionDuration: Motion.d(160),
      pageBuilder: (ctx, _, _) {
        final size = MediaQuery.sizeOf(ctx);
        Widget item(String icon, String label, VoidCallback f) => Pressable(
              onTap: () {
                Navigator.pop(ctx);
                f();
              },
              pressScale: .98,
              radius: BorderRadius.circular(6),
              hover: c.surface2,
              child: SizedBox(height: 36, child: Row(children: [const SizedBox(width: 10), MpIcon(icon, size: 16), const SizedBox(width: 12), Text(label, style: mpStyle(ctx))])),
            );
        return Stack(children: [
          Positioned(
            left: at.dx.clamp(8, size.width - 208),
            top: at.dy.clamp(8, size.height - 200),
            child: Material(
              color: c.surface,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: c.line)),
              shadowColor: Colors.black,
              child: Container(
                width: 200,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: Theme.of(ctx).brightness == Brightness.dark ? .4 : .1), blurRadius: 24, offset: const Offset(0, 8))]),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  item('reply', 'Reply', () => _startReply(m)),
                  if (m.kind == 'text') item('copy', 'Copy', () => _copy(m)),
                  if (m.kind != 'text') item('folder', 'Show in folder', () => showInFolder(m)),
                  Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4), color: c.line),
                  item('delete', 'Delete', () => _delete(m)),
                ]),
              ),
            ),
          ),
        ]);
      },
      transitionBuilder: (ctx, a, _, child) => popTransition(a, child, origin: Alignment.topLeft),
    );
  }

  bool get _isPc => dev.kind == 'laptop' || dev.kind == 'desktop';

  void _openAgents() => Navigator.of(context).push(agentRoute(AgentsPage(pc: dev)));

  void _openInfoSheet() {
    if (widget.onInfo != null) return widget.onInfo!();
  }

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final body = Column(children: [
      _header(c),
      Expanded(child: StoreBuilder(builder: (context) {
        final all = store.chat(dev.id);
        final q = _query?.trim() ?? '';
        final msgs = q.isEmpty ? all : all.where((m) => _matches(m, q)).toList();
        if (q.isNotEmpty && msgs.isEmpty) {
          return Center(child: Text('No messages match “$q”', style: mpStyle(context, color: c.text2)));
        }
        if (appForeground && store.unread(dev.id) > 0) WidgetsBinding.instance.addPostFrameCallback((_) => store.markRead(dev.id));
        if (msgs.isEmpty) return _empty(c);
        return ListView.builder(
          controller: _scroll,
          reverse: true,
          padding: EdgeInsets.fromLTRB(widget.desktop ? 24 : 16, 16, widget.desktop ? 24 : 16, 8),
          itemCount: msgs.length,
          itemBuilder: (_, i) {
            final m = msgs[msgs.length - 1 - i];
            final older = i + 1 < msgs.length ? msgs[msgs.length - 2 - i] : null;
            final fresh = _seen.add(m.id);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (older == null || dayLabel(older.ts) != dayLabel(m.ts))
                Padding(padding: const EdgeInsets.fromLTRB(0, 8, 0, 12), child: Center(child: Text(dayLabel(m.ts), style: mpStyle(context, size: MpText.meta, color: c.text2)))),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: EnterAnim(
                  key: ValueKey(m.id),
                  animate: fresh,
                  origin: m.mine ? Alignment.bottomRight : Alignment.bottomLeft,
                  child: MsgTile(
                    highlight: q,
                    m: m,
                    dev: dev,
                    desktop: widget.desktop,
                    onMenu: () => _openMenu(m),
                    onContext: (p) => _contextMenu(m, p),
                    onReply: () => _startReply(m),
                  ),
                ),
              ),
            ]);
          },
        );
      })),
      _replyBar(c),
      _input(c),
    ]);

    if (!widget.desktop) return body;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openSearch},
      child: DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        // shortcut: dragged folders are skipped; only regular files are sent.
        _sendPaths(d.files.map((f) => f.path).where((p) => FileSystemEntity.isFileSync(p)));
      },
      child: Stack(children: [
        body,
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_dragging,
            child: AnimatedOpacity(
              opacity: _dragging ? 1 : 0,
              duration: Motion.d(180),
              child: AnimatedScale(
                scale: _dragging ? 1 : .98,
                duration: Motion.d(220),
                curve: Motion.curve,
                child: Container(
                  color: c.bg.withValues(alpha: .92),
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: c.text.withValues(alpha: .7), width: 2)),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Container(width: 64, height: 64, decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: c.line)), alignment: Alignment.center, child: const MpIcon('drop', size: 28)),
                      const SizedBox(height: 12),
                      Text('Drop to send to ${dev.name}', style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    ),
    );
  }

  void _openSearch() => setState(() => _query = '');
  void _closeSearch() => setState(() {
        _query = null;
        _search.clear();
      });

  Widget _header(MpColors c) => AnimatedSwitcher(
        duration: Motion.d(220),
        transitionBuilder: (w, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0, -.15), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Motion.curve)), child: w)),
        child: _query == null ? KeyedSubtree(key: const ValueKey('h'), child: _titleBar(c)) : KeyedSubtree(key: const ValueKey('s'), child: _searchBar(c)),
      );

  Widget _searchBar(MpColors c) {
    final n = _query!.isEmpty ? null : store.chat(dev.id).where((m) => _matches(m, _query!)).length;
    return Container(
      height: widget.desktop ? 64 : null,
      padding: widget.desktop ? const EdgeInsets.fromLTRB(16, 0, 16, 0) : const EdgeInsets.fromLTRB(4, 8, 12, 8),
      decoration: widget.desktop ? BoxDecoration(border: Border(bottom: BorderSide(color: c.line))) : null,
      child: Row(children: [
        IconBtn('back', size: widget.desktop ? 36 : 44, iconSize: widget.desktop ? 20 : 24, onTap: _closeSearch, tip: 'Close search'),
        const SizedBox(width: 4),
        Expanded(
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeSearch},
            child: TextField(
              controller: _search,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              style: mpStyle(context),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search in ${dev.name}',
                hintStyle: mpStyle(context, color: c.text2.withValues(alpha: .8)),
                filled: true,
                fillColor: c.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide(color: c.line)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide(color: c.text2, width: 1.2)),
              ),
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: Motion.d(200),
          child: n == null ? const SizedBox.shrink() : Padding(key: ValueKey(n), padding: const EdgeInsets.only(left: 12), child: Text(n == 1 ? '1 result' : '$n results', style: mpStyle(context, size: MpText.meta, color: c.text2))),
        ),
      ]),
    );
  }

  static bool _matches(Msg m, String q) {
    final t = q.toLowerCase().trim();
    return t.isEmpty || m.text.toLowerCase().contains(t) || m.name.toLowerCase().contains(t);
  }

  Widget _titleBar(MpColors c) {
    final on = store.online[dev.id] == true;
    final status = Row(mainAxisSize: MainAxisSize.min, children: [
      AnimatedSize(duration: Motion.d(200), child: on ? const Padding(padding: EdgeInsets.only(right: 6), child: OnlineDot(true)) : const SizedBox.shrink()),
      AnimatedSwitcher(duration: Motion.d(200), child: Text(statusOf(dev.id), key: ValueKey(statusOf(dev.id)), style: mpStyle(context, size: MpText.meta, color: c.text2))),
      if (store.battery[dev.id] != null) ...[const SizedBox(width: 10), BatteryChip(dev.id)],
    ]);
    if (widget.desktop) {
      return Container(
        height: 64,
        padding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
        child: StoreBuilder(builder: (context) => Row(children: [
              DeviceAvatar(dev.kind, size: 40, square: true),
              const SizedBox(width: 12),
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(dev.name, style: mpStyle(context, w: FontWeight.w700)), status])),
              if (!_isPc && isDesktop) IconBtn('remote', size: 36, iconSize: 20, onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PhoneMirrorPage(phone: dev))), tip: 'Show and control ${dev.name}'),
              if (_isPc) IconBtn('screen', size: 36, iconSize: 20, onTap: () => openScreen(context, dev), tip: 'Live screen'),
              if (_isPc) IconBtn('assistant', size: 36, iconSize: 20, onTap: _openAgents, tip: 'Claude on ${dev.name}'),
              IconBtn('search', size: 36, iconSize: 20, onTap: _openSearch, tip: 'Search (Ctrl+F)'),
              IconBtn('info', size: 36, iconSize: 20, onTap: widget.onInfo, bg: widget.infoOpen ? c.surface2 : null, tip: 'Device info'),
            ])),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
      child: StoreBuilder(builder: (context) => Row(children: [
            IconBtn('back', onTap: widget.onBack, iconSize: 24),
            Expanded(
              child: Pressable(
                onTap: _openInfoSheet,
                pressScale: .98,
                radius: BorderRadius.circular(16),
                padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
                child: Row(children: [
                  Hero(tag: 'avatar-${dev.id}', child: DeviceAvatar(dev.kind, size: 40)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(dev.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, w: FontWeight.w700)), status])),
                ]),
              ),
            ),
            if (_isPc) IconBtn('screen', onTap: () => openScreen(context, dev), color: c.text2, tip: 'Live screen'),
            if (_isPc) IconBtn('assistant', onTap: _openAgents, color: c.text2, tip: 'Claude on ${dev.name}'),
            IconBtn('search', onTap: _openSearch, color: c.text2, tip: 'Search'),
          ])),
    );
  }

  Widget _empty(MpColors c) => Center(
        child: EnterAnim(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(48, 0, 48, 48),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 72, height: 72, decoration: BoxDecoration(color: c.surface2, shape: BoxShape.circle), alignment: Alignment.center, child: MpIcon(dev.kind, size: 32, stroke: 1.4)),
              const SizedBox(height: 24),
              Text('Nothing here yet', style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
              const SizedBox(height: 12),
              Text(
                'Messages and files you send to ${dev.name} will appear here.${store.online[dev.id] == true ? '' : ' It will get them when it’s back online.'}',
                textAlign: TextAlign.center,
                style: mpStyle(context, color: c.text2),
              ),
            ]),
          ),
        ),
      );

  Widget _replyBar(MpColors c) => AnimatedSize(
        duration: Motion.d(220),
        curve: Motion.curve,
        child: AnimatedSwitcher(
          duration: Motion.d(200),
          transitionBuilder: (w, a) => FadeTransition(opacity: a, child: SizeTransition(sizeFactor: a, child: w)),
          child: _reply == null
              ? const SizedBox(width: double.infinity)
              : Container(
                  key: ValueKey(_reply!['id']),
                  margin: EdgeInsets.fromLTRB(widget.desktop ? 16 : 12, 0, widget.desktop ? 16 : 12, 4),
                  padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                  decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: c.line)),
                  child: Row(children: [
                    MpIcon('reply', size: 18, color: c.text2),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Replying to ${_reply!['who']}', style: mpStyle(context, size: MpText.meta, w: FontWeight.w700)),
                        Text(_reply!['text'], maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, size: MpText.meta, color: c.text2)),
                      ]),
                    ),
                    IconBtn('close', iconSize: 18, color: c.text2, onTap: () => setState(() => _reply = null)),
                  ]),
                ),
        ),
      );

  Widget _input(MpColors c) {
    final field = CallbackShortcuts(
      bindings: {if (widget.desktop) const SingleActivator(LogicalKeyboardKey.enter): _send},
      child: TextField(
        controller: _draft,
        focusNode: _focus,
        minLines: 1,
        maxLines: 5,
        textInputAction: widget.desktop ? TextInputAction.newline : TextInputAction.send,
        onSubmitted: (_) => _send(),
        style: mpStyle(context),
        cursorWidth: 1.6,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: 'Message ${dev.name}',
          hintStyle: mpStyle(context, color: c.text2.withValues(alpha: .8)),
          contentPadding: EdgeInsets.symmetric(horizontal: widget.desktop ? 20 : 8, vertical: 12),
        ),
      ),
    );
    final hasText = _draft.text.trim().isNotEmpty;
    final send = AnimatedScale(
      scale: hasText ? 1 : .9,
      duration: Motion.d(220),
      curve: Motion.pop,
      child: IconBtn('send', size: widget.desktop ? 44 : 48, bg: c.accent, color: c.onAccent, onTap: _send, tip: 'Send'),
    );
    if (widget.desktop) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          IconBtn('attach', color: c.text2, iconSize: 20, onTap: _attach, tip: 'Attach file'),
          const SizedBox(width: 8),
          Expanded(child: Container(constraints: const BoxConstraints(minHeight: 44), decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(22), border: Border.all(color: c.line)), child: field)),
          const SizedBox(width: 8),
          send,
        ]),
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: c.line)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Padding(padding: const EdgeInsets.only(bottom: 3), child: IconBtn('attach', size: 40, color: c.text2, onTap: _attach)),
                Expanded(child: field),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          send,
        ]),
      ),
    );
  }
}

/// One message: bubble, reactions, meta. Desktop shows a reaction bar on hover.
class MsgTile extends StatefulWidget {
  final Msg m;
  final Device dev;
  final bool desktop;
  final String highlight;
  final VoidCallback onMenu, onReply;
  final void Function(Offset) onContext;
  const MsgTile({super.key, this.highlight = '', required this.m, required this.dev, required this.desktop, required this.onMenu, required this.onContext, required this.onReply});
  @override
  State<MsgTile> createState() => _MsgTileState();
}

class _MsgTileState extends State<MsgTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.m, c = MpColors.of(context);
    final mine = m.mine;
    final maxW = MediaQuery.sizeOf(context).width * (widget.desktop ? .5 : .8);
    final meta = m.mine && m.status == 'pending'
        ? (m.progress != null ? 'Sending · ${(m.progress! * 100).round()}%' : 'Waiting for ${widget.dev.name}')
        : timeLabel(m.ts);

    final bubble = Pressable(
      onTap: m.kind == 'text' ? null : () => openFile(context, m),
      onLongPress: widget.desktop ? null : widget.onMenu,
      onSecondaryTap: widget.desktop ? widget.onContext : null,
      pressScale: .97,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: AnimatedContainer(
          duration: Motion.d(240),
          padding: m.kind == 'image' ? const EdgeInsets.all(4) : m.kind == 'file' ? const EdgeInsets.fromLTRB(12, 10, 12, 10) : const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: mine ? c.accent : c.surface2,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(MpRadius.bubble),
              topRight: const Radius.circular(MpRadius.bubble),
              bottomLeft: Radius.circular(mine ? MpRadius.bubble : MpRadius.tail),
              bottomRight: Radius.circular(mine ? MpRadius.tail : MpRadius.bubble),
            ),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: mine ? c.onAccent : c.text),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (m.replyTo != null) _quote(c, mine),
              if (m.kind == 'text') LinkText(m.text, highlight: widget.highlight, style: mpStyle(context, color: mine ? c.onAccent : c.text)),
              if (m.kind == 'file') _file(c, mine),
              if (m.kind == 'image') _image(c, mine),
            ]),
          ),
        ),
      ),
    );

    final reacts = m.reacts.entries.toList();
    final under = Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final r in reacts)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: TweenAnimationBuilder<double>(
              key: ValueKey(r.key),
              tween: Tween(begin: .4, end: 1),
              duration: Motion.d(320),
              curve: Motion.pop,
              builder: (_, s, child) => Transform.scale(scale: s, child: child),
              child: Pressable(
                onTap: () => client.react(widget.dev, m.id, r.key),
                child: AnimatedContainer(
                  duration: Motion.d(180),
                  height: 26,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(999), border: Border.all(color: r.value.contains('me') ? c.text2 : c.line)),
                  child: Center(child: Text(r.value.length > 1 ? '${r.key} ${r.value.length}' : r.key, style: mpStyle(context, size: MpText.meta))),
                ),
              ),
            ),
          ),
        AnimatedSwitcher(duration: Motion.d(200), child: Text(meta, key: ValueKey(meta), style: mpStyle(context, size: MpText.meta, color: c.text2))),
      ]),
    );

    Widget tile = Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [bubble, under]);
    if (!widget.desktop) return tile;

    // Desktop: floating quick-reaction bar on hover.
    final bar = AnimatedOpacity(
      opacity: _hover ? 1 : 0,
      duration: Motion.d(150),
      child: AnimatedSlide(
        offset: _hover ? Offset.zero : Offset(mine ? .15 : -.15, 0),
        duration: Motion.d(200),
        curve: Motion.curve,
        child: IgnorePointer(
          ignoring: !_hover,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(999), border: Border.all(color: c.line), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .12), blurRadius: 16, offset: const Offset(0, 6))]),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final e in quickEmoji.take(5))
                Pressable(
                  onTap: () => client.react(widget.dev, m.id, e),
                  hover: c.surface2,
                  pressScale: .85,
                  color: m.reacts[e]?.contains('me') == true ? c.surface2 : null,
                  child: SizedBox(width: 32, height: 32, child: Center(child: Text(e, style: const TextStyle(fontSize: 17)))),
                ),
              Container(width: 1, height: 20, margin: const EdgeInsets.symmetric(horizontal: 2), color: c.line),
              IconBtn('reply', size: 32, iconSize: 17, color: c.text2, onTap: widget.onReply, tip: 'Reply'),
              IconBtn('add', size: 32, iconSize: 17, color: c.text2, onTap: widget.onMenu, tip: 'More'),
            ]),
          ),
        ),
      ),
    );
    // The bar sits beside the bubble (inside the tile's bounds) so it actually receives clicks.
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (mine) ...[bar, const SizedBox(width: 8)],
          Flexible(child: tile),
          if (!mine) ...[const SizedBox(width: 8), bar],
        ]),
      ),
    );
  }

  Widget _quote(MpColors c, bool mine) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: BoxDecoration(color: mine ? c.quote : c.surface, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            MpIcon('reply', size: 14, stroke: 2, color: mine ? c.onAccent : c.text),
            const SizedBox(width: 4),
            Text(widget.m.replyTo!['who'] ?? '', style: mpStyle(context, size: MpText.meta, w: FontWeight.w700, color: mine ? c.onAccent : c.text)),
          ]),
          Text(widget.m.replyTo!['text'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, size: MpText.meta, color: mine ? c.onAccentSub : c.text2)),
        ]),
      );

  Widget _progress(MpColors c, bool mine) {
    final p = widget.m.progress;
    return AnimatedSize(
      duration: Motion.d(200),
      child: p == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 2),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: p),
                duration: Motion.d(160),
                builder: (_, v, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(value: v, minHeight: 4, backgroundColor: mine ? c.quote : c.surface, color: mine ? c.onAccent : c.text),
                ),
              ),
            ),
    );
  }

  Widget _file(MpColors c, bool mine) {
    final m = widget.m;
    final sub = m.progress != null ? '${fmtSize((m.size * m.progress!).round())} of ${fmtSize(m.size)}' : '${m.name.contains('.') ? '${m.name.split('.').last.toUpperCase()} · ' : ''}${fmtSize(m.size)}';
    return SizedBox(
      width: widget.desktop ? 300 : 224,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(color: mine ? c.quote : c.surface, borderRadius: BorderRadius.circular(MpRadius.tile)), alignment: Alignment.center, child: MpIcon('file', size: 22, color: mine ? c.onAccent : c.text)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, w: FontWeight.w700, color: mine ? c.onAccent : c.text)),
              Text(sub, style: mpStyle(context, size: MpText.meta, color: mine ? c.onAccentSub : c.text2)),
            ]),
          ),
          if (widget.desktop && !mine) IconBtn('folder', size: 32, iconSize: 16, onTap: () => showInFolder(m), tip: 'Show in folder'),
        ]),
        _progress(c, mine),
      ]),
    );
  }

  Widget _image(MpColors c, bool mine) {
    final m = widget.m;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.file(
          File(m.path),
          width: 232, height: 168, fit: BoxFit.cover, cacheWidth: 600,
          frameBuilder: (_, child, frame, sync) => AnimatedOpacity(opacity: sync || frame != null ? 1 : 0, duration: Motion.d(240), child: child),
          errorBuilder: (_, _, _) => Container(
            width: 232, height: 168, color: c.imgPh,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [MpIcon('image', size: 28, stroke: 1.4, color: c.text2), const SizedBox(height: 4), Text(m.name, style: mpStyle(context, size: MpText.meta, color: c.text2))]),
          ),
        ),
      ),
      if (m.progress != null) SizedBox(width: 224, child: _progress(c, mine)),
    ]);
  }
}

class _MsgMenu extends StatefulWidget {
  final Msg m;
  final bool desktop;
  final void Function(String) onReact;
  final VoidCallback onReply, onCopy, onDelete, onOpen;
  const _MsgMenu({required this.m, required this.desktop, required this.onReact, required this.onReply, required this.onCopy, required this.onDelete, required this.onOpen});
  @override
  State<_MsgMenu> createState() => _MsgMenuState();
}

class _MsgMenuState extends State<_MsgMenu> {
  bool _more = false;
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context), m = widget.m;
    void act(VoidCallback f) {
      Navigator.pop(context);
      f();
    }

    Widget emoji(String e) => Pressable(
          onTap: () => act(() => widget.onReact(e)),
          pressScale: .8,
          hover: c.surface2,
          color: m.reacts[e]?.contains('me') == true ? c.surface2 : null,
          child: SizedBox(width: 44, height: 44, child: Center(child: Text(e, style: const TextStyle(fontSize: 22)))),
        );
    Widget item(String icon, String label, VoidCallback f) => Pressable(
          onTap: () => act(f),
          pressScale: .98,
          radius: BorderRadius.circular(14),
          hover: c.surface2,
          child: SizedBox(height: 48, child: Row(children: [const SizedBox(width: 12), MpIcon(icon, size: 20), const SizedBox(width: 16), Text(label, style: mpStyle(context))])),
        );

    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: m.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () {},
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(999), border: Border.all(color: c.line)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      for (final e in quickEmoji) emoji(e),
                      Pressable(
                        onTap: () => setState(() => _more = !_more),
                        color: c.surface2,
                        child: SizedBox(width: 44, height: 44, child: Center(child: AnimatedRotation(turns: _more ? .125 : 0, duration: Motion.d(240), curve: Motion.curve, child: const MpIcon('add', size: 20, stroke: 1.8)))),
                      ),
                    ]),
                  ),
                ),
                AnimatedSize(
                  duration: Motion.d(260),
                  curve: Motion.curve,
                  child: !_more
                      ? const SizedBox(height: 0)
                      : Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Container(
                            width: 6 * 44 + 4 * 2 + 10,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: c.line)),
                            child: Wrap(spacing: 2, runSpacing: 2, children: [for (final e in moreEmoji) emoji(e)]),
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .8),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    decoration: BoxDecoration(
                      color: m.mine ? c.accent : c.surface2,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(20), topRight: const Radius.circular(20),
                        bottomLeft: Radius.circular(m.mine ? 20 : 6), bottomRight: Radius.circular(m.mine ? 6 : 20),
                      ),
                    ),
                    child: Text(m.preview, maxLines: 6, overflow: TextOverflow.ellipsis, style: mpStyle(context, color: m.mine ? c.onAccent : c.text)),
                  ),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () {},
                  child: Container(
                    width: 224,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(20)),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      item('reply', 'Reply', widget.onReply),
                      if (m.kind == 'text') item('copy', 'Copy', widget.onCopy) else item('file', 'Open', widget.onOpen),
                      item('delete', 'Delete', widget.onDelete),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
