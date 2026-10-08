import 'dart:io';

import 'package:remvibe_download_service/remvibe_download_service.dart';
import 'package:test/test.dart';

void main() {
  final RemVibeDownloadService service = RemVibeDownloadService();

  setUp(() async {
    service.clearPolicy = RemVibeClearPolicy.immediate;
    service.clearCompletedItems();
    await service.stop();

    for (final RemVibeDownloadJob job in List<RemVibeDownloadJob>.of(service.jobs)) {
      await service.cancelJob(job);
    }
  });

  test('downloadNow uses DownloadService lifecycle and returns a success response', () async {
    final List<int> bytes = <int>[1, 2, 3, 4, 5];
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });
    server.listen((HttpRequest request) async {
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });

    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() async {
      await directory.delete(recursive: true);
    });

    final List<RemVibeListEventType> events = <RemVibeListEventType>[];
    final RemVibeDownloadHandler handler = RemVibeDownloadHandler(
      onJob: (RemVibeDownloadJob job, RemVibeListEventType event) {
        events.add(event);
      },
    )..start();
    addTearDown(handler.dispose);

    expect(service.active, isFalse);

    final RemVibeDownloadResponse response = await service.downloadNow(
      url: Uri.parse('http://127.0.0.1:${server.port}/manifest.json'),
      folder: directory,
      filename: 'version_manifest_v2.json',
    );

    expect(service.active, isTrue);
    expect(response.status, RemVibeDownloadStatus.completed);
    expect(response.success, isTrue);
    expect(response.error, isFalse);
    expect(response.cancelled, isFalse);
    expect(response.url, Uri.parse('http://127.0.0.1:${server.port}/manifest.json'));
    expect(response.folder.path, directory.path);
    expect(response.filename, 'version_manifest_v2.json');
    expect(response.errorMessage, isNull);
    expect(response.downloadedSize, bytes.length);
    expect(response.totalSize, bytes.length);
    expect(response.errorCount, 0);
    expect(response.file, isNotNull);
    expect(await response.file!.readAsBytes(), bytes);
    expect(events, contains(RemVibeListEventType.add));
    expect(events, contains(RemVibeListEventType.update));
    expect(events, contains(RemVibeListEventType.remove));

    await service.stop();
  });

  test('downloadNow returns terminal error details after retries are exhausted', () async {
    var attemptCount = 0;
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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

    final RemVibeDownloadResponse response = await service.downloadNow(
      url: Uri.parse('http://127.0.0.1:${server.port}/failure.json'),
      folder: directory,
      filename: 'failure.json',
      maxErrorCount: 2,
    );

    expect(attemptCount, 2);
    expect(response.status, RemVibeDownloadStatus.error);
    expect(response.success, isFalse);
    expect(response.error, isTrue);
    expect(response.cancelled, isFalse);
    expect(response.folder.path, directory.path);
    expect(response.filename, 'failure.json');
    expect(response.errorMessage, isNotNull);
    expect(response.errorMessage, isNotEmpty);
    expect(response.downloadedSize, 0);
    expect(response.errorCount, 2);
    expect(await response.file!.exists(), isFalse);

    await service.stop();
  });

  test('validator sees the complete temporary file before publication', () async {
    final List<int> bytes = <int>[7, 8, 9];
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() => directory.delete(recursive: true));
    final File destination = File('${directory.path}${Platform.pathSeparator}validated.bin');
    var validatorCalled = false;

    final RemVibeDownloadResponse response = await service.downloadNow(
      url: Uri.parse('http://127.0.0.1:${server.port}/validated.bin'),
      folder: directory,
      filename: 'validated.bin',
      validator: (File temporary) async {
        validatorCalled = true;
        expect(temporary.path, '${destination.path}.download');
        expect(await temporary.readAsBytes(), bytes);
        expect(await destination.exists(), isFalse);
      },
    );

    expect(response.success, isTrue);
    expect(validatorCalled, isTrue);
    expect(await destination.readAsBytes(), bytes);
    expect(await File('${destination.path}.download').exists(), isFalse);
  });

  test('sync and async validator failures never replace an existing destination', () async {
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      request.response.add(<int>[1, 2, 3]);
      await request.response.close();
    });
    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() => directory.delete(recursive: true));

    for (final MapEntry<String, RemVibeDownloadItemValidator> entry
        in <String, RemVibeDownloadItemValidator>{
      'sync.bin': (File _) => throw StateError('sync invalid'),
      'async.bin': (File _) async => throw StateError('async invalid'),
    }.entries) {
      final File destination = File('${directory.path}${Platform.pathSeparator}${entry.key}');
      await destination.writeAsString('existing');
      final RemVibeDownloadResponse response = await service.downloadNow(
        url: Uri.parse('http://127.0.0.1:${server.port}/${entry.key}'),
        folder: directory,
        filename: entry.key,
        validator: entry.value,
        maxErrorCount: 1,
      );

      expect(response.error, isTrue);
      expect(response.errorCount, 1);
      expect(await destination.readAsString(), 'existing');
      expect(await File('${destination.path}.download').exists(), isFalse);
    }
  });

  test('validator failure uses generic retry and later valid bytes publish', () async {
    var attempts = 0;
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      attempts++;
      request.response.add(attempts == 1 ? <int>[0] : <int>[4, 5, 6]);
      await request.response.close();
    });
    final Directory directory = await Directory.systemTemp.createTemp();
    addTearDown(() => directory.delete(recursive: true));

    final RemVibeDownloadResponse response = await service.downloadNow(
      url: Uri.parse('http://127.0.0.1:${server.port}/retry.bin'),
      folder: directory,
      filename: 'retry.bin',
      maxErrorCount: 2,
      validator: (File temporary) async {
        if ((await temporary.readAsBytes()).length != 3) {
          throw StateError('invalid length');
        }
      },
    );

    expect(attempts, 2);
    expect(response.success, isTrue);
    expect(response.errorCount, 1);
    expect(await response.file!.readAsBytes(), <int>[4, 5, 6]);
  });
}
