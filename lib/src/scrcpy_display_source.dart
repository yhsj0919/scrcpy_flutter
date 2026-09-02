/// Selects the Android display captured by one scrcpy session.
sealed class ScrcpyDisplaySource {
  const ScrcpyDisplaySource();

  const factory ScrcpyDisplaySource.main() = ScrcpyMainDisplaySource;

  const factory ScrcpyDisplaySource.existing(
    int displayId, {
    ScrcpyDisplayImePolicy imePolicy,
  }) = ScrcpyExistingDisplaySource;

  const factory ScrcpyDisplaySource.virtual({
    int? width,
    int? height,
    int? dpi,
    bool systemDecorations,
    ScrcpyVirtualDisplayClosePolicy closePolicy,
    ScrcpyDisplayImePolicy imePolicy,
    bool keepActive,
    bool flexDisplay,
    ScrcpyApplicationLaunch? launchApplication,
  }) = ScrcpyVirtualDisplaySource;

  void validate();

  /// scrcpy-server arguments owned by this display source.
  List<String> toServerArguments();
}

final class ScrcpyMainDisplaySource extends ScrcpyDisplaySource {
  const ScrcpyMainDisplaySource();

  @override
  void validate() {}

  @override
  List<String> toServerArguments() => const <String>[];
}

final class ScrcpyExistingDisplaySource extends ScrcpyDisplaySource {
  const ScrcpyExistingDisplaySource(
    this.displayId, {
    this.imePolicy = ScrcpyDisplayImePolicy.systemDefault,
  });

  final int displayId;
  final ScrcpyDisplayImePolicy imePolicy;

  @override
  void validate() {
    if (displayId < 0) {
      throw RangeError.value(displayId, 'displayId', 'must be >= 0');
    }
  }

  @override
  List<String> toServerArguments() => <String>[
    'display_id=$displayId',
    if (imePolicy.serverName case final name?) 'display_ime_policy=$name',
  ];
}

enum ScrcpyVirtualDisplayClosePolicy {
  destroyContent,
  moveContentToMainDisplay,
}

enum ScrcpyDisplayImePolicy {
  systemDefault(null),
  local('local'),
  fallbackDisplay('fallback'),
  hide('hide');

  const ScrcpyDisplayImePolicy(this.serverName);

  final String? serverName;
}

final class ScrcpyApplicationLaunch {
  const ScrcpyApplicationLaunch(
    this.packageName, {
    this.forceStopBeforeStart = false,
  });

  final String packageName;
  final bool forceStopBeforeStart;

  /// Value used by scrcpy's START_APP control message.
  String get controlName =>
      forceStopBeforeStart ? '+$packageName' : packageName;

  void validate() {
    if (packageName.isEmpty ||
        packageName != packageName.trim() ||
        packageName.contains(RegExp(r'[\s=]')) ||
        packageName.startsWith('+') ||
        packageName.startsWith('?')) {
      throw ArgumentError.value(
        packageName,
        'packageName',
        'must be a package name without whitespace, =, + or ? prefixes',
      );
    }
  }
}

final class ScrcpyVirtualDisplaySource extends ScrcpyDisplaySource {
  const ScrcpyVirtualDisplaySource({
    this.width,
    this.height,
    this.dpi,
    this.systemDecorations = true,
    this.closePolicy = ScrcpyVirtualDisplayClosePolicy.destroyContent,
    this.imePolicy = ScrcpyDisplayImePolicy.systemDefault,
    this.keepActive = false,
    this.flexDisplay = false,
    this.launchApplication,
  });

  final int? width;
  final int? height;
  final int? dpi;
  final bool systemDecorations;
  final ScrcpyVirtualDisplayClosePolicy closePolicy;
  final ScrcpyDisplayImePolicy imePolicy;
  final bool keepActive;
  final bool flexDisplay;
  final ScrcpyApplicationLaunch? launchApplication;

  @override
  void validate() {
    if ((width == null) != (height == null)) {
      throw ArgumentError('width and height must be provided together');
    }
    if (width case final value? when value <= 0 || value > 16384) {
      throw RangeError.range(value, 1, 16384, 'width');
    }
    if (height case final value? when value <= 0 || value > 16384) {
      throw RangeError.range(value, 1, 16384, 'height');
    }
    if (dpi case final value? when value <= 0 || value > 10000) {
      throw RangeError.range(value, 1, 10000, 'dpi');
    }
    launchApplication?.validate();
  }

  @override
  List<String> toServerArguments() {
    final size = width == null ? '' : '${width}x$height';
    final specification = dpi == null ? size : '$size/$dpi';
    return <String>[
      'new_display=$specification',
      'vd_destroy_content=${closePolicy == ScrcpyVirtualDisplayClosePolicy.destroyContent}',
      'vd_system_decorations=$systemDecorations',
      if (imePolicy.serverName case final name?) 'display_ime_policy=$name',
      if (keepActive) 'keep_active=true',
      if (flexDisplay) 'flex_display=true',
    ];
  }
}
