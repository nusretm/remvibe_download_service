# remvibe_download_service

Reusable Dart download queue and lifecycle service used by RemVibe projects.

## Features

- Application-wide singleton download authority.
- Job and item lifecycle with add/update/remove observation.
- Configurable per-job concurrency and retry count.
- Optional per-item validation before publication.
- `downloadNow(...)` convenience API using the same queue lifecycle.
- Shared `RemVibeClearPolicy` and `RemVibeListEventType` contracts from `remvibe_dart_models`.

## Usage

```dart
import 'dart:io';

import 'package:remvibe_download_service/remvibe_download_service.dart';

final RemVibeDownloadService service = RemVibeDownloadService();
await service.start();

final RemVibeDownloadResponse response = await service.downloadNow(
  url: Uri.parse('https://example.test/file.bin'),
  folder: Directory.systemTemp,
  filename: 'file.bin',
);
```
