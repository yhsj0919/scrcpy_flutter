import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';
import 'package:scrcpy_flutter/src/scrcpy_video_connection_io.dart';

void main() {
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
