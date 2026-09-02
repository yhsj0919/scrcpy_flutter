# 开发环境记录

更新于 2026-08-31。设备序列号、配对码和其他敏感信息不得写入本文件。

## 当前已确认

| 项目 | 当前值 | 状态 |
| --- | --- | --- |
| 操作系统 | Windows | 已确认 |
| Flutter SDK | 3.47.2 stable，revision `d3b14c8769` | 通过 `flutter_tools.snapshot` 验证 |
| Dart SDK | 3.13.2 | format、analyze 和测试可运行 |
| Android SDK | `D:\Develop\AndroidSdk` | 路径已确认 |
| ADB | `D:\Develop\AndroidSdk\platform-tools\adb.exe` | 路径已确认，设备查询命令待恢复 |
| Visual Studio | Community 2026 18.9.1 | Desktop C++ 工具链通过 doctor 和 Windows 构建验证 |
| Windows SDK | 10.0.26100.0 | 通过 doctor 验证 |
| CMake | 3.22.1 | 通过版本命令和 Windows 构建验证 |
| Ninja | 1.10.2 | 通过版本命令和 Windows 构建验证 |

## 2026-08-31 验证结果

- `dart format lib test packages`：通过。
- `dart analyze packages\adb_client\lib packages\adb_client_process\lib lib`：通过，无问题。
- `packages/adb_client` 的 `dart test`：3 项通过。
- `packages/adb_client_process` 的 `dart test`：10 项通过，覆盖设备解析、Windows 内置路径、成功、失败、stdin、超时、取消和 2 MB 输出。
- 后续增加 typed API 脱敏用例后，`packages/adb_client_process` 共 11 项测试通过。
- `flutter pub get`：通过，根插件和 example 依赖已解析。
- `flutter.bat`：受 SDK 锁/权限影响会等待；不删除锁文件、不结束来源不明进程。
- 直接以同一 SDK 的 Dart 执行 `flutter_tools.snapshot --no-version-check test`：可正常运行。
- 根插件完整 Flutter 测试：13 项通过。
- example Widget 测试：1 项通过。
- 完整 `flutter analyze`：通过，无问题。
- Windows Debug Demo 构建：通过，产物为 `example/build/windows/x64/runner/Debug/scrcpy_flutter_example.exe`。
- Windows Release Demo 构建：通过；确认 scrcpy server、ADB 和对应许可证文件进入产物。
- 构建产物确认包含并可运行 ADB 37.0.1，以及 `AdbWinApi.dll`、`AdbWinUsbApi.dll` 和 `NOTICE.txt`。
- `flutter doctor -v`：Windows、Flutter、Visual Studio、连接设备和网络资源通过；Android SDK license 状态未知，不阻塞当前 Windows 目标。
- `example` 的定向 Dart analyzer 与 Widget 测试：通过。
- Windows 视频原生集成测试：3 项通过；确认离线媒体 Texture 生命周期、真实 scrcpy H.264 随机分片解码，以及 server 4.1/SCID/动态 forward/首批视频数据连接链路。
- 此前 `flutter --version`、`adb devices -l` 也出现长时间阻塞；尚未确认已有 Dart/ADB 进程的所有者，因此未结束这些进程。

## 已知环境事项

- `flutter.bat` 在当前自动化身份下受 SDK 锁/权限影响；直接运行同 SDK 的 `flutter_tools.snapshot` 可以完整执行分析、测试、doctor 和构建。
- Android SDK license 状态未知，后续开始 Android 宿主构建前处理。
- 仍有更早启动且来源不明的 Dart/ADB 进程；本阶段没有结束它们。

