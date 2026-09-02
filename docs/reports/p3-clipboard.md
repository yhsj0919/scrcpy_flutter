# P3 剪贴板与文本输入验收报告

验收日期：2026-09-02

## 协议实现

- scrcpy 4.1 客户端消息：`GET_CLIPBOARD=8`、`SET_CLIPBOARD=9`
- SET 字段：64 位 sequence、paste 标志、32 位 UTF-8 长度和正文
- 设备消息：Clipboard（类型 0）和 Clipboard ACK（类型 1）
- 支持 socket 分片、多个消息合包及 UHID output 跳过
- UTF-8 剪贴板正文上限为 `256 KiB - 14`，超限在发送前拒绝
- SET 默认等待匹配 sequence 的 ACK，control socket 提前关闭时明确失败

协议依据：scrcpy v4.1 官方 `control_msg.h`、`device_msg.c`、`DeviceMessageWriterTest.java` 和控制消息序列化测试。

## 同步策略

- 内置 server 使用 `clipboard_autosync=false`，显式 GET 始终具有确定语义
- `ScrcpyClipboardSynchronizer` 以可配置周期检查宿主剪贴板并请求设备剪贴板
- 设备写入宿主后记录来源值，不会在下一轮回写设备
- 宿主写入设备后忽略相同的设备返回值
- 支持启停、宿主推送、发送并粘贴、设备 COPY/CUT 拉取
- 剪贴板正文不进入日志或异常诊断字段

## 自动测试

- [x] GET/SET 官方格式 fixture
- [x] 中英文 UTF-8 编码
- [x] Clipboard 与 ACK 分片/合包解析
- [x] 超长消息和未知类型拒绝
- [x] 设备→宿主同步
- [x] 宿主→设备同步
- [x] 两个方向的自身回环抑制
- [x] 手动 paste、copy、cut

## 真机测试

- 设备：ZC-3588A，Android 15，网络 ADB
- 测试值：包含英文、中文、换行、标点和数字
- 流程：SET → 等待 ACK → GET → UTF-8 精确比较 → 清理测试值
- 结果：全部通过；server 确认设备剪贴板写入，完整控制测试期间视频 2→49 帧且会话保持稳定

## Demo

设备控制区提供：

- 双向剪贴板同步开关
- 宿主→设备
- 发送并粘贴
- 设备复制→宿主
- 设备剪切→宿主

## 结论

P3-07 验收通过。

