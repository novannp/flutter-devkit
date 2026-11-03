import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:devkit/modules/editor/agent_view.dart';
import 'package:devkit/modules/editor/project_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProcess implements Process {
  _FakeProcess(this.lines, {this.code = 0, this.stderrText = ''});

  final List<String> lines;
  final int code;
  final String stderrText;
  final _stdin = StreamController<List<int>>();
  late final sent = _stdin.stream.transform(utf8.decoder).join();
  late final IOSink _sink = IOSink(_stdin.sink);

  @override
  IOSink get stdin {
    unawaited(sent);
    return _sink;
  }

  @override
  Stream<List<int>> get stdout => Stream.fromIterable([for (final l in lines) utf8.encode('$l\n')]);

  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(stderrText));

  @override
  Future<int> get exitCode async => code;

  @override
  int get pid => 0;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

String _json(Object value) => jsonEncode(value);

final _reply = [
  _json({'type': 'system', 'subtype': 'init', 'session_id': 'abc-12345'}),
  _json({'type': 'stream_event', 'session_id': 'abc-12345', 'parent_tool_use_id': null, 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'Hel'}}}),
  _json({'type': 'stream_event', 'session_id': 'abc-12345', 'parent_tool_use_id': null, 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'lo'}}}),
  _json({'type': 'assistant', 'parent_tool_use_id': null, 'message': {'content': [{'type': 'text', 'text': 'Hello'}, {'type': 'tool_use', 'id': 't1', 'name': 'Edit', 'input': {'file_path': '/p/lib/a.dart'}}]}}),
  _json({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'is_error': true}]}}),
  _json({'type': 'result', 'subtype': 'success', 'is_error': false, 'result': 'Hello', 'session_id': 'abc-12345', 'permission_denials': []}),
];

void main() {
  group('arguments', () {
    test('never skip permissions, and take the mode', () {
      final args = agentArguments(AgentMode.editFiles, null);
      expect(args, containsAllInOrder(['-p', '--output-format', 'stream-json', '--permission-mode', 'acceptEdits']));
      expect(args.join(' '), isNot(contains('dangerously')));
      expect(args, isNot(contains('--resume')));
      expect(agentArguments(AgentMode.readOnly, null), contains('plan'));
    });

    test('resume only something that looks like a session id', () {
      expect(agentArguments(AgentMode.readOnly, 'abc-12345'), containsAllInOrder(['--resume', 'abc-12345']));
      expect(agentArguments(AgentMode.readOnly, 'x & calc'), isNot(contains('--resume')));
    });
  });

  test('tool calls read as a line, with their file', () {
    expect(describeToolCall('Edit', {'file_path': '/p/lib/a.dart'}), ('Edit a.dart', '/p/lib/a.dart'));
    expect(describeToolCall('Bash', {'command': 'ls\nmore'}), ('Bash: ls', null));
    expect(describeToolCall('Thing', null), ('Thing', null));
  });

  test('only whether someone is signed in is read from the status', () {
    expect(agentSignedIn('{"loggedIn": true, "email": "a@b"}'), isTrue);
    expect(agentSignedIn('{"loggedIn": false}'), isFalse);
    expect(agentSignedIn('not json'), isFalse);
  });

  group('a conversation', () {
    test('streams text, lists tools and marks failures', () {
      final s = AgentSession('/p');
      addTearDown(s.dispose);
      _reply.forEach(s.applyLine);
      expect(s.sessionId, 'abc-12345');
      expect(s.items.map((i) => (i.kind, i.text)), [(AgentItemKind.assistant, 'Hello'), (AgentItemKind.tool, 'Edit a.dart')]);
      expect(s.items.last.failed, isTrue);
      expect(s.items.last.path, '/p/lib/a.dart');
    });

    test('lines it cannot read, and what a subagent says, are left out', () {
      final s = AgentSession('/p');
      addTearDown(s.dispose);
      s.applyLine('not json');
      s.applyLine('[1]');
      s.applyLine(_json({'type': 'surprise'}));
      s.applyLine(_json({'type': 'stream_event', 'parent_tool_use_id': 't', 'event': {'delta': {'type': 'text_delta', 'text': 'inner'}}}));
      expect(s.items, isEmpty);
    });

    test('what the mode refuses, and errors, are said', () {
      final s = AgentSession('/p');
      addTearDown(s.dispose);
      s.applyLine(_json({'type': 'result', 'is_error': true, 'result': 'Rate limited', 'permission_denials': [{'tool_name': 'Bash'}, {'tool_name': 'Bash'}]}));
      expect(s.items.first.kind, AgentItemKind.note);
      expect(s.items.first.text, contains('Bash'));
      expect(s.items.last.text, 'Rate limited');
    });

    test('the message goes through stdin, and the next one resumes', () async {
      final runs = <List<String>>[];
      final processes = <_FakeProcess>[];
      final s = AgentSession('/p', spawn: (args, _) async {
        runs.add(args);
        final process = _FakeProcess(_reply);
        processes.add(process);
        return process;
      });
      addTearDown(s.dispose);
      await s.send('say "hi" & bye', AgentMode.editFiles, context: 'The file open is a.dart.');
      expect(await processes.first.sent, 'The file open is a.dart.\n\nsay "hi" & bye');
      expect(runs.first.join(' '), isNot(contains('hi')));
      expect(s.items.first.text, 'say "hi" & bye', reason: 'the context stays out of the conversation');
      expect(s.busy, isFalse);

      await s.send('more', AgentMode.editFiles);
      expect(runs.last, containsAllInOrder(['--resume', 'abc-12345']));

      s.newConversation();
      expect(s.items, isEmpty);
      expect(s.sessionId, isNull);
    });

    test('a failure to run says why', () async {
      final s = AgentSession('/p', spawn: (_, _) async => _FakeProcess(const [], code: 1, stderrText: 'boom'));
      addTearDown(s.dispose);
      await s.send('x', AgentMode.readOnly);
      expect((s.items.last.kind, s.items.last.text), (AgentItemKind.error, 'boom'));

      final gone = AgentSession('/p', spawn: (_, _) async => throw const ProcessException('claude', []));
      addTearDown(gone.dispose);
      await gone.send('x', AgentMode.readOnly);
      expect(gone.items.last.kind, AgentItemKind.error);
      expect(gone.busy, isFalse);
    });
  });

  group('the panel', () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    Widget panel({required ToolProbe probe, AgentSpawn? spawn, bool visible = true, List<List<String>>? signIn}) => MaterialApp(
      home: Scaffold(
        body: AgentView(root: '/p', visible: visible, probe: probe, spawn: spawn, onSignIn: (c) async => signIn?.add(c), activeFile: () => '/p/lib/a.dart'),
      ),
    );

    testWidgets('waits until shown before running anything', (tester) async {
      var asked = 0;
      Future<(int, String)> probe(List<String> _) async {
        asked++;
        return (0, '{"loggedIn": true}');
      }

      await tester.pumpWidget(panel(probe: probe, visible: false));
      await settle(tester);
      expect(asked, 0);
      await tester.pumpWidget(panel(probe: probe));
      await settle(tester);
      expect(asked, 1);
    });

    testWidgets('without Claude Code it says how to get it', (tester) async {
      await tester.pumpWidget(panel(probe: (_) async => (-1, 'not found')));
      await settle(tester);
      expect(find.text('How to install it'), findsOneWidget);
    });

    testWidgets('signed out, it sends you to sign in with Claude Code itself', (tester) async {
      final signIn = <List<String>>[];
      await tester.pumpWidget(panel(probe: (c) async => c.contains('auth') ? (1, '{"loggedIn": false}') : (0, '2.0.0'), signIn: signIn));
      await settle(tester);
      await tester.tap(find.text('Sign in'));
      expect(signIn.single, ['claude', 'auth', 'login']);
    });

    testWidgets('Enter sends, and the reply shows with its tools', (tester) async {
      late _FakeProcess process;
      await tester.pumpWidget(panel(
        probe: (_) async => (0, '{"loggedIn": true}'),
        spawn: (_, _) async => process = _FakeProcess(_reply),
      ));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'fix it');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.text('fix it'), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Edit a.dart'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      final sent = await tester.runAsync(() => process.sent);
      expect(sent, contains('fix it'));
      expect(sent, contains('a.dart'), reason: 'it knows what file is open');
    });
  });
}
