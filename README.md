# PhotoBridge · M1 原始资源导出验证

iPhone PhotoKit 相簿返回次序诊断 + Intel macOS USB/AFC 合成文件探针。**M0 已取得目标设备上的人工顺序比对和双向 USB 合成文件证据。M1 原始资源导出设备验收、原图导回及恢复仍待验证。**

- iOS：`apps/iOS/`，用 XcodeGen 2.44.1 读取 `project.yml` 生成工程。
- macOS：`swift run PhotoBridgeMac`；`bash scripts/build-mac.sh` 生成 Intel App。
- 检查：`swift run CoreChecks`、`python3 -m unittest discover -s tests -v`；完整 Xcode 环境再运行 `swift test`。
- [实际状态](docs/IMPLEMENTATION_STATUS.md)、[API/许可审查](docs/M0_API_LICENSE_AUDIT.md)、[真机验收步骤](docs/M0_DEVICE_RUNBOOK.md)、[构建与签名](docs/BUILD_AND_INSTALL.md)。

默认仅复制；不删除、覆盖原图，不改 EXIF / GPS / MakerNotes / 私有元数据。M1 新增原始资源本机暂存和 Mac USB hash 校验下载；尚未实现照片库导回与恢复。所有真实标识及照片只留本地，不提交 GitHub。

原始资源导出实测与命令见 [M1_DEVICE_RUNBOOK.md](docs/M1_DEVICE_RUNBOOK.md)。
