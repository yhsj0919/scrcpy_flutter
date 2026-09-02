import 'dart:convert';

import 'package:adb_client/adb_client.dart';

import 'scrcpy_error.dart';

enum ScrcpyFileType { file, directory, symbolicLink, other }

final class ScrcpyFileEntry {
  const ScrcpyFileEntry({
    required this.path,
    required this.name,
    required this.type,
    required this.size,
    this.modifiedAt,
  });

  final String path;
  final String name;
  final ScrcpyFileType type;
  final int size;
  final DateTime? modifiedAt;
}

final class ScrcpyFileManager {
  const ScrcpyFileManager({required AdbClient adbClient, required this.serial})
    : _adb = adbClient;

  final AdbClient _adb;
  final String serial;

  Future<List<ScrcpyFileEntry>> listDirectory(
    String path, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _validateRemotePath(path);
    final listing = await _shell(
      'find ${_quote(path)} -mindepth 1 -maxdepth 1 -print0',
      cancellationToken: cancellationToken,
    );
    final paths = utf8
        .decode(listing.stdout, allowMalformed: true)
        .split('\u0000')
        .where((value) => value.isNotEmpty)
        .toList();
    final entries = <ScrcpyFileEntry>[];
    for (final child in paths) {
      final result = await _shell(
        "stat -c '%F|%s|%Y' -- ${_quote(child)}",
        cancellationToken: cancellationToken,
      );
      final fields = utf8
          .decode(result.stdout, allowMalformed: true)
          .trim()
          .split('|');
      if (fields.length < 3) continue;
      final seconds = int.tryParse(fields[2]);
      entries.add(
        ScrcpyFileEntry(
          path: child,
          name: child.split('/').last,
          type: _parseType(fields[0]),
          size: int.tryParse(fields[1]) ?? 0,
          modifiedAt: seconds == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.type == ScrcpyFileType.directory &&
          b.type != ScrcpyFileType.directory) {
        return -1;
      }
      if (a.type != ScrcpyFileType.directory &&
          b.type == ScrcpyFileType.directory) {
        return 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return List<ScrcpyFileEntry>.unmodifiable(entries);
  }

  Future<void> createDirectory(
    String path, {
    bool recursive = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    _validateRemotePath(path);
    await _shell(
      'mkdir ${recursive ? '-p ' : ''}-- ${_quote(path)}',
      cancellationToken: cancellationToken,
    );
  }

  Future<void> rename(
    String source,
    String destination, {
    bool overwrite = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    _validateRemotePath(source);
    _validateRemotePath(destination);
    if (!overwrite &&
        await exists(destination, cancellationToken: cancellationToken)) {
      throw const ScrcpyException(
        ScrcpyErrorCode.adbFailure,
        'Destination already exists',
      );
    }
    await _shell(
      'mv ${overwrite ? '-f' : '-n'} -- ${_quote(source)} ${_quote(destination)}',
      cancellationToken: cancellationToken,
    );
  }

  Future<void> delete(
    String path, {
    bool recursive = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    _validateRemotePath(path);
    if (path == '/') {
      throw ArgumentError.value(path, 'path', 'Refusing to delete root');
    }
    await _shell(
      'rm ${recursive ? '-rf' : '-f'} -- ${_quote(path)}',
      cancellationToken: cancellationToken,
    );
  }

  Future<bool> exists(
    String path, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _validateRemotePath(path);
    final result = await _adb.shell(serial, <String>[
      'sh',
      '-c',
      _quote('test -e ${_quote(path)}'),
    ], cancellationToken: cancellationToken);
    return result.isSuccess;
  }

  Future<void> push(
    String localPath,
    String remotePath, {
    bool overwrite = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    _validateRemotePath(remotePath);
    if (!overwrite &&
        await exists(remotePath, cancellationToken: cancellationToken)) {
      throw const ScrcpyException(
        ScrcpyErrorCode.adbFailure,
        'Remote destination already exists',
      );
    }
    await _adb.push(
      serial,
      localPath,
      remotePath,
      cancellationToken: cancellationToken,
    );
  }

  Future<void> pull(
    String remotePath,
    String localPath, {
    AdbCancellationToken? cancellationToken,
  }) {
    _validateRemotePath(remotePath);
    return _adb.pull(
      serial,
      remotePath,
      localPath,
      cancellationToken: cancellationToken,
    );
  }

  Future<AdbCommandResult> _shell(
    String command, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final result = await _adb.shell(serial, <String>[
      'sh',
      '-c',
      _quote(command),
    ], cancellationToken: cancellationToken);
    if (!result.isSuccess) {
      throw ScrcpyException(
        ScrcpyErrorCode.adbFailure,
        'Remote file operation failed',
        cause: utf8.decode(result.stderr, allowMalformed: true),
      );
    }
    return result;
  }

  static ScrcpyFileType _parseType(String value) {
    final normalized = value.toLowerCase();
    if (normalized.contains('directory')) return ScrcpyFileType.directory;
    if (normalized.contains('symbolic link')) {
      return ScrcpyFileType.symbolicLink;
    }
    if (normalized.contains('file')) return ScrcpyFileType.file;
    return ScrcpyFileType.other;
  }

  static void _validateRemotePath(String path) {
    if (!path.startsWith('/') || path.contains('\u0000')) {
      throw ArgumentError.value(
        path,
        'path',
        'Must be an absolute Android path',
      );
    }
  }

  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
}
