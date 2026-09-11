import 'package:adb_client/adb_client.dart';
import 'package:test/test.dart';

void main() {
  group('AdbUsbHostStatus', () {
    test('distinguishes missing devices and missing ADB interfaces', () {
      expect(_status().state, AdbUsbHostState.noDevice);
      expect(
        _status(attachedDeviceCount: 1).state,
        AdbUsbHostState.noAdbInterface,
      );
    });

    test('reports the USB permission lifecycle', () {
      expect(
        _status(attachedDeviceCount: 1, adbDeviceCount: 1).state,
        AdbUsbHostState.permissionRequired,
      );
      expect(
        _status(
          attachedDeviceCount: 1,
          adbDeviceCount: 1,
          permissionRequestPending: true,
        ).state,
        AdbUsbHostState.permissionPending,
      );
      expect(
        _status(
          attachedDeviceCount: 1,
          adbDeviceCount: 1,
          permissionDenied: true,
        ).state,
        AdbUsbHostState.permissionDenied,
      );
    });

    test('an authorized ADB interface is ready', () {
      expect(
        _status(
          attachedDeviceCount: 2,
          adbDeviceCount: 1,
          authorizedDeviceCount: 1,
          permissionDenied: true,
        ).state,
        AdbUsbHostState.ready,
      );
    });
  });
}

AdbUsbHostStatus _status({
  int attachedDeviceCount = 0,
  int adbDeviceCount = 0,
  int authorizedDeviceCount = 0,
  bool permissionRequestPending = false,
  bool permissionDenied = false,
}) => AdbUsbHostStatus(
  attachedDeviceCount: attachedDeviceCount,
  adbDeviceCount: adbDeviceCount,
  authorizedDeviceCount: authorizedDeviceCount,
  permissionRequestPending: permissionRequestPending,
  permissionDenied: permissionDenied,
);
