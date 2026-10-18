# PhotoBridge · 原始资源 USB 备份与恢复诊断

原生 iPhone PhotoKit + Intel macOS USB/AFC。目标设备上已验证 20 张手动顺序及移动位置复测、双向各 100 MiB 合成探针；真实 JPEG/编辑附件、3 组 HEIC + MOV Live Photo 已经 USB 下载并逐文件 hash，Mac 新副本创建/修改时间均验证为按资产间隔 5 秒。上述结果限定于实际样本，不能推广为全部格式或完整产品验收通过。

0.3.0 新增 Mac 原始备份 USB 回传、iPhone 完整资源预检、新相簿顺序导入及导入后资源回读校验。真实 Live 资源已返回手机 App 收件箱，**照片库导入、资源往返、系统照片人工顺序和 Live 播放均待安装新版本后验证**。不支持的资源组合整组报错，不丢弃编辑附件。

- iOS：`apps/iOS/`，XcodeGen 2.44.1 从 `project.yml` 生成工程，GitHub Actions 实编译并打包未签名 IPA。
- macOS：`swift run PhotoBridgeMac`；`bash scripts/build-mac.sh` 生成 Intel App；包内 scripts 携带实际 USB 下载/回传工具。
- 检查：`swift run CoreChecks`、`python3 -m unittest discover -s tests -v`；完整 Xcode 环境再运行 `swift test`。
- [实际状态](docs/IMPLEMENTATION_STATUS.md)、[API/许可审查](docs/M0_API_LICENSE_AUDIT.md)、[构建与签名](docs/BUILD_AND_INSTALL.md)。
- [M0 真机验收](docs/M0_DEVICE_RUNBOOK.md)、[原始资源备份](docs/M1_DEVICE_RUNBOOK.md)、[USB 回传与新相簿恢复](docs/M2_DEVICE_RUNBOOK.md)。

默认复制，不删除或覆盖原件，不写媒体内部 EXIF/GPS/MakerNotes/私人数据；照片库恢复需在手机点击开始，仅添加新副本和新相簿。真实标识、照片和详细元数据仅留本地。自动续传、照片库失败恢复、全格式/万张压力测试和最终产品化界面仍未完成。
