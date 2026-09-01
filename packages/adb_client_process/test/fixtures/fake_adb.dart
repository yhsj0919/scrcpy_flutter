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
    default:
      stdout.write(arguments.join('|'));
  }
}
