# P3 坐标映射验收报告

## 结论

- [x] `BoxFit.contain` 正确过滤黑边并映射可见四角。
- [x] `BoxFit.cover` 正确补偿被裁剪的源图区域。
- [x] 支持居中及非居中 `Alignment`。
- [x] 窗口等比例缩放后归一化坐标保持一致。
- [x] Flutter 逻辑像素/DPI 等比例变化后坐标保持一致。
- [x] 视频横竖屏和动态尺寸更新后立即采用新尺寸映射。
- [x] 零尺寸、非有限尺寸和无效坐标安全返回 `null`。

P3-03 验收通过。

## 映射边界

输入覆盖层接收 Flutter Widget 内的逻辑坐标，使用 `applyBoxFit` 分别计算：

- `source`：实际参与显示的视频源区域；
- `destination`：视频在 Widget 内实际占用的区域。

`contain` 中落在 destination 之外的事件属于黑边，不发送到设备。`cover` 中事件映射回裁剪后的 source，再除以完整视频宽高，得到 scrcpy 控制通道使用的 0～1 归一化坐标。

DPI 不需要读取 Windows 物理缩放倍数：指针位置和 Widget 约束都由 Flutter 以逻辑像素提供，相同 DPI 变换会在归一化计算中抵消。

## 自动化证据

`test/scrcpy_input_test.dart` 覆盖：

1. contain 上、下黑边拒绝。
2. 可见区域四角映射到 (0,0)、(1,0)、(0,1)、(1,1)。
3. cover 居中、左上和右下对齐的源裁剪偏移。
4. 非居中 contain destination 位置。
5. 窗口放大两倍后的坐标不变性。
6. 视频与 Widget 逻辑尺寸同步 DPI 缩放后的坐标不变性。
7. 1920×1080 与 1080×1920 动态切换时黑边和有效区域变化。
8. Widget 重建后输入层立即使用新的 `videoSize`。
9. 零尺寸、NaN 和 Infinity 防御。

全插件测试共 37 项通过，静态检查无问题。

## 真机相关证据

P1-04 已在 Xiaomi Android 16 上完成 20 次横竖屏切换，视频尺寸在 286×640 和 640×286 间更新；Demo 的 `ValueListenableBuilder` 每次使用控制器当前宽高重建 `ScrcpyInputLayer`，因此动态尺寸进入本报告验证过的同一纯函数路径。

