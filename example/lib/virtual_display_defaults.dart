import 'dart:math' as math;

import 'package:adb_client/adb_client.dart';

/// Default virtual-display geometry used by the example application.
///
/// New displays are portrait-first. Large device resolutions are reduced
/// proportionally, including density, without changing their orientation.
final class VirtualDisplayDefaults {
  const VirtualDisplayDefaults({
    required this.width,
    required this.height,
    required this.dpi,
  });

  static const fallback = VirtualDisplayDefaults(
    width: 720,
    height: 1280,
    dpi: 240,
  );

  final int width;
  final int height;
  final int dpi;

  factory VirtualDisplayDefaults.fromDeviceDetails(
    AdbDeviceDetails details, {
    int maxLongEdge = 1280,
  }) {
    final deviceWidth = details.screenWidth;
    final deviceHeight = details.screenHeight;
    final deviceDpi = details.densityDpi;
    if (deviceWidth == null ||
        deviceWidth <= 0 ||
        deviceWidth > 16384 ||
        deviceHeight == null ||
        deviceHeight <= 0 ||
        deviceHeight > 16384 ||
        deviceDpi == null ||
        deviceDpi <= 0 ||
        deviceDpi > 10000) {
      return fallback;
    }

    final portraitWidth = math.min(deviceWidth, deviceHeight);
    final portraitHeight = math.max(deviceWidth, deviceHeight);
    final scale = math.min(1.0, maxLongEdge / portraitHeight);
    int alignEven(double value) => math.max(2, (value / 2).round() * 2);

    return VirtualDisplayDefaults(
      width: alignEven(portraitWidth * scale),
      height: alignEven(portraitHeight * scale),
      dpi: math.max(1, (deviceDpi * scale).round()),
    );
  }
}
