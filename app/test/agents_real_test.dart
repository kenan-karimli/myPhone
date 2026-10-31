// Opt-in, uses real Claude Code (and a little of your quota):
//   REAL_CLAUDE=1 flutter test test/agents_real_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/agents.dart';
import 'package:myphone/store.dart';

void main() {
  test('real claude: approval request arrives, deny is respected', () async {
    final root = await Directory.systemTemp.createTemp('agents-real');
    final store = await Store.open(Directory('${root.path}/pc'));
    final host = AgentHost(store, alert: (_, _) {});
    final s = await host.start(root.path, 'Use the Bash tool to run exactly: mkdir made-by-agent . Then reply in one short sentence.', 'phone');
    for (var i = 0; i < 600 && s.pending.isEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(s.pending, isNotEmpty, reason: 'no permission request from claude');
    host.approve(s.key, s.pending.keys.first, false);
    for (var i = 0; i < 600 && !s.events.any((e) => e['k'] == 'result'); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(s.events.any((e) => e['k'] == 'result'), isTrue);
    expect(Directory('${root.path}/made-by-agent').existsSync(), isFalse);
    // ignore: avoid_print
    print('events: ${s.events.map((e) => e['k']).join(', ')}');
    host.dispose();
    await root.delete(recursive: true);
  }, skip: Platform.environment['REAL_CLAUDE'] != '1', timeout: const Timeout(Duration(minutes: 3)));
}
