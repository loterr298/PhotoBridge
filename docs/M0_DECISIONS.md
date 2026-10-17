# M0 架构决策（2026-10-17）

范围：本次建立可执行诊断工程，检验 G1/G2，不把诊断读序当成已证明保序。

1. iOS 16+ SwiftUI + PhotoKit：只列自建普通相簿；提供 nil options 与空 PHFetchOptions 两种探测，不设置 sortDescriptors。完整导出相簿名、相簿 ID、逐项 1-based ordinal、localIdentifier、创建时间、权限、系统/构建版本。真实缩略图仅用于人工辨认。
2. 顺序验证：外部 Photos App 为基准，独立记录 20 项，移动五项后再次核对。读序不自动转为 PASS；Limited 不能作为全相簿验证。快照只写本地 Documents，可主动分享。
3. USB：House Arrest VendDocuments + AFC，USB-only 设备查找；独立 Python ctypes 诊断脚本动态调用用户已安装 libimobiledevice，不捆绑 GPL pymobiledevice3。协议非 Apple 公开 SDK，版本/分发合规仍有风险，不称“官方批准通道”。测试仅在 UUID 目录写合成数据，不访问系统照片库、覆盖或删除用户文件。
4. Mac 原生 SwiftUI App 提供 ImageCaptureCore 相机发现，与 AFC 和 PhotoKit 状态严格分开。macOS 13 最低版本，当前 Intel macOS 15.7.9 实际编译；更低系统兼容仍待测。
5. Swift Package 提供共享快照、顺序对比、流式 SHA-256 合成探针。XcodeGen 生成 iOS 工程；GitHub Actions 记录实际 Xcode/SDK，不假定 Beta 工具链存在。未签名 .app 不能直接装机。
6. M1–M4 在 G1/G2 真机验证后推进；默认只复制，不改 EXIF / MakerNotes / GPS / 私有字段，不提供任何原图删除路径。

## 执行计划

- [ ] 核心：先写并运行顺序缺项/错序/重复、SHA-256/文件冲突测试，再实现比较和流式探针。
- [ ] iOS：真实权限/相簿/成员/缩略图、两种无排序探测、JSON 导出、100 MiB 合成文件及回传校验；生成工程并编译验证可用部分。
- [ ] USB：先测路径边界、散列、部分写入逻辑，再实现 USB-only AFC 上传/下载及无设备错误报告。
- [ ] 工程：Intel App/CLI 产物、单元测试、CI、签名/20 张人工验证说明，记录每项真实结果并提交。

Review focus：权限撤回、Limited 缺项、iCloud 缩略图缺失、USB 断线、AFC 文件冲突、云端 SDK 缺失均不能产生假通过。
