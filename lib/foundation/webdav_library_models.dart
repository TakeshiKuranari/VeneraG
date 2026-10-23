import 'dart:convert';

String ensureWebdavDirectory(String path) =>
    path.endsWith('/') ? path : '$path/';

String encodeWebdavComicId(String path) =>
    base64Url.encode(utf8.encode(ensureWebdavDirectory(path)));

int compareWebdavNames(String a, String b) {
  final ra = RegExp(r'(\d+|\D+)').allMatches(a).map((m) => m[0]!).toList();
  final rb = RegExp(r'(\d+|\D+)').allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < ra.length && i < rb.length; i++) {
    final sa = ra[i], sb = rb[i];
    final na = int.tryParse(sa), nb = int.tryParse(sb);
    int c;
    if (na != null && nb != null) {
      c = na.compareTo(nb);
    } else {
      c = sa.toLowerCase().compareTo(sb.toLowerCase());
    }
    if (c != 0) return c;
  }
  return ra.length.compareTo(rb.length);
}

/// A single browsable item: either a comic folder or an importable archive.
class WebdavEntry {
  final String name;
  final String path;
  final bool isArchiveFile;
  final int? size;
  final DateTime? modified;

  const WebdavEntry._({
    required this.name,
    required this.path,
    required this.isArchiveFile,
    this.size,
    this.modified,
  });

  factory WebdavEntry.comic({
    required String name,
    required String path,
    DateTime? modified,
  }) => WebdavEntry._(
    name: name,
    path: ensureWebdavDirectory(path),
    isArchiveFile: false,
    modified: _validTime(modified),
  );

  factory WebdavEntry.archive({
    required String name,
    required String path,
    int? size,
    DateTime? modified,
  }) => WebdavEntry._(
    name: name,
    path: path,
    isArchiveFile: true,
    size: size,
    modified: _validTime(modified),
  );

  static DateTime? _validTime(DateTime? value) =>
      value != null && value.millisecondsSinceEpoch > 0 ? value : null;

  /// The opaque comic id used to open this folder as an online comic.
  String get comicId => encodeWebdavComicId(path);
}
