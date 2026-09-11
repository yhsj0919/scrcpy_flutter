# ScrcpyForAndroid upstream

- Repository: <https://github.com/Miuzarte/ScrcpyForAndroid>
- Imported baseline: `e2d8499331d2386db9c27af9bafcc8ba3617044d`
- License: Apache-2.0; see `LICENSE` in this directory.
- Scope: Android-host ADB/TLS/pairing transport, scrcpy socket lifecycle and MediaCodec integration.

The Flutter plugin keeps its public session and view API. Android implementation
changes belong in this directory or in a thin adapter under
`android/src/main/kotlin/dev/scrcpy/flutter`; upstream code must not depend on
Dart ADB transport. UI, Compose screens and application-specific storage from
the upstream application are intentionally excluded.

When updating, compare the upstream transport, pairing, `Scrcpy.kt`, decoder and
renderer files as one unit. Do not cherry-pick isolated latency workarounds.
