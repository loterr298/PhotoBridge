# 实施状态记录

2026-10-17 · M0 已写代码，G1/G2 真机验收仍未运行。原规格包来自 `/Users/l/Downloads/PhotoBridge-AI-Project`，已导入当前仓库 `PhotoBridge/`，原包保留。

## 已完成的软件实现

- iOS SwiftUI 诊断：PhotoKit 全库/受限/拒绝权限；自建普通相簿与真实懒加载缩略图；nil / empty 两种无指定排序读取；逐项 ordinal、localIdentifier、相簿名和 JSON；不会自行报告手动顺序通过。
- iPhone / Mac 独立 100 MiB 合成文件、SHA-256 流式生成与回读；USB-only AFC / House Arrest PoC；新 UUID 目录、部分写入处理、大小/hash 检查；无删除照片或内部元数据改写接口。
- 原生 Mac 相机发现 App，明确 ImageCaptureCore/PTP 与 PhotoKit 相簿顺序分离。
- Swift Package、XcodeGen 配置、CI、签名说明与 20 张人工对比/双向 USB 操作手册。

## 已执行验证

| 项目 | 结果 | 证据 |
|---|---|---|
| Swift 核心实际运行 | PASS，11 项合成检查 | evidence/core-checks.log |
| Python 实际运行 | PASS，6 项检查 | evidence/python-green.log |
| 本机 XCTest | BLOCKED：无 XCTest 模块，缺完整 Xcode | evidence/swift-red.log，swift-green.log（该文件是失败输出，不代表通过） |
| Intel release 编译 / 打包 | PASS，x86_64 / ad-hoc 签名 | evidence/mac-build.log、mac-package.log |
| 旧动态库加载 | FAIL 后修复可用库选择 | evidence/usb-discovery.json、usb-discovery-fixed.json |
| USB 设备发现 | BLOCKED，实际 lookup -3 / 无设备 | evidence/usb-discovery-fixed.json |
| 云端 iOS 构建 | PENDING：新私有仓库已创建，待上传并实际运行 | 以后续 CI 运行链接/日志更新 |

## 设备待验证 / 已知阻塞

| 验收 | 状态 |
|---|---|
| O-01 / O-02：20 张手动顺序与移动五项复测 | NOT_RUN |
| U-01 / U-02：关无线、双向 100 MiB、拔线及 App 独立回读 | NOT_RUN |
| C-02：目标 iPhone 签名安装及权限 | NOT_RUN |
| C-01：macOS 13/14 运行与真实 USB | NOT_RUN；当前 15.7.9 编译已完成 |
| R-01 / R-02 / M-01：恢复、Live Photo、原始资源/元数据 | NOT_RUN，后续阶段未实现 |
| M1–M4：正式导出、文件时间、保序恢复、续传、性能和正式 UI | NOT_RUN；不越过 G1/G2 可行性闸门 |

下一步：完成云编译与编译问题修复；签名装机后按 M0_DEVICE_RUNBOOK.md 留存本地证据，只有实测成功才推进后续阶段。不上传私人照片。

补充实际执行：XcodeGen 2.44.1 成功生成项目（evidence/xcodegen.log），iOS 源文件通过 Swift parser（非 iOS 类型检查/链接）；两个 plist lint 通过。Intel App 启动后真实进程已存在，未做 GUI/设备功能验收。对“丢弃部分写入”和“忽略相簿错位”分别注入临时回归，检查确实失败后恢复生产代码并重跑通过（partial-write-red.log / order-mutation-red.log）。不是所有单测均按首次 RED→GREEN 编写，原始失败包含环境和缺模块错误，已如实保留。

GitHub 私有仓库已由用户登录的网页建立：https://github.com/loterr298/PhotoBridge 。连接器返回 404（无新仓库安装授权），命令行无凭据。采用网页上传仅包含本项目已提交文件的 SourceBundle.zip，临时 bootstrap CI 展开源码并提交正常目录，然后执行构建；不上传其他工作目录或私人照片。

## 首次云构建与审查修复

- GitHub Actions #1：**SUCCESS**，2026-10-17 22:31 +08:00，运行 https://github.com/loterr298/PhotoBridge/actions/runs/39041117636 ，工作流 commit `8ca4506db746d950b25d12bde9bcec66da0facf4`。实际 Xcode 16.4 / iOS 18.5 SDK；并非 iOS 27.2 SDK。包含 XCTest、11 项核心检查、6 项 Python 检查、iOS arm64 device build、Intel x86_64 App。
- 云产物：artifact `12103951700`，227 KB，SHA-256 `a73ce905c9aa0373ef0d78e85c387b006b4b336619de1013b32073fda34752ce`，可在上述运行页面下载。尚未签名安装 iPhone。
- 独立审查发现 P2：缩略图的旧 PhotoKit 回调可能在视图切换后显示错误照片，影响人工标识映射。已补请求取消与 generation token，旧请求/消失视图回调被拒绝；新增检查先编译失败（thumbnail-red.log），实现后通过。最终修复版将再跑 CI。
- 无其他 Critical / Important 审查发现；无延期 minor。审查不替代真机验收。
