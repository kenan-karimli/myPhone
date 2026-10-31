// Opt-in, uses real Claude Code (Haiku, a few cents):
//   REAL_CLAUDE=1 flutter test test/assistant_real_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/agents.dart';
import 'package:myphone/assistant.dart';
import 'package:myphone/net.dart';
import 'package:myphone/store.dart';

void main() {
  test('text "send me the DSA deck" -> Claude finds and sends the file, marked as Claude; "hello" -> silence', () async {
    final root = await Directory.systemTemp.createTemp('assist');
    final docs = Directory('${root.path}/docs')..createSync();
    File('${docs.path}/DSA_Final_Presentation.pptx').writeAsBytesSync(List.filled(2048, 7));
    File('${docs.path}/groceries.txt').writeAsStringSync('milk');

    final pc = await Store.open(Directory('${root.path}/pc'));
    pc.set('assistantModel', 'haiku');
    final phoneStore = await Store.open(Directory('${root.path}/phone'));
    final pcClient = Client(pc, myPort: 4841);
    late final AgentHost host;
    var approvals = 0;
    host = AgentHost(pc, alert: (_, ev) {
      if (ev['kind'] == 'approve') {
        approvals++; // like pressing Allow on the phone
        host.approve(ev['sid'], ev['rid'], true);
      }
    });
    final assistant = Assistant(pc, host, pcClient, Directory('${root.path}/pcdata'), port: 4841, home: root.path);
    final pcNode = Node(pc, saveDir: () async => Directory('${root.path}/pc-dl'), localRoutes: assistant.handleLocal, onIncoming: (d, m) {
      if (m != null) assistant.onMessage(d, m);
    });
    await pcNode.start(listenPort: 4841);
    final phoneNode = Node(phoneStore, saveDir: () async => Directory('${root.path}/phone-dl'), onIncoming: (_, _) {});
    await phoneNode.start(listenPort: 4842);
    final phone = Client(phoneStore, myPort: 4842);
    final pcDev = await phone.hello('127.0.0.1:4841');
    await phoneStore.upsertDevice(pcDev);
    final phoneDev = pc.devices.values.single;
    pc.setPresence(phoneDev.id, true);

    await phone.sendText(pcDev, 'send me the presentation deck for the DSA project, it is in ${docs.path}');
    List<Msg> got() => phoneStore.chat(pcDev.id).where((m) => !m.mine).toList();
    for (var i = 0; i < 1200 && !got().any((m) => m.kind == 'file'); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    final file = got().firstWhere((m) => m.kind == 'file');
    expect(file.name, 'DSA_Final_Presentation.pptx');
    expect(file.by, 'claude');
    expect(File(file.path).lengthSync(), 2048);

    // Let the first turn finish, then small talk must stay silent.
    for (var i = 0; i < 600 && host.sessions['assist-${phoneDev.id}']!.status != 'idle'; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    final before = got().length;
    await phone.sendText(pcDev, 'hello');
    final s = host.sessions['assist-${phoneDev.id}']!;
    await Future.delayed(const Duration(seconds: 1));
    for (var i = 0; i < 600 && s.status != 'idle'; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await Future.delayed(const Duration(seconds: 1));
    // ignore: avoid_print
    print('approvals asked: $approvals');
    // ignore: avoid_print
    print('replies: ${got().map((m) => '${m.by}:${m.kind}:${m.kind == 'text' ? m.text : m.name}').join(' | ')}');
    expect(got().length, before, reason: '"hello" should get no reply');

    host.dispose();
    phone.close();
    pcClient.close();
    await pcNode.stop();
    await phoneNode.stop();
    await root.delete(recursive: true);
  }, skip: Platform.environment['REAL_CLAUDE'] != '1', timeout: const Timeout(Duration(minutes: 4)));
}
