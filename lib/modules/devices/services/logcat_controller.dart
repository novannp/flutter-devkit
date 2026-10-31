import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'device_adb.dart';
import '../../../core/history.dart';

class LogLine {
  LogLine(this.raw, {this.time, this.pid, this.level = 'V', this.tag = '', this.message = '', this.crash = false});

  final String raw;
  final String? time;
  final int? pid;
  final String level;
  final String tag;
  final String message;
  final bool crash;

  static final _re = RegExp(r'^(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+(\d+)\s+\d+\s+([VDIWEF])\s+(.*?)\s*: (.*)$');

  factory LogLine.parse(String raw) {
    final m = _re.firstMatch(raw);
    if (m == null) return LogLine(raw, message: raw);
    final level = m[3]!;
    final tag = m[4]!;
    final message = m[5]!;
    final crash =
        (tag == 'AndroidRuntime' && message.startsWith('FATAL EXCEPTION')) ||
        (tag == 'ActivityManager' && message.startsWith('ANR in')) ||
        (tag == 'flutter' && level == 'E' && message.contains('Unhandled Exception'));
    return LogLine(raw, time: m[1], pid: int.parse(m[2]!), level: level, tag: tag, message: message, crash: crash);
  }
}

/// Logcat stays alive while the workspace is open, so bug reports & the crash badge work even when another tab is active.
class LogcatController extends ChangeNotifier {
  LogcatController(this.dev);

  final DeviceAdb dev;
  static const maxLines = 20000;

  final lines = <LogLine>[];
  final ourPids = <int, String>{};
  final crashes = <LogLine>[];
  final _crashEvents = StreamController<LogLine>.broadcast();
  Process? _process;
  Timer? _pidPoll;
  Timer? _flush;
  var _dirty = false;
  var paused = false;

  Stream<LogLine> get onCrash => _crashEvents.stream;
  SessionLog? _session;

  void start() {
    History.session('logcat', dev.target).then((s) => _session = s);
    _restart();
    _pollPid();
    _pidPoll = Timer.periodic(const Duration(seconds: 3), (_) => _pollPid());
    _flush = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_dirty) return;
      _dirty = false;
      notifyListeners();
    });
  }

  Future<void> _restart() async {
    _process?.kill();
    final p = await dev.logcat();
    _process = p;
    p.stderr.drain<void>();
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((raw) {
      if (paused) return;
      final line = LogLine.parse(raw);
      _session?.writeln(raw);
      lines.add(line);
      if (lines.length > maxLines + 2000) lines.removeRange(0, lines.length - maxLines);
      if (line.crash) {
        crashes.add(line);
        _crashEvents.add(line);
        // Keep the lead-up so the crash can be reviewed after the session is gone.
        final context = lines.skip(lines.length > 60 ? lines.length - 60 : 0).map((l) => l.raw).join('\n');
        History.add('crashes', 'crash', '${line.tag}: ${line.message}', {
          'device': dev.target,
          'app': ?ourPids[line.pid],
          'log': context,
        });
      }
      _dirty = true;
    });
  }

  Future<void> restart() => _restart();

  // Old pids are kept so logs from before an app restart don't drop out of the filter.
  Future<void> _pollPid() async {
    final pids = await dev.ourPids();
    if (pids.keys.any((p) => !ourPids.containsKey(p))) _dirty = true;
    ourPids.addAll(pids);
  }

  void togglePause() {
    paused = !paused;
    notifyListeners();
  }

  Future<void> clear() async {
    await dev.clearLogcat();
    lines.clear();
    crashes.clear();
    notifyListeners();
  }

  void clearCrashes() {
    crashes.clear();
    notifyListeners();
  }

  String dump({int last = 5000}) =>
      lines.skip(lines.length > last ? lines.length - last : 0).map((l) => l.raw).join('\n');

  @override
  void dispose() {
    _session?.close();
    _process?.kill();
    _pidPoll?.cancel();
    _flush?.cancel();
    _crashEvents.close();
    super.dispose();
  }
}
