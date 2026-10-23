import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/webdav_library_index.dart';
import 'package:venera/foundation/webdav_library_models.dart';
import 'package:venera/foundation/webdav_metadata.dart';

void main() {
  late Directory directory;
  late String cache;
  late DateTime now;
  final indexes = <WebdavLibraryIndex>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venerag-index-test-');
    cache = '${directory.path}/index.json';
    now = DateTime.utc(2026, 10, 1);
  });
  tearDown(() async {
    for (final index in indexes) {
      index.close();
    }
    indexes.clear();
    await directory.delete(recursive: true);
  });

  WebdavLibraryIndex index(
    WebdavMetadataReader reader, {
    bool Function()? current,
  }) {
    final value = WebdavLibraryIndex(
      cacheFile: cache,
      reader: reader,
      clock: () => now,
      isCurrent: current,
    );
    indexes.add(value);
    return value;
  }

  test('cache survives reopen and expires exactly at seven days', () async {
    var calls = 0;
    Future<WebdavMetadata?> read(String _) async {
      calls++;
      return WebdavMetadata(title: 'Version $calls');
    }

    final first = index(read);
    await first.metadata('/library/a');
    first.close();
    now = now.add(const Duration(days: 7) - const Duration(milliseconds: 1));
    final second = index(read);
    expect((await second.metadata('/library/a/'))!.title, 'Version 1');
    expect(calls, 1);
    now = now.add(const Duration(milliseconds: 1));
    expect((await second.metadata('/library/a/'))!.title, 'Version 2');
    expect(calls, 2);
  });

  test('manual force bypasses a fresh cache', () async {
    var calls = 0;
    final value = index((_) async => WebdavMetadata(title: '${++calls}'));
    await value.metadata('/a/');
    await value.metadata('/a/', force: true);
    expect(calls, 2);
  });

  test('absent metadata uses the same seven-day lifetime', () async {
    var calls = 0;
    final value = index((_) async {
      calls++;
      return null;
    });
    await value.metadata('/a/');
    now = now.add(const Duration(days: 6));
    await value.metadata('/a/');
    expect(calls, 1);
    now = now.add(const Duration(days: 1));
    await value.metadata('/a/');
    expect(calls, 2);
  });

  test(
    'missing metadata is cached and force clears previous metadata',
    () async {
      var calls = 0;
      final value = index(
        (_) async => ++calls == 1 ? const WebdavMetadata(title: 'Old') : null,
      );
      await value.metadata('/a/');
      expect(await value.metadata('/a/', force: true), isNull);
      expect(await value.metadata('/a/'), isNull);
      expect(value.snapshot['/a/'], isNull);
      expect(calls, 2);
    },
  );

  test('network failure retains old data and does not renew TTL', () async {
    var calls = 0;
    final value = index((_) async {
      if (++calls > 1) throw const SocketException('offline');
      return const WebdavMetadata(title: 'Old');
    });
    await value.metadata('/a/');
    final saved = await File(cache).readAsString();
    now = now.add(const Duration(days: 7));
    await expectLater(value.metadata('/a/'), throwsA(isA<SocketException>()));
    await expectLater(value.metadata('/a/'), throwsA(isA<SocketException>()));
    expect(value.snapshot['/a/']!.title, 'Old');
    expect(await File(cache).readAsString(), saved);
    expect(calls, 3);
  });

  test('deduplicates simultaneous requests for the same path', () async {
    final response = Completer<WebdavMetadata?>();
    var calls = 0;
    final value = index((_) {
      calls++;
      return response.future;
    });
    final one = value.metadata('/a');
    final two = value.metadata('/a/');
    await Future<void>.delayed(Duration.zero);
    response.complete(const WebdavMetadata(title: 'A'));
    expect((await one)!.title, 'A');
    expect((await two)!.title, 'A');
    expect(calls, 1);
  });

  test('refresh caps concurrency and excludes archives', () async {
    var active = 0, peak = 0, calls = 0, progress = 0;
    final value = index((_) async {
      active++;
      calls++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      active--;
      return const WebdavMetadata();
    });
    final entries = [
      for (var i = 0; i < 30; i++)
        WebdavEntry.comic(name: '$i', path: '/library/$i/'),
      WebdavEntry.archive(name: 'a.cbz', path: '/library/a.cbz'),
    ];
    expect(
      await value.refresh(
        entries,
        directory: '/library/',
        onProgress: (done, total) {
          progress = done;
          expect(total, 30);
        },
      ),
      0,
    );
    expect(peak, 4);
    expect(calls, 30);
    expect(progress, 30);
    await value.refresh(entries, directory: '/library/');
    expect(calls, 30);
  });

  test(
    'visible detail requests take priority over queued background work',
    () async {
      final pending = <String, Completer<WebdavMetadata?>>{};
      final value = index((path) {
        final response = Completer<WebdavMetadata?>();
        pending[path] = response;
        return response.future;
      });
      final refresh = value.refresh([
        for (var i = 0; i < 12; i++)
          WebdavEntry.comic(name: '$i', path: '/library/$i/'),
      ], directory: '/library/');
      await Future<void>.delayed(Duration.zero);
      final requested = value.metadata('/library/9/');
      final expectation = expectLater(requested, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      pending['/library/0/']!.complete(null);
      await Future<void>.delayed(Duration.zero);
      expect(pending, contains('/library/9/'));
      expect(pending, isNot(contains('/library/4/')));
      value.close();
      for (final response in pending.values) {
        if (!response.isCompleted) response.complete(null);
      }
      await expectation;
      await refresh;
    },
  );

  test(
    'listing refresh removes deleted direct children but preserves other directories',
    () async {
      final value = index((_) async => const WebdavMetadata(title: 'A'));
      await value.metadata('/library/keep/');
      await value.metadata('/library/deleted/');
      await value.metadata('/other/keep/');
      await value.refresh([
        WebdavEntry.comic(name: 'Keep', path: '/library/keep/'),
        WebdavEntry.comic(name: 'New', path: '/library/new/'),
      ], directory: '/library/');
      expect(
        value.snapshot.keys,
        unorderedEquals(['/library/keep/', '/library/new/', '/other/keep/']),
      );
    },
  );

  test('closing cancels queued work and drops running responses', () async {
    final response = Completer<WebdavMetadata?>();
    var calls = 0;
    final value = index((_) {
      calls++;
      return response.future;
    });
    final refresh = value.refresh([
      for (var i = 0; i < 12; i++)
        WebdavEntry.comic(name: '$i', path: '/library/$i/'),
    ], directory: '/library/');
    await Future<void>.delayed(Duration.zero);
    value.close();
    response.complete(const WebdavMetadata(title: 'Too late'));
    expect(await refresh, 12);
    expect(calls, 4);
    expect(value.snapshot, isEmpty);
    expect(await File(cache).exists(), isFalse);
  });

  test('late metadata cannot resurrect a deleted directory entry', () async {
    final response = Completer<WebdavMetadata?>();
    final value = index((_) => response.future);
    final older = value.refresh([
      WebdavEntry.comic(name: 'Removed', path: '/library/removed/'),
    ], directory: '/library/');
    await Future<void>.delayed(Duration.zero);
    await value.refresh([], directory: '/library/');
    response.complete(const WebdavMetadata(title: 'Removed'));
    await older;
    expect(value.snapshot, isEmpty);
    final saved = jsonDecode(await File(cache).readAsString()) as Map;
    expect(saved['records'], isEmpty);
  });

  test(
    'configuration change drops old responses and prevents persistence',
    () async {
      var current = true;
      final response = Completer<WebdavMetadata?>();
      final value = index((_) => response.future, current: () => current);
      final pending = value.metadata('/a/');
      final expectation = expectLater(pending, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      current = false;
      response.complete(const WebdavMetadata(title: 'Stale'));
      await expectation;
      expect(value.snapshot, isEmpty);
      expect(await File(cache).exists(), isFalse);
    },
  );

  test(
    'last owner closes the index while another owner keeps it usable',
    () async {
      final value = index((_) async => null)
        ..retain()
        ..retain();
      value.release();
      await value.metadata('/a/');
      value.release();
      await expectLater(value.metadata('/a/'), throwsStateError);
    },
  );

  test('corrupt cache and future timestamps are rebuilt', () async {
    await File(cache).writeAsString('{');
    final first = index((_) async => const WebdavMetadata(title: 'Recovered'));
    expect((await first.metadata('/a/'))!.title, 'Recovered');
    first.close();
    final json = jsonDecode(await File(cache).readAsString()) as Map;
    json['records']['/a/']['time'] = now
        .add(const Duration(days: 30))
        .millisecondsSinceEpoch;
    await File(cache).writeAsString(jsonEncode(json));
    final second = index((_) async => const WebdavMetadata(title: 'Current'));
    expect((await second.metadata('/a/'))!.title, 'Current');
  });
}
