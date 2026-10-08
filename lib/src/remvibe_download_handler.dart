part of 'remvibe_download_service.dart';

typedef RemVibeDownloadJobCallback = void Function(
  RemVibeDownloadJob job,
  RemVibeListEventType event,
);

/// Observes the download job list without being required to own a job.
class RemVibeDownloadHandler {
  RemVibeDownloadHandler({required this.onJob}) {
    RemVibeDownloadService()._registerHandler(this);
  }

  final RemVibeDownloadJobCallback onJob;

  bool _active = false;
  bool _disposed = false;

  bool get active => _active;

  void start() {
    if (_disposed) {
      throw StateError('A disposed RemVibeDownloadHandler cannot be started.');
    }
    if (_active) {
      return;
    }
    _active = true;
    final List<RemVibeDownloadJob> jobs = RemVibeDownloadService().jobs;
    for (final RemVibeDownloadJob job in jobs) {
      _emit(job, RemVibeListEventType.add);
    }
  }

  void stop() {
    if (_disposed) {
      return;
    }
    _active = false;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _active = false;
    _disposed = true;
    RemVibeDownloadService()._unregisterHandler(this);
  }

  void _emit(RemVibeDownloadJob job, RemVibeListEventType event) {
    if (!_active || _disposed) {
      return;
    }
    try {
      onJob(job, event);
    } catch (error, stackTrace) {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }
}
