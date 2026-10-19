# PhotoBridge · 原始资源 USB 备份与恢复诊断

原生 iPhone PhotoKit + Intel macOS USB/AFC。目标设备上已验证 20 张手动顺序及移动位置复测、双向各 100 MiB 合成探针；真实 JPEG/编辑附件、3 组 HEIC + MOV Live Photo 已经 USB 下载并逐文件 hash，Mac 新副本创建/修改时间均验证为按资产间隔 5 秒。上述结果限定于实际样本，不能推广为全部格式或完整产品验收通过。

3 张 HEIC/MOV Live Photo 已完成真实 USB 往返、Photos 回读全资源 hash、系统照片人工顺序及播放确认。20 张含编辑资源样本在第 12 张严格停止：原图和编辑后 JPEG 一致，系统只重置了编辑附件 adjustmentTimestamp，不能称为全部资源字节一致。

0.3.1 新增用户明确授权、默认关闭的系统编辑记录时间选项，其他字段/类型及媒体 bytes 仍严格校验；有授权差异时记录单独状态和原始附件，不伪称 byte-identical。新策略真机复测待安装新版。Mac 下载继续执行已通过真实 AFC 偏移及受控接收中断测试；物理拔线恢复、上传/iPhone 暂存/照片库事务续传尚未通过。

- iOS：`apps/iOS/`，XcodeGen 2.44.1 从 `project.yml` 生成工程，GitHub Actions 实编译并打包未签名 IPA。
- macOS：`swift run PhotoBridgeMac`；`bash scripts/build-mac.sh` 生成 Intel App；包内 scripts 携带实际 USB 下载/回传工具。
- 检查：`swift run CoreChecks`、`python3 -m unittest discover -s tests -v`；完整 Xcode 环境再运行 `swift test`。
- [实际状态](docs/IMPLEMENTATION_STATUS.md)、[API/许可审查](docs/M0_API_LICENSE_AUDIT.md)、[构建与签名](docs/BUILD_AND_INSTALL.md)。
- [M0 真机验收](docs/M0_DEVICE_RUNBOOK.md)、[原始资源备份](docs/M1_DEVICE_RUNBOOK.md)、[USB 回传与新相簿恢复](docs/M2_DEVICE_RUNBOOK.md)。

默认复制，不删除或覆盖原件，不写媒体内部 EXIF/GPS/MakerNotes/私人数据；照片库恢复需在手机点击开始，仅添加新副本和新相簿。真实标识、照片和详细元数据仅留本地。上传/iPhone 暂存/照片库事务续传、物理拔线和全格式/万张压力测试、最终产品化界面仍未完成。

[授权边界](docs/PRESERVATION_POLICY.md) · [Mac 下载继续执行](docs/USB_RESUME_RUNBOOK.md)。
