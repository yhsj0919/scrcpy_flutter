# scrcpy_flutter

一个基于 scrcpy server 的可嵌入式 Flutter Android 设备显示与控制组件。长期目标是实现由 Flutter 渲染和管理的低延迟多设备墙。

项目目前处于架构设计和技术原型阶段。仓库中的平台代码仍然是 Flutter 插件模板，scrcpy 会话、视频管线、控制协议和设备墙 API 尚未实现。

## 项目文档

- [架构与视频管线](docs/architecture.md)
- [实现进度与功能进度](docs/status.md)
- [可执行开发计划与交接清单](docs/development-plan.md)
- [功能范围与优先级](docs/features.md)

## 第一个里程碑

第一阶段以 Windows 主机和单台 Android 设备为目标：

1. 通过 ADB 发现设备。
2. 部署并启动版本匹配的 `scrcpy-server`。
3. 建立视频连接和控制连接。
4. 将 H.264 原始视频流送入 FVP/libmdk。
5. 在 Flutter 中显示 FVP 输出的纹理。
6. 覆盖输入层，映射坐标并发送触摸事件。
