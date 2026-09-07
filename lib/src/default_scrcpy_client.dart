import 'scrcpy_client.dart';
import 'scrcpy_facade.dart';
import 'default_scrcpy_client_stub.dart'
    if (dart.library.io) 'default_scrcpy_client_io.dart'
    as implementation;

/// Creates the supported platform default without requiring the embedding app
/// to know which ADB transport package is in use.
ScrcpyClient createDefaultScrcpyClient({
  String? adbExecutablePath,
  String? scrcpyServerPath,
}) => implementation.createDefaultScrcpyClient(
  adbExecutablePath: adbExecutablePath,
  scrcpyServerPath: scrcpyServerPath,
);

/// Creates the ready-to-use API with bundled platform resources.
ScrcpyManager createDefaultScrcpyManager({
  String? adbExecutablePath,
  String? scrcpyServerPath,
  int? maxSessions = 16,
}) => ScrcpyManager.fromClient(
  createDefaultScrcpyClient(
    adbExecutablePath: adbExecutablePath,
    scrcpyServerPath: scrcpyServerPath,
  ),
  maxSessions: maxSessions,
);
