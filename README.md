# PhotoBridge · 原始资源 USB 备份与恢复诊断

原生 iPhone PhotoKit + Intel macOS USB/AFC。目标设备上已验证 20 张手动顺序及移动位置复测、双向各 100 MiB 合成探针；真实 JPEG/编辑附件、3 组 HEIC + MOV Live Photo 已经 USB 下载并逐文件 hash，Mac 新副本创建/修改时间均验证为按资产间隔 5 秒。上述结果限定于实际样本，不能推广为全部格式或完整产品验收通过。

3 张 HEIC/MOV Live Photo 已完成真实 USB 往返、Photos 回读全资源 hash、系统照片人工顺序及播放确认。20 张含编辑资源样本也已按用户明确授权的策略完成往返：25 份原图/编辑后 JPEG 字节一致，5 份编辑附件仅系统 adjustmentTimestamp 改变，其余解析字段一致；系统照片 20 张顺序与 5 张编辑效果均经用户确认。仍不称为全部资源字节一致。

0.3.1 新增用户明确授权、默认关闭的系统编辑记录时间选项，其他字段/类型及媒体 bytes 仍严格校验；有授权差异时记录单独状态和原始附件，不伪称 byte-identical。0.3.1 真机全20项报告及 USB 独立回读30份已完成，见 [限定样本证据](docs/evidence/m2-dw-authorized-photos-roundtrip-verified.json)。Mac 下载继续执行已通过真实 AFC 偏移及受控接收中断测试，并完成 [20项真实物理拔线下载续传](docs/evidence/m2-physical-usb-download-resume-verified.json)；Mac 上传已通过受控中断及[真实物理拔线续传](docs/evidence/m2-physical-usb-upload-resume-verified.json)，仅限 App 收件目录；iPhone 暂存的 dw 资源边界停止/重启继续已有样本证据，Photos 事务的3-Live提交后停止/重启继续已有样本证据，提交中强杀仍未测试。

- iOS：`apps/iOS/`，XcodeGen 2.44.1 从 `project.yml` 生成工程，GitHub Actions 实编译并打包未签名 IPA。
- macOS：`swift run PhotoBridgeMac`；`bash scripts/build-mac.sh` 生成 Intel App；包内 scripts 携带实际 USB 下载/回传工具。
- 检查：`swift run CoreChecks`、`python3 -m unittest discover -s tests -v`；完整 Xcode 环境再运行 `swift test`。
- [实际状态](docs/IMPLEMENTATION_STATUS.md)、[最终交付审计](docs/FINAL_DELIVERY_AUDIT.md)、[API/许可审查](docs/M0_API_LICENSE_AUDIT.md)、[构建与签名](docs/BUILD_AND_INSTALL.md)。

## 交付门禁

在仓库根目录执行 `bash scripts/verify-delivery.sh` 可重复运行核心测试、iOS 语法检查和 Intel macOS 打包；结果写入 `build/verification/`。该命令不会把未做的真机 Photos/USB 验收伪装成通过。
- [M0 真机验收](docs/M0_DEVICE_RUNBOOK.md)、[原始资源备份](docs/M1_DEVICE_RUNBOOK.md)、[USB 回传与新相簿恢复](docs/M2_DEVICE_RUNBOOK.md)。

默认复制，不删除或覆盖原件，不写媒体内部 EXIF/GPS/MakerNotes/私人数据；照片库恢复需在手机点击开始，仅添加新副本和新相簿。真实标识、照片和详细元数据仅留本地。当前产品化界面、导出、USB 续传和恢复路径已在源码中交付；Photos 提交中强杀、资源写入中终止、权限/空间/iCloud 故障、全格式/万张压力测试仍按设备证据单独验收。

[授权边界](docs/PRESERVATION_POLICY.md) · [Mac 下载继续执行](docs/USB_RESUME_RUNBOOK.md)。

[Mac 上传继续执行](docs/USB_UPLOAD_RESUME_RUNBOOK.md)：只续写已绑定、尚未发布恢复请求的新 App 收件会话；照片库仍须手机人工启动。

0.3.5新增[iPhone暂存中断恢复](docs/IOS_STAGING_RECOVERY_RUNBOOK.md)：逐资源检查点，旧会话只读，校验复用到新会话；未完成资源完整重读。本机 dw20项/30资源的停止、用户确认重启后继续已通过独立USB审计，复用1/重新读取29、hash30/30及旧文件bytes/mtime/birthtime不变；此结果不代表资源写入中强杀或Photos事务恢复。

0.3.6 新增[Photos 事务恢复协议](docs/PHOTOS_TRANSACTION_RECOVERY_RUNBOOK.md)：按持久化 placeholder 标识核对既有副本，全部重新回读后再创建剩余项；状态不明确及旧版失败会话拒绝重放。新二进制已在本机3-Live样本完成首项提交后停止、用户确认重启、同一会话继续；首个ID与相簿不变、仅创建剩余2项、6资源独立USB字节一致、17旧文件不变，系统照片3张顺序及播放经用户确认。见[限定样本证据](docs/evidence/m3-photos-transaction-device-recovery-verified.json)。提交中强杀/系统终止及权限/空间/iCloud故障仍未验证。

## 当前用户流程（Mac 0.3.15 / build19；iPhone 0.3.15 / build19）

1. 数据线连接 iPhone 和 Mac，解锁手机并打开新版 PhotoBridge，允许访问全部照片。
2. 在 Mac 点击“读取 iPhone 相册”，选定相册，再点“选择文件夹并开始导出”。所选位置内会创建一个新的相册文件夹，全部照片直接保存在里面，没有逐张子文件夹。
3. 扫描时显示真实读取数量；准备好一张的完整资源后，Mac 就接收、校验并保存这一张，同时手机继续处理后续照片。Mac 显示已保存数量、速度和保存位置；点“查看已保存照片”按原相册顺序浏览，或在 Finder 按名称升序查看。
4. 需要中断时点击暂停。重新连接后在 Mac 选择“继续未完成的导出”，选择旧目录；程序在新目录复用校验通过的完整文件，旧目录保持不变。未完成资源重新读取。
5. 从 Mac 导入 iPhone：选择已完成的 PhotoBridge 备份文件夹并上传；再在 iPhone“导入到 iPhone”确认收件并创建新相册。

顺序清单是排序依据；文件系统时间按照片位置间隔 5 秒。原始照片只读复制，不删除或覆盖原件，不主动改写媒体内部 EXIF/GPS/MakerNotes。手机需要保持 App 前台，仍占用暂存空间；完整清单最终校验通过才显示完成。新实时流程及万张压力测试尚待新版真机验收，不能用云编译替代。

Mac 平铺保存格式：每项一份带序号的可见主文件；原图、Live Photo 配对视频、编辑附件和恢复清单保留为同一根目录的隐藏文件。完整导回请保留整个相册文件夹。格式与校验边界见 [平铺相册说明](docs/FLAT_MAC_ALBUM.md)。

Large-batch validation and limits: [reproducible test scope](docs/LARGE_BATCH_VALIDATION.md). Synthetic checks do not replace real-device acceptance.
