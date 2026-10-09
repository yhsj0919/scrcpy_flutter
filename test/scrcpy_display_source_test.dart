import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

void main() {
  test('main display keeps the historical default server arguments', () {
    const source = ScrcpyDisplaySource.main();

    expect(source.toServerArguments(), isEmpty);
    expect(source.validate, returnsNormally);
  });

  test('existing display serializes id and optional IME policy', () {
    const source = ScrcpyDisplaySource.existing(
      7,
      imePolicy: ScrcpyDisplayImePolicy.local,
    );

    expect(source.toServerArguments(), <String>[
      'display_id=7',
      'display_ime_policy=local',
    ]);
  });

  test('virtual display serializes all scrcpy 5.0.1 display options', () {
    const source = ScrcpyVirtualDisplaySource(
      width: 1280,
      height: 720,
      dpi: 240,
      systemDecorations: false,
      closePolicy: ScrcpyVirtualDisplayClosePolicy.moveContentToMainDisplay,
      imePolicy: ScrcpyDisplayImePolicy.hide,
      keepActive: true,
      flexDisplay: true,
      launchApplication: ScrcpyApplicationLaunch(
        'com.example.app',
        forceStopBeforeStart: true,
      ),
    );

    expect(source.toServerArguments(), <String>[
      'new_display=1280x720/240',
      'vd_destroy_content=false',
      'vd_system_decorations=false',
      'display_ime_policy=hide',
      'keep_active=true',
      'flex_display=true',
    ]);
    expect(source.launchApplication?.controlName, '+com.example.app');
  });

  test('virtual display supports server defaults and dpi-only form', () {
    expect(
      const ScrcpyDisplaySource.virtual().toServerArguments().first,
      'new_display=',
    );
    expect(
      const ScrcpyDisplaySource.virtual(dpi: 320).toServerArguments().first,
      'new_display=/320',
    );
  });

  test('display source rejects invalid combinations', () {
    expect(
      () => const ScrcpyDisplaySource.existing(-1).validate(),
      throwsRangeError,
    );
    expect(
      () => const ScrcpyDisplaySource.virtual(width: 1280).validate(),
      throwsArgumentError,
    );
    expect(
      () => const ScrcpyDisplaySource.virtual(dpi: 0).validate(),
      throwsRangeError,
    );
    expect(
      () => const ScrcpyApplicationLaunch('bad package').validate(),
      throwsArgumentError,
    );
  });

  test('launching an app requires a control channel', () {
    const configuration = ScrcpySessionConfiguration(
      deviceSerial: 'device',
      controlEnabled: false,
      displaySource: ScrcpyDisplaySource.virtual(
        launchApplication: ScrcpyApplicationLaunch('com.example.app'),
      ),
    );

    expect(configuration.validate, throwsArgumentError);
  });
}
