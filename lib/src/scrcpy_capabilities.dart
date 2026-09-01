final class ScrcpyCapabilities {
  const ScrcpyCapabilities({
    required this.deviceDiscovery,
    required this.usbAdb,
    required this.networkAdb,
    required this.wirelessPairing,
    required this.video,
    required this.control,
  });

  final bool deviceDiscovery;
  final bool usbAdb;
  final bool networkAdb;
  final bool wirelessPairing;
  final bool video;
  final bool control;
}
