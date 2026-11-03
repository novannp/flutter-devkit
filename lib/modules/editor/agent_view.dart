import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/child_processes.dart';
import '../../core/platform_keys.dart';
import '../../core/settings.dart';
import '../../extensions/work/work_service.dart' show openUrl;
import 'markdown_view.dart';
import 'project_tools.dart';

/// What the agent may do without asking. There's nobody to ask in this mode of the CLI, so what isn't allowed is refused.
enum AgentMode {
  readOnly('plan', 'Read only'),
  editFiles('acceptEdits', 'Edit files');

  const AgentMode(this.flag, this.label);

  final String flag, label;
}

enum AgentItemKind { user, assistant, tool, error, note }

class AgentItem {
  AgentItem(this.kind, this.text, {this.id, this.path});

  final AgentItemKind kind;
  String text;

  /// A tool call's id, to find it again when its result comes.
  final String? id;

  /// The file a tool worked on.
  final String? path;
  var failed = false;
}

/// One line saying what a tool call is doing, from what it was given.
(String, String?) describeToolCall(String name, Object? input) {
  final m = input is Map ? input : const {};
  final path = m['file_path'] ?? m['notebook_path'];
  if (path is String) return ('$name ${p.basename(path)}', path);
  for (final key in const ['command', 'pattern', 'query', 'url', 'description', 'prompt']) {
    if (m[key] case final String value when value.trim().isNotEmpty) {
      return ('$name: ${value.trim().split('\n').first}', null);
    }
  }
  return (name, null);
}

bool _isSessionId(String id) => RegExp(r'^[0-9a-fA-F-]{8,64}$').hasMatch(id);

List<String> agentArguments(AgentMode mode, String? sessionId) => [
  '-p',
  '--output-format',
  'stream-json',
  '--verbose',
  '--include-partial-messages',
  '--permission-mode',
  mode.flag,
  if (sessionId != null && _isSessionId(sessionId)) ...['--resume', sessionId],
];

typedef AgentSpawn = Future<Process> Function(List<String> arguments, String workingDirectory);

// A copy of the environment, without what tells a CLI it's running inside another Claude Code.
Future<Process> _spawnClaude(List<String> arguments, String workingDirectory) => Process.start(
  'claude',
  arguments,
  workingDirectory: workingDirectory,
  runInShell: Platform.isWindows,
  includeParentEnvironment: false,
  environment: {...Platform.environment}
    ..remove('CLAUDECODE')
    ..remove('CLAUDE_CODE_ENTRYPOINT'),
);

/// A conversation with Claude Code in a project. It runs the `claude` the user already has, as the VS Code
/// extension does, so sign-in and credentials stay with that program and this one never sees them.
class AgentSession extends ChangeNotifier {
  AgentSession(this.root, {this.spawn = _spawnClaude});

  final String root;
  final AgentSpawn spawn;
  final items = <AgentItem>[];
  String? sessionId;
  bool busy = false;
  Process? _process;
  AgentItem? _streaming;
  var _disposed = false;
  var _stopped = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// [context] says what's on screen. It goes to the agent, without showing in the conversation.
  Future<void> send(String prompt, AgentMode mode, {String? context}) async {
    final text = prompt.trim();
    if (text.isEmpty || busy) return;
    items.add(AgentItem(AgentItemKind.user, text));
    busy = true;
    _stopped = false;
    _streaming = null;
    _changed();
    try {
      final process = await spawn(agentArguments(mode, sessionId), root);
      if (_disposed) {
        process.kill();
        return;
      }
      _process = process;
      ChildProcesses.bind(process);
      // Through stdin, because a shell would take a message's quotes and & for its own.
      process.stdin.write(context == null ? text : '$context\n\n$text');
      unawaited(process.stdin.close().catchError((_) {}));
      final errors = StringBuffer();
      final out = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach(applyLine);
      final err = process.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(errors.write);
      final code = await process.exitCode;
      await Future.wait([out, err]);
      if (_stopped) {
        items.add(AgentItem(AgentItemKind.note, 'Stopped.'));
      } else if (code != 0 && !items.any((i) => i.kind == AgentItemKind.error && identical(i, items.last))) {
        final message = errors.toString().trim();
        items.add(AgentItem(AgentItemKind.error, message.isEmpty ? 'Claude Code exited with code $code.' : message));
      }
    } on Exception catch (e) {
      items.add(AgentItem(AgentItemKind.error, "Couldn't start Claude Code: $e"));
    }
    _process = null;
    _streaming = null;
    busy = false;
    _changed();
  }

  /// Reads one line of `--output-format stream-json`. Anything it doesn't know is left alone.
  void applyLine(String line) {
    final Object? data;
    try {
      data = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (data is! Map) return;
    if (data['session_id'] case final String id) sessionId = id;
    // What a subagent says along the way isn't the conversation.
    if (data['parent_tool_use_id'] != null) return;
    switch (data['type']) {
      case 'stream_event':
        final event = data['event'];
        final delta = event is Map ? event['delta'] : null;
        if (delta is Map && delta['type'] == 'text_delta' && delta['text'] is String) {
          final streaming = _streaming ??= (AgentItem(AgentItemKind.assistant, '')..also(items.add));
          streaming.text += delta['text'] as String;
          _changed();
        }
      case 'assistant':
        _streaming = null;
        final message = data['message'];
        final content = message is Map ? message['content'] : null;
        for (final block in content is List ? content : const []) {
          if (block is Map && block['type'] == 'tool_use' && block['name'] is String) {
            final (text, path) = describeToolCall(block['name'] as String, block['input']);
            items.add(AgentItem(AgentItemKind.tool, text, id: block['id'] as String?, path: path));
          }
        }
        _changed();
      case 'user':
        final message = data['message'];
        final content = message is Map ? message['content'] : null;
        for (final block in content is List ? content : const []) {
          if (block is Map && block['type'] == 'tool_result' && block['is_error'] == true) {
            for (final item in items) {
              if (item.id == block['tool_use_id']) item.failed = true;
            }
          }
        }
        _changed();
      case 'result':
        final denied = data['permission_denials'];
        if (denied is List && denied.isNotEmpty) {
          final names = {for (final d in denied) if (d is Map && d['tool_name'] is String) d['tool_name'] as String};
          items.add(AgentItem(AgentItemKind.note, 'Not allowed in this mode: ${names.join(', ')}. Change the mode below, or allow it in your Claude Code settings.'));
        }
        if (data['is_error'] == true) {
          final message = data['result'] ?? data['subtype'] ?? 'Claude Code stopped with an error.';
          items.add(AgentItem(AgentItemKind.error, '$message'));
        }
        _changed();
    }
  }

  void stop() {
    final process = _process;
    if (process == null) return;
    _stopped = true;
    unawaited(ChildProcesses.killTree(process));
  }

  /// Starts over: the next message begins a new conversation.
  void newConversation() {
    stop();
    sessionId = null;
    items.clear();
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

extension<T> on T {
  void also(void Function(T) use) => use(this);
}

enum AgentAvailability { checking, missing, signedOut, ready }

/// `claude auth status` prints JSON. Only whether someone's signed in is read from it.
bool agentSignedIn(String output) {
  final start = output.indexOf('{');
  if (start < 0) return false;
  try {
    final data = jsonDecode(output.substring(start));
    return data is Map && data['loggedIn'] == true;
  } on FormatException {
    return false;
  }
}

class AgentView extends StatefulWidget {
  const AgentView({super.key, required this.root, required this.visible, this.activeFile, this.onBeforeSend, this.onOpenFile, this.spawn, this.probe, this.onSignIn = openInSystemTerminal});

  final String root;

  /// Asks the CLI whether it's signed in only once someone looks.
  final bool visible;

  /// The file on screen, so "this file" means what the user thinks it means.
  final String? Function()? activeFile;

  /// Saves open files first, so the agent reads what's on the screen.
  final Future<void> Function()? onBeforeSend;
  final ValueChanged<String>? onOpenFile;
  final AgentSpawn? spawn;
  final ToolProbe? probe;
  final Future<void> Function(List<String> command) onSignIn;

  @override
  State<AgentView> createState() => _AgentViewState();
}

class _AgentViewState extends State<AgentView> {
  late final _session = widget.spawn == null ? AgentSession(widget.root) : AgentSession(widget.root, spawn: widget.spawn!);
  late final _probe = widget.probe ?? probeIn(widget.root);
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  var _availability = AgentAvailability.checking;
  var _checked = false;

  AgentMode get _mode => AgentMode.values.firstWhere((m) => m.name == Settings.instance.text('app.agentMode'), orElse: () => AgentMode.editFiles);

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    Settings.instance.addListener(_rebuild);
    if (widget.visible) unawaited(_check());
  }

  @override
  void didUpdateWidget(AgentView old) {
    super.didUpdateWidget(old);
    if (widget.visible && !_checked) unawaited(_check());
  }

  @override
  void dispose() {
    Settings.instance.removeListener(_rebuild);
    _session
      ..removeListener(_onSession)
      ..dispose();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onSession() {
    _rebuild();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _check() async {
    _checked = true;
    if (mounted) setState(() => _availability = AgentAvailability.checking);
    final (code, output) = await _probe(const ['claude', 'auth', 'status']);
    if (!mounted) return;
    final version = code == 0 || agentSignedIn(output) ? true : (await _probe(const ['claude', '--version'])).$1 == 0;
    if (!mounted) return;
    setState(() {
      _availability = !version
          ? AgentAvailability.missing
          : (agentSignedIn(output) ? AgentAvailability.ready : AgentAvailability.signedOut);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _session.busy) return;
    _input.clear();
    await widget.onBeforeSend?.call();
    final file = widget.activeFile?.call();
    await _session.send(text, _mode, context: file == null ? null : 'The file open in the editor is ${p.relative(file, from: widget.root)}.');
  }

  KeyEventResult _onInputKey(FocusNode _, KeyEvent e) {
    // Enter sends, and Shift+Enter starts a new line.
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.enter || HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    unawaited(_send());
    return KeyEventResult.handled;
  }

  Widget _centered(List<Widget> children) => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );

  Widget _item(AgentItem item, ColorScheme scheme) {
    switch (item.kind) {
      case AgentItemKind.user:
        return Container(
          margin: const EdgeInsets.fromLTRB(24, 8, 8, 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(color: scheme.primary.withValues(alpha: .12), borderRadius: BorderRadius.circular(9)),
          child: SelectableText(item.text, style: const TextStyle(fontSize: 13)),
        );
      case AgentItemKind.assistant:
        return Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 4), child: MarkdownView(item.text));
      case AgentItemKind.tool:
        final path = item.path;
        final row = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: Row(
            children: [
              Icon(item.failed ? Icons.error_outline : Icons.build_outlined, size: 13, color: item.failed ? scheme.error : scheme.outline),
              const SizedBox(width: 6),
              Expanded(
                child: Text(item.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: item.failed ? scheme.error : scheme.onSurfaceVariant)),
              ),
            ],
          ),
        );
        return path == null ? row : InkWell(onTap: () => widget.onOpenFile?.call(path), child: row);
      case AgentItemKind.error:
        return Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 4), child: SelectableText(item.text, style: TextStyle(fontSize: 12.5, color: scheme.error)));
      case AgentItemKind.note:
        return Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 4), child: Text(item.text, style: TextStyle(fontSize: 12, color: scheme.outline)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant);
    final Widget body;
    switch (_availability) {
      case AgentAvailability.checking:
        body = const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
      case AgentAvailability.missing:
        body = _centered([
          Text('The agent runs Claude Code, which isn\'t installed yet.', textAlign: TextAlign.center, style: small),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => openUrl('https://docs.claude.com/en/docs/claude-code/setup'), child: const Text('How to install it')),
          TextButton(onPressed: () => unawaited(_check()), child: const Text('Check again')),
        ]);
      case AgentAvailability.signedOut:
        body = _centered([
          Text('Sign in to Claude Code once, and the agent uses that from then on.', textAlign: TextAlign.center, style: small),
          const SizedBox(height: 10),
          FilledButton(onPressed: () => unawaited(widget.onSignIn(const ['claude', 'auth', 'login'])), child: const Text('Sign in')),
          TextButton(onPressed: () => unawaited(_check()), child: const Text('Check again')),
        ]);
      case AgentAvailability.ready:
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _session.items.isEmpty
                  ? _centered([Text('Ask about this project, or ask for a change.', textAlign: TextAlign.center, style: small)])
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: _session.items.length,
                      itemBuilder: (_, i) => _item(_session.items[i], scheme),
                    ),
            ),
            if (_session.busy) const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Focus(
                onKeyEvent: _onInputKey,
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
                  minLines: 1,
                  maxLines: 6,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(isDense: true, hintText: 'Message the agent'),
                ),
              ),
            ),
            SizedBox(
              height: 32,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'What the agent may do without asking. It works in this project, and commands stay refused unless your Claude Code settings allow them.',
                    child: PopupMenuButton<AgentMode>(
                      initialValue: _mode,
                      onSelected: (m) => unawaited(Settings.instance.update('app.agentMode', m.name)),
                      itemBuilder: (_) => [for (final m in AgentMode.values) PopupMenuItem(height: 30, value: m, child: Text(m.label, style: const TextStyle(fontSize: 13)))],
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_mode.label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                          Icon(Icons.arrow_drop_down, size: 16, color: scheme.outline),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (_session.busy)
                    IconButton(tooltip: 'Stop', iconSize: 17, visualDensity: VisualDensity.compact, onPressed: _session.stop, icon: Icon(Icons.stop_circle_outlined, color: scheme.error))
                  else
                    IconButton(tooltip: platformKeys('Send (Enter)'), iconSize: 17, visualDensity: VisualDensity.compact, onPressed: () => unawaited(_send()), icon: Icon(Icons.send, color: scheme.primary)),
                ],
              ),
            ),
          ],
        );
    }
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Expanded(child: Text('Agent', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant))),
                if (_availability == AgentAvailability.ready)
                  IconButton(tooltip: 'New conversation', iconSize: 16, visualDensity: VisualDensity.compact, onPressed: _session.newConversation, icon: const Icon(Icons.add_comment_outlined)),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
