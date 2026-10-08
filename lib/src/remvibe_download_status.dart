part of 'remvibe_download_service.dart';

/// Lifecycle state shared by download jobs and download items.
enum RemVibeDownloadStatus {
  idle,
  downloading,
  completed,
  cancelled,
  error,
}
