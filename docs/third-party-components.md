# 第三方组件与二进制清单

更新于 2026-09-11。二进制升级必须同时更新版本、SHA-256、NOTICE 和验证记录。

## ScrcpyForAndroid 源码基线

- 来源：<https://github.com/Miuzarte/ScrcpyForAndroid>。
- 许可证：Apache-2.0，完整文本保留在 `android/third_party/scrcpy_for_android/LICENSE`。
- 使用范围：Android 宿主的 ADB、scrcpy socket 和媒体链路参考实现。
- 来源与同步规则：`android/third_party/scrcpy_for_android/UPSTREAM.md`。
- 只移植与插件后端相关的模块，不引入上游 Compose 页面和应用业务代码。
- Android 配对 JNI 使用 `io.github.vvb2060.ndk:boringssl:20251124`。
  C++ 运行库使用宿主 NDK 自带的 `c++_static`，避免绑定上游特定 LLVM
  版本预编译的 libc++。
- ADB TLS 证书由 Android JCA 生成，不引入 Bouncy Castle，宿主无需处理其
  `META-INF` 资源冲突。

已删除仓库内的 `flutter_adb` 副本及其密码学、mDNS 依赖。Kadb 也未被采用，仓库和构建产物不得包含其 GPL-3.0 配对依赖。

## Android SDK Platform-Tools（Windows）

- 来源：本机 Android SDK Platform-Tools 37.0.1（Google 官方 SDK 组件）。
- ADB 版本：Android Debug Bridge 1.0.41，构建版本 37.0.1-15733141。
- 打包位置：`windows/third_party/platform-tools/`。
- 运行时位置：Flutter Windows 构建会将文件复制到宿主可执行文件所在目录。
- 默认定位：`ProcessAdbClient` 使用 `Platform.resolvedExecutable` 的父目录查找 `adb.exe`。
- 覆盖方式：构造 `ProcessAdbClient(executable: ...)` 时可提供明确路径。
- 许可证与声明：随包保留 `windows/third_party/platform-tools/NOTICE.txt`。

| 文件 | SHA-256 |
| --- | --- |
| `adb.exe` | `B4A6B455702684652CCCF7B46258B29E653538904359A58FD4931CF3EF286B3F` |
| `AdbWinApi.dll` | `C1D653030B4BDE65D3E07E4D0B0979E17BE56DF1436CDD15528630F27808050D` |
| `AdbWinUsbApi.dll` | `0710E894D9B40F71A670C13C694079D564C92C1279DA382CFE4850983AAEBE1B` |
| `NOTICE.txt` | `38EC8C6F5B7799C223FFEAB1F9E81C2D5FC67B5E56D6424F649630CA1EE1A811` |

## 更新流程

1. 只从 Android SDK Manager 或 Google 官方 Platform-Tools 发布包取得文件。
2. 同时替换 `adb.exe`、`AdbWinApi.dll`、`AdbWinUsbApi.dll`、`NOTICE.txt` 和 `source.properties`。
3. 重新计算 SHA-256，并更新本文件。
4. 构建 Windows example，确认四个文件出现在 Runner 输出目录。
5. 在没有配置系统 ADB/PATH 的环境执行版本、设备发现、连接和配对回归。

## scrcpy server 4.1

- 来源：Genymobile 官方 `v4.1` GitHub Release 的 `scrcpy-server-v4.1`。
- 上游提交：tag `v4.1`，release commit `2926c06`。
- 打包位置：`windows/third_party/scrcpy/scrcpy-server-v4.1`。
- 运行时位置：Windows 构建复制到宿主可执行文件目录。
- 许可证：Apache License 2.0，随包保留 `windows/third_party/scrcpy/LICENSE`。

| 文件 | SHA-256 |
| --- | --- |
| `scrcpy-server-v4.1` | `DEACB991ED2509715160FFDC7907E47B4160EB30D1566217E9047FD5B8850CAE` |
| `LICENSE` | `01C12035BF35AF37241298DC7AD538EB2A07E5C940437BC6876FEEAA9D1951D0` |

server 升级必须同步修改协议 fixture、启动参数、资源文件名、校验值和真机回归基线。

## Android SDK Platform-Tools（Linux 与 macOS）

- 来源：Google 官方 SDK Platform-Tools 37.0.1 固定版本发布包。
- Linux 包：`platform-tools_r37.0.1-linux.zip`。
- macOS 包：`platform-tools_r37.0.1-darwin.zip`，包含 x86_64 与 arm64 通用 ADB。
- 只分发 `adb`、`NOTICE.txt` 和 `source.properties`；`fastboot`、SQLite、文件系统工具及 ADB 不依赖的 `lib64` 均未纳入插件。
- Linux 构建将 ADB、NOTICE 和 scrcpy server 安装至应用 bundle 的 `lib` 目录，并显式保留 ADB 可执行权限。
- macOS 通过 CocoaPods resource bundle 分发相同资源，并在签名前的 Pod 准备阶段设置 ADB 可执行权限；运行时不修改已签名应用包。

| 平台 | 文件 | SHA-256 |
| --- | --- | --- |
| Linux | `adb` | `A902BE8F45C6C62E76C9EFAF6947A0FA747C9CABD89A2AC8E0D16ECB30B3ED01` |
| macOS | `adb` | `1811E253B21B12CBFDA7201EBAF86C10E7DDCB5C606A7A81F7C82B4C429C2D3B` |

两个 ADB 二进制均已检查动态依赖：Linux 仅依赖常规系统运行库，macOS 仅依赖系统 Framework 和 `libSystem`。目标平台验收时仍需分别检查可执行权限、USB 发现、mDNS、验证码配对和签名后的进程启动。

## libopus 1.5.2

- 来源：Xiph.Org 官方发布包 `opus-1.5.2.tar.gz`。
- 发布包 SHA-256：`65C1D2F78B9F2FB20082C38CBE47C951AD5839345876E46941612EE87F9A7CE1`。
- 源码位置：`windows/third_party/opus/`。
- 构建方式：CMake 以静态库编入 Windows 插件，不分发额外 DLL，不构建测试、示例或安装目标。
- 用途：将 scrcpy Opus payload 解码为 48 kHz、双声道、16-bit PCM；Windows `waveOut` 负责播放。
- 许可证：三条款 BSD 风格许可证，完整文本保留在 `windows/third_party/opus/COPYING`。

升级 libopus 时必须从 Xiph.Org 官方发布目录获取，核对发布包哈希，保留 `COPYING`，并重跑 Windows Debug/Release 构建、音频单测和真机播放测试。

