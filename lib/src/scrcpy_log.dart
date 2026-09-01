enum ScrcpyLogLevel { trace, debug, info, warning, error }

final class ScrcpyLogRecord {
  const ScrcpyLogRecord({
    required this.level,
    required this.source,
    required this.message,
    this.sessionId,
    this.fields = const <String, Object?>{},
  });

  final ScrcpyLogLevel level;
  final String source;
  final String message;
  final String? sessionId;
  final Map<String, Object?> fields;
}

typedef ScrcpyLogSink = void Function(ScrcpyLogRecord record);

final class ScrcpyLogger {
  const ScrcpyLogger(this.sink);

  final ScrcpyLogSink sink;

  void log({
    required ScrcpyLogLevel level,
    required String source,
    required String message,
    String? sessionId,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    sink(
      ScrcpyLogRecord(
        level: level,
        source: source,
        message: message,
        sessionId: sessionId,
        fields: <String, Object?>{
          for (final entry in fields.entries)
            entry.key: _isSensitiveKey(entry.key) ? '<redacted>' : entry.value,
        },
      ),
    );
  }
}

bool _isSensitiveKey(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  return normalized.contains('serial') ||
      normalized.contains('pairingcode') ||
      normalized.contains('password') ||
      normalized.contains('token');
}
