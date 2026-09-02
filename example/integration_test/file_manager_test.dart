import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('manages files with spaces Chinese and shell characters', (
    _,
  ) async {
    final client = createDefaultScrcpyClient();
    final readyDevices = (await client.discoverDevices())
        .where((candidate) => candidate.isReady)
        .toList();
    final usbDevices = readyDevices
        .where((candidate) => candidate.connectionType == AdbConnectionType.usb)
        .toList();
    final device = usbDevices.isNotEmpty
        ? usbDevices.first
        : readyDevices.first;
    final manager = client.createFileManager(device.serial);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final remoteRoot = "/sdcard/Download/scrcpy 文件 $suffix '安全'";
    final remoteFile = '$remoteRoot/原始 file & data.txt';
    final renamedFile = "$remoteRoot/重命名 'ok'.txt";
    final localRoot = await Directory.systemTemp.createTemp(
      'scrcpy_file_test_',
    );
    final source = File('${localRoot.path}${Platform.pathSeparator}源 文件.txt');
    final pulled = File('${localRoot.path}${Platform.pathSeparator}下载 文件.txt');
    await source.writeAsString('scrcpy Flutter 文件测试');

    try {
      await manager.createDirectory(remoteRoot, recursive: true);
      await manager.push(source.path, remoteFile);
      await expectLater(
        manager.push(source.path, remoteFile),
        throwsA(isA<ScrcpyException>()),
      );

      var entries = await manager.listDirectory(remoteRoot);
      expect(
        entries.map((entry) => entry.name),
        contains('原始 file & data.txt'),
      );

      await manager.rename(remoteFile, renamedFile);
      entries = await manager.listDirectory(remoteRoot);
      expect(entries.map((entry) => entry.name), contains("重命名 'ok'.txt"));

      await manager.pull(renamedFile, pulled.path);
      expect(await pulled.readAsString(), 'scrcpy Flutter 文件测试');

      final cancelled = AdbCancellationToken()..cancel();
      await expectLater(
        manager.pull(renamedFile, pulled.path, cancellationToken: cancelled),
        throwsA(isA<AdbException>()),
      );

      await manager.delete(renamedFile);
      expect(await manager.listDirectory(remoteRoot), isEmpty);
    } finally {
      try {
        await manager.delete(remoteRoot, recursive: true);
      } catch (_) {
        // The first operation may fail before the test directory exists.
      }
      await localRoot.delete(recursive: true);
    }
  });
}
