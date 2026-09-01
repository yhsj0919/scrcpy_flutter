import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  test('serializes the scrcpy 4.1 32-byte touch message', () {
    final bytes = ScrcpyControlMessageSerializer.pointer(
      const ScrcpyPointerEvent(
        pointerId: 0x1234567887654321,
        action: ScrcpyPointerAction.down,
        normalizedX: 100 / 1079,
        normalizedY: 200 / 1919,
        buttons: 1,
      ),
      videoWidth: 1080,
      videoHeight: 1920,
    );

    expect(bytes, <int>[
      2,
      0,
      0x12,
      0x34,
      0x56,
      0x78,
      0x87,
      0x65,
      0x43,
      0x21,
      0,
      0,
      0,
      100,
      0,
      0,
      0,
      200,
      0x04,
      0x38,
      0x07,
      0x80,
      0xff,
      0xff,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      1,
    ]);
  });

  test('serializes key and UTF-8 text messages', () {
    expect(
      ScrcpyControlMessageSerializer.key(
        keyCode: 0x42,
        down: false,
        repeat: 5,
        metaState: 0x41,
      ),
      <int>[0, 1, 0, 0, 0, 0x42, 0, 0, 0, 5, 0, 0, 0, 0x41],
    );
    expect(ScrcpyControlMessageSerializer.text('你好'), <int>[
      1,
      0,
      0,
      0,
      6,
      0xe4,
      0xbd,
      0xa0,
      0xe5,
      0xa5,
      0xbd,
    ]);
  });

  test('serializes the scrcpy 4.1 scroll message', () {
    expect(
      ScrcpyControlMessageSerializer.scroll(
        normalizedX: 260 / 1079,
        normalizedY: 1026 / 1919,
        videoWidth: 1080,
        videoHeight: 1920,
        horizontal: 16,
        vertical: -16,
        buttons: 1,
      ),
      <int>[
        3,
        0,
        0,
        1,
        4,
        0,
        0,
        4,
        2,
        4,
        0x38,
        7,
        0x80,
        0x7f,
        0xff,
        0x80,
        0x01,
        0,
        0,
        0,
        1,
      ],
    );
  });
}
