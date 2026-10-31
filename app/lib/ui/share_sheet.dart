import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core.dart';
import '../store.dart';
import '../tokens.dart';
import 'device_list.dart';
import 'widgets.dart';

const _share = MethodChannel('myphone/share');

/// Android "Share → myPhone": [onShared] gets each batch of files/text.
void listenForShares(void Function(List<String> paths, String text) onShared, {void Function()? onFocus}) {
  if (!Platform.isAndroid) return;
  _share.setMethodCallHandler((call) async {
    if (call.method == 'focus') onFocus?.call();
    if (call.method == 'shared') {
      final m = Map<String, dynamic>.from(call.arguments as Map);
      onShared(List<String>.from(m['paths'] ?? const []), m['text'] ?? '');
    }
  });
  _share.invokeMethod('ready');
}

/// "Send to…" sheet. Returns the device the items were sent to.
/// Returns the target: a device, or (on the phone) "Claude on `PC`" when [claude] is true.
/// For a device the items are sent here; for Claude the caller takes over.
Future<(Device, bool claude)?> showShareSheet(BuildContext context, List<String> paths, String text, {bool desktop = false}) async {
  final c = MpColors.of(context);
  final what = paths.isEmpty
      ? text
      : paths.length == 1
          ? paths.first.split('/').last
          : '${paths.length} files';
  Widget content(BuildContext ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .7),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (desktop)
            const SizedBox(height: 24)
          else
            Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.fromLTRB(0, 12, 0, 20), decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(999)))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text('Send to…', style: mpStyle(ctx, size: MpText.title, w: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                MpIcon(paths.isEmpty ? 'send' : (paths.length == 1 && kindForFile(paths.first) == 'image' ? 'image' : 'file'), size: 22),
                const SizedBox(width: 12),
                Expanded(child: Text(what, maxLines: 2, overflow: TextOverflow.ellipsis, style: mpStyle(ctx, w: FontWeight.w500))),
              ]),
            ),
          ),
          if (store.devices.isEmpty)
            Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 32), child: Text('Add a device first.', style: mpStyle(ctx, color: c.text2)))
          else
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 16), children: [
                for (final (i, d) in sortedDevices().indexed)
                  EnterAnim(
                    key: ValueKey(d.id),
                    child: Pressable(
                      onTap: () => Navigator.pop(ctx, (d, false)),
                      pressScale: .98,
                      radius: BorderRadius.circular(MpRadius.bubble),
                      hover: c.surface2,
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        DeviceAvatar(d.kind, size: 44),
                        const SizedBox(width: 16),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(d.name, style: mpStyle(ctx, w: FontWeight.w700)),
                          Row(children: [
                            if (store.online[d.id] == true) const Padding(padding: EdgeInsets.only(right: 6), child: OnlineDot(true)),
                            Text(statusOf(d.id), style: mpStyle(ctx, size: MpText.meta, color: c.text2)),
                          ]),
                        ])),
                        if (i == 0) MpIcon('send', size: 20, color: c.text2),
                      ]),
                    ),
                  ),
                // Ask Claude about it, on any PC (phone only: agents are started from here).
                if (!desktop)
                  for (final d in sortedDevices().where((d) => d.kind == 'laptop' || d.kind == 'desktop'))
                    EnterAnim(
                      key: ValueKey('claude-${d.id}'),
                      child: Pressable(
                        onTap: () => Navigator.pop(ctx, (d, true)),
                        pressScale: .98,
                        radius: BorderRadius.circular(MpRadius.bubble),
                        hover: c.surface2,
                        padding: const EdgeInsets.all(12),
                        child: Row(children: [
                          Container(width: 44, height: 44, decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle), alignment: Alignment.center, child: MpIcon('assistant', size: 20, color: c.onAccent)),
                          const SizedBox(width: 16),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Claude on ${d.name}', style: mpStyle(ctx, w: FontWeight.w700)),
                            Text('Ask an agent about ${paths.isEmpty ? 'this' : paths.length == 1 ? 'this file' : 'these files'}', style: mpStyle(ctx, size: MpText.meta, color: c.text2)),
                          ])),
                        ]),
                      ),
                    ),
              ]),
            ),
        ]),
      );

  final dev = desktop
      ? await showGeneralDialog<(Device, bool)>(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Close',
          barrierColor: c.scrim,
          transitionDuration: Motion.d(240),
          pageBuilder: (ctx, _, _) => Center(
            child: Material(
              color: c.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: c.line)),
              child: SizedBox(width: 420, child: content(ctx)),
            ),
          ),
          transitionBuilder: (ctx, a, _, child) => popTransition(a, child),
        )
      : await showModalBottomSheet<(Device, bool)>(
          context: context,
          isScrollControlled: true,
          backgroundColor: c.surface,
          barrierColor: c.scrim,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(MpRadius.sheet))),
          sheetAnimationStyle: AnimationStyle(duration: Motion.d(360), reverseDuration: Motion.d(240), curve: Motion.curve),
          builder: (ctx) => SafeArea(child: content(ctx)),
        );
  if (dev == null || dev.$2) return dev;
  for (final p in paths) {
    await client.sendFile(dev.$1, p);
  }
  if (text.trim().isNotEmpty) await client.sendText(dev.$1, text.trim());
  return dev;
}
