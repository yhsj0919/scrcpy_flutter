# 第三方组件与二进制清单

更新于 2026-08-31。二进制升级必须同时更新版本、SHA-256、NOTICE 和验证记录。

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

