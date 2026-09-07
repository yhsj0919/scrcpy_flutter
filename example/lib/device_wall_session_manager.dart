import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/foundation.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

/// Example-only session view used by the device-wall composition.
final class DeviceWallManagedSession {
  const DeviceWallManagedSession._({
    required this.id,
    required this.configuration,
    required this._session,
  });

  final String id;
  final ScrcpySessionConfiguration configuration;
  final ScrcpyRawSession _session;

  String get deviceSerial => configuration.deviceSerial;
  ValueListenable<ScrcpySessionState> get state => _session.state;
  Stream<ScrcpyVideoConnection> get reconnectedConnections =>
      _session.reconnectedConnections;
}

/// Owns and coordinates multiple independent scrcpy sessions.
///
/// The manager owns the sessions and their connections. Video and audio
/// controllers created from a returned connection remain owned by the caller
/// and must be released before removing the corresponding managed session.
final class DeviceWallSessionManager extends ChangeNotifier {
  DeviceWallSessionManager({required this.client, this.maxSessions = 16}) {
    final limit = maxSessions;
    if (limit != null && limit <= 0) {
      throw RangeError.value(limit, 'maxSessions', 'must be positive');
    }
  }

  final ScrcpyClient client;
  final int? maxSessions;
  final Map<String, _ManagedSessionEntry> _entries =
      <String, _ManagedSessionEntry>{};
  int _nextId = 1;
  String? _focusedId;
  Future<void>? _closeFuture;
  bool _closing = false;
  bool _disposed = false;

  List<DeviceWallManagedSession> get sessions =>
      List<DeviceWallManagedSession>.unmodifiable(
        _entries.values.map((entry) => entry.view),
      );

  String? get focusedId => _focusedId;

  DeviceWallManagedSession? get focusedSession => session(_focusedId);

  DeviceWallManagedSession? session(String? id) =>
      id == null ? null : _entries[id]?.view;

  List<DeviceWallManagedSession> sessionsForDevice(String deviceSerial) =>
      List<DeviceWallManagedSession>.unmodifiable(
        _entries.values
            .where(
              (entry) => entry.view.configuration.deviceSerial == deviceSerial,
            )
            .map((entry) => entry.view),
      );

  Map<String, List<DeviceWallManagedSession>> get sessionsByDevice {
    final grouped = <String, List<DeviceWallManagedSession>>{};
    for (final entry in _entries.values) {
      grouped
          .putIfAbsent(
            entry.view.deviceSerial,
            () => <DeviceWallManagedSession>[],
          )
          .add(entry.view);
    }
    return Map<String, List<DeviceWallManagedSession>>.unmodifiable(
      grouped.map(
        (serial, values) => MapEntry(
          serial,
          List<DeviceWallManagedSession>.unmodifiable(values),
        ),
      ),
    );
  }

  DeviceWallManagedSession create(
    ScrcpySessionConfiguration configuration, {
    String? id,
  }) {
    _checkActive();
    configuration.validate();
    final limit = maxSessions;
    if (limit != null && _entries.length >= limit) {
      throw StateError('Session limit reached: $limit');
    }
    final resolvedId = id?.trim().isNotEmpty == true ? id!.trim() : _newId();
    if (_entries.containsKey(resolvedId)) {
      throw StateError('Session id is already registered: $resolvedId');
    }
    final session = client.createSession(configuration);
    late final _ManagedSessionEntry entry;
    void listener() {
      if (!_disposed && identical(_entries[resolvedId], entry)) {
        notifyListeners();
      }
    }

    final view = DeviceWallManagedSession._(
      id: resolvedId,
      configuration: configuration,
      session: session,
    );
    entry = _ManagedSessionEntry(view: view, listener: listener);
    _entries[resolvedId] = entry;
    session.state.addListener(listener);
    notifyListeners();
    return view;
  }

  Future<void> prepare(String id, {AdbCancellationToken? cancellationToken}) =>
      _activeEntry(id).view._session
          .prepare(cancellationToken: cancellationToken);

  Future<ScrcpyVideoConnection> start(
    String id, {
    AdbCancellationToken? cancellationToken,
  }) =>
      _activeEntry(id).view._session
          .start(cancellationToken: cancellationToken);

  Future<void> stop(String id) => _activeEntry(id).view._session.stop();

  void focus(String? id) {
    _checkActive();
    if (id != null) _activeEntry(id);
    if (_focusedId == id) return;
    _focusedId = id;
    notifyListeners();
  }

  Future<bool> remove(String id) async {
    if (_disposed) return false;
    final entry = _entries[id];
    if (entry == null) return false;
    final activeRemoval = entry.removal;
    if (activeRemoval != null) {
      await activeRemoval;
      return true;
    }
    if (_focusedId == id) _focusedId = null;
    notifyListeners();
    final removal = _remove(id, entry);
    entry.removal = removal;
    await removal;
    return true;
  }

  Future<void> _remove(String id, _ManagedSessionEntry entry) async {
    try {
      await entry.view._session.stop();
    } finally {
      entry.view._session.state.removeListener(entry.listener);
      entry.view._session.dispose();
      if (identical(_entries[id], entry)) {
        _entries.remove(id);
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<void> close() {
    if (_disposed) return Future<void>.value();
    return _closeFuture ??= _close();
  }

  Future<void> _close() async {
    _closing = true;
    final ids = _entries.keys.toList(growable: false);
    Object? firstError;
    StackTrace? firstStackTrace;
    await Future.wait<void>(
      ids.map((id) async {
        try {
          await remove(id);
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
      }),
    );
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  String _newId() {
    while (true) {
      final id = 'session-${_nextId++}';
      if (!_entries.containsKey(id)) return id;
    }
  }

  _ManagedSessionEntry _activeEntry(String id) {
    _checkActive();
    final entry = _entries[id];
    if (entry == null) {
      throw StateError('Unknown session: $id');
    }
    if (entry.removal != null) {
      throw StateError('Session is being removed: $id');
    }
    return entry;
  }

  void _checkActive() {
    if (_disposed || _closing) {
      throw StateError('Session manager is closed');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _closing = true;
    _disposed = true;
    for (final entry in _entries.values) {
      entry.view._session.state.removeListener(entry.listener);
      entry.view._session.dispose();
    }
    _entries.clear();
    _focusedId = null;
    super.dispose();
  }
}

final class _ManagedSessionEntry {
  _ManagedSessionEntry({required this.view, required this.listener});

  final DeviceWallManagedSession view;
  final VoidCallback listener;
  Future<void>? removal;
}
