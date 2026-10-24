import 'package:flutter/material.dart';
import 'package:venera/foundation/webdav_library_query.dart';
import 'package:venera/utils/translations.dart';

class WebdavLibrarySortBar extends StatelessWidget {
  const WebdavLibrarySortBar({
    super.key,
    required this.sort,
    required this.descending,
    required this.onSortChanged,
    required this.onDirectionChanged,
  });

  final WebdavSort sort;
  final bool descending;
  final ValueChanged<WebdavSort> onSortChanged;
  final VoidCallback onDirectionChanged;

  String _sortLabel(WebdavSort value) => switch (value) {
    WebdavSort.title => 'Title'.tl,
    WebdavSort.author => 'Authors'.tl,
    WebdavSort.modified => 'Remote modification time'.tl,
  };

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: PopupMenuButton<WebdavSort>(
          tooltip: 'Sort'.tl,
          initialValue: sort,
          onSelected: onSortChanged,
          itemBuilder: (_) => [
            for (final value in WebdavSort.values)
              CheckedPopupMenuItem(
                value: value,
                checked: sort == value,
                child: Text(_sortLabel(value)),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.sort, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _sortLabel(sort),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: descending ? 'Descending'.tl : 'Ascending'.tl,
        icon: Icon(descending ? Icons.arrow_downward : Icons.arrow_upward),
        onPressed: onDirectionChanged,
      ),
    ],
  );
}

/// Keep navigation together on narrow screens; the count yields space first.
class WebdavLibraryPagination extends StatelessWidget {
  const WebdavLibraryPagination({
    super.key,
    required this.result,
    required this.onPageChanged,
    required this.onJumpToPage,
  });

  final WebdavQueryResult result;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onJumpToPage;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          '@count results'.tlParams({'count': '${result.total}'}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton(
        tooltip: 'Previous page'.tl,
        icon: const Icon(Icons.chevron_left),
        onPressed: result.page <= 1
            ? null
            : () => onPageChanged(result.page - 1),
      ),
      Flexible(
        child: Tooltip(
          message: 'Go to page'.tl,
          child: TextButton(
            onPressed: result.pages <= 1 ? null : onJumpToPage,
            child: Text(
              '${result.page} / ${result.pages}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              semanticsLabel: 'Page @page / @pages'.tlParams({
                'page': '${result.page}',
                'pages': '${result.pages}',
              }),
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: 'Next page'.tl,
        icon: const Icon(Icons.chevron_right),
        onPressed: result.page >= result.pages
            ? null
            : () => onPageChanged(result.page + 1),
      ),
    ],
  );
}
