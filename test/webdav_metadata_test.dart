import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/webdav_metadata.dart';

void main() {
  group('WebDAV portable metadata', () {
    test('reads the sync format and separates authors from flat tags', () {
      final metadata = WebdavMetadata.parse(
        utf8.encode(
          jsonEncode({
            'title': '作品标题',
            'author': 'Author A, Author B, author a, ',
            'tags': ['category', 'tag', 'TAG', '', '中文'],
            'chapters': null,
          }),
        ),
      );
      expect(metadata.title, '作品标题');
      expect(metadata.authors, ['Author A', 'Author B']);
      expect(metadata.tags, ['category', 'tag', '中文']);
      expect(metadata.detailTags['author'], metadata.authors);
      expect(metadata.detailTags['Tags'], metadata.tags);
    });

    test('accepts UTF-8 BOM and optional description', () {
      final metadata = WebdavMetadata.parse(
        utf8.encode('\uFEFF{"title":"标题","description":"简介"}'),
      );
      expect(metadata.title, '标题');
      expect(metadata.description, '简介');
      expect(metadata.authors, isEmpty);
    });

    test('ignores fields of the wrong type and invalid list items', () {
      final metadata = WebdavMetadata.fromJson({
        'title': 2,
        'author': null,
        'tags': [' ok ', 2, null],
      });
      expect(metadata.title, isEmpty);
      expect(metadata.authors, isEmpty);
      expect(metadata.tags, ['ok']);
    });

    test('rejects malformed JSON, non-object JSON and invalid UTF-8', () {
      for (final bytes in [
        utf8.encode('{'),
        utf8.encode('[]'),
        [0xFF],
      ]) {
        expect(() => WebdavMetadata.parse(bytes), throwsFormatException);
      }
    });

    test('cache serialization preserves metadata', () {
      const original = WebdavMetadata(
        title: 'Title',
        authors: ['A', 'B'],
        tags: ['tag'],
        description: 'Text',
      );
      final restored = WebdavMetadata.fromJson(original.toJson());
      expect(restored.toJson(), original.toJson());
    });
  });
}
