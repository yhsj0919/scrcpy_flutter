import 'dart:io';

Future<void> writeScrcpyMetrics(String path, String content) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(content, flush: true);
}
