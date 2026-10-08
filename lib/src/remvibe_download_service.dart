library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'package:remvibe_dart_models/remvibe_dart_models.dart';

part 'remvibe_download_handler.dart';
part 'remvibe_download_item.dart';
part 'remvibe_download_job.dart';
part 'remvibe_download_response.dart';
part 'remvibe_download_status.dart';

/// Application-wide authority for download jobs.
class RemVibeDownloadService {
  RemVibeDownloadService._();

  static final RemVibeDownloadService _instance = RemVibeDownloadService._();

  factory RemVibeDownloadService() => _instance;

  final Dio _dio = Dio();
  final List<RemVibeDownloadJob> _jobs = <RemVibeDownloadJob>[];
  final List<RemVibeDownloadHandler> _handlers = <RemVibeDownloadHandler>[];
  final Map<RemVibeDownloadItem, CancelToken> _cancelTokens =
      <RemVibeDownloadItem, CancelToken>{};
  final Map<RemVibeDownloadItem, Future<void>> _downloadFutures =
      <RemVibeDownloadItem, Future<void>>{};

  bool _active = false;
  int _downloadNowSequence = 0;
  RemVibeClearPolicy clearPolicy = RemVibeClearPolicy.beforeNextAdd;
  RemVibeDownloadJob? _activeJob;

  bool get active => _active;

  List<RemVibeDownloadJob> get jobs =>
      List<RemVibeDownloadJob>.unmodifiable(_jobs);

  RemVibeDownloadJob? get activeJob => _activeJob;

  int get downloadedSize => _jobs.fold<int>(
        0,
        (int total, RemVibeDownloadJob job) => total + job.downloadedSize,
      );

  int? get totalSize {
    var total = 0;
    for (final RemVibeDownloadJob job in _jobs) {
      final int? jobSize = job.totalSize;
      if (jobSize == null) {
        return null;
      }
      total += jobSize;
    }
    return total;
  }

  int? get percent {
    final int? total = totalSize;
    if (total == null) {
      return null;
    }
    if (total == 0) {
      return _jobs.isEmpty ? 100 : 0;
    }
    return ((downloadedSize / total) * 100).clamp(0, 100).floor();
  }

  Future<RemVibeDownloadResponse> downloadNow({
    required Uri url,
    required Directory folder,
    String? filename,
    int? size,
    RemVibeDownloadItemValidator? validator,
    int maxErrorCount = 3,
  }) async {
    final RemVibeDownloadItem item = RemVibeDownloadItem(
      url: url,
      directory: folder,
      filename: filename,
      size: size,
      validator: validator,
    );
    final Completer<RemVibeDownloadResponse> response = Completer<RemVibeDownloadResponse>();

    late final RemVibeDownloadJob job;
    job = RemVibeDownloadJob(
      key: _nextDownloadNowKey(),
      title: filename ?? url.toString(),
      items: <RemVibeDownloadItem>[item],
      maxConcurrentItems: 1,
      maxErrorCount: maxErrorCount,
      onStatus: (RemVibeDownloadJob job) {
        if (response.isCompleted) {
          return;
        }

        if (job.status == RemVibeDownloadStatus.completed ||
            job.status == RemVibeDownloadStatus.cancelled ||
            job.status == RemVibeDownloadStatus.error) {
          response.complete(_createDownloadResponse(item, job.status));
        }
      },
    );

    if (!_active) {
      await start();
    }

    addJob(job);
    return response.future;
  }

  Future<void> start() async {
    if (_active) {
      return;
    }
    _active = true;
    _pump();
  }

  Future<void> stop() async {
    if (!_active && _activeJob == null) {
      return;
    }
    _active = false;

    final RemVibeDownloadJob? job = _activeJob;
    final List<Future<void>> activeFutures = job == null
        ? <Future<void>>[]
        : job.activeItems
            .map((RemVibeDownloadItem item) => _downloadFutures[item])
            .whereType<Future<void>>()
            .toList(growable: false);

    if (job != null) {
      for (final RemVibeDownloadItem item in job.activeItems) {
        _cancelTokens[item]?.cancel('Download service stopped.');
      }
    }

    await Future.wait(activeFutures);

    if (job != null && job.status == RemVibeDownloadStatus.downloading) {
      job._setStatus(RemVibeDownloadStatus.idle);
      _notifyJob(job, RemVibeListEventType.update);
    }
    _activeJob = null;
  }

  RemVibeDownloadJob addJob(RemVibeDownloadJob job) {
    _applyClearPolicyBeforeAdd();

    RemVibeDownloadJob? existing;
    for (final RemVibeDownloadJob candidate in _jobs) {
      if (candidate.key == job.key) {
        existing = candidate;
        break;
      }
    }

    if (existing != null) {
      if (clearPolicy == RemVibeClearPolicy.manual && _isTerminal(existing.status)) {
        _removeJob(existing);
      } else {
        existing._addItems(job.items);
        _notifyJob(existing, RemVibeListEventType.update);
        if (_active && identical(_activeJob, existing)) {
          _pump();
        }
        return existing;
      }
    }

    _jobs.add(job);
    _notifyJob(job, RemVibeListEventType.add);
    if (_active) {
      _pump();
    }
    return job;
  }

  void clearCompletedItems() {
    _clearCompletedItems();
  }

  Future<void> cancelJob(RemVibeDownloadJob job) async {
    if (!_jobs.contains(job)) {
      return;
    }

    job._setStatus(RemVibeDownloadStatus.cancelled);
    for (final RemVibeDownloadItem item in job.items) {
      if (item.status != RemVibeDownloadStatus.completed) {
        item._setStatus(RemVibeDownloadStatus.cancelled);
      }
    }
    _notifyJob(job, RemVibeListEventType.update);

    final List<Future<void>> activeFutures = job.activeItems
        .map((RemVibeDownloadItem item) => _downloadFutures[item])
        .whereType<Future<void>>()
        .toList(growable: false);

    for (final RemVibeDownloadItem item in job.activeItems) {
      _cancelTokens[item]?.cancel('Download job cancelled.');
    }
    await Future.wait(activeFutures);

    _removeJob(job);
    if (_active) {
      _pump();
    }
  }

  String _nextDownloadNowKey() {
    String key;
    do {
      _downloadNowSequence++;
      key = '__remvibe_download_now_$_downloadNowSequence';
    } while (_jobs.any((RemVibeDownloadJob job) => job.key == key));
    return key;
  }

  RemVibeDownloadResponse _createDownloadResponse(RemVibeDownloadItem item, RemVibeDownloadStatus status) {
    return RemVibeDownloadResponse._(
      status: status,
      url: item.url,
      folder: item.directory,
      filename: item.filename,
      errorMessage: item.errorMessage,
      downloadedSize: item.downloadedSize,
      totalSize: item.size,
      errorCount: item.errorCount,
    );
  }

  void _applyClearPolicyBeforeAdd() {
    if (clearPolicy == RemVibeClearPolicy.beforeNextAdd && _allJobsCompleted) {
      _clearCompletedItems();
    }
  }

  bool get _allJobsCompleted => _jobs.isNotEmpty && _jobs.every((RemVibeDownloadJob job) => job.status == RemVibeDownloadStatus.completed);

  bool _isTerminal(RemVibeDownloadStatus status) {
    return status == RemVibeDownloadStatus.completed || status == RemVibeDownloadStatus.cancelled || status == RemVibeDownloadStatus.error;
  }

  void _clearCompletedItems() {
    final List<RemVibeDownloadJob> completed = _jobs.where((RemVibeDownloadJob job) => job.status == RemVibeDownloadStatus.completed).toList(growable: false);
    for (final RemVibeDownloadJob job in completed) {
      _removeJob(job);
    }
  }

  void _removeJob(RemVibeDownloadJob job) {
    if (!_jobs.remove(job)) {
      return;
    }

    if (identical(_activeJob, job)) {
      _activeJob = null;
    }
    _notifyJob(job, RemVibeListEventType.remove);
  }

  void _registerHandler(RemVibeDownloadHandler handler) {
    if (!_handlers.contains(handler)) {
      _handlers.add(handler);
    }
  }

  void _unregisterHandler(RemVibeDownloadHandler handler) {
    _handlers.remove(handler);
  }

  void _notifyJob(RemVibeDownloadJob job, RemVibeListEventType event) {
    for (final RemVibeDownloadHandler handler
        in List<RemVibeDownloadHandler>.of(_handlers)) {
      handler._emit(job, event);
    }
  }

  void _pump() {
    if (!_active) {
      return;
    }

    RemVibeDownloadJob? job = _activeJob;
    if (job == null) {
      for (final RemVibeDownloadJob candidate in _jobs) {
        if (candidate.status == RemVibeDownloadStatus.idle) {
          job = candidate;
          break;
        }
      }
      if (job == null) {
        return;
      }
      _activeJob = job;
      job._setStatus(RemVibeDownloadStatus.downloading);
      _notifyJob(job, RemVibeListEventType.update);
    }

    final bool retryBatch = job.activeItems.isEmpty && !job._hasIdleItem;

    while (_active && job.activeItems.length < job.maxConcurrentItems) {
      final RemVibeDownloadItem? next = job._getNext();
      if (next == null) {
        break;
      }
      if (next.status == RemVibeDownloadStatus.error && !retryBatch) {
        break;
      }

      job._addActiveItem(next);
      next._setDownloadedSize(0);
      next._setErrorMessage(null);
      next._setStatus(RemVibeDownloadStatus.downloading);
      _notifyJob(job, RemVibeListEventType.update);

      final Future<void> future = _downloadItem(job, next);
      _downloadFutures[next] = future;
      unawaited(future);
    }

    if (job.activeItems.isNotEmpty || job._getNext() != null) {
      return;
    }

    if (job._allCompleted) {
      job._setStatus(RemVibeDownloadStatus.completed);
      _notifyJob(job, RemVibeListEventType.update);
      _activeJob = null;

      if (clearPolicy == RemVibeClearPolicy.immediate) {
        _removeJob(job);
      } else if (clearPolicy == RemVibeClearPolicy.whenAllCompleted && _allJobsCompleted) {
        _clearCompletedItems();
      }

      _pump();
      return;
    }

    job._setStatus(RemVibeDownloadStatus.error);
    _notifyJob(job, RemVibeListEventType.update);
    _activeJob = null;
    _pump();
  }

  Future<void> _downloadItem(
    RemVibeDownloadJob job,
    RemVibeDownloadItem item,
  ) async {
    final CancelToken cancelToken = CancelToken();
    _cancelTokens[item] = cancelToken;
    File? temporaryFile;
    IOSink? sink;

    try {
      final Response<ResponseBody> response = await _dio.getUri<ResponseBody>(
        item.url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancelToken,
      );
      final ResponseBody? body = response.data;
      if (body == null) {
        throw StateError('Download response body is empty.');
      }

      final String? contentLength =
          response.headers.value(Headers.contentLengthHeader);
      final int? responseSize = int.tryParse(contentLength ?? '');
      if (responseSize != null && responseSize >= 0) {
        item._setSize(responseSize);
      }

      if (item.filename == null) {
        final List<String>? dispositionValues =
            response.headers['content-disposition'];
        final String? disposition =
            dispositionValues == null || dispositionValues.isEmpty
                ? null
                : dispositionValues.first;
        final String? headerFilename = _contentDispositionFilename(disposition);
        if (headerFilename != null) {
          item._setFilename(headerFilename);
        }
      }
      if (item.filename == null) {
        final List<String> pathSegments = item.url.pathSegments
            .where((String segment) => segment.isNotEmpty)
            .toList(growable: false);
        if (pathSegments.isNotEmpty) {
          item._setFilename(pathSegments.last);
        }
      }

      final File? destination = item.file;
      if (destination == null) {
        throw StateError('Download filename could not be resolved.');
      }

      await item.directory.create(recursive: true);
      temporaryFile = File('${destination.path}.download');
      if (await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
      sink = temporaryFile.openWrite(mode: FileMode.writeOnly);

      var received = 0;
      await for (final List<int> chunk in body.stream) {
        sink.add(chunk);
        received += chunk.length;
        item._setDownloadedSize(received);
        _notifyJob(job, RemVibeListEventType.update);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      item._setSize(received);
      final RemVibeDownloadItemValidator? validator = item.validator;
      if (validator != null) {
        await validator(temporaryFile);
      }
      item._setErrorMessage(null);
      if (await destination.exists()) {
        await destination.delete();
      }
      await temporaryFile.rename(destination.path);
      temporaryFile = null;
      item._setStatus(RemVibeDownloadStatus.completed);
    } catch (error) {
      item._setErrorMessage(error.toString());
      await sink?.close();
      sink = null;
      if (temporaryFile != null && await temporaryFile.exists()) {
        await temporaryFile.delete();
      }

      item._setDownloadedSize(0);
      if (job.status == RemVibeDownloadStatus.cancelled) {
        item._setStatus(RemVibeDownloadStatus.cancelled);
      } else if (!_active) {
        item._setStatus(RemVibeDownloadStatus.idle);
      } else {
        item._incrementErrorCount();
        item._setStatus(RemVibeDownloadStatus.error);
      }
    } finally {
      _cancelTokens.remove(item);
      unawaited(_downloadFutures.remove(item));
      job._removeActiveItem(item);
      _notifyJob(job, RemVibeListEventType.update);
      if (_active && job.status == RemVibeDownloadStatus.downloading) {
        _pump();
      }
    }
  }

  String? _contentDispositionFilename(String? header) {
    if (header == null || header.isEmpty) {
      return null;
    }

    final RegExp filenameStar = RegExp(
      r'''filename\*\s*=\s*(?:UTF-8'')?([^;]+)''',
      caseSensitive: false,
    );
    final RegExpMatch? starMatch = filenameStar.firstMatch(header);
    if (starMatch != null) {
      final String encoded =
          starMatch.group(1)!.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), '');
      try {
        return Uri.decodeComponent(encoded);
      } on FormatException {
        return encoded;
      }
    }

    final RegExp filename = RegExp(
      r'''filename\s*=\s*(?:"([^"]+)"|([^;]+))''',
      caseSensitive: false,
    );
    final RegExpMatch? match = filename.firstMatch(header);
    return (match?.group(1) ?? match?.group(2))?.trim();
  }
}
