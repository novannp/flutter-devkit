import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../../core/child_processes.dart';

/// flutter_pty joins the command line without quoting, so a path with a space splits into several arguments.
String ptyArgument(String value) =>
    Platform.isWindows && value.contains(' ') && !value.startsWith('"') ? '"$value"' : value;

class ShellKind {
  const ShellKind(this.label, this.exe, [this.args = const []]);

  final String label;
  final String exe;
  final List<String> args;

  static const _gitBash = r'C:\Program Files\Git\bin\bash.exe';

  /// Shells installed on this PC, preferred first.
  static List<ShellKind> available() => [
    if (File(_gitBash).existsSync()) const ShellKind('Git Bash', _gitBash, ['--login', '-i']),
    const ShellKind('PowerShell', 'powershell.exe', ['-NoLogo']),
    const ShellKind('Command Prompt', 'cmd.exe'),
  ];

  static ShellKind deviceShell(String adb, String target) => ShellKind('Device shell', adb, ['-s', target, 'shell']);
}

/// One interactive terminal: a ConPTY process wired to an xterm buffer.
class ConsoleSession extends ChangeNotifier {
  ConsoleSession({required this.shell, this.cwd, this.environment, String? title}) : title = title ?? shell.label {
    _start();
  }

  final ShellKind shell;
  final String? cwd;
  final Map<String, String>? environment;
  String title;

  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();
  Pty? _pty;
  bool exited = false;

  void _start() {
    exited = false;
    final pty = Pty.start(
      ptyArgument(shell.exe),
      arguments: [for (final a in shell.args) ptyArgument(a)],
      workingDirectory: cwd,
      environment: environment,
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    _pty = pty;
    ChildProcesses.bindPid(pty.pid);
    pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);
    pty.exitCode.then((code) {
      if (_pty != pty) return;
      exited = true;
      terminal.write('\r\n\x1b[90m[process exited with code $code — press Enter to restart]\x1b[0m\r\n');
      notifyListeners();
    });
    terminal.onOutput = (data) {
      if (exited) {
        if (data.contains('\r')) restart();
        return;
      }
      _pty?.write(const Utf8Encoder().convert(data));
    };
    terminal.onResize = (w, h, _, _) => _pty?.resize(h, w);
  }

  void restart() {
    _pty?.kill();
    terminal.write('\x1b[2J\x1b[H');
    _start();
    notifyListeners();
  }

  void run(String command) => _pty?.write(const Utf8Encoder().convert('$command\r'));

  @override
  void dispose() {
    final pty = _pty;
    _pty = null;
    pty?.kill();
    super.dispose();
  }
}
