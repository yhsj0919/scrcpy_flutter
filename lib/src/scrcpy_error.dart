enum ScrcpyErrorCode {
  unsupportedCapability,
  resourceMissing,
  adbFailure,
  connectionFailure,
  protocolFailure,
  videoFailure,
  cancelled,
}

final class ScrcpyException implements Exception {
  const ScrcpyException(this.code, this.message, {this.cause});

  final ScrcpyErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'ScrcpyException($code, $message)';
}
