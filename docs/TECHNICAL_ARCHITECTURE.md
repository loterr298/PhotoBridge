# 技术架构与关键风险（开发人员必读）

## 推荐架构

```
            iPhone（SwiftUI + PhotoKit）
         ┌───────────────────────────┐
         │ AlbumReader + OrderProbe │ ← 必须先验证系统自定义顺序能否被读取
         │ OriginalResourceExporter  │ ← 照片 / RAW / Live Photo 资源组
         │ Importer + AlbumRestorer  │ ← PhotoKit 写回 + 索引恢复
         │ App Documents Staging    │ ← 校验 + 轻量暂存
         └─────────────┬─────────────┘
                       │ USB 有线：已配对/信任设备的 AFC / House Arrest 等可行路径
         ┌─────────────▼─────────────┐
         │ Mac（SwiftUI + 传输引擎）  │
         │ USBDiscovery/Transfer     │
         │ Manifest & Integrity      │
         │ AlbumStorage & Timestamps │
         │ TransferQueue + Recovery  │
         └───────────────────────────┘
```

**不可混淆**：PhotoKit 负责读取/写入相簿与原始照片资源，但 PhotoKit 不是在 Mac 与 iPhone 之间的 USB 文件传输协议；Mac 的 ImageCaptureCore 可读取相机目录，但不保证自建相簿成员或用户手动排序。两个通道都需分别验证。

## 顺序的权威来源

1. iPhone 源相簿：Photos App 中真实人工设置的自定义顺序。
2. 应用导出时：PhotoKit 返回次序必须先与 Photos App 人工比对验证。
3. Mac 备份时：写入版本化 `album-order.json`，ordinal 代表固定位置，最可靠。
4. Mac Finder 辅助展示：序号前缀与 5 秒文件系统时间；其他 Finder 排序方式不承诺一致。
5. iPhone 恢复时：按 manifest 给每个新 asset 对应组排序，以 PhotoKit 的 collection change request 插入/移动资源并二次读取验证；保证目标为**用户自建可编辑相簿**，不是系统相册全部视图。

## iPhone 端服务

- **AlbumReader / OrderProbe**：根据 Photos 权限列举自建相簿、获取 PHFetchResult、提供读到的 index + identifier + 缩略图顺序诊断文件；不可根据 `creationDate` 补造顺序。
- **ResourceCatalog**：一个逻辑资产关联零个或多个 PHAssetResource；原始/编辑资源类型准确分类，Live Photo 配对必须正确；每个 raw resource 独立 hash。
- **ResourceExportService**：PHAssetResourceManager 提供真实媒体数据并写入文件；受控并行、背压和暂存回收。
- **ResourceImportService**：PHAssetCreationRequest.addResource(fileURL:) 接收传进沙盒的资源；设置 shouldMoveFile=false 防止默认移走源文件；导回后重新读取资源、核对。
- **AlbumRestoreService**：按 original ordinal 重建/更新用户自建相簿；如不支持定位插入，应报失败并保留恢复数据而不是返回成功。

## Mac 端服务

- **DeviceConnection**：实际 USB 设备发现、信任、故障提示。
- **StagingBridge**：从 iPhone App 的 Documents 目录传出/传入，可采用实测成功的 USB/AFC/House Arrest 手段；如调用 GPL 工具应特别处理许可和组件边界。
- **TransferCoordinator**：有界队列、按文件流式 I/O、重试、暂停、续传、真实吞吐统计。
- **Integrity**：每个资源校验 SHA-256，复制成功后提交文件；中断时不能留下貌似完好的文件。
- **AlbumStore**：相簿目录、原名映射、冲突处理、transaction state、manifest 和日志。
- **TimestampPolicy**：`baseTime` + ordinal×5s，在 OS 支持的情况下给文件设系统时间；不对原始媒体内容修改。

## 关键可行性闸门

| 闸门 | 需要实测的证据 | 未通过怎么办 |
|---|---|---|
| G1: 读系统相簿手动顺序 | 20 张打乱顺序的 Source Photos vs PhotoKit 全序列一致 | 标记阻塞；不可冒充 A 方案完成；保留独立功能 |
| G2: 真 USB 双向传输 | USB 连线下双向传 100 MB+ 文件，每方向完整 hash | 调整端点及连接方式，不暗换 Wi-Fi |
| G3: 原始资源 | HEIC / JPG / DNG / Live Photo 资源组逐个校验 | 标注系统不提供或导入造成差异的资源类型 |
| G4: 恢复自建相簿顺序 | 读回目标自建相簿 20/20 一致 | 不报告恢复成功，提供异常报告 |
| G5: Intel Mac 构建 | 构建产物包含 x86_64，实际系统版本能打开 | 调整 deployment target 或代码 API，不能只生成 arm64 |

## 一致性模型

- 保留 A：原始媒体字节 SHA-256 相等，这是 **原始资源备份** 的严格目标。
- 保留 B：导回 PhotoKit 后的资源、元数据不变，这是 **照片库往返** 的验收目标；系统可能重新封装或不暴露同样的资源，因此必须实测并单独列出差异。
- 排序 A：源 Photos App 手动顺序 = 读取排序清单（需验证）。
- 排序 B：排序清单 = 重新导入后自建相簿顺序（可通过公开操作尝试，但仍需实测）。
- 时间：仅 Mac 文件系统属性默认改变；如果用户选了“照片显示时间排序兼容模式”，才通过 PhotoKit 修改显示拍摄时间并保留还原值。

## 进度状态机

`discovered → enumerated → staged → transferred → verified → committed`，失败状态 `failed`、用户主动 `paused`、断线 `disconnected`。导回另外建立 `reimported → album-placed → reverified`，不能把 copied 当 restored。

## 不做的事

- 依赖私有照片库数据库文件读取手动排序；越狱或绕过系统权限；修改未知私有元数据。
- 原文件就地改写 EXIF 时间；删除原文件；传输照片经第三方网络服务器。
- 将 Mac 的 ImageCaptureCore 目录顺序当成 iPhone 相簿手动顺序。
- 自称“所有 iPhone 主图库视图一律固定排序”。


## Live USB connection lease (0.3.18)

Mac runs one non-overlapping automatic heartbeat worker, independently of media/progress tasks. Each invocation opens the existing USB-only AFC/House Arrest transport, writes <=4096-byte `Control/connection-request.json` (fresh UUID nonce plus previously read reply nonce), then waits up to1.5s for a matching `connection-reply.json`. The helper process has a4s hard deadline; successful cycles sleep2s. No Photos access or transfer reset is performed by this worker. First connection/reconnection schedules album enumeration once when idle.

iPhone has a separate400ms worker, bounded regular/single-link reads and atomic reply writes. It echoes nonce/foreground state. The Mac confirms it read that reply in the next challenge; only a fresh confirmation of the phone's preceding reply enables phone green. Re-reading the same file never renews an8s uptime lease. Foreground transitions/relaunch invalidate it. Mac sleep/wake invalidates the probe generation and rejects a pre-sleep result; failed checks clear its state. No wall-clock agreement is required.

Two fixed disposable connection files and the existing progress file are the only UI metadata replacements. Source media, manifests and journals retain no-overwrite behavior. Partial JSON is retried; invalid/oversized/link records cannot authorize anything. Connection status is advisory and never authorizes Photos writes, hash acceptance or completed-transfer reporting. Separate AFC heartbeat sessions introduce small background I/O; real-device concurrent-transfer/latency/sleep testing remains required.
