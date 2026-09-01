import 'adb_endpoint.dart';

enum AdbMdnsServiceType { pairing, connect }

final class AdbMdnsService {
  const AdbMdnsService({
    required this.name,
    required this.type,
    required this.endpoint,
  });

  final String name;
  final AdbMdnsServiceType type;
  final AdbEndpoint endpoint;
}
