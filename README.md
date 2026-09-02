# scrcpy_flutter

Windows 构建默认随插件分发固定版本的 ADB 及其运行库，宿主不需要预装 Android SDK 或配置 PATH；开发者仍可通过公开构造参数覆盖 ADB 路径。

一个基于 scrcpy server 的可嵌入式 Flutter Android 设备显示与控制插件。它首先是供其他 Flutter 应用依赖的插件包，仓库中的 example 只用于演示和验收。长期目标是实现由 Flutter 渲染和管理的低延迟多设备墙。

项目目前处于 Windows 单设备视频技术验证阶段。ADB、scrcpy 4.1 视频连接、Flutter Texture 组件和 Windows Media Foundation 原生后端已有实现；控制协议和设备墙仍待开发。

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
4. 保留 scrcpy codec、session 和 frame metadata，拆分 H.264 编码包。
5. 通过平台原生解码器输出 Flutter Texture。
6. 覆盖输入层，映射坐标并发送触摸事件。

