import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/webdav_library_controls.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/webdav_library_index.dart';
import 'package:venera/foundation/webdav_library_index_store.dart';
import 'package:venera/foundation/webdav_library_query.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/foundation/webdav_metadata.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/webdav_libraries_page.dart';
import 'package:venera/utils/translations.dart';

/// Browses and searches folder-based comics online.
class WebdavLibraryPage extends StatefulWidget {
  const WebdavLibraryPage({
    super.key,
    required this.libraryId,
    this.dir,
    this.initialFilter,
  });

  final String libraryId;
  final String? dir;
  final WebdavFilter? initialFilter;

  @override
  State<WebdavLibraryPage> createState() => _WebdavLibraryPageState();
}

class _WebdavLibraryPageState extends State<WebdavLibraryPage> {
  bool loading = true;
  String? error;
  List<WebdavEntry> entries = const [];
  Map<String, WebdavMetadata?> metadata = const {};
  WebdavLibraryIndex? _index;
  int _generation = 0;
  bool _indexing = false;
  int _failures = 0;
  final _progress = ValueNotifier((done: 0, total: 0));
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _query = _LibraryQueryState();
  bool searchMode = false;
  WebdavLibraryConfig? get _config => WebdavLibraryStore.find(widget.libraryId);

  @override
  void initState() {
    super.initState();
    _query.filter = widget.initialFilter;
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _index?.release();
    _progress.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    final generation = ++_generation;
    final config = _config;
    final client = config == null ? null : WebdavLibraryClient(config);
    final index = config == null
        ? null
        : WebdavLibraryIndexes.acquire(config, reader: client!.readMetadata);
    _index?.release();
    _index = index;
    setState(() {
      loading = true;
      error = null;
      _indexing = false;
      _failures = 0;
      _progress.value = (done: 0, total: 0);
      // Do not retain a snapshot from an edited server/account/root.
      metadata = const {};
    });
    if (config == null || index == null) {
      setState(() {
        loading = false;
        entries = const [];
      });
      return;
    }
    final response = await client!.listEntries(widget.dir);
    await index.ready;
    if (!mounted || generation != _generation) return;
    setState(() {
      loading = false;
      if (response.error) {
        error = response.errorMessage;
      } else {
        entries = response.data;
        metadata = index.snapshot;
        _indexing = true;
      }
    });
    if (response.error) return;
    final failures = await index.refresh(
      entries,
      directory: widget.dir ?? config.rootPath,
      force: force,
      onProgress: (done, total) {
        if (!mounted || generation != _generation) return;
        _progress.value = (done: done, total: total);
      },
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      metadata = index.snapshot;
      _indexing = false;
      _failures = failures;
      _query.page = _result().page;
    });
  }

  WebdavQueryResult _result() => WebdavLibraryQuery(
    keyword: _query.keyword,
    filter: _query.filter,
    sort: _query.sort,
    descending: _query.descending,
    page: _query.page,
  ).apply(entries, metadata);

  void _change(VoidCallback change, {bool resetPage = true}) {
    setState(() {
      change();
      if (resetPage) _query.page = 1;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _exitSearch() {
    _search.clear();
    _change(() {
      searchMode = false;
      _query.keyword = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    return PopScope(
      canPop: !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _exitSearch();
      },
      child: Scaffold(
        body: SmoothCustomScrollView(
          controller: _scroll,
          scrollbarTopPadding: context.padding.top + 56,
          slivers: [
            SliverAppbar(
              leading: searchMode
                  ? IconButton(
                      tooltip: 'Cancel'.tl,
                      icon: const Icon(Icons.close),
                      onPressed: _exitSearch,
                    )
                  : null,
              title: searchMode
                  ? AppSearchField(
                      controller: _search,
                      autofocus: true,
                      height: AppSearchField.toolbarHeight,
                      hintText: 'Search titles, authors and tags'.tl,
                      onChanged: (value) =>
                          _change(() => _query.keyword = value),
                    )
                  : Text(
                      widget.dir == null
                          ? (config?.displayName ?? 'WebDAV Library'.tl)
                          : WebdavLibrary.titleOf(widget.dir!),
                    ),
              actions: [
                if (!searchMode)
                  IconButton(
                    tooltip: 'Search'.tl,
                    icon: const Icon(Icons.search),
                    onPressed: () => setState(() => searchMode = true),
                  ),
                if (widget.dir == null && !searchMode)
                  IconButton(
                    tooltip: 'Settings'.tl,
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () async {
                      final current = _config;
                      if (current == null) return;
                      await showPopUpWidget(
                        context,
                        WebdavLibraryEditor(config: current),
                      );
                      if (mounted) _load();
                    },
                  ),
                IconButton(
                  tooltip: 'Refresh library and metadata'.tl,
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _load(force: true),
                ),
              ],
            ),
            if (config != null) SliverToBoxAdapter(child: _controls()),
            ..._buildBody(),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WebdavLibrarySortBar(
            sort: _query.sort,
            descending: _query.descending,
            onSortChanged: (value) => _change(() => _query.sort = value),
            onDirectionChanged: () =>
                _change(() => _query.descending = !_query.descending),
          ),
          if (_query.filter case final filter?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InputChip(
                label: Text(
                  '${filter.kind == WebdavFilterKind.author ? "Authors".tl : "Tags".tl}: ${filter.value}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onDeleted: () => _change(() => _query.filter = null),
              ),
            ),
          if (_indexing)
            ValueListenableBuilder(
              valueListenable: _progress,
              builder: (context, progress, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: progress.total == 0
                        ? null
                        : progress.done / progress.total,
                  ),
                  Text(
                    'Indexing metadata: @done / @total. Results are incomplete.'
                        .tlParams({
                          'done': '${progress.done}',
                          'total': '${progress.total}',
                        }),
                  ),
                ],
              ),
            ),
          if (!_indexing && _failures > 0)
            Text(
              'Could not refresh metadata for @count comics. Refresh to retry.'
                  .tlParams({'count': '$_failures'}),
            ),
          if (!loading && error == null) _pagination(_result()),
        ],
      ),
    );
  }

  Widget _pagination(WebdavQueryResult result) => WebdavLibraryPagination(
    result: result,
    onPageChanged: (page) =>
        _change(() => _query.page = page, resetPage: false),
    onJumpToPage: () => _jumpToPage(result),
  );

  Future<void> _jumpToPage(WebdavQueryResult result) async {
    final page = await showDialog<int>(
      context: context,
      builder: (_) => _PageJumpDialog(page: result.page),
    );
    if (mounted && page != null) {
      _change(
        () => _query.page = page.clamp(1, result.pages),
        resetPage: false,
      );
    }
  }

  List<Widget> _buildBody() {
    if (_config == null) {
      return [_empty('WebDAV comic library is not configured'.tl)];
    }
    if (loading) {
      return const [
        SliverFillRemaining(child: Center(child: CircularProgressIndicator())),
      ];
    }
    if (error != null) {
      return [
        SliverFillRemaining(
          child: NetworkError(
            message: error!,
            retry: () => _load(),
            withAppbar: false,
          ),
        ),
      ];
    }
    final result = _result();
    if (result.entries.isEmpty) {
      return [
        _empty(
          entries.isEmpty ? 'Nothing here'.tl : 'No search results found'.tl,
        ),
      ];
    }
    return [
      SliverGridComics(
        comics: result.entries.map((e) {
          final m = metadata[e.path];
          return Comic(
            m?.title.isNotEmpty == true ? m!.title : e.name,
            'cover.jpg',
            e.comicId,
            m?.authors.join(', '),
            m?.tags,
            m?.description ?? '',
            _config!.sourceKey,
            null,
            null,
          );
        }).toList(),
        onTap: _openComic,
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _pagination(result),
        ),
      ),
    ];
  }

  Widget _empty(String message) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(child: Text(message)),
  );

  void _openComic(Comic comic, int heroID) {
    final sourceKey = _config?.sourceKey;
    if (sourceKey == null) return;
    context.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: sourceKey,
        title: comic.title,
        heroID: heroID,
      ),
    );
  }
}

class _LibraryQueryState {
  String keyword = '';
  WebdavFilter? filter;
  WebdavSort sort = WebdavSort.title;
  bool descending = false;
  int page = 1;
}

class _PageJumpDialog extends StatefulWidget {
  const _PageJumpDialog({required this.page});
  final int page;

  @override
  State<_PageJumpDialog> createState() => _PageJumpDialogState();
}

class _PageJumpDialogState extends State<_PageJumpDialog> {
  late final _input = TextEditingController(text: '${widget.page}');

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit(String text) {
    final page = int.tryParse(text);
    if (page != null) Navigator.pop(context, page);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Go to page'.tl),
    content: TextField(
      controller: _input,
      autofocus: true,
      keyboardType: TextInputType.number,
      onSubmitted: _submit,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text('Cancel'.tl),
      ),
      TextButton(
        onPressed: () => _submit(_input.text),
        child: Text('Confirm'.tl),
      ),
    ],
  );
}
