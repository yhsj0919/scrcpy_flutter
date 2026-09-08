import 'dart:io';
import 'dart:typed_data';

Future<void> writeScrcpyCapture(String path, Uint8List bytes) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
}
