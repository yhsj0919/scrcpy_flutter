import 'package:flutter_test/flutter_test.dart';
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

void main() {
  test('logger redacts structured sensitive fields by default', () {
    ScrcpyLogRecord? captured;
    final logger = ScrcpyLogger((record) => captured = record);

    logger.log(
      level: ScrcpyLogLevel.info,
      source: 'adb',
      message: 'pair requested',
      sessionId: 'session-1',
      fields: const <String, Object?>{
        'deviceSerial': 'secret-device',
        'pairing_code': '123456',
        'elapsedMs': 12,
      },
    );

    expect(captured?.fields['deviceSerial'], '<redacted>');
    expect(captured?.fields['pairing_code'], '<redacted>');
    expect(captured?.fields['elapsedMs'], 12);
    expect(captured?.sessionId, 'session-1');
  });

  test('errors expose stable machine-readable codes', () {
    const adb = AdbException(AdbErrorCode.timedOut, 'timeout');
    const scrcpy = ScrcpyException(
      ScrcpyErrorCode.protocolFailure,
      'bad packet',
    );

    expect(adb.code, AdbErrorCode.timedOut);
    expect(scrcpy.code, ScrcpyErrorCode.protocolFailure);
  });
}
