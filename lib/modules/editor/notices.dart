import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// When a project's dependencies last changed, if its packages are behind them; null when they're up to date.
/// The stamp lets a dismissed notice come back once something changes again.
int? packagesOutOfSyncSince(String root) {
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return null;
  final changed = [pubspec, File(p.join(root, 'pubspec.lock'))].where((f) => f.existsSync()).map((f) => f.lastModifiedSync()).reduce((a, b) => a.isAfter(b) ? a : b);
  final config = File(p.join(root, '.dart_tool', 'package_config.json'));
  if (config.existsSync() && !changed.isAfter(config.lastModifiedSync())) return null;
  return changed.millisecondsSinceEpoch;
}

bool isProjectPubspec(String path, String root) => p.equals(path, p.join(root, 'pubspec.yaml'));

class NoticeAction {
  const NoticeAction(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;
}

class EditorNotice {
  const EditorNotice({required this.id, required this.message, required this.source, this.icon = Icons.info_outline, this.actions = const []});

  final String id, message, source;
  final IconData icon;
  final List<NoticeAction> actions;
}

/// A notification in the corner of the Editor, like VS Code's.
class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.notice, required this.onDismiss});

  final EditorNotice notice;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      builder: (_, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
      ),
      child: Material(
        elevation: 6,
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(notice.icon, size: 16, color: scheme.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(notice.message, style: const TextStyle(fontSize: 12.5))),
                  IconButton(
                    tooltip: 'Dismiss',
                    iconSize: 14,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 22, height: 22),
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 24),
                  Expanded(child: Text('Source: ${notice.source}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: scheme.outline))),
                  for (final a in notice.actions)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, right: 4),
                      child: TextButton(
                        style: TextButton.styleFrom(textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                        onPressed: a.onPressed,
                        child: Text(a.label),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
