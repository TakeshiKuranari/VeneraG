import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
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
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// Browses folder-based comics online and offers archives for local import.
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
  final _tabs = [_LibraryTab(), _LibraryTab()];
  bool _archives = false;
  bool searchMode = false;
  _LibraryTab get _tab => _tabs[_archives ? 1 : 0];
  WebdavLibraryConfig? get _config => WebdavLibraryStore.find(widget.libraryId);

  @override
  void initState() {
    super.initState();
    _tabs.first.filter = widget.initialFilter;
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
      for (var i = 0; i < _tabs.length; i++) {
        _tabs[i].page = _result(archives: i == 1).page;
      }
    });
  }

  WebdavQueryResult _result({bool? archives}) {
    final isArchive = archives ?? _archives;
    final tab = _tabs[isArchive ? 1 : 0];
    return WebdavLibraryQuery(
      keyword: tab.keyword,
      filter: tab.filter,
      sort: tab.sort,
      descending: tab.descending,
      page: tab.page,
      pageSize: tab.pageSize,
      archives: isArchive,
    ).apply(entries, metadata);
  }

  void _change(VoidCallback change, {bool resetPage = true}) {
    setState(() {
      change();
      if (resetPage) _tab.page = 1;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _exitSearch() {
    _search.clear();
    _change(() {
      searchMode = false;
      _tab.keyword = '';
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
                      onChanged: (value) => _change(() => _tab.keyword = value),
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
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final archives in [false, true])
                ChoiceChip(
                  label: Text(archives ? 'Archives'.tl : 'Comics'.tl),
                  selected: _archives == archives,
                  onSelected: (_) => _change(() {
                    _archives = archives;
                    _search.text = _tab.keyword;
                  }, resetPage: false),
                ),
              DropdownButton<WebdavSort>(
                value: _tab.sort,
                items: [
                  DropdownMenuItem(
                    value: WebdavSort.title,
                    child: Text('Title'.tl),
                  ),
                  if (!_archives)
                    DropdownMenuItem(
                      value: WebdavSort.author,
                      child: Text('Authors'.tl),
                    ),
                  DropdownMenuItem(
                    value: WebdavSort.modified,
                    child: Text('Remote modification time'.tl),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) _change(() => _tab.sort = value);
                },
              ),
              IconButton(
                tooltip: _tab.descending ? 'Descending'.tl : 'Ascending'.tl,
                icon: Icon(
                  _tab.descending ? Icons.arrow_downward : Icons.arrow_upward,
                ),
                onPressed: () =>
                    _change(() => _tab.descending = !_tab.descending),
              ),
              if (_tab.filter case final filter?)
                InputChip(
                  label: Text(
                    '${filter.kind == WebdavFilterKind.author ? "Authors".tl : "Tags".tl}: ${filter.value}',
                  ),
                  onDeleted: () => _change(() => _tab.filter = null),
                ),
            ],
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

  Widget _pagination(WebdavQueryResult result) => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text('@count results'.tlParams({'count': '${result.total}'})),
      DropdownButton<int>(
        value: _tab.pageSize,
        items: [
          for (final size in [24, 48, 96])
            DropdownMenuItem(
              value: size,
              child: Text('@count per page'.tlParams({'count': '$size'})),
            ),
        ],
        onChanged: (value) {
          if (value != null) _change(() => _tab.pageSize = value);
        },
      ),
      IconButton(
        tooltip: 'Previous page'.tl,
        icon: const Icon(Icons.chevron_left),
        onPressed: result.page <= 1
            ? null
            : () =>
                  _change(() => _tab.page = result.page - 1, resetPage: false),
      ),
      TextButton(
        onPressed: result.pages <= 1 ? null : () => _jumpToPage(result),
        child: Text(
          'Page @page / @pages'.tlParams({
            'page': '${result.page}',
            'pages': '${result.pages}',
          }),
        ),
      ),
      IconButton(
        tooltip: 'Next page'.tl,
        icon: const Icon(Icons.chevron_right),
        onPressed: result.page >= result.pages
            ? null
            : () =>
                  _change(() => _tab.page = result.page + 1, resetPage: false),
      ),
    ],
  );

  Future<void> _jumpToPage(WebdavQueryResult result) async {
    final page = await showDialog<int>(
      context: context,
      builder: (_) => _PageJumpDialog(page: result.page),
    );
    if (mounted && page != null) {
      _change(() => _tab.page = page.clamp(1, result.pages), resetPage: false);
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
      if (!_archives)
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
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate((context, i) {
            final entry = result.entries[i];
            return ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(entry.name),
              subtitle: entry.size == null
                  ? null
                  : Text(_humanSize(entry.size!)),
              trailing: const Icon(Icons.download_outlined),
              onTap: () => _importArchive(entry),
            );
          }, childCount: result.entries.length),
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

  void _importArchive(WebdavEntry entry) async {
    final client = WebdavLibraryClient.forId(widget.libraryId);
    if (client == null) return;
    final dir = await _tempDir();
    final savePath = FilePath.join(dir, entry.name);
    final controller = showLoadingDialog(
      context,
      message: "Downloading".tl,
      allowCancel: false,
    );
    final res = await client.downloadArchive(entry.path, savePath);
    controller.close();
    if (!mounted) {
      // Left the page mid-download: still clean up the temp file.
      File(savePath).deleteIgnoreError();
      return;
    }
    if (res.error) {
      // A failed download may leave a half-written file behind.
      File(savePath).deleteIgnoreError();
      context.showMessage(message: res.errorMessage!);
      return;
    }
    // Reuse the existing archive importer; it opens its own progress dialog and
    // registers the comic into the local library. The temp file is always
    // removed afterwards, even if extraction throws on a corrupt archive.
    try {
      final importer = ImportComic(copyToLocal: true);
      await importer.cbzFile(File(savePath));
    } finally {
      File(savePath).deleteIgnoreError();
    }
  }

  static String _humanSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    double s = bytes.toDouble();
    int u = 0;
    while (s >= 1024 && u < units.length - 1) {
      s /= 1024;
      u++;
    }
    return '${s.toStringAsFixed(s < 10 && u > 0 ? 1 : 0)} ${units[u]}';
  }

  Future<String> _tempDir() async {
    final d = FilePath.join(App.cachePath, 'webdav_archive');
    final dir = Directory(d);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return d;
  }
}

class _LibraryTab {
  String keyword = '';
  WebdavFilter? filter;
  WebdavSort sort = WebdavSort.title;
  bool descending = false;
  int page = 1;
  int pageSize = 24;
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
