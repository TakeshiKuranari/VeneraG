import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/webdav_library_controls.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/webdav_library_query.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  setUp(() {
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'zh-CN';
    addTearDown(() => appdata.settings['language'] = language);
  });

  Widget wrap(Widget child, {double scale = 1}) => MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );

  for (final width in [320.0, 360.0, 600.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('pager stays on one line at $width px, text scale $scale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          wrap(
            Column(
              children: [
                WebdavLibrarySortBar(
                  sort: WebdavSort.modified,
                  descending: false,
                  onSortChanged: (_) {},
                  onDirectionChanged: () {},
                ),
                WebdavLibraryPagination(
                  result: const WebdavQueryResult([], 222, 7, 10),
                  onPageChanged: (_) {},
                  onJumpToPage: () {},
                ),
              ],
            ),
            scale: scale,
          ),
        );
        expect(tester.takeException(), isNull);
        final previous = tester.getCenter(find.byIcon(Icons.chevron_left));
        final next = tester.getCenter(find.byIcon(Icons.chevron_right));
        final page = tester.getCenter(find.text('7 / 10'));
        expect(previous.dy, page.dy);
        expect(next.dy, page.dy);
        expect(previous.dx, lessThan(page.dx));
        expect(page.dx, lessThan(next.dx));
      });
    }
  }

  testWidgets('pager navigates, jumps and disables boundary buttons', (
    tester,
  ) async {
    final pages = <int>[];
    var jumps = 0;
    Future<void> showPage(int page, int totalPages) => tester.pumpWidget(
      wrap(
        WebdavLibraryPagination(
          result: WebdavQueryResult(const [], 222, page, totalPages),
          onPageChanged: pages.add,
          onJumpToPage: () => jumps++,
        ),
      ),
    );

    await showPage(7, 10);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.tap(find.text('7 / 10'));
    expect(pages, [6, 8]);
    expect(jumps, 1);

    await showPage(1, 1);
    expect(
      tester.widget<IconButton>(find.byType(IconButton).first).onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton).last).onPressed,
      isNull,
    );
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );
  });

  testWidgets('sort menu works without a page size selector', (tester) async {
    WebdavSort? sort;
    var directions = 0;
    await tester.pumpWidget(
      wrap(
        WebdavLibrarySortBar(
          sort: WebdavSort.title,
          descending: false,
          onSortChanged: (value) => sort = value,
          onDirectionChanged: () => directions++,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is CheckedPopupMenuItem<WebdavSort> &&
            widget.value == WebdavSort.author,
      ),
    );
    await tester.pumpAndSettle();
    expect(sort, WebdavSort.author);

    expect(find.byType(PopupMenuButton<int>), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_upward));
    expect(directions, 1);
    expect(tester.takeException(), isNull);
  });
}
