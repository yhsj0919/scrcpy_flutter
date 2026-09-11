import 'dart:convert';
import 'dart:io';

import 'package:adb_client/adb_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android host executes shell through direct network ADB', (
    tester,
  ) async {
    if (!Platform.isAndroid) return;
    const authority = String.fromEnvironment('ADB_TEST_ENDPOINT');
    if (authority.isEmpty) return;
    final endpoint = AdbEndpoint.tryParse(authority);
    expect(endpoint, isNotNull);

    final client = createDefaultScrcpyClient();
    final adb = client.adbClient;
    await adb.connect(endpoint!);
    try {
      final devices = await adb.listDevices();
      expect(
        devices.map((device) => device.serial),
        contains(endpoint.authority),
      );
      final result = await adb.shell(endpoint.authority, const <String>[
        'getprop',
        'ro.product.model',
      ]);
      expect(result.isSuccess, isTrue);
      expect(utf8.decode(result.stdout).trim(), isNotEmpty);

      final local = File('${Directory.systemTemp.path}/adb-network-source.txt');
      final pulled = File('${Directory.systemTemp.path}/adb-network-pulled.txt');
      const remote = '/data/local/tmp/adb-network-roundtrip.txt';
      await local.writeAsString('scrcpy_flutter android adb\n');
      await adb.push(endpoint.authority, local.path, remote);
      await adb.pull(endpoint.authority, remote, pulled.path);
      expect(await pulled.readAsString(), await local.readAsString());
      await adb.shell(endpoint.authority, const <String>['rm', '-f', remote]);
      await local.delete();
      await pulled.delete();
    } finally {
      await adb.disconnect(endpoint);
    }
  });
}
