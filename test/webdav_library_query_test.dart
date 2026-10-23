import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/webdav_library_models.dart';
import 'package:venera/foundation/webdav_library_query.dart';
import 'package:venera/foundation/webdav_metadata.dart';

void main() {
  final entries = [
    for (var i = 1; i <= 60; i++)
      WebdavEntry.comic(
        name: 'folder $i',
        path: '/library/$i/',
        modified: i == 60 ? null : DateTime(2026, 1, i),
      ),
    WebdavEntry.archive(name: 'bundle.cbz', path: '/library/bundle.cbz'),
  ];
  final metadata = {
    for (var i = 1; i <= 60; i++)
      '/library/$i/': WebdavMetadata(
        title: 'Title $i',
        authors: i == 60 ? [] : [i.isEven ? 'Alice' : 'Bob'],
        tags: [i.isEven ? 'tag' : 'tag-long'],
      ),
  };

  test('natural-sorts before slicing and counts the whole library', () {
    final result = const WebdavLibraryQuery(page: 2).apply(entries, metadata);
    expect(result.total, 60);
    expect(result.pages, 3);
    expect(result.entries.length, 24);
    expect(result.entries.first.path, '/library/25/');
    expect(result.entries.last.path, '/library/48/');
  });

  test('searches metadata outside the first page and directory names', () {
    final result = const WebdavLibraryQuery(
      keyword: ' title 59 ',
    ).apply(entries, metadata);
    expect(result.entries.single.path, '/library/59/');
    expect(
      const WebdavLibraryQuery(
        keyword: 'folder 59',
      ).apply(entries, metadata).total,
      1,
    );
    expect(
      const WebdavLibraryQuery(keyword: 'ALICE').apply(entries, metadata).total,
      29,
    );
    expect(
      const WebdavLibraryQuery(
        keyword: 'tag-long',
      ).apply(entries, metadata).total,
      30,
    );
  });

  test('exact tag filter does not include substring matches', () {
    final result = const WebdavLibraryQuery(
      filter: WebdavFilter(WebdavFilterKind.tag, ' TAG '),
    ).apply(entries, metadata);
    expect(result.total, 30);
    expect(
      result.entries.every((e) => int.parse(e.name.split(' ').last).isEven),
      isTrue,
    );
  });

  test('exact author combines with a text query', () {
    final result = const WebdavLibraryQuery(
      keyword: 'Title 2',
      filter: WebdavFilter(WebdavFilterKind.author, 'alice'),
    ).apply(entries, metadata);
    expect(result.total, 6);
    expect(
      const WebdavLibraryQuery(
        filter: WebdavFilter(WebdavFilterKind.author, 'Ali'),
      ).apply(entries, metadata).total,
      0,
    );
  });

  test('author and time missing values are last in both directions', () {
    for (final sort in [WebdavSort.author, WebdavSort.modified]) {
      for (final descending in [false, true]) {
        final result = WebdavLibraryQuery(
          sort: sort,
          descending: descending,
          pageSize: 96,
        ).apply(entries, metadata);
        expect(result.entries.last.path, '/library/60/');
      }
    }
  });

  test('descending time sorts newest first', () {
    final result = const WebdavLibraryQuery(
      sort: WebdavSort.modified,
      descending: true,
    ).apply(entries, metadata);
    expect(result.entries.first.path, '/library/59/');
  });

  test('empty results, invalid page size and pages are bounded', () {
    final empty = const WebdavLibraryQuery(
      keyword: 'missing',
      page: 99,
    ).apply(entries, metadata);
    expect(empty.total, 0);
    expect(empty.page, 1);
    expect(empty.entries, isEmpty);
    expect(const WebdavLibraryQuery(page: 99).apply(entries, metadata).page, 3);
    expect(
      const WebdavLibraryQuery(
        page: -1,
        pageSize: 0,
      ).apply(entries, metadata).entries.length,
      24,
    );
  });

  test('archives have a separate result count and ignore comic filters', () {
    final result = const WebdavLibraryQuery(
      archives: true,
      keyword: 'bundle',
      filter: WebdavFilter(WebdavFilterKind.author, 'Alice'),
    ).apply(entries, metadata);
    expect(result.total, 1);
    expect(result.entries.single.isArchiveFile, isTrue);
  });

  test(
    'same titles use a stable path tiebreaker and empty title falls back',
    () {
      final same = [
        WebdavEntry.comic(name: 'Title', path: '/z/'),
        WebdavEntry.comic(name: 'Title', path: '/a/'),
      ];
      expect(
        const WebdavLibraryQuery().apply(same, {}).entries.first.path,
        '/a/',
      );
      expect(
        const WebdavLibraryQuery()
            .apply(same.reversed.toList(), {'/z/': const WebdavMetadata()})
            .entries
            .first
            .path,
        '/a/',
      );
    },
  );
}
