import 'dart:async';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/material.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

import 'screenshot_helper.dart';
import 'virtual_display_defaults.dart';

class VirtualDisplayWorkspacePage extends StatefulWidget {
  const VirtualDisplayWorkspacePage({
    required this.client,
    required this.device,
    super.key,
  });

  final ScrcpyClient client;
  final AdbDevice device;

  @override
  State<VirtualDisplayWorkspacePage> createState() =>
      _VirtualDisplayWorkspacePageState();
}

class _VirtualDisplayWorkspacePageState
    extends State<VirtualDisplayWorkspacePage> {
  late final ScrcpyManager _scrcpy;
  final ScrcpyAudioFocusManager _audioFocus = ScrcpyAudioFocusManager();
  final List<_VirtualScreenDefinition> _screens = <_VirtualScreenDefinition>[];
  List<AdbApplication> _applications = const <AdbApplication>[];
  VirtualDisplayDefaults _displayDefaults = VirtualDisplayDefaults.fallback;
  Object? _error;
  bool _loading = true;
  int _nextId = 1;

  @override
  void dispose() {
    _audioFocus.dispose();
    unawaited(_scrcpy.close().whenComplete(_scrcpy.dispose));
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scrcpy = ScrcpyManager.fromClient(widget.client);
    unawaited(_loadApplications());
  }

  Future<void> _loadApplications() async {
    try {
      final defaultsFuture = _loadDisplayDefaults();
      final applications = await widget.client.listApplications(
        widget.device.serial,
      );
      final defaults = await defaultsFuture;
      if (!mounted) return;
      setState(() {
        _applications = applications
            .where(
              (application) => application.enabled && application.launchable,
            )
            .toList(growable: false);
        _displayDefaults = defaults;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  Future<VirtualDisplayDefaults> _loadDisplayDefaults() async {
    try {
      final details = await AdbToolkit(widget.client.adbClient)
          .getDeviceDetails(widget.device);
      return VirtualDisplayDefaults.fromDeviceDetails(details);
    } catch (_) {
      return VirtualDisplayDefaults.fallback;
    }
  }

  Future<void> _addScreen() async {
    final definition = await showDialog<_VirtualScreenDefinition>(
      context: context,
      builder: (_) => _CreateVirtualScreenDialog(
        applications: _applications,
        id: _nextId,
        defaults: _displayDefaults,
      ),
    );
    if (!mounted || definition == null) return;
    setState(() {
      _nextId++;
      _screens.add(definition);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${widget.device.model ?? '设备'} · 虚拟屏工作台'),
      actions: <Widget>[
        IconButton(
          tooltip: '刷新应用',
          onPressed: _loading ? null : _loadApplications,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '创建虚拟屏',
          onPressed: _loading || _applications.isEmpty ? null : _addScreen,
          icon: const Icon(Icons.add_to_queue),
        ),
      ],
    ),
    body: Column(
      children: <Widget>[
        if (_loading) const LinearProgressIndicator(),
        if (_error case final error?)
          MaterialBanner(
            content: Text('$error'),
            actions: <Widget>[
              TextButton(onPressed: _loadApplications, child: const Text('重试')),
            ],
          ),
        Expanded(
          child: _screens.isEmpty
              ? Center(
                  child: FilledButton.icon(
                    onPressed: _loading || _applications.isEmpty
                        ? null
                        : _addScreen,
                    icon: const Icon(Icons.add_to_queue),
                    label: const Text('创建第一块虚拟屏'),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.maxWidth / 460).floor().clamp(
                      1,
                      6,
                    );
                    const spacing = 12.0;
                    final tileWidth =
                        (constraints.maxWidth -
                            spacing * 2 -
                            spacing * (columns - 1)) /
                        columns;
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(spacing),
                      child: Wrap(
                        spacing: spacing,
                        runSpacing: spacing,
                        children: <Widget>[
                          for (final screen in _screens)
                            SizedBox(
                              width: tileWidth,
                              child: _VirtualDisplayTile(
                                key: ValueKey<int>(screen.id),
                                manager: _scrcpy,
                                device: widget.device,
                                definition: screen,
                                applications: _applications,
                                audioFocus: _audioFocus,
                                onClose: () =>
                                    setState(() => _screens.remove(screen)),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
    floatingActionButton: _screens.isEmpty
        ? null
        : FloatingActionButton.extended(
            onPressed: _loading ? null : _addScreen,
            icon: const Icon(Icons.add),
            label: const Text('新增屏幕'),
          ),
  );
}

final class _VirtualScreenDefinition {
  const _VirtualScreenDefinition({
    required this.id,
    required this.application,
    required this.width,
    required this.height,
    required this.dpi,
    required this.systemDecorations,
    required this.moveContentToMain,
    required this.audioEnabled,
  });

  final int id;
  final AdbApplication application;
  final int width;
  final int height;
  final int dpi;
  final bool systemDecorations;
  final bool moveContentToMain;
  final bool audioEnabled;
}

class _CreateVirtualScreenDialog extends StatefulWidget {
  const _CreateVirtualScreenDialog({
    required this.applications,
    required this.id,
    required this.defaults,
  });

  final List<AdbApplication> applications;
  final int id;
  final VirtualDisplayDefaults defaults;

  @override
  State<_CreateVirtualScreenDialog> createState() =>
      _CreateVirtualScreenDialogState();
}

class _CreateVirtualScreenDialogState
    extends State<_CreateVirtualScreenDialog> {
  late AdbApplication _application = widget.applications.first;
  late final _width = TextEditingController(text: '${widget.defaults.width}');
  late final _height = TextEditingController(text: '${widget.defaults.height}');
  late final _dpi = TextEditingController(text: '${widget.defaults.dpi}');
  bool _systemDecorations = false;
  bool _moveContentToMain = false;
  bool _audioEnabled = true;
  Object? _error;

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    _dpi.dispose();
    super.dispose();
  }

  void _swap() {
    final width = _width.text;
    setState(() {
      _width.text = _height.text;
      _height.text = width;
    });
  }

  void _submit() {
    try {
      final width = int.parse(_width.text);
      final height = int.parse(_height.text);
      final dpi = int.parse(_dpi.text);
      ScrcpyVirtualDisplaySource(
        width: width,
        height: height,
        dpi: dpi,
      ).validate();
      Navigator.of(context).pop(
        _VirtualScreenDefinition(
          id: widget.id,
          application: _application,
          width: width,
          height: height,
          dpi: dpi,
          systemDecorations: _systemDecorations,
          moveContentToMain: _moveContentToMain,
          audioEnabled: _audioEnabled,
        ),
      );
    } catch (error) {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('创建虚拟屏'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DropdownButtonFormField<AdbApplication>(
              isExpanded: true,
              initialValue: _application,
              decoration: const InputDecoration(labelText: '初始应用'),
              items: widget.applications
                  .map(
                    (app) => DropdownMenuItem<AdbApplication>(
                      value: app,
                      child: Text(
                        '${app.name} · ${app.packageName}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _application = value!),
            ),
            Row(
              children: <Widget>[
                Expanded(child: _numberField(_width, '虚拟屏宽度（px）')),
                IconButton(
                  tooltip: '交换横竖',
                  onPressed: _swap,
                  icon: const Icon(Icons.screen_rotation),
                ),
                Expanded(child: _numberField(_height, '虚拟屏高度（px）')),
              ],
            ),
            _numberField(_dpi, 'DPI'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示系统装饰'),
              value: _systemDecorations,
              onChanged: (value) => setState(() => _systemDecorations = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('关闭后将内容移回主屏'),
              value: _moveContentToMain,
              onChanged: (value) => setState(() => _moveContentToMain = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('将设备音频转发到电脑'),
              subtitle: const Text('使用与主界面相同的播放捕获；音频属于整台设备，不保证只包含此虚拟屏应用'),
              value: _audioEnabled,
              onChanged: (value) => setState(() => _audioEnabled = value),
            ),
            if (_error case final error?)
              Text(
                '$error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('创建')),
    ],
  );

  Widget _numberField(TextEditingController controller, String label) =>
      TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
      );
}

class _VirtualDisplayTile extends StatefulWidget {
  const _VirtualDisplayTile({
    required this.manager,
    required this.device,
    required this.definition,
    required this.applications,
    required this.audioFocus,
    required this.onClose,
    super.key,
  });

  final ScrcpyManager manager;
  final AdbDevice device;
  final _VirtualScreenDefinition definition;
  final List<AdbApplication> applications;
  final ScrcpyAudioFocusManager audioFocus;
  final VoidCallback onClose;

  @override
  State<_VirtualDisplayTile> createState() => _VirtualDisplayTileState();
}

class _VirtualDisplayTileState extends State<_VirtualDisplayTile> {
  ScrcpySession? _session;
  ScrcpyVideoController? _video;
  ScrcpyInputController? _input;
  ScrcpyAdaptiveDisplayController? _adaptiveDisplay;
  ScrcpyAudioController? _audio;
  Object? _audioError;
  Object? _error;
  late int _width = widget.definition.width;
  late int _height = widget.definition.height;
  int? _videoWidth;
  int? _videoHeight;
  int _reconnectCount = 0;
  late AdbApplication _application = widget.definition.application;
  // Respect the explicitly requested creation size. Flex display remains
  // available, but preview-driven resizing is opt-in per tile.
  bool _autoFit = false;
  late final String _audioFocusId =
      '${widget.device.serial}:${widget.definition.id}';

  @override
  void initState() {
    super.initState();
    widget.audioFocus.addListener(_handleAudioFocusChanged);
    unawaited(_start());
  }

  void _handleAudioFocusChanged() {
    if (mounted) setState(() {});
  }

  void _handleAudioState() {
    if (mounted) setState(() {});
  }

  Future<void> _requestAudioFocus() async {
    try {
      await widget.audioFocus.tryRequestFocus(_audioFocusId);
    } catch (error) {
      if (mounted) setState(() => _audioError = error);
    }
  }

  String get _audioLabel {
    if (!widget.definition.audioEnabled) return '关闭';
    if (_audioError != null) return '不可用';
    final audio = _audio;
    if (audio == null) return '连接中';
    if (audio.value.status == ScrcpyAudioStatus.ended) return '已断开';
    if (audio.value.status == ScrcpyAudioStatus.error) return '错误';
    if (audio.value.packetsReceived == 0) return '等待数据';
    if (audio.value.playedBuffers == 0) return '等待播放';
    return widget.audioFocus.isFocused(_audioFocusId)
        ? '电脑播放 ${audio.value.playedBuffers}'
        : '已静音';
  }

  Future<void> _start() async {
    try {
      final session = await widget.manager.createSession(
        id: 'workspace-${widget.definition.id}',
        deviceSerial: widget.device.serial,
        video: ScrcpyVideoOptions(maxSize: _width > _height ? _width : _height),
        audioEnabled: widget.definition.audioEnabled,
        audio: const ScrcpyAudioOptions(
          codec: ScrcpyAudioCodec.opus,
          source: ScrcpyAudioSource.playback,
          duplicateOnDevice: false,
          initiallyMuted: true,
        ),
        display: ScrcpyDisplay.virtual(
          width: _width,
          height: _height,
          dpi: widget.definition.dpi,
          systemDecorations: widget.definition.systemDecorations,
          closePolicy: widget.definition.moveContentToMain
              ? ScrcpyVirtualDisplayClosePolicy.moveContentToMainDisplay
              : ScrcpyVirtualDisplayClosePolicy.destroyContent,
          application: _application.packageName,
        ),
        reconnectPolicy: const ScrcpyReconnectPolicy(maxAttempts: 5),
      );
      if (!mounted) {
        await widget.manager.removeSession(session.id);
        return;
      }
      _session = session;
      session.addListener(_handleSessionChanged);
      await _syncSessionResources();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _handleSessionChanged() => unawaited(_syncSessionResources());

  Future<void> _syncSessionResources() async {
    final session = _session;
    if (session == null || !mounted) return;
    final video = session.video;
    final audio = session.audio;
    final input = session.input;
    final videoChanged = !identical(_video, video);
    final audioChanged = !identical(_audio, audio);
    final inputChanged = !identical(_input, input);
    if (!videoChanged && !audioChanged && !inputChanged) {
      if (mounted) setState(() {});
      return;
    }
    _adaptiveDisplay?.dispose();
    _adaptiveDisplay = null;
    if (videoChanged) {
      _video?.removeListener(_handleVideoState);
      video?.addListener(_handleVideoState);
    }
    if (audioChanged) {
      _audio?.removeListener(_handleAudioState);
      await widget.audioFocus.unregister(_audioFocusId);
      audio?.addListener(_handleAudioState);
      if (audio != null) {
        await widget.audioFocus.register(
          id: _audioFocusId,
          controller: audio,
          requestFocus: widget.audioFocus.focusedId == null,
        );
      }
    }
    if (_video != null && video != null && videoChanged) _reconnectCount++;
    if (input != null) {
      _adaptiveDisplay = ScrcpyAdaptiveDisplayController(
        input: input,
        maxSize: _width > _height ? _width : _height,
        onResized: (size) {
          if (mounted) {
            setState(() {
              _width = size.width.round();
              _height = size.height.round();
            });
          }
        },
        onError: (error, _) {
          if (mounted) setState(() => _error = error);
        },
      );
    }
    if (!mounted) return;
    setState(() {
      _video = video;
      _audio = audio;
      _input = input;
      _error = null;
      _audioError = widget.definition.audioEnabled && audio == null
          ? StateError('scrcpy server 未提供音频流')
          : null;
    });
    _handleVideoState();
  }

  void _handleVideoState() {
    final state = _video?.value;
    final width = state?.width;
    final height = state?.height;
    if (!mounted || width == null || height == null) return;
    if (_videoWidth == width && _videoHeight == height) return;
    setState(() {
      _videoWidth = width;
      _videoHeight = height;
    });
  }

  Future<void> _rotate() async {
    final session = _session;
    if (session == null || !session.isControllable) return;
    try {
      await session.resizeDisplay(width: _height, height: _width);
      if (mounted) {
        setState(() {
          final width = _width;
          _width = _height;
          _height = width;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _editSize() async {
    final size = await showDialog<Size>(
      context: context,
      builder: (_) =>
          _ResizeVirtualDisplayDialog(width: _width, height: _height),
    );
    final session = _session;
    if (!mounted ||
        size == null ||
        session == null ||
        !session.isControllable) {
      return;
    }
    final width = size.width.round() & ~1;
    final height = size.height.round() & ~1;
    try {
      await session.resizeDisplay(width: width, height: height);
      if (mounted) {
        setState(() {
          _width = width;
          _height = height;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _switchApplication(AdbApplication application) async {
    try {
      await _session?.startApplication(application.packageName);
      if (mounted) setState(() => _application = application);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    widget.audioFocus.removeListener(_handleAudioFocusChanged);
    _adaptiveDisplay?.dispose();
    _video?.removeListener(_handleVideoState);
    _audio?.removeListener(_handleAudioState);
    unawaited(widget.audioFocus.unregister(_audioFocusId));
    final session = _session;
    if (session != null) {
      session.removeListener(_handleSessionChanged);
      unawaited(widget.manager.removeSession(session.id));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ListTile(
          dense: true,
          title: Text('屏幕 ${widget.definition.id} · ${_application.name}'),
          subtitle: Text(
            '$_width×$_height / ${widget.definition.dpi} DPI'
            '${_videoWidth == null ? '' : ' · 视频 $_videoWidth×$_videoHeight'}'
            '${_reconnectCount == 0 ? '' : ' · 重连 $_reconnectCount 次'}'
            ' · 音频 $_audioLabel'
            ' · ${_autoFit ? '动态虚拟屏' : '固定虚拟屏'}',
          ),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          children: <Widget>[
            IconButton(
              tooltip: '截取当前画面',
              onPressed: _session == null
                  ? null
                  : () => unawaited(
                      captureSessionScreenshot(
                        context,
                        _session!,
                        name:
                            '${widget.device.redactedSerial}_virtual_${widget.definition.id}',
                      ),
                    ),
              icon: const Icon(Icons.screenshot_monitor),
            ),
            if (_session != null)
              SessionRecordingButton(
                key: ValueKey('record-${_session!.id}'),
                session: _session!,
                name: 'virtual-${widget.definition.id}',
              ),
            IconButton(
              tooltip: _audio == null
                  ? (!widget.definition.audioEnabled
                        ? '未启用设备音频'
                        : _audioError == null
                        ? '正在连接设备音频'
                        : '设备音频不可用')
                  : widget.audioFocus.isFocused(_audioFocusId)
                  ? '当前音频焦点'
                  : '切换到此窗口的设备音频',
              onPressed: _audio == null
                  ? null
                  : () => unawaited(_requestAudioFocus()),
              icon: Icon(
                _audioError != null
                    ? Icons.volume_off
                    : widget.audioFocus.isFocused(_audioFocusId)
                    ? Icons.volume_up
                    : Icons.volume_mute,
              ),
            ),
            PopupMenuButton<AdbApplication>(
              tooltip: '切换应用',
              icon: const Icon(Icons.apps),
              onSelected: (application) =>
                  unawaited(_switchApplication(application)),
              itemBuilder: (_) => widget.applications
                  .map(
                    (app) => PopupMenuItem<AdbApplication>(
                      value: app,
                      child: Text(app.name),
                    ),
                  )
                  .toList(),
            ),
            IconButton(
              tooltip: _autoFit ? '关闭动态虚拟屏尺寸' : '让虚拟屏尺寸跟随预览区域',
              onPressed: _input == null
                  ? null
                  : () {
                      setState(() => _autoFit = !_autoFit);
                      if (!_autoFit) _adaptiveDisplay?.cancelPending();
                    },
              icon: Icon(_autoFit ? Icons.fit_screen : Icons.crop_free),
            ),
            IconButton(
              tooltip: '调整虚拟屏尺寸和比例',
              onPressed: _input == null ? null : _editSize,
              icon: const Icon(Icons.aspect_ratio),
            ),
            IconButton(
              tooltip: '切换横竖',
              onPressed: _input == null ? null : _rotate,
              icon: const Icon(Icons.screen_rotation),
            ),
            IconButton(
              tooltip: '关闭屏幕',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _audio == null
              ? null
              : (_) => unawaited(_requestAudioFocus()),
          child: AspectRatio(
            aspectRatio: (_videoWidth ?? _width) / (_videoHeight ?? _height),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (_autoFit &&
                    constraints.hasBoundedWidth &&
                    constraints.hasBoundedHeight) {
                  _adaptiveDisplay?.updatePreview(
                    Size(
                      constraints.maxWidth *
                          MediaQuery.devicePixelRatioOf(context),
                      constraints.maxHeight *
                          MediaQuery.devicePixelRatioOf(context),
                    ),
                  );
                }
                return ColoredBox(
                  color: const Color(0xff101218),
                  child: _error != null
                      ? Center(child: Text('$_error'))
                      : _session == null || _video == null
                      ? const Center(child: CircularProgressIndicator())
                      : ScrcpyView(session: _session!),
                );
              },
            ),
          ),
        ),
      ],
    ),
  );
}

class _ResizeVirtualDisplayDialog extends StatefulWidget {
  const _ResizeVirtualDisplayDialog({
    required this.width,
    required this.height,
  });

  final int width;
  final int height;

  @override
  State<_ResizeVirtualDisplayDialog> createState() =>
      _ResizeVirtualDisplayDialogState();
}

class _ResizeVirtualDisplayDialogState
    extends State<_ResizeVirtualDisplayDialog> {
  late final TextEditingController _width = TextEditingController(
    text: '${widget.width}',
  );
  late final TextEditingController _height = TextEditingController(
    text: '${widget.height}',
  );
  Object? _error;

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final width = int.parse(_width.text);
      final height = int.parse(_height.text);
      if (width <= 0 || width > 0xffff || height <= 0 || height > 0xffff) {
        throw const FormatException('宽高必须在 1～65535 之间');
      }
      Navigator.of(context).pop(Size(width.toDouble(), height.toDouble()));
    } catch (error) {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('调整虚拟屏尺寸'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextField(
          controller: _width,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '虚拟屏宽度（px）'),
        ),
        TextField(
          controller: _height,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '虚拟屏高度（px）'),
        ),
        if (_error case final error?)
          Text(
            '$error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('应用')),
    ],
  );
}
