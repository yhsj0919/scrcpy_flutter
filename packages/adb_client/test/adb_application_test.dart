import 'dart:convert';

import 'package:test/test.dart';
import 'package:adb_client/adb_client.dart';

final class _ApplicationAdbClient implements AdbClient {
  final commands = <List<String>>[];
  final responses = <AdbCommandResult>[];

  @override
  Future<AdbCommandResult> shell(
    String serial,
    List<String> arguments, {
    AdbCancellationToken? cancellationToken,
  }) async {
    commands.add(arguments);
    return responses.removeAt(0);
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
  test('merges package metadata and launcher activities', () {
    final apps = AdbApplicationParser.merge(
      launcherActivitiesOutput: '''
  com.android.settings/.Settings
  com.example.demo/.MainActivity
''',
      packageListOutput: '''
package:/system/priv-app/Settings/Settings.apk=com.android.settings versionCode:36 uid:1000
package:/data/app/~~AbC==/com.example.demo-XyZ==/base.apk=com.example.demo versionCode:42 uid:10123
not-a-package
''',
      packageDumpOutput: '''
  Package [com.android.settings] (123):
    versionCode=36 minSdk=35 targetSdk=36
    versionName=16
    User 0: installed=true enabled=0 stopped=false
  Package [com.example.demo] (456):
    versionCode=42 minSdk=24 targetSdk=36
    versionName=2.1.0
    User 0: installed=true enabled=3 stopped=true
''',
    );

    expect(apps, hasLength(2));
    final settings = apps.firstWhere(
      (app) => app.packageName == 'com.android.settings',
    );
    expect(settings.name, 'com.android.settings');
    expect(settings.type, AdbApplicationType.system);
    expect(settings.enabled, isTrue);
    expect(settings.launchable, isTrue);
    expect(settings.versionName, '16');
    expect(settings.versionCode, 36);

    final demo = apps.firstWhere(
      (app) => app.packageName == 'com.example.demo',
    );
    expect(demo.name, 'com.example.demo');
    expect(demo.type, AdbApplicationType.user);
    expect(demo.enabled, isFalse);
    expect(demo.uid, 10123);
    expect(demo.matches('EXAMPLE'), isTrue);
  });

  test('keeps packages without a launcher activity', () {
    final apps = AdbApplicationParser.merge(
      packageListOutput: 'package:/system/framework/framework-res.apk=android versionCode:36 uid:1000\n',
      packageDumpOutput: '',
    );

    expect(apps.single.packageName, 'android');
    expect(apps.single.name, 'android');
    expect(apps.single.type, AdbApplicationType.system);
    expect(apps.single.enabled, isTrue);
    expect(apps.single.launchable, isFalse);
  });

  test(
    'starts a resolved launcher component with optional force-stop',
    () async {
      final adb = _ApplicationAdbClient()
        ..responses.addAll(<AdbCommandResult>[
          _result(''),
          _result('priority=0\ncom.example.demo/.MainActivity\n'),
          _result('Starting: Intent { cmp=com.example.demo/.MainActivity }\n'),
        ]);
      final manager = AdbApplicationManager(adbClient: adb, serial: 'device');

      await manager.startApplication('com.example.demo', forceStopFirst: true);

      expect(adb.commands[0], <String>['am', 'force-stop', 'com.example.demo']);
      expect(adb.commands[2], <String>[
        'am',
        'start',
        '-n',
        'com.example.demo/.MainActivity',
      ]);
    },
  );

  test('reports an app without a launcher activity', () async {
    final adb = _ApplicationAdbClient()
      ..responses.add(_result('No activity found\n'));
    final manager = AdbApplicationManager(adbClient: adb, serial: 'device');

    await expectLater(
      manager.startApplication('com.example.service'),
      throwsA(
        isA<AdbApplicationOperationException>()
            .having(
              (error) => error.operation,
              'operation',
              AdbApplicationOperation.start,
            )
            .having(
              (error) => error.packageName,
              'packageName',
              'com.example.service',
            ),
      ),
    );
  });
}
