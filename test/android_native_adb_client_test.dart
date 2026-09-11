import 'package:adb_client/adb_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/src/android_native_adb_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('scrcpy_flutter/android_adb');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'maps Android NSD services and only waits for initial discovery',
    () async {
      final waits = <int>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'discoverMdnsServices');
            waits.add(
              (call.arguments as Map<Object?, Object?>)['waitMillis']! as int,
            );
            return <Map<String, Object>>[
              <String, Object>{
                'name': 'adb-device-pairing',
                'type': '_adb-tls-pairing._tcp',
                'host': '192.168.1.20',
                'port': 37123,
              },
              <String, Object>{
                'name': 'adb-device-connect',
                'type': '_adb-tls-connect._tcp',
                'host': 'fe80::1%wlan0',
                'port': 40111,
              },
            ];
          });
      final client = AndroidNativeAdbClient();

      final first = await client.discoverMdnsServices();
      final second = await client.discoverMdnsServices();

      expect(waits, <int>[1200, 0]);
      expect(first, hasLength(2));
      expect(first.first.type, AdbMdnsServiceType.pairing);
      expect(first.first.endpoint.authority, '192.168.1.20:37123');
      expect(first.last.type, AdbMdnsServiceType.connect);
      expect(first.last.endpoint.authority, '[fe80::1%wlan0]:40111');
      expect(second, hasLength(2));
    },
  );

  test('ignores unrelated DNS-SD services', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => <Map<String, Object>>[
            <String, Object>{
              'name': 'printer',
              'type': '_ipp._tcp',
              'host': '192.168.1.30',
              'port': 631,
            },
          ],
        );

    expect(await AndroidNativeAdbClient().discoverMdnsServices(), isEmpty);
  });
}
