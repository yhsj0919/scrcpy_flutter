import 'dart:async';
import 'dart:convert';

import 'package:adb_client/adb_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

import 'screenshot_helper.dart';
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
  late final ScrcpyManager _sessions;
  final ScrcpyAudioFocusManager _audioFocus = ScrcpyAudioFocusManager();
  late final List<_DeviceWallWindow> _windows;
  _DeviceWallQualityProfile _defaultQualityProfile =
      _DeviceWallQualityProfile.defaults;
  int _nextVirtualId = 1;
  String? _expandedId;
  final Set<String> _selectedDeviceSerials = <String>{};
  bool _selectionMode = false;
  AdbBatchTask? _batchTask;
  AdbBatchSnapshot? _batchSnapshot;
  StreamSubscription<AdbBatchSnapshot>? _batchSubscription;
  String? _batchLabel;
  final Map<String, ScrcpyInputController> _windowInputs =
      <String, ScrcpyInputController>{};
  final Map<String, Size> _windowVideoSizes = <String, Size>{};
  bool _touchBroadcastEnabled = false;
  String? _touchBroadcastSourceId;
  final Set<String> _touchBroadcastTargetIds = <String>{};
  final Map<int, ScrcpyPointerEvent> _activeBroadcastPointers =
      <int, ScrcpyPointerEvent>{};
  late final ScrcpyProcessMetricsCollector _processMetrics;
  final Map<String, ScrcpySessionMetricsSnapshot> _sessionMetrics =
      <String, ScrcpySessionMetricsSnapshot>{};
  final ValueNotifier<int> _metricsRevision = ValueNotifier<int>(0);
  bool _disposed = false;
  String? _focusedId;

  @override
  void initState() {
    super.initState();
    _sessions = ScrcpyManager.fromClient(widget.client);
    _processMetrics = ScrcpyProcessMetricsCollector();
    _processMetrics.addListener(_notifyMetricsChanged);
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
    _disposed = true;
    _batchTask?.cancel();
    unawaited(_batchSubscription?.cancel());
    _processMetrics.removeListener(_notifyMetricsChanged);
    _processMetrics.dispose();
    _metricsRevision.dispose();
    _audioFocus.dispose();
    unawaited(_sessions.close().whenComplete(_sessions.dispose));
    super.dispose();
  }

  void _focus(String id) {
    _focusedId = id;
    final window = _windows.where((item) => item.id == id).firstOrNull;
    if (window != null) {
      unawaited(_audioFocus.tryRequestFocus(window.audioFocusId));
    }
    if (mounted) setState(() {});
  }

  void _notifyMetricsChanged() {
    if (!_disposed) _metricsRevision.value++;
  }

  void _updateSessionMetrics(
    String windowId,
    ScrcpySessionMetricsSnapshot? snapshot,
  ) {
    if (snapshot == null) {
      _sessionMetrics.remove(windowId);
    } else {
      _sessionMetrics[windowId] = snapshot;
    }
    _notifyMetricsChanged();
  }

  Future<void> _showMetrics() => showDialog<void>(
    context: context,
    builder: (_) => _DeviceWallMetricsDialog(
      revision: _metricsRevision,
      windows: _windows,
      sessionMetrics: _sessionMetrics,
      processMetrics: _processMetrics,
    ),
  );

  Future<void> _configureDefaultQuality() async {
    final profile = await showDialog<_DeviceWallQualityProfile>(
      context: context,
      builder: (_) => _QualityProfileDialog(
        title: '新窗口默认画质',
        initialValue: _defaultQualityProfile,
      ),
    );
    if (!mounted || profile == null) return;
    setState(() => _defaultQualityProfile = profile);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('默认画质已更新，只影响之后创建的窗口')));
  }

  List<String> get _selectedSerials =>
      _selectedDeviceSerials.toList(growable: false);

  bool get _batchRunning =>
      _batchTask != null && !(_batchSnapshot?.isComplete ?? false);

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedDeviceSerials.clear();
    });
  }

  void _selectAllDevices() => setState(() {
    _selectedDeviceSerials
      ..clear()
      ..addAll(widget.devices.map((device) => device.serial));
  });

  Future<void> _runBatch(String label, AdbBatchOperation operation) async {
    final targets = _selectedSerials;
    if (targets.isEmpty || _batchRunning) return;
    await _batchSubscription?.cancel();
    final task = AdbBatchTask(
      targets: targets,
      operation: operation,
      maxConcurrency: 3,
      itemTimeout: const Duration(seconds: 20),
    );
    setState(() {
      _batchTask = task;
      _batchLabel = label;
      _batchSnapshot = task.current;
    });
    _batchSubscription = task.snapshots.listen((snapshot) {
      if (mounted && identical(_batchTask, task)) {
        setState(() => _batchSnapshot = snapshot);
      }
    });
    final result = await task.start();
    if (!mounted || !identical(_batchTask, task)) return;
    setState(() => _batchSnapshot = result);
    await _showBatchResults();
  }

  Future<void> _sendBatchKey(int keyCode, String label) =>
      _runBatch(label, (serial, token) async {
        final result = await widget.client.adbClient.shell(serial, <String>[
          'input',
          'keyevent',
          '$keyCode',
        ], cancellationToken: token);
        if (!result.isSuccess) throw StateError('$label 失败');
      });

  Future<AdbApplication?> _chooseBatchApplication(String title) async {
    final serials = _selectedSerials;
    if (serials.isEmpty) return null;
    try {
      final applications = (await widget.client.listApplications(serials.first))
          .where((application) => application.enabled && application.launchable)
          .toList(growable: false);
      if (!mounted) return null;
      return await showDialog<AdbApplication>(
        context: context,
        builder: (_) =>
            _ApplicationPicker(applications: applications, title: title),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取应用失败：$error')));
      }
      return null;
    }
  }

  Future<void> _startBatchApplication() async {
    final application = await _chooseBatchApplication('选择要批量启动的应用');
    if (application == null) return;
    await _runBatch(
      '启动 ${application.name}',
      (serial, token) => AdbToolkit(widget.client.adbClient)
          .applications(serial)
          .startApplication(application.packageName, cancellationToken: token),
    );
  }

  Future<void> _stopBatchApplication() async {
    final application = await _chooseBatchApplication('选择要批量停止的应用');
    if (application == null) return;
    await _runBatch(
      '停止 ${application.name}',
      (serial, token) => AdbToolkit(widget.client.adbClient)
          .applications(serial)
          .stopApplication(application.packageName, cancellationToken: token),
    );
  }

  Future<void> _showBatchResults() async {
    final snapshot = _batchSnapshot;
    if (!mounted || snapshot == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _BatchResultsDialog(
        label: _batchLabel ?? '批量任务',
        snapshot: snapshot,
        devices: widget.devices,
      ),
    );
  }

  void _handleBatchAction(_DeviceWallBatchAction action) {
    switch (action) {
      case _DeviceWallBatchAction.home:
        unawaited(_sendBatchKey(3, 'Home'));
      case _DeviceWallBatchAction.back:
        unawaited(_sendBatchKey(4, '返回'));
      case _DeviceWallBatchAction.recents:
        unawaited(_sendBatchKey(187, '最近任务'));
      case _DeviceWallBatchAction.startApplication:
        unawaited(_startBatchApplication());
      case _DeviceWallBatchAction.stopApplication:
        unawaited(_stopBatchApplication());
    }
  }

  void _updateWindowInput(
    String windowId,
    ScrcpyInputController? controller,
    Size? videoSize,
  ) {
    if (controller == null) {
      final affectsBroadcast =
          _touchBroadcastEnabled &&
          (_touchBroadcastSourceId == windowId ||
              _touchBroadcastTargetIds.contains(windowId));
      if (affectsBroadcast) _cancelActiveBroadcastPointers();
      _windowInputs.remove(windowId);
      _windowVideoSizes.remove(windowId);
      if (affectsBroadcast) {
        _touchBroadcastTargetIds.remove(windowId);
        if (_touchBroadcastSourceId == windowId ||
            _touchBroadcastTargetIds.isEmpty) {
          _touchBroadcastEnabled = false;
          _touchBroadcastSourceId = null;
          _touchBroadcastTargetIds.clear();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
      return;
    }
    _windowInputs[windowId] = controller;
    if (videoSize != null && !videoSize.isEmpty) {
      _windowVideoSizes[windowId] = videoSize;
    }
  }

  void _broadcastPointer(String sourceId, ScrcpyPointerEvent event) {
    if (!_touchBroadcastEnabled || sourceId != _touchBroadcastSourceId) return;
    if (event.action == ScrcpyPointerAction.hover ||
        event.action == ScrcpyPointerAction.scroll) {
      return;
    }
    final normalizedEvent = ScrcpyPointerEvent(
      pointerId: event.pointerId,
      action: event.action,
      normalizedX: event.normalizedX,
      normalizedY: event.normalizedY,
      buttons: event.buttons,
    );
    if (event.action == ScrcpyPointerAction.down ||
        event.action == ScrcpyPointerAction.move) {
      _activeBroadcastPointers[event.pointerId] = normalizedEvent;
    } else {
      _activeBroadcastPointers.remove(event.pointerId);
    }
    for (final targetId in _touchBroadcastTargetIds.toList()) {
      final controller = _windowInputs[targetId];
      if (controller == null) {
        _touchBroadcastTargetIds.remove(targetId);
        continue;
      }
      unawaited(
        controller.sendPointer(normalizedEvent).catchError((Object error) {
          if (kDebugMode) {
            debugPrint('触摸广播发送失败 [$targetId]: $error');
          }
        }),
      );
    }
  }

  void _handleInputFailure(String windowId, Object error) {
    if (!_touchBroadcastEnabled) return;
    if (windowId == _touchBroadcastSourceId) {
      _cancelActiveBroadcastPointers();
      setState(() {
        _touchBroadcastEnabled = false;
        _touchBroadcastSourceId = null;
        _touchBroadcastTargetIds.clear();
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('主控窗口输入失效，已停止触摸广播：$error')));
      return;
    }
    if (_touchBroadcastTargetIds.remove(windowId)) {
      if (_touchBroadcastTargetIds.isEmpty) {
        _touchBroadcastEnabled = false;
        _touchBroadcastSourceId = null;
      }
      setState(() {});
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('输入失效的广播目标已移除：$error')));
    }
  }

  Future<void> _configureTouchBroadcast() async {
    final configuration = await showDialog<_TouchBroadcastConfiguration>(
      context: context,
      builder: (_) => _TouchBroadcastDialog(
        windows: _windows,
        videoSizes: _windowVideoSizes,
        initialSourceId:
            _touchBroadcastSourceId ?? _focusedId ?? _windows.firstOrNull?.id,
        initialTargetIds: _touchBroadcastTargetIds,
      ),
    );
    if (!mounted || configuration == null) return;
    setState(() {
      _touchBroadcastSourceId = configuration.sourceId;
      _touchBroadcastTargetIds
        ..clear()
        ..addAll(configuration.targetIds);
      _touchBroadcastEnabled = configuration.targetIds.isNotEmpty;
    });
  }

  void _stopTouchBroadcast() {
    _cancelActiveBroadcastPointers();
    setState(() {
      _touchBroadcastEnabled = false;
      _touchBroadcastTargetIds.clear();
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('触摸广播已紧急停止')));
  }

  void _cancelActiveBroadcastPointers() {
    for (final controller
        in _touchBroadcastTargetIds.map((id) => _windowInputs[id]).nonNulls) {
      for (final pointer in _activeBroadcastPointers.values) {
        unawaited(
          controller.sendPointer(
            ScrcpyPointerEvent(
              pointerId: pointer.pointerId,
              action: ScrcpyPointerAction.cancel,
              normalizedX: pointer.normalizedX,
              normalizedY: pointer.normalizedY,
              buttons: 0,
            ),
          ),
        );
      }
    }
    _activeBroadcastPointers.clear();
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
    });
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
    if (_touchBroadcastEnabled &&
        (_touchBroadcastSourceId == window.id ||
            _touchBroadcastTargetIds.contains(window.id))) {
      _cancelActiveBroadcastPointers();
    }
    setState(() {
      _windows.remove(window);
      _windowInputs.remove(window.id);
      _windowVideoSizes.remove(window.id);
      _sessionMetrics.remove(window.id);
      _touchBroadcastTargetIds.remove(window.id);
      if (_touchBroadcastSourceId == window.id ||
          _touchBroadcastTargetIds.isEmpty) {
        _touchBroadcastEnabled = false;
        _touchBroadcastSourceId = null;
        _touchBroadcastTargetIds.clear();
      }
      if (_expandedId == window.id) _expandedId = null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('设备墙 · ${widget.devices.length} 台 · ${_windows.length} 个窗口'),
      actions: <Widget>[
        IconButton(
          tooltip: '性能指标',
          onPressed: _showMetrics,
          icon: const Icon(Icons.monitor_heart_outlined),
        ),
        if (_touchBroadcastEnabled)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: _stopTouchBroadcast,
            icon: const Icon(Icons.touch_app),
            label: Text('停止同步（${_touchBroadcastTargetIds.length}）'),
          )
        else
          IconButton(
            tooltip: '配置触摸广播',
            onPressed: _windows.length < 2 ? null : _configureTouchBroadcast,
            icon: const Icon(Icons.touch_app_outlined),
          ),
        IconButton(
          tooltip: _selectionMode ? '退出批量选择' : '批量控制',
          onPressed: _batchRunning ? null : _toggleSelectionMode,
          icon: Icon(
            _selectionMode ? Icons.checklist_rtl : Icons.library_add_check,
          ),
        ),
        if (_selectionMode) ...[
          TextButton(
            onPressed: _selectAllDevices,
            child: Text('全选（${_selectedDeviceSerials.length}）'),
          ),
          PopupMenuButton<_DeviceWallBatchAction>(
            tooltip: '对选中设备执行',
            enabled: _selectedDeviceSerials.isNotEmpty && !_batchRunning,
            onSelected: _handleBatchAction,
            itemBuilder: (_) => const <PopupMenuEntry<_DeviceWallBatchAction>>[
              PopupMenuItem(
                value: _DeviceWallBatchAction.home,
                child: ListTile(leading: Icon(Icons.home), title: Text('Home')),
              ),
              PopupMenuItem(
                value: _DeviceWallBatchAction.back,
                child: ListTile(
                  leading: Icon(Icons.arrow_back),
                  title: Text('返回'),
                ),
              ),
              PopupMenuItem(
                value: _DeviceWallBatchAction.recents,
                child: ListTile(
                  leading: Icon(Icons.view_carousel),
                  title: Text('最近任务'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: _DeviceWallBatchAction.startApplication,
                child: ListTile(
                  leading: Icon(Icons.play_arrow),
                  title: Text('启动应用'),
                ),
              ),
              PopupMenuItem(
                value: _DeviceWallBatchAction.stopApplication,
                child: ListTile(leading: Icon(Icons.stop), title: Text('停止应用')),
              ),
            ],
          ),
        ],
        if (_batchRunning) ...[
          IconButton(
            tooltip: _batchTask!.isPaused ? '继续剩余任务' : '暂停剩余任务',
            onPressed: () => setState(() {
              _batchTask!.isPaused ? _batchTask!.resume() : _batchTask!.pause();
            }),
            icon: Icon(_batchTask!.isPaused ? Icons.play_arrow : Icons.pause),
          ),
          IconButton(
            tooltip: '紧急停止批量任务',
            onPressed: _batchTask!.cancel,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ] else if (_batchSnapshot != null)
          IconButton(
            tooltip: '查看上次批量结果',
            onPressed: _showBatchResults,
            icon: const Icon(Icons.fact_check_outlined),
          ),
        IconButton(
          tooltip: '新窗口默认画质',
          onPressed: _configureDefaultQuality,
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
                        focused: _focusedId == window.id,
                        expanded: _expandedId == window.id,
                        initialQuality: _defaultQualityProfile,
                        selectionMode: _selectionMode,
                        selected: _selectedDeviceSerials.contains(
                          window.device.serial,
                        ),
                        onSelectionChanged: (selected) => setState(() {
                          if (selected) {
                            _selectedDeviceSerials.add(window.device.serial);
                          } else {
                            _selectedDeviceSerials.remove(window.device.serial);
                          }
                        }),
                        onInputChanged: (controller, videoSize) =>
                            _updateWindowInput(
                              window.id,
                              controller,
                              videoSize,
                            ),
                        onPointer: (event) =>
                            _broadcastPointer(window.id, event),
                        onInputFailure: (error) =>
                            _handleInputFailure(window.id, error),
                        onMetrics: (snapshot) =>
                            _updateSessionMetrics(window.id, snapshot),
                        onFocus: () => _focus(window.id),
                        onToggleExpanded: () {
                          final id = window.id;
                          _focusedId = id;
                          unawaited(
                            _audioFocus.tryRequestFocus(window.audioFocusId),
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

enum _DeviceWallBatchAction {
  home,
  back,
  recents,
  startApplication,
  stopApplication,
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

  static const defaults = _DeviceWallQualityProfile(
    maxSize: 1280,
    maxFps: 30,
    bitRateMbps: 4,
  );

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

class _DeviceWallTile extends StatefulWidget {
  const _DeviceWallTile({
    required this.manager,
    required this.audioFocus,
    required this.window,
    required this.focused,
    required this.expanded,
    required this.initialQuality,
    required this.selectionMode,
    required this.selected,
    required this.onSelectionChanged,
    required this.onInputChanged,
    required this.onPointer,
    required this.onInputFailure,
    required this.onMetrics,
    required this.onFocus,
    required this.onToggleExpanded,
    this.onClose,
    super.key,
  });

  final ScrcpyManager manager;
  final ScrcpyAudioFocusManager audioFocus;
  final _DeviceWallWindow window;
  final bool focused;
  final bool expanded;
  final _DeviceWallQualityProfile initialQuality;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool> onSelectionChanged;
  final void Function(ScrcpyInputController? controller, Size? videoSize)
  onInputChanged;
  final ValueChanged<ScrcpyPointerEvent> onPointer;
  final ValueChanged<Object> onInputFailure;
  final ValueChanged<ScrcpySessionMetricsSnapshot?> onMetrics;
  final VoidCallback onFocus;
  final VoidCallback onToggleExpanded;
  final VoidCallback? onClose;

  @override
  State<_DeviceWallTile> createState() => _DeviceWallTileState();
}

class _DeviceWallTileState extends State<_DeviceWallTile> {
  ScrcpySession? _session;
  Future<void> _connectionChange = Future<void>.value();
  late _DeviceWallQualityProfile _appliedQuality = widget.initialQuality;
  final ValueNotifier<ScrcpySessionState> _metricsSessionState =
      ValueNotifier<ScrcpySessionState>(ScrcpySessionState.idle);
  late final ScrcpySessionMetricsCollector _metrics;
  ScrcpyVideoController? _video;
  ScrcpyAudioController? _audio;
  ScrcpyInputController? _input;
  ScrcpyInputController? _sourceInput;
  Object? _error;
  Object? _audioError;
  int _reconnectCount = 0;
  bool _disposing = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _metrics = ScrcpySessionMetricsCollector(
      sessionState: _metricsSessionState,
      videoCodec: ScrcpyVideoCodec.h264.serverName,
    )..addListener(_reportMetrics);
    widget.audioFocus.addListener(_handleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<ScrcpySession> _createSession(
    _DeviceWallQualityProfile qualityProfile,
  ) => widget.manager.createSession(
    deviceSerial: widget.window.device.serial,
    display: widget.window.displaySource,
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
      initiallyMuted: true,
    ),
    reconnectPolicy: const ScrcpyReconnectPolicy(maxAttempts: 5),
    id: widget.window.id,
  );

  void _handleChanged() {
    if (_disposing) return;
    final session = _session;
    if (session == null) return;
    final state = session.state.value;
    if (_metricsSessionState.value != state) {
      _metricsSessionState.value = state;
    }
    _connectionChange = _connectionChange
        .catchError((Object _) {})
        .then((_) => _syncSessionResources());
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    try {
      final session = await _createSession(_appliedQuality);
      if (_disposing) {
        await widget.manager.removeSession(session.id);
        return;
      }
      _session = session;
      _metricsSessionState.value = session.state.value;
      session.addListener(_handleChanged);
      await _syncSessionResources();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _syncSessionResources() async {
    final session = _session;
    if (_disposing || session == null) return;
    final video = session.video;
    final audio = session.audio;
    final sourceInput = session.input;
    final videoChanged = !identical(_video, video);
    final audioChanged = !identical(_audio, audio);
    final inputChanged = !identical(_sourceInput, sourceInput);
    if (!videoChanged && !audioChanged && !inputChanged) return;

    if (videoChanged) _video?.removeListener(_handleChanged);
    if (audioChanged) {
      _audio?.removeListener(_handleChanged);
      if (!widget.window.isVirtual) {
        await widget.audioFocus.unregister(widget.window.audioFocusId);
      }
    }
    if (_video != null && video != null && videoChanged) _reconnectCount++;

    final input = sourceInput == null
        ? null
        : _TouchBroadcastInputController(
            delegate: sourceInput,
            onPointer: widget.onPointer,
            onFailure: widget.onInputFailure,
          );
    if (videoChanged) video?.addListener(_handleChanged);
    if (audioChanged) audio?.addListener(_handleChanged);
    if (audio != null && !widget.window.isVirtual) {
      await widget.audioFocus.register(
        id: widget.window.audioFocusId,
        controller: audio,
        requestFocus: widget.focused || widget.audioFocus.focusedId == null,
      );
    }
    if (_disposing) {
      video?.removeListener(_handleChanged);
      audio?.removeListener(_handleChanged);
      if (!widget.window.isVirtual) {
        await widget.audioFocus.unregister(widget.window.audioFocusId);
      }
      return;
    }
    _video = video;
    _audio = audio;
    _sourceInput = sourceInput;
    _input = input;
    _error = null;
    _audioError = !widget.window.isVirtual && audio == null ? '设备未提供音频流' : null;
    _metrics.attach(
      video: video,
      audio: audio,
      reconnectCount: _reconnectCount,
    );
    widget.onInputChanged(input, video == null ? null : stateSize(video.value));
    if (mounted) setState(() {});
  }

  Future<void> _configureQuality() async {
    final profile = await showDialog<_DeviceWallQualityProfile>(
      context: context,
      builder: (_) => _QualityProfileDialog(
        title: '${widget.window.title} · 画质',
        initialValue: _appliedQuality,
      ),
    );
    if (!mounted || profile == null || profile == _appliedQuality) return;
    await _applyQuality(profile);
  }

  Future<void> _applyQuality(_DeviceWallQualityProfile qualityProfile) async {
    if (_disposing || qualityProfile == _appliedQuality) return;
    final operation = _connectionChange.catchError((Object _) {}).then((
      _,
    ) async {
      if (_disposing || qualityProfile == _appliedQuality) return;
      await _releaseControllers();
      final previous = _session;
      previous?.removeListener(_handleChanged);
      if (previous != null) await widget.manager.removeSession(previous.id);
      if (_disposing) return;

      final replacement = await _createSession(qualityProfile);
      if (_disposing) {
        await widget.manager.removeSession(replacement.id);
        return;
      }
      _session = replacement;
      _appliedQuality = qualityProfile;
      replacement.addListener(_handleChanged);
      await _syncSessionResources();
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
      final session = _session;
      if (session == null) return;
      await session.stop();
      if (_disposing) return;
      await session.start();
      await _syncSessionResources();
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
    _video?.removeListener(_handleChanged);
    _audio?.removeListener(_handleChanged);
    _video = null;
    _audio = null;
    _input = null;
    _sourceInput = null;
    widget.onInputChanged(null, null);
    _metrics.attach(reconnectCount: _reconnectCount);
    if (!widget.window.isVirtual) {
      await widget.audioFocus.unregister(widget.window.audioFocusId);
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _metrics.removeListener(_reportMetrics);
    _metrics.dispose();
    _metricsSessionState.dispose();
    widget.onMetrics(null);
    widget.audioFocus.removeListener(_handleChanged);
    final session = _session;
    session?.removeListener(_handleChanged);
    final cleanup = _connectionChange
        .catchError((Object _) {})
        .then((_) => _releaseControllers())
        .whenComplete(
          () => session == null
              ? Future<void>.value()
              : widget.manager.removeSession(session.id),
        );
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
            leading: widget.selectionMode
                ? Checkbox(
                    value: widget.selected,
                    onChanged: (value) =>
                        widget.onSelectionChanged(value ?? false),
                  )
                : Icon(
                    widget.window.device.connectionType ==
                            AdbConnectionType.network
                        ? Icons.wifi
                        : Icons.usb,
                  ),
            title: Text(widget.window.title),
            subtitle: Text(
              '${widget.window.device.redactedSerial}'
              '${widget.window.isVirtual ? ' · 虚拟屏' : ''} · $_statusLabel'
              '${_reconnectCount == 0 ? '' : ' · 重连 $_reconnectCount 次'}'
              ' · 流≤${_appliedQuality.maxSize}px/'
              '${_appliedQuality.maxFps}fps/'
              '${_formatMbps(_appliedQuality.bitRateMbps)}Mbps'
              '$_audioStatusSuffix',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: '截取当前画面',
                  onPressed: _session == null
                      ? null
                      : () => unawaited(
                          captureSessionScreenshot(
                            context,
                            _session!,
                            name: widget.window.id,
                          ),
                        ),
                  icon: const Icon(Icons.screenshot_monitor),
                ),
                if (_session != null)
                  SessionRecordingButton(
                    key: ValueKey('record-${_session!.id}'),
                    session: _session!,
                    name: widget.window.id,
                  ),
                IconButton(
                  tooltip: '设置此窗口画质（将重新连接一次）',
                  onPressed: _retrying ? null : _configureQuality,
                  icon: const Icon(Icons.tune),
                ),
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

  Widget _buildVideo() => ScrcpyView(
    session: _session!,
    inputController: _input,
    placeholder: const Center(child: CircularProgressIndicator()),
  );

  static Size? stateSize(ScrcpyVideoState state) {
    final width = state.width;
    final height = state.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width.toDouble(), height.toDouble());
  }

  String get _statusLabel => switch (_session?.state.value) {
    null => '等待启动',
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

  void _reportMetrics() => widget.onMetrics(_metrics.value);
}

class _QualityProfileDialog extends StatefulWidget {
  const _QualityProfileDialog({
    required this.title,
    required this.initialValue,
  });

  final String title;
  final _DeviceWallQualityProfile initialValue;

  @override
  State<_QualityProfileDialog> createState() => _QualityProfileDialogState();
}

final class _TouchBroadcastInputController
    implements ScrcpyInputController, ScrcpyScreenPowerInputController {
  const _TouchBroadcastInputController({
    required this.delegate,
    required this.onPointer,
    required this.onFailure,
  });

  final ScrcpyInputController delegate;
  final ValueChanged<ScrcpyPointerEvent> onPointer;
  final ValueChanged<Object> onFailure;

  @override
  Future<void> sendPointer(ScrcpyPointerEvent event) async {
    try {
      final status = delegate;
      if (status is ScrcpyInputTransportStatus &&
          !(status as ScrcpyInputTransportStatus).isAvailable) {
        throw StateError('scrcpy control transport is unavailable');
      }
      await delegate.sendPointer(event);
      if (status is ScrcpyInputTransportStatus &&
          !(status as ScrcpyInputTransportStatus).isAvailable) {
        throw StateError('scrcpy control transport closed during input');
      }
      onPointer(event);
    } catch (error) {
      onFailure(error);
      rethrow;
    }
  }

  @override
  Future<void> sendKey({required int keyCode, bool down = true}) =>
      delegate.sendKey(keyCode: keyCode, down: down);

  @override
  Future<void> sendText(String text) => delegate.sendText(text);

  @override
  Future<void> startApplication(ScrcpyApplicationLaunch application) =>
      delegate.startApplication(application);

  @override
  Future<void> resizeDisplay({required int width, required int height}) =>
      delegate.resizeDisplay(width: width, height: height);

  @override
  Stream<String> get clipboardChanges => delegate.clipboardChanges;

  @override
  Future<void> requestClipboard({ScrcpyCopyKey copyKey = ScrcpyCopyKey.none}) =>
      delegate.requestClipboard(copyKey: copyKey);

  @override
  Future<void> setClipboard(String text, {bool paste = false}) =>
      delegate.setClipboard(text, paste: paste);

  @override
  Future<void> sendBackOrScreenOn({bool down = true}) {
    final input = delegate;
    if (input is ScrcpyScreenPowerInputController) {
      return (input as ScrcpyScreenPowerInputController).sendBackOrScreenOn(
        down: down,
      );
    }
    return input.sendKey(keyCode: ScrcpyAndroidKeyCode.back, down: down);
  }
}

final class _TouchBroadcastConfiguration {
  const _TouchBroadcastConfiguration({
    required this.sourceId,
    required this.targetIds,
  });

  final String sourceId;
  final Set<String> targetIds;
}

class _TouchBroadcastDialog extends StatefulWidget {
  const _TouchBroadcastDialog({
    required this.windows,
    required this.videoSizes,
    required this.initialSourceId,
    required this.initialTargetIds,
  });

  final List<_DeviceWallWindow> windows;
  final Map<String, Size> videoSizes;
  final String? initialSourceId;
  final Set<String> initialTargetIds;

  @override
  State<_TouchBroadcastDialog> createState() => _TouchBroadcastDialogState();
}

class _TouchBroadcastDialogState extends State<_TouchBroadcastDialog> {
  late String? _sourceId = widget.initialSourceId;
  late final Set<String> _targetIds = widget.initialTargetIds.toSet();

  bool _compatible(String targetId) {
    final source = widget.videoSizes[_sourceId];
    final target = widget.videoSizes[targetId];
    if (source == null || target == null) return false;
    final sameOrientation =
        (source.width >= source.height) == (target.width >= target.height);
    if (!sameOrientation) return false;
    final sourceRatio = source.width / source.height;
    final targetRatio = target.width / target.height;
    return ((sourceRatio - targetRatio).abs() / sourceRatio) <= 0.15;
  }

  @override
  Widget build(BuildContext context) {
    _targetIds.removeWhere((id) => id == _sourceId || !_compatible(id));
    return AlertDialog(
      title: const Text('触摸广播'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '仅广播点击、拖动和长按。不广播键盘、文本、剪贴板、'
                '鼠标中键/右键及滚轮。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 16),
              Text('主控窗口', style: Theme.of(context).textTheme.titleSmall),
              RadioGroup<String>(
                groupValue: _sourceId,
                onChanged: (value) => setState(() {
                  _sourceId = value;
                  _targetIds.clear();
                }),
                child: Column(
                  children: <Widget>[
                    for (final window in widget.windows)
                      RadioListTile<String>(
                        value: window.id,
                        title: Text(window.title),
                        subtitle: Text(_windowDescription(window)),
                      ),
                  ],
                ),
              ),
              const Divider(),
              Text('同步目标', style: Theme.of(context).textTheme.titleSmall),
              for (final window in widget.windows)
                if (window.id != _sourceId)
                  CheckboxListTile(
                    value: _targetIds.contains(window.id),
                    title: Text(window.title),
                    subtitle: Text(
                      _compatible(window.id)
                          ? _windowDescription(window)
                          : '${_windowDescription(window)} · 宽高比/方向不兼容',
                    ),
                    onChanged: _compatible(window.id)
                        ? (selected) => setState(() {
                            selected ?? false
                                ? _targetIds.add(window.id)
                                : _targetIds.remove(window.id);
                          })
                        : null,
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
        FilledButton.icon(
          onPressed: _sourceId != null && _targetIds.isNotEmpty
              ? () => Navigator.pop(
                  context,
                  _TouchBroadcastConfiguration(
                    sourceId: _sourceId!,
                    targetIds: Set<String>.unmodifiable(_targetIds),
                  ),
                )
              : null,
          icon: const Icon(Icons.touch_app),
          label: const Text('开启同步'),
        ),
      ],
    );
  }

  String _windowDescription(_DeviceWallWindow window) {
    final size = widget.videoSizes[window.id];
    final dimensions = size == null
        ? '画面尺寸未就绪'
        : '${size.width.round()}×${size.height.round()}';
    return '${window.device.redactedSerial}'
        '${window.isVirtual ? ' · 虚拟屏' : ' · 主屏'} · $dimensions';
  }
}

class _QualityProfileDialogState extends State<_QualityProfileDialog> {
  late final TextEditingController _maxSize = TextEditingController(
    text: '${widget.initialValue.maxSize}',
  );
  late final TextEditingController _fps = TextEditingController(
    text: '${widget.initialValue.maxFps}',
  );
  late final TextEditingController _bitRate = TextEditingController(
    text: _formatNumber(widget.initialValue.bitRateMbps),
  );
  String? _error;

  @override
  void dispose() {
    _maxSize.dispose();
    _fps.dispose();
    _bitRate.dispose();
    super.dispose();
  }

  void _restoreDefaults() {
    const profile = _DeviceWallQualityProfile.defaults;
    _maxSize.text = '${profile.maxSize}';
    _fps.text = '${profile.maxFps}';
    _bitRate.text = _formatNumber(profile.bitRateMbps);
    setState(() => _error = null);
  }

  void _submit() {
    final maxSize = int.tryParse(_maxSize.text.trim());
    final maxFps = int.tryParse(_fps.text.trim());
    final bitRate = double.tryParse(_bitRate.text.trim());
    if (maxSize == null || maxSize < 64 || maxSize > 16384) {
      return _showError('最大边长需在 64–16384 之间');
    }
    if (maxFps == null || maxFps < 1 || maxFps > 240) {
      return _showError('帧率需在 1–240 之间');
    }
    if (bitRate == null || bitRate < 0.1 || bitRate > 100) {
      return _showError('码率需在 0.1–100 Mbps 之间');
    }

    Navigator.pop(
      context,
      _DeviceWallQualityProfile(
        maxSize: maxSize,
        maxFps: maxFps,
        bitRateMbps: bitRate,
      ),
    );
  }

  void _showError(String message) => setState(() => _error = message);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('修改现有窗口会重新建立一次视频会话；聚焦、全屏和滚动不会改变画质。'),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: _numberField(
                    controller: _maxSize,
                    label: '最大边长',
                    suffix: 'px',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _numberField(
                    controller: _fps,
                    label: '最大帧率',
                    suffix: 'fps',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _numberField(
                    controller: _bitRate,
                    label: '码率',
                    suffix: 'Mbps',
                    decimal: true,
                  ),
                ),
              ],
            ),
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

class _DeviceWallMetricsDialog extends StatelessWidget {
  const _DeviceWallMetricsDialog({
    required this.revision,
    required this.windows,
    required this.sessionMetrics,
    required this.processMetrics,
  });

  final ValueListenable<int> revision;
  final List<_DeviceWallWindow> windows;
  final Map<String, ScrcpySessionMetricsSnapshot> sessionMetrics;
  final ScrcpyProcessMetricsCollector processMetrics;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('设备墙性能指标'),
    content: SizedBox(
      width: 1050,
      height: 620,
      child: ValueListenableBuilder<int>(
        valueListenable: revision,
        builder: (context, _, child) {
          final process = processMetrics.value;
          final snapshots = sessionMetrics.values.toList(growable: false);
          final totalVideoRate = snapshots.fold<double>(
            0,
            (sum, item) => sum + item.videoBitRate,
          );
          final totalAudioRate = snapshots.fold<double>(
            0,
            (sum, item) => sum + item.audioBitRate,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Wrap(
                spacing: 20,
                runSpacing: 8,
                children: <Widget>[
                  Text('Session：${snapshots.length}'),
                  Text('视频总码率：${_rate(totalVideoRate)}'),
                  Text('音频总码率：${_rate(totalAudioRate)}'),
                  Text(
                    '进程 CPU：'
                    '${process == null ? '—' : '${process.cpuUsagePercent.toStringAsFixed(1)}%'}',
                  ),
                  Text(
                    '工作集：'
                    '${process == null ? '—' : _bytes(process.workingSetBytes)}',
                  ),
                  Text(
                    '私有内存：'
                    '${process == null ? '—' : _bytes(process.privateBytes)}',
                  ),
                  Text(
                    '进程线程：'
                    '${process == null || process.threadCount == 0 ? '—' : process.threadCount}',
                  ),
                  const Tooltip(
                    message: '当前平台未提供可靠的单 Session GPU 归因',
                    child: Text('进程/Session GPU：—'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '“卡顿”表示传输仍有新数据但解码画面未增加的连续区间；'
                '端到端延迟尚无统一时钟，因此不显示伪估算值。',
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Scrollbar(
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: DataTable(
                        columns: const <DataColumn>[
                          DataColumn(label: Text('窗口')),
                          DataColumn(label: Text('状态')),
                          DataColumn(label: Text('画面/解码器')),
                          DataColumn(label: Text('FPS')),
                          DataColumn(label: Text('视频码率')),
                          DataColumn(label: Text('音频码率')),
                          DataColumn(label: Text('帧/包')),
                          DataColumn(label: Text('音频播放/丢弃')),
                          DataColumn(label: Text('重连/错误/卡顿')),
                          DataColumn(label: Text('延迟/GPU')),
                        ],
                        rows: <DataRow>[
                          for (final window in windows)
                            _row(window, sessionMetrics[window.id]),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
    actions: <Widget>[
      TextButton.icon(
        onPressed: () => _copySnapshot(context),
        icon: const Icon(Icons.copy),
        label: const Text('复制 JSON 快照'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );

  DataRow _row(
    _DeviceWallWindow window,
    ScrcpySessionMetricsSnapshot? value,
  ) => DataRow(
    cells: <DataCell>[
      DataCell(Text(window.title)),
      DataCell(Text(value?.sessionState.name ?? '等待数据')),
      DataCell(
        Text(
          value == null
              ? '—'
              : '${value.width ?? 0}×${value.height ?? 0} / '
                    '${value.videoCodec ?? '—'} / ${value.decoder ?? '—'}',
        ),
      ),
      DataCell(Text(value?.framesPerSecond.toStringAsFixed(1) ?? '—')),
      DataCell(Text(value == null ? '—' : _rate(value.videoBitRate))),
      DataCell(Text(value == null ? '—' : _rate(value.audioBitRate))),
      DataCell(
        Text(
          value == null
              ? '—'
              : '${value.framesRendered}/${value.videoPacketsReceived}',
        ),
      ),
      DataCell(
        Text(
          value == null
              ? '—'
              : '${value.audioBuffersPlayed}/${value.audioBuffersDropped}',
        ),
      ),
      DataCell(
        Text(
          value == null
              ? '—'
              : '${value.reconnectCount}/${value.errorCount}/${value.stallCount}',
        ),
      ),
      const DataCell(Text('—/—')),
    ],
  );

  Future<void> _copySnapshot(BuildContext context) async {
    final payload = <String, Object?>{
      'exportedAt': DateTime.now().toIso8601String(),
      'process': processMetrics.value?.toJson(),
      'sessions': <String, Object?>{
        for (final window in windows)
          window.id: <String, Object?>{
            'title': window.title,
            'deviceSerial': window.device.redactedSerial,
            'virtualDisplay': window.isVirtual,
            'metrics': sessionMetrics[window.id]?.toJson(),
          },
      },
    };
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(payload)),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('性能快照已复制为 JSON')));
    }
  }

  static String _rate(double bitsPerSecond) => bitsPerSecond >= 1000000
      ? '${(bitsPerSecond / 1000000).toStringAsFixed(2)} Mbps'
      : '${(bitsPerSecond / 1000).toStringAsFixed(1)} Kbps';

  static String _bytes(int bytes) => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GiB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
}

class _BatchResultsDialog extends StatelessWidget {
  const _BatchResultsDialog({
    required this.label,
    required this.snapshot,
    required this.devices,
  });

  final String label;
  final AdbBatchSnapshot snapshot;
  final List<AdbDevice> devices;

  @override
  Widget build(BuildContext context) {
    final bySerial = <String, AdbDevice>{
      for (final device in devices) device.serial: device,
    };
    return AlertDialog(
      title: Text(label),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final item in snapshot.items.values)
              ListTile(
                leading: Icon(
                  _icon(item.state),
                  color: _color(context, item.state),
                ),
                title: Text(
                  bySerial[item.target]?.model ??
                      bySerial[item.target]?.device ??
                      '安卓设备',
                ),
                subtitle: Text(
                  '${bySerial[item.target]?.redactedSerial ?? item.target} · '
                  '${_label(item.state)}'
                  '${item.error == null ? '' : '\n${item.error}'}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  static String _label(AdbBatchItemState state) => switch (state) {
    AdbBatchItemState.queued => '等待中',
    AdbBatchItemState.running => '执行中',
    AdbBatchItemState.succeeded => '成功',
    AdbBatchItemState.failed => '失败',
    AdbBatchItemState.cancelled => '已取消',
    AdbBatchItemState.timedOut => '超时',
  };

  static IconData _icon(AdbBatchItemState state) => switch (state) {
    AdbBatchItemState.queued => Icons.schedule,
    AdbBatchItemState.running => Icons.sync,
    AdbBatchItemState.succeeded => Icons.check_circle,
    AdbBatchItemState.failed => Icons.error,
    AdbBatchItemState.cancelled => Icons.cancel,
    AdbBatchItemState.timedOut => Icons.timer_off,
  };

  static Color? _color(BuildContext context, AdbBatchItemState state) =>
      switch (state) {
        AdbBatchItemState.succeeded => Colors.green,
        AdbBatchItemState.failed ||
        AdbBatchItemState.timedOut => Theme.of(context).colorScheme.error,
        _ => null,
      };
}

class _ApplicationPicker extends StatefulWidget {
  const _ApplicationPicker({required this.applications, this.title = '选择应用'});

  final List<AdbApplication> applications;
  final String title;

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
      title: Text(widget.title),
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
