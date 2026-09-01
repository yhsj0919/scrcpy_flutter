enum AdbErrorCode {
  executableNotFound,
  startFailed,
  commandFailed,
  timedOut,
  cancelled,
  invalidResponse,
}

final class AdbException implements Exception {
  const AdbException(this.code, this.message, {this.exitCode});

  final AdbErrorCode code;
  final String message;
  final int? exitCode;

  @override
  String toString() => 'AdbException($code, $message)';
}
