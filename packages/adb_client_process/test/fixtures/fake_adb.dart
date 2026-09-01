import 'dart:async';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  switch (arguments.firstOrNull) {
    case 'success':
      stdout.write('ok:${arguments.skip(1).join(',')}');
    case 'stdin':
      await stdout.addStream(stdin);
    case 'failure':
      stderr.write('expected failure');
      exitCode = 7;
    case 'sleep':
      await Future<void>.delayed(const Duration(seconds: 30));
    case 'long-running':
      stdout.write('ready');
      await stdout.flush();
      await Future<void>.delayed(const Duration(seconds: 30));
    case 'large':
      stdout.add(List<int>.filled(2 * 1024 * 1024, 65));
    case 'connect':
      final endpoint = arguments.elementAtOrNull(1) ?? '';
      if (endpoint.startsWith('sleep.')) {
        await Future<void>.delayed(const Duration(seconds: 30));
        return;
      }
      stdout.write(
        endpoint.startsWith('fail.')
            ? 'failed to connect to $endpoint'
            : endpoint.startsWith('already.')
            ? 'already connected to $endpoint'
            : 'connected to $endpoint',
      );
    case 'disconnect':
      final endpoint = arguments.elementAtOrNull(1) ?? '';
      if (endpoint.startsWith('missing.')) exitCode = 1;
      stdout.write(
        endpoint.startsWith('fail.')
            ? 'failed to disconnect $endpoint'
            : endpoint.startsWith('missing.')
            ? "no such device '$endpoint'"
            : 'disconnected $endpoint',
      );
    case 'pair':
      final endpoint = arguments.elementAtOrNull(1) ?? '';
      final pairingCode = arguments.elementAtOrNull(2);
      if (pairingCode == '999999') {
        await Future<void>.delayed(const Duration(seconds: 30));
        return;
      }
      stdout.write(
        pairingCode == '000000'
            ? 'Failed: Unable to start pairing client.'
            : pairingCode == '111111'
            ? 'Failed: pairing code expired.'
            : 'Successfully paired to $endpoint',
      );
    case 'mdns':
      stdout.write('''List of discovered mdns services
adb-demo-a\t_adb-tls-pairing._tcp.\t192.0.2.10:37123
adb-demo-a\t_adb-tls-connect._tcp.\t192.0.2.10:41001
adb-demo-v6\t_adb-tls-pairing._tcp.\t[2001:db8::10]:38888
''');
    default:
      stdout.write(arguments.join('|'));
  }
}
