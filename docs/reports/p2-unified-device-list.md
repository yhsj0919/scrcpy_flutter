# P2 统一设备列表验收报告

## 结论

- [x] USB、网络在线设备和已配对未连接设备使用统一 `AdbDevice` 模型。
- [x] 在线设备状态以 `adb devices -l` 为权威来源。
- [x] mDNS connect 服务生成 `paired` 状态，pairing 服务不误入设备列表。
- [x] 同一 mDNS 服务端口变化时仅保留最新端口。
- [x] 已在线的相同网络端点不会重复显示。
- [x] 每个发现条目记录 `lastSeenAt`，Demo 显示最后发现时间。
- [x] 已配对条目可直接连接，在线网络设备可直接断开。

P2-08 验收通过。

## 状态和操作

| 来源 | 统一状态 | 是否可进入画面 | 列表操作 |
|---|---|---:|---|
| `adb devices -l` 的 `device` | `device` | 是 | 网络设备可断开 |
| `adb devices -l` 的其他状态 | 原始 ADB 状态 | 否 | 展示原因 |
| `_adb-tls-connect._tcp` 且尚未在线 | `paired` | 否 | 连接 |
| `_adb-tls-pairing._tcp` | 不生成设备条目 | 否 | 在配对对话框处理 |

## 自动化证据

- `test/scrcpy_flutter_test.dart` 验证在线与 mDNS 条目合并、在线端点去重、同服务动态端口取最新值、pairing 广播忽略和 `lastSeenAt`。
- `example/test/widget_test.dart` 验证混合 USB、网络异常和已配对设备的数量、状态文案及连接入口。
- 根包 30 项测试通过，Demo Widget 测试通过，静态检查无问题。

设备序列号在 UI 和日志中继续使用稳定脱敏值。
