import 'dart:io';

import 'package:flutter/foundation.dart';

import 'atlassian.dart';
import '../../core/files.dart';

class WorkService extends ChangeNotifier {
  WorkService._();

  static final instance = WorkService._();

  var config = AtlassianConfig();
  late var jira = JiraClient(config);
  late var bitbucket = BitbucketClient(config);
  bool loaded = false;
  final _issues = <String, (DateTime, JiraIssue)>{};

  Future<void> load({bool force = false}) async {
    if (loaded && !force) return;
    config = await AtlassianConfig.load();
    jira = JiraClient(config);
    bitbucket = BitbucketClient(config);
    _issues.clear();
    loaded = true;
    notifyListeners();
  }

  Future<void> save(AtlassianConfig c) async {
    await c.save();
    await load(force: true);
  }

  /// Short-lived cache so every workspace window doesn't hit Jira on each rebuild.
  Future<JiraIssue?> cachedIssue(String key) async {
    final hit = _issues[key];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 2)) return hit.$2;
    try {
      final issue = await jira.issue(key);
      _issues[key] = (DateTime.now(), issue);
      return issue;
    } on ApiException {
      return hit?.$2;
    }
  }

  void forget(String key) => _issues.remove(key);
}

void openUrl(String url) => Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);

Future<void> openInVsCode(String path) async {
  try {
    await Process.start('code', [path], runInShell: true, mode: ProcessStartMode.detached);
  } on ProcessException {
    await openExternal(path);
  }
}
