import 'dart:async';

import 'package:flutter/foundation.dart';

import 'scrcpy_audio.dart';

/// Coordinates audio playback across independently owned scrcpy sessions.
///
/// Controllers remain owned by their sessions. Once registered, mute changes
/// should go through this manager so a user's mute preference is preserved
/// while focus moves between windows.
final class ScrcpyAudioFocusManager extends ChangeNotifier {
  final Map<String, _AudioFocusEntry> _entries = <String, _AudioFocusEntry>{};
  Future<void> _operations = Future<void>.value();
  String? _focusedId;
  bool _closing = false;
  bool _disposed = false;

  String? get focusedId => _focusedId;
  List<String> get registeredIds => List<String>.unmodifiable(_entries.keys);

  bool isFocused(String id) => _focusedId == id;

  bool isRegistered(String id) => _entries.containsKey(id);

  Future<void> register({
    required String id,
    required ScrcpyAudioController controller,
    bool muted = false,
    bool requestFocus = false,
  }) {
    _checkActive();
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    if (_entries.containsKey(id)) {
      throw StateError('Audio focus participant already registered: $id');
    }
    void listener() => _handleControllerState(id);
    final entry = _AudioFocusEntry(controller, muted, listener);
    _entries[id] = entry;
    controller.addListener(listener);
    return _enqueue(() async {
      try {
        if (requestFocus) {
          await _applyFocus(id);
        } else {
          await controller.setMuted(true);
          _notify();
        }
      } catch (_) {
        if (identical(_entries[id], entry)) {
          _entries.remove(id);
          controller.removeListener(listener);
        }
        rethrow;
      }
    });
  }

  Future<void> requestFocus(String id) {
    _checkActive();
    if (!_entries.containsKey(id)) {
      throw StateError('Unknown audio focus participant: $id');
    }
    return _enqueue(() => _applyFocus(id));
  }

  /// Requests focus only while [id] is still registered.
  ///
  /// This is intended for UI events which may race with an audio stream ending
  /// or a session reconnect. It returns false instead of reporting a lifecycle
  /// race as an application error.
  Future<bool> tryRequestFocus(String id) async {
    if (_disposed || _closing || !_entries.containsKey(id)) return false;
    var applied = false;
    await _enqueue(() async {
      if (!_entries.containsKey(id)) return;
      await _applyFocus(id);
      applied = true;
    });
    return applied;
  }

  Future<void> setMuted(String id, bool muted) {
    _checkActive();
    final entry = _entries[id];
    if (entry == null) {
      throw StateError('Unknown audio focus participant: $id');
    }
    entry.userMuted = muted;
    return _enqueue(() async {
      if (!identical(_entries[id], entry)) return;
      await entry.controller.setMuted(_focusedId == id ? muted : true);
      if (identical(_entries[id], entry)) _notify();
    });
  }

  Future<void> unregister(String id) {
    if (_disposed) return Future<void>.value();
    final entry = _entries.remove(id);
    if (entry == null) return Future<void>.value();
    entry.controller.removeListener(entry.listener);
    if (_focusedId == id) _focusedId = null;
    _notify();
    return _enqueue(() async {
      try {
        await entry.controller.setMuted(true);
      } catch (_) {
        // A disconnected or already disposed audio sink cannot be muted.
      }
    });
  }

  Future<void> clearFocus() {
    if (_disposed) return Future<void>.value();
    return _enqueue(() async {
      final entries = _entries.entries.toList(growable: false);
      _focusedId = null;
      for (final item in entries) {
        if (identical(_entries[item.key], item.value)) {
          await item.value.controller.setMuted(true);
        }
      }
      _notify();
    });
  }

  Future<void> close() async {
    if (_disposed || _closing) return;
    _closing = true;
    final ids = _entries.keys.toList(growable: false);
    for (final id in ids) {
      await unregister(id);
    }
    _disposed = true;
  }

  void _handleControllerState(String id) {
    final entry = _entries[id];
    if (entry == null) return;
    final status = entry.controller.value.status;
    if (status == ScrcpyAudioStatus.ended ||
        status == ScrcpyAudioStatus.error) {
      unawaited(unregister(id));
    }
  }

  Future<void> _applyFocus(String id) async {
    final target = _entries[id];
    if (target == null) return;
    // Do not leave a stale focused id visible if switching focus fails midway.
    final hadFocus = _focusedId != null;
    _focusedId = null;
    if (hadFocus) _notify();
    final entries = _entries.entries.toList(growable: false);
    for (final item in entries) {
      if (item.key != id && identical(_entries[item.key], item.value)) {
        await item.value.controller.setMuted(true);
      }
    }
    if (!identical(_entries[id], target)) return;
    await target.controller.setMuted(target.userMuted);
    if (!identical(_entries[id], target)) return;
    _focusedId = id;
    _notify();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _operations
        .catchError((Object _) {})
        .then((_) => operation());
    _operations = result;
    return result;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkActive() {
    if (_disposed || _closing) {
      throw StateError('Audio focus manager is closed');
    }
  }

  @override
  void dispose() {
    _closing = true;
    _disposed = true;
    for (final entry in _entries.values) {
      entry.controller.removeListener(entry.listener);
    }
    _entries.clear();
    super.dispose();
  }
}

final class _AudioFocusEntry {
  _AudioFocusEntry(this.controller, this.userMuted, this.listener);

  final ScrcpyAudioController controller;
  final VoidCallback listener;
  bool userMuted;
}
