# P5-01 设备应用清单验收

## 结果

P5-01 于 2026-09-02 验收通过。插件公开 API 可枚举设备全部安装包，并提供应用名称、包名、版本、启用状态、系统/用户类型、UID、APK 路径和是否具有桌面入口。

## 实现

- `AdbApplicationManager` 使用 `cmd package query-activities` 一次性取得桌面入口，不依赖 scrcpy server。
- `pm list packages -f -U --show-versioncode` 提供完整安装包集合，确保没有 Launcher Activity 的包也不会遗漏。
- `dumpsys package packages` 一次性补齐 `versionName`、版本代码和当前用户启用状态，避免逐包 ADB 查询。
- 三份 ADB 输出按包名合并；任何无法解析的单行都会被跳过，Activity 或 dumpsys 元数据不可用时仍保留包名级结果。
- Demo 的设备页新增“应用列表”入口，支持名称/包名搜索、用户/系统分类、刷新、数量与加载耗时展示。

## 自动化验证

- `test/scrcpy_application_test.dart`：覆盖中英文名称、系统/用户分类、启用/停用状态、版本合并、无桌面入口包和异常行跳过。
- 根包完整测试：71 项全部通过。
- `flutter analyze`：无问题。

## 真机验证

- 设备：ZC-3588A，Android 15，通过网络 ADB 连接。
- Windows 集成测试构建成功。
- 读取结果：140 个安装包，其中 3 个用户应用、20 个具有桌面入口。
- 拆分后首次完整读取耗时：675 ms。
- 验证了 `android` 系统包、系统类型和用户类型均存在，所有条目名称和包名非空。
- 回归修正：`/data/app/~~...==/...==/base.apk` 路径包含 `=`，解析器现在从合法包名边界反向确定分隔位置，不再丢弃用户应用。

## 后续

P5-02 已直接复用 `AdbApplication.packageName` 和 `launchable` 实现主屏启动、可选启动前 force-stop 及停止应用。2026-09-02 补充了 `ScrcpyClient.listApplications()` 名称增强：基础清单仍来自独立 ADB 包，scrcpy 层使用内置 server 的 `list_apps` 解析本地化标签，失败时无损回退包名；图标仍留给未来独立 ADB helper。

