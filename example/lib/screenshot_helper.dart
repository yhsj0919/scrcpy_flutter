import 'dart:io';

import 'package:flutter/material.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';

Future<void> captureSessionScreenshot(
  BuildContext context,
  ScrcpySession session, {
  required String name,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final screenshot = await session.captureFrame();
    final safeName = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final path =
        '${Directory.current.path}${Platform.pathSeparator}'
        'screenshots${Platform.pathSeparator}${safeName}_$timestamp.png';
    await screenshot.saveToFile(path);
    messenger.showSnackBar(SnackBar(content: Text('截图已保存：$path')));
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('截图失败：$error')));
  }
}

class SessionRecordingButton extends StatefulWidget {
  const SessionRecordingButton({
    required this.session,
    required this.name,
    super.key,
  });

  final ScrcpySession session;
  final String name;

  @override
  State<SessionRecordingButton> createState() => _SessionRecordingButtonState();
}

class _SessionRecordingButtonState extends State<SessionRecordingButton> {
  bool _recording = false;
  bool _busy = false;
  String? _path;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_recording) {
        final frames = await widget.session.stopRecording();
        messenger.showSnackBar(
          SnackBar(content: Text('录屏已保存：$_path（$frames 帧）')),
        );
        if (mounted) setState(() => _recording = false);
      } else {
        final directory = Directory(
          '${Directory.current.path}${Platform.pathSeparator}recordings',
        );
        await directory.create(recursive: true);
        final safeName = widget.name.replaceAll(
          RegExp(r'[^a-zA-Z0-9._-]+'),
          '_',
        );
        final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
        final path =
            '${directory.path}${Platform.pathSeparator}'
            '${safeName}_$timestamp.mp4';
        await widget.session.startRecording(path);
        _path = path;
        if (mounted) setState(() => _recording = true);
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('录屏失败：$error')));
      if (mounted) setState(() => _recording = false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: _recording ? '停止录屏' : '开始录屏',
    onPressed: _busy ? null : _toggle,
    color: _recording ? Theme.of(context).colorScheme.error : null,
    icon: Icon(_recording ? Icons.stop_circle : Icons.videocam_outlined),
  );
}
