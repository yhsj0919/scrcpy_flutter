import 'package:adb_client/adb_client.dart';

import 'scrcpy_video_connection.dart';

ScrcpyVideoConnector createScrcpyVideoConnector({
  required AdbClient adbClient,
  required String serverPath,
  String? expectedServerSha256,
}) => throw UnsupportedError(
  'scrcpy video connections are unavailable on this platform',
);
