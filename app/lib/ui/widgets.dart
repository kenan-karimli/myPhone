import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core.dart';
import '../store.dart';
import '../tokens.dart';

String timeLabel(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts), now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days == 0) return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  if (days == 1) return 'Yesterday';
  if (days < 7) return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];
  return '${d.day}.${d.month.toString().padLeft(2, '0')}';
}

String dayLabel(int ts) {
  final t = timeLabel(ts);
  return t.contains(':') ? 'Today' : t;
}

String statusOf(String devId) {
  if (store.online[devId] == true) return 'Online';
  final s = store.lastSeen[devId];
  if (s == null) return 'Offline';
  final m = DateTime.now().difference(s).inMinutes;
  return m < 1 ? 'last seen just now' : m < 60 ? 'last seen ${m}m ago' : m < 1440 ? 'last seen ${m ~/ 60}h ago' : 'last seen ${timeLabel(s.millisecondsSinceEpoch)}';
}

class OnlineDot extends StatelessWidget {
  final bool on;
  final double size;
  final Color? border;
  const OnlineDot(this.on, {super.key, this.size = 8, this.border});
  @override
  Widget build(BuildContext context) => AnimatedScale(
        scale: on ? 1 : 0,
        duration: Motion.d(260),
        curve: on ? Motion.pop : Curves.easeIn,
        child: Container(
          width: size, height: size,
          decoration: BoxDecoration(color: MpColors.of(context).dot, shape: BoxShape.circle, border: border == null ? null : Border.all(color: border!, width: 2)),
        ),
      );
}

class DeviceAvatar extends StatelessWidget {
  final String kind;
  final double size;
  final bool? online; // null: no badge
  final bool square;
  const DeviceAvatar(this.kind, {super.key, this.size = 48, this.online, this.square = false});
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    return SizedBox(
      width: size, height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: size, height: size,
          decoration: square
              ? BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(size > 56 ? 16 : 10), border: Border.all(color: c.line))
              : BoxDecoration(color: c.surface2, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: MpIcon(icons.containsKey(kind) ? kind : 'desktop', size: size * .5, color: c.text),
        ),
        if (online != null) Positioned(right: -3, bottom: -3, child: OnlineDot(online!, size: 12, border: square ? c.surface : c.bg)),
      ]),
    );
  }
}

/// Scales down a touch while pressed; hover tint on desktop.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap, onLongPress;
  final void Function(Offset global)? onSecondaryTap;
  final Color? hover, color;
  final BorderRadius radius;
  final EdgeInsets padding;
  final double pressScale;
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress, this.onSecondaryTap, this.hover, this.color, this.radius = const BorderRadius.all(Radius.circular(999)), this.padding = EdgeInsets.zero, this.pressScale = .96});
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false, _hover = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress == null ? null : () { setState(() => _down = false); widget.onLongPress!(); },
        onSecondaryTapUp: widget.onSecondaryTap == null ? null : (d) => widget.onSecondaryTap!(d.globalPosition),
        child: AnimatedScale(
          scale: _down ? widget.pressScale : 1,
          duration: Motion.d(140),
          curve: Motion.curve,
          child: AnimatedContainer(
            duration: Motion.d(160),
            curve: Motion.curve,
            padding: widget.padding,
            decoration: BoxDecoration(color: _hover && widget.hover != null ? widget.hover : (widget.color ?? Colors.transparent), borderRadius: widget.radius),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class IconBtn extends StatelessWidget {
  final String icon;
  final VoidCallback? onTap;
  final double size, iconSize;
  final Color? color, bg;
  final String? tip;
  const IconBtn(this.icon, {super.key, this.onTap, this.size = 44, this.iconSize = 22, this.color, this.bg, this.tip});
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final b = Pressable(
      onTap: onTap,
      color: bg,
      hover: bg == null ? c.surface2 : null,
      child: SizedBox(width: size, height: size, child: Center(child: MpIcon(icon, size: iconSize, color: color ?? c.text, stroke: bg != null ? 1.9 : 1.6))),
    );
    return tip == null ? b : Tooltip(message: tip!, child: b);
  }
}

class PillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool solid;
  final String? icon;
  final double height;
  final bool expand;
  const PillButton(this.label, {super.key, this.onTap, this.solid = true, this.icon, this.height = 48, this.expand = false});
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final fg = solid ? c.bg : c.text;
    return AnimatedOpacity(
      opacity: onTap == null ? .4 : 1,
      duration: Motion.d(200),
      child: Pressable(
        onTap: onTap,
        color: solid ? c.text : Colors.transparent,
        hover: solid ? null : c.surface2,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: solid ? null : BoxDecoration(borderRadius: BorderRadius.circular(999), border: Border.all(color: c.line)),
          child: Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[MpIcon(icon!, size: 18, color: fg, stroke: 1.8), const SizedBox(width: 8)],
            Text(label, style: mpStyle(context, w: FontWeight.w700, color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// iOS-ish switch drawn in tokens; thumb glides, track cross-fades.
class MpSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const MpSwitch(this.value, this.onChanged, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    return Semantics(
      toggled: value,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: Motion.d(220),
            curve: Motion.curve,
            width: 46, height: 28,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: value ? c.accent : c.surface2, borderRadius: BorderRadius.circular(999), border: Border.all(color: value ? c.accent : c.line)),
            child: AnimatedAlign(
              duration: Motion.d(260),
              curve: Motion.pop,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(width: 20, height: 20, decoration: BoxDecoration(color: value ? c.onAccent : c.text2, shape: BoxShape.circle)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Segmented control with a sliding indicator.
class MpSegmented<T> extends StatelessWidget {
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  const MpSegmented({super.key, required this.items, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final i = items.indexWhere((e) => e.$1 == value);
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(999)),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth / items.length;
        return Stack(children: [
          AnimatedPositioned(
            duration: Motion.d(280),
            curve: Motion.curve,
            left: w * i, top: 0, bottom: 0, width: w,
            child: Container(decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(999), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 6, offset: const Offset(0, 1))])),
          ),
          Row(children: [
            for (final e in items)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(e.$1),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: Motion.d(200),
                        style: mpStyle(context, size: MpText.meta, w: e.$1 == value ? FontWeight.w700 : FontWeight.w500, color: e.$1 == value ? c.text : c.text2),
                        child: Text(e.$2),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ]);
      }),
    );
  }
}

/// Fade + rise + slight grow; used for newly arrived items.
class EnterAnim extends StatefulWidget {
  final Widget child;
  final bool animate;
  final Alignment origin;
  const EnterAnim({super.key, required this.child, this.animate = true, this.origin = Alignment.bottomCenter});
  @override
  State<EnterAnim> createState() => _EnterAnimState();
}

class _EnterAnimState extends State<EnterAnim> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: Motion.d(340), value: widget.animate ? 0 : 1)..forward();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: Motion.curve);
    return FadeTransition(
      opacity: a,
      child: AnimatedBuilder(
        animation: a,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, 14 * (1 - a.value)),
          child: Transform.scale(scale: .94 + .06 * a.value, alignment: widget.origin, child: child),
        ),
        child: widget.child,
      ),
    );
  }
}

/// Animated in/out wrapper for overlays (menus, dialogs).
Widget popTransition(Animation<double> a, Widget child, {Alignment origin = Alignment.center}) {
  final c = CurvedAnimation(parent: a, curve: Motion.curve, reverseCurve: Curves.easeIn);
  return FadeTransition(opacity: c, child: ScaleTransition(scale: Tween(begin: .92, end: 1.0).animate(c), alignment: origin, child: child));
}

void showToast(BuildContext context, String text) {
  final c = MpColors.of(context);
  final overlay = Overlay.of(context);
  late OverlayEntry e;
  e = OverlayEntry(builder: (_) => _Toast(text: text, c: c, onDone: () => e.remove()));
  overlay.insert(e);
}

class _Toast extends StatefulWidget {
  final String text;
  final MpColors c;
  final VoidCallback onDone;
  const _Toast({required this.text, required this.c, required this.onDone});
  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final _a = AnimationController(vsync: this, duration: Motion.d(260));
  @override
  void initState() {
    super.initState();
    _a.forward().then((_) => Future.delayed(const Duration(milliseconds: 1500))).then((_) => mounted ? _a.reverse() : null).then((_) => widget.onDone());
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned(
        left: 0, right: 0, bottom: 96,
        child: IgnorePointer(
          child: Center(
            child: popTransition(_a, Material(
              color: widget.c.text,
              borderRadius: BorderRadius.circular(999),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10), child: Text(widget.text, style: mpStyle(context, size: MpText.meta, w: FontWeight.w500, color: widget.c.bg))),
            ), origin: Alignment.bottomCenter),
          ),
        ),
      );
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
        child: Text(text.toUpperCase(), style: mpStyle(context, size: MpText.meta, w: FontWeight.w700, color: MpColors.of(context).text2).copyWith(letterSpacing: .8)),
      );
}

/// Rebuilds on any store change.
class StoreBuilder extends StatelessWidget {
  final WidgetBuilder builder;
  const StoreBuilder({super.key, required this.builder});
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: store, builder: (c, _) => builder(c));
}

String previewFor(Device d) {
  final l = store.chat(d.id);
  if (l.isEmpty) return 'No messages yet';
  return (l.last.mine ? 'You: ' : '') + l.last.preview;
}

/// Little battery glyph + percent. Hidden until the device reports one.
class BatteryChip extends StatelessWidget {
  final String devId;
  final bool compact;
  const BatteryChip(this.devId, {super.key, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final b = store.battery[devId];
    if (b == null) return const SizedBox.shrink();
    final c = MpColors.of(context);
    final level = (b['level'] as int).clamp(0, 100);
    final charging = b['charging'] == true;
    final color = level <= 15 && !charging ? const Color(0xFFE5484D) : c.text2;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 20, height: 11,
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(border: Border.all(color: color, width: 1.2), borderRadius: BorderRadius.circular(3)),
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: level / 100),
          duration: Motion.d(500),
          curve: Motion.curve,
          builder: (_, v, _) => FractionallySizedBox(widthFactor: v.clamp(.06, 1), child: Container(decoration: BoxDecoration(color: charging ? c.dot : color, borderRadius: BorderRadius.circular(1.5)))),
        ),
      ),
      Container(width: 2, height: 4, margin: const EdgeInsets.only(left: 1), decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1))),
      if (!compact) ...[
        const SizedBox(width: 5),
        Text('$level%${charging ? ' ⚡' : ''}', style: mpStyle(context, size: MpText.meta, color: color)),
      ],
    ]);
  }
}

/// Message text where links (http/https/www) open in the browser.
class LinkText extends StatefulWidget {
  final String text, highlight;
  final TextStyle style;
  const LinkText(this.text, {super.key, required this.style, this.highlight = ''});
  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  static final _url = RegExp(r'(https?://|www\.)[^\s<>"]+[^\s<>".,;:!?)\]]', caseSensitive: false);
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
    final spans = <InlineSpan>[];
    final hlBg = MpColors.of(context).accent.withValues(alpha: .35);
    // Plain text, with search matches marked.
    void plain(String t) {
      final q = widget.highlight.trim().toLowerCase();
      if (q.isEmpty) return spans.add(TextSpan(text: t));
      var j = 0;
      final lower = t.toLowerCase();
      for (var k = lower.indexOf(q); k >= 0; k = lower.indexOf(q, j)) {
        if (k > j) spans.add(TextSpan(text: t.substring(j, k)));
        spans.add(TextSpan(text: t.substring(k, k + q.length), style: TextStyle(backgroundColor: hlBg, fontWeight: FontWeight.w700)));
        j = k + q.length;
      }
      if (j < t.length) spans.add(TextSpan(text: t.substring(j)));
    }

    var i = 0;
    for (final m in _url.allMatches(widget.text)) {
      if (m.start > i) plain(widget.text.substring(i, m.start));
      final link = m.group(0)!;
      final tap = TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(link.startsWith('www.') ? 'https://$link' : link), mode: LaunchMode.externalApplication);
      _taps.add(tap);
      spans.add(TextSpan(text: link, style: const TextStyle(decoration: TextDecoration.underline), recognizer: tap, mouseCursor: SystemMouseCursors.click));
      i = m.end;
    }
    if (i < widget.text.length) plain(widget.text.substring(i));
    if (spans.length == 1 && spans.first is TextSpan && (spans.first as TextSpan).style == null) return Text(widget.text, style: widget.style);
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
