import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// One entry in a history log (activity, crashes).
class HistoryEntry {
  const HistoryEntry(this.time, this.kind, this.title, this.data);

  final DateTime time;
  final String kind;
  final String title;
  final Map<String, dynamic> data;

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime(0),
    j['kind'] as String? ?? '',
    j['title'] as String? ?? '',
    (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}

/// Local, append-only history so past activity, crashes and session logs can be reviewed later.
///
/// Every Slipway window (main + workspace windows) appends to the same files; entries are small JSON
/// lines, so concurrent appends don't interleave in practice.
class History {
  static const retention = Duration(days: 30);
  static const _maxEntries = 5000;
  static const _maxSessionBytes = 1024 * 1024 * 1024;
  static final _sep = Platform.pathSeparator;
  static Directory? _dir;

  static Future<Directory> dir() async =>
      _dir ??= await Directory('${(await getApplicationSupportDirectory()).path}${_sep}history')
          .create(recursive: true);

  static Future<File> _file(String log) async => File('${(await dir()).path}$_sep$log.jsonl');

  /// Records an event. [log] is the file (`activity`, `crashes`); [kind] groups entries for filtering.
  static Future<void> add(String log, String kind, String title, [Map<String, dynamic> data = const {}]) async {
    try {
      final line = jsonEncode({'time': DateTime.now().toIso8601String(), 'kind': kind, 'title': title, 'data': data});
      await (await _file(log)).writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // History must never break the feature that's logging.
    }
  }

  static Future<void> activity(String kind, String title, [Map<String, dynamic> data = const {}]) =>
      add('activity', kind, title, data);

  /// Newest first.
  static Future<List<HistoryEntry>> read(String log) async {
    final f = await _file(log);
    if (!f.existsSync()) return [];
    final out = <HistoryEntry>[];
    for (final line in await f.readAsLines()) {
      try {
        out.add(HistoryEntry.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {}
    }
    return out.reversed.toList();
  }

  static Future<Directory> sessionsDir([String? kind]) async {
    final base = '${(await dir()).path}${_sep}sessions';
    return Directory(kind == null ? base : '$base$_sep$kind').create(recursive: true);
  }

  static String safe(String s) => s.replaceAll(RegExp(r'[^\w.\-]+'), '_');

  /// A log file for one session (logcat, flutter run, maintenance output).
  static Future<SessionLog> session(String kind, String name) async {
    final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);
    final file = File('${(await sessionsDir(kind)).path}$_sep${ts}_${safe(name)}.log');
    return SessionLog._(file);
  }

  /// Drops old session files and trims the JSONL logs; run once at startup.
  static Future<void> prune() async {
    try {
      final cutoff = DateTime.now().subtract(retention);
      final files = <File>[];
      await for (final e in (await sessionsDir()).list(recursive: true)) {
        if (e is! File) continue;
        if (e.lastModifiedSync().isBefore(cutoff)) {
          await e.delete();
        } else {
          files.add(e);
        }
      }
      // Logcat adds up fast; keep the newest sessions within the size budget.
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      var total = 0;
      for (final f in files) {
        total += f.lengthSync();
        if (total > _maxSessionBytes) await f.delete();
      }
      for (final log in ['activity', 'crashes']) {
        final f = await _file(log);
        if (!f.existsSync()) continue;
        final lines = await f.readAsLines();
        final keep = lines.where((l) {
          final t = DateTime.tryParse(RegExp(r'"time":"([^"]+)"').firstMatch(l)?[1] ?? '');
          return t == null || t.isAfter(cutoff);
        }).toList();
        final trimmed = keep.length > _maxEntries ? keep.sublist(keep.length - _maxEntries) : keep;
        if (trimmed.length != lines.length) await f.writeAsString(trimmed.map((l) => '$l\n').join());
      }
    } catch (_) {}
  }
}

/// Buffered append-only text log for a session; caps size so a chatty logcat can't fill the disk.
class SessionLog {
  SessionLog._(this.file);

  static const _maxBytes = 50 * 1024 * 1024;

  final File file;
  final _buf = StringBuffer();
  Timer? _timer;
  var _written = 0;
  var _full = false;

  void writeln(String line) {
    if (_full) return;
    _buf.writeln(line);
    _timer ??= Timer(const Duration(seconds: 1), _flush);
  }

  Future<void> _flush() async {
    _timer = null;
    if (_buf.isEmpty) return;
    var text = _buf.toString();
    _buf.clear();
    if (_written + text.length > _maxBytes) {
      text = '$text\n[log truncated: reached ${_maxBytes ~/ (1024 * 1024)} MB]\n';
      _full = true;
    }
    _written += text.length;
    try {
      await file.writeAsString(text, mode: FileMode.append);
    } catch (_) {}
  }

  Future<void> close() async {
    _timer?.cancel();
    await _flush();
  }
}
