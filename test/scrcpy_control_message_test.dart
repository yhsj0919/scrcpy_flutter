import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  test('serializes scrcpy BACK_OR_SCREEN_ON messages', () {
    expect(ScrcpyControlMessageSerializer.backOrScreenOn(down: true), <int>[
      4,
      0,
    ]);
    expect(ScrcpyControlMessageSerializer.backOrScreenOn(down: false), <int>[
      4,
      1,
    ]);
  });

  test('serializes the scrcpy well-known mouse pointer id', () {
    final data = ScrcpyControlMessageSerializer.pointer(
      const ScrcpyPointerEvent(
        pointerId: ScrcpyPointerId.mouse,
        action: ScrcpyPointerAction.down,
        normalizedX: 0.5,
        normalizedY: 0.5,
        buttons: 1,
      ),
      videoWidth: 1080,
      videoHeight: 1920,
    );

    expect(
      ByteData.sublistView(data).getUint64(2, Endian.big),
      0xffffffffffffffff,
    );
  });

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

  test('serializes scrcpy 4.1 clipboard control messages', () {
    expect(
      ScrcpyControlMessageSerializer.getClipboard(copyKey: ScrcpyCopyKey.cut),
      <int>[8, 2],
    );
    expect(
      ScrcpyControlMessageSerializer.setClipboard(
        text: 'aé',
        sequence: 0x0102030405060708,
        paste: true,
      ),
      <int>[9, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0, 0, 0, 3, 0x61, 0xc3, 0xa9],
    );
  });

  test('serializes scrcpy 4.1 START_APP control message', () {
    expect(
      ScrcpyControlMessageSerializer.startApplication('+com.example.app'),
      <int>[
        16,
        16,
        0x2b,
        0x63,
        0x6f,
        0x6d,
        0x2e,
        0x65,
        0x78,
        0x61,
        0x6d,
        0x70,
        0x6c,
        0x65,
        0x2e,
        0x61,
        0x70,
        0x70,
      ],
    );
    expect(
      () => ScrcpyControlMessageSerializer.startApplication(''),
      throwsArgumentError,
    );
    expect(
      () => ScrcpyControlMessageSerializer.startApplication('a' * 256),
      throwsArgumentError,
    );
  });

  test('serializes scrcpy 4.1 RESIZE_DISPLAY control message', () {
    expect(
      ScrcpyControlMessageSerializer.resizeDisplay(width: 1280, height: 720),
      <int>[21, 0x05, 0x00, 0x02, 0xd0],
    );
    expect(
      () => ScrcpyControlMessageSerializer.resizeDisplay(width: 0, height: 1),
      throwsRangeError,
    );
  });

  test('parses fragmented and coalesced device clipboard messages', () {
    final parser = ScrcpyDeviceMessageParser();

    expect(parser.add(<int>[0, 0, 0]), isEmpty);
    final messages = parser.add(<int>[
      0,
      3,
      0x61,
      0xc3,
      0xa9,
      1,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ]);

    expect(messages, hasLength(2));
    expect((messages[0] as ScrcpyClipboardMessage).text, 'aé');
    expect(
      (messages[1] as ScrcpyClipboardAckMessage).sequence,
      0x0102030405060708,
    );
  });

  test('rejects oversized and unknown device messages', () {
    final oversized = ScrcpyDeviceMessageParser();
    expect(() => oversized.add(<int>[0, 0, 4, 0, 0]), throwsFormatException);
    expect(
      () => ScrcpyDeviceMessageParser().add(<int>[99]),
      throwsFormatException,
    );
  });
}
