# P3 视频画质配置验收报告

验收日期：2026-09-02

## API 与 UI

- `ScrcpyVideoOptions` 支持最大尺寸、最大 FPS、视频码率、`ScrcpyVideoCodec` 和可选 MediaCodec encoder
- codec 使用 `h264`、`h265`、`av1` 类型化枚举，不再接受任意字符串
- 参数范围和 encoder 名称在启动前校验
- Demo 可选择尺寸、FPS、码率和 codec
- Demo 通过设备能力探测动态列出自动、硬件和软件编码器

## 能力探测

`ScrcpyClient.probeVideoCapabilities()` 临时运行内置 scrcpy 4.1 的 `list_encoders=true`，解析官方输出后立即清理设备端探测文件。

ZC-3588A（Android 15）实测：

- H.264：Rockchip 硬件编码器、Android 软件编码器及 alias
- H.265：Rockchip 硬件编码器和 Android 软件编码器
- AV1：Android 软件编码器
- 去除 alias 后，Demo 仅展示实际编码器入口

## 解码支持边界

- scrcpy 视频协议解析器识别 H.264、H.265 和 AV1 codec ID
- 当前 Windows Native Texture 后端仅实现 H.264 Media Foundation 解码
- H.265/AV1 会在创建 Texture 前返回机器可读 `unsupportedCapability`
- 设备编码能力与本地解码能力分开呈现，不做静默回退，也不产生黑屏/花屏

## 两档真机对比

设备画面在测试期间基本静止，因此实际 FPS 和吞吐代表静态画面，不代表运动场景上限。

| 配置 | 实际尺寸 | 总帧 | 平均 FPS | 平均吞吐 | 首帧 |
|---|---:|---:|---:|---:|---:|
| 720 / 15 FPS / 2 Mbps | 404×720 | 10 | 1.25 | 0.01 Mbps | 1965 ms |
| 1280 / 30 FPS / 8 Mbps | 720×1280 | 11 | 1.37 | 0.03 Mbps | 1985 ms |

高档实际长边由 720 提升至 1280，静态画面吞吐约为低档 3 倍。两个 profile 均成功取得原生 Texture 帧并正常释放资源。

## 测试覆盖

- [x] H.264/H.265/AV1 codec ID
- [x] 未知 codec 拒绝
- [x] 画质参数范围校验
- [x] encoder 名称校验
- [x] scrcpy 4.1 编码器列表解析
- [x] hardware/software、vendor、alias 分类
- [x] H.265 原生解码明确失败
- [x] 真机能力探测
- [x] 两档 H.264 真机指标

## 结论

P3-08 验收通过。首版默认和可播放 codec 仍为 H.264；H.265/AV1 的设备端选择与能力模型已经稳定，后续增加对应 Windows 解码器时无需修改公开配置 API。

