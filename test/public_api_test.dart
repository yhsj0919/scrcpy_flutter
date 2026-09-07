import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  test('default entrypoint exposes only the ready-to-use surface', () {
    final managerFactory = createDefaultScrcpyManager;
    final display = ScrcpyDisplay.virtual(
      width: 720,
      height: 1280,
      application: 'com.example.app',
    );
    const video = ScrcpyVideoOptions(maxSize: 1280, maxFps: 30);

    expect(managerFactory, isNotNull);
    expect(display, isNotNull);
    expect(video.maxSize, 1280);
  });
}
