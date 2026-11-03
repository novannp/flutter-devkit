import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/child_processes.dart';
import 'dart_sdk.dart';

/// Splits an LSP byte stream into JSON messages (`Content-Length` framing).
class LspFrameParser {
  final _buffer = BytesBuilder();
  static final _separator = ascii.encode('\r\n\r\n');

  List<Map<String, dynamic>> add(List<int> chunk) {
    _buffer.add(chunk);
    final messages = <Map<String, dynamic>>[];
    var bytes = _buffer.takeBytes();
    while (true) {
      final end = _indexOfSeparator(bytes);
      if (end < 0) break;
      final start = end + _separator.length;
      final header = RegExp(
        r'Content-Length:\s*(\d+)',
        caseSensitive: false,
      ).firstMatch(ascii.decode(bytes.sublist(0, end), allowInvalid: true));
      // Anything else the process printed isn't a message; waiting on it would stall the rest.
      if (header == null) {
        bytes = bytes.sublist(start);
        continue;
      }
      final length = int.parse(header[1]!);
      if (bytes.length < start + length) break;
      try {
        if (jsonDecode(utf8.decode(bytes.sublist(start, start + length), allowMalformed: true))
            case final Map<String, dynamic> message) {
          messages.add(message);
        }
      } on FormatException {
        // A broken message is dropped, and the ones after it still arrive.
      }
      bytes = bytes.sublist(start + length);
    }
    _buffer.add(bytes);
    return messages;
  }

  int _indexOfSeparator(List<int> b) {
    outer:
    for (var i = 0; i <= b.length - _separator.length; i++) {
      for (var j = 0; j < _separator.length; j++) {
        if (b[i + j] != _separator[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

class LspException implements Exception {
  const LspException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The Dart Analysis Server over LSP, using the project's own SDK.
class LspClient {
  LspClient(this.root);

  final String root;

  Process? _process;
  final _parser = LspFrameParser();
  final _pending = <int, Completer<dynamic>>{};
  var _nextId = 1;
  var _closed = false;

  /// `textDocument/publishDiagnostics` params.
  final diagnostics = StreamController<Map<String, dynamic>>.broadcast();

  /// `$/analyzerStatus` from the server: true while analyzing.
  final analyzing = StreamController<bool>.broadcast();

  /// Edits the server wants applied, e.g. after a code action command.
  void Function(Map<String, dynamic> edit)? onApplyEdit;
  void Function()? onExit;

  /// What `workspace/configuration` answers for the `dart` section.
  Map<String, dynamic> Function()? dartConfig;

  /// How to read semantic tokens, from the server's `initialize` answer.
  List<String> tokenTypes = const [];
  List<String> tokenModifiers = const [];

  bool get running => _process != null;

  Future<void> start() async {
    final cmd = dartCommand(root);
    final process = await Process.start(
      cmd.exe,
      [...cmd.args, 'language-server', '--protocol=lsp', '--client-id=slipway', '--client-version=1'],
      workingDirectory: root,
      runInShell: cmd.runInShell,
    );
    // Closed while the process was still launching: nothing else would ever stop it.
    if (_closed) {
      process.kill();
      throw const LspException('Dart analysis server stopped');
    }
    _process = process;
    ChildProcesses.bind(process);
    process.stdout.listen((chunk) => _parser.add(chunk).forEach(_onMessage));
    process.stderr.drain<void>();
    unawaited(
      process.exitCode.then((_) {
        _process = null;
        for (final c in _pending.values) {
          if (!c.isCompleted) c.completeError(const LspException('Dart analysis server stopped'));
        }
        _pending.clear();
        onExit?.call();
      }),
    );
    final init = await request('initialize', {
      'processId': pid,
      'rootUri': Uri.directory(root).toString(),
      'capabilities': {
        'workspace': {
          'configuration': true,
          'applyEdit': true,
          'workspaceEdit': {'documentChanges': true},
        },
        'textDocument': {
          'synchronization': {'didSave': true},
          'publishDiagnostics': {},
          'completion': {
            'completionItem': {
              'snippetSupport': true,
              'insertTextModeSupport': {
                'valueSet': [1, 2],
              },
              'deprecatedSupport': true,
              'labelDetailsSupport': true,
              'documentationFormat': ['markdown', 'plaintext'],
              'resolveSupport': {
                'properties': ['documentation', 'detail', 'additionalTextEdits'],
              },
            },
          },
          'hover': {
            'contentFormat': ['plaintext', 'markdown'],
          },
          'codeAction': {
            'codeActionLiteralSupport': {
              'codeActionKind': {
                'valueSet': ['quickfix', 'refactor', 'source'],
              },
            },
          },
          'rename': {'prepareSupport': false},
          'documentSymbol': {'hierarchicalDocumentSymbolSupport': true},
          'signatureHelp': {
            'signatureInformation': {
              'documentationFormat': ['markdown', 'plaintext'],
              'parameterInformation': {'labelOffsetSupport': false},
              'activeParameterSupport': true,
            },
          },
          'semanticTokens': {
            'requests': {'full': true},
            'tokenTypes': const <String>[],
            'tokenModifiers': const <String>[],
            'formats': const ['relative'],
          },
        },
      },
      'initializationOptions': {
        // Analyze only what's open: far less memory on repos with many packages.
        'onlyAnalyzeProjectsWithOpenFiles': true,
        'closingLabels': false,
        'outline': false,
        'flutterOutline': false,
      },
    }, timeout: const Duration(minutes: 2));
    final legend = ((init as Map?)?['capabilities'] as Map?)?['semanticTokensProvider']?['legend'] as Map?;
    tokenTypes = (legend?['tokenTypes'] as List?)?.cast<String>() ?? const [];
    tokenModifiers = (legend?['tokenModifiers'] as List?)?.cast<String>() ?? const [];
    notify('initialized', {});
  }

  void _onMessage(Map<String, dynamic> m) {
    // The server can still be talking while it shuts down.
    if (_closed) return;
    final method = m['method'] as String?;
    if (method == null) {
      final c = _pending.remove(m['id']);
      if (c == null) return;
      final error = m['error'] as Map?;
      if (error != null) {
        c.completeError(LspException('${error['message']}'));
      } else {
        c.complete(m['result']);
      }
      return;
    }
    if (m.containsKey('id')) return _onServerRequest(m['id'], method, m['params']);
    switch (method) {
      case 'textDocument/publishDiagnostics':
        diagnostics.add((m['params'] as Map).cast<String, dynamic>());
      case r'$/analyzerStatus':
        analyzing.add((m['params'] as Map)['isAnalyzing'] == true);
    }
  }

  void _onServerRequest(Object? id, String method, Object? params) {
    Object? result;
    switch (method) {
      case 'workspace/applyEdit':
        final edit = ((params as Map)['edit'] as Map).cast<String, dynamic>();
        onApplyEdit?.call(edit);
        result = {'applied': true};
      case 'workspace/configuration':
        result = [
          for (final item in (params as Map)['items'] as List)
            (item as Map)['section'] == 'dart'
                ? (dartConfig?.call() ?? const <String, dynamic>{})
                : const <String, dynamic>{},
        ];
    }
    _send({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  void _send(Map<String, dynamic> message) {
    final body = utf8.encode(jsonEncode(message));
    _process?.stdin
      ?..add(ascii.encode('Content-Length: ${body.length}\r\n\r\n'))
      ..add(body);
  }

  Future<dynamic> request(String method, Object? params, {Duration timeout = const Duration(seconds: 30)}) {
    if (_process == null) return Future.error(const LspException('Dart analysis server is not running'));
    final id = _nextId++;
    final completer = _pending[id] = Completer<dynamic>();
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        // Otherwise the server goes on working for nobody, and everything after this waits behind it.
        notify(r'$/cancelRequest', {'id': id});
        throw LspException('$method timed out');
      },
    );
  }

  void notify(String method, Object? params) => _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  Future<void> dispose() async {
    final process = _process;
    if (process != null) {
      try {
        await request('shutdown', null, timeout: const Duration(seconds: 2));
        notify('exit', null);
      } on Exception {
        process.kill();
      }
    }
    _closed = true;
    _process = null;
    // Closed mid-start, `initialize` is still waiting and will never hear back.
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(const LspException('Dart analysis server stopped'));
    }
    _pending.clear();
    await diagnostics.close();
    await analyzing.close();
  }
}
