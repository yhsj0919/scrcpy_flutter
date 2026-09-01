import 'package:flutter/material.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

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
  List<AdbDevice> _devices = const <AdbDevice>[];
  Object? _error;
  bool _loading = false;
  bool _changingConnection = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await widget.client.discoverDevices();
      if (!mounted) return;
      setState(() => _devices = devices);
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
      await widget.client.connect(endpoint);
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
      await widget.client.disconnect(endpoint);
      await _refreshAfterConnectionChange();
      if (mounted) _showMessage('已断开 ${endpoint.authority}');
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _changingConnection = false);
    }
  }

  Future<void> _refreshAfterConnectionChange() async {
    final devices = await widget.client.discoverDevices();
    if (mounted) setState(() => _devices = devices);
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
          TextButton.icon(
            onPressed: _changingConnection ? null : _connect,
            icon: const Icon(Icons.add_link),
            label: const Text('网络连接'),
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
                runtime?.scrcpyServerPath ?? '当前平台未提供 scrcpy server',
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_loading || _changingConnection) const LinearProgressIndicator(),
          if (_error case final error?)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: const Text('设备发现失败'),
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
                onDisconnect: device.connectionType == AdbConnectionType.network
                    ? () => _disconnect(device)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.client,
    required this.device,
    required this.connectionBusy,
    this.onDisconnect,
  });

  final ScrcpyClient client;
  final AdbDevice device;
  final bool connectionBusy;
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
        '${device.redactedSerial} · ${device.connectionType.name} · '
        '${device.state.name}',
      ),
      trailing: onDisconnect == null
          ? device.state == AdbDeviceState.device
                ? const Icon(Icons.check_circle, color: Colors.green)
                : const Icon(Icons.warning_amber)
          : IconButton(
              tooltip: '断开网络设备',
              onPressed: connectionBusy ? null : onDisconnect,
              icon: const Icon(Icons.link_off),
            ),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => DeviceSessionPage(client: client, device: device),
        ),
      ),
    ),
  );
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

class DeviceSessionPage extends StatefulWidget {
  const DeviceSessionPage({
    required this.client,
    required this.device,
    super.key,
  });

  final ScrcpyClient client;
  final AdbDevice device;

  @override
  State<DeviceSessionPage> createState() => _DeviceSessionPageState();
}

class _DeviceSessionPageState extends State<DeviceSessionPage> {
  late final ScrcpySession _session = widget.client.createSession(
    ScrcpySessionConfiguration(deviceSerial: widget.device.serial),
  );
  Object? _error;
  ScrcpyVideoController? _videoController;
  ScrcpyInputController? _inputController;
  bool _startingVideo = false;
  int _maxSize = 1280;
  int _maxFps = 30;
  int _bitRateMbps = 4;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    setState(() => _error = null);
    try {
      await _session.prepare();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _startVideo() async {
    if (_startingVideo || _videoController != null) return;
    setState(() {
      _startingVideo = true;
      _error = null;
    });
    try {
      await _session.prepare();
      final connection = await widget.client.createVideoConnector().connect(
        ScrcpySessionConfiguration(
          deviceSerial: widget.device.serial,
          controlEnabled: true,
          video: ScrcpyVideoOptions(
            maxSize: _maxSize,
            maxFps: _maxFps,
            bitRate: _bitRateMbps * 1000 * 1000,
          ),
        ),
      );
      final controller = createNativeScrcpyVideoController(connection);
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _videoController = controller;
        _inputController = connection.input;
      });
      await controller.start();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _startingVideo = false);
    }
  }

  Future<void> _stopVideo() async {
    final controller = _videoController;
    if (controller == null) return;
    await controller.stop();
    controller.dispose();
    if (mounted) {
      setState(() {
        _videoController = null;
        _inputController = null;
      });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.device.model ?? '设备详情')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: ListView(
        children: <Widget>[
          SizedBox(
            height: 420,
            child: ColoredBox(
              color: const Color(0xff101218),
              child: _videoController == null
                  ? const Center(child: Text('点击下方按钮启动真机画面'))
                  : _inputController == null
                  ? ScrcpyVideoView(controller: _videoController!)
                  : ValueListenableBuilder<ScrcpyVideoState>(
                      valueListenable: _videoController!,
                      builder: (context, video, _) => ScrcpyInputLayer(
                        controller: _inputController!,
                        videoSize: video.width != null && video.height != null
                            ? Size(
                                video.width!.toDouble(),
                                video.height!.toDouble(),
                              )
                            : null,
                        child: ScrcpyVideoView(
                          controller: _videoController!,
                          placeholder: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Text('设备：${widget.device.redactedSerial}'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: <Widget>[
              SizedBox(
                width: 150,
                child: DropdownButtonFormField<int>(
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
                      ? (value) => setState(() => _maxSize = value!)
                      : null,
                ),
              ),
              SizedBox(
                width: 130,
                child: DropdownButtonFormField<int>(
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
                      ? (value) => setState(() => _maxFps = value!)
                      : null,
                ),
              ),
              SizedBox(
                width: 140,
                child: DropdownButtonFormField<int>(
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
                      ? (value) => setState(() => _bitRateMbps = value!)
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
          const SizedBox(height: 12),
          ValueListenableBuilder<ScrcpySessionState>(
            valueListenable: _session.state,
            builder: (context, state, _) => Card(
              child: ListTile(
                leading: const Icon(Icons.video_settings),
                title: Text('会话状态：${state.name}'),
                subtitle: Text(
                  _videoController == null
                      ? '视频未启动'
                      : 'scrcpy 4.1 · Native Texture',
                ),
              ),
            ),
          ),
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
}
