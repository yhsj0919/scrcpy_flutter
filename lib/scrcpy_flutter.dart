
import 'scrcpy_flutter_platform_interface.dart';

class ScrcpyFlutter {
  Future<String?> getPlatformVersion() {
    return ScrcpyFlutterPlatform.instance.getPlatformVersion();
  }
}
