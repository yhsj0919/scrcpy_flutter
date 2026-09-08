import 'dart:async';

import 'package:flutter/material.dart';
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

import 'device_wall.dart';
import 'screenshot_helper.dart';
import 'virtual_display_defaults.dart';
import 'virtual_display_workspace.dart';

extension on ScrcpyClient {
  AdbToolkit get adbToolkit => AdbToolkit(adbClient);
}

void main() => runApp(DeviceWallDemo(client: createDefaultScrcpyClient()));

class DeviceWallDemo extends StatelessWidget {
  const DeviceWallDemo({required this.client, super.key});

  final ScrcpyClient client;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'scrcpy_flutter Demo',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      useMaterial3: true,
    ),
    home: DeviceDiscoveryPage(client: client),
  );
}

class DeviceDiscoveryPage extends StatefulWidget {
  const DeviceDiscoveryPage({required this.client, super.key});

  final ScrcpyClient client;

  @override
  State<DeviceDiscoveryPage> createState() => _DeviceDiscoveryPageState();
}

class _DeviceDiscoveryPageState extends State<DeviceDiscoveryPage> {
  late final AdbDeviceMonitor _deviceMonitor;
  StreamSubscription<AdbDeviceSnapshot>? _deviceSubscription;
  List<AdbDevice> _devices = const <AdbDevice>[];
  Object? _error;
  bool _loading = false;
  bool _changingConnection = false;
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _deviceMonitor = AdbDeviceMonitor(widget.client.adbToolkit);
    _deviceSubscription = _deviceMonitor.snapshots.listen(
      _applyDeviceSnapshot,
      onError: (Object error) {
        if (mounted) setState(() => _error = error);
      },
    );
    _startMonitor();
  }

  Future<void> _startMonitor() async {
    setState(() => _loading = true);
    try {
      await _deviceMonitor.start();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyDeviceSnapshot(AdbDeviceSnapshot snapshot) {
    if (!mounted) return;
    final hadDevices = _lastUpdated != null;
    setState(() {
      _devices = snapshot.devices;
      _lastUpdated = snapshot.observedAt;
      _error = null;
    });
    if (hadDevices &&
        (snapshot.added.isNotEmpty ||
            snapshot.removed.isNotEmpty ||
            snapshot.changed.isNotEmpty)) {
      _showMessage(
        '设备变化：+${snapshot.added.length} '
        '-${snapshot.removed.length} 状态${snapshot.changed.length}',
      );
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _deviceMonitor.refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _connect() async {
    final endpoint = await showDialog<AdbEndpoint>(
      context: context,
      builder: (context) => const _ConnectDeviceDialog(),
    );
    if (endpoint == null || _changingConnection) return;
    setState(() {
      _changingConnection = true;
      _error = null;
    });
    try {
      await widget.client.adbToolkit.connect(endpoint);
      await _refreshAfterConnectionChange();
      if (mounted) _showMessage('已连接 ${endpoint.authority}');
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _changingConnection = false);
    }
  }

  Future<void> _disconnect(AdbDevice device) async {
    if (_changingConnection) return;
    final endpoint = AdbEndpoint.tryParse(device.serial);
    if (endpoint == null) {
      setState(() => _error = '无法解析网络设备地址：${device.redactedSerial}');
      return;
    }
    setState(() {
      _changingConnection = true;
      _error = null;
    });
    try {
      await widget.client.adbToolkit.disconnect(endpoint);
      await _refreshAfterConnectionChange();
      if (mounted) _showMessage('已断开 ${endpoint.authority}');
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _changingConnection = false);
    }
  }

  Future<void> _connectPairedDevice(AdbDevice device) async {
    if (_changingConnection) return;
    final endpoint = AdbEndpoint.tryParse(device.serial);
    if (endpoint == null) {
      setState(() => _error = '无法解析已配对设备地址：${device.redactedSerial}');
      return;
    }
    setState(() {
      _changingConnection = true;
      _error = null;
    });
    try {
      await widget.client.adbToolkit.connect(endpoint);
      await _refreshAfterConnectionChange();
      if (mounted) _showMessage('已连接配对设备 ${endpoint.authority}');
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _changingConnection = false);
    }
  }

  Future<void> _pair() async {
    List<AdbMdnsService> discoveredServices = const <AdbMdnsService>[];
    try {
      discoveredServices = await widget.client.adbToolkit
          .discoverMdnsServices();
    } catch (_) {
      // Manual entry remains available when mDNS is unavailable.
    }
    if (!mounted) return;
    final request = await showDialog<_PairDeviceRequest>(
      context: context,
      builder: (context) =>
          _PairDeviceDialog(discoveredServices: discoveredServices),
    );
    if (request == null || _changingConnection) return;
    setState(() {
      _changingConnection = true;
      _error = null;
    });
    try {
      await widget.client.adbToolkit.pair(
        request.pairingEndpoint,
        request.pairingCode,
      );
      if (request.connectionEndpoint case final endpoint?) {
        await widget.client.adbToolkit.connect(endpoint);
      }
      await _refreshAfterConnectionChange();
      if (mounted) {
        _showMessage(request.connectionEndpoint == null ? '配对成功' : '配对并连接成功');
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _changingConnection = false);
    }
  }

  Future<void> _refreshAfterConnectionChange() async {
    await _deviceMonitor.refresh();
  }

  @override
  void dispose() {
    unawaited(_deviceSubscription?.cancel());
    unawaited(_deviceMonitor.close());
    super.dispose();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.client.runtimeInfo;
    return Scaffold(
      appBar: AppBar(
        title: const Text('scrcpy_flutter 设备验证'),
        actions: <Widget>[
          IconButton(
            tooltip: '打开设备墙',
            onPressed: _devices.any((device) => device.isReady)
                ? () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => DeviceWallPage(
                        client: widget.client,
                        devices: _devices
                            .where((device) => device.isReady)
                            .toList(growable: false),
                      ),
                    ),
                  )
                : null,
            icon: const Icon(Icons.grid_view),
          ),
          IconButton(
            tooltip: '批量应用管理',
            onPressed: _devices.any((device) => device.isReady)
                ? () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => BatchPackagePage(
                        client: widget.client,
                        devices: _devices
                            .where((device) => device.isReady)
                            .toList(),
                      ),
                    ),
                  )
                : null,
            icon: const Icon(Icons.apps),
          ),
          TextButton.icon(
            onPressed: _changingConnection ? null : _connect,
            icon: const Icon(Icons.add_link),
            label: const Text('网络连接'),
          ),
          TextButton.icon(
            onPressed: _changingConnection ? null : _pair,
            icon: const Icon(Icons.password),
            label: const Text('验证码配对'),
          ),
          IconButton(
            tooltip: '刷新设备',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          Card(
            child: ListTile(
              leading: const Icon(Icons.terminal),
              title: Text(
                runtime?.usesBundledAdb == true ? '内置 ADB' : '平台 ADB',
              ),
              subtitle: Text(runtime?.adbExecutablePath ?? '当前平台未提供 ADB 路径'),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.monitor_heart),
              title: const Text('原生视频后端'),
              subtitle: const Text('scrcpy 帧协议 · Windows Media Foundation'),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('scrcpy server 4.1 · Native Texture'),
              subtitle: Text(
                runtime?.scrcpyServerPath == null
                    ? '当前平台未提供 scrcpy server'
                    : '${runtime!.scrcpyServerPath}\n'
                          '版本 ${runtime.scrcpyServerVersion ?? '自定义'} · '
                          '${runtime.scrcpyServerSha256 == null ? '自定义资源' : '启动时校验 SHA-256'}',
              ),
              isThreeLine: runtime?.scrcpyServerPath != null,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.devices),
              title: Text(
                '设备 ${_devices.length} 台 · '
                '可用 ${_devices.where((device) => device.isReady).length} 台',
              ),
              subtitle: Text(
                _lastUpdated == null
                    ? '尚未刷新'
                    : '最后刷新 ${_formatTime(_lastUpdated!)}',
              ),
            ),
          ),
          if (_loading || _changingConnection) const LinearProgressIndicator(),
          if (_error case final error?)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: const Text('操作失败'),
                subtitle: Text('$error'),
              ),
            )
          else if (!_loading && _devices.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.phonelink_off),
                title: Text('未发现设备'),
                subtitle: Text('请连接 Android 设备并确认 USB 调试授权，然后点击刷新。'),
              ),
            )
          else
            ..._devices.map(
              (device) => _DeviceTile(
                client: widget.client,
                device: device,
                connectionBusy: _changingConnection,
                onConnect: device.state == AdbDeviceState.paired
                    ? () => _connectPairedDevice(device)
                    : null,
                onDisconnect:
                    device.connectionType == AdbConnectionType.network &&
                        device.state != AdbDeviceState.paired
                    ? () => _disconnect(device)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  String _formatTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}';
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.client,
    required this.device,
    required this.connectionBusy,
    this.onConnect,
    this.onDisconnect,
  });

  final ScrcpyClient client;
  final AdbDevice device;
  final bool connectionBusy;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(
        device.connectionType == AdbConnectionType.network
            ? Icons.wifi
            : Icons.usb,
      ),
      title: Text(device.model ?? device.device ?? 'Android 设备'),
      subtitle: Text(
        '${device.redactedSerial} · ${_connectionLabel(device.connectionType)} · '
        '${_stateLabel(device.state)}'
        '${device.lastSeenAt == null ? '' : ' · ${_formatDeviceTime(device.lastSeenAt!)}'}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Tooltip(
            message: _stateHint(device.state),
            child: Icon(
              _stateIcon(device.state),
              color: _stateColor(device.state),
            ),
          ),
          if (onConnect != null)
            IconButton(
              tooltip: '连接已配对设备',
              onPressed: connectionBusy ? null : onConnect,
              icon: const Icon(Icons.link),
            ),
          if (onDisconnect != null)
            IconButton(
              tooltip: '断开网络设备',
              onPressed: connectionBusy ? null : onDisconnect,
              icon: const Icon(Icons.link_off),
            ),
        ],
      ),
      onTap: device.isReady
          ? () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) =>
                    DeviceSessionPage(client: client, device: device),
              ),
            )
          : null,
    ),
  );

  static String _connectionLabel(AdbConnectionType type) => switch (type) {
    AdbConnectionType.usb => 'USB',
    AdbConnectionType.network => '网络',
    AdbConnectionType.unknown => '未知连接',
  };

  static String _stateLabel(AdbDeviceState state) => switch (state) {
    AdbDeviceState.device => '可用',
    AdbDeviceState.unauthorized => '等待授权',
    AdbDeviceState.offline => '离线',
    AdbDeviceState.recovery => 'Recovery 模式',
    AdbDeviceState.bootloader => 'Bootloader 模式',
    AdbDeviceState.sideload => 'Sideload 模式',
    AdbDeviceState.noPermissions => '无访问权限',
    AdbDeviceState.paired => '已配对，未连接',
    AdbDeviceState.unknown => '未知状态',
  };

  static String _stateHint(AdbDeviceState state) => switch (state) {
    AdbDeviceState.device => '设备可用，点击进入画面',
    AdbDeviceState.unauthorized => '请在 Android 设备上确认 USB 调试授权',
    AdbDeviceState.offline => '设备离线，请检查连接后刷新',
    AdbDeviceState.noPermissions => '当前进程没有访问该设备的权限',
    AdbDeviceState.paired => '设备已配对，连接后可启动 scrcpy 会话',
    _ => '该状态暂不支持启动 scrcpy 会话',
  };

  static IconData _stateIcon(AdbDeviceState state) => switch (state) {
    AdbDeviceState.device => Icons.check_circle,
    AdbDeviceState.unauthorized => Icons.key_off,
    AdbDeviceState.offline => Icons.cloud_off,
    AdbDeviceState.recovery => Icons.restore,
    AdbDeviceState.bootloader => Icons.build_circle,
    AdbDeviceState.sideload => Icons.system_update,
    AdbDeviceState.noPermissions => Icons.lock,
    AdbDeviceState.paired => Icons.link,
    AdbDeviceState.unknown => Icons.help,
  };

  static Color _stateColor(AdbDeviceState state) => switch (state) {
    AdbDeviceState.device => Colors.green,
    AdbDeviceState.unauthorized => Colors.orange,
    AdbDeviceState.offline => Colors.grey,
    AdbDeviceState.noPermissions => Colors.red,
    AdbDeviceState.paired => Colors.indigo,
    _ => Colors.blueGrey,
  };

  static String _formatDeviceTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}';
}

class _ConnectDeviceDialog extends StatefulWidget {
  const _ConnectDeviceDialog();

  @override
  State<_ConnectDeviceDialog> createState() => _ConnectDeviceDialogState();
}

class _ConnectDeviceDialogState extends State<_ConnectDeviceDialog> {
  final _formKey = GlobalKey<FormState>();
  final _addressController = TextEditingController();

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('连接网络设备'),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _addressController,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '设备地址',
          hintText: '192.168.1.100:5555',
          helperText: '省略端口时使用 5555',
        ),
        validator: (value) => AdbEndpoint.tryParse(value ?? '') == null
            ? '请输入有效的主机名、IP 地址和端口'
            : null,
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('连接')),
    ],
  );

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(AdbEndpoint.tryParse(_addressController.text));
  }
}

final class _PairDeviceRequest {
  const _PairDeviceRequest({
    required this.pairingEndpoint,
    required this.pairingCode,
    this.connectionEndpoint,
  });

  final AdbEndpoint pairingEndpoint;
  final String pairingCode;
  final AdbEndpoint? connectionEndpoint;
}

class _PairDeviceDialog extends StatefulWidget {
  const _PairDeviceDialog({required this.discoveredServices});

  final List<AdbMdnsService> discoveredServices;

  @override
  State<_PairDeviceDialog> createState() => _PairDeviceDialogState();
}

class _PairDeviceDialogState extends State<_PairDeviceDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pairingAddressController = TextEditingController();
  final _pairingCodeController = TextEditingController();
  final _connectionAddressController = TextEditingController();

  @override
  void dispose() {
    _pairingAddressController.dispose();
    _pairingCodeController.dispose();
    _connectionAddressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Wireless Debugging 配对'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.discoveredServices.isNotEmpty) ...<Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '发现的无线调试服务',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final service in widget.discoveredServices)
                    ActionChip(
                      avatar: Icon(
                        service.type == AdbMdnsServiceType.pairing
                            ? Icons.password
                            : Icons.link,
                        size: 18,
                      ),
                      label: Text(
                        '${service.type == AdbMdnsServiceType.pairing ? '配对' : '连接'} '
                        '${service.endpoint.authority}',
                      ),
                      onPressed: () {
                        if (service.type == AdbMdnsServiceType.pairing) {
                          _pairingAddressController.text =
                              service.endpoint.authority;
                          final matchingConnection = widget.discoveredServices
                              .where(
                                (candidate) =>
                                    candidate.type ==
                                        AdbMdnsServiceType.connect &&
                                    candidate.endpoint.host ==
                                        service.endpoint.host,
                              )
                              .lastOrNull;
                          if (matchingConnection != null) {
                            _connectionAddressController.text =
                                matchingConnection.endpoint.authority;
                          }
                        } else {
                          _connectionAddressController.text =
                              service.endpoint.authority;
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _pairingAddressController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '配对地址',
                hintText: '192.168.1.100:37123',
              ),
              validator: (value) => AdbEndpoint.tryParse(value ?? '') == null
                  ? '请输入手机显示的配对 IP 和端口'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pairingCodeController,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '六位配对码'),
              validator: (value) => RegExp(r'^\d{6}$').hasMatch(value ?? '')
                  ? null
                  : '请输入六位数字配对码',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _connectionAddressController,
              decoration: const InputDecoration(
                labelText: '连接地址（可选）',
                hintText: '192.168.1.100:调试端口',
                helperText: '配对端口和连接端口通常不同',
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) return null;
                return AdbEndpoint.tryParse(value) == null
                    ? '请输入有效的连接 IP 和端口'
                    : null;
              },
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('配对')),
    ],
  );

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final connectionAddress = _connectionAddressController.text.trim();
    Navigator.of(context).pop(
      _PairDeviceRequest(
        pairingEndpoint: AdbEndpoint.tryParse(_pairingAddressController.text)!,
        pairingCode: _pairingCodeController.text,
        connectionEndpoint: connectionAddress.isEmpty
            ? null
            : AdbEndpoint.tryParse(connectionAddress),
      ),
    );
  }
}

class DeviceSessionPage extends StatefulWidget {
  const DeviceSessionPage({
    required this.client,
    required this.device,
    this.displaySource = const ScrcpyDisplaySource.main(),
    super.key,
  });

  final ScrcpyClient client;
  final AdbDevice device;
  final ScrcpyDisplaySource displaySource;

  @override
  State<DeviceSessionPage> createState() => _DeviceSessionPageState();
}

enum _AudioPlaybackTarget { computer, phone }

class _DeviceSessionPageState extends State<DeviceSessionPage> {
  late final ScrcpyManager _scrcpy;
  ScrcpySession? _session;
  AdbDeviceStatusMonitor? _statusMonitor;
  StreamSubscription<AdbDeviceStatus>? _statusSubscription;
  Object? _error;
  ScrcpyVideoController? _videoController;
  ScrcpyAudioController? _audioController;
  Object? _audioError;
  bool _audioMuted = false;
  double _audioVolume = 1;
  _AudioPlaybackTarget _audioPlaybackTarget = _AudioPlaybackTarget.computer;
  ScrcpyInputController? _inputController;
  ScrcpyClipboardSynchronizer? _clipboardSync;
  ScrcpyVideoConnectionInfo? _connectionInfo;
  ScrcpyVideoCodecInfo? _activeCodec;
  int _reconnectCount = 0;
  bool _clipboardSyncEnabled = false;
  bool _startingVideo = false;
  int _maxSize = 1280;
  int _maxFps = 30;
  int _bitRateMbps = 4;
  ScrcpyVideoCodec _videoCodec = ScrcpyVideoCodec.h264;
  String? _videoEncoder;
  ScrcpyVideoCapabilities? _videoCapabilities;
  AdbDeviceDetails? _deviceDetails;
  AdbDeviceStatus? _deviceStatus;
  int _statusIntervalSeconds = 5;
  int _statusMonitorGeneration = 0;
  bool _loadingDeviceDetails = true;
  int? _virtualDisplayWidth;
  int? _virtualDisplayHeight;
  final _textInputController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scrcpy = ScrcpyManager.fromClient(widget.client, maxSessions: 1);
    final source = widget.displaySource;
    if (source is ScrcpyVirtualDisplaySource) {
      _virtualDisplayWidth = source.width ?? 1280;
      _virtualDisplayHeight = source.height ?? 960;
    }
    unawaited(_restartStatusMonitor(_statusIntervalSeconds));
    _prepare();
  }

  Future<ScrcpySession> _createSession() => _scrcpy.createSession(
    deviceSerial: widget.device.serial,
    controlEnabled: true,
    audioEnabled: _audioPlaybackTarget == _AudioPlaybackTarget.computer,
    audio: const ScrcpyAudioOptions(
      codec: ScrcpyAudioCodec.opus,
      source: ScrcpyAudioSource.automatic,
      duplicateOnDevice: false,
    ),
    display: widget.displaySource,
    reconnectPolicy: const ScrcpyReconnectPolicy(maxAttempts: 5),
    video: ScrcpyVideoOptions(
      maxSize: _maxSize,
      maxFps: _maxFps,
      bitRate: _bitRateMbps * 1000 * 1000,
      codec: _videoCodec,
      encoder: _videoEncoder,
    ),
    start: false,
  );

  Future<void> _restartStatusMonitor(int seconds) async {
    final generation = ++_statusMonitorGeneration;
    await _statusSubscription?.cancel();
    await _statusMonitor?.close();
    if (!mounted || generation != _statusMonitorGeneration) return;
    final monitor = widget.client.adbToolkit.status(
      widget.device.serial,
      interval: Duration(seconds: seconds),
    );
    _statusMonitor = monitor;
    _statusSubscription = monitor.statuses.listen((status) {
      if (mounted && identical(_statusMonitor, monitor)) {
        setState(() => _deviceStatus = status);
      }
    });
    setState(() {
      _statusIntervalSeconds = seconds;
      _deviceStatus = null;
    });
    try {
      await monitor.start();
    } catch (error) {
      if (mounted && identical(_statusMonitor, monitor)) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _replaceSession(void Function() updateOptions) async {
    final previous = _session;
    if (previous != null) {
      previous.removeListener(_handleSessionChanged);
      await _scrcpy.removeSession(previous.id);
    }
    updateOptions();
    final replacement = await _createSession();
    replacement.addListener(_handleSessionChanged);
    if (mounted) setState(() => _session = replacement);
  }

  Future<void> _prepare() async {
    setState(() => _error = null);
    try {
      final session = await _createSession();
      session.addListener(_handleSessionChanged);
      if (!mounted) {
        await _scrcpy.removeSession(session.id);
        return;
      }
      setState(() => _session = session);
      final details = await widget.client.adbToolkit.getDeviceDetails(
        widget.device,
      );
      if (mounted) {
        setState(() {
          _deviceDetails = details;
          _loadingDeviceDetails = false;
        });
      }
      try {
        final capabilities = await widget.client.probeVideoCapabilities(
          widget.device.serial,
        );
        if (mounted) setState(() => _videoCapabilities = capabilities);
      } catch (_) {
        // Device details and H.264 auto-selection remain usable without a probe.
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingDeviceDetails = false;
          _error = error;
        });
      }
    }
  }

  Future<void> _startVideo() async {
    if (_startingVideo || _videoController != null) return;
    final session = _session;
    if (session == null) return;
    setState(() {
      _startingVideo = true;
      _error = null;
    });
    try {
      await session.start();
      await _syncSessionResources();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _startingVideo = false);
    }
  }

  void _handleSessionChanged() {
    unawaited(_syncSessionResources());
  }

  Future<void> _syncSessionResources() async {
    final session = _session;
    if (session == null) return;
    final previousVideo = _videoController;
    final previousAudio = _audioController;
    final previousClipboard = _clipboardSync;
    final controller = session.video;
    final audio = session.audio;
    final input = session.input;
    if (identical(previousVideo, controller) &&
        identical(previousAudio, audio) &&
        identical(_inputController, input)) {
      if (mounted) setState(() {});
      return;
    }
    if (!identical(_inputController, input)) {
      await previousClipboard?.stop();
    }
    if (!mounted || !identical(_session, session)) return;
    if (previousVideo != null && controller != null) _reconnectCount++;
    final clipboard = input == null
        ? null
        : ScrcpyClipboardSynchronizer(
            input,
            onError: (error, _) {
              if (mounted) setState(() => _error = error);
            },
          );
    setState(() {
      _videoController = controller;
      _audioController = audio;
      _inputController = input;
      _connectionInfo = null;
      _activeCodec = null;
      _clipboardSync = clipboard;
      _clipboardSyncEnabled = false;
      _error = null;
      _audioError = null;
    });
    if (audio != null) {
      try {
        await audio.setVolume(_audioVolume);
        await audio.setMuted(_audioMuted);
      } catch (error) {
        if (mounted) setState(() => _audioError = error);
      }
    }
  }

  Future<void> _stopVideo() async {
    final session = _session;
    if (session == null || _videoController == null) return;
    await _clipboardSync?.stop();
    await session.stop();
    if (mounted) {
      setState(() {
        _videoController = null;
        _audioController = null;
        _audioError = null;
        _inputController = null;
        _clipboardSync = null;
        _clipboardSyncEnabled = false;
        _connectionInfo = null;
        _activeCodec = null;
        _reconnectCount = 0;
      });
    }
  }

  Future<void> _setAudioMuted(bool muted) async {
    _audioMuted = muted;
    try {
      await _audioController?.setMuted(muted);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _audioError = error);
    }
  }

  Future<void> _setAudioVolume(double volume) async {
    _audioVolume = volume;
    try {
      await _audioController?.setVolume(volume);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _audioError = error);
    }
  }

  Future<void> _setAudioPlaybackTarget(_AudioPlaybackTarget target) async {
    if (target == _audioPlaybackTarget || _startingVideo) return;
    final wasRunning = _videoController != null;
    if (wasRunning) await _stopVideo();
    final previous = _session;
    if (previous != null) {
      previous.removeListener(_handleSessionChanged);
      await _scrcpy.removeSession(previous.id);
    }
    if (!mounted) return;
    setState(() {
      _audioPlaybackTarget = target;
      _session = null;
      _error = null;
    });
    try {
      final replacement = await _createSession();
      replacement.addListener(_handleSessionChanged);
      if (!mounted) {
        await _scrcpy.removeSession(replacement.id);
        return;
      }
      setState(() => _session = replacement);
      if (wasRunning) await _startVideo();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _sendAndroidKey(int keyCode) async {
    final session = _session;
    if (session == null || !session.isControllable) return;
    try {
      await session.key(keyCode);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _resizeVirtualDisplay(int width, int height) async {
    final session = _session;
    if (session == null || !session.isControllable) return;
    final alignedWidth = width.clamp(2, 0xffff) & ~1;
    final alignedHeight = height.clamp(2, 0xffff) & ~1;
    try {
      await session.resizeDisplay(width: alignedWidth, height: alignedHeight);
      if (mounted) {
        setState(() {
          _virtualDisplayWidth = alignedWidth;
          _virtualDisplayHeight = alignedHeight;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _swapVirtualDisplayOrientation() async {
    final width = _virtualDisplayWidth;
    final height = _virtualDisplayHeight;
    if (width == null || height == null) return;
    await _resizeVirtualDisplay(height, width);
  }

  Future<void> _sendText() async {
    final session = _session;
    final text = _textInputController.text;
    if (session == null || !session.isControllable || text.isEmpty) return;
    try {
      await session.sendText(text);
      _textInputController.clear();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _pinch({required bool zoomIn}) async {
    final session = _session;
    if (session == null || !session.isControllable) return;
    try {
      await session.pinch(
        startSpan: zoomIn ? 0.18 : 0.5,
        endSpan: zoomIn ? 0.5 : 0.18,
      );
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _toggleClipboardSync(bool enabled) async {
    final synchronizer = _clipboardSync;
    if (synchronizer == null) return;
    try {
      if (enabled) {
        await synchronizer.start();
      } else {
        await synchronizer.stop();
      }
      if (mounted) setState(() => _clipboardSyncEnabled = enabled);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _pushClipboard({bool paste = false}) async {
    try {
      await _clipboardSync?.pushHostToDevice(paste: paste);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _pullClipboard(ScrcpyCopyKey copyKey) async {
    try {
      await _clipboardSync?.pullDeviceToHost(copyKey: copyKey);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _statusMonitorGeneration++;
    unawaited(_statusSubscription?.cancel());
    unawaited(_statusMonitor?.close());
    unawaited(_clipboardSync?.stop());
    _textInputController.dispose();
    _session?.removeListener(_handleSessionChanged);
    unawaited(_scrcpy.close().whenComplete(_scrcpy.dispose));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.displaySource is ScrcpyVirtualDisplaySource
            ? '${widget.device.model ?? '设备'} · 虚拟屏'
            : widget.device.model ?? '设备详情',
      ),
      actions: <Widget>[
        IconButton(
          tooltip: '截取当前画面',
          onPressed: _session == null
              ? null
              : () => unawaited(
                  captureSessionScreenshot(
                    context,
                    _session!,
                    name: widget.device.redactedSerial,
                  ),
                ),
          icon: const Icon(Icons.screenshot_monitor),
        ),
        if (_session != null)
          SessionRecordingButton(
            key: ValueKey('record-${_session!.id}'),
            session: _session!,
            name: widget.device.redactedSerial,
          ),
        IconButton(
          tooltip: '虚拟屏工作台',
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => VirtualDisplayWorkspacePage(
                client: widget.client,
                device: widget.device,
              ),
            ),
          ),
          icon: const Icon(Icons.dashboard_customize),
        ),
        IconButton(
          tooltip: '应用列表',
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => DeviceApplicationsPage(
                client: widget.client,
                device: widget.device,
                virtualDisplayInput:
                    widget.displaySource is ScrcpyVirtualDisplaySource
                    ? _inputController
                    : null,
              ),
            ),
          ),
          icon: const Icon(Icons.apps),
        ),
        IconButton(
          tooltip: '文件管理',
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => DeviceFileManagerPage(
                client: widget.client,
                device: widget.device,
              ),
            ),
          ),
          icon: const Icon(Icons.folder),
        ),
      ],
    ),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: ListView(
        children: <Widget>[
          SizedBox(
            height: 420,
            child: ColoredBox(
              color: const Color(0xff101218),
              child: _session == null || _videoController == null
                  ? const Center(child: Text('点击下方按钮启动真机画面'))
                  : ScrcpyView(
                      session: _session!,
                      placeholder: const Center(
                        child: CircularProgressIndicator(),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Text('设备：${widget.device.redactedSerial}'),
          const SizedBox(height: 12),
          _buildDeviceDetailsCard(),
          if (_deviceStatus case final status?) ...<Widget>[
            const SizedBox(height: 12),
            _buildDeviceStatusCard(status),
          ],
          if (widget.displaySource is ScrcpyVirtualDisplaySource) ...<Widget>[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.aspect_ratio),
                title: Text(
                  '虚拟屏：${_virtualDisplayWidth ?? 0}×${_virtualDisplayHeight ?? 0}',
                ),
                subtitle: const Text('运行中可交换宽高；应用也可能按自身方向请求旋转'),
                trailing: FilledButton.tonalIcon(
                  onPressed: _inputController == null
                      ? null
                      : _swapVirtualDisplayOrientation,
                  icon: const Icon(Icons.screen_rotation),
                  label: const Text('切换横竖'),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: <Widget>[
              SizedBox(
                width: 160,
                child: DropdownButtonFormField<_AudioPlaybackTarget>(
                  isExpanded: true,
                  initialValue: _audioPlaybackTarget,
                  decoration: const InputDecoration(labelText: '声音播放位置'),
                  items: const <DropdownMenuItem<_AudioPlaybackTarget>>[
                    DropdownMenuItem(
                      value: _AudioPlaybackTarget.computer,
                      child: Text('电脑播放'),
                    ),
                    DropdownMenuItem(
                      value: _AudioPlaybackTarget.phone,
                      child: Text('手机播放'),
                    ),
                  ],
                  onChanged: _startingVideo
                      ? null
                      : (value) {
                          if (value != null) {
                            unawaited(_setAudioPlaybackTarget(value));
                          }
                        },
                ),
              ),
              SizedBox(
                width: 150,
                child: DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: _maxSize,
                  decoration: const InputDecoration(labelText: '最大尺寸'),
                  items: const <int>[720, 1080, 1280, 1600, 1920]
                      .map(
                        (value) => DropdownMenuItem<int>(
                          value: value,
                          child: Text('$value'),
                        ),
                      )
                      .toList(),
                  onChanged: _videoController == null
                      ? (value) => _replaceSession(() => _maxSize = value!)
                      : null,
                ),
              ),
              SizedBox(
                width: 130,
                child: DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: _maxFps,
                  decoration: const InputDecoration(labelText: '最大 FPS'),
                  items: const <int>[15, 30, 45, 60]
                      .map(
                        (value) => DropdownMenuItem<int>(
                          value: value,
                          child: Text('$value'),
                        ),
                      )
                      .toList(),
                  onChanged: _videoController == null
                      ? (value) => _replaceSession(() => _maxFps = value!)
                      : null,
                ),
              ),
              SizedBox(
                width: 140,
                child: DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: _bitRateMbps,
                  decoration: const InputDecoration(labelText: '码率 Mbps'),
                  items: const <int>[1, 2, 4, 8, 12]
                      .map(
                        (value) => DropdownMenuItem<int>(
                          value: value,
                          child: Text('$value'),
                        ),
                      )
                      .toList(),
                  onChanged: _videoController == null
                      ? (value) => _replaceSession(() => _bitRateMbps = value!)
                      : null,
                ),
              ),
              SizedBox(
                width: 185,
                child: DropdownButtonFormField<ScrcpyVideoCodec>(
                  isExpanded: true,
                  initialValue: _videoCodec,
                  decoration: const InputDecoration(labelText: '视频编码'),
                  selectedItemBuilder: (context) => ScrcpyVideoCodec.values
                      .map(
                        (codec) => Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            codec.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  items: ScrcpyVideoCodec.values
                      .map(
                        (codec) => DropdownMenuItem<ScrcpyVideoCodec>(
                          value: codec,
                          child: Text(
                            '${codec.label}${ScrcpyVideoCapabilities.nativeDecoderCodecs.contains(codec) ? '' : '（本地暂不可解码）'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _videoController == null
                      ? (value) => _replaceSession(() {
                          _videoCodec = value!;
                          _videoEncoder = null;
                        })
                      : null,
                ),
              ),
              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _videoEncoder ?? '',
                  decoration: const InputDecoration(
                    labelText: 'Android 编码器（可选）',
                  ),
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem<String>(
                      value: '',
                      child: Text('自动选择'),
                    ),
                    for (final encoder
                        in _videoCapabilities?.forCodec(_videoCodec) ??
                            const <ScrcpyVideoEncoder>[])
                      DropdownMenuItem<String>(
                        value: encoder.name,
                        child: Text(
                          '${encoder.name} · ${encoder.hardware ? '硬件' : '软件'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _videoController == null
                      ? (value) => _replaceSession(
                          () => _videoEncoder = value?.isEmpty ?? true
                              ? null
                              : value,
                        )
                      : null,
                ),
              ),
            ],
          ),
          if (_videoController case final controller?) ...<Widget>[
            const SizedBox(height: 12),
            ValueListenableBuilder<ScrcpyVideoState>(
              valueListenable: controller,
              builder: (context, video, _) => Card(
                child: ListTile(
                  leading: const Icon(Icons.speed),
                  title: Text(
                    '${video.width ?? 0}×${video.height ?? 0} · '
                    '${video.framesPerSecond.toStringAsFixed(1)} FPS',
                  ),
                  subtitle: Text(
                    '显示 ${video.framesRendered} 帧 · '
                    '接收 ${video.packetsReceived} 包 · '
                    '${(video.bytesReceived / 1024 / 1024).toStringAsFixed(1)} MB',
                  ),
                ),
              ),
            ),
          ],
          if (_audioController case final audio?) ...<Widget>[
            const SizedBox(height: 12),
            ValueListenableBuilder<ScrcpyAudioState>(
              valueListenable: audio,
              builder: (context, state, _) => Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        tooltip: state.muted ? '恢复设备声音' : '静音设备声音',
                        onPressed: () => _setAudioMuted(!state.muted),
                        icon: Icon(
                          state.muted ? Icons.volume_off : Icons.volume_up,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: state.volume,
                          onChanged: _setAudioVolume,
                        ),
                      ),
                      Flexible(
                        child: Text(
                          '${state.codec ?? 'Opus'} · '
                          '峰值 ${(state.peakLevel * 100).toStringAsFixed(0)}% · '
                          '解码 ${state.decodedPackets} · '
                          '播放 ${state.playedBuffers} · '
                          '丢弃 ${state.droppedBuffers}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ] else if (_audioError case final audioError?) ...<Widget>[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.volume_off),
                title: const Text('设备音频不可用，画面继续运行'),
                subtitle: Text('$audioError'),
              ),
            ),
          ],
          if (_inputController != null) ...<Widget>[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('设备控制'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        IconButton.filledTonal(
                          tooltip: 'Back',
                          onPressed: () =>
                              _sendAndroidKey(ScrcpyAndroidKeyCode.back),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Home',
                          onPressed: () =>
                              _sendAndroidKey(ScrcpyAndroidKeyCode.home),
                          icon: const Icon(Icons.home),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Recent Apps',
                          onPressed: () =>
                              _sendAndroidKey(ScrcpyAndroidKeyCode.appSwitch),
                          icon: const Icon(Icons.view_carousel),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Power',
                          onPressed: () =>
                              _sendAndroidKey(ScrcpyAndroidKeyCode.power),
                          icon: const Icon(Icons.power_settings_new),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Wake',
                          onPressed: () =>
                              _sendAndroidKey(ScrcpyAndroidKeyCode.wakeUp),
                          icon: const Icon(Icons.wb_sunny_outlined),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Volume Down',
                          onPressed: () =>
                              _sendAndroidKey(ScrcpyAndroidKeyCode.volumeDown),
                          icon: const Icon(Icons.volume_down),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Volume Up',
                          onPressed: () =>
                              _sendAndroidKey(ScrcpyAndroidKeyCode.volumeUp),
                          icon: const Icon(Icons.volume_up),
                        ),
                        IconButton.filledTonal(
                          tooltip: '双指放大',
                          onPressed: () => _pinch(zoomIn: true),
                          icon: const Icon(Icons.zoom_in),
                        ),
                        IconButton.filledTonal(
                          tooltip: '双指缩小',
                          onPressed: () => _pinch(zoomIn: false),
                          icon: const Icon(Icons.zoom_out),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _textInputController,
                            decoration: const InputDecoration(
                              labelText: '向当前输入框发送文本',
                            ),
                            onSubmitted: (_) => _sendText(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _sendText,
                          child: const Text('发送'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        FilterChip(
                          label: const Text('双向剪贴板同步'),
                          selected: _clipboardSyncEnabled,
                          onSelected: _toggleClipboardSync,
                        ),
                        OutlinedButton.icon(
                          onPressed: _pushClipboard,
                          icon: const Icon(Icons.content_copy),
                          label: const Text('宿主→设备'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _pushClipboard(paste: true),
                          icon: const Icon(Icons.content_paste),
                          label: const Text('发送并粘贴'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _pullClipboard(ScrcpyCopyKey.copy),
                          icon: const Icon(Icons.phone_android),
                          label: const Text('设备复制→宿主'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _pullClipboard(ScrcpyCopyKey.cut),
                          icon: const Icon(Icons.content_cut),
                          label: const Text('设备剪切→宿主'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_session case final session?)
            ValueListenableBuilder<ScrcpySessionState>(
              valueListenable: session.state,
              builder: (context, state, _) => Card(
                child: ListTile(
                  leading: const Icon(Icons.video_settings),
                  title: Text('会话状态：${state.name}'),
                  subtitle: Text(
                    _videoController == null
                        ? '${_displaySourceLabel(widget.displaySource)} · 视频未启动'
                        : '${_displaySourceLabel(widget.displaySource)} · scrcpy 4.1 · Native Texture',
                  ),
                ),
              ),
            ),
          if (_connectionInfo case final info?) ...<Widget>[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('连接诊断'),
                    const SizedBox(height: 8),
                    SelectableText(
                      'SCID：${info.scid}\n'
                      '本地转发端口：${info.localPort}\n'
                      '视频流：${_activeCodec?.width ?? 0}×${_activeCodec?.height ?? 0} · ${_videoCodec.label}\n'
                      'Android 编码器：${_videoEncoder ?? '自动选择'}\n'
                      '请求参数：最大 $_maxSize · $_maxFps FPS · $_bitRateMbps Mbps\n'
                      '渲染后端：Native Texture\n'
                      '自动重连次数：$_reconnectCount',
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_error case final error?) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              '$error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _startingVideo
                ? null
                : (_videoController == null ? _startVideo : _stopVideo),
            icon: Icon(
              _videoController == null ? Icons.play_arrow : Icons.stop,
            ),
            label: Text(_videoController == null ? '启动真机画面' : '停止画面'),
          ),
        ],
      ),
    ),
  );

  Widget _buildDeviceDetailsCard() {
    final details = _deviceDetails;
    if (_loadingDeviceDetails) {
      return const Card(
        child: ListTile(
          leading: CircularProgressIndicator(),
          title: Text('正在读取设备详情'),
        ),
      );
    }
    if (details == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('设备详情不可用'),
        ),
      );
    }
    final screen = details.screenWidth == null || details.screenHeight == null
        ? '未知'
        : '${details.screenWidth}×${details.screenHeight}'
              '${details.densityDpi == null ? '' : ' · ${details.densityDpi} dpi'}';
    final battery = details.batteryLevel == null
        ? '未知'
        : '${details.batteryLevel}%'
              '${details.batteryTemperatureCelsius == null ? '' : ' · ${details.batteryTemperatureCelsius!.toStringAsFixed(1)}℃'}';
    final storage = details.storageTotalBytes == null
        ? '未知'
        : '${_formatBytes(details.storageAvailableBytes)} 可用 / '
              '${_formatBytes(details.storageTotalBytes)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('设备基础详情'),
            const SizedBox(height: 8),
            Text(
              '品牌：${details.brand ?? '未知'} · ${details.manufacturer ?? '未知'}',
            ),
            Text('型号：${details.model ?? '未知'}'),
            Text(
              '系统：Android ${details.androidVersion ?? '未知'} · '
              'SDK ${details.sdkLevel ?? '未知'} · ${details.abi ?? '未知 ABI'}',
            ),
            Text('连接：${_connectionTypeLabel(details.connectionType)}'),
            Text('屏幕：$screen'),
            Text('电池：$battery'),
            Text('存储：$storage'),
            Text('运行时间：${_formatDuration(details.uptime)}'),
            if (details.unavailable.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '部分信息不可用：${details.unavailable.keys.join('、')}',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceStatusCard(AdbDeviceStatus status) {
    final usedMemory =
        status.memoryTotalBytes == null || status.memoryAvailableBytes == null
        ? null
        : status.memoryTotalBytes! - status.memoryAvailableBytes!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(child: Text('设备运行状态')),
                SizedBox(
                  width: 105,
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: _statusIntervalSeconds,
                    underline: const SizedBox.shrink(),
                    items: const <int>[2, 5, 10, 30]
                        .map(
                          (seconds) => DropdownMenuItem<int>(
                            value: seconds,
                            child: Text('$seconds 秒'),
                          ),
                        )
                        .toList(),
                    onChanged: (seconds) {
                      if (seconds != null &&
                          seconds != _statusIntervalSeconds) {
                        unawaited(_restartStatusMonitor(seconds));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${status.observedAt.hour.toString().padLeft(2, '0')}:'
                  '${status.observedAt.minute.toString().padLeft(2, '0')}:'
                  '${status.observedAt.second.toString().padLeft(2, '0')}',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'CPU：${status.cpuUsagePercent == null ? '采样中' : '${status.cpuUsagePercent!.toStringAsFixed(1)}%'}',
            ),
            Text(
              '设备 GPU：${status.deviceGpuPercent == null
                  ? status.deviceGpuSource == null
                        ? '不支持'
                        : '采样中 · ${status.deviceGpuSource}'
                  : '${status.deviceGpuPercent!.toStringAsFixed(1)}%'}'
              '${status.deviceGpuFrequencyHz == null ? '' : ' · ${(status.deviceGpuFrequencyHz! / 1000000).toStringAsFixed(0)} MHz'}'
              '${status.deviceGpuPercent == null || status.deviceGpuSource == null ? '' : ' · ${status.deviceGpuSource}'}',
            ),
            Text(
              '内存：${usedMemory == null ? '未知' : _formatBytes(usedMemory)} 已用 / '
              '${_formatBytes(status.memoryTotalBytes)}',
            ),
            Text(
              '存储：${_formatBytes(status.storageAvailableBytes)} 可用 / '
              '${_formatBytes(status.storageTotalBytes)}',
            ),
            Text(
              '网络累计：↓ ${_formatBytes(status.networkReceivedBytes)} '
              '↑ ${_formatBytes(status.networkTransmittedBytes)}',
            ),
            Text(
              '电池：${status.batteryLevel ?? '未知'}%'
              '${status.batteryTemperatureCelsius == null ? '' : ' · ${status.batteryTemperatureCelsius!.toStringAsFixed(1)}℃'}',
            ),
            Text('前台应用：${status.foregroundApplication ?? '未知'}'),
            if (status.foregroundApplication != null) ...<Widget>[
              Text(
                '应用进程：PID ${status.foregroundApplicationPid ?? '未知'} · '
                'CPU ${status.foregroundApplicationCpuPercent == null ? '采样中' : '${status.foregroundApplicationCpuPercent!.toStringAsFixed(1)}%'}',
              ),
              Text(
                '应用内存：PSS ${_formatBytes(status.foregroundApplicationPssBytes)} · '
                'RSS ${_formatBytes(status.foregroundApplicationRssBytes)}',
              ),
              Text(
                '应用 GPU：${status.foregroundApplicationGpuPercent == null ? '不支持或采样中' : '${status.foregroundApplicationGpuPercent!.toStringAsFixed(1)}%'} · '
                '显存 ${_formatBytes(status.foregroundApplicationGpuMemoryBytes)}',
              ),
            ],
            if (status.unavailable.isNotEmpty)
              Text(
                '部分状态不可用：${status.unavailable.keys.join('、')}',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
          ],
        ),
      ),
    );
  }

  static String _connectionTypeLabel(AdbConnectionType type) => switch (type) {
    AdbConnectionType.usb => 'USB',
    AdbConnectionType.network => '网络 ADB',
    AdbConnectionType.unknown => '未知',
  };

  static String _displaySourceLabel(ScrcpyDisplaySource source) =>
      switch (source) {
        ScrcpyMainDisplaySource() => '显示源：主屏',
        ScrcpyExistingDisplaySource(displayId: final id) => '显示源：Display $id',
        ScrcpyVirtualDisplaySource(launchApplication: final app) =>
          '显示源：虚拟屏${app == null ? '' : ' · ${app.packageName}'}',
      };

  static String _formatBytes(int? bytes) {
    if (bytes == null) return '未知';
    final gib = bytes / 1024 / 1024 / 1024;
    return '${gib.toStringAsFixed(gib >= 10 ? 1 : 2)} GiB';
  }

  static String _formatDuration(Duration? duration) {
    if (duration == null) return '未知';
    final days = duration.inDays;
    final hours = duration.inHours.remainder(24);
    final minutes = duration.inMinutes.remainder(60);
    return '${days > 0 ? '$days 天 ' : ''}$hours 小时 $minutes 分钟';
  }
}

class DeviceApplicationsPage extends StatefulWidget {
  const DeviceApplicationsPage({
    required this.client,
    required this.device,
    this.virtualDisplayInput,
    super.key,
  });

  final ScrcpyClient client;
  final AdbDevice device;
  final ScrcpyInputController? virtualDisplayInput;

  @override
  State<DeviceApplicationsPage> createState() => _DeviceApplicationsPageState();
}

class _DeviceApplicationsPageState extends State<DeviceApplicationsPage> {
  late final AdbApplicationManager _manager;
  final _searchController = TextEditingController();
  List<AdbApplication> _applications = const <AdbApplication>[];
  AdbApplicationType? _type;
  Object? _error;
  Duration? _elapsed;
  bool _loading = false;
  final Set<String> _busyPackages = <String>{};

  @override
  void initState() {
    super.initState();
    _manager = widget.client.adbToolkit.applications(widget.device.serial);
    _searchController.addListener(_refreshFilter);
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_refreshFilter)
      ..dispose();
    super.dispose();
  }

  void _refreshFilter() => setState(() {});

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final stopwatch = Stopwatch()..start();
    try {
      final applications = await widget.client.listApplications(
        widget.device.serial,
      );
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _applications = applications;
        _elapsed = stopwatch.elapsed;
      });
    } catch (error) {
      stopwatch.stop();
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runApplicationOperation(
    AdbApplication application,
    AdbApplicationOperation operation, {
    bool forceStopFirst = false,
  }) async {
    if (!_busyPackages.add(application.packageName)) return;
    setState(() => _error = null);
    try {
      if (operation == AdbApplicationOperation.start) {
        await _manager.startApplication(
          application.packageName,
          forceStopFirst: forceStopFirst,
        );
      } else {
        await _manager.stopApplication(application.packageName);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              operation == AdbApplicationOperation.start
                  ? '已启动 ${application.name}'
                  : '已停止 ${application.name}',
            ),
          ),
        );
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() => _busyPackages.remove(application.packageName));
      }
    }
  }

  Future<void> _openVirtualDisplay(
    AdbApplication application, {
    bool forceStopFirst = false,
  }) async {
    var defaults = VirtualDisplayDefaults.fallback;
    try {
      defaults = VirtualDisplayDefaults.fromDeviceDetails(
        await widget.client.adbToolkit.getDeviceDetails(widget.device),
      );
    } catch (_) {
      // Keep virtual display creation available when a vendor ROM does not
      // expose display metrics to the shell user.
    }
    if (!mounted) return;
    final source = await showDialog<ScrcpyVirtualDisplaySource>(
      context: context,
      builder: (_) => _VirtualDisplayConfigurationDialog(
        application: application,
        forceStopFirst: forceStopFirst,
        defaults: defaults,
      ),
    );
    if (!mounted || source == null) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DeviceSessionPage(
          client: widget.client,
          device: widget.device,
          displaySource: source,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _applications
        .where(
          (app) =>
              (_type == null || app.type == _type) &&
              app.matches(_searchController.text),
        )
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备应用'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: '搜索名称或包名',
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    ChoiceChip(
                      label: const Text('全部'),
                      selected: _type == null,
                      onSelected: (_) => setState(() => _type = null),
                    ),
                    ChoiceChip(
                      label: const Text('用户应用'),
                      selected: _type == AdbApplicationType.user,
                      onSelected: (_) =>
                          setState(() => _type = AdbApplicationType.user),
                    ),
                    ChoiceChip(
                      label: const Text('系统应用'),
                      selected: _type == AdbApplicationType.system,
                      onSelected: (_) =>
                          setState(() => _type = AdbApplicationType.system),
                    ),
                    Text(
                      '${visible.length}/${_applications.length}'
                      '${_elapsed == null ? '' : ' · ${_elapsed!.inMilliseconds} ms'}',
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '$error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final app = visible[index];
                final busy = _busyPackages.contains(app.packageName);
                final version =
                    app.versionName ??
                    (app.versionCode == null ? '未知' : '${app.versionCode}');
                return ListTile(
                  leading: Icon(
                    app.type == AdbApplicationType.system
                        ? Icons.settings_applications
                        : Icons.apps,
                  ),
                  title: Text(app.name),
                  subtitle: Text(
                    '${app.packageName}\n版本：$version · '
                    '${app.enabled ? '已启用' : '已停用'} · '
                    '${app.launchable ? '可启动' : '无桌面入口'}',
                  ),
                  isThreeLine: true,
                  trailing: busy
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : PopupMenuButton<String>(
                          tooltip: '应用操作',
                          onSelected: (value) {
                            switch (value) {
                              case 'start':
                                unawaited(
                                  _runApplicationOperation(
                                    app,
                                    AdbApplicationOperation.start,
                                  ),
                                );
                              case 'restart':
                                unawaited(
                                  _runApplicationOperation(
                                    app,
                                    AdbApplicationOperation.start,
                                    forceStopFirst: true,
                                  ),
                                );
                              case 'stop':
                                unawaited(
                                  _runApplicationOperation(
                                    app,
                                    AdbApplicationOperation.stop,
                                  ),
                                );
                              case 'virtual':
                                unawaited(_openVirtualDisplay(app));
                              case 'virtual-restart':
                                unawaited(
                                  _openVirtualDisplay(
                                    app,
                                    forceStopFirst: true,
                                  ),
                                );
                              case 'current-virtual':
                                unawaited(
                                  widget.virtualDisplayInput!.startApplication(
                                    ScrcpyApplicationLaunch(app.packageName),
                                  ),
                                );
                            }
                          },
                          itemBuilder: (_) => <PopupMenuEntry<String>>[
                            PopupMenuItem<String>(
                              value: 'start',
                              enabled: app.enabled && app.launchable,
                              child: const Text('在主屏启动'),
                            ),
                            PopupMenuItem<String>(
                              value: 'restart',
                              enabled: app.enabled && app.launchable,
                              child: const Text('强停后启动'),
                            ),
                            PopupMenuItem<String>(
                              value: 'virtual',
                              enabled: app.enabled && app.launchable,
                              child: const Text('在虚拟屏打开'),
                            ),
                            PopupMenuItem<String>(
                              value: 'virtual-restart',
                              enabled: app.enabled && app.launchable,
                              child: const Text('强停后在虚拟屏打开'),
                            ),
                            if (widget.virtualDisplayInput != null)
                              PopupMenuItem<String>(
                                value: 'current-virtual',
                                enabled: app.enabled && app.launchable,
                                child: const Text('在当前虚拟屏打开'),
                              ),
                            const PopupMenuDivider(),
                            const PopupMenuItem<String>(
                              value: 'stop',
                              child: Text('停止应用'),
                            ),
                          ],
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _VirtualDisplayConfigurationDialog extends StatefulWidget {
  const _VirtualDisplayConfigurationDialog({
    required this.application,
    required this.forceStopFirst,
    required this.defaults,
  });

  final AdbApplication application;
  final bool forceStopFirst;
  final VirtualDisplayDefaults defaults;

  @override
  State<_VirtualDisplayConfigurationDialog> createState() =>
      _VirtualDisplayConfigurationDialogState();
}

class _VirtualDisplayConfigurationDialogState
    extends State<_VirtualDisplayConfigurationDialog> {
  late final _width = TextEditingController(text: '${widget.defaults.width}');
  late final _height = TextEditingController(text: '${widget.defaults.height}');
  late final _dpi = TextEditingController(text: '${widget.defaults.dpi}');
  bool _systemDecorations = false;
  bool _keepActive = true;
  bool _moveContentToMain = false;
  Object? _error;

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    _dpi.dispose();
    super.dispose();
  }

  void _swapOrientation() {
    final width = _width.text;
    setState(() {
      _width.text = _height.text;
      _height.text = width;
    });
  }

  void _submit() {
    try {
      final source = ScrcpyVirtualDisplaySource(
        width: int.parse(_width.text),
        height: int.parse(_height.text),
        dpi: int.parse(_dpi.text),
        systemDecorations: _systemDecorations,
        closePolicy: _moveContentToMain
            ? ScrcpyVirtualDisplayClosePolicy.moveContentToMainDisplay
            : ScrcpyVirtualDisplayClosePolicy.destroyContent,
        keepActive: _keepActive,
        flexDisplay: true,
        launchApplication: ScrcpyApplicationLaunch(
          widget.application.packageName,
          forceStopBeforeStart: widget.forceStopFirst,
        ),
      );
      source.validate();
      Navigator.of(context).pop(source);
    } catch (error) {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('创建虚拟屏 · ${widget.application.name}'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _width,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '宽度'),
                  ),
                ),
                IconButton(
                  tooltip: '交换横竖屏',
                  onPressed: _swapOrientation,
                  icon: const Icon(Icons.screen_rotation),
                ),
                Expanded(
                  child: TextField(
                    controller: _height,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '高度'),
                  ),
                ),
              ],
            ),
            TextField(
              controller: _dpi,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'DPI'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示系统装饰'),
              value: _systemDecorations,
              onChanged: (value) => setState(() => _systemDecorations = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('保持虚拟屏活跃'),
              value: _keepActive,
              onChanged: (value) => setState(() => _keepActive = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('关闭后将内容移回主屏'),
              value: _moveContentToMain,
              onChanged: (value) => setState(() => _moveContentToMain = value),
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
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('创建并打开')),
    ],
  );
}

class DeviceFileManagerPage extends StatefulWidget {
  const DeviceFileManagerPage({
    required this.client,
    required this.device,
    super.key,
  });

  final ScrcpyClient client;
  final AdbDevice device;

  @override
  State<DeviceFileManagerPage> createState() => _DeviceFileManagerPageState();
}

class _DeviceFileManagerPageState extends State<DeviceFileManagerPage> {
  late final AdbFileManager _manager;
  var _path = '/sdcard';
  var _entries = const <AdbFileEntry>[];
  Object? _error;
  bool _busy = false;
  AdbCancellationToken? _operationCancellation;

  @override
  void initState() {
    super.initState();
    _manager = widget.client.adbToolkit.files(widget.device.serial);
    unawaited(_load());
  }

  Future<void> _load([String? path]) async {
    final destination = path ?? _path;
    await _run((token) async {
      final entries = await _manager.listDirectory(
        destination,
        cancellationToken: token,
      );
      if (mounted) {
        setState(() {
          _path = destination;
          _entries = entries;
        });
      }
    });
  }

  Future<void> _run(
    Future<void> Function(AdbCancellationToken token) operation,
  ) async {
    if (_busy) return;
    final cancellation = AdbCancellationToken();
    setState(() {
      _busy = true;
      _error = null;
      _operationCancellation = cancellation;
    });
    try {
      await operation(cancellation);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _operationCancellation = null;
        });
      }
    }
  }

  Future<String?> _askText({
    required String title,
    required String label,
    String initial = '',
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value?.isEmpty ?? true ? null : value;
  }

  Future<bool> _confirm(String title, String target) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SelectableText('目标：$target'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  String _childPath(String name) => _path == '/' ? '/$name' : '$_path/$name';

  Future<void> _createDirectory() async {
    final name = await _askText(title: '新建目录', label: '目录名称');
    if (name == null) return;
    await _run((token) async {
      await _manager.createDirectory(
        _childPath(name),
        cancellationToken: token,
      );
      final entries = await _manager.listDirectory(
        _path,
        cancellationToken: token,
      );
      if (mounted) setState(() => _entries = entries);
    });
  }

  Future<void> _rename(AdbFileEntry entry) async {
    final name = await _askText(
      title: '重命名',
      label: '新名称',
      initial: entry.name,
    );
    if (name == null || name == entry.name) return;
    final destination = _childPath(name);
    var overwrite = false;
    if (await _manager.exists(destination)) {
      overwrite = await _confirm('目标已存在，确认覆盖？', destination);
      if (!overwrite) return;
    }
    await _run((token) async {
      await _manager.rename(
        entry.path,
        destination,
        overwrite: overwrite,
        cancellationToken: token,
      );
      final entries = await _manager.listDirectory(
        _path,
        cancellationToken: token,
      );
      if (mounted) setState(() => _entries = entries);
    });
  }

  Future<void> _delete(AdbFileEntry entry) async {
    if (!await _confirm('确认删除？', entry.path)) return;
    await _run((token) async {
      await _manager.delete(
        entry.path,
        recursive: entry.type == AdbFileType.directory,
        cancellationToken: token,
      );
      final entries = await _manager.listDirectory(
        _path,
        cancellationToken: token,
      );
      if (mounted) setState(() => _entries = entries);
    });
  }

  Future<void> _upload() async {
    final local = await _askText(title: '上传文件', label: 'Windows 本地绝对路径');
    if (local == null) return;
    final suggested = local.replaceAll('\\', '/').split('/').last;
    final remote = await _askText(
      title: '上传到设备',
      label: 'Android 目标绝对路径',
      initial: _childPath(suggested),
    );
    if (remote == null) return;
    var overwrite = false;
    if (await _manager.exists(remote)) {
      overwrite = await _confirm('远程文件已存在，确认覆盖？', remote);
      if (!overwrite) return;
    }
    await _run((token) async {
      await _manager.push(
        local,
        remote,
        overwrite: overwrite,
        cancellationToken: token,
      );
      final entries = await _manager.listDirectory(
        _path,
        cancellationToken: token,
      );
      if (mounted) setState(() => _entries = entries);
    });
  }

  Future<void> _download(AdbFileEntry entry) async {
    final local = await _askText(
      title: '下载文件',
      label: 'Windows 本地目标路径',
      initial: entry.name,
    );
    if (local == null) return;
    if (!await _confirm('确认下载到本地？', local)) return;
    await _run(
      (token) => _manager.pull(entry.path, local, cancellationToken: token),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('文件管理'),
      actions: <Widget>[
        IconButton(
          tooltip: '上传文件',
          onPressed: _busy ? null : _upload,
          icon: const Icon(Icons.upload_file),
        ),
        IconButton(
          tooltip: '新建目录',
          onPressed: _busy ? null : _createDirectory,
          icon: const Icon(Icons.create_new_folder),
        ),
        IconButton(
          tooltip: '刷新',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: <Widget>[
        ListTile(
          leading: IconButton(
            tooltip: '上一级',
            onPressed: _busy || _path == '/'
                ? null
                : () {
                    final slash = _path.lastIndexOf('/');
                    unawaited(
                      _load(slash <= 0 ? '/' : _path.substring(0, slash)),
                    );
                  },
            icon: const Icon(Icons.arrow_upward),
          ),
          title: SelectableText(_path),
          trailing: _busy
              ? TextButton.icon(
                  onPressed: _operationCancellation?.cancel,
                  icon: const Icon(Icons.cancel),
                  label: const Text('取消任务'),
                )
              : null,
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error case final error?)
          ListTile(
            leading: Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text('$error'),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _entries.length,
            itemBuilder: (context, index) {
              final entry = _entries[index];
              final directory = entry.type == AdbFileType.directory;
              return ListTile(
                leading: Icon(directory ? Icons.folder : Icons.description),
                title: Text(entry.name),
                subtitle: directory ? null : Text(_formatBytes(entry.size)),
                onTap: directory ? () => _load(entry.path) : null,
                trailing: PopupMenuButton<String>(
                  enabled: !_busy,
                  onSelected: (action) {
                    if (action == 'download') unawaited(_download(entry));
                    if (action == 'rename') unawaited(_rename(entry));
                    if (action == 'delete') unawaited(_delete(entry));
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    if (!directory)
                      const PopupMenuItem(value: 'download', child: Text('下载')),
                    const PopupMenuItem(value: 'rename', child: Text('重命名')),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
  }
}

class BatchPackagePage extends StatefulWidget {
  const BatchPackagePage({
    required this.client,
    required this.devices,
    super.key,
  });

  final ScrcpyClient client;
  final List<AdbDevice> devices;

  @override
  State<BatchPackagePage> createState() => _BatchPackagePageState();
}

class _BatchPackagePageState extends State<BatchPackagePage> {
  final _apkController = TextEditingController();
  final _packageController = TextEditingController();
  final _selected = <String>{};
  StreamSubscription<AdbBatchSnapshot>? _subscription;
  AdbBatchTask? _task;
  AdbBatchSnapshot? _snapshot;
  Object? _error;
  int _maxConcurrency = 3;
  bool _replaceExisting = false;
  bool _keepData = false;
  bool _retryOnce = false;

  bool get _running => _snapshot?.isComplete == false;

  @override
  void dispose() {
    _task?.cancel();
    unawaited(_subscription?.cancel());
    _apkController.dispose();
    _packageController.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String action, String parameters) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('确认$action？'),
          content: SelectableText(
            '$parameters\n\n目标设备（${_selected.length} 台）：\n'
            '${widget.devices.where((device) => _selected.contains(device.serial)).map((device) => device.redactedSerial).join('\n')}',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('开始执行'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _install() async {
    final apkPath = _apkController.text.trim();
    if (_selected.isEmpty || apkPath.isEmpty) {
      setState(() => _error = '请选择设备并输入 APK 绝对路径');
      return;
    }
    if (!await _confirm(
      '批量安装',
      'APK：$apkPath\n覆盖安装：${_replaceExisting ? '是' : '否'}\n'
          '并发：$_maxConcurrency\n失败重试：${_retryOnce ? '1 次' : '不重试'}',
    )) {
      return;
    }
    final manager = widget.client.adbToolkit.batchPackages;
    await _startTask(
      manager.installTask(
        deviceSerials: _selected.toList(),
        apkPath: apkPath,
        replaceExisting: _replaceExisting,
        maxConcurrency: _maxConcurrency,
        maxAttempts: _retryOnce ? 2 : 1,
      ),
    );
  }

  Future<void> _uninstall() async {
    final packageName = _packageController.text.trim();
    if (_selected.isEmpty || packageName.isEmpty) {
      setState(() => _error = '请选择设备并输入应用包名');
      return;
    }
    if (!await _confirm(
      '批量卸载',
      '包名：$packageName\n保留数据：${_keepData ? '是' : '否'}\n'
          '并发：$_maxConcurrency\n失败重试：${_retryOnce ? '1 次' : '不重试'}',
    )) {
      return;
    }
    try {
      final manager = widget.client.adbToolkit.batchPackages;
      await _startTask(
        manager.uninstallTask(
          deviceSerials: _selected.toList(),
          packageName: packageName,
          keepData: _keepData,
          maxConcurrency: _maxConcurrency,
          maxAttempts: _retryOnce ? 2 : 1,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _startTask(AdbBatchTask task) async {
    await _subscription?.cancel();
    setState(() {
      _task = task;
      _snapshot = task.current;
      _error = null;
    });
    _subscription = task.snapshots.listen((snapshot) {
      if (mounted && identical(_task, task)) {
        setState(() => _snapshot = snapshot);
      }
    });
    try {
      final result = await task.start();
      if (mounted && identical(_task, task)) {
        setState(() => _snapshot = result);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('批量应用管理'),
      actions: <Widget>[
        TextButton(
          onPressed: _running
              ? null
              : () => setState(() {
                  if (_selected.length == widget.devices.length) {
                    _selected.clear();
                  } else {
                    _selected.addAll(
                      widget.devices.map((device) => device.serial),
                    );
                  }
                }),
          child: Text(
            _selected.length == widget.devices.length ? '取消全选' : '全选',
          ),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Text('选择设备（${_selected.length}/${widget.devices.length}）'),
        for (final device in widget.devices)
          CheckboxListTile(
            value: _selected.contains(device.serial),
            onChanged: _running
                ? null
                : (selected) => setState(() {
                    if (selected ?? false) {
                      _selected.add(device.serial);
                    } else {
                      _selected.remove(device.serial);
                    }
                  }),
            title: Text(device.model ?? device.device ?? 'Android 设备'),
            subtitle: Text(device.redactedSerial),
          ),
        const Divider(),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: _maxConcurrency,
                decoration: const InputDecoration(labelText: '最大并发数'),
                items: const <int>[1, 2, 3, 4, 6, 8]
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text('$value')),
                    )
                    .toList(),
                onChanged: _running
                    ? null
                    : (value) => setState(() => _maxConcurrency = value!),
              ),
            ),
            FilterChip(
              label: const Text('失败重试一次'),
              selected: _retryOnce,
              onSelected: _running
                  ? null
                  : (value) => setState(() => _retryOnce = value),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _apkController,
          enabled: !_running,
          decoration: const InputDecoration(
            labelText: 'APK 本地绝对路径',
            hintText: r'C:\packages\app.apk',
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _replaceExisting,
          onChanged: _running
              ? null
              : (value) => setState(() => _replaceExisting = value ?? false),
          title: const Text('覆盖安装现有应用'),
        ),
        FilledButton.icon(
          onPressed: _running ? null : _install,
          icon: const Icon(Icons.install_mobile),
          label: const Text('批量安装'),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _packageController,
          enabled: !_running,
          decoration: const InputDecoration(
            labelText: '应用包名',
            hintText: 'com.example.app',
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _keepData,
          onChanged: _running
              ? null
              : (value) => setState(() => _keepData = value ?? false),
          title: const Text('卸载后保留应用数据'),
        ),
        FilledButton.tonalIcon(
          onPressed: _running ? null : _uninstall,
          icon: const Icon(Icons.delete_outline),
          label: const Text('批量卸载'),
        ),
        if (_running) ...<Widget>[
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: _snapshot == null
                ? null
                : _snapshot!.items.values
                          .where(
                            (item) =>
                                item.state != AdbBatchItemState.queued &&
                                item.state != AdbBatchItemState.running,
                          )
                          .length /
                      _snapshot!.items.length,
          ),
          TextButton.icon(
            onPressed: _task?.cancel,
            icon: const Icon(Icons.cancel),
            label: const Text('取消全部任务'),
          ),
        ],
        if (_error case final error?)
          Text(
            '$error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_snapshot case final snapshot?) ...<Widget>[
          const SizedBox(height: 16),
          const Text('逐设备结果'),
          for (final item in snapshot.items.values)
            ListTile(
              leading: Icon(_batchStateIcon(item.state)),
              title: Text(
                widget.devices
                    .firstWhere((device) => device.serial == item.target)
                    .redactedSerial,
              ),
              subtitle: Text(
                '${_batchStateLabel(item.state)} · 尝试 ${item.attempts} 次'
                '${item.error == null ? '' : '\n${item.error}'}',
              ),
            ),
        ],
      ],
    ),
  );

  static String _batchStateLabel(AdbBatchItemState state) => switch (state) {
    AdbBatchItemState.queued => '等待中',
    AdbBatchItemState.running => '执行中',
    AdbBatchItemState.succeeded => '成功',
    AdbBatchItemState.failed => '失败',
    AdbBatchItemState.cancelled => '已取消',
    AdbBatchItemState.timedOut => '超时',
  };

  static IconData _batchStateIcon(AdbBatchItemState state) => switch (state) {
    AdbBatchItemState.queued => Icons.schedule,
    AdbBatchItemState.running => Icons.sync,
    AdbBatchItemState.succeeded => Icons.check_circle,
    AdbBatchItemState.failed => Icons.error,
    AdbBatchItemState.cancelled => Icons.cancel,
    AdbBatchItemState.timedOut => Icons.timer_off,
  };
}
