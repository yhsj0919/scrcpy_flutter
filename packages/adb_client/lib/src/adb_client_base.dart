import 'adb_cancellation_token.dart';
import 'adb_command.dart';
import 'adb_device.dart';
import 'adb_endpoint.dart';

abstract interface class AdbCommandExecutor {
  Future<AdbCommandResult> execute(
    AdbCommand command, {
    AdbCancellationToken? cancellationToken,
  });
}

abstract interface class AdbRunningCommand {
  Stream<List<int>> get stdout;

  Stream<List<int>> get stderr;

  Future<int> get exitCode;

  bool kill();
}

abstract interface class AdbLongRunningCommandExecutor {
  Future<AdbRunningCommand> start(
    AdbCommand command, {
    AdbCancellationToken? cancellationToken,
  });
}

abstract interface class AdbDeviceService {
  Future<List<AdbDevice>> listDevices({
    AdbCancellationToken? cancellationToken,
  });
}

abstract interface class AdbConnectionService {
  Future<void> connect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  });

  Future<void> disconnect(
    AdbEndpoint endpoint, {
    AdbCancellationToken? cancellationToken,
  });

  Future<void> pair(
    AdbEndpoint endpoint,
    String pairingCode, {
    AdbCancellationToken? cancellationToken,
  });
}

abstract interface class AdbShellService {
  Future<AdbCommandResult> shell(
    String serial,
    List<String> arguments, {
    AdbCancellationToken? cancellationToken,
  });
}

abstract interface class AdbSyncService {
  Future<void> push(
    String serial,
    String localPath,
    String remotePath, {
    AdbCancellationToken? cancellationToken,
  });

  Future<void> pull(
    String serial,
    String remotePath,
    String localPath, {
    AdbCancellationToken? cancellationToken,
  });
}

abstract interface class AdbPackageService {
  Future<void> install(
    String serial,
    String apkPath, {
    bool replaceExisting = false,
    AdbCancellationToken? cancellationToken,
  });

  Future<void> uninstall(
    String serial,
    String packageName, {
    bool keepData = false,
    AdbCancellationToken? cancellationToken,
  });
}

abstract interface class AdbForwardService {
  Future<void> forward(
    String serial,
    AdbForwardRule rule, {
    AdbCancellationToken? cancellationToken,
  });

  Future<void> removeForward(
    String serial,
    String local, {
    AdbCancellationToken? cancellationToken,
  });
}

abstract interface class AdbClient
    implements
        AdbCommandExecutor,
        AdbLongRunningCommandExecutor,
        AdbDeviceService,
        AdbConnectionService,
        AdbShellService,
        AdbSyncService,
        AdbPackageService,
        AdbForwardService {}
