import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/tools.dart';
import '../../core/history.dart';

class RemoteImage {
  const RemoteImage({
    required this.path,
    required this.api,
    required this.tag,
    required this.tagDisplay,
    required this.abi,
    required this.revision,
    required this.displayName,
    required this.size,
    required this.sha1,
    required this.url,
    required this.typeDetails,
    required this.preview,
  });

  /// sdkmanager path, e.g. `system-images;android-34;google_apis;x86_64`.
  final String path;
  final String api;
  final String tag;
  final String tagDisplay;
  final String abi;
  final String revision;
  final String displayName;
  final int size;
  final String? sha1;
  final String url;
  final String typeDetails;
  final bool preview;

  List<String> get segments => path.split(';');
  int get apiNumber => int.tryParse(api.split('.').first) ?? 0;
}

class ImageJob {
  ImageJob(this.image);

  final RemoteImage image;
  int received = 0;
  String stage = 'Downloading';
  String? error;
  bool cancelled = false;
  bool done = false;

  double get progress => image.size == 0 ? 0 : received / image.size;
}

/// Downloads system images straight from Google's SDK repository (no sdkmanager/Java needed).
class SystemImageManager extends ChangeNotifier {
  SystemImageManager._();

  static final instance = SystemImageManager._();

  static const _base = 'https://dl.google.com/android/repository/sys-img';
  static const _repos = ['android', 'google_apis', 'google_apis_playstore'];
  static final _sep = Platform.pathSeparator;

  List<RemoteImage>? catalog;
  String? catalogError;
  bool loadingCatalog = false;
  final jobs = <String, ImageJob>{};

  /// Emulator images must match the host CPU.
  static List<String> get hostAbis =>
      Platform.version.contains('arm64') ? const ['arm64-v8a'] : const ['x86_64', 'x86'];

  Future<void> loadCatalog({bool force = false}) async {
    if (loadingCatalog || (catalog != null && !force)) return;
    loadingCatalog = true;
    catalogError = null;
    notifyListeners();
    try {
      final all = <String, RemoteImage>{};
      for (final repo in _repos) {
        final url = '$_base/$repo/sys-img2-3.xml';
        for (final img in _parse(await _get(url), url)) {
          // Same path can appear per channel; keep the stable one, else the newest.
          final prev = all[img.path];
          if (prev == null || (prev.preview && !img.preview)) all[img.path] = img;
        }
      }
      catalog = all.values.where((i) => hostAbis.contains(i.abi)).toList()
        ..sort((a, b) {
          final c = b.apiNumber.compareTo(a.apiNumber);
          return c != 0 ? c : a.tag.compareTo(b.tag);
        });
    } catch (e) {
      catalogError = 'Could not load the image catalog: $e';
    }
    loadingCatalog = false;
    notifyListeners();
  }

  static Future<String> _get(String url) async {
    final client = HttpClient();
    try {
      final res = await (await client.getUrl(Uri.parse(url))).close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      return await res.transform(const SystemEncoding().decoder).join();
    } finally {
      client.close();
    }
  }

  static String? _tag(String block, String name) => RegExp('<$name>([^<]*)</$name>').firstMatch(block)?[1]?.trim();

  static List<RemoteImage> _parse(String xml, String repoUrl) {
    final channels = {
      for (final m in RegExp(r'<channel id="([^"]+)">([^<]+)</channel>').allMatches(xml)) m[1]!: m[2]!.trim(),
    };
    final dir = repoUrl.substring(0, repoUrl.lastIndexOf('/') + 1);
    final out = <RemoteImage>[];
    for (final m in RegExp(r'<remotePackage path="([^"]+)">(.*?)</remotePackage>', dotAll: true).allMatches(xml)) {
      final path = m[1]!, b = m[2]!;
      final seg = path.split(';');
      if (seg.length != 4) continue;
      final archive = RegExp(r'<archive>(.*?)</archive>', dotAll: true)
          .allMatches(b)
          .map((a) => a[1]!)
          .where((a) => !a.contains('<host-os>') || a.contains('<host-os>windows</host-os>'))
          .firstOrNull;
      final url = archive == null ? null : _tag(archive, 'url');
      if (archive == null || url == null) continue;
      final rev = RegExp(r'<revision>(.*?)</revision>', dotAll: true).firstMatch(b)?[1] ?? '';
      final channel = channels[RegExp(r'<channelRef ref="([^"]+)"').firstMatch(b)?[1]] ?? 'stable';
      final tagBlock = RegExp(r'<tag>(.*?)</tag>', dotAll: true).firstMatch(b)?[1] ?? '';
      out.add(
        RemoteImage(
          path: path,
          api: seg[1].replaceFirst('android-', ''),
          tag: seg[2],
          tagDisplay: _tag(tagBlock, 'display') ?? seg[2],
          abi: seg[3],
          revision: [_tag(rev, 'major'), _tag(rev, 'minor'), _tag(rev, 'micro')].nonNulls.join('.'),
          displayName: _tag(b, 'display-name') ?? path,
          size: int.tryParse(_tag(archive, 'size') ?? '') ?? 0,
          sha1: RegExp(r'<checksum type="sha1">([0-9a-f]+)</checksum>').firstMatch(archive)?[1],
          url: url.startsWith('http') ? url : '$dir$url',
          typeDetails: RegExp(r'<type-details[^>]*>.*?</type-details>', dotAll: true).firstMatch(b)?[0] ?? '',
          preview: channel != 'stable',
        ),
      );
    }
    return out;
  }

  Directory _targetDir(String sdk, RemoteImage img) =>
      Directory([sdk, 'system-images', ...img.segments.skip(1)].join(_sep));

  bool isInstalled(String sdk, RemoteImage img) => File('${_targetDir(sdk, img).path}${_sep}system.img').existsSync();

  Future<void> install(String sdk, RemoteImage img) async {
    if (jobs[img.path] case final j? when !j.done && j.error == null) return;
    final job = jobs[img.path] = ImageJob(img);
    notifyListeners();
    final tmp = Directory([sdk, 'system-images', '.slipway-tmp'].join(_sep))..createSync(recursive: true);
    final zip = File('${tmp.path}$_sep${img.segments.skip(1).join('_')}.zip');
    final extractDir = Directory('${zip.path}.d');
    final client = HttpClient();
    try {
      final res = await (await client.getUrl(Uri.parse(img.url))).close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final sink = zip.openWrite();
      var lastNotify = DateTime.now();
      await for (final chunk in res) {
        if (job.cancelled) break;
        sink.add(chunk);
        job.received += chunk.length;
        if (DateTime.now().difference(lastNotify).inMilliseconds > 250) {
          lastNotify = DateTime.now();
          notifyListeners();
        }
      }
      await sink.close();
      if (job.cancelled) throw 'Cancelled';

      if (img.sha1 != null) {
        job.stage = 'Verifying';
        notifyListeners();
        final r = await Tools.run('certutil', ['-hashfile', zip.path, 'SHA1'], timeout: const Duration(minutes: 3));
        if (r.ok && !r.stdout.replaceAll(' ', '').toLowerCase().contains(img.sha1!)) throw 'Checksum mismatch';
      }

      job.stage = 'Extracting';
      notifyListeners();
      if (extractDir.existsSync()) extractDir.deleteSync(recursive: true);
      extractDir.createSync();
      final r = await Tools.run('tar', ['-xf', zip.path, '-C', extractDir.path], timeout: const Duration(minutes: 10));
      if (!r.ok) throw 'Extract failed: ${r.stderr.trim()}';

      // The zip holds a single top folder (e.g. `x86_64/`).
      final entries = extractDir.listSync();
      final root = entries.length == 1 && entries.first is Directory ? entries.first as Directory : extractDir;
      final target = _targetDir(sdk, img);
      if (target.existsSync()) target.deleteSync(recursive: true);
      target.parent.createSync(recursive: true);
      await root.rename(target.path);
      await File('${target.path}${_sep}package.xml').writeAsString(_packageXml(img));
      job.done = true;
      History.activity('emulator', 'Downloaded ${img.path}');
    } catch (e) {
      job.error = job.cancelled ? 'Cancelled' : '$e';
    } finally {
      client.close(force: true);
      for (final f in [zip, extractDir]) {
        try {
          if (f.existsSync()) f.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  void cancel(RemoteImage img) {
    jobs[img.path]?.cancelled = true;
    notifyListeners();
  }

  void clearJob(RemoteImage img) {
    jobs.remove(img.path);
    notifyListeners();
  }

  Future<void> uninstall(String sdk, RemoteImage img) => uninstallDir(_targetDir(sdk, img));

  Future<void> uninstallDir(Directory dir) async {
    History.activity('emulator', 'Removed system image', {'path': dir.path});
    if (dir.existsSync()) await dir.delete(recursive: true);
    // Drop now-empty tag/api folders.
    for (var d = dir.parent; d.path.contains('system-images') && !d.path.endsWith('system-images'); d = d.parent) {
      if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
    }
    notifyListeners();
  }

  /// Lets Android Studio's SDK Manager recognise images installed by Slipway.
  static String _packageXml(RemoteImage img) =>
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02" xmlns:ns6="http://schemas.android.com/sdk/android/repo/sys-img2/02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><license id="android-sdk-license" type="text"/><localPackage path="${img.path}" obsolete="false">${img.typeDetails.replaceAll('sys-img:', 'ns6:')}<revision>${img.revision.split('.').indexed.map((e) => '<${['major', 'minor', 'micro'][e.$1]}>${e.$2}</${['major', 'minor', 'micro'][e.$1]}>').join()}</revision><display-name>${img.displayName}</display-name><uses-license ref="android-sdk-license"/></localPackage></ns2:repository>
''';
}
