import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_library_index.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/utils/io.dart';

/// Resolves configuration/lifetime separately from the transport-free index.
abstract class WebdavLibraryIndexes {
  static final _shared =
      <String, ({String signature, WebdavLibraryIndex index})>{};

  static String _identity(WebdavLibraryConfig config) =>
      jsonEncode([config.id, config.url, config.user, config.rootPath]);

  static String _signature(WebdavLibraryConfig config) => sha256
      .convert(utf8.encode('${_identity(config)}\n${config.pass}'))
      .toString();

  static WebdavLibraryIndex acquire(
    WebdavLibraryConfig config, {
    required WebdavMetadataReader reader,
  }) {
    final signature = _signature(config);
    var record = _shared[config.id];
    if (record == null || record.signature != signature) {
      record?.index.close();
      final hash = sha256.convert(utf8.encode(_identity(config)));
      late final WebdavLibraryIndex index;
      index = WebdavLibraryIndex(
        cacheFile: FilePath.join(
          App.cachePath,
          'webdav_metadata',
          '$hash.json',
        ),
        reader: reader,
        isCurrent: () {
          final current = WebdavLibraryStore.find(config.id);
          return current != null && _signature(current) == signature;
        },
        onClosed: () {
          if (identical(_shared[config.id]?.index, index)) {
            _shared.remove(config.id);
          }
        },
        onCacheError: (error) =>
            Log.warning('WebdavLibraryIndex', 'Cache write failed: $error'),
      );
      record = (signature: signature, index: index);
      _shared[config.id] = record;
    }
    record.index.retain();
    return record.index;
  }
}
