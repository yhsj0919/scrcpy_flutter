import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/material.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

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
    unawaited(_audioFocus.tryRequestFocus(id));
    if (mounted) setState(() {});
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
    final id = 'wall-virtual-${_nextVirtualId++}';
    setState(() {
      _windows.add(
        _DeviceWallWindow(
          id: id,
          device: device,
          title: application.name,
          displaySource: ScrcpyDisplaySource.virtual(
            width: 1280,
            height: 720,
            dpi: 240,
            keepActive: true,
            flexDisplay: true,
            launchApplication: ScrcpyApplicationLaunch(application.packageName),
          ),
        ),
      );
    });
  }

  void _removeWindow(_DeviceWallWindow window) {
    setState(() {
      _windows.remove(window);
      if (_expandedId == window.id) _expandedId = null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('设备墙 · ${widget.devices.length} 台 · ${_windows.length} 个窗口'),
      actions: <Widget>[
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
        const spacing = 12.0;
        final columns = switch (constraints.maxWidth) {
          >= 1800 => 4,
          >= 1200 => 3,
          >= 720 => 2,
          _ => 1,
        };
        final tileWidth =
            (constraints.maxWidth - 32 - spacing * (columns - 1)) / columns;
        return SingleChildScrollView(
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
                    key: ValueKey('device-wall-cell-${window.id}'),
                    width: _expandedId == null
                        ? tileWidth
                        : constraints.maxWidth - 32,
                    child: _DeviceWallTile(
                      key: ValueKey(window.id),
                      manager: _sessions,
                      audioFocus: _audioFocus,
                      window: window,
                      focused: _sessions.focusedId == window.id,
                      expanded: _expandedId == window.id,
                      onFocus: () => _focus(window.id),
                      onToggleExpanded: () {
                        final id = window.id;
                        _sessions.focus(id);
                        unawaited(_audioFocus.tryRequestFocus(id));
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
            ],
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
}

class _DeviceWallTile extends StatefulWidget {
  const _DeviceWallTile({
    required this.manager,
    required this.audioFocus,
    required this.window,
    required this.focused,
    required this.expanded,
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
  final VoidCallback onFocus;
  final VoidCallback onToggleExpanded;
  final VoidCallback? onClose;

  @override
  State<_DeviceWallTile> createState() => _DeviceWallTileState();
}

class _DeviceWallTileState extends State<_DeviceWallTile> {
  late final ScrcpyManagedSession _session;
  StreamSubscription<ScrcpyVideoConnection>? _reconnectSubscription;
  Future<void> _connectionChange = Future<void>.value();
  ScrcpyVideoController? _video;
  ScrcpyAudioController? _audio;
  ScrcpyInputController? _input;
  Object? _error;
  Object? _audioError;
  int _reconnectCount = 0;
  bool _disposing = false;

  @override
  void initState() {
    super.initState();
    _session = widget.manager.create(
      ScrcpySessionConfiguration(
        deviceSerial: widget.window.device.serial,
        displaySource: widget.window.displaySource,
        video: const ScrcpyVideoOptions(
          maxSize: 1280,
          maxFps: 30,
          bitRate: 4000000,
        ),
        audioEnabled: true,
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
    widget.audioFocus.addListener(_handleChanged);
    _session.state.addListener(_handleChanged);
    _reconnectSubscription = _session.reconnectedConnections.listen(
      (connection) =>
          unawaited(_queueConnection(connection, isReconnect: true)),
      onError: (Object error) {
        if (mounted) setState(() => _error = error);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  void _handleChanged() {
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
        _video = video;
        _input = connection.input;
        _error = null;
        _audioError = null;
        if (isReconnect) _reconnectCount++;
      });

      final stream = connection.audio;
      if (stream == null) {
        if (mounted) setState(() => _audioError = '设备未提供音频流');
        return;
      }
      audio = createNativeScrcpyAudioController(stream);
      await audio.setMuted(true);
      await audio.start();
      await widget.audioFocus.register(
        id: widget.window.id,
        controller: audio,
        requestFocus:
            widget.manager.focusedId == widget.window.id ||
            widget.audioFocus.focusedId == null,
      );
      if (!mounted) {
        await widget.audioFocus.unregister(widget.window.id);
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

  Future<void> _releaseControllers() async {
    final video = _video;
    final audio = _audio;
    _video = null;
    _audio = null;
    _input = null;
    video?.removeListener(_handleChanged);
    audio?.removeListener(_handleChanged);
    await widget.audioFocus.unregister(widget.window.id);
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
              '$_audioStatusSuffix',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: _audioError == null
                      ? _audioLabel
                      : '音频不可用：$_audioError',
                  onPressed: _audio == null ? null : widget.onFocus,
                  icon: Icon(
                    _audioError != null
                        ? Icons.volume_off
                        : widget.audioFocus.isFocused(widget.window.id)
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
                          child: Text(
                            '$_error',
                            style: const TextStyle(color: Colors.white),
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
    final audio = _audio;
    if (audio == null) return '音频连接中';
    final state = audio.value;
    if (state.status == ScrcpyAudioStatus.error) return '音频播放错误';
    if (state.status == ScrcpyAudioStatus.ended) return '音频已断开';
    if (state.packetsReceived == 0) return '等待音频数据';
    if (state.playedBuffers == 0) return '等待音频播放';
    return widget.audioFocus.isFocused(widget.window.id) ? '当前音频焦点' : '切换音频焦点';
  }

  String get _audioStatusSuffix {
    if (_audioError != null) return ' · 音频不可用';
    final audio = _audio;
    if (audio == null) return ' · 音频连接中';
    final state = audio.value;
    if (state.status == ScrcpyAudioStatus.error) return ' · 音频错误';
    if (state.status == ScrcpyAudioStatus.ended) return ' · 音频已断开';
    if (state.packetsReceived == 0) return ' · 等待音频数据';
    if (state.playedBuffers == 0) return ' · 等待音频播放';
    return widget.audioFocus.isFocused(widget.window.id)
        ? ' · 电脑播放中'
        : ' · 音频已静音';
  }
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
