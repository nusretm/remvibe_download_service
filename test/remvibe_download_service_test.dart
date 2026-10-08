import 'dart:async';
import 'dart:io';

import 'package:remvibe_download_service/remvibe_download_service.dart';
import 'package:test/test.dart';

void main() {
  final RemVibeDownloadService service = RemVibeDownloadService();

  setUp(() async {
    service.clearPolicy = RemVibeClearPolicy.immediate;
    service.clearCompletedItems();
    await service.stop();
    for (final RemVibeDownloadJob job
        in List<RemVibeDownloadJob>.of(service.jobs)) {
      await service.cancelJob(job);
    }
  });

  test('service is singleton and inactive jobs do not start', () async {
    expect(
      identical(RemVibeDownloadService(), RemVibeDownloadService()),
      isTrue,
    );
    expect(service.active, isFalse);

    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    final RemVibeDownloadJob job = RemVibeDownloadJob(
      key: 'inactive',
      title: 'Inactive',
      items: <RemVibeDownloadItem>[
        RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:1/not-started.bin'),
          directory: directory,
          filename: 'not-started.bin',
        ),
      ],
    );

    service.addJob(job);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(job.status, RemVibeDownloadStatus.idle);
    expect(job.items.single.status, RemVibeDownloadStatus.idle);
  });

  test('duplicate identity with two null validators keeps existing merge behavior', () {
    final Directory directory = Directory('validator-merge-null');
    final RemVibeDownloadItem existing = _mergeItem(
      directory,
      size: 1,
    );
    final RemVibeDownloadItem incoming = _mergeItem(
      directory,
      size: 2,
    );

    final RemVibeDownloadJob job = RemVibeDownloadJob(
      key: 'validator-merge-null',
      title: 'Validator merge null',
      items: <RemVibeDownloadItem>[existing, incoming],
    );

    expect(job.items, hasLength(1));
    expect(job.items.single, same(existing));
    expect(job.items.single.size, 2);
    expect(job.items.single.validator, isNull);
  });

  test('duplicate identity with the same validator instance merges', () {
    final Directory directory = Directory('validator-merge-identical');
    void validator(File _) {}
    final RemVibeDownloadItem existing = _mergeItem(
      directory,
      size: 1,
      validator: validator,
    );
    final RemVibeDownloadItem incoming = _mergeItem(
      directory,
      size: 2,
      validator: validator,
    );

    final RemVibeDownloadJob job = RemVibeDownloadJob(
      key: 'validator-merge-identical',
      title: 'Validator merge identical',
      items: <RemVibeDownloadItem>[existing, incoming],
    );

    expect(job.items, hasLength(1));
    expect(job.items.single, same(existing));
    expect(job.items.single.size, 2);
    expect(job.items.single.validator, same(validator));
  });

  test('duplicate identity rejects null then non-null validator without mutation', () {
    _expectValidatorMergeConflict(
      service,
      existingValidator: null,
      incomingValidator: (File _) {},
      key: 'validator-null-non-null',
    );
  });

  test('duplicate identity rejects non-null then null validator without mutation', () {
    _expectValidatorMergeConflict(
      service,
      existingValidator: (File _) {},
      incomingValidator: null,
      key: 'validator-non-null-null',
    );
  });

  test('duplicate identity rejects distinct validator instances without mutation', () {
    _expectValidatorMergeConflict(
      service,
      existingValidator: (File _) {},
      incomingValidator: (File _) {},
      key: 'validator-distinct',
    );
  });

  test('handler start replays existing jobs as add events', () async {
    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    final RemVibeDownloadJob job = RemVibeDownloadJob(
      key: 'handler-replay',
      title: 'Handler replay',
      items: <RemVibeDownloadItem>[
        RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:1/replay.bin'),
          directory: directory,
          filename: 'replay.bin',
        ),
      ],
    );
    service.addJob(job);

    final List<(RemVibeDownloadJob, RemVibeListEventType)> events =
        <(RemVibeDownloadJob, RemVibeListEventType)>[];
    final RemVibeDownloadHandler handler = RemVibeDownloadHandler(
      onJob: (
        RemVibeDownloadJob eventJob,
        RemVibeListEventType event,
      ) {
        events.add((eventJob, event));
      },
    );
    addTearDown(handler.dispose);

    handler.start();

    expect(events, <(RemVibeDownloadJob, RemVibeListEventType)>[
      (job, RemVibeListEventType.add),
    ]);
  });

  test('response headers resolve filename and size', () async {
    final List<int> bytes = List<int>.generate(256, (int index) => index);
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });
    server.listen((HttpRequest request) async {
      request.response.headers.set(
        'content-disposition',
        'attachment; filename="from-header.bin"',
      );
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });

    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    final Completer<void> completed = Completer<void>();
    final RemVibeDownloadJob job = RemVibeDownloadJob(
      key: 'metadata',
      title: 'Metadata',
      items: <RemVibeDownloadItem>[
        RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:${server.port}/download'),
          directory: directory,
        ),
      ],
      onStatus: (RemVibeDownloadJob job) {
        if (job.status == RemVibeDownloadStatus.completed &&
            !completed.isCompleted) {
          completed.complete();
        }
      },
    );

    await service.start();
    service.addJob(job);
    await completed.future.timeout(const Duration(seconds: 5));

    final RemVibeDownloadItem item = job.items.single;
    expect(item.filename, 'from-header.bin');
    expect(item.size, bytes.length);
    expect(item.downloadedSize, bytes.length);
    expect(item.status, RemVibeDownloadStatus.completed);
    expect(await item.file!.readAsBytes(), bytes);
  });

  test('failed item succeeds on third attempt', () async {
    var attemptCount = 0;
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });
    server.listen((HttpRequest request) async {
      attemptCount++;
      if (attemptCount < 3) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        return;
      }
      request.response.add(<int>[1, 2, 3]);
      await request.response.close();
    });

    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    final Completer<void> completed = Completer<void>();
    final RemVibeDownloadJob job = RemVibeDownloadJob(
      key: 'retry-success',
      title: 'Retry success',
      maxConcurrentItems: 1,
      items: <RemVibeDownloadItem>[
        RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:${server.port}/retry.bin'),
          directory: directory,
          filename: 'retry.bin',
        ),
      ],
      onStatus: (RemVibeDownloadJob job) {
        if (job.status == RemVibeDownloadStatus.completed &&
            !completed.isCompleted) {
          completed.complete();
        }
      },
    );

    await service.start();
    service.addJob(job);
    await completed.future.timeout(const Duration(seconds: 5));

    expect(attemptCount, 3);
    expect(job.items.single.errorCount, 2);
    expect(job.items.single.errorMessage, isNull);
    expect(job.items.single.status, RemVibeDownloadStatus.completed);
  });

  test('job becomes error after three failed attempts', () async {
    var attemptCount = 0;
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });
    server.listen((HttpRequest request) async {
      attemptCount++;
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    });

    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    final Completer<void> failed = Completer<void>();
    final RemVibeDownloadJob job = RemVibeDownloadJob(
      key: 'retry-error',
      title: 'Retry error',
      maxConcurrentItems: 1,
      items: <RemVibeDownloadItem>[
        RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:${server.port}/always-fails.bin'),
          directory: directory,
          filename: 'always-fails.bin',
        ),
      ],
      onStatus: (RemVibeDownloadJob job) {
        if (job.status == RemVibeDownloadStatus.error && !failed.isCompleted) {
          failed.complete();
        }
      },
    );

    await service.start();
    service.addJob(job);
    await failed.future.timeout(const Duration(seconds: 5));

    expect(attemptCount, 3);
    expect(job.items.single.errorCount, 3);
    expect(job.items.single.errorMessage, isNotNull);
    expect(job.items.single.errorMessage, isNotEmpty);
    expect(job.items.single.status, RemVibeDownloadStatus.error);
    expect(service.jobs, contains(job));
  });

  test('a job downloads at most five items concurrently by default', () async {
    var activeRequests = 0;
    var maxActiveRequests = 0;
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });
    server.listen((HttpRequest request) async {
      activeRequests++;
      if (activeRequests > maxActiveRequests) {
        maxActiveRequests = activeRequests;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      request.response.add(<int>[1]);
      await request.response.close();
      activeRequests--;
    });

    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    final Completer<void> completed = Completer<void>();
    final RemVibeDownloadJob job = RemVibeDownloadJob(
      key: 'concurrency',
      title: 'Concurrency',
      items: List<RemVibeDownloadItem>.generate(
        8,
        (int index) => RemVibeDownloadItem(
          url: Uri.parse('http://127.0.0.1:${server.port}/$index.bin'),
          directory: directory,
          filename: '$index.bin',
        ),
      ),
      onStatus: (RemVibeDownloadJob job) {
        if (job.status == RemVibeDownloadStatus.completed &&
            !completed.isCompleted) {
          completed.complete();
        }
      },
    );

    expect(job.maxConcurrentItems, 5);
    await service.start();
    service.addJob(job);
    await completed.future.timeout(const Duration(seconds: 5));

    expect(maxActiveRequests, 5);
  });
}

RemVibeDownloadItem _mergeItem(
  Directory directory, {
  required int size,
  RemVibeDownloadItemValidator? validator,
}) {
  return RemVibeDownloadItem(
    url: Uri.parse('https://example.test/shared.bin'),
    directory: directory,
    filename: 'shared.bin',
    size: size,
    validator: validator,
  );
}

void _expectValidatorMergeConflict(
  RemVibeDownloadService service, {
  required RemVibeDownloadItemValidator? existingValidator,
  required RemVibeDownloadItemValidator? incomingValidator,
  required String key,
}) {
  final Directory directory = Directory(key);
  final RemVibeDownloadItem existing = _mergeItem(
    directory,
    size: 7,
    validator: existingValidator,
  );
  final RemVibeDownloadJob existingJob = RemVibeDownloadJob(
    key: key,
    title: 'Existing',
    items: <RemVibeDownloadItem>[existing],
  );
  final RemVibeDownloadJob incomingJob = RemVibeDownloadJob(
    key: key,
    title: 'Incoming',
    items: <RemVibeDownloadItem>[
      _mergeItem(
        directory,
        size: 99,
        validator: incomingValidator,
      ),
    ],
  );
  service.addJob(existingJob);

  expect(
    () => service.addJob(incomingJob),
    throwsA(
      isA<StateError>().having(
        (StateError error) => error.message,
        'message',
        contains('incompatible validator contract'),
      ),
    ),
  );
  expect(service.jobs, <RemVibeDownloadJob>[existingJob]);
  expect(existingJob.items, <RemVibeDownloadItem>[existing]);
  expect(existingJob.items.single.size, 7);
  expect(existingJob.items.single.validator, same(existingValidator));
  expect(existingJob.status, RemVibeDownloadStatus.idle);
  expect(existing.status, RemVibeDownloadStatus.idle);
}
