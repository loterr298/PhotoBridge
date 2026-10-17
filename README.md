# PhotoBridge · M0 诊断工程

iPhone PhotoKit 相簿返回次序诊断 + Intel macOS USB/AFC 合成文件探针。**手动顺序保真、真 USB 双向、原图往返尚待设备验收。**

- iOS：`apps/iOS/`，用 XcodeGen 2.44.1 读取 `project.yml` 生成工程。
- macOS：`swift run PhotoBridgeMac`；`bash scripts/build-mac.sh` 生成 Intel App。
- 检查：`swift run CoreChecks`、`python3 -m unittest discover -s tests -v`；完整 Xcode 环境再运行 `swift test`。
- [实际状态](docs/IMPLEMENTATION_STATUS.md)、[API/许可审查](docs/M0_API_LICENSE_AUDIT.md)、[真机验收步骤](docs/M0_DEVICE_RUNBOOK.md)、[构建与签名](docs/BUILD_AND_INSTALL.md)。

默认仅复制；不删除、覆盖原图，不改 EXIF / GPS / MakerNotes / 私有元数据。M0 仅生成合成测试数据，未实现正式照片导出和恢复。所有真实标识及照片只留本地，不提交 GitHub。
