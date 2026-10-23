import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/webdav_metadata.dart';
import 'package:venera/foundation/webdav_library_models.dart';

typedef WebdavMetadataReader = Future<WebdavMetadata?> Function(String path);

/// A ref-counted, device-local index. Only successful reads (including 404s)
/// advance timestamps. Neither this cache nor its filenames contain credentials.
class WebdavLibraryIndex {
  static const ttl = Duration(days: 7);
  static const concurrency = 4;
  WebdavLibraryIndex({
    required this.cacheFile,
    required WebdavMetadataReader reader,
    DateTime Function()? clock,
    bool Function()? isCurrent,
    this.onClosed,
    this.onCacheError,
  }) : _reader = reader,
       _clock = clock ?? DateTime.now,
       _isCurrent = isCurrent ?? (() => true) {
    ready = _restore();
  }

  final String cacheFile;
  final WebdavMetadataReader _reader;
  final DateTime Function() _clock;
  final bool Function() _isCurrent;
  late final Future<void> ready;
  final _records = <String, _MetadataRecord>{};
  final _listedPaths = <String, Set<String>>{};
  final _pending = Queue<_MetadataRequest>();
  final _inFlight = <String, Future<WebdavMetadata?>>{};
  Future<void> _writes = Future.value();
  final void Function()? onClosed;
  final void Function(Object error)? onCacheError;
  int _owners = 0;
  int _running = 0;
  bool _active = true;
  static int _nextTemporaryId = 0;
  final int _temporaryId = _nextTemporaryId++;
  bool get _valid => _active && _isCurrent();

  Map<String, WebdavMetadata?> get snapshot => Map.unmodifiable({
    for (final e in _records.entries) e.key: e.value.metadata,
  });

  void retain() => _owners++;

  void release() {
    if (_owners > 0) _owners--;
    if (_owners != 0) return;
    close();
  }

  void close() {
    if (!_active) return;
    _active = false;
    onClosed?.call();
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completion.completeError(
        StateError('Index closed'),
      );
    }
  }

  Future<void> _restore() async {
    try {
      final file = File(cacheFile);
      if (!await file.exists()) return;
      final json = jsonDecode(utf8.decode(await file.readAsBytes())) as Map;
      if (json['version'] != 1 || !_valid) return;
      for (final e in (json['records'] as Map).entries) {
        try {
          final path = e.key as String;
          if (!path.startsWith('/') || !path.endsWith('/')) continue;
          final record = e.value as Map;
          final time = DateTime.fromMillisecondsSinceEpoch(
            record['time'] as int,
          );
          // Future timestamps should not make a bad cache live indefinitely.
          if (time.isAfter(_clock())) continue;
          _records[path] = _MetadataRecord(
            record['metadata'] == null
                ? null
                : WebdavMetadata.fromJson(
                    Map<String, dynamic>.from(record['metadata'] as Map),
                  ),
            time,
          );
        } catch (_) {
          // A malformed record must not discard otherwise usable metadata.
        }
      }
    } catch (_) {
      // A deleted/corrupt cache is rebuilt from the remote library.
    }
  }

  Future<WebdavMetadata?> metadata(
    String path, {
    bool force = false,
    bool persist = true,
    bool priority = true,
  }) async {
    await ready;
    if (!_valid) throw StateError('Index closed');
    path = ensureWebdavDirectory(path);
    final pending = _inFlight[path];
    if (pending != null) {
      // A visible cover/detail must not wait behind an entire library scan.
      if (priority) {
        for (final request in _pending.toList()) {
          if (request.path == path) {
            _pending.remove(request);
            _pending.addFirst(request);
            break;
          }
        }
      }
      return pending;
    }
    final cached = _records[path];
    if (!force && cached != null && _clock().difference(cached.time) < ttl) {
      return cached.metadata;
    }
    final request = _MetadataRequest(path, persist);
    _inFlight[path] = request.completion.future;
    if (priority) {
      _pending.addFirst(request);
    } else {
      _pending.add(request);
    }
    _pump();
    return request.completion.future;
  }

  void _pump() {
    while (_valid && _running < concurrency && _pending.isNotEmpty) {
      _running++;
      unawaited(_fetch(_pending.removeFirst()));
    }
    if (!_valid && _pending.isNotEmpty) close();
  }

  Future<void> _fetch(_MetadataRequest request) async {
    try {
      final value = await _reader(request.path);
      if (!_valid) throw StateError('Index closed');
      final listed = _listedPaths[_parentOf(request.path)];
      // A later directory refresh may have deleted this comic while its GET
      // was running. Such a response must not resurrect a removed cache row.
      if (listed == null || listed.contains(request.path)) {
        _records[request.path] = _MetadataRecord(value, _clock());
      }
      if (request.persist) await _persist();
      if (!_valid) throw StateError('Index closed');
      request.completion.complete(value);
    } catch (e, stack) {
      request.completion.completeError(e, stack);
    } finally {
      _inFlight.remove(request.path);
      _running--;
      _pump();
    }
  }

  static String _parentOf(String path) {
    final withoutSlash = path.substring(0, path.length - 1);
    return withoutSlash.substring(0, withoutSlash.lastIndexOf('/') + 1);
  }

  /// Called only after a successful directory listing. Intermediate metadata
  /// stays private until the UI publishes the final snapshot, preventing jumps.
  Future<int> refresh(
    List<WebdavEntry> entries, {
    required String directory,
    bool force = false,
    void Function(int done, int total)? onProgress,
  }) async {
    await ready;
    if (!_valid) return 0;
    final paths = entries
        .where((e) => !e.isArchiveFile)
        .map((e) => ensureWebdavDirectory(e.path))
        .toSet();
    final dir = ensureWebdavDirectory(directory);
    _listedPaths[dir] = paths;
    _records.removeWhere((path, _) {
      return _parentOf(path) == dir && !paths.contains(path);
    });
    var done = 0, failures = 0;
    onProgress?.call(done, paths.length);
    await Future.wait(
      paths.map((path) async {
        try {
          await metadata(path, force: force, persist: false, priority: false);
        } catch (_) {
          failures++;
        }
        if (_valid) onProgress?.call(++done, paths.length);
      }),
    );
    if (_valid) await _persist();
    return failures;
  }

  Future<void> _persist() {
    _writes = _writes.then((_) async {
      if (!_valid) return;
      final temporary = File('$cacheFile.$_temporaryId.tmp');
      try {
        final file = File(cacheFile);
        await file.parent.create(recursive: true);
        await temporary.writeAsString(
          jsonEncode({
            'version': 1,
            'records': {
              for (final e in _records.entries)
                e.key: {
                  'time': e.value.time.millisecondsSinceEpoch,
                  'metadata': e.value.metadata?.toJson(),
                },
            },
          }),
          flush: true,
        );
        if (_valid) {
          await temporary.rename(cacheFile);
        } else {
          if (await temporary.exists()) await temporary.delete();
        }
      } catch (e) {
        onCacheError?.call(e);
      } finally {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {
          // Cache cleanup cannot affect browsing or reading.
        }
      }
    });
    return _writes;
  }
}

class _MetadataRecord {
  const _MetadataRecord(this.metadata, this.time);
  final WebdavMetadata? metadata;
  final DateTime time;
}

class _MetadataRequest {
  _MetadataRequest(this.path, this.persist);
  final String path;
  final bool persist;
  final completion = Completer<WebdavMetadata?>();
}
