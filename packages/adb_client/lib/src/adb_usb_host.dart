import 'adb_cancellation_token.dart';

/// The observable state of an Android USB Host connection.
enum AdbUsbHostState {
  noDevice,
  noAdbInterface,
  permissionRequired,
  permissionPending,
  permissionDenied,
  ready,
}

/// Describes USB devices visible to a host and their authorization state.
final class AdbUsbHostStatus {
  const AdbUsbHostStatus({
    required this.attachedDeviceCount,
    required this.adbDeviceCount,
    required this.authorizedDeviceCount,
    required this.permissionRequestPending,
    required this.permissionDenied,
  });

  /// The number of all devices enumerated while the Android device is Host.
  final int attachedDeviceCount;

  /// The number of enumerated devices that expose an ADB interface.
  final int adbDeviceCount;

  /// The number of ADB devices the application may currently access.
  final int authorizedDeviceCount;

  /// Whether an Android USB permission dialog is awaiting a decision.
  final bool permissionRequestPending;

  /// Whether permission was rejected for an attached ADB device.
  final bool permissionDenied;

  /// The most relevant state derived from the USB device counts and permissions.
  AdbUsbHostState get state {
    if (attachedDeviceCount == 0) return AdbUsbHostState.noDevice;
    if (adbDeviceCount == 0) return AdbUsbHostState.noAdbInterface;
    if (authorizedDeviceCount > 0) return AdbUsbHostState.ready;
    if (permissionRequestPending) return AdbUsbHostState.permissionPending;
    if (permissionDenied) return AdbUsbHostState.permissionDenied;
    return AdbUsbHostState.permissionRequired;
  }
}

/// Provides optional USB Host diagnostics for ADB backends that support them.
abstract interface class AdbUsbHostProvider {
  /// Reads USB Host status and optionally requests access to unapproved devices.
  ///
  /// Setting [requestPermission] to `true` clears a previous rejection and may
  /// display the platform USB permission dialog again.
  Future<AdbUsbHostStatus> getUsbHostStatus({
    bool requestPermission = false,
    AdbCancellationToken? cancellationToken,
  });
}
