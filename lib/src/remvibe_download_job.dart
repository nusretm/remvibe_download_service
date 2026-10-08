part of 'remvibe_download_service.dart';

typedef RemVibeDownloadJobStatusCallback = void Function(
  RemVibeDownloadJob job,
);

/// A logical download operation containing one or more download items.
class RemVibeDownloadJob {
  RemVibeDownloadJob({
    required this.key,
    required this.title,
    required List<RemVibeDownloadItem> items,
    this.onStatus,
    int maxConcurrentItems = 5,
    int maxErrorCount = 3,
  })  : _maxConcurrentItems = maxConcurrentItems,
        _maxErrorCount = maxErrorCount {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'Must not be empty.');
    }
    if (maxConcurrentItems < 1) {
      throw ArgumentError.value(
        maxConcurrentItems,
        'maxConcurrentItems',
        'Must be at least 1.',
      );
    }
    if (maxErrorCount < 1) {
      throw ArgumentError.value(
        maxErrorCount,
        'maxErrorCount',
        'Must be at least 1.',
      );
    }
    _addItems(items);
  }

  final String key;
  final String title;
  final RemVibeDownloadJobStatusCallback? onStatus;

  final List<RemVibeDownloadItem> _items = <RemVibeDownloadItem>[];
  final List<RemVibeDownloadItem> _activeItems = <RemVibeDownloadItem>[];

  int _maxConcurrentItems;
  int _maxErrorCount;
  RemVibeDownloadStatus _status = RemVibeDownloadStatus.idle;

  int get maxConcurrentItems => _maxConcurrentItems;

  set maxConcurrentItems(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'value', 'Must be at least 1.');
    }
    _maxConcurrentItems = value;
  }

  int get maxErrorCount => _maxErrorCount;

  set maxErrorCount(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'value', 'Must be at least 1.');
    }
    _maxErrorCount = value;
  }

  List<RemVibeDownloadItem> get items =>
      List<RemVibeDownloadItem>.unmodifiable(_items);

  List<RemVibeDownloadItem> get activeItems =>
      List<RemVibeDownloadItem>.unmodifiable(_activeItems);

  RemVibeDownloadStatus get status => _status;

  int get downloadedSize => _items.fold<int>(
        0,
        (int total, RemVibeDownloadItem item) => total + item.downloadedSize,
      );

  int? get totalSize {
    var total = 0;
    for (final RemVibeDownloadItem item in _items) {
      final int? itemSize = item.size;
      if (itemSize == null) {
        return null;
      }
      total += itemSize;
    }
    return total;
  }

  int? get percent {
    final int? total = totalSize;
    if (total == null) {
      return null;
    }
    if (total == 0) {
      return _items.isNotEmpty &&
              _items.every(
                (RemVibeDownloadItem item) =>
                    item.status == RemVibeDownloadStatus.completed,
              )
          ? 100
          : 0;
    }
    return ((downloadedSize / total) * 100).clamp(0, 100).floor();
  }

  bool get _hasIdleItem => _items.any(
        (RemVibeDownloadItem item) => item.status == RemVibeDownloadStatus.idle,
      );

  bool get _allCompleted =>
      _items.isNotEmpty &&
      _items.every(
        (RemVibeDownloadItem item) =>
            item.status == RemVibeDownloadStatus.completed,
      );

  RemVibeDownloadItem? _getNext() {
    for (final RemVibeDownloadItem item in _items) {
      if (item.status == RemVibeDownloadStatus.idle) {
        return item;
      }
    }
    for (final RemVibeDownloadItem item in _items) {
      if (item.status == RemVibeDownloadStatus.error &&
          item.errorCount < maxErrorCount) {
        return item;
      }
    }
    return null;
  }

  int _addItems(Iterable<RemVibeDownloadItem> items) {
    final List<RemVibeDownloadItem> incoming = items.toList(growable: false);
    final List<RemVibeDownloadItem> known =
        List<RemVibeDownloadItem>.of(_items);
    for (final RemVibeDownloadItem item in incoming) {
      RemVibeDownloadItem? existing;
      for (final RemVibeDownloadItem candidate in known) {
        if (candidate._identityKey == item._identityKey) {
          existing = candidate;
          break;
        }
      }
      if (existing == null) {
        known.add(item);
      } else if (!identical(existing.validator, item.validator)) {
        throw StateError(
          'Duplicate download item "${item.url}" has an incompatible validator contract.',
        );
      }
    }

    var added = 0;
    for (final RemVibeDownloadItem item in incoming) {
      RemVibeDownloadItem? existing;
      for (final RemVibeDownloadItem candidate in _items) {
        if (candidate._identityKey == item._identityKey) {
          existing = candidate;
          break;
        }
      }
      if (existing == null) {
        _items.add(item);
        added++;
      } else if (item.size != null && existing.size != item.size) {
        existing._setSize(item.size);
      }
    }
    return added;
  }

  void _addActiveItem(RemVibeDownloadItem item) {
    if (!_activeItems.contains(item)) {
      _activeItems.add(item);
    }
  }

  void _removeActiveItem(RemVibeDownloadItem item) {
    _activeItems.remove(item);
  }

  void _setStatus(RemVibeDownloadStatus value) {
    if (_status == value) {
      return;
    }
    _status = value;
    final RemVibeDownloadJobStatusCallback? callback = onStatus;
    if (callback == null) {
      return;
    }
    try {
      callback(this);
    } catch (error, stackTrace) {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }
}
