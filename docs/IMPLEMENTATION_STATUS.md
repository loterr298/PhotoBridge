# 实施状态记录

更新：2026-10-18。**M0 诊断代码已实现并经云端双端编译；G1/G2 真机可行性仍未验收。**

规格包从 `/Users/l/Downloads/PhotoBridge-AI-Project` 导入当前工作区 `PhotoBridge/`，原包未改动。私有 GitHub 仓库：[loterr298/PhotoBridge](https://github.com/loterr298/PhotoBridge)。

## 已完成的软件实现

- iOS SwiftUI：PhotoKit 全库/受限/拒绝权限，自建普通相簿、真实懒加载缩略图，nil / empty 两种不指定排序的读取。逐项输出相簿名、相簿 ID、ordinal、localIdentifier、时间、权限、系统/构建版本；可保存本地 JSON 并主动分享。读取本身永远不自动标为顺序通过。
- iPhone / Mac 各自生成 100 MiB 合成文件，流式 SHA-256 / 回读校验。USB-only House Arrest / AFC PoC，新 UUID 目录、部分写入处理、大小/hash 检查、不覆盖现有文件；iPhone 独立回读上传文件。此代码尚无设备传输通过证据。
- Intel Mac 原生 App 真实调用 ImageCaptureCore 发现相机设备；相机目录不冒充 PhotoKit 相簿顺序。AFC 脚本单独提供并随 App 打包。
- Swift Package、XcodeGen、单元测试、GitHub Actions、签名说明、20 张人工比对及双向 USB 手册。所有操作仅本地，不上传私人照片；M0 不写入照片库或内部 EXIF / GPS / MakerNotes / 私有元数据。

## 已执行验证

| 项目 | 真实结果 | 证据 |
|---|---|---|
| 本地 Swift 核心检查 | PASS：11 项基础检查 + 1 项缩略图请求隔离检查 | evidence/core-checks-final.log |
| 本地 Python 测试 | PASS：6 项 | evidence/python-final.log |
| 本机 XCTest | BLOCKED：只有 Command Line Tools，无 XCTest | evidence/swift-red.log、swift-green.log；后者也是失败日志，文件名不代表通过 |
| 云端 XCTest | PASS：4 tests / 0 failures | evidence/cloud-build-4.log |
| 云端核心 / Python 检查 | PASS：12 项核心 / 6 项 Python | evidence/cloud-build-4.log |
| iOS arm64 真机目标编译 | BUILD SUCCEEDED，未签名 | Actions #4，Xcode 16.4 / iOS 18.5 SDK；不等于目标 Beta 安装测试 |
| XcodeGen 2.44.1 | PASS，工程实际生成；工具压缩包 SHA-256 已固定校验 | evidence/xcodegen.log、CI 日志 |
| Intel Release App | PASS：x86_64，ad-hoc 签名验证通过 | evidence/mac-package-final.log |
| 本机 App 启动 | 已实际启动进程；未做 GUI / USB 功能验收 | evidence/local-environment.json |
| USB 库加载 | 旧库依赖缺失后修复，当前可用库能加载 | evidence/usb-discovery.json、usb-discovery-fixed.json |
| USB 设备发现 | BLOCKED：lookup -3，未找到 USB iPhone | evidence/usb-discovery-final.json |

本地 Mac 包：`build/PhotoBridgeMac-Intel.zip`，SHA-256 `e1c19307952220dbda6a866a4dae0b77d04cd646ca638fbc5d8ca931ead7a7f6`。

## 云端构建与源码提交

- 本地实际提交：`176872c` 规格；`c2cf51c` M0 实现；`0f7f01f` 明确测试路径；`7e9ffcc` 缩略图竞态修复与云编译记录。当前仓库其他已有项目均未提交到 PhotoBridge 私有仓库。
- [Actions #1](https://github.com/loterr298/PhotoBridge/actions/runs/39041117636)：SUCCESS，工作流 commit `8ca4506db746d950b25d12bde9bcec66da0facf4`。首轮代码编译通过。
- Actions #2 只提交了新版源包，旧 bootstrap 因已有 Package.swift 未展开新版本；虽然构建成功，**不能算缩略图修复的编译证据**。
- [Actions #3](https://github.com/loterr298/PhotoBridge/actions/runs/39079880516)：修复版实际测试和双端编译通过，workflow commit `af24ce901bd2eb12c5f32ad9ccb8d67de5a45b0b`，展开源码 commit `4e9a33f`；源包 SHA-256 `145fcdafadc1103de34fb068e2df05d0433b7e7b6d173b7643a3990461046053`。
- [修复版构建产物](https://github.com/loterr298/PhotoBridge/actions/runs/39079880516/artifacts/12118711190)：238530 bytes，SHA-256 `5d51a2610c432505f949c855d2570ee4b2f8bd7ad66bcf7365ce15c52b2af235`，内含 iOS unsigned .app.zip、Intel App、校验值、完整工具链/测试/构建日志、生成的 project.pbxproj。浏览器自动下载未取得本地文件；以上是实际已生成的云端产物链接。
- 首次建仓因连接器未获新仓库权限、命令行未登录，使用用户已登录网页上传已提交源码包，CI 校验后展开为正常源码目录。临时 bootstrap 现已移除，后续 CI 只读仓库并直接构建已提交源码，避免反复解包覆盖后续开发。

## 失败、修复和审查

1. 本机 XCTest 缺模块：环境限制，保留失败输出；使用本机可执行 CoreChecks，并由完整 Xcode 云环境实际运行 XCTest。没有将本机 XCTest 说成通过。
2. 本机旧 libimobiledevice.dylib 的 libusbmuxd.dylib 依赖缺失：加入实际候选库加载；已从加载失败推进到真实 USB lookup 无设备错误。不修改系统库。
3. 独立代码审查发现 P2：旧缩略图异步回调可能覆盖新资产的图像，影响人工编号映射。取消旧请求并使用 generation token，视图消失时失效；新增回归检查及云端 XCTest 验证。无其余 Critical / Important 或延期 minor。
4. 对部分写入丢尾、忽略错位分别临时注入回归，确认检查失败后恢复并重测通过。原始首次 RED 日志包含缺模块/环境错误；并非声称全部测试严格以行为断言 RED 开始。
5. CI 存在 actions v4 的 Node 20 弃用提示，runner 强制使用 Node 24；目前构建成功，完整警告保留日志。

## 设备待验证 / 后续阶段

| 验收 | 状态 |
|---|---|
| O-01 / O-02：20 张系统 Photos 自定义顺序 + 移动五项复测 | NOT_RUN |
| U-01 / U-02：关闭无线、双向 100 MiB、拔线及 iPhone 独立回读 | NOT_RUN |
| C-02：目标 iPhone 签名安装、启动、权限 | NOT_RUN；unsigned .app 不能直接安装 |
| C-01：macOS 13/14 运行及目标设备 USB | NOT_RUN；本机 macOS 15.7.9 编译/启动已执行 |
| R-01 / R-02 / M-01：恢复、Live Photo、原始资源和元数据往返 | NOT_RUN；未实现 |
| M1–M4：正式原图导出、5 秒文件时间、相簿恢复、续传、性能、正式 UI | NOT_RUN；不越过 G1/G2 闸门，不以诊断界面冒充成品 |

下一步：按 [BUILD_AND_INSTALL.md](BUILD_AND_INSTALL.md) 完成有效签名装机；连接并信任 USB iPhone，按 [M0_DEVICE_RUNBOOK.md](M0_DEVICE_RUNBOOK.md) 完成 O-01/O-02/U-01/U-02，证据只留本地。G1/G2 实测成功后再依序实现正式原始资源导出和恢复。许可证与 Apple API 边界见 [M0_API_LICENSE_AUDIT.md](M0_API_LICENSE_AUDIT.md)。

## 最终直接源码构建（2026-10-18）

[Actions #4](https://github.com/loterr298/PhotoBridge/actions/runs/39080022210) **SUCCESS**，commit `66dae157b690f6023309444db4423e191d399ced`。直接 checkout 已提交源码，只读 contents 权限，不解包 SourceBundle。4 项 XCTest、12 项核心检查、6 项 Python 测试均通过，iOS device build 和 Intel 打包通过。完整日志 `evidence/cloud-build-4.log`，摘要 `cloud-build-4.json`，页面截图 `cloud-build-4-success.png`。

[最终构建产物](https://github.com/loterr298/PhotoBridge/actions/runs/39080022210/artifacts/12118895251)：238535 bytes，SHA-256 `be560da205b8d48994fa712a62115620a90f51a2e377dd658f45d736f642d870`。云产物默认保留 14 天；含 unsigned iOS App、Intel App 和构建/测试日志。浏览器自动下载仍未取得本地云产物，未伪称已下载。Mac 本机产物已实际生成于 build/。

M0 软件交付至此完成；相簿保序、USB 双向传输和原图往返的设备验收仍是 NOT_RUN。后续阶段没有标为已实现或通过。
