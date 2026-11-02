import 'package:flutter/material.dart';

import 'atlassian.dart';
import 'work_service.dart';

class WorkSettingsDialog extends StatefulWidget {
  const WorkSettingsDialog({super.key});

  @override
  State<WorkSettingsDialog> createState() => _WorkSettingsDialogState();
}

class _WorkSettingsDialogState extends State<WorkSettingsDialog> {
  final _c = WorkService.instance.config;
  late final _jiraUrl = TextEditingController(text: _c.jiraUrl);
  late final _jiraEmail = TextEditingController(text: _c.jiraEmail);
  late final _jiraToken = TextEditingController(text: _c.jiraToken);
  late final _jiraProject = TextEditingController(text: _c.jiraProject);
  late final _bbWorkspace = TextEditingController(text: _c.bbWorkspace);
  late final _bbUser = TextEditingController(text: _c.bbUser);
  late final _bbToken = TextEditingController(text: _c.bbToken);
  late final _base = TextEditingController(text: _c.baseBranch);
  String? _jiraResult, _bbResult;
  var _testing = false;

  AtlassianConfig get _draft => AtlassianConfig(
    jiraUrl: _jiraUrl.text.trim().replaceAll(RegExp(r'/+$'), ''),
    jiraEmail: _jiraEmail.text.trim(),
    jiraToken: _jiraToken.text.trim(),
    jiraProject: _jiraProject.text.trim().toUpperCase(),
    bbWorkspace: _bbWorkspace.text.trim(),
    bbUser: _bbUser.text.trim(),
    bbToken: _bbToken.text.trim(),
    baseBranch: _base.text.trim().isEmpty ? 'develop' : _base.text.trim(),
  );

  Future<void> _test() async {
    final d = _draft;
    setState(() {
      _testing = true;
      _jiraResult = _bbResult = null;
    });
    final results = await Future.wait([
      if (d.hasJira)
        JiraClient(d).myself().then((n) => '✓ Signed in as $n', onError: (e) => '✗ $e')
      else
        Future.value('Not set'),
      if (d.hasBitbucket)
        BitbucketClient(d).me().then((_) => '✓ Connected', onError: (e) => '✗ $e')
      else
        Future.value('Not set'),
    ]);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _jiraResult = results[0];
      _bbResult = results[1];
    });
  }

  Future<void> _save() async {
    await WorkService.instance.save(_draft);
    if (mounted) Navigator.pop(context, true);
  }

  Widget _field(TextEditingController c, String label, {String? hint, bool secret = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: c,
      obscureText: secret,
      decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), isDense: true),
    ),
  );

  Widget _result(String? r) => r == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(r, style: TextStyle(fontSize: 12, color: r.startsWith('✓') ? Colors.green : Colors.red)),
        );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final outline = Theme.of(context).colorScheme.outline;
    return AlertDialog(
      title: const Text('Connect Jira & Bitbucket'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Tokens are encrypted for your Windows account and never leave this PC except to Atlassian.',
                style: TextStyle(color: outline, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text('Jira', style: text.titleSmall),
                  const Spacer(),
                  TextButton(
                    onPressed: () => openUrl('https://id.atlassian.com/manage-profile/security/api-tokens'),
                    child: const Text('Create API token'),
                  ),
                ],
              ),
              _field(_jiraUrl, 'Site URL', hint: 'https://yourteam.atlassian.net'),
              _field(_jiraEmail, 'Email', hint: 'Leave empty for a Server/Data Center personal access token'),
              _field(_jiraToken, 'API token', secret: true),
              _field(_jiraProject, 'Project key (optional)', hint: 'e.g. POS — empty shows all your projects'),
              _result(_jiraResult),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text('Bitbucket', style: text.titleSmall),
                  const Spacer(),
                  TextButton(
                    onPressed: () => openUrl('https://bitbucket.org/account/settings/app-passwords/'),
                    child: const Text('Create app password'),
                  ),
                ],
              ),
              _field(_bbWorkspace, 'Workspace', hint: 'my-team'),
              _field(_bbUser, 'Username or email', hint: 'Username for app passwords, email for API tokens'),
              _field(_bbToken, 'App password or API token', secret: true),
              Text(
                'Needs read access to repositories and read/write to pull requests.',
                style: TextStyle(color: outline, fontSize: 12),
              ),
              const SizedBox(height: 8),
              _result(_bbResult),
              const SizedBox(height: 6),
              Text('Git', style: text.titleSmall),
              const SizedBox(height: 8),
              _field(_base, 'Base branch for new work', hint: 'develop'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _testing ? null : _test,
          icon: _testing
              ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_tethering, size: 18),
          label: const Text('Test connection'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
