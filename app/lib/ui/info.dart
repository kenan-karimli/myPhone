import 'package:flutter/material.dart';

import '../core.dart';
import '../store.dart';
import '../tokens.dart';
import 'widgets.dart';

/// Device details + "coming soon" features. Phone: bottom sheet. Desktop: side panel.
class DeviceInfo extends StatelessWidget {
  final Device dev;
  final bool desktop;
  final VoidCallback onRemoved;
  const DeviceInfo({super.key, required this.dev, required this.onRemoved, this.desktop = false});

  Future<void> _remove(BuildContext context) async {
    final ok = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: MpColors.of(context).scrim,
      transitionDuration: Motion.d(220),
      pageBuilder: (ctx, _, _) => Center(
        child: Material(
          color: MpColors.of(ctx).surface,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: 340,
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Remove ${dev.name}?', style: mpStyle(ctx, size: MpText.title, w: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('It disappears from your list. Chat history stays on disk, and it comes back if the device messages you again.', style: mpStyle(ctx, color: MpColors.of(ctx).text2)),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                PillButton('Cancel', solid: false, height: 44, onTap: () => Navigator.pop(ctx, false)),
                const SizedBox(width: 8),
                PillButton('Remove', height: 44, onTap: () => Navigator.pop(ctx, true)),
              ]),
            ]),
          ),
        ),
      ),
      transitionBuilder: (ctx, a, _, child) => popTransition(a, child),
    );
    if (ok == true) {
      await store.removeDevice(dev.id);
      onRemoved();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    Widget row(String k, String v) => Padding(
          padding: EdgeInsets.symmetric(vertical: desktop ? 12 : 8, horizontal: desktop ? 16 : 0),
          child: Row(children: [
            Text(k, style: mpStyle(context, size: desktop ? MpText.meta : MpText.body, color: c.text2)),
            const SizedBox(width: 16),
            Expanded(child: Text(v, textAlign: TextAlign.right, style: mpStyle(context, size: desktop ? MpText.meta : MpText.body, w: desktop ? FontWeight.w700 : FontWeight.w400))),
          ]),
        );

    return StoreBuilder(builder: (context) {
      final on = store.online[dev.id] == true;
      final head = Column(children: [
        DeviceAvatar(dev.kind, size: desktop ? 64 : 56, square: desktop),
        const SizedBox(height: 8),
        Text(dev.name, style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
        Row(mainAxisSize: MainAxisSize.min, children: [if (on) const Padding(padding: EdgeInsets.only(right: 6), child: OnlineDot(true)), Text(statusOf(dev.id), style: mpStyle(context, size: MpText.meta, color: c.text2))]),
      ]);
      final b = store.battery[dev.id];
      final rows = [
        row('Tailscale name', dev.host),
        row('Address', dev.addr.isEmpty ? '—' : dev.addr),
        row('Status', on ? 'Online' : 'Offline'),
        if (b != null) row('Battery', '${b['level']}%${b['charging'] == true ? ' · charging' : ''}'),
      ];
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        head,
        const SizedBox(height: 24),
        if (desktop)
          Container(
            decoration: BoxDecoration(border: Border.all(color: c.line), borderRadius: BorderRadius.circular(10)),
            child: Column(children: [for (var i = 0; i < rows.length; i++) ...[if (i > 0) Divider(height: 1, color: c.line), rows[i]]]),
          )
        else
          ...rows,
        const SizedBox(height: 24),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
          if (isDesktop && (dev.kind == 'phone' || dev.kind == 'tablet'))
            PillButton('Ring ${dev.kind}', solid: false, height: 44, onTap: () async {
              try {
                await client.sendEvent(dev, {'t': 'ring'});
                if (context.mounted) showToast(context, 'Ringing ${dev.name}…');
              } catch (_) {
                if (context.mounted) showToast(context, '${dev.name} isn’t reachable');
              }
            }),
          PillButton('Remove device', solid: false, height: 44, icon: 'delete', onTap: () => _remove(context)),
        ]),
      ]);
    });
  }
}

void showInfoSheet(BuildContext context, Device dev, VoidCallback onRemoved) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: MpColors.of(context).surface,
      barrierColor: MpColors.of(context).scrim,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(MpRadius.sheet))),
      sheetAnimationStyle: AnimationStyle(duration: Motion.d(360), reverseDuration: Motion.d(240), curve: Motion.curve),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 24), decoration: BoxDecoration(color: MpColors.of(ctx).line, borderRadius: BorderRadius.circular(999))),
            DeviceInfo(dev: dev, onRemoved: () {
              Navigator.pop(ctx);
              onRemoved();
            }),
          ]),
        ),
      ),
    );
