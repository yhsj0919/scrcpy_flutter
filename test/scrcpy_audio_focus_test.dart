import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

final class _FakeAudioController extends ChangeNotifier
    implements ScrcpyAudioController {
  ScrcpyAudioState state = const ScrcpyAudioState(
    status: ScrcpyAudioStatus.ready,
  );
  final List<bool> muteCalls = <bool>[];
  bool endOnNextMute = false;

  @override
  ScrcpyAudioState get value => state;

  @override
  Future<void> setMuted(bool muted) async {
    muteCalls.add(muted);
    state = ScrcpyAudioState(
      status: endOnNextMute ? ScrcpyAudioStatus.ended : state.status,
      muted: muted,
      volume: state.volume,
    );
    endOnNextMute = false;
    notifyListeners();
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  void emitStatus(ScrcpyAudioStatus status) {
    state = ScrcpyAudioState(
      status: status,
      muted: state.muted,
      volume: state.volume,
    );
    notifyListeners();
  }
}

void main() {
  test('only the focused participant is audible', () async {
    final first = _FakeAudioController();
    final second = _FakeAudioController();
    final manager = ScrcpyAudioFocusManager();

    await manager.register(id: 'first', controller: first, requestFocus: true);
    await manager.register(id: 'second', controller: second);
    expect(manager.focusedId, 'first');
    expect(first.value.muted, isFalse);
    expect(second.value.muted, isTrue);

    await manager.requestFocus('second');
    expect(first.value.muted, isTrue);
    expect(second.value.muted, isFalse);
    expect(manager.focusedId, 'second');
    await manager.close();
    manager.dispose();
  });

  test('preserves user mute while focus changes', () async {
    final first = _FakeAudioController();
    final second = _FakeAudioController();
    final manager = ScrcpyAudioFocusManager();
    await manager.register(id: 'first', controller: first, requestFocus: true);
    await manager.register(id: 'second', controller: second);

    await manager.setMuted('first', true);
    await manager.requestFocus('second');
    await manager.requestFocus('first');
    expect(first.value.muted, isTrue);
    expect(second.value.muted, isTrue);
    await manager.close();
    manager.dispose();
  });

  test('unregistering focus leaves every participant muted', () async {
    final first = _FakeAudioController();
    final second = _FakeAudioController();
    final manager = ScrcpyAudioFocusManager();
    await manager.register(id: 'first', controller: first, requestFocus: true);
    await manager.register(id: 'second', controller: second);

    await manager.unregister('first');
    expect(manager.focusedId, isNull);
    expect(second.value.muted, isTrue);
    expect(manager.registeredIds, <String>['second']);
    await manager.close();
    manager.dispose();
  });

  test('ended focused participant is released automatically', () async {
    final first = _FakeAudioController();
    final second = _FakeAudioController();
    final manager = ScrcpyAudioFocusManager();
    await manager.register(id: 'first', controller: first, requestFocus: true);
    await manager.register(id: 'second', controller: second);

    first.emitStatus(ScrcpyAudioStatus.ended);
    await Future<void>.delayed(Duration.zero);

    expect(manager.focusedId, isNull);
    expect(manager.registeredIds, <String>['second']);
    expect(second.value.muted, isTrue);
    await manager.close();
    manager.dispose();
  });

  test(
    'conditional focus ignores a participant removed by lifecycle',
    () async {
      final controller = _FakeAudioController();
      final manager = ScrcpyAudioFocusManager();
      await manager.register(
        id: 'participant',
        controller: controller,
        requestFocus: true,
      );
      await manager.unregister('participant');

      expect(await manager.tryRequestFocus('participant'), isFalse);
      expect(manager.focusedId, isNull);
      await manager.close();
      manager.dispose();
    },
  );

  test(
    'focus operations tolerate controller removal during notification',
    () async {
      final first = _FakeAudioController();
      final second = _FakeAudioController();
      final manager = ScrcpyAudioFocusManager();
      await manager.register(id: 'first', controller: first);
      await manager.register(id: 'second', controller: second);
      first.endOnNextMute = true;

      await manager.clearFocus();

      expect(manager.registeredIds, <String>['second']);
      expect(manager.focusedId, isNull);
      await manager.close();
      manager.dispose();
    },
  );
}
