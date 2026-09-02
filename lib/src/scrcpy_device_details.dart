import 'dart:convert';

import 'package:adb_client/adb_client.dart';

final class ScrcpyDeviceDetails {
  const ScrcpyDeviceDetails({
    required this.serial,
    required this.connectionType,
    required this.observedAt,
    this.brand,
    this.manufacturer,
    this.model,
    this.androidVersion,
    this.sdkLevel,
    this.abi,
    this.screenWidth,
    this.screenHeight,
    this.densityDpi,
    this.batteryLevel,
    this.batteryTemperatureCelsius,
    this.storageTotalBytes,
    this.storageAvailableBytes,
    this.uptime,
    this.unavailable = const <String, String>{},
  });

  final String serial;
  final AdbConnectionType connectionType;
  final DateTime observedAt;
  final String? brand;
  final String? manufacturer;
  final String? model;
  final String? androidVersion;
  final int? sdkLevel;
  final String? abi;
  final int? screenWidth;
  final int? screenHeight;
  final int? densityDpi;
  final int? batteryLevel;
  final double? batteryTemperatureCelsius;
  final int? storageTotalBytes;
  final int? storageAvailableBytes;
  final Duration? uptime;

  /// Query groups that were unavailable. Other fields remain usable.
  final Map<String, String> unavailable;
}

final class ScrcpyDeviceDetailsParser {
  const ScrcpyDeviceDetailsParser._();

  static Map<String, String> properties(String output) {
    final result = <String, String>{};
    final pattern = RegExp(r'^\[([^\]]+)\]: \[(.*)\]$');
    for (final line in const LineSplitter().convert(output)) {
      final match = pattern.firstMatch(line.trim());
      if (match != null) result[match.group(1)!] = match.group(2)!;
    }
    return result;
  }

  static (int, int)? screenSize(String output) {
    final matches = RegExp(
      r'(?:Physical|Override) size:\s*(\d+)x(\d+)',
      caseSensitive: false,
    ).allMatches(output).toList();
    final match = matches.isEmpty ? null : matches.last;
    if (match == null) return null;
    return (int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  static int? density(String output) {
    final matches = RegExp(
      r'(?:Physical|Override) density:\s*(\d+)',
      caseSensitive: false,
    ).allMatches(output).toList();
    return matches.isEmpty ? null : int.tryParse(matches.last.group(1)!);
  }

  static ({int? level, double? temperatureCelsius}) battery(String output) {
    int? level;
    int? scale;
    int? temperatureTenths;
    for (final line in const LineSplitter().convert(output)) {
      final parts = line.trim().split(':');
      if (parts.length < 2) continue;
      final value = int.tryParse(parts.sublist(1).join(':').trim());
      switch (parts.first.trim()) {
        case 'level':
          level = value;
        case 'scale':
          scale = value;
        case 'temperature':
          temperatureTenths = value;
      }
    }
    final percentage = level == null || scale == null || scale <= 0
        ? null
        : (level * 100 / scale).round().clamp(0, 100);
    return (
      level: percentage,
      temperatureCelsius: temperatureTenths == null
          ? null
          : temperatureTenths / 10,
    );
  }

  static ({int totalBytes, int availableBytes})? storage(String output) {
    for (final line in const LineSplitter().convert(output).reversed) {
      final columns = line.trim().split(RegExp(r'\s+'));
      if (columns.length < 5 || !columns.last.startsWith('/data')) continue;
      final totalKb = int.tryParse(columns[1]);
      final availableKb = int.tryParse(columns[3]);
      if (totalKb != null && availableKb != null) {
        return (totalBytes: totalKb * 1024, availableBytes: availableKb * 1024);
      }
    }
    return null;
  }

  static Duration? uptime(String output) {
    final seconds = double.tryParse(output.trim().split(RegExp(r'\s+')).first);
    return seconds == null
        ? null
        : Duration(milliseconds: (seconds * 1000).round());
  }
}
