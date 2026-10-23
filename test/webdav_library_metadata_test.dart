import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  test(
    'metadata indexing uses one GET with no chapter or OPTIONS requests',
    () async {
      final adapter = _MetadataAdapter();
      final metadata = await _client(adapter).readMetadata('/library/Comic/');
      expect(metadata!.title, 'Metadata title');
      expect(metadata.authors, ['A', 'B']);
      expect(metadata.tags, ['tag']);
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.uri.path, '/library/Comic/metadata.json');
    },
  );

  test('only HTTP 404 is treated as absent metadata', () async {
    expect(
      await _client(
        _MetadataAdapter(status: 404),
      ).readMetadata('/library/Comic/'),
      isNull,
    );
    for (final status in [403, 500, 503]) {
      await expectLater(
        _client(
          _MetadataAdapter(status: status),
        ).readMetadata('/library/Comic/'),
        throwsStateError,
      );
    }
  });

  test('invalid JSON and timeouts propagate to the index for retry', () async {
    await expectLater(
      _client(_MetadataAdapter(body: '{')).readMetadata('/library/Comic/'),
      throwsFormatException,
    );
    await expectLater(
      _client(_MetadataAdapter(timeout: true)).readMetadata('/library/Comic/'),
      throwsA(isA<DioException>()),
    );
  });

  test(
    'details use metadata but preserve actual directory-based chapters',
    () async {
      final adapter = _MetadataAdapter();
      final id = WebdavLibrary.encodeId('/library/Comic/');
      final result = await _client(adapter).loadComicInfo(id);
      expect(result.error, isFalse);
      expect(result.data.title, 'Metadata title');
      expect(result.data.findAuthor(), 'A, B');
      expect(result.data.tags['Tags'], ['tag']);
      expect(result.data.description, 'Description');
      expect(result.data.chapters!.ids, ['/library/Comic/']);
      expect(result.data.cover, endsWith('/library/Comic/1.jpg'));
      expect(result.data.comicId, id);
    },
  );

  test('missing or corrupt metadata never prevents reading a comic', () async {
    for (final adapter in [
      _MetadataAdapter(status: 404),
      _MetadataAdapter(body: '{'),
    ]) {
      final result = await _client(
        adapter,
      ).loadComicInfo(WebdavLibrary.encodeId('/library/Comic/'));
      expect(result.error, isFalse);
      expect(result.data.title, 'Comic');
      expect(result.data.tags, isEmpty);
      expect(result.data.chapters!.ids, ['/library/Comic/']);
    }
  });

  test('directory listings carry remote modification times', () async {
    final result = await _client(_MetadataAdapter()).listEntries();
    expect(result.error, isFalse);
    expect(result.data.single.modified, DateTime.utc(2026, 10, 1));
  });
}

WebdavLibraryClient _client(_MetadataAdapter adapter) {
  final config = WebdavLibraryConfig(
    id: 'metadata-test',
    sourceKey: 'webdav_library_metadata_test',
    name: 'Metadata test',
    url: 'https://example.test',
    user: '',
    pass: '',
    root: '/library/',
  );
  return WebdavLibraryClient(
    config,
    clientFactory: (_) => webdav.newClient(config.url, adapter: adapter),
  );
}

class _MetadataAdapter implements HttpClientAdapter {
  _MetadataAdapter({this.status = 200, String? body, this.timeout = false})
    : body =
          body ??
          jsonEncode({
            'title': 'Metadata title', 'author': 'A, B', 'tags': ['tag'],
            'description': 'Description',
            // This incompatible range must never replace the real chapter directory.
            'chapters': [
              {'title': 'Wrong chapter', 'start': 1, 'end': 200},
            ],
          });

  final int status;
  final String body;
  final bool timeout;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.method == 'GET') {
      if (timeout)
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      return ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );
    }
    final path = options.uri.path;
    final children = path == '/library/'
        ? '<d:response><d:href>/library/Comic/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getlastmodified>Thu, 01 Oct 2026 00:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
        : '<d:response><d:href>/library/Comic/1.jpg</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
    return ResponseBody.fromString(
      '''
<d:multistatus xmlns:d="DAV:">
<d:response><d:href>$path</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
$children
</d:multistatus>''',
      207,
      headers: {
        Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
