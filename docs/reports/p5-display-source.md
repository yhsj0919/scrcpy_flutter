# P5-03 Session 显示源模型

完成日期：2026-09-02。

## 结果

`ScrcpySessionConfiguration.displaySource` 现在明确支持三种来源：

- `ScrcpyDisplaySource.main()`：默认主显示，保持原有行为和参数完全不变。
- `ScrcpyDisplaySource.existing(displayId)`：采集指定的已有 Android Display。
- `ScrcpyDisplaySource.virtual(...)`：新建虚拟显示，集中配置尺寸、DPI、系统装饰、关闭时内容策略、IME 策略、保持活跃、flex display 和启动应用。

所有 server 参数只在显示源模型中序列化，连接层不再自行判断显示类型。宽高必须同时提供；displayId、尺寸、DPI 和应用名会在连接设备前校验。配置了启动应用时必须启用控制通道。

启动应用不是 scrcpy-server 启动参数。scrcpy 4.1 官方客户端是在连接建立后发送 `START_APP` 控制消息，因此本步骤只保存强类型的 `ScrcpyApplicationLaunch`；发送消息和单虚拟屏真机闭环属于 P5-04。

## 验证

- 默认主屏参数为空，现有调用不变。
- 已有 displayId 与 IME 参数序列化通过。
- 虚拟屏完整参数、默认尺寸和仅 DPI 格式序列化通过。
- 非法 displayId、缺失单边尺寸、非法 DPI、应用名以及无控制通道启动应用均被拒绝。
- 根工程 `flutter analyze` 无问题；完整测试此前 61 项通过，新增 fake connector 传递测试后显示源相关 19 项定向测试通过。

参数行为对照 [scrcpy 4.1 Options.java](https://github.com/Genymobile/scrcpy/blob/v4.1/server/src/main/java/com/genymobile/scrcpy/Options.java) 和 [virtual display 文档](https://github.com/Genymobile/scrcpy/blob/v4.1/doc/virtual-display.md)。
