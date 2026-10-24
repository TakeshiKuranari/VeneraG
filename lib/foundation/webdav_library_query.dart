import 'package:venera/foundation/webdav_metadata.dart';
import 'package:venera/foundation/webdav_library_models.dart';

enum WebdavSort { title, author, modified }

enum WebdavFilterKind { author, tag }

class WebdavFilter {
  const WebdavFilter(this.kind, this.value);
  final WebdavFilterKind kind;
  final String value;
}

/// All operations precede slicing, so metadata search covers the entire library.
class WebdavLibraryQuery {
  const WebdavLibraryQuery({
    this.keyword = '',
    this.filter,
    this.sort = WebdavSort.title,
    this.descending = false,
    this.page = 1,
    this.pageSize = defaultPageSize,
    this.archives = false,
  });

  static const defaultPageSize = 20;

  final String keyword;
  final WebdavFilter? filter;
  final WebdavSort sort;
  final bool descending;
  final int page;
  final int pageSize;
  final bool archives;

  WebdavQueryResult apply(
    List<WebdavEntry> entries,
    Map<String, WebdavMetadata?> metadata,
  ) {
    String title(WebdavEntry e) {
      final value = metadata[e.path]?.title ?? '';
      return value.isEmpty || e.isArchiveFile ? e.name : value;
    }

    String author(WebdavEntry e) => metadata[e.path]?.authors.join(', ') ?? '';
    final needle = keyword.trim().toLowerCase();
    final exact = filter?.value.trim().toLowerCase();
    final result = entries.where((e) {
      if (e.isArchiveFile != archives) return false;
      final m = metadata[e.path];
      if (!archives && filter != null) {
        final values = filter!.kind == WebdavFilterKind.author
            ? m?.authors
            : m?.tags;
        if (values == null ||
            !values.any((v) => v.trim().toLowerCase() == exact)) {
          return false;
        }
      }
      return needle.isEmpty ||
          [
            e.name,
            title(e),
            if (!archives) ...[...?m?.authors, ...?m?.tags],
          ].any((v) => v.toLowerCase().contains(needle));
    }).toList();
    result.sort((a, b) {
      int comparison;
      switch (sort) {
        case WebdavSort.title:
          comparison = compareWebdavNames(title(a), title(b));
        case WebdavSort.author:
          final av = author(a), bv = author(b);
          if (av.isEmpty != bv.isEmpty) return av.isEmpty ? 1 : -1;
          comparison = compareWebdavNames(av, bv);
        case WebdavSort.modified:
          if ((a.modified == null) != (b.modified == null)) {
            return a.modified == null ? 1 : -1;
          }
          comparison = a.modified?.compareTo(b.modified!) ?? 0;
      }
      if (comparison != 0) return descending ? -comparison : comparison;
      comparison = compareWebdavNames(title(a), title(b));
      return comparison != 0 ? comparison : a.path.compareTo(b.path);
    });
    final size = pageSize > 0 ? pageSize : defaultPageSize;
    final pages = result.isEmpty ? 1 : (result.length / size).ceil();
    final current = page.clamp(1, pages);
    final start = (current - 1) * size;
    return WebdavQueryResult(
      result.sublist(start, (start + size).clamp(0, result.length)),
      result.length,
      current,
      pages,
    );
  }
}

class WebdavQueryResult {
  const WebdavQueryResult(this.entries, this.total, this.page, this.pages);
  final List<WebdavEntry> entries;
  final int total;
  final int page;
  final int pages;
}
