import 'dart:convert';

import 'package:adb_client/adb_client.dart';
import 'package:test/test.dart';

final class _FileAdbClient implements AdbClient {
  final List<List<String>> shellCalls = <List<String>>[];
  final List<AdbCommandResult> results = <AdbCommandResult>[];
  AdbCommandResult result = _result('');

  @override
  Future<AdbCommandResult> shell(
    String serial,
    List<String> arguments, {
    AdbCancellationToken? cancellationToken,
  }) async {
    shellCalls.add(arguments);
    return results.isEmpty ? result : results.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdbCommandResult _result(String output, {int exitCode = 0}) => AdbCommandResult(
  exitCode: exitCode,
  stdout: utf8.encode(output),
  stderr: const <int>[],
  elapsed: Duration.zero,
);

void main() {
  test('lists one directory without a nested shell script', () async {
    final adb = _FileAdbClient();
    final manager = AdbFileManager(adbClient: adb, serial: 'device');

    await manager.listDirectory('/sdcard');

    expect(adb.shellCalls, <List<String>>[
      <String>['ls', '-A1', '/sdcard'],
    ]);
  });

  test(
    'builds child paths and requests metadata without shell quoting',
    () async {
      final adb = _FileAdbClient()
        ..results.addAll(<AdbCommandResult>[
          _result('Music\nfile name.txt\n'),
          _result(
            '/sdcard/Music\u001fdirectory\u001f4096\u001f100\n'
            '/sdcard/file name.txt\u001fregular file\u001f12\u001f200\n',
          ),
        ]);
      final manager = AdbFileManager(adbClient: adb, serial: 'device');

      final entries = await manager.listDirectory('/sdcard');

      expect(adb.shellCalls, <List<String>>[
        <String>['ls', '-A1', '/sdcard'],
        <String>[
          'stat',
          '-c',
          '%n\u001f%F\u001f%s\u001f%Y',
          '/sdcard/Music',
          '/sdcard/file name.txt',
        ],
      ]);
      expect(entries.map((entry) => entry.path), <String>[
        '/sdcard/Music',
        '/sdcard/file name.txt',
      ]);
    },
  );

  test('includes the remote shell error in file operation failures', () async {
    final adb = _FileAdbClient()
      ..result = _result('find: permission denied', exitCode: 1);
    final manager = AdbFileManager(adbClient: adb, serial: 'device');

    await expectLater(
      manager.listDirectory('/data'),
      throwsA(
        isA<AdbException>().having(
          (error) => error.message,
          'message',
          contains('permission denied'),
        ),
      ),
    );
  });
}
