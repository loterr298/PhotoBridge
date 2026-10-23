# PhotoBridge 最终交付审计

更新时间：2026-10-23。此表只描述当前源码和已保存证据；历史阶段的 `NOT_RUN` 记录保留在 `IMPLEMENTATION_STATUS.md`，不能覆盖本表的最新判断。

| 原始要求 | 当前交付 | 代码/证据 | 仍然不能扩大宣称的范围 |
|---|---|---|---|
| PhotoKit 手动顺序诊断 | 已实现 | `apps/iOS/PhotoBridgeApp.swift`、`OrderSnapshot`、`docs/M0_DEVICE_RUNBOOK.md` | 公共 API 没有全场景手动排序保证；不同权限、共享/智能相簿和其他系统版本仍需独立证据 |
| 原图与资源组导出 | 已实现 | `apps/iOS/OriginalExportService.swift`、`AlbumManifest` | iCloud 未下载、HEIC/PNG/RAW/DNG 全格式和大批量仍需真实样本验收 |
| SHA-256、原子写入、5 秒逻辑时间 | 已实现 | `scripts/album_export.py`、`PhotoBridgeCore/StagingFiles.swift`、`PhotoBridgeCore/AlbumManifest.swift` | 创建时间在文件系统不支持时会如实标记；不能把辅助时间当媒体 EXIF 时间 |
| USB/AFC 双向与 PTP 区分 | 已实现 | `scripts/usb_probe.py`、`album_export.py`、`album_restore.py`、Mac `ImageCaptureCore` 诊断 | USB 速率、线材、macOS 13/14 和更多异常设备组合需现场测量；PTP 目录永远不是相簿顺序来源 |
| 断点续传与安全停止 | 已实现 | `album_resume.py`、`upload_resume.py`、`transfer_control.py`、Mac 实时进度 UI | 提交中强杀、系统终止和全部磁盘/权限故障仍需真机故障日志 |
| PhotoKit 恢复、顺序与 Live Photo | 已实现 | `apps/iOS/RestoreService.swift`、`RestoreView.swift`、`docs/PHOTOS_TRANSACTION_RECOVERY_RUNBOOK.md` | 系统可能重置编辑附件时间；仅用户明确授权的副本可接受该变化。全格式和大规模仍未覆盖 |
| 极简苹果风格双端 UI | 已实现 | `apps/iOS/*.swift`、`Sources/PhotoBridgeMac/PhotoBridgeMac.swift`、`docs/UI_DESIGN.md` | 最终视觉验收必须在目标 iPhone 和 Intel Mac 上逐屏观察；没有把静态设计图当功能 |
| 可复现工程、测试、CI、产物 | 已实现 | `project.yml`、`Package.swift`、`.github/workflows/diagnostics.yml`、`scripts/verify-delivery.sh` | 当前本地分支可生成 Intel 包；最近远程 Actions #28 是旧 commit 基线，当前 commit 需要有权限的 GitHub push 后才能生成对应云 IPA |

## 本地交付证据

执行：

```bash
bash scripts/verify-delivery.sh
```

本轮实际结果：Swift CoreChecks 11 + 导出检查 8 + AFC 提交检查 4 + 恢复安全检查 8 + 时间策略检查 15 + 批量检查 3；StagingChecks 23；RecoveryChecks 57；Python 63 项；iOS Swift 语法解析通过；Intel 二进制为 `x86_64`。本机只有 Command Line Tools，XCTest 明确记录为环境阻塞，GitHub Actions 的 Xcode runner 才运行 XCTest 和 iOS device build。

当前本地 Mac 包：`build/PhotoBridgeMac-Intel.zip`，SHA-256 `0bfebc36ec1f3fcfbf076313d9f1f4f345bc8c4d423900ef217a8a852b169e13`。

可直接交付的双端载荷目录：`build/PhotoBridge-0.3.8-M4-Apps/`，其中 iPhone 未签名 IPA SHA-256 为 `7d2607760f65f7c9d13adaf4f182a9c282e10b1fe7d8e9bfccb037ade4feadab`，Mac ZIP SHA-256 为 `13b4c034c16f7a67afec35690065c809493327972167b4346bde83c958b54d68`。该载荷来自 Actions #25/#26 的 M4 云构建系列；当前源码后续的交付门禁提交不改变应用代码，但若要让云产物带上 `f8b8280`，仍需把本地分支推到 GitHub。

## 用户可用边界

用户可以使用已签名安装的 iPhone App 和 Intel Mac App 完成：读取相簿顺序、原始资源暂存、Mac USB 下载/校验/续传、已校验备份上传、iPhone 预检和明确启动恢复。原始照片默认只复制，不删除、不覆盖、不修改内部 EXIF/GPS/MakerNotes。未签名 IPA 不能直接安装，签名必须使用用户自己的 Apple ID / 开发者证书。

尚未满足“无需任何外部验证即可称为全部场景完成”的项目只有设备覆盖和分发条件：当前分支的云编译、目标 macOS 13/14、HEIC/PNG/RAW/DNG 全格式、万张压力、异常故障注入以及最终逐屏视觉验收。应用会在这些条件缺失时显示待验证或失败，不会伪造通过。

## 最新云端交付（2026-10-24）

GitHub Actions run **#32**（`39998331913`）在远程 commit `6f5f4778985058089d8457101671ffa9d059bbeb` 上成功完成。归档下载：`PhotoBridge-diagnostics-6f5f4778985058089d8457101671ffa9d059bbeb.zip`，归档 SHA-256 为 `5a1a97f71b7b938962dd3acb77696c422549b670935cdcd4b2b0f7373b4196ff`。

| 文件 | SHA-256 | 说明 |
|---|---|---|
| `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa` | `6b967dac62ce7d60ecfe8cbae070fa6f910e2612b0c1a69e905f367595a3977f` | iOS 未签名包，需 Apple ID 签名 |
| `PhotoBridgeMac-Intel.zip` | `99266db8fe9c0def3dfb2992b9ba8cd3a930e68ef5644c284c10cffda09dcf12` | Intel macOS 包 |
| `PhotoBridgeOrderProbe-unsigned.app.zip` | `e859d8268523da8b488cc525991a25e2eb3c1633fe8211f277329cd2186c97e1` | iOS `.app` 备用归档 |
