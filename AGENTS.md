# AGENTS.md — 给 Codex / Coding Agent 的执行指令

你正在开发 PhotoBridge，面向 2018 Intel i7 MacBook 与运行 iOS 27.2 Beta 的 iPhone。用户选择 **A：从系统 Photos App 现有相簿读取手动排列顺序，往返导出/导入后恢复，不要求用户再次排序**。

## 你的任务

完整阅读 `PROJECT_PROMPT.md`、`docs/` 与 `schemas/`，把 `assets/iphone-ui-minimal.png` 作为 iPhone UI 的最高优先级视觉参考。**不要只写建议，实际写代码、测试、构建和交付。**

优先级：①原图数据不损坏；②真实读取和恢复相簿顺序；③双向 USB 与安全续传；④高速度；⑤ UI 视觉细节。不可用“先做 UI”回避核心技术可行性。

## 强制工作顺序

- **M0：调查与诊断**。先验证 PhotoKit 在目标 iOS 上读取自建相簿时是否可获得与系统照片 App 完全一致的自定义手动顺序；输出 20 张真机测试的对应标识、索引和人工对比流程。同步建立 Mac 端 USB 连接和 App 沙盒 AFC/House Arrest 可用性的诊断工程。若没有设备权限，交付可安装诊断版，不得假装真机通过。
- **M1：原始资源导出**。通过 `PHAssetResourceManager` 做原图/Live Photo/必要资源读取和正确配对；SHA-256 校验；不可改写原始资源。支持 iCloud 原件尚未下载等情况。
- **M2：双向 USB**。验证可用的正常配对、信任及官方许可的数据通道；做流式传输、原子提交、断点续传、失败重试。不要把 ImageCaptureCore 摄像头文件列表当作相簿顺序。
- **M3：回写照片库与恢复相簿**。用 PhotoKit 正确创建资产/相簿，按序号插入/移动相簿内容；运行逐项比对。Live Photo 复合资源完整性必须验证。
- **M4：效率与产品化**。传输并发自适应、速度统计、中文极简 SwiftUI、macOS Intel 兼容、GitHub Actions CI 与安装说明。

在 M0 未验证通过前，可以并行实现独立模块、测试和 UI，但**不得发布“完全保序已实现”的宣称**。

## 开发纪律

1. 每次改动后运行能够运行的测试，并记入 `docs/IMPLEMENTATION_STATUS.md`：已完成 / 设备待验证 / 已知阻塞 / 下一步。
2. 不要用占位进度、假 USB 连接、演示图片充当真实功能；UI 占位必须显式标注。
3. 默认只复制，原始资源不可变；不要删除、覆盖或移动用户文件。`PHAssetResourceCreationOptions.shouldMoveFile = false` 作为默认，明确验证行为。
4. 检验文件 SHA-256 与 manifest 映射；时间改变另存文件属性日志，不破坏原件，校验规则应明确定义。
5. 原始 EXIF、MakerNotes、ICC、GPS、厂商私有字段等原本存在的信息不得主动改写。排序所需的时间调整需有原值恢复清单。
6. 真正的“排序恒定”以 `album-order.json` 为权威，前缀文件名和 5 秒文件时间是辅助，不能假定 Finder 或系统图库所有视图强制遵从。
7. 不调用越狱/未公开相册 API；如公共 API 限制目标，给出证据和可选替代路径，用户未批准前不可降低需求。
8. 所有第三方项目先查许可证；`pymobiledevice3` 的 GPL-3.0 许可需特别评估隔离使用和再分发义务，不能无脑将源码嵌入闭源 App。
9. 云端 runner/SDK 版本必须在构建时实际检查，不要写死“iOS 27.2 Beta 工具链已经存在”。不将证书、Token、Apple 凭据提交 Git。
10. 使用系统本机存储和 USB 传照片，不要把私人照片上传 GitHub、第三方云或遥测服务。

## 立即开始

请执行：阅读主提示词 → 审核开源项目与 API → 创建工程目录、XcodeGen 配置或等效可复现配置、原生 iOS 排序诊断 App、Mac USB 诊断模块、单元测试、GitHub Actions → 尝试实际云编译 → 汇报产物与严格可信的结果。不要在已有信息足够时反复询问用户。
