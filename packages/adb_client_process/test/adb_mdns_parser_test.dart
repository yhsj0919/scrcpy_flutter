import 'package:adb_client/adb_client.dart';
import 'package:adb_client_process/adb_client_process.dart';
import 'package:test/test.dart';

void main() {
  test('parses pairing and connect services with changing ports', () {
    final services = parseAdbMdnsServices('''
List of discovered mdns services
adb-one _adb-tls-pairing._tcp. 192.0.2.10:37123
adb-one _adb-tls-connect._tcp. 192.0.2.10:41001
adb-one _adb-tls-connect._tcp. 192.0.2.10:42002
adb-v6 _adb-tls-pairing._tcp. [2001:db8::1]:38888
ignored _adb._tcp. 192.0.2.30:5555
''');

    expect(services, hasLength(4));
    expect(services.first.type, AdbMdnsServiceType.pairing);
    expect(services.first.endpoint.authority, '192.0.2.10:37123');
    expect(services[2].endpoint.port, 42002);
    expect(services.last.endpoint.authority, '[2001:db8::1]:38888');
  });

  test('ignores headers, malformed rows and duplicate endpoints', () {
    final services = parseAdbMdnsServices('''
List of discovered mdns services
broken
adb-one _adb-tls-pairing._tcp. invalid:
adb-one _adb-tls-pairing._tcp. 192.0.2.10:37123
adb-two _adb-tls-pairing._tcp. 192.0.2.10:37123
''');

    expect(services, hasLength(1));
  });
}
