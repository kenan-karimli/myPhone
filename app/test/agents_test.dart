import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/agents.dart';
import 'package:myphone/net.dart';
import 'package:myphone/store.dart';

void main() {
  test('normalize: text, tool call, tool result, result', () {
    expect(normalize({'type': 'user', 'message': {'content': 'hi'}}).single, containsPair('k', 'user'));
    expect(normalize({'type': 'user', 'isMeta': true, 'message': {'content': 'hidden'}}), isEmpty);
    final a = normalize({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'yo'}, {'type': 'tool_use', 'id': 't', 'name': 'Bash', 'input': {'command': 'ls'}}]}});
    expect(a.map((e) => e['k']), ['text', 'tool']);
    expect(a[1]['summary'], 'ls');
    expect(normalize({'type': 'result', 'subtype': 'success'}).single['ok'], isTrue);
  });

  test('phone starts an agent on the PC, approves, gets alerts', () async {
    final root = await Directory.systemTemp.createTemp('agents');
    final pcStore = await Store.open(Directory('${root.path}/pc'));
    final phoneStore = await Store.open(Directory('${root.path}/phone'));
    final alerts = <Map>[];
    final host = AgentHost(pcStore, alert: (dev, ev) => alerts.add(ev), claudePath: '${Directory.current.path}/test/fixtures/fake_claude.py');
    final pcNode = Node(pcStore, saveDir: () async => root, onIncoming: (_, _) {}, extraRoutes: host.handle);
    await pcNode.start(listenPort: 4811);
    final phone = Client(phoneStore, myPort: 4812);
    final phoneNode = Node(phoneStore, saveDir: () async => root, onIncoming: (_, _) {});
    await phoneNode.start(listenPort: 4812);
    final pc = await phone.hello('127.0.0.1:4811');
    await phoneStore.upsertDevice(pc);

    final list = await phone.call(pc, 'GET', '/agents');
    expect(list['available'], isTrue);

    final started = await phone.call(pc, 'POST', '/agents/start', body: {'cwd': root.path, 'prompt': 'make a folder'});
    final id = started['id'] as String;

    Future<List> events() async => (await phone.call(pc, 'GET', '/agents/s/$id/events?after=0&v=0'))['events'] as List;
    List evs = [];
    for (var i = 0; i < 50 && !evs.any((e) => e['k'] == 'approve'); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      evs = await events();
    }
    final ask = evs.firstWhere((e) => e['k'] == 'approve');
    expect(ask['summary'], 'mkdir x');
    expect(alerts.single['kind'], 'approve');
    alerts.clear();

    // Unknown devices can't touch agents.
    final stranger = Client(await Store.open(Directory('${root.path}/x')));
    expect(() => stranger.call(Device(id: 'pc', name: 'pc', kind: 'desktop', host: '127.0.0.1:4811'), 'GET', '/agents'), throwsA(isA<HttpException>()));

    await phone.call(pc, 'POST', '/agents/s/$id/approve', body: {'rid': ask['rid'], 'allow': true});
    for (var i = 0; i < 50 && !evs.any((e) => e['k'] == 'result'); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      evs = await events();
    }
    expect(evs.where((e) => e['k'] == 'text').single['text'], 'made it');
    expect(evs.firstWhere((e) => e['k'] == 'approve')['state'], 'allowed');
    expect(alerts.single['kind'], 'done');

    host.dispose();
    phone.close();
    stranger.close();
    await pcNode.stop();
    await phoneNode.stop();
    await root.delete(recursive: true);
  });
}
