import 'dart:convert';

/// The portable metadata written by the favorites sync tool. Chapter ranges
/// deliberately stay out of this model: WebDAV chapters come from directories.
class WebdavMetadata {
  const WebdavMetadata({
    this.title = '',
    this.authors = const [],
    this.tags = const [],
    this.description = '',
  });

  final String title;
  final List<String> authors;
  final List<String> tags;
  final String description;

  static List<String> _strings(Iterable<dynamic> values) {
    final seen = <String>{};
    return List.unmodifiable(
      values
          .whereType<String>()
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty && seen.add(v.toLowerCase())),
    );
  }

  factory WebdavMetadata.parse(List<int> bytes) {
    var text = utf8.decode(bytes);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Expected a metadata object');
    }
    return WebdavMetadata.fromJson(json);
  }

  factory WebdavMetadata.fromJson(Map<String, dynamic> json) {
    String string(String key) =>
        json[key] is String ? (json[key] as String).trim() : '';
    return WebdavMetadata(
      title: string('title'),
      authors: _strings(string('author').split(',')),
      tags: _strings(json['tags'] is List ? json['tags'] as List : const []),
      description: string('description'),
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': authors.join(', '),
    'tags': tags,
    'description': description,
  };

  Map<String, List<String>> get detailTags => {
    if (authors.isNotEmpty) 'author': authors,
    if (tags.isNotEmpty) 'Tags': tags,
  };
}
