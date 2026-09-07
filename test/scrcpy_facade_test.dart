import 'package:adb_client/adb_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

final class _UnusedAdbService implements AdbDeviceService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ScrcpySession _session(String id) => ScrcpySession.fromRaw(
  ScrcpyRawSession(
    id: id,
    adbDeviceService: _UnusedAdbService(),
    configuration: ScrcpySessionConfiguration(deviceSerial: 'device-$id'),
  ),
);

void main() {
  test('virtual display factory creates a portrait application display', () {
    final display = ScrcpyDisplay.virtual(application: 'com.example.music');

    expect(display, isA<ScrcpyVirtualDisplaySource>());
    final virtual = display as ScrcpyVirtualDisplaySource;
    expect(virtual.width, 720);
    expect(virtual.height, 1280);
    expect(virtual.dpi, 240);
    expect(virtual.keepActive, isTrue);
    expect(virtual.flexDisplay, isTrue);
    expect(virtual.launchApplication?.packageName, 'com.example.music');
  });

  test('display helpers create main and existing sources', () {
    expect(ScrcpyDisplay.main, isA<ScrcpyMainDisplaySource>());
    final existing = ScrcpyDisplay.existing(
      22,
      imePolicy: ScrcpyDisplayImePolicy.local,
    );
    expect(existing, isA<ScrcpyExistingDisplaySource>());
    expect((existing as ScrcpyExistingDisplaySource).displayId, 22);
    expect(existing.imePolicy, ScrcpyDisplayImePolicy.local);
  });

  test('session group has one switchable primary and stable membership', () {
    final first = _session('first');
    final second = _session('second');
    final group = ScrcpySessionGroup(
      id: 'selected',
      sessions: <ScrcpySession>[first, second, first],
      primary: first,
    );

    expect(group.sessions, <ScrcpySession>[first, second]);
    expect(group.primary, first);
    group.setPrimary(second);
    expect(group.primary, second);
    group.remove(second);
    expect(group.primary, first);

    group.dispose();
    first.dispose();
    second.dispose();
  });

  testWidgets('group view renders the primary without owning it', (
    tester,
  ) async {
    final session = _session('primary');
    final group = ScrcpySessionGroup(
      id: 'selected',
      sessions: <ScrcpySession>[session],
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScrcpyGroupView(
          group: group,
          placeholder: const SizedBox(key: Key('placeholder')),
        ),
      ),
    );
    expect(find.byKey(const Key('placeholder')), findsOneWidget);
    expect(session.state.value, ScrcpySessionState.idle);

    group.dispose();
    session.dispose();
  });
}
