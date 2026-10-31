import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import '../store.dart';
import '../tokens.dart';
import 'widgets.dart';

/// Live picture of another device's screen. Reconnects by itself.
class ScreenView extends StatefulWidget {
  final Device pc;
  final String quality;
  final BoxFit fit;
  final ValueChanged<int>? onFps;
  const ScreenView({super.key, required this.pc, this.quality = 'medium', this.fit = BoxFit.contain, this.onFps});
  @override
  State<ScreenView> createState() => _ScreenViewState();
}

class _ScreenViewState extends State<ScreenView> {
  StreamSubscription<Uint8List>? _sub;
  Uint8List? _frame;
  String? _error;
  int _count = 0;
  Timer? _fpsTimer, _retry;

  @override
  void initState() {
    super.initState();
    _connect();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      widget.onFps?.call(_count);
      _count = 0;
    });
  }

  @override
  void didUpdateWidget(ScreenView old) {
    super.didUpdateWidget(old);
    if (old.quality != widget.quality || old.pc.id != widget.pc.id) _connect();
  }

  void _connect() {
    _sub?.cancel();
    _retry?.cancel();
    _sub = client.screen(widget.pc, widget.quality).listen(
      (f) {
        _count++;
        if (mounted) {
          setState(() {
            _frame = f;
            _error = null;
          });
        }
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _error = e is HttpException ? e.message : 'Can’t reach ${widget.pc.name}');
        _retry = Timer(const Duration(seconds: 3), _connect);
      },
      onDone: () {
        if (mounted) _retry = Timer(const Duration(seconds: 1), _connect);
      },
      cancelOnError: true,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _fpsTimer?.cancel();
    _retry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: AnimatedSwitcher(
      duration: Motion.d(300),
      child: _frame != null
          ? Image.memory(_frame!, key: const ValueKey('frame'), gaplessPlayback: true, fit: widget.fit, filterQuality: FilterQuality.medium, width: double.infinity, height: double.infinity)
          : Container(
              key: ValueKey(_error ?? 'wait'),
              color: Colors.black,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_error == null)
                  SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70, strokeCap: StrokeCap.round))
                else
                  const MpIcon('screen', size: 26, color: Colors.white54),
                const SizedBox(height: 10),
                Text(_error ?? 'Connecting to ${widget.pc.name}…', textAlign: TextAlign.center, style: mpStyle(context, size: MpText.meta, color: Colors.white70)),
              ]),
            ),
      ),
    );
  }
}

/// Fullscreen live view: pinch to zoom, tap to show/hide controls, any orientation.
class ScreenPage extends StatefulWidget {
  final Device pc;
  const ScreenPage({super.key, required this.pc});
  @override
  State<ScreenPage> createState() => _ScreenPageState();
}

class _ScreenPageState extends State<ScreenPage> {
  bool _chrome = true;
  int _fps = 0;
  late String _quality = store.get('screenQuality', 'medium');
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([]); // follow the phone: rotate for landscape
    _autoHide();
  }

  @override
  void dispose() {
    _hide?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _autoHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () => mounted ? setState(() => _chrome = false) : null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _chrome = !_chrome);
          if (_chrome) _autoHide();
        },
        child: Stack(children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 6,
              child: ScreenView(pc: widget.pc, quality: _quality, onFps: (f) => mounted ? setState(() => _fps = f) : null),
            ),
          ),
          Positioned(
            left: 0, right: 0, top: 0,
            child: IgnorePointer(
              ignoring: !_chrome,
              child: AnimatedOpacity(
                opacity: _chrome ? 1 : 0,
                duration: Motion.d(220),
                child: AnimatedSlide(
                  offset: _chrome ? Offset.zero : const Offset(0, -.3),
                  duration: Motion.d(260),
                  curve: Motion.curve,
                  child: Container(
                    decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC000000), Color(0x00000000)])),
                    padding: EdgeInsets.fromLTRB(8, MediaQuery.paddingOf(context).top + 8, 16, 28),
                    child: Row(children: [
                      IconBtn('back', iconSize: 24, color: Colors.white, onTap: () => Navigator.pop(context)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(widget.pc.name, style: mpStyle(context, w: FontWeight.w700, color: Colors.white)),
                          Text('Live · $_fps fps', style: mpStyle(context, size: MpText.meta, color: Colors.white70)),
                        ]),
                      ),
                      SizedBox(
                        width: 210,
                        child: Theme(
                          data: Theme.of(context).copyWith(extensions: [MpColors.build(true, accents[store.get<num>('accent', 0).toInt()])]),
                          child: Builder(
                            builder: (context) => MpSegmented(
                              items: const [('low', 'Low'), ('medium', 'Medium'), ('high', 'High')],
                              value: _quality,
                              onChanged: (q) {
                                setState(() => _quality = q);
                                store.set('screenQuality', q);
                                _autoHide();
                              },
                            ),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Small live panel (16:9). Tap for fullscreen; it pauses meanwhile so only one stream runs.
class ScreenPanel extends StatefulWidget {
  final Device pc;
  const ScreenPanel({super.key, required this.pc});
  @override
  State<ScreenPanel> createState() => _ScreenPanelState();
}

class _ScreenPanelState extends State<ScreenPanel> {
  bool _full = false;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: GestureDetector(
          onTap: () async {
            setState(() => _full = true);
            await openScreen(context, widget.pc);
            if (mounted) setState(() => _full = false);
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: _full ? const ColoredBox(color: Colors.black) : ScreenView(pc: widget.pc, quality: store.get('screenQuality', 'medium')),
            ),
          ),
        ),
      );
}

Future<void> openScreen(BuildContext context, Device pc) => Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: Motion.d(360),
      reverseTransitionDuration: Motion.d(280),
      pageBuilder: (_, _, _) => ScreenPage(pc: pc),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Motion.curve), child: child),
    ));
