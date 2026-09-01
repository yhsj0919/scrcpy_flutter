import 'package:adb_client/adb_client.dart';

List<AdbMdnsService> parseAdbMdnsServices(String output) {
  final services = <AdbMdnsService>[];
  final seen = <String>{};
  for (final rawLine in output.split(RegExp(r'\r?\n'))) {
    final fields = rawLine.trim().split(RegExp(r'\s+'));
    if (fields.length < 3) continue;
    final serviceType = fields[1].replaceFirst(RegExp(r'\.$'), '');
    final type = switch (serviceType) {
      '_adb-tls-pairing._tcp' => AdbMdnsServiceType.pairing,
      '_adb-tls-connect._tcp' => AdbMdnsServiceType.connect,
      _ => null,
    };
    final endpoint = AdbEndpoint.tryParse(fields[2]);
    if (type == null || endpoint == null) continue;
    final key = '${type.name}:${endpoint.authority}';
    if (!seen.add(key)) continue;
    services.add(
      AdbMdnsService(name: fields[0], type: type, endpoint: endpoint),
    );
  }
  return services;
}
