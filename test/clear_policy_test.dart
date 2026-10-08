import 'dart:async';
import 'dart:io';

import 'package:remvibe_download_service/remvibe_download_service.dart';
import 'package:test/test.dart';

void main() {
  final RemVibeDownloadService service = RemVibeDownloadService();

  setUp(() async {
    service.clearPolicy = RemVibeClearPolicy.immediate;
    await service.stop();
    service.clearCompletedItems();
    for (final RemVibeDownloadJob job
        in List<RemVibeDownloadJob>.of(service.jobs)) {
      await service.cancelJob(job);
    }
  });

  test('beforeNextAdd retains a completed job until the next batch starts',
      () async {
    service.clearPolicy = RemVibeClearPolicy.beforeNextAdd;
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      request.response.add(<int>[1, 2, 3]);
      await request.response.close();
    });
    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() => directory.delete(recursive: true));

    final Completer<void> firstCompleted = Completer<void>();
    final RemVibeDownloadJob first = RemVibeDownloadJob(
      key: 'clear-first',
      title: 'First',
      items: <RemVibeDownloadItem>[
        RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:${server.port}/first.bin'),
          directory: directory,
          filename: 'first.bin',
        ),
      ],
      onStatus: (RemVibeDownloadJob job) {
        if (job.status == RemVibeDownloadStatus.completed &&
            !firstCompleted.isCompleted) {
          firstCompleted.complete();
        }
      },
    );

    await service.start();
    service.addJob(first);
    await firstCompleted.future.timeout(const Duration(seconds: 5));
    expect(service.jobs, contains(first));

    final Completer<void> secondCompleted = Completer<void>();
    final RemVibeDownloadJob second = RemVibeDownloadJob(
      key: 'clear-second',
      title: 'Second',
      items: <RemVibeDownloadItem>[
        RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:${server.port}/second.bin'),
          directory: directory,
          filename: 'second.bin',
        ),
      ],
      onStatus: (RemVibeDownloadJob job) {
        if (job.status == RemVibeDownloadStatus.completed &&
            !secondCompleted.isCompleted) {
          secondCompleted.complete();
        }
      },
    );

    service.addJob(second);
    expect(service.jobs, isNot(contains(first)));
    await secondCompleted.future.timeout(const Duration(seconds: 5));
    expect(service.jobs, contains(second));
  });

  test('manual replaces a terminal job with the same key', () async {
    service.clearPolicy = RemVibeClearPolicy.manual;
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      request.response.add(<int>[4, 5, 6]);
      await request.response.close();
    });
    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() => directory.delete(recursive: true));

    final Completer<void> firstCompleted = Completer<void>();
    final RemVibeDownloadJob first = RemVibeDownloadJob(
      key: 'manual-replace',
      title: 'Old',
      items: <RemVibeDownloadItem>[
        RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:${server.port}/old.bin'),
          directory: directory,
          filename: 'old.bin',
        ),
      ],
      onStatus: (RemVibeDownloadJob job) {
        if (job.status == RemVibeDownloadStatus.completed &&
            !firstCompleted.isCompleted) {
          firstCompleted.complete();
        }
      },
    );

    await service.start();
    service.addJob(first);
    await firstCompleted.future.timeout(const Duration(seconds: 5));

    final Completer<void> replacementCompleted = Completer<void>();
    final RemVibeDownloadJob replacement = RemVibeDownloadJob(
      key: 'manual-replace',
      title: 'New',
      items: <RemVibeDownloadItem>[
        RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:${server.port}/new.bin'),
          directory: directory,
          filename: 'new.bin',
        ),
      ],
      onStatus: (RemVibeDownloadJob job) {
        if (job.status == RemVibeDownloadStatus.completed &&
            !replacementCompleted.isCompleted) {
          replacementCompleted.complete();
        }
      },
    );

    expect(service.addJob(replacement), same(replacement));
    await replacementCompleted.future.timeout(const Duration(seconds: 5));
    expect(service.jobs, contains(replacement));
    expect(service.jobs, isNot(contains(first)));
  });
}
