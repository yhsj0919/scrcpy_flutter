# scrcpy_flutter 示例程序

这个程序用于手工验证插件公开 API，不承载 scrcpy 或 ADB 核心实现。当前示例覆盖设备连接与断开、设备详情、文件和应用管理、实时画面与控制、音频播放，以及同一设备上的多虚拟屏工作台。

## Windows 运行

进入示例目录后执行：

```powershell
cd example
flutter pub get
flutter run -d windows
```

ADB、scrcpy server 和 Opus 会随 Windows 插件构建，不要求系统预装 ADB。真机需要先开启 USB 调试，首次连接时在设备上完成授权。

进度与待验收项目以根目录的 [`docs/development-plan.md`](../docs/development-plan.md) 为准。
