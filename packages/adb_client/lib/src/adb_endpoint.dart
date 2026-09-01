final class AdbEndpoint {
  const AdbEndpoint({required this.host, required this.port})
    : assert(host != ''),
      assert(port > 0 && port <= 65535);

  final String host;
  final int port;

  static AdbEndpoint? tryParse(String value, {int defaultPort = 5555}) {
    final input = value.trim();
    if (input.isEmpty) return null;

    if (input.startsWith('[')) {
      final closingBracket = input.indexOf(']');
      if (closingBracket <= 1) return null;
      final host = input.substring(1, closingBracket);
      if (closingBracket == input.length - 1) {
        return AdbEndpoint(host: host, port: defaultPort);
      }
      if (input[closingBracket + 1] != ':') return null;
      final port = int.tryParse(input.substring(closingBracket + 2));
      return _validated(host, port);
    }

    final colonCount = ':'.allMatches(input).length;
    if (colonCount == 0) {
      return AdbEndpoint(host: input, port: defaultPort);
    }
    if (colonCount > 1) {
      return AdbEndpoint(host: input, port: defaultPort);
    }
    final separator = input.lastIndexOf(':');
    return _validated(
      input.substring(0, separator),
      int.tryParse(input.substring(separator + 1)),
    );
  }

  static AdbEndpoint? _validated(String host, int? port) {
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    return AdbEndpoint(host: host, port: port);
  }

  String get authority {
    final normalizedHost = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return '$normalizedHost:$port';
  }
}

final class AdbForwardRule {
  const AdbForwardRule({required this.local, required this.remote});

  /// ADB socket spec such as `tcp:27183` or `localabstract:scrcpy_...`.
  final String local;
  final String remote;
}
