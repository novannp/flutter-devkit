import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/secrets.dart';

class AtlassianConfig {
  AtlassianConfig({
    this.jiraUrl = '',
    this.jiraEmail = '',
    this.jiraToken = '',
    this.jiraProject = '',
    this.bbWorkspace = '',
    this.bbUser = '',
    this.bbToken = '',
    this.baseBranch = 'develop',
  });

  String jiraUrl, jiraEmail, jiraToken, jiraProject;
  String bbWorkspace, bbUser, bbToken, baseBranch;

  bool get hasJira => jiraUrl.isNotEmpty && jiraToken.isNotEmpty;
  bool get hasBitbucket => bbWorkspace.isNotEmpty && bbUser.isNotEmpty && bbToken.isNotEmpty;

  static Future<AtlassianConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return AtlassianConfig(
      jiraUrl: p.getString('jira_url') ?? '',
      jiraEmail: p.getString('jira_email') ?? '',
      jiraToken: await Secrets.read('jira_token') ?? '',
      jiraProject: p.getString('jira_project') ?? '',
      bbWorkspace: p.getString('bb_workspace') ?? '',
      bbUser: p.getString('bb_user') ?? '',
      bbToken: await Secrets.read('bb_token') ?? '',
      baseBranch: p.getString('git_base_branch') ?? 'develop',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('jira_url', jiraUrl.trim().replaceAll(RegExp(r'/+$'), ''));
    await p.setString('jira_email', jiraEmail.trim());
    await p.setString('jira_project', jiraProject.trim().toUpperCase());
    await p.setString('bb_workspace', bbWorkspace.trim());
    await p.setString('bb_user', bbUser.trim());
    await p.setString('git_base_branch', baseBranch.trim());
    await Secrets.write('jira_token', jiraToken.trim());
    await Secrets.write('bb_token', bbToken.trim());
  }
}

class ApiException implements Exception {
  ApiException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => status == 0 ? message : 'HTTP $status: $message';
}

Future<dynamic> _send(
  String method,
  Uri uri,
  String auth, {
  Object? json,
  Map<String, String> headers = const {},
  List<File> files = const [],
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.openUrl(method, uri);
    req.headers
      ..set(HttpHeaders.authorizationHeader, auth)
      ..set(HttpHeaders.acceptHeader, 'application/json');
    headers.forEach(req.headers.set);
    if (files.isNotEmpty) {
      final boundary = 'hotrestart${Random().nextInt(1 << 32)}';
      req.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        req.add(
          utf8.encode(
            '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$name"\r\n'
            'Content-Type: application/octet-stream\r\n\r\n',
          ),
        );
        req.add(await f.readAsBytes());
        req.add(utf8.encode('\r\n'));
      }
      req.add(utf8.encode('--$boundary--\r\n'));
    } else if (json != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(json)));
    }
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) throw ApiException(res.statusCode, _errorText(body));
    return body.isEmpty ? null : jsonDecode(body);
  } on SocketException catch (e) {
    throw ApiException(0, 'Cannot reach ${uri.host}: ${e.osError?.message ?? e.message}');
  } finally {
    client.close();
  }
}

String _errorText(String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final msgs = [
        ...?(j['errorMessages'] as List?)?.map((e) => '$e'),
        ...?(j['errors'] as Map?)?.values.map((e) => '$e'),
        if (j['error'] case {'message': final m}) '$m',
        if (j['message'] case final String m) m,
      ];
      if (msgs.isNotEmpty) return msgs.join('; ');
    }
  } catch (_) {}
  return body.length > 200 ? '${body.substring(0, 200)}…' : body;
}

String _basic(String user, String token) => 'Basic ${base64.encode(utf8.encode('$user:$token'))}';

// ---------------------------------------------------------------- Jira

enum StatusGroup { todo, inProgress, done }

class JiraComment {
  const JiraComment(this.author, this.body, this.created);

  final String author;
  final String body;
  final DateTime? created;
}

class JiraIssue {
  JiraIssue({
    required this.key,
    required this.summary,
    required this.status,
    required this.group,
    required this.type,
    required this.url,
    this.priority,
    this.updated,
    this.description = '',
    this.comments = const [],
  });

  final String key, summary, status, type, url;
  final StatusGroup group;
  final String? priority;
  final DateTime? updated;
  final String description;
  final List<JiraComment> comments;
}

class JiraTransition {
  const JiraTransition(this.id, this.name, this.to);

  final String id, name, to;
}

class JiraClient {
  JiraClient(this.config);

  final AtlassianConfig config;

  /// Cloud uses REST v3 (rich-text ADF bodies); Server / Data Center uses v2 with a personal access token.
  bool get cloud {
    final host = Uri.tryParse(config.jiraUrl)?.host ?? '';
    return host.endsWith('.atlassian.net') || host.endsWith('.jira.com');
  }

  String get _v => cloud ? '3' : '2';

  String get _auth =>
      config.jiraEmail.isEmpty ? 'Bearer ${config.jiraToken}' : _basic(config.jiraEmail, config.jiraToken);

  Uri _uri(String path, [Map<String, String>? q]) =>
      Uri.parse('${config.jiraUrl}/rest/api/$_v$path').replace(queryParameters: q);

  Future<dynamic> _req(String method, String path, {Map<String, String>? query, Object? json, List<File>? files}) =>
      _send(
        method,
        _uri(path, query),
        _auth,
        json: json,
        files: files ?? const [],
        headers: files == null ? const {} : const {'X-Atlassian-Token': 'no-check'},
      );

  String browseUrl(String key) => '${config.jiraUrl}/browse/$key';

  Future<String> myself() async => ((await _req('GET', '/myself')) as Map)['displayName'] as String? ?? '';

  static const _fields = 'summary,status,issuetype,priority,updated';

  Future<List<JiraIssue>> myIssues({String? text}) async {
    final project = config.jiraProject.isEmpty ? '' : 'project = "${config.jiraProject}" AND ';
    final search = text == null || text.isEmpty
        ? 'assignee = currentUser() AND (statusCategory != Done OR updated >= -14d)'
        : _textJql(text);
    final jql = '$project$search ORDER BY updated DESC';
    final res = await _req(
      'GET',
      cloud ? '/search/jql' : '/search',
      query: {'jql': jql, 'fields': _fields, 'maxResults': '60'},
    );
    return [for (final i in (res['issues'] as List? ?? const [])) _issue(i as Map)];
  }

  static String _textJql(String text) {
    final t = text.trim();
    if (RegExp(r'^[A-Za-z][A-Za-z0-9]+-\d+$').hasMatch(t)) return 'key = "${t.toUpperCase()}"';
    return 'text ~ "${t.replaceAll('"', r'\"')}"';
  }

  Future<JiraIssue> issue(String key) async {
    final res = await _req('GET', '/issue/$key', query: {'fields': '$_fields,description,comment'});
    return _issue(res as Map, full: true);
  }

  Future<List<JiraTransition>> transitions(String key) async {
    final res = await _req('GET', '/issue/$key/transitions');
    return [
      for (final t in (res['transitions'] as List? ?? const []))
        JiraTransition('${t['id']}', '${t['name']}', '${t['to']?['name'] ?? t['name']}'),
    ];
  }

  Future<void> transition(String key, String id) => _req(
    'POST',
    '/issue/$key/transitions',
    json: {
      'transition': {'id': id},
    },
  );

  /// Moves the issue to the first transition whose target status matches one of [names] (case-insensitive).
  Future<String?> moveTo(String key, List<String> names) async {
    final wanted = names.map((n) => n.toLowerCase()).toList();
    for (final w in wanted) {
      final t = (await transitions(key)).where((t) => t.to.toLowerCase() == w || t.name.toLowerCase() == w);
      if (t.isNotEmpty) {
        await transition(key, t.first.id);
        return t.first.to;
      }
    }
    return null;
  }

  Future<void> comment(String key, String text) =>
      _req('POST', '/issue/$key/comment', json: {'body': cloud ? toAdf(text) : text});

  Future<void> attach(String key, List<File> files) => _req('POST', '/issue/$key/attachments', files: files);

  JiraIssue _issue(Map j, {bool full = false}) {
    final f = j['fields'] as Map? ?? const {};
    final status = f['status'] as Map? ?? const {};
    final cat = status['statusCategory']?['key'] as String?;
    final desc = f['description'];
    return JiraIssue(
      key: j['key'] as String,
      summary: f['summary'] as String? ?? '',
      status: status['name'] as String? ?? '?',
      group: switch (cat) {
        'done' => StatusGroup.done,
        'indeterminate' => StatusGroup.inProgress,
        _ => StatusGroup.todo,
      },
      type: f['issuetype']?['name'] as String? ?? '',
      priority: f['priority']?['name'] as String?,
      updated: DateTime.tryParse(f['updated'] as String? ?? ''),
      url: browseUrl(j['key'] as String),
      description: !full ? '' : (desc is Map ? adfToText(desc) : (desc as String? ?? '')),
      comments: !full
          ? const []
          : [
              for (final c in (f['comment']?['comments'] as List? ?? const []))
                JiraComment(
                  c['author']?['displayName'] as String? ?? '?',
                  c['body'] is Map ? adfToText(c['body'] as Map) : '${c['body'] ?? ''}',
                  DateTime.tryParse(c['created'] as String? ?? ''),
                ),
            ],
    );
  }
}

/// Plain text from Atlassian Document Format, good enough for reading in HotRestart.
String adfToText(Map node) {
  final out = StringBuffer();
  void walk(Map n, String indent) {
    final type = n['type'];
    final kids = (n['content'] as List? ?? const []).cast<Map>();
    switch (type) {
      case 'text':
        out.write(n['text'] ?? '');
      case 'hardBreak':
        out.write('\n');
      case 'mention' || 'emoji' || 'status':
        out.write(n['attrs']?['text'] ?? n['attrs']?['shortName'] ?? '');
      case 'inlineCard' || 'blockCard':
        out.write(n['attrs']?['url'] ?? '');
      case 'listItem':
        out.write('$indent• ');
        for (final k in kids) {
          walk(k, '$indent  ');
        }
      case 'paragraph' || 'heading' || 'codeBlock' || 'blockquote':
        for (final k in kids) {
          walk(k, indent);
        }
        out.write('\n');
      default:
        for (final k in kids) {
          walk(k, indent);
        }
    }
  }

  walk(node, '');
  return out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// One paragraph per line; `*bold*` (Jira wiki style, used by the bug report) becomes strong text.
Map<String, dynamic> toAdf(String text) => {
  'type': 'doc',
  'version': 1,
  'content': [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty)
        {
          'type': 'paragraph',
          'content': [
            for (final m in RegExp(r'\*([^*\n]+)\*|[^*]+|\*').allMatches(line))
              {
                'type': 'text',
                'text': m[1] ?? m[0]!,
                if (m[1] != null)
                  'marks': [
                    {'type': 'strong'},
                  ],
              },
          ],
        },
  ],
};

// ---------------------------------------------------------------- Bitbucket

class PullRequest {
  PullRequest({
    required this.id,
    required this.repo,
    required this.title,
    required this.source,
    required this.dest,
    required this.author,
    required this.mine,
    required this.reviewer,
    required this.approvedByMe,
    required this.approvals,
    required this.comments,
    required this.url,
    this.updated,
  });

  final int id;
  final String repo, title, source, dest, author, url;
  final bool mine, reviewer, approvedByMe;
  final int approvals, comments;
  final DateTime? updated;
}

class BitbucketClient {
  BitbucketClient(this.config);

  final AtlassianConfig config;
  String? _me;

  String get _auth => _basic(config.bbUser, config.bbToken);

  Future<dynamic> _req(String method, String path, {Map<String, String>? query, Object? json}) =>
      _send(method, Uri.parse('https://api.bitbucket.org/2.0$path').replace(queryParameters: query), _auth, json: json);

  String _repo(String slug) => '/repositories/${config.bbWorkspace}/$slug';

  Future<String> me() async => _me ??= ((await _req('GET', '/user')) as Map)['uuid'] as String;

  Future<List<PullRequest>> openPrs(String slug) async {
    final me = await this.me();
    final res = await _req(
      'GET',
      '${_repo(slug)}/pullrequests',
      query: {'state': 'OPEN', 'pagelen': '50', 'fields': '+values.participants,-values.summary,-values.rendered'},
    );
    return [
      for (final p in (res['values'] as List? ?? const []))
        () {
          final parts = (p['participants'] as List? ?? const []).cast<Map>();
          final mePart = parts.where((x) => x['user']?['uuid'] == me).firstOrNull;
          return PullRequest(
            id: p['id'] as int,
            repo: slug,
            title: p['title'] as String? ?? '',
            source: p['source']?['branch']?['name'] as String? ?? '',
            dest: p['destination']?['branch']?['name'] as String? ?? '',
            author: p['author']?['display_name'] as String? ?? '?',
            mine: p['author']?['uuid'] == me,
            reviewer: mePart?['role'] == 'REVIEWER',
            approvedByMe: mePart?['approved'] == true,
            approvals: parts.where((x) => x['approved'] == true).length,
            comments: p['comment_count'] as int? ?? 0,
            url: p['links']?['html']?['href'] as String? ?? '',
            updated: DateTime.tryParse(p['updated_on'] as String? ?? ''),
          );
        }(),
    ];
  }

  Future<List<Map>> _defaultReviewers(String slug, String me) async {
    try {
      final res = await _req('GET', '${_repo(slug)}/default-reviewers', query: {'pagelen': '50'});
      return [
        for (final r in (res['values'] as List? ?? const []))
          if (r['uuid'] != me) {'uuid': r['uuid']},
      ];
    } on ApiException {
      return const [];
    }
  }

  Future<PullRequest> createPr(
    String slug, {
    required String source,
    required String dest,
    required String title,
    required String description,
  }) async {
    final me = await this.me();
    final res = await _req(
      'POST',
      '${_repo(slug)}/pullrequests',
      json: {
        'title': title,
        'description': description,
        'source': {
          'branch': {'name': source},
        },
        'destination': {
          'branch': {'name': dest},
        },
        'reviewers': await _defaultReviewers(slug, me),
        'close_source_branch': true,
      },
    );
    return PullRequest(
      id: res['id'] as int,
      repo: slug,
      title: title,
      source: source,
      dest: dest,
      author: '',
      mine: true,
      reviewer: false,
      approvedByMe: false,
      approvals: 0,
      comments: 0,
      url: res['links']?['html']?['href'] as String? ?? '',
    );
  }

  Future<void> approve(PullRequest pr, {bool undo = false}) =>
      _req(undo ? 'DELETE' : 'POST', '${_repo(pr.repo)}/pullrequests/${pr.id}/approve');

  /// Latest pipeline state for a branch, e.g. SUCCESSFUL / FAILED / IN_PROGRESS.
  Future<String?> pipelineState(String slug, String branch) async {
    try {
      final res = await _req(
        'GET',
        '${_repo(slug)}/pipelines/',
        query: {'target.branch': branch, 'sort': '-created_on', 'pagelen': '1'},
      );
      final p = (res['values'] as List?)?.firstOrNull as Map?;
      if (p == null) return null;
      final state = p['state'] as Map?;
      return (state?['result']?['name'] ?? state?['name']) as String?;
    } on ApiException catch (e) {
      debugPrint('pipelines: $e');
      return null;
    }
  }
}
