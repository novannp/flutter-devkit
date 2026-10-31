import 'dart:io';

/// Copies a PNG to the clipboard as an image (not a path) so it can be pasted straight into Slack/Jira.
Future<bool> copyImageToClipboard(String path) async {
  try {
    if (Platform.isWindows) {
      // WinForms clipboard needs an STA thread.
      final escaped = path.replaceAll("'", "''");
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; "
            "\$img = [System.Drawing.Image]::FromFile('$escaped'); "
            "[System.Windows.Forms.Clipboard]::SetImage(\$img); \$img.Dispose()",
      ]);
      return r.exitCode == 0;
    }
    if (Platform.isMacOS) {
      final r = await Process.run('osascript', [
        '-e',
        'set the clipboard to (read (POSIX file "$path") as «class PNGf»)',
      ]);
      return r.exitCode == 0;
    }
  } catch (_) {}
  return false;
}
