import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';
import 'package:scrcpy_flutter/src/default_scrcpy_client_io.dart';
import 'package:scrcpy_flutter/src/scrcpy_video_connection_io.dart';

void main() {
  test('bundled desktop resources match their recorded checksums', () async {
    final expected = <String, String>{
      'windows/third_party/scrcpy/scrcpy-server-v5.0.1':
          bundledScrcpyServerSha256,
      'linux/third_party/scrcpy/scrcpy-server-v5.0.1': bundledScrcpyServerSha256,
      'macos/third_party/scrcpy/scrcpy-server-v5.0.1': bundledScrcpyServerSha256,
      'linux/third_party/platform-tools/adb':
          'a902be8f45c6c62e76c9efaf6947a0fa747c9cabd89a2ac8e0d16ecb30b3ed01',
      'macos/third_party/platform-tools/adb':
          '1811e253b21b12cbfda7201ebaf86c10e7ddcb5c606a7a81f7c82b4c429c2d3b',
    };

    for (final entry in expected.entries) {
      final bytes = await File(entry.key).readAsBytes();
      expect(sha256.convert(bytes).toString(), entry.value, reason: entry.key);
    }
  });

  test('validates an expected scrcpy server checksum', () async {
    final directory = await Directory.systemTemp.createTemp('scrcpy-resource-');
    final file = File('${directory.path}${Platform.pathSeparator}server.jar');
    addTearDown(() => directory.delete(recursive: true));
    await file.writeAsBytes(<int>[1, 2, 3, 4]);
    final expected = sha256.convert(<int>[1, 2, 3, 4]).toString();

    await validateScrcpyServerResource(file.path, expectedSha256: expected);
  });

  test('rejects a mismatched scrcpy server checksum', () async {
    final directory = await Directory.systemTemp.createTemp('scrcpy-resource-');
    final file = File('${directory.path}${Platform.pathSeparator}server.jar');
    addTearDown(() => directory.delete(recursive: true));
    await file.writeAsBytes(<int>[1, 2, 3, 4]);

    await expectLater(
      validateScrcpyServerResource(file.path, expectedSha256: '00'),
      throwsA(
        isA<ScrcpyException>().having(
          (error) => error.code,
          'code',
          ScrcpyErrorCode.resourceInvalid,
        ),
      ),
    );
  });
}
