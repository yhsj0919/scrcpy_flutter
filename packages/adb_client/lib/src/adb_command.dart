import 'dart:typed_data';

/// A structured invocation. Arguments are never joined into a shell command.
final class AdbCommand {
  const AdbCommand(
    this.arguments, {
    this.stdin,
    this.timeout = const Duration(seconds: 15),
    this.sensitiveArgumentIndexes = const <int>{},
  });

  final List<String> arguments;
  final Uint8List? stdin;
  final Duration timeout;

  /// Argument indexes which must be redacted from diagnostic output.
  final Set<int> sensitiveArgumentIndexes;

  List<String> get redactedArguments => <String>[
    for (var index = 0; index < arguments.length; index++)
      sensitiveArgumentIndexes.contains(index)
          ? '<redacted>'
          : arguments[index],
  ];
}

final class AdbCommandResult {
  const AdbCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.elapsed,
  });

  final int exitCode;
  final List<int> stdout;
  final List<int> stderr;
  final Duration elapsed;

  bool get isSuccess => exitCode == 0;
}
