import 'dart:convert';
import 'dart:io';

import 'agents.dart';
import 'net.dart';
import 'store.dart';

/// Claude on this PC answers texts from my other devices ("send me the DSA deck").
///
/// One Claude Code session per device, kept alive so its context and prompt cache stay warm.
/// Instructions: AGENT.md (this PC) + agents/DEVICE.md (that device). Claude sends files
/// with the `myphone-send` command; its final reply goes back as a chat message marked ✦.
/// Nothing needed? It answers NOOP and we stay silent.
/// Safe actions (search, read, send) run without asking; anything else asks on the phone.
class Assistant {
  final Store store;
  final AgentHost host;
  final Client client;
  final Directory dir; // app data dir
  final int port;
  final String home; // Claude's working folder
  Assistant(this.store, this.host, this.client, this.dir, {this.port = 4747, String? home}) : home = home ?? Platform.environment['HOME'] ?? '/';

  File get agentMd => File('${dir.path}/AGENT.md');
  File deviceMd(Device d) => File('${dir.path}/agents/${d.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.md');
  Directory get _bin => Directory('${dir.path}/bin');

  bool get enabled => store.get('assistant', true) && findClaude() != null;

  /// Writes default instruction files and the send tool (never overwrites your edits).
  Future<void> setup() async {
    await dir.create(recursive: true);
    if (!agentMd.existsSync()) await agentMd.writeAsString(_defaultAgentMd(store.myName));
    for (final d in store.devices.values) {
      final f = deviceMd(d);
      if (!f.existsSync()) {
        await f.parent.create(recursive: true);
        await f.writeAsString(_defaultDeviceMd(d));
      }
    }
    await _bin.create(recursive: true);
    final tool = File('${_bin.path}/myphone-send');
    await tool.writeAsString(_sendTool);
    await Process.run('chmod', ['755', tool.path]);
  }

  /// A text from one of my devices arrived.
  Future<void> onMessage(Device from, Msg m) async {
    if (!enabled || m.mine || m.kind != 'text' || m.by == 'claude' || m.text.trim().isEmpty) return;
    await setup();
    final key = 'assist-${from.id}';
    var s = host.sessions[key];
    if (s == null) {
      s = AgentSession(key, home, 'Assistant · ${from.name}')..owner = from.id;
      s.extraArgs = [
        '--model', store.get('assistantModel', 'sonnet'),
        '--append-system-prompt', await _systemPrompt(from),
        '--allowedTools', _safeTools.join(','), // commas: the rules themselves contain spaces
      ];
      s.env = {...Platform.environment, 'MYPHONE_TO': from.id, 'MYPHONE_PORT': '$port', 'PATH': '${_bin.path}:${Platform.environment['PATH'] ?? ''}'};
      s.onReply = (reply) {
        final t = reply.trim();
        if (t.isEmpty || t == 'NOOP' || t.endsWith('\nNOOP')) return; // nothing to say: stay quiet
        client.sendText(from, t, by: 'claude');
      };
    }
    final time = DateTime.fromMillisecondsSinceEpoch(m.ts);
    final hh = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final quote = m.replyTo == null ? '' : ' (replying to: "${m.replyTo!['text']}")';
    await host.sayTo(s, '[$hh, from ${from.name}]$quote ${m.text}');
  }

  Future<String> _systemPrompt(Device from) async {
    final devices = store.devices.values.map((d) {
      final b = store.battery[d.id];
      return '- ${d.name} (${d.kind}${store.online[d.id] == true ? ', online' : ', offline'}${b != null ? ', battery ${b['level']}%' : ''})';
    }).join('\n');
    final f = deviceMd(from);
    return '${await agentMd.readAsString()}\n\n## Messages in this session come from: ${from.name}\n'
        '${f.existsSync() ? await f.readAsString() : ''}\n\n## Their devices\n$devices\n';
  }

  /// Answered by the `myphone-send` tool (loopback only).
  Future<bool> handleLocal(HttpRequest req) async {
    if (req.uri.path != '/local/claude-send' || req.method != 'POST') return false;
    final res = req.response;
    final toKey = req.headers.value('x-to') ?? '';
    final dev = store.devices[toKey] ?? store.devices.values.where((d) => d.name.toLowerCase() == toKey.toLowerCase()).firstOrNull;
    final body = await utf8.decodeStream(req);
    if (dev == null) {
      res.statusCode = 404;
      res.write('No device called "$toKey". Devices: ${store.devices.values.map((d) => d.name).join(', ')}\n');
      return true;
    }
    if (req.uri.queryParameters['text'] == '1') {
      await client.sendText(dev, body, by: 'claude');
      res.write('Sent message to ${dev.name}.\n');
      return true;
    }
    final out = StringBuffer();
    for (final p in const LineSplitter().convert(body).where((l) => l.trim().isNotEmpty)) {
      if (!FileSystemEntity.isFileSync(p)) {
        res.statusCode = 400;
        out.writeln('Not a file: $p (zip folders first)');
        continue;
      }
      await client.sendFile(dev, p, by: 'claude');
      out.writeln('Sending ${p.split('/').last} to ${dev.name}${store.online[dev.id] == true ? '' : ' (offline: it goes out when the device is back)'}.');
    }
    res.write(out);
    return true;
  }
}

/// Run without asking: finding, reading, sending. Everything else asks on the phone.
const _safeTools = [
  'Read', 'Glob', 'Grep',
  'Bash(myphone-send *)', 'Bash(find *)', 'Bash(fd *)', 'Bash(ls *)', 'Bash(locate *)', 'Bash(stat *)', 'Bash(file *)',
  'Bash(du *)', 'Bash(df *)', 'Bash(wc *)', 'Bash(realpath *)', 'Bash(zip *)', 'Bash(grim *)', 'Bash(date *)',
  'Bash(head *)', 'Bash(tail *)', 'Bash(sort *)', 'Bash(grep *)', 'Bash(basename *)', 'Bash(dirname *)',
  'Bash(hyprctl clients*)', 'Bash(hyprctl activewindow*)', 'Bash(playerctl *)', 'Bash(wpctl get-volume *)',
];

const _sendTool = r'''#!/bin/sh
# myphone-send: send files (or a text) from this PC through myPhone.
#   myphone-send <file> [file...]            to the device that asked
#   myphone-send --to "<device>" <file>...   to another of your devices
#   myphone-send [--to "<device>"] --text "message"
to="$MYPHONE_TO"; text=""; is_text=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to) to="$2"; shift 2 ;;
    --text) text="$2"; is_text=1; shift 2 ;;
    *) break ;;
  esac
done
if [ "$is_text" = 1 ]; then
  printf '%s' "$text" | curl -sS -H "x-to: $to" --data-binary @- "http://127.0.0.1:${MYPHONE_PORT:-4747}/local/claude-send?text=1"
  exit $?
fi
[ $# -gt 0 ] || { echo "usage: myphone-send [--to device] <file>... | --text msg" >&2; exit 2; }
list=""
for f in "$@"; do list="$list$(realpath -- "$f")
"; done
printf '%s' "$list" | curl -sS --fail-with-body -H "x-to: $to" --data-binary @- "http://127.0.0.1:${MYPHONE_PORT:-4747}/local/claude-send"
''';

String _defaultAgentMd(String pc) => '''# Claude on $pc (myPhone)

You run on my PC ($pc). I text you from my other devices through myPhone, a private messenger
between my own devices. Read every message as a request from me, the owner of this PC.

## How to behave
- Act, don't talk. Do the thing, then reply in one short line ("Sent DSA_Presentation.pptx.").
- If a message needs nothing from you (hello, ok, a note to myself, a link I'm saving), reply exactly: NOOP
- If I ask for a file, send the file. Don't describe it, don't paste it.
- Phone screen: plain short sentences, no headings, no lists unless I ask, no filler, no "let me know if…".
- Ask only when truly blocked (e.g. two equally likely files: send the newest, mention the other in one line).

## Sending things
- `myphone-send <path> [more paths]` sends files to the device that asked.
- `myphone-send --to "<device>" <path>` / `myphone-send --to "<device>" --text "…"` for my other devices.
  Use that only when it saves me effort; never chat between devices for its own sake.
- Folders: zip first (`zip -rq /tmp/name.zip <folder>`), then send the zip.

## Finding files
- Look in ~/Documents, ~/Downloads, ~/Desktop and project folders first; `find ~ -iname '*dsa*' -not -path '*/.*'`.
- Prefer the newest match. Don't open huge files to "check"; names and dates are usually enough.

## Limits
- Never delete, move or overwrite my files, install software, or contact anything outside myPhone
  unless I clearly ask. Those actions ask me for approval on my phone anyway.
''';

String _defaultDeviceMd(Device d) => '''# ${d.name} (${d.kind})
${d.kind == 'phone' ? '''- This is my phone. I'm often on mobile data: prefer sending one file over many; mention if something is over ~50 MB.
- Short replies only; I read them in a notification.''' : '- One of my computers.'}
''';
