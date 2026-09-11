import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'scrcpy_client.dart';
import 'scrcpy_capture.dart';
import 'scrcpy_audio.dart';
import 'scrcpy_display_source.dart';
import 'scrcpy_error.dart';
import 'scrcpy_input.dart';
import 'scrcpy_session.dart';
import 'scrcpy_video.dart';

/// Concise display factories for the high-level session API.
abstract final class ScrcpyDisplay {
  static const ScrcpyDisplaySource main = ScrcpyDisplaySource.main();

  static ScrcpyDisplaySource existing(
    int displayId, {
    ScrcpyDisplayImePolicy imePolicy = ScrcpyDisplayImePolicy.systemDefault,
  }) => ScrcpyDisplaySource.existing(displayId, imePolicy: imePolicy);

  static ScrcpyDisplaySource virtual({
    int width = 720,
    int height = 1280,
    int dpi = 240,
    bool systemDecorations = true,
    ScrcpyVirtualDisplayClosePolicy closePolicy =
        ScrcpyVirtualDisplayClosePolicy.destroyContent,
    ScrcpyDisplayImePolicy imePolicy = ScrcpyDisplayImePolicy.systemDefault,
    bool keepActive = true,
    bool flexible = true,
    String? application,
    bool forceStopBeforeStart = false,
  }) => ScrcpyDisplaySource.virtual(
    width: width,
    height: height,
    dpi: dpi,
    systemDecorations: systemDecorations,
    closePolicy: closePolicy,
    imePolicy: imePolicy,
    keepActive: keepActive,
    flexDisplay: flexible,
    launchApplication: application == null
        ? null
        : ScrcpyApplicationLaunch(
            application,
            forceStopBeforeStart: forceStopBeforeStart,
          ),
  );
}

/// One complete display session suitable for [ScrcpyView].
///
/// Connections, native decoders, audio sinks, and reconnect replacement are
/// owned internally. Create instances through [ScrcpyManager.createSession].
final class ScrcpySession extends ChangeNotifier {
  @visibleForTesting
  ScrcpySession.fromRaw(this._raw) {
    _raw.addListener(notifyListeners);
  }

  final ScrcpyRawSession _raw;
  bool _disposed = false;

  String get id => _raw.id;
  String get deviceSerial => _raw.deviceSerial;
  ValueListenable<ScrcpySessionState> get state => _raw.state;
  bool get isConnected => _raw.isConnected;
  bool get isControllable => _raw.isControllable;
  bool get hasAudio => _raw.hasAudio;
  bool get isRunning => _raw.video != null;

  /// Current video controller. Prefer [ScrcpyView] unless custom rendering or
  /// diagnostics require direct observation.
  ScrcpyVideoController? get video => _raw.video;

  ScrcpyAudioController? get audio => _raw.audio;
  ScrcpyInputController? get input => _raw.input;

  ScrcpyVideoController? get _video => video;
  ScrcpyInputController? get _input => input;

  Future<void> home() => _raw.home();
  Future<void> back() => _raw.back();
  Future<void> power() => _raw.power();
  Future<void> key(int keyCode) => _raw.key(keyCode);
  Future<void> sendText(String text) => _raw.sendText(text);
  Future<void> setMuted(bool muted) => _raw.setMuted(muted);
  Future<void> setVolume(double volume) => _raw.setVolume(volume);
  Future<void> startApplication(
    String packageName, {
    bool forceStopBeforeStart = false,
  }) => _raw.startApplication(
    packageName,
    forceStopBeforeStart: forceStopBeforeStart,
  );
  Future<void> resizeDisplay({required int width, required int height}) =>
      _raw.resizeDisplay(width: width, height: height);
  Future<void> pinch({required double startSpan, required double endSpan}) =>
      _raw.pinch(startSpan: startSpan, endSpan: endSpan);

  /// Captures the currently displayed frame as PNG without reconnecting.
  Future<ScrcpyScreenshot> captureFrame() {
    final controller = video;
    if (controller == null) {
      throw const ScrcpyException(
        ScrcpyErrorCode.captureFailure,
        'This session has no active video stream',
      );
    }
    return controller.captureFrame();
  }

  bool get isRecording => video?.isRecording ?? false;

  Future<void> startRecording(String path) {
    final controller = video;
    if (controller == null) {
      throw const ScrcpyException(
        ScrcpyErrorCode.recordingFailure,
        'This session has no active video stream',
      );
    }
    return controller.startRecording(path);
  }

  Future<int> stopRecording() => video?.stopRecording() ?? Future<int>.value(0);

  Future<ScrcpySession> start({AdbCancellationToken? cancellationToken}) =>
      _open(cancellationToken: cancellationToken);

  Future<void> stop() => _raw.stop();

  Future<ScrcpySession> _open({AdbCancellationToken? cancellationToken}) async {
    await _raw.open(cancellationToken: cancellationToken);
    return this;
  }

  Future<void> close() async {
    if (_disposed) return;
    _raw.removeListener(notifyListeners);
    await _raw.close();
    _disposed = true;
    super.dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _raw.removeListener(notifyListeners);
    _raw.dispose();
    super.dispose();
  }
}

/// High-level owner for complete, renderable scrcpy sessions.
final class ScrcpyManager extends ChangeNotifier {
  ScrcpyManager.fromClient(ScrcpyClient client, {this.maxSessions = 16})
    : _client = client {
    final limit = maxSessions;
    if (limit != null && limit <= 0) {
      throw RangeError.value(limit, 'maxSessions', 'must be positive');
    }
  }

  final ScrcpyClient _client;
  final int? maxSessions;

  AdbToolkit get adb => AdbToolkit(_client.adbClient);
  final Map<String, ScrcpySession> _sessions = <String, ScrcpySession>{};
  final Map<String, VoidCallback> _listeners = <String, VoidCallback>{};
  final Map<String, ScrcpySessionGroup> _groups =
      <String, ScrcpySessionGroup>{};
  var _nextId = 1;
  var _nextGroupId = 1;
  bool _closed = false;

  List<ScrcpySession> get sessions =>
      List<ScrcpySession>.unmodifiable(_sessions.values);

  ScrcpySession? session(String id) => _sessions[id];

  List<ScrcpySessionGroup> get groups =>
      List<ScrcpySessionGroup>.unmodifiable(_groups.values);

  ScrcpySessionGroup? group(String id) => _groups[id];

  List<ScrcpySession> sessionsForDevice(String deviceSerial) =>
      List<ScrcpySession>.unmodifiable(
        _sessions.values.where(
          (session) => session.deviceSerial == deviceSerial,
        ),
      );

  Future<ScrcpySession> createSession({
    required String deviceSerial,
    ScrcpyDisplaySource display = ScrcpyDisplay.main,
    ScrcpyVideoOptions video = const ScrcpyVideoOptions(),
    bool controlEnabled = true,
    bool audioEnabled = false,
    bool audioRequired = false,
    ScrcpyAudioOptions audio = const ScrcpyAudioOptions(),
    ScrcpyReconnectPolicy reconnectPolicy = const ScrcpyReconnectPolicy(
      maxAttempts: 3,
    ),
    String? id,
    AdbCancellationToken? cancellationToken,
    bool start = true,
  }) async {
    _checkActive();
    final limit = maxSessions;
    if (limit != null && _sessions.length >= limit) {
      throw StateError('Session limit reached: $limit');
    }
    final resolvedId = id?.trim().isNotEmpty == true
        ? id!.trim()
        : 'session-${_nextId++}';
    if (_sessions.containsKey(resolvedId)) {
      throw StateError('Session id is already registered: $resolvedId');
    }
    final rawSession = _client.createSession(
      ScrcpySessionConfiguration(
        deviceSerial: deviceSerial,
        video: video,
        controlEnabled: controlEnabled,
        audioEnabled: audioEnabled,
        audioRequired: audioRequired,
        audio: audio,
        displaySource: display,
        reconnectPolicy: reconnectPolicy,
      ),
      id: resolvedId,
    );
    final session = ScrcpySession.fromRaw(rawSession);
    void listener() => notifyListeners();
    _sessions[resolvedId] = session;
    _listeners[resolvedId] = listener;
    session.addListener(listener);
    notifyListeners();
    try {
      if (start) {
        await session._open(cancellationToken: cancellationToken);
      }
      return session;
    } catch (_) {
      await removeSession(resolvedId);
      rethrow;
    }
  }

  Future<ScrcpySession> createVirtualSession({
    required String deviceSerial,
    int width = 720,
    int height = 1280,
    int dpi = 240,
    String? application,
    bool audioEnabled = false,
    String? id,
  }) => createSession(
    deviceSerial: deviceSerial,
    id: id,
    audioEnabled: audioEnabled,
    display: ScrcpyDisplay.virtual(
      width: width,
      height: height,
      dpi: dpi,
      application: application,
    ),
  );

  Future<bool> removeSession(String id) async {
    final session = _sessions.remove(id);
    if (session == null) return false;
    for (final group in _groups.values.toList(growable: false)) {
      group._detach(session);
      if (group.sessions.isEmpty) {
        _groups.remove(group.id);
        group.removeListener(notifyListeners);
        group.dispose();
      }
    }
    final listener = _listeners.remove(id);
    if (listener != null) session.removeListener(listener);
    notifyListeners();
    await session.close();
    return true;
  }

  ScrcpySessionGroup createGroup({
    required Iterable<ScrcpySession> sessions,
    ScrcpySession? primary,
    String? id,
  }) {
    _checkActive();
    final members = sessions.toList(growable: false);
    if (members.isEmpty) {
      throw ArgumentError.value(members, 'sessions', 'must not be empty');
    }
    for (final member in members) {
      if (!identical(_sessions[member.id], member)) {
        throw ArgumentError(
          'Session is not owned by this manager: ${member.id}',
        );
      }
    }
    final resolvedId = id?.trim().isNotEmpty == true
        ? id!.trim()
        : 'group-${_nextGroupId++}';
    if (_groups.containsKey(resolvedId)) {
      throw StateError('Session group id is already registered: $resolvedId');
    }
    final group = ScrcpySessionGroup(
      id: resolvedId,
      sessions: members,
      primary: primary,
    );
    _groups[resolvedId] = group;
    group.addListener(notifyListeners);
    notifyListeners();
    return group;
  }

  bool removeGroup(String id) {
    final group = _groups.remove(id);
    if (group == null) return false;
    group.removeListener(notifyListeners);
    group.dispose();
    notifyListeners();
    return true;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final group in _groups.values) {
      group.removeListener(notifyListeners);
      group.dispose();
    }
    _groups.clear();
    final ids = _sessions.keys.toList(growable: false);
    await Future.wait(ids.map(removeSession));
  }

  void _checkActive() {
    if (_closed) throw StateError('ScrcpyManager is closed');
  }

  @override
  void dispose() {
    if (!_closed) {
      _closed = true;
      for (final group in _groups.values) {
        group.removeListener(notifyListeners);
        group.dispose();
      }
      _groups.clear();
      for (final entry in _sessions.entries) {
        final listener = _listeners[entry.key];
        if (listener != null) entry.value.removeListener(listener);
        entry.value.dispose();
      }
      _sessions.clear();
      _listeners.clear();
    }
    super.dispose();
  }
}

/// A set of sessions controlled through one visible primary session.
///
/// Membership selection belongs to the embedding application. Pointer target
/// snapshots and per-session input lifecycles are managed internally.
final class ScrcpySessionGroup extends ChangeNotifier {
  ScrcpySessionGroup({
    required this.id,
    required Iterable<ScrcpySession> sessions,
    ScrcpySession? primary,
  }) : _sessions = <ScrcpySession>{...sessions} {
    if (_sessions.isEmpty) {
      throw ArgumentError.value(sessions, 'sessions', 'must not be empty');
    }
    final selected = primary ?? _sessions.first;
    if (!_sessions.contains(selected)) {
      throw ArgumentError.value(primary, 'primary', 'must be a group member');
    }
    _primary = selected;
    _input = _ScrcpyGroupInputController(this);
  }

  final String id;
  final Set<ScrcpySession> _sessions;
  late ScrcpySession _primary;
  late final _ScrcpyGroupInputController _input;
  bool _disposed = false;

  List<ScrcpySession> get sessions =>
      List<ScrcpySession>.unmodifiable(_sessions);
  ScrcpySession get primary => _primary;
  bool get isEmpty => _sessions.isEmpty;

  void setPrimary(ScrcpySession session) {
    _checkActive();
    if (!_sessions.contains(session)) {
      throw ArgumentError.value(session, 'session', 'must be a group member');
    }
    if (identical(_primary, session)) return;
    _input.cancelActivePointers();
    _primary = session;
    notifyListeners();
  }

  void add(ScrcpySession session) {
    _checkActive();
    if (_sessions.add(session)) notifyListeners();
  }

  bool remove(ScrcpySession session) {
    _checkActive();
    if (!_sessions.contains(session) || _sessions.length == 1) return false;
    return _detach(session);
  }

  bool _detach(ScrcpySession session) {
    if (_disposed || !_sessions.remove(session)) return false;
    _input.removeTarget(session);
    if (_sessions.isNotEmpty && identical(_primary, session)) {
      _primary = _sessions.first;
    }
    notifyListeners();
    return true;
  }

  Future<void> home() => _forEach((session) => session.home());
  Future<void> back() => _forEach((session) => session.back());
  Future<void> power() => _forEach((session) => session.power());
  Future<void> sendText(String text) =>
      _forEach((session) => session.sendText(text));
  Future<void> setMuted(bool muted) =>
      _forEach((session) => session.setMuted(muted));
  Future<void> setVolume(double volume) =>
      _forEach((session) => session.setVolume(volume));

  Future<void> startApplication(
    String packageName, {
    bool forceStopBeforeStart = false,
  }) => _input.startApplication(
    ScrcpyApplicationLaunch(
      packageName,
      forceStopBeforeStart: forceStopBeforeStart,
    ),
  );

  Future<void> _forEach(
    Future<void> Function(ScrcpySession session) operation,
  ) async {
    _checkActive();
    final targets = _sessions.toList(growable: false);
    await Future.wait(
      targets.map((session) async {
        try {
          await operation(session);
        } catch (error) {
          debugPrint('scrcpy group $id skipped ${session.id}: $error');
        }
      }),
    );
  }

  void _checkActive() {
    if (_disposed) throw StateError('ScrcpySessionGroup is disposed: $id');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _input.dispose();
    _sessions.clear();
    super.dispose();
  }
}

final class _ScrcpyGroupInputController
    implements
        ScrcpyInputController,
        ScrcpyInputTransportStatus,
        ScrcpyScreenPowerInputController {
  _ScrcpyGroupInputController(this.group);

  final ScrcpySessionGroup group;
  final Map<int, List<ScrcpyInputController>> _pointerTargets =
      <int, List<ScrcpyInputController>>{};
  bool _disposed = false;

  @override
  bool get isAvailable => !_disposed && _currentTargets().isNotEmpty;

  List<ScrcpyInputController> _currentTargets() => group._sessions
      .map((session) => session._input)
      .whereType<ScrcpyInputController>()
      .where(_available)
      .toList();

  static bool _available(ScrcpyInputController controller) =>
      switch (controller) {
        ScrcpyInputTransportStatus status => status.isAvailable,
        _ => true,
      };

  @override
  Future<void> sendPointer(ScrcpyPointerEvent event) async {
    if (_disposed) return;
    var targets = _pointerTargets[event.pointerId];
    if (event.action == ScrcpyPointerAction.down) {
      final stale = _pointerTargets.remove(event.pointerId);
      if (stale != null) {
        await _sendPointerTo(
          stale,
          _copyPointer(event, ScrcpyPointerAction.cancel),
        );
      }
      targets = _currentTargets();
      _pointerTargets[event.pointerId] = targets;
    } else if (event.action == ScrcpyPointerAction.hover ||
        event.action == ScrcpyPointerAction.scroll) {
      targets = _currentTargets();
    }
    if (targets == null || targets.isEmpty) return;
    if (event.action == ScrcpyPointerAction.up ||
        event.action == ScrcpyPointerAction.cancel) {
      _pointerTargets.remove(event.pointerId);
    }
    await _sendPointerTo(targets, _copyPointer(event, event.action));
  }

  ScrcpyPointerEvent _copyPointer(
    ScrcpyPointerEvent event,
    ScrcpyPointerAction action,
  ) => ScrcpyPointerEvent(
    pointerId: event.pointerId,
    action: action,
    normalizedX: event.normalizedX,
    normalizedY: event.normalizedY,
    buttons: event.buttons,
    scrollDeltaX: event.scrollDeltaX,
    scrollDeltaY: event.scrollDeltaY,
  );

  Future<void> _sendPointerTo(
    Iterable<ScrcpyInputController> targets,
    ScrcpyPointerEvent event,
  ) => _isolate(
    targets.map(
      (target) =>
          () => target.sendPointer(event),
    ),
  );

  void removeTarget(ScrcpySession session) {
    final input = session._input;
    if (input == null) return;
    for (final entry in _pointerTargets.entries) {
      if (!entry.value.remove(input)) continue;
      unawaited(
        _sendPointerTo(
          <ScrcpyInputController>[input],
          ScrcpyPointerEvent(
            pointerId: entry.key,
            action: ScrcpyPointerAction.cancel,
            normalizedX: 0,
            normalizedY: 0,
            buttons: 0,
          ),
        ),
      );
    }
  }

  void cancelActivePointers() {
    final active = Map<int, List<ScrcpyInputController>>.from(_pointerTargets);
    _pointerTargets.clear();
    for (final entry in active.entries) {
      unawaited(
        _sendPointerTo(
          entry.value,
          ScrcpyPointerEvent(
            pointerId: entry.key,
            action: ScrcpyPointerAction.cancel,
            normalizedX: 0,
            normalizedY: 0,
            buttons: 0,
          ),
        ),
      );
    }
  }

  Future<void> _all(
    Future<void> Function(ScrcpyInputController input) operation,
  ) => _isolate(
    _currentTargets().map(
      (input) =>
          () => operation(input),
    ),
  );

  Future<void> _isolate(Iterable<Future<void> Function()> operations) async {
    await Future.wait(
      operations.map((operation) async {
        try {
          await operation();
        } catch (error) {
          debugPrint('scrcpy group ${group.id} input skipped: $error');
        }
      }),
    );
  }

  @override
  Future<void> sendKey({required int keyCode, bool down = true}) =>
      _all((input) => input.sendKey(keyCode: keyCode, down: down));

  @override
  Future<void> sendBackOrScreenOn({bool down = true}) => _all((input) {
    if (input case ScrcpyScreenPowerInputController screenInput) {
      return screenInput.sendBackOrScreenOn(down: down);
    }
    return input.sendKey(keyCode: ScrcpyAndroidKeyCode.back, down: down);
  });

  @override
  Future<void> sendText(String text) => _all((input) => input.sendText(text));

  @override
  Future<void> startApplication(ScrcpyApplicationLaunch application) =>
      _all((input) => input.startApplication(application));

  @override
  Future<void> resizeDisplay({required int width, required int height}) =>
      _all((input) => input.resizeDisplay(width: width, height: height));

  ScrcpyInputController? get _primaryInput => group.primary._input;

  @override
  Stream<String> get clipboardChanges =>
      _primaryInput?.clipboardChanges ?? const Stream<String>.empty();

  @override
  Future<void> requestClipboard({
    ScrcpyCopyKey copyKey = ScrcpyCopyKey.none,
  }) async => _primaryInput?.requestClipboard(copyKey: copyKey);

  @override
  Future<void> setClipboard(String text, {bool paste = false}) =>
      _all((input) => input.setClipboard(text, paste: paste));

  void dispose() {
    if (_disposed) return;
    cancelActivePointers();
    _disposed = true;
  }
}

typedef ScrcpyViewErrorBuilder = Widget Function(
  BuildContext context,
  Object? error,
);

/// Ready-to-embed video and input surface for one [ScrcpySession].
///
/// Removing this widget never closes the session; [ScrcpyManager] owns it.
final class ScrcpyView extends StatelessWidget {
  const ScrcpyView({
    required this.session,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.interactive = true,
    this.autofocus = true,
    this.captureAllKeys = false,
    this.blockHostGestures = true,
    this.gestureEdgeThreshold = 0.02,
    this.placeholder,
    this.errorBuilder,
    this.controlGroup,
    this.inputController,
    super.key,
  });

  final ScrcpySession session;
  final BoxFit fit;
  final Alignment alignment;
  final bool interactive;
  final bool autofocus;
  final bool captureAllKeys;
  final bool blockHostGestures;
  final double gestureEdgeThreshold;
  final Widget? placeholder;
  final ScrcpyViewErrorBuilder? errorBuilder;

  /// When provided, input on this view controls every session in the group.
  /// The displayed [session] should normally be [ScrcpySessionGroup.primary].
  final ScrcpySessionGroup? controlGroup;

  /// Optional input decorator for usage-side routing, logging or policies.
  /// Video and lifecycle still come from [session].
  final ScrcpyInputController? inputController;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final video = session._video;
      if (video == null) {
        if (session.state.value == ScrcpySessionState.error) {
          return errorBuilder?.call(context, null) ??
              placeholder ??
              const SizedBox.expand();
        }
        return placeholder ?? const SizedBox.expand();
      }
      return ValueListenableBuilder<ScrcpyVideoState>(
        valueListenable: video,
        builder: (context, state, _) {
          final videoSize = state.width != null && state.height != null
              ? Size(state.width!.toDouble(), state.height!.toDouble())
              : null;
          final view = ScrcpyVideoView(
            controller: video,
            fit: fit,
            alignment: alignment,
            placeholder: placeholder,
          );
          final input =
              controlGroup?._input ?? inputController ?? session._input;
          if (!interactive || input == null) return view;
          return ScrcpyInputLayer(
            controller: input,
            videoSize: videoSize,
            fit: fit,
            alignment: alignment,
            autofocus: autofocus,
            captureAllKeys: captureAllKeys,
            blockHostGestures: blockHostGestures,
            gestureEdgeThreshold: gestureEdgeThreshold,
            child: view,
          );
        },
      );
    },
  );
}

/// Shows the group's primary session and broadcasts its input to all members.
final class ScrcpyGroupView extends StatelessWidget {
  const ScrcpyGroupView({
    required this.group,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.interactive = true,
    this.autofocus = true,
    this.captureAllKeys = false,
    this.blockHostGestures = true,
    this.gestureEdgeThreshold = 0.02,
    this.placeholder,
    this.errorBuilder,
    super.key,
  });

  final ScrcpySessionGroup group;
  final BoxFit fit;
  final Alignment alignment;
  final bool interactive;
  final bool autofocus;
  final bool captureAllKeys;
  final bool blockHostGestures;
  final double gestureEdgeThreshold;
  final Widget? placeholder;
  final ScrcpyViewErrorBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: group,
    builder: (context, _) => ScrcpyView(
      session: group.primary,
      fit: fit,
      alignment: alignment,
      interactive: interactive,
      autofocus: autofocus,
      captureAllKeys: captureAllKeys,
      blockHostGestures: blockHostGestures,
      gestureEdgeThreshold: gestureEdgeThreshold,
      placeholder: placeholder,
      errorBuilder: errorBuilder,
      controlGroup: group,
    ),
  );
}
