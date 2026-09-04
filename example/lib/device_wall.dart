import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

import 'virtual_display_defaults.dart';

class DeviceWallPage extends StatefulWidget {
  const DeviceWallPage({
    required this.client,
    required this.devices,
    super.key,
  });

  final ScrcpyClient client;
  final List<AdbDevice> devices;

  @override
  State<DeviceWallPage> createState() => _DeviceWallPageState();
}

class _DeviceWallPageState extends State<DeviceWallPage> {
  late final ScrcpySessionManager _sessions;
  final ScrcpyAudioFocusManager _audioFocus = ScrcpyAudioFocusManager();
  late final List<_DeviceWallWindow> _windows;
  final GlobalKey _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _cellKeys = <String, GlobalKey>{};
  final Set<String> _visibleWindowIds = <String>{};
  bool _visibilityUpdateScheduled = false;
  _DeviceWallQualityPolicy _qualityPolicy = _DeviceWallQualityPolicy.defaults;
  int _qualityRevision = 0;
  int _nextVirtualId = 1;
  String? _expandedId;

  @override
  void initState() {
    super.initState();
    _sessions = ScrcpySessionManager(client: widget.client);
    _windows = <_DeviceWallWindow>[
      for (final device in widget.devices)
        _DeviceWallWindow(
          id: 'wall-${device.redactedSerial}',
          device: device,
          title: device.model ?? device.device ?? 'Android 设备',
          displaySource: const ScrcpyDisplaySource.main(),
        ),
    ];
    _visibleWindowIds.addAll(_windows.map((window) => window.id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _windows.isNotEmpty) {
        _focus(_windows.first.id);
      }
    });
  }

  @override
  void dispose() {
    _audioFocus.dispose();
    _sessions.dispose();
    super.dispose();
  }

  void _focus(String id) {
    _sessions.focus(id);
    final window = _windows.where((item) => item.id == id).firstOrNull;
    if (window != null) {
      unawaited(_audioFocus.tryRequestFocus(window.audioFocusId));
    }
    if (mounted) setState(() {});
  }

  void _scheduleVisibilityUpdate() {
    if (_visibilityUpdateScheduled) return;
    _visibilityUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityUpdateScheduled = false;
      if (!mounted) return;
      final viewport = _viewportKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) return;
      final viewportOrigin = viewport.localToGlobal(Offset.zero);
      final viewportRect = viewportOrigin & viewport.size;
      final visible = <String>{};
      for (final window in _windows) {
        final renderObject = _cellKeys[window.id]?.currentContext
            ?.findRenderObject();
        if (renderObject is! RenderBox || !renderObject.hasSize) continue;
        final origin = renderObject.localToGlobal(Offset.zero);
        final rect = origin & renderObject.size;
        if (!rect.isEmpty && rect.overlaps(viewportRect)) {
          visible.add(window.id);
        }
      }
      if (setEquals(visible, _visibleWindowIds)) return;
      setState(() {
        _visibleWindowIds
          ..clear()
          ..addAll(visible);
      });
    });
  }

  _DeviceWallQualityTier _qualityTier(String id) {
    if (_sessions.focusedId == id) return _DeviceWallQualityTier.focused;
    if (_visibleWindowIds.contains(id)) return _DeviceWallQualityTier.visible;
    return _DeviceWallQualityTier.offscreen;
  }

  Future<void> _configureQualityPolicy() async {
    final policy = await showDialog<_DeviceWallQualityPolicy>(
      context: context,
      builder: (_) => _QualityPolicyDialog(initialValue: _qualityPolicy),
    );
    if (!mounted || policy == null || policy == _qualityPolicy) return;
    setState(() {
      _qualityPolicy = policy;
      _qualityRevision++;
    });
  }

  Future<void> _addVirtualApplication() async {
    final limit = _sessions.maxSessions;
    if (limit != null && _windows.length >= limit) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('最多可同时打开 $limit 个窗口')));
      return;
    }
    final device = await showDialog<AdbDevice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择目标设备'),
        children: <Widget>[
          for (final device in widget.devices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, device),
              child: ListTile(
                leading: const Icon(Icons.phone_android),
                title: Text(device.model ?? device.device ?? 'Android 设备'),
                subtitle: Text(device.redactedSerial),
              ),
            ),
        ],
      ),
    );
    if (!mounted || device == null) return;
    final displayDefaultsFuture = _loadDisplayDefaults(device);
    List<AdbApplication> applications;
    try {
      applications = (await widget.client.listApplications(device.serial))
          .where((application) => application.enabled && application.launchable)
          .toList(growable: false);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取应用失败：$error')));
      }
      return;
    }
    if (!mounted) return;
    if (applications.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该设备没有可启动的应用')));
      return;
    }
    final application = await showDialog<AdbApplication>(
      context: context,
      builder: (context) => _ApplicationPicker(applications: applications),
    );
    if (!mounted || application == null) return;
    final displayDefaults = await displayDefaultsFuture;
    if (!mounted) return;
    final id = 'wall-virtual-${_nextVirtualId++}';
    setState(() {
      _windows.add(
        _DeviceWallWindow(
          id: id,
          device: device,
          title: application.name,
          displaySource: ScrcpyDisplaySource.virtual(
            width: displayDefaults.width,
            height: displayDefaults.height,
            dpi: displayDefaults.dpi,
            keepActive: true,
            flexDisplay: true,
            launchApplication: ScrcpyApplicationLaunch(application.packageName),
          ),
        ),
      );
      _visibleWindowIds.add(id);
    });
    _scheduleVisibilityUpdate();
  }

  Future<VirtualDisplayDefaults> _loadDisplayDefaults(AdbDevice device) async {
    try {
      final details = await AdbToolkit(widget.client.adbClient)
          .getDeviceDetails(device);
      return VirtualDisplayDefaults.fromDeviceDetails(details);
    } catch (_) {
      // Device details are best-effort. Keep application launching available
      // on vendor ROMs which do not expose wm size or density to shell.
    }
    return VirtualDisplayDefaults.fallback;
  }

  void _removeWindow(_DeviceWallWindow window) {
    setState(() {
      _windows.remove(window);
      _visibleWindowIds.remove(window.id);
      _cellKeys.remove(window.id);
      if (_expandedId == window.id) _expandedId = null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('设备墙 · ${widget.devices.length} 台 · ${_windows.length} 个窗口'),
      actions: <Widget>[
        IconButton(
          tooltip: '画质调度设置',
          onPressed: _configureQualityPolicy,
          icon: const Icon(Icons.tune),
        ),
        if (_expandedId != null)
          TextButton.icon(
            onPressed: () => setState(() => _expandedId = null),
            icon: const Icon(Icons.grid_view),
            label: const Text('返回设备墙'),
          ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _addVirtualApplication,
      icon: const Icon(Icons.add_to_queue),
      label: const Text('添加应用窗口'),
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        _scheduleVisibilityUpdate();
        const spacing = 12.0;
        final columns = switch (constraints.maxWidth) {
          >= 1800 => 4,
          >= 1200 => 3,
          >= 720 => 2,
          _ => 1,
        };
        final tileWidth =
            (constraints.maxWidth - 32 - spacing * (columns - 1)) / columns;
        return SizedBox(
          key: _viewportKey,
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _scheduleVisibilityUpdate();
              return false;
            },
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: <Widget>[
                  for (final window in _windows)
                    Visibility(
                      visible: _expandedId == null || _expandedId == window.id,
                      maintainState: true,
                      maintainAnimation: true,
                      child: SizedBox(
                        key: _cellKeys.putIfAbsent(window.id, GlobalKey.new),
                        width: _expandedId == null
                            ? tileWidth
                            : constraints.maxWidth - 32,
                        child: KeyedSubtree(
                          key: ValueKey('device-wall-cell-${window.id}'),
                          child: _DeviceWallTile(
                            key: ValueKey(window.id),
                            manager: _sessions,
                            audioFocus: _audioFocus,
                            window: window,
                            focused: _sessions.focusedId == window.id,
                            expanded: _expandedId == window.id,
                            qualityTier: _qualityTier(window.id),
                            qualityProfile: _qualityPolicy.profileFor(
                              _qualityTier(window.id),
                            ),
                            qualityRevision: _qualityRevision,
                            onFocus: () => _focus(window.id),
                            onToggleExpanded: () {
                              final id = window.id;
                              _sessions.focus(id);
                              unawaited(
                                _audioFocus.tryRequestFocus(
                                  window.audioFocusId,
                                ),
                              );
                              setState(() {
                                _expandedId = _expandedId == id ? null : id;
                              });
                            },
                            onClose: window.isVirtual
                                ? () => _removeWindow(window)
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

final class _DeviceWallWindow {
  const _DeviceWallWindow({
    required this.id,
    required this.device,
    required this.title,
    required this.displaySource,
  });

  final String id;
  final AdbDevice device;
  final String title;
  final ScrcpyDisplaySource displaySource;

  bool get isVirtual => displaySource is ScrcpyVirtualDisplaySource;

  String get audioFocusId => 'device-audio:${device.serial}';
}

enum _DeviceWallQualityTier {
  focused('聚焦'),
  visible('可见'),
  offscreen('离屏');

  const _DeviceWallQualityTier(this.label);

  final String label;
}

final class _DeviceWallQualityProfile {
  const _DeviceWallQualityProfile({
    required this.maxSize,
    required this.maxFps,
    required this.bitRateMbps,
  });

  final int maxSize;
  final int maxFps;
  final double bitRateMbps;

  int get bitRate => (bitRateMbps * 1000000).round();

  @override
  bool operator ==(Object other) =>
      other is _DeviceWallQualityProfile &&
      maxSize == other.maxSize &&
      maxFps == other.maxFps &&
      bitRateMbps == other.bitRateMbps;

  @override
  int get hashCode => Object.hash(maxSize, maxFps, bitRateMbps);
}

final class _DeviceWallQualityPolicy {
  const _DeviceWallQualityPolicy({
    required this.focused,
    required this.visible,
    required this.offscreen,
  });

  static const defaults = _DeviceWallQualityPolicy(
    focused: _DeviceWallQualityProfile(
      maxSize: 1280,
      maxFps: 30,
      bitRateMbps: 4,
    ),
    visible: _DeviceWallQualityProfile(
      maxSize: 960,
      maxFps: 20,
      bitRateMbps: 2.5,
    ),
    offscreen: _DeviceWallQualityProfile(
      maxSize: 640,
      maxFps: 10,
      bitRateMbps: 1.5,
    ),
  );

  final _DeviceWallQualityProfile focused;
  final _DeviceWallQualityProfile visible;
  final _DeviceWallQualityProfile offscreen;

  _DeviceWallQualityProfile profileFor(_DeviceWallQualityTier tier) =>
      switch (tier) {
        _DeviceWallQualityTier.focused => focused,
        _DeviceWallQualityTier.visible => visible,
        _DeviceWallQualityTier.offscreen => offscreen,
      };

  @override
  bool operator ==(Object other) =>
      other is _DeviceWallQualityPolicy &&
      focused == other.focused &&
      visible == other.visible &&
      offscreen == other.offscreen;

  @override
  int get hashCode => Object.hash(focused, visible, offscreen);
}

class _DeviceWallTile extends StatefulWidget {
  const _DeviceWallTile({
    required this.manager,
    required this.audioFocus,
    required this.window,
    required this.focused,
    required this.expanded,
    required this.qualityTier,
    required this.qualityProfile,
    required this.qualityRevision,
    required this.onFocus,
    required this.onToggleExpanded,
    this.onClose,
    super.key,
  });

  final ScrcpySessionManager manager;
  final ScrcpyAudioFocusManager audioFocus;
  final _DeviceWallWindow window;
  final bool focused;
  final bool expanded;
  final _DeviceWallQualityTier qualityTier;
  final _DeviceWallQualityProfile qualityProfile;
  final int qualityRevision;
  final VoidCallback onFocus;
  final VoidCallback onToggleExpanded;
  final VoidCallback? onClose;

  @override
  State<_DeviceWallTile> createState() => _DeviceWallTileState();
}

class _DeviceWallTileState extends State<_DeviceWallTile> {
  late ScrcpyManagedSession _session;
  StreamSubscription<ScrcpyVideoConnection>? _reconnectSubscription;
  Future<void> _connectionChange = Future<void>.value();
  Timer? _qualityTimer;
  late _DeviceWallQualityTier _appliedQualityTier = widget.qualityTier;
  late _DeviceWallQualityProfile _appliedQualityProfile = widget.qualityProfile;
  ScrcpyVideoController? _video;
  ScrcpyAudioController? _audio;
  ScrcpyInputController? _input;
  Object? _error;
  Object? _audioError;
  int _reconnectCount = 0;
  bool _disposing = false;
  bool _disconnectCleanupQueued = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _session = _createManagedSession(_appliedQualityProfile);
    widget.audioFocus.addListener(_handleChanged);
    _session.state.addListener(_handleChanged);
    _bindReconnects();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  ScrcpyManagedSession _createManagedSession(
    _DeviceWallQualityProfile qualityProfile,
  ) => widget.manager.create(
    ScrcpySessionConfiguration(
      deviceSerial: widget.window.device.serial,
      displaySource: widget.window.displaySource,
      video: ScrcpyVideoOptions(
        maxSize: qualityProfile.maxSize,
        maxFps: qualityProfile.maxFps,
        bitRate: qualityProfile.bitRate,
      ),
      // Android playback capture belongs to the physical device, not to a
      // display. Its main-screen session owns the single shared audio stream.
      audioEnabled: !widget.window.isVirtual,
      audio: ScrcpyAudioOptions(
        codec: ScrcpyAudioCodec.opus,
        source: widget.window.isVirtual
            ? ScrcpyAudioSource.playback
            : ScrcpyAudioSource.automatic,
        duplicateOnDevice: false,
      ),
      reconnectPolicy: const ScrcpyReconnectPolicy(maxAttempts: 5),
    ),
    id: widget.window.id,
  );

  void _bindReconnects() {
    _reconnectSubscription = _session.reconnectedConnections.listen(
      (connection) =>
          unawaited(_queueConnection(connection, isReconnect: true)),
      onError: (Object error) {
        if (mounted) setState(() => _error = error);
      },
    );
  }

  @override
  void didUpdateWidget(covariant _DeviceWallTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Focus and visibility change frequently while the wall scrolls. Keep the
    // stream alive; only explicitly applying settings may rebuild a session.
    if (oldWidget.qualityRevision != widget.qualityRevision) {
      _qualityTimer?.cancel();
      _qualityTimer = Timer(const Duration(milliseconds: 600), () {
        if (mounted) {
          unawaited(
            _applyQualityTier(widget.qualityTier, widget.qualityProfile),
          );
        }
      });
    }
  }

  void _handleChanged() {
    final state = _session.state.value;
    if ((state == ScrcpySessionState.disconnected ||
            state == ScrcpySessionState.error) &&
        !_disconnectCleanupQueued) {
      _disconnectCleanupQueued = true;
      _connectionChange = _connectionChange
          .catchError((Object _) {})
          .then((_) => _releaseControllers());
    }
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    try {
      final connection = await widget.manager.start(widget.window.id);
      await _queueConnection(connection);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _queueConnection(
    ScrcpyVideoConnection connection, {
    bool isReconnect = false,
  }) {
    final operation = _connectionChange.catchError((Object _) {}).then((
      _,
    ) async {
      if (_disposing) {
        await connection.close();
        return;
      }
      await _attachConnection(connection, isReconnect: isReconnect);
    });
    _connectionChange = operation;
    return operation;
  }

  Future<void> _attachConnection(
    ScrcpyVideoConnection connection, {
    required bool isReconnect,
  }) async {
    await _releaseControllers();
    ScrcpyVideoController? video;
    ScrcpyAudioController? audio;
    try {
      video = createNativeScrcpyVideoController(connection);
      await video.start();
      if (!mounted) {
        video.dispose();
        await connection.close();
        return;
      }
      video.addListener(_handleChanged);
      setState(() {
        _disconnectCleanupQueued = false;
        _video = video;
        _input = connection.input;
        _error = null;
        _audioError = null;
        if (isReconnect) _reconnectCount++;
      });

      final stream = connection.audio;
      if (widget.window.isVirtual) return;
      if (stream == null) {
        if (mounted) setState(() => _audioError = '设备未提供音频流');
        return;
      }
      audio = createNativeScrcpyAudioController(stream);
      await audio.setMuted(true);
      await audio.start();
      await widget.audioFocus.register(
        id: widget.window.audioFocusId,
        controller: audio,
        requestFocus:
            widget.manager.focusedId == widget.window.id ||
            widget.audioFocus.focusedId == null,
      );
      if (!mounted) {
        await widget.audioFocus.unregister(widget.window.audioFocusId);
        await audio.stop();
        audio.dispose();
        return;
      }
      audio.addListener(_handleChanged);
      setState(() => _audio = audio);
    } catch (error) {
      if (!identical(_video, video)) {
        try {
          await video?.stop();
        } catch (_) {}
        video?.dispose();
      }
      if (!identical(_audio, audio)) {
        try {
          await audio?.stop();
        } catch (_) {}
        audio?.dispose();
      }
      if (mounted) {
        setState(() {
          if (_video == null) {
            _error = error;
          } else {
            _audioError = error;
          }
        });
      }
    }
  }

  Future<void> _applyQualityTier(
    _DeviceWallQualityTier qualityTier,
    _DeviceWallQualityProfile qualityProfile,
  ) async {
    if (_disposing ||
        (qualityTier == _appliedQualityTier &&
            qualityProfile == _appliedQualityProfile)) {
      return;
    }
    final operation = _connectionChange.catchError((Object _) {}).then((
      _,
    ) async {
      if (_disposing ||
          (qualityTier == _appliedQualityTier &&
              qualityProfile == _appliedQualityProfile)) {
        return;
      }
      await _releaseControllers();
      await _reconnectSubscription?.cancel();
      _reconnectSubscription = null;
      _session.state.removeListener(_handleChanged);
      await widget.manager.remove(widget.window.id);
      if (_disposing) return;

      _session = _createManagedSession(qualityProfile);
      _appliedQualityTier = qualityTier;
      _appliedQualityProfile = qualityProfile;
      _disconnectCleanupQueued = false;
      _session.state.addListener(_handleChanged);
      _bindReconnects();
      if (widget.focused) widget.manager.focus(widget.window.id);
      final connection = await widget.manager.start(widget.window.id);
      if (_disposing) {
        await connection.close();
        return;
      }
      await _attachConnection(connection, isReconnect: false);
    });
    _connectionChange = operation;
    try {
      await operation;
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _retry() async {
    if (_disposing || _retrying) return;
    setState(() {
      _retrying = true;
      _error = null;
      _audioError = null;
    });
    final operation = _connectionChange.catchError((Object _) {}).then((
      _,
    ) async {
      await _releaseControllers();
      await widget.manager.stop(widget.window.id);
      if (_disposing) return;
      final connection = await widget.manager.start(widget.window.id);
      if (_disposing) {
        await connection.close();
        return;
      }
      await _attachConnection(connection, isReconnect: true);
    });
    _connectionChange = operation;
    try {
      await operation;
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _releaseControllers() async {
    final video = _video;
    final audio = _audio;
    _video = null;
    _audio = null;
    _input = null;
    video?.removeListener(_handleChanged);
    audio?.removeListener(_handleChanged);
    if (!widget.window.isVirtual) {
      await widget.audioFocus.unregister(widget.window.audioFocusId);
    }
    if (audio != null) {
      try {
        await audio.stop();
      } catch (_) {}
      audio.dispose();
    }
    if (video != null) {
      try {
        await video.stop();
      } catch (_) {}
      video.dispose();
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _qualityTimer?.cancel();
    widget.audioFocus.removeListener(_handleChanged);
    _session.state.removeListener(_handleChanged);
    unawaited(_reconnectSubscription?.cancel());
    final cleanup = _connectionChange
        .catchError((Object _) {})
        .then((_) => _releaseControllers())
        .whenComplete(() => widget.manager.remove(widget.window.id));
    _connectionChange = cleanup;
    unawaited(cleanup);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _video?.value;
    final ratio = state?.aspectRatio ?? 16 / 9;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: widget.focused
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            dense: true,
            leading: Icon(
              widget.window.device.connectionType == AdbConnectionType.network
                  ? Icons.wifi
                  : Icons.usb,
            ),
            title: Text(widget.window.title),
            subtitle: Text(
              '${widget.window.device.redactedSerial}'
              '${widget.window.isVirtual ? ' · 虚拟屏' : ''} · $_statusLabel'
              '${_reconnectCount == 0 ? '' : ' · 重连 $_reconnectCount 次'}'
              ' · ${widget.qualityTier.label}'
              '${widget.qualityTier == _appliedQualityTier ? '' : '(保持当前流)'}'
              ' · 流≤${_appliedQualityProfile.maxSize}px/'
              '${_appliedQualityProfile.maxFps}fps/'
              '${_formatMbps(_appliedQualityProfile.bitRateMbps)}Mbps'
              '$_audioStatusSuffix',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: _audioError == null
                      ? _audioLabel
                      : '音频不可用：$_audioError',
                  onPressed:
                      widget.audioFocus.isRegistered(widget.window.audioFocusId)
                      ? widget.onFocus
                      : null,
                  icon: Icon(
                    _audioError != null
                        ? Icons.volume_off
                        : widget.audioFocus.isFocused(
                            widget.window.audioFocusId,
                          )
                        ? Icons.volume_up
                        : Icons.volume_mute,
                  ),
                ),
                IconButton(
                  tooltip: widget.expanded ? '返回设备墙' : '聚焦显示',
                  onPressed: widget.onToggleExpanded,
                  icon: Icon(
                    widget.expanded ? Icons.fullscreen_exit : Icons.fullscreen,
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: '关闭应用窗口',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => widget.onFocus(),
            child: AspectRatio(
              aspectRatio: ratio,
              child: ColoredBox(
                color: const Color(0xff101218),
                child: _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                '连接失败：$_error',
                                textAlign: TextAlign.center,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white),
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: _retrying ? null : _retry,
                                icon: _retrying
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.refresh),
                                label: Text(_retrying ? '重试中' : '重试本窗口'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _video == null
                    ? const Center(child: CircularProgressIndicator())
                    : _buildVideo(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideo() => ValueListenableBuilder<ScrcpyVideoState>(
    valueListenable: _video!,
    builder: (context, state, _) {
      final view = ScrcpyVideoView(
        controller: _video!,
        placeholder: const Center(child: CircularProgressIndicator()),
      );
      final input = _input;
      if (input == null || state.width == null || state.height == null) {
        return view;
      }
      return ScrcpyInputLayer(
        controller: input,
        videoSize: Size(state.width!.toDouble(), state.height!.toDouble()),
        child: view,
      );
    },
  );

  String get _statusLabel => switch (_session.state.value) {
    ScrcpySessionState.idle => '等待启动',
    ScrcpySessionState.preparing => '准备中',
    ScrcpySessionState.ready => '已连接',
    ScrcpySessionState.starting => '启动中',
    ScrcpySessionState.streaming => '播放中',
    ScrcpySessionState.disconnected => '连接中断',
    ScrcpySessionState.reconnecting => '重连中',
    ScrcpySessionState.stopping => '停止中',
    ScrcpySessionState.error => '错误',
    ScrcpySessionState.disposed => '已释放',
  };

  String get _audioLabel {
    if (widget.window.isVirtual) {
      if (!widget.audioFocus.isRegistered(widget.window.audioFocusId)) {
        return '设备音频连接中';
      }
      return widget.audioFocus.isFocused(widget.window.audioFocusId)
          ? '当前设备音频焦点'
          : '切换到该设备音频';
    }
    final audio = _audio;
    if (audio == null) return '音频连接中';
    final state = audio.value;
    if (state.status == ScrcpyAudioStatus.error) return '音频播放错误';
    if (state.status == ScrcpyAudioStatus.ended) return '音频已断开';
    if (state.packetsReceived == 0) return '等待音频数据';
    if (state.playedBuffers == 0) return '等待音频播放';
    return widget.audioFocus.isFocused(widget.window.audioFocusId)
        ? '当前音频焦点'
        : '切换音频焦点';
  }

  String get _audioStatusSuffix {
    if (widget.window.isVirtual) {
      if (!widget.audioFocus.isRegistered(widget.window.audioFocusId)) {
        return ' · 设备音频连接中';
      }
      return widget.audioFocus.isFocused(widget.window.audioFocusId)
          ? ' · 电脑播放中'
          : ' · 音频已静音';
    }
    if (_audioError != null) return ' · 音频不可用';
    final audio = _audio;
    if (audio == null) return ' · 音频连接中';
    final state = audio.value;
    if (state.status == ScrcpyAudioStatus.error) return ' · 音频错误';
    if (state.status == ScrcpyAudioStatus.ended) return ' · 音频已断开';
    if (state.packetsReceived == 0) return ' · 等待音频数据';
    if (state.playedBuffers == 0) return ' · 等待音频播放';
    return widget.audioFocus.isFocused(widget.window.audioFocusId)
        ? ' · 电脑播放中'
        : ' · 音频已静音';
  }

  String _formatMbps(double value) =>
      value == value.roundToDouble() ? value.toInt().toString() : '$value';
}

class _QualityPolicyDialog extends StatefulWidget {
  const _QualityPolicyDialog({required this.initialValue});

  final _DeviceWallQualityPolicy initialValue;

  @override
  State<_QualityPolicyDialog> createState() => _QualityPolicyDialogState();
}

class _QualityPolicyDialogState extends State<_QualityPolicyDialog> {
  late final Map<_DeviceWallQualityTier, TextEditingController>
  _maxSizeControllers;
  late final Map<_DeviceWallQualityTier, TextEditingController> _fpsControllers;
  late final Map<_DeviceWallQualityTier, TextEditingController>
  _bitRateControllers;
  String? _error;

  @override
  void initState() {
    super.initState();
    _maxSizeControllers = _controllersFor(
      widget.initialValue,
      (profile) => '${profile.maxSize}',
    );
    _fpsControllers = _controllersFor(
      widget.initialValue,
      (profile) => '${profile.maxFps}',
    );
    _bitRateControllers = _controllersFor(
      widget.initialValue,
      (profile) => _formatNumber(profile.bitRateMbps),
    );
  }

  Map<_DeviceWallQualityTier, TextEditingController> _controllersFor(
    _DeviceWallQualityPolicy policy,
    String Function(_DeviceWallQualityProfile profile) valueOf,
  ) => {
    for (final tier in _DeviceWallQualityTier.values)
      tier: TextEditingController(text: valueOf(policy.profileFor(tier))),
  };

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      ..._maxSizeControllers.values,
      ..._fpsControllers.values,
      ..._bitRateControllers.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _restoreDefaults() {
    for (final tier in _DeviceWallQualityTier.values) {
      final profile = _DeviceWallQualityPolicy.defaults.profileFor(tier);
      _maxSizeControllers[tier]!.text = '${profile.maxSize}';
      _fpsControllers[tier]!.text = '${profile.maxFps}';
      _bitRateControllers[tier]!.text = _formatNumber(profile.bitRateMbps);
    }
    setState(() => _error = null);
  }

  void _submit() {
    final profiles = <_DeviceWallQualityTier, _DeviceWallQualityProfile>{};
    for (final tier in _DeviceWallQualityTier.values) {
      final maxSize = int.tryParse(_maxSizeControllers[tier]!.text.trim());
      final maxFps = int.tryParse(_fpsControllers[tier]!.text.trim());
      final bitRate = double.tryParse(_bitRateControllers[tier]!.text.trim());
      if (maxSize == null || maxSize < 64 || maxSize > 16384) {
        return _showError('${tier.label}档最大边长需在 64–16384 之间');
      }
      if (maxFps == null || maxFps < 1 || maxFps > 240) {
        return _showError('${tier.label}档帧率需在 1–240 之间');
      }
      if (bitRate == null || bitRate < 0.1 || bitRate > 100) {
        return _showError('${tier.label}档码率需在 0.1–100 Mbps 之间');
      }
      profiles[tier] = _DeviceWallQualityProfile(
        maxSize: maxSize,
        maxFps: maxFps,
        bitRateMbps: bitRate,
      );
    }

    final focused = profiles[_DeviceWallQualityTier.focused]!;
    final visible = profiles[_DeviceWallQualityTier.visible]!;
    final offscreen = profiles[_DeviceWallQualityTier.offscreen]!;
    if (focused.maxSize < visible.maxSize ||
        visible.maxSize < offscreen.maxSize ||
        focused.maxFps < visible.maxFps ||
        visible.maxFps < offscreen.maxFps ||
        focused.bitRateMbps < visible.bitRateMbps ||
        visible.bitRateMbps < offscreen.bitRateMbps) {
      return _showError('聚焦档参数需不低于可见档，可见档需不低于离屏档');
    }

    Navigator.pop(
      context,
      _DeviceWallQualityPolicy(
        focused: focused,
        visible: visible,
        offscreen: offscreen,
      ),
    );
  }

  void _showError(String message) => setState(() => _error = message);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('设备墙画质调度'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              '滚动、聚焦和离屏切换不会重连。点击“应用”后，现有窗口会按当时所在档位'
              '重建一次视频会话；之后的自动状态变化保持当前视频流。',
            ),
            const SizedBox(height: 12),
            for (final tier in _DeviceWallQualityTier.values) ...[
              Text(tier.label, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _numberField(
                      controller: _maxSizeControllers[tier]!,
                      label: '最大边长',
                      suffix: 'px',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _numberField(
                      controller: _fpsControllers[tier]!,
                      label: '最大帧率',
                      suffix: 'fps',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _numberField(
                      controller: _bitRateControllers[tier]!,
                      label: '码率',
                      suffix: 'Mbps',
                      decimal: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: <Widget>[
      TextButton(onPressed: _restoreDefaults, child: const Text('恢复默认')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('应用')),
    ],
  );

  Widget _numberField({
    required TextEditingController controller,
    required String label,
    required String suffix,
    bool decimal = false,
  }) => TextField(
    controller: controller,
    keyboardType: TextInputType.numberWithOptions(decimal: decimal),
    decoration: InputDecoration(labelText: label, suffixText: suffix),
    onSubmitted: (_) => _submit(),
  );

  static String _formatNumber(double value) =>
      value == value.roundToDouble() ? '${value.toInt()}' : '$value';
}

class _ApplicationPicker extends StatefulWidget {
  const _ApplicationPicker({required this.applications});

  final List<AdbApplication> applications;

  @override
  State<_ApplicationPicker> createState() => _ApplicationPickerState();
}

class _ApplicationPickerState extends State<_ApplicationPicker> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final applications = widget.applications
        .where((application) => application.matches(_query))
        .toList(growable: false);
    return AlertDialog(
      title: const Text('选择应用'),
      content: SizedBox(
        width: 520,
        height: 560,
        child: Column(
          children: <Widget>[
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: '搜索应用名或包名',
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: applications.isEmpty
                  ? const Center(child: Text('没有匹配的应用'))
                  : ListView.builder(
                      itemCount: applications.length,
                      itemBuilder: (context, index) {
                        final application = applications[index];
                        return ListTile(
                          leading: const Icon(Icons.apps),
                          title: Text(application.name),
                          subtitle: Text(application.packageName),
                          onTap: () => Navigator.pop(context, application),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
