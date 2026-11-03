import 'package:path/path.dart' as p;

enum PreviewKind {
  image,
  svg,
  pdf,
  markdown,
  table,
  json,
  font,
  archive,
  binary,
  none;

  /// These can't be edited as text, so the preview is all the tab has.
  bool get onlyPreview => this == image || this == pdf || this == font || this == archive || this == binary;
}

const _kinds = {
  '.png': PreviewKind.image,
  '.jpg': PreviewKind.image,
  '.jpeg': PreviewKind.image,
  '.gif': PreviewKind.image,
  '.webp': PreviewKind.image,
  '.bmp': PreviewKind.image,
  '.ico': PreviewKind.image,
  '.wbmp': PreviewKind.image,
  '.svg': PreviewKind.svg,
  '.pdf': PreviewKind.pdf,
  '.md': PreviewKind.markdown,
  '.markdown': PreviewKind.markdown,
  '.csv': PreviewKind.table,
  '.tsv': PreviewKind.table,
  '.json': PreviewKind.json,
  '.arb': PreviewKind.json,
  '.ttf': PreviewKind.font,
  '.otf': PreviewKind.font,
  '.zip': PreviewKind.archive,
  '.apk': PreviewKind.archive,
  '.aab': PreviewKind.archive,
  '.aar': PreviewKind.archive,
  '.jar': PreviewKind.archive,
  '.ipa': PreviewKind.archive,
};

PreviewKind previewKindOf(String path) => _kinds[p.extension(path).toLowerCase()] ?? PreviewKind.none;
