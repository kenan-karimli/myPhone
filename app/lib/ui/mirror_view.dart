import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import '../mirror.dart';
import '../store.dart';
import '../tokens.dart';
import 'widgets.dart';

/// PC: the phone's screen in a window. Click = tap, drag = swipe, hold = long press,
/// wheel = scroll, right-click = Back, typing goes to the focused field on the phone.
class PhoneMirrorPage extends StatefulWidget {
  final Device phone;
  const PhoneMirrorPage({super.key, required this.phone});
  @override
  State<PhoneMirrorPage> createState() => _PhoneMirrorPageState();
}

class _PhoneMirrorPageState extends State<PhoneMirrorPage> {
  MirrorSession? _s;
  StreamSubscription? _sub;
  Uint8List? _frame;
  String? _error;
  int _fps = 0, _count = 0;
  Timer? _fpsTimer;
  final _focus = FocusNode();
  // current pointer gesture
  final _pts = <Offset>[];
  DateTime? _down;
  Size _box = Size.zero;

  @override
  void initState() {
    super.initState();
    mirrorHost?.addListener(_attach);
    _attach();
    if (_s == null) _request();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _fps = _count;
          _count = 0;
        });
      }
    });
  }

  Future<void> _request() async {
    if (mirrorHost == null) {
      setState(() => _error = 'Port 4749 is busy, so the phone can’t connect. Restart myPhone.');
      return;
    }
    try {
      await client.sendEvent(widget.phone, {'t': 'mirror'});
    } catch (_) {
      if (mounted) setState(() => _error = '${widget.phone.name} isn’t reachable right now.');
    }
  }

  void _attach() {
    final s = mirrorHost?.sessions[widget.phone.id];
    if (s == _s) {
      if (mounted) setState(() {});
      return;
    }
    _sub?.cancel();
    _s = s;
    _frame = s?.last;
    _sub = s?.frames.stream.listen((f) {
      _count++;
      if (mounted) setState(() => _frame = f);
    }, onError: (e) => mounted ? setState(() => _error = '$e') : null);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    mirrorHost?.removeListener(_attach);
    _sub?.cancel();
    _fpsTimer?.cancel();
    _s?.close(); // ends sharing on the phone
    _focus.dispose();
    super.dispose();
  }

  void _send(Map<String, dynamic> ev) => _s?.input(ev);

  Offset _norm(Offset p) => Offset((p.dx / _box.width).clamp(0, 1), (p.dy / _box.height).clamp(0, 1));

  void _up() {
    if (_pts.isEmpty || _down == null) return;
    final ms = DateTime.now().difference(_down!).inMilliseconds;
    final first = _pts.first, lastP = _pts.last;
    final moved = (lastP - first).distance;
    if (moved < 6) {
      final p = _norm(first);
      _send({'a': ms > 500 ? 'long' : 'tap', 'x': p.dx, 'y': p.dy});
    } else {
      // Keep up to ~40 points so curved drags stay curved.
      final step = (_pts.length / 40).ceil().clamp(1, 1000);
      final pts = [for (var i = 0; i < _pts.length; i += step) _norm(_pts[i]), _norm(lastP)];
      _send({'a': 'swipe', 'pts': [for (final p in pts) [p.dx, p.dy]], 'ms': ms.clamp(60, 2500)});
    }
    _pts.clear();
    _down = null;
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.backspace) {
      _send({'a': 'backspace'});
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _send({'a': 'enter'});
    } else if (k == LogicalKeyboardKey.escape) {
      _send({'a': 'back'});
    } else if (e.character != null && e.character!.isNotEmpty && e.character!.codeUnitAt(0) >= 32) {
      _send({'a': 'text', 's': e.character});
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final s = _s;
    final ratio = s != null && s.w > 0 && s.h > 0 ? s.w / s.h : 9 / 19.5;

    Widget screen;
    if (_frame != null) {
      screen = LayoutBuilder(builder: (_, box) {
        _box = box.biggest;
        return Listener(
          onPointerDown: (e) {
            _focus.requestFocus();
            if (e.buttons == kSecondaryMouseButton) {
              _send({'a': 'back'});
              return;
            }
            _down = DateTime.now();
            _pts
              ..clear()
              ..add(e.localPosition);
          },
          onPointerMove: (e) => _down != null ? _pts.add(e.localPosition) : null,
          onPointerUp: (_) => _up(),
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              final p = _norm(e.localPosition);
              _send({'a': 'scroll', 'x': p.dx, 'y': p.dy, 'dy': (e.scrollDelta.dy / 120).clamp(-3, 3)});
            }
          },
          child: MouseRegion(cursor: SystemMouseCursors.precise, child: Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.fill, width: double.infinity, height: double.infinity, filterQuality: FilterQuality.medium)),
        );
      });
    } else {
      screen = Container(
        color: Colors.black,
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_error == null) const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70, strokeCap: StrokeCap.round)) else const MpIcon('error', color: Colors.white70),
          const SizedBox(height: 16),
          Text(_error ?? (s == null ? 'Waiting for ${widget.phone.name}…' : 'Starting video…'), textAlign: TextAlign.center, style: mpStyle(context, w: FontWeight.w700, color: Colors.white)),
          const SizedBox(height: 8),
          if (_error == null && s == null)
            Text('On the phone, tap the notification (or open myPhone) and press “Start now”.', textAlign: TextAlign.center, style: mpStyle(context, size: MpText.meta, color: Colors.white70)),
        ]),
      );
    }

    Widget navBtn(String label, IconData icon, String a) => Tooltip(
          message: label,
          child: Pressable(
            onTap: () => _send({'a': a}),
            hover: c.surface2,
            child: SizedBox(width: 48, height: 40, child: Icon(icon, size: 20, color: c.text)),
          ),
        );

    return Scaffold(
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _key,
        child: Column(children: [
          Container(
            height: 64,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
            child: Row(children: [
              IconBtn('back', size: 36, iconSize: 20, onTap: () => Navigator.pop(context), tip: 'Close'),
              const SizedBox(width: 8),
              DeviceAvatar(widget.phone.kind, size: 36, square: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.phone.name, style: mpStyle(context, w: FontWeight.w700)),
                  Text(s == null ? 'Not connected' : (s.control ? 'Live · $_fps fps · click, drag, scroll and type' : 'Live · $_fps fps · view only'), style: mpStyle(context, size: MpText.meta, color: c.text2)),
                ]),
              ),
              if (s != null && !s.control)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999)),
                  child: Text('To control: phone → myPhone Settings → Phone control', style: mpStyle(context, size: 12, color: c.text2)),
                ),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: AspectRatio(
                  aspectRatio: ratio,
                  child: ClipRRect(borderRadius: BorderRadius.circular(18), child: AnimatedSwitcher(duration: Motion.d(300), child: KeyedSubtree(key: ValueKey(_frame != null), child: screen))),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              navBtn('Back (right-click, Esc)', Icons.arrow_back_ios_new_rounded, 'back'),
              navBtn('Home', Icons.circle_outlined, 'home'),
              navBtn('Recent apps', Icons.crop_square_rounded, 'recents'),
              const SizedBox(width: 12),
              navBtn('Notifications', Icons.notifications_none_rounded, 'notifications'),
              navBtn('Lock screen', Icons.lock_outline_rounded, 'lock'),
            ]),
          ),
        ]),
      ),
    );
  }
}
