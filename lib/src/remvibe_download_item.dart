part of 'remvibe_download_service.dart';

typedef RemVibeDownloadItemValidator = FutureOr<void> Function(File file);

/// One downloadable file owned by a [RemVibeDownloadJob].
class RemVibeDownloadItem {
  RemVibeDownloadItem({
    required this.url,
    required this.directory,
    String? filename,
    int? size,
    this.validator,
  })  : _requestedFilename = _validateRequestedFilename(filename),
        _filename = _validateRequestedFilename(filename),
        _size = _validateSize(size);

  final Uri url;
  final Directory directory;
  final RemVibeDownloadItemValidator? validator;

  final String? _requestedFilename;
  String? _filename;
  int? _size;
  int _downloadedSize = 0;
  int _errorCount = 0;
  String? _errorMessage;
  RemVibeDownloadStatus _status = RemVibeDownloadStatus.idle;

  String? get filename => _filename;

  File? get file {
    final String? value = _filename;
    return value == null ? null : File(p.join(directory.path, value));
  }

  int? get size => _size;
  int get downloadedSize => _downloadedSize;
  int get errorCount => _errorCount;
  String? get errorMessage => _errorMessage;
  RemVibeDownloadStatus get status => _status;

  String get _identityKey => <String>[
        url.toString(),
        p.normalize(p.absolute(directory.path)),
        _requestedFilename ?? '',
      ].join('\u0000');

  void _setFilename(String value) {
    if (_requestedFilename != null) {
      return;
    }
    final String normalized = value.trim().replaceAll('\\', '/');
    final String safeFilename = p.posix.basename(normalized);
    if (safeFilename.isEmpty || safeFilename == '.' || safeFilename == '..') {
      throw ArgumentError.value(value, 'value', 'Invalid download filename.');
    }
    _filename = safeFilename;
  }

  void _setSize(int? value) {
    _size = _validateSize(value);
  }

  void _setDownloadedSize(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Must not be negative.');
    }
    _downloadedSize = value;
  }

  void _setStatus(RemVibeDownloadStatus value) {
    _status = value;
  }

  void _incrementErrorCount() {
    _errorCount++;
  }

  void _setErrorMessage(String? value) {
    _errorMessage = value;
  }

  static String? _validateRequestedFilename(String? value) {
    if (value == null) {
      return null;
    }
    final String filename = value.trim();
    if (filename.isEmpty ||
        filename == '.' ||
        filename == '..' ||
        filename.contains('/') ||
        filename.contains('\\')) {
      throw ArgumentError.value(value, 'filename', 'Must be a plain filename.');
    }
    return filename;
  }

  static int? _validateSize(int? value) {
    if (value != null && value < 0) {
      throw ArgumentError.value(value, 'size', 'Must not be negative.');
    }
    return value;
  }
}
