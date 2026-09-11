import 'dart:convert';

import 'adb_cancellation_token.dart';
import 'adb_client_base.dart';
import 'adb_command.dart';
import 'adb_exception.dart';

enum AdbFileType { file, directory, symbolicLink, other }

final class AdbFileEntry {
  const AdbFileEntry({
    required this.path,
    required this.name,
    required this.type,
    required this.size,
    this.modifiedAt,
  });

  final String path;
  final String name;
  final AdbFileType type;
  final int size;
  final DateTime? modifiedAt;
}

final class AdbFileManager {
  const AdbFileManager({required AdbClient adbClient, required this.serial})
    : _adb = adbClient;

  final AdbClient _adb;
  final String serial;

  Future<List<AdbFileEntry>> listDirectory(
    String path, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _validateRemotePath(path);
    final listing = await _shell(<String>[
      'ls',
      '-A1',
      path,
    ], cancellationToken: cancellationToken);
    final paths = utf8
        .decode(listing.stdout, allowMalformed: true)
        .split('\n')
        .map(
          (name) =>
              name.endsWith('\r') ? name.substring(0, name.length - 1) : name,
        )
        .where((value) => value.isNotEmpty)
        .map((name) => path == '/' ? '/$name' : '$path/$name')
        .toList(growable: false);
    final entries = <AdbFileEntry>[];
    for (var offset = 0; offset < paths.length; offset += _statBatchSize) {
      final end = (offset + _statBatchSize).clamp(0, paths.length);
      final batch = paths.sublist(offset, end);
      final result = await _adb.shell(serial, <String>[
        'stat',
        '-c',
        _statFormat,
        ...batch,
      ], cancellationToken: cancellationToken);
      final lines = utf8
          .decode(result.stdout, allowMalformed: true)
          .split('\n');
      for (final line in lines) {
        if (line.isEmpty) continue;
        final fields = line.split(_statSeparator);
        if (fields.length < 4) continue;
        final metadataOffset = fields.length - 3;
        final child = fields.sublist(0, metadataOffset).join(_statSeparator);
        final seconds = int.tryParse(fields[metadataOffset + 2].trim());
        entries.add(
          AdbFileEntry(
            path: child,
            name: child.split('/').last,
            type: _parseType(fields[metadataOffset]),
            size: int.tryParse(fields[metadataOffset + 1]) ?? 0,
            modifiedAt: seconds == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
          ),
        );
      }
    }
    entries.sort((a, b) {
      if (a.type == AdbFileType.directory && b.type != AdbFileType.directory) {
        return -1;
      }
      if (a.type != AdbFileType.directory && b.type == AdbFileType.directory) {
        return 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return List<AdbFileEntry>.unmodifiable(entries);
  }

  Future<void> createDirectory(
    String path, {
    bool recursive = false,
    AdbCancellationToken? cancellationToken,
  }) async {
    _validateRemotePath(path);
    await _shell(<String>[
      'mkdir',
      if (recursive) '-p',
      path,
    ], cancellationToken: cancellationToken);
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
      throw const AdbException(
        AdbErrorCode.commandFailed,
        'Destination already exists',
      );
    }
    await _shell(<String>[
      'mv',
      overwrite ? '-f' : '-n',
      source,
      destination,
    ], cancellationToken: cancellationToken);
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
    await _shell(<String>[
      'rm',
      recursive ? '-rf' : '-f',
      path,
    ], cancellationToken: cancellationToken);
  }

  Future<bool> exists(
    String path, {
    AdbCancellationToken? cancellationToken,
  }) async {
    _validateRemotePath(path);
    final result = await _adb.shell(serial, <String>[
      'test',
      '-e',
      path,
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
      throw const AdbException(
        AdbErrorCode.commandFailed,
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
    List<String> arguments, {
    AdbCancellationToken? cancellationToken,
  }) async {
    final result = await _adb.shell(
      serial,
      arguments,
      cancellationToken: cancellationToken,
    );
    if (!result.isSuccess) {
      final output = utf8.decode(<int>[
        ...result.stderr,
        ...result.stdout,
      ], allowMalformed: true).trim();
      throw AdbException(
        AdbErrorCode.commandFailed,
        output.isEmpty
            ? 'Remote file operation failed'
            : 'Remote file operation failed: $output',
        exitCode: result.exitCode,
      );
    }
    return result;
  }

  static AdbFileType _parseType(String value) {
    final normalized = value.toLowerCase();
    if (normalized.contains('directory')) return AdbFileType.directory;
    if (normalized.contains('symbolic link')) {
      return AdbFileType.symbolicLink;
    }
    if (normalized.contains('file')) return AdbFileType.file;
    return AdbFileType.other;
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

  static const _statBatchSize = 64;
  static const _statSeparator = '\u001f';
  static const _statFormat =
      '%n$_statSeparator%F$_statSeparator%s$_statSeparator%Y';
}
