import 'dart:io';

import 'package:flutter/material.dart';

import 'avd_service.dart';
import 'system_images.dart';

Future<void> showSystemImagesDialog(BuildContext context, AvdService svc) => showDialog<void>(
  context: context,
  builder: (_) => _SystemImagesDialog(svc: svc),
);

const _versions = {
  '21': '5.0',
  '22': '5.1',
  '23': '6.0',
  '24': '7.0',
  '25': '7.1',
  '26': '8.0',
  '27': '8.1',
  '28': '9',
  '29': '10',
  '30': '11',
  '31': '12',
  '32': '12L',
  '33': '13',
  '34': '14',
  '35': '15',
  '36': '16',
};

String? androidVersion(String api) => _versions[api.split('.').first];

bool _matches(RemoteImage i, String query) {
  final hay = [
    'api ${i.api}',
    i.api,
    'android ${androidVersion(i.api) ?? ''}',
    i.tag.replaceAll('_', ' '),
    i.tagDisplay,
    i.abi,
    i.displayName,
    if (i.preview) 'preview',
  ].join(' ').toLowerCase();
  return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
}

String _gb(int bytes) =>
    bytes >= 1 << 30 ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';

class _SystemImagesDialog extends StatefulWidget {
  const _SystemImagesDialog({required this.svc});

  final AvdService svc;

  @override
  State<_SystemImagesDialog> createState() => _SystemImagesDialogState();
}

class _SystemImagesDialogState extends State<_SystemImagesDialog> {
  final m = SystemImageManager.instance;
  var _tag = 'all';
  var _showPreview = false;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    m.loadCatalog();
  }

  Future<void> _removeInstalled(SystemImage img, String sdk) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove system image?'),
        content: Text('${img.label}\nAVDs using it will no longer start.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await m.uninstallDir(Directory('$sdk${Platform.pathSeparator}${img.relPath}'));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final sdk = widget.svc.sdkRoot;

    return Dialog(
      child: SizedBox(
        width: 820,
        height: 620,
        child: ListenableBuilder(
          listenable: m,
          builder: (context, _) {
            final installed = widget.svc.systemImages();
            final catalog = (m.catalog ?? const <RemoteImage>[])
                .where((i) => _showPreview || !i.preview)
                .where((i) => _tag == 'all' || i.tag == _tag)
                .where((i) => _matches(i, _search.text))
                .toList();
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text('System images', style: text.titleLarge),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Reload catalog',
                        onPressed: m.loadingCatalog ? null : () => m.loadCatalog(force: true),
                        icon: const Icon(Icons.refresh),
                      ),
                      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                    ],
                  ),
                  Text(
                    sdk == null ? 'Android SDK not found' : 'Installed into $sdk${Platform.pathSeparator}system-images',
                    style: text.bodySmall?.copyWith(color: sdk == null ? scheme.error : scheme.outline),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'INSTALLED (${installed.length})',
                    style: text.labelSmall?.copyWith(color: scheme.outline, letterSpacing: .6),
                  ),
                  const SizedBox(height: 6),
                  if (installed.isEmpty)
                    Text('None yet — download one below.', style: text.bodySmall?.copyWith(color: scheme.outline))
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final i in installed)
                          InputChip(
                            avatar: Icon(Icons.check_circle, size: 16, color: scheme.primary),
                            label: Text(i.label),
                            onDeleted: sdk == null ? null : () => _removeInstalled(i, sdk),
                            deleteButtonTooltipMessage: 'Remove',
                          ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text('AVAILABLE', style: text.labelSmall?.copyWith(color: scheme.outline, letterSpacing: .6)),
                      const Spacer(),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'all', label: Text('All')),
                          ButtonSegment(value: 'google_apis', label: Text('Google APIs')),
                          ButtonSegment(value: 'google_apis_playstore', label: Text('Play Store')),
                          ButtonSegment(value: 'default', label: Text('AOSP')),
                        ],
                        selected: {_tag},
                        onSelectionChanged: (v) => setState(() => _tag = v.first),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Previews'),
                        selected: _showPreview,
                        onSelected: (v) => setState(() => _showPreview = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Search: 34, Android 14, play store, x86_64…',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () => setState(_search.clear),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: m.loadingCatalog
                        ? const Center(child: CircularProgressIndicator())
                        : m.catalogError != null
                        ? Center(
                            child: Text(m.catalogError!, style: TextStyle(color: scheme.error)),
                          )
                        : Card(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            child: ListView.separated(
                              itemCount: catalog.length,
                              separatorBuilder: (_, _) => const Divider(height: 1),
                              itemBuilder: (_, i) => _ImageRow(image: catalog[i], sdk: sdk, manager: m),
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

class _ImageRow extends StatelessWidget {
  const _ImageRow({required this.image, required this.sdk, required this.manager});

  final RemoteImage image;
  final String? sdk;
  final SystemImageManager manager;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final img = image;
    final job = manager.jobs[img.path];
    final installed = sdk != null && manager.isInstalled(sdk!, img);
    final running = job != null && !job.done && job.error == null;

    Widget trailing;
    if (running) {
      trailing = SizedBox(
        width: 230,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: job.stage == 'Downloading' ? job.progress : null),
                  const SizedBox(height: 4),
                  Text(
                    job.stage == 'Downloading'
                        ? '${_gb(job.received)} / ${_gb(img.size)} · ${(job.progress * 100).round()}%'
                        : '${job.stage}…',
                    style: text.labelSmall?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Cancel',
              onPressed: () => manager.cancel(img),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      );
    } else if (installed) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 18, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            'Installed',
            style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
          ),
          IconButton(
            tooltip: 'Remove',
            onPressed: () => manager.uninstall(sdk!, img),
            icon: Icon(Icons.delete_outline, size: 18, color: scheme.outline),
          ),
        ],
      );
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (job?.error != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Tooltip(
                message: job!.error!,
                child: Icon(Icons.error_outline, size: 18, color: scheme.error),
              ),
            ),
          OutlinedButton.icon(
            onPressed: sdk == null ? null : () => manager.install(sdk!, img),
            icon: const Icon(Icons.download, size: 16),
            label: Text(_gb(img.size)),
          ),
        ],
      );
    }

    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: scheme.primary.withValues(alpha: .10),
        child: Text(
          img.api,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary),
        ),
      ),
      title: Text(
        '${androidVersion(img.api) == null ? '' : 'Android ${androidVersion(img.api)} · '}API ${img.api} · '
        '${img.tagDisplay}${img.preview ? ' · preview' : ''}',
      ),
      subtitle: Text('${img.abi} · rev ${img.revision}', style: text.bodySmall?.copyWith(color: scheme.outline)),
      trailing: trailing,
    );
  }
}
