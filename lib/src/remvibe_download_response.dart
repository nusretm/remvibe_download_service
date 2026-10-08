part of 'remvibe_download_service.dart';

class RemVibeDownloadResponse {
  const RemVibeDownloadResponse._({
    required this.status,
    required this.url,
    required this.folder,
    required this.filename,
    required this.errorMessage,
    required this.downloadedSize,
    required this.totalSize,
    required this.errorCount,
  });

  final RemVibeDownloadStatus status;
  final Uri url;
  final Directory folder;
  final String? filename;
  final String? errorMessage;
  final int downloadedSize;
  final int? totalSize;
  final int errorCount;

  bool get success => status == RemVibeDownloadStatus.completed;

  bool get error => status == RemVibeDownloadStatus.error;

  bool get cancelled => status == RemVibeDownloadStatus.cancelled;

  File? get file {
    final String? value = filename;
    return value == null ? null : File(p.join(folder.path, value));
  }
}
