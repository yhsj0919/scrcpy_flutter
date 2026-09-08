enum ScrcpyErrorCode {
  unsupportedCapability,
  resourceMissing,
  resourceInvalid,
  adbFailure,
  connectionFailure,
  protocolFailure,
  videoFailure,
  captureFailure,
  recordingFailure,
  cancelled,
}

final class ScrcpyException implements Exception {
  const ScrcpyException(this.code, this.message, {this.cause});

  final ScrcpyErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'ScrcpyException($code, $message)'
      : 'ScrcpyException($code, $message, cause: $cause)';
}
