import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class Note {
  Note({required this.id, this.text = '', this.color = 0, this.pinned = false, DateTime? updated})
    : updated = updated ?? DateTime.now();

  final String id;
  String text;
  int color;
  bool pinned;
  DateTime updated;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'color': color,
    'pinned': pinned,
    'updated': updated.toIso8601String(),
  };

  factory Note.fromJson(Map<String, dynamic> j) => Note(
    id: j['id'] as String,
    text: j['text'] as String? ?? '',
    color: j['color'] as int? ?? 0,
    pinned: j['pinned'] as bool? ?? false,
    updated: DateTime.tryParse(j['updated'] as String? ?? ''),
  );
}

/// Sticky notes kept in notes.json next to the other app data.
class NotesStore extends ChangeNotifier {
  NotesStore._();

  static final instance = NotesStore._();

  final notes = <Note>[];
  bool loaded = false;
  Timer? _saveDebounce;

  /// Pinned first, then most recently edited.
  List<Note> get sorted => [...notes]
    ..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updated.compareTo(a.updated);
    });

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}notes.json');

  Future<void> load() async {
    if (loaded) return;
    try {
      final f = await _file();
      if (f.existsSync()) {
        notes.addAll([
          for (final j in jsonDecode(await f.readAsString()) as List) Note.fromJson(j as Map<String, dynamic>),
        ]);
      }
    } catch (_) {
      // A corrupt file shouldn't block new notes; the next save rewrites it.
    }
    loaded = true;
    notifyListeners();
  }

  Note add({int color = 0}) {
    final note = Note(id: DateTime.now().microsecondsSinceEpoch.toString(), color: color);
    notes.add(note);
    _changed();
    return note;
  }

  void update(Note note, {String? text, int? color, bool? pinned}) {
    if (text != null) note.text = text;
    if (color != null) note.color = color;
    if (pinned != null) note.pinned = pinned;
    if (text != null) note.updated = DateTime.now();
    _changed(repaint: text == null);
  }

  void remove(Note note) {
    notes.remove(note);
    _changed();
  }

  void restore(Note note) {
    notes.add(note);
    _changed();
  }

  // Typing doesn't repaint the grid, otherwise notes would jump around while being edited.
  void _changed({bool repaint = true}) {
    if (repaint) notifyListeners();
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () async {
      await (await _file()).writeAsString(jsonEncode([for (final n in notes) n.toJson()]));
    });
  }
}
