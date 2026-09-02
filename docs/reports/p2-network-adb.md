# P2 网络 ADB 连接验收报告

## 结论

- [x] 支持主机名、IPv4、带/不带端口及 IPv6 端点解析。
- [x] 支持网络 ADB connect/disconnect。
- [x] 重复 connect 和重复 disconnect 按幂等成功处理。
- [x] 错误地址返回 `connectionFailed`，超时返回 `timedOut`，取消返回 `cancelled`。
- [x] 地址作为独立进程参数传递并在诊断信息中脱敏。

P2-06 验收通过。

## 自动化验证

`packages/adb_client_process/test/process_adb_client_test.dart` 覆盖：

1. 首次连接和 `already connected` 重复连接。
2. 首次断开和 `no such device` 重复断开。
3. ADB 退出码为 0、但文本表示失败的异常情况。
4. 可配置连接超时及 `AdbErrorCode.timedOut`。
5. 在途连接取消及 `AdbErrorCode.cancelled`。
6. connect/disconnect 错误统一映射为 `connectionFailed`。

`ProcessAdbClient.connectionTimeout` 默认 15 秒，宿主和测试可以按场景覆盖。仅 disconnect 的明确 `no such device` 允许在非零退出码下按幂等成功处理，其他非零退出码不会被吞掉。

## 真机验证

- 日期：2026-09-01
- 宿主：Windows
- 设备：Rockchip ZC-3588A，Android 15
- 连接方式：局域网 ADB（TCP 5555）

真机依次验证：

1. 对已连接端点再次 connect，成功。
2. disconnect，成功。
3. 再次 disconnect；真实 ADB 返回非零退出码和 `no such device`，适配层已兼容该语义。
4. 重新 connect 并确认设备列表状态为 `device`。
5. 对本机不可用端口执行 connect，确认错误地址被拒绝。
6. `finally` 再次 connect，确认测试结束后设备保持在线。

设备地址和序列号不写入本报告。

