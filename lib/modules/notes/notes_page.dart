import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'notes_store.dart';

// Paper colors stay light in dark mode too, like real sticky notes; text is always dark.
const noteColors = [
  Color(0xFFFFF3A3),
  Color(0xFFFFD1DC),
  Color(0xFFC8F2D0),
  Color(0xFFCDE7FF),
  Color(0xFFE3D4FF),
  Color(0xFFFFDDB8),
];

const _ink = Color(0xFF2B2B2B);

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final store = NotesStore.instance;
  var _query = '';
  String? _focusId;

  @override
  void initState() {
    super.initState();
    store.load();
  }

  void _add() {
    final note = store.add(color: store.notes.length % noteColors.length);
    setState(() => _focusId = note.id);
  }

  void _delete(Note note) {
    store.remove(note);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Note deleted'),
          behavior: SnackBarBehavior.floating,
          width: 360,
          action: SnackBarAction(label: 'Undo', onPressed: () => store.restore(note)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.keyN, control: true): _add},
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            final q = _query.toLowerCase();
            final notes = store.sorted.where((n) => n.text.toLowerCase().contains(q)).toList();
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text('Notes', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 12),
                      Text('${store.notes.length} notes', style: TextStyle(color: scheme.outline)),
                      const Spacer(),
                      SizedBox(
                        width: 280,
                        child: TextField(
                          onChanged: (v) => setState(() => _query = v),
                          decoration: const InputDecoration(
                            hintText: 'Search notes…',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _add,
                        icon: const Icon(Icons.add),
                        label: const Text('New note (Ctrl+N)'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: !store.loaded
                        ? const Center(child: CircularProgressIndicator())
                        : notes.isEmpty
                        ? _Empty(searching: _query.isNotEmpty, onAdd: _add)
                        : SingleChildScrollView(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: Wrap(
                              spacing: 14,
                              runSpacing: 14,
                              children: [
                                for (final n in notes)
                                  _StickyNote(
                                    key: ValueKey(n.id),
                                    note: n,
                                    autofocus: n.id == _focusId,
                                    onDelete: () => _delete(n),
                                  ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StickyNote extends StatefulWidget {
  const _StickyNote({super.key, required this.note, required this.autofocus, required this.onDelete});

  final Note note;
  final bool autofocus;
  final VoidCallback onDelete;

  @override
  State<_StickyNote> createState() => _StickyNoteState();
}

class _StickyNoteState extends State<_StickyNote> {
  late final _ctl = TextEditingController(text: widget.note.text);
  var _hover = false;

  Note get note => widget.note;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  String _ago() {
    final d = DateTime.now().difference(note.updated);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    final t = note.updated;
    return '${t.day}/${t.month}/${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final store = NotesStore.instance;
    final paper = noteColors[note.color % noteColors.length];
    final iconStyle = IconButton.styleFrom(
      foregroundColor: _ink.withValues(alpha: 0.7),
      visualDensity: VisualDensity.compact,
      iconSize: 17,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 260,
        constraints: const BoxConstraints(minHeight: 200),
        decoration: BoxDecoration(
          color: paper,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _hover ? 0.22 : 0.12),
              blurRadius: _hover ? 14 : 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(_ago(), style: TextStyle(fontSize: 11, color: _ink.withValues(alpha: 0.5))),
                const Spacer(),
                IconButton(
                  tooltip: note.pinned ? 'Unpin' : 'Pin to top',
                  style: iconStyle,
                  onPressed: () => store.update(note, pinned: !note.pinned),
                  icon: Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                ),
                IconButton(
                  tooltip: 'Copy text',
                  style: iconStyle,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: note.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Note copied'), behavior: SnackBarBehavior.floating, width: 280),
                    );
                  },
                  icon: const Icon(Icons.copy),
                ),
                IconButton(
                  tooltip: 'Delete',
                  style: iconStyle,
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            TextField(
              controller: _ctl,
              autofocus: widget.autofocus,
              maxLines: null,
              minLines: 6,
              cursorColor: _ink,
              style: const TextStyle(color: _ink, fontSize: 14, height: 1.4),
              decoration: InputDecoration(
                hintText: 'Write something…',
                hintStyle: TextStyle(color: _ink.withValues(alpha: 0.4)),
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: (v) => store.update(note, text: v),
            ),
            const SizedBox(height: 6),
            AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Row(
                children: [
                  for (var i = 0; i < noteColors.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InkWell(
                        onTap: () => store.update(note, color: i),
                        customBorder: const CircleBorder(),
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: noteColors[i],
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _ink.withValues(alpha: i == note.color ? 0.8 : 0.25),
                              width: i == note.color ? 2 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.searching, required this.onAdd});

  final bool searching;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sticky_note_2_outlined, size: 48, color: scheme.outline),
          const SizedBox(height: 10),
          Text(searching ? 'No notes match.' : 'Jot down IPs, test steps, anything.'),
          if (!searching) ...[
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('New note')),
          ],
        ],
      ),
    );
  }
}
