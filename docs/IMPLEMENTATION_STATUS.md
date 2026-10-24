# 实施状态记录

## 当前交付快照（2026-10-23）

这是仓库当前源码的最新状态摘要；下面的历史记录保留每个阶段的原始证据，不能覆盖本节结论。

| 范围 | 当前状态 | 证据边界 |
|---|---|---|
| iOS SwiftUI 用户端 | **代码已实现，可生成未签名 iOS 包** | PhotoKit 相簿读取、原始资源暂存、SHA-256、断点恢复、PhotoKit 回写、权限/空间/时间策略均有真实实现；当前分支的完整 Xcode 编译仍需 GitHub Actions 或安装 Xcode 的机器 |
| Intel macOS 用户端 | **代码已实现，可生成 x86_64 App** | `scripts/build-mac.sh` 会打包 AFC/House Arrest、PTP 诊断、下载/上传/续传、原子校验和进度 UI |
| 自动化验证 | **本地可执行** | `bash scripts/verify-delivery.sh` 运行 Swift Package、CoreChecks、StagingChecks、RecoveryChecks、Python 测试、iOS Swift 语法解析和 Intel 打包；报告写入 `build/verification/delivery-gate.json` |
| 真机与系统 Photos 验收 | **按证据分级，不能扩大宣称** | 已有目标设备的限定范围顺序、USB 合成探针和部分原始资源/恢复证据；HEIC/PNG/RAW/DNG、大批量、macOS 13/14、签名安装和异常注入仍需对应设备日志 |
| 云编译 | **最近一次记录为远程 main 的基线构建** | Actions #28 成功，但源码 commit `4b22c46` 早于当前本地提交；没有把它当作当前 UI 的编译证据。当前分支无法从本机 Git CLI 推送（无 GitHub CLI 凭据） |

可交付文件：本地 `build/PhotoBridgeMac-Intel.zip`；iOS 需要 Actions 生成 unsigned IPA 后用用户自己的 Apple ID 签名。未签名 IPA 不能直接安装。真机未覆盖的项目在 UI 和文档中保持“待验证”，不会显示“已通过”。

### M4.6 面向用户的界面文案收口（2026-10-23）

根据最新交付审查，iPhone 和 Intel Mac 的主流程已改为普通用户语言：

- “备份相册 / 保存到 Mac / 继续上次保存 / 恢复到新相册 / 连接帮助”成为主要动作；USB、AFC、PhotoKit、SHA-256、localIdentifier 等工程词移到详细信息或高级设置。
- iPhone 的连接、保存、恢复、暂停、失败和完成状态都改为“发生了什么 + 下一步怎么做”的短句；相册编号和内部标识只在“查看详细信息”中显示。
- Mac 端把“检测 USB、收件会话、真实输出、续传”改成连接、手机备份、详细信息和继续上次保存；底层日志仍保留，方便排查但不打扰日常使用。
- 本轮 `swiftc -parse apps/iOS/*.swift`、`swift build --product PhotoBridgeMac`、Python 63 项、CoreChecks 49 项、StagingChecks 23 项、RecoveryChecks 57 项均通过。

本次总门禁命令：

```bash
bash scripts/verify-delivery.sh
```

只有没有 Xcode 的环境可使用 `bash scripts/verify-delivery.sh --core-only`；这不会绕过测试，只跳过本地 Intel 打包。GitHub Actions 会执行同一门禁的 `--core-only` 模式，再执行实际 iOS device build 和 Intel package build。

更新：2026-10-23。历史阶段记录从下方开始。

### M4.18 备份页面进度和用户化布局（2026-10-24）

按最新页面参考图调整“备份到 Mac”页面：移除多余的技术说明和重复动作，保留相册名、照片数量、可选的 iCloud 原图下载、开始备份、备份进度和继续上次备份。点击后新增独立的扫描状态：显示转圈进度和“正在读取 X 张照片…”，扫描完成后再显示逐项备份进度。

本地验证：iOS Swift 语法解析通过，Python 63 项测试通过，`git diff --check` 通过；GitHub Actions #85 已完成云构建。

扫描进度版云包：iPhone IPA SHA-256 `0f1ff1ac5ef8cedc8bcb299ff800aa459ffe90dde4da7f085c5d86c5c3a743b3`；Intel Mac ZIP SHA-256 `2e5fb2da076c1d9dfb6e8980c2fb2dd950371bc1f5a5f119f1e425b02f3b4dbd`；artifact digest `sha256:5f7f651d07b997bff98b6fc56b76704df3e2453b3302094cd344a3b437280c64`。

### M4.17 大相册点击无响应修复（2026-10-24）

修复“点击开始备份后万张照片长时间没有反应”：原实现会在主线程同步扫描相册成员并读取每张照片的资源目录，导致 SwiftUI 无法及时刷新。现在相册扫描、成员数量统计和恢复前的重复扫描都在后台任务执行；点击后立即显示“正在读取相册…”，完成扫描后再进入逐项备份。

本地验证：iOS Swift 语法解析通过，Python 63 项测试通过，`git diff --check` 通过；GitHub Actions #81 已完成云构建。

大相册修复包：iPhone IPA SHA-256 `28dc167ba025c27332bd08da413c4af47852dad151f260301fec56dbdfa1852e`；Intel Mac ZIP SHA-256 `ebb6e49e9843de279c9f4884f52da89b620718794532a951a3f7e3ffcc36f079`；artifact digest `sha256:e8300d2ee5a7c18d0ba62ba4239ad5852d3c0e1d571a3aa2ff5e7f2336cf163d`。真机大相册点击反馈仍需用新包复测。

### M4.16 Mac 本地覆盖更新（2026-10-24）

已按用户授权直接更新本机 `/Applications/PhotoBridgeMac.app`：先保留旧版本备份，再安装 `PhotoBridge-0.3.11-FullPolish`，验证 Intel x86_64 架构、严格代码签名和 0.3.8/12 包版本，并启动新进程。证据：`docs/evidence/m4-full-polish-mac-auto-update.json`。

后续用户继续要求 Mac 端更新时，沿用“备份旧 App → 覆盖安装 → 验签 → 启动”的流程，不再要求用户重复手动替换。

### M4.15 全页面文案与状态收口（2026-10-24）

逐页检查了当前用户可进入的界面：备份首页、相册选择、备份详情、备份进度、导入页面和 Mac 双向传输窗口。

- 删除重复的刷新入口和“传输”泛称。
- 将“正在准备/正在保存/正在恢复”等内部状态转成“正在读取照片/正在备份照片/正在导入照片”。
- 让每一页只保留当前动作、当前进度、下一步操作；隐藏会话编号、工程术语和不必要的技术说明。
- 保留错误、暂停、继续和真实进度，不改变底层数据保护和传输逻辑。

本地验证：iOS/Intel Swift 语法解析通过，Intel x86_64 打包通过，Python 63 项测试通过，`git diff --check` 通过；GitHub Actions #77 已完成本轮云构建。

全页面优化版云包：iPhone IPA SHA-256 `01d139056904055e6cc4b0a01b115507d8fb2bbee8aae8230f571988a15bf2f7`；Intel Mac ZIP SHA-256 `6bbb55257181d14a6adcc6f5396655438114641fcf712a928940ef012b164672`；artifact digest `sha256:abfc9a55ec4757a00f06c5dce4e4b75aec4698841e7a9812a7c66cd36c0257b4`。

### M4.14 两条主流程收口（2026-10-24）

根据用户实际操作反馈，删除 iPhone 主界面的“传输”入口，改为两个直接可理解的页面：

1. `备份到 Mac`：选择相册 → 开始备份 → 在 iPhone 查看进度；Mac 端查找手机备份、选择文件夹并保存，同时查看进度。
2. `导入到 iPhone`：Mac 端选择照片文件夹并发送；iPhone 端查找照片、检查后开始导入，同时查看进度。

删除了重复的功能介绍、泛化的“传输”页面和不必要的高级入口。两端的底层续传、校验和原顺序逻辑保持不变。

本地验证：iOS/Intel Swift 语法解析通过，Intel x86_64 打包通过，Python 63 项测试通过，`git diff --check` 通过；GitHub Actions #72 已完成本轮云构建。

本轮核心流程包：iPhone IPA SHA-256 `f883dfcdcf82463ce5039e1817a3c45e8615ab9f984558672f1ae73679575976`；Intel Mac ZIP SHA-256 `c5dab0790f15e7b290e74d794e790202d8d10ee46a2a56575482876cc9e6fff2`；artifact digest `sha256:7a4022f05fa5cf53989e0a522ab9a11c9d578f42a90f9bd75e8b43242e0fd845`。

### M4.13 卡片亮度微调（2026-10-24）

用户反馈首页和其他页面卡片偏灰。本轮把 iPhone 和 Mac 的主卡片从系统材质改成更亮的系统背景白色浮层，降低灰雾感，保留浅蓝背景、白色边缘和轻阴影；相册行、连接状态和 Mac 侧栏视觉同步调整。真实数据、传输逻辑和按钮行为未改变。

本地验证：iOS/Intel Swift 语法解析通过，Intel x86_64 打包通过，Python 63 项测试通过，`git diff --check` 通过；GitHub Actions #66 已完成本轮云构建。

亮色卡片版云包：iPhone IPA SHA-256 `7651ad4f815c16a48e0ad45ca6d3bb67c886a1e84c3e0ea73094d27ef8d3e416`；Intel Mac ZIP SHA-256 `e678238a14a132504b38ef00f8a1bd274aefc081404617c8420fbf98297ba630`；artifact digest `sha256:ece2dbf4e558ce2df724ce8999c44ed9413197504981052a979ab21644c7c189`。

### M4.12 参考图视觉重做（2026-10-24）

根据 `download.png` 和 `assets/iphone-ui-minimal.png` 的确认稿，双端页面已改为同一套浅蓝、白色半透明卡片和系统圆角视觉：

- iPhone 首页恢复四个用户可见入口：相册、传输、恢复、设置；相册页加入顶部连接状态、设备卡片、开始导出/导入到 iPhone、真实相册封面列表和顺序保留提示。
- iPhone 传输、恢复、设置页统一卡片间距和文案，隐藏工程编号、诊断术语和底层传输细节；真实进度、失败和可继续状态仍保留。
- Intel Mac 改为侧栏 + 主内容布局，顶部连接状态卡片，中部“开始导出”和“导入到 iPhone”两个主操作卡片，底部显示真实进度和完整保存路径。
- 不使用参考图作为静态屏幕，所有封面、数量、状态和进度仍来自 PhotoKit/USB 实际数据。

本地验证：`swiftc -parse apps/iOS/*.swift`、`swiftc -parse Sources/PhotoBridgeMac/PhotoBridgeMac.swift`、`swift build --product PhotoBridgeMac`、`bash scripts/build-mac.sh`、Python 63 项测试和 `git diff --check` 均通过。GitHub Actions #61 已完成本轮 iOS arm64 unsigned build、Intel macOS build 和交付闸门。

本轮云包：iOS IPA SHA-256 `1165522352ccdf06748c08d7cf8c095a4cd81177c7e23fe63b669cc8af36748f`；Intel Mac ZIP SHA-256 `d6529897e16a4f9c704b9f859252ad7e30ef06279d6655c5145fbc6181947e86`；artifact digest `sha256:8e5e95327dd6691dc906151d75537d5d374ca9fe24ba8d4f7d6aeeebcd0f710d`。

### M4.11 面向最终用户的双端交付收口（2026-10-24）

本轮根据实际使用反馈，产品界面只保留两条主流程：

- iPhone：选择相册 → 点“开始准备照片” → 照片暂存在手机的 PhotoBridge 文件区。
- Intel Mac：点“查找手机备份” → 选择保存文件夹 → 保存完成后显示完整路径。
- Mac → iPhone：选择电脑上的照片文件夹 → 发送 → iPhone 点“恢复到新相册”。原相册和原文件不会被删除或覆盖，顺序按保存清单恢复。
- 删除了用户端的诊断、相机目录、底层 USB/AFC、会话哈希和测试暂停等主界面内容；底层脚本和日志仍保留给排查使用。

针对“保存快完成时闪退”，定位到导出结束阶段一次性把整本相册的资源清单编码成 JSON，可能造成末尾内存峰值。已改为逐项写入临时清单，完成后原子替换正式清单；中断时保留可继续的已完成项目，并在最后阶段显示“正在整理保存记录，请不要关闭 App”。这是基于代码路径和触发时机的修复，仍需用户在大相册上复测，不能把云编译当作真机稳定性证明。

GitHub Actions #54 已成功完成 iOS arm64 unsigned build、Intel macOS build、自动化测试和交付闸门：

- iOS IPA：`build/PhotoBridge-0.3.8-M4-Final/PhotoBridgeOrderProbe-0.3.8-M4-unsigned.ipa`，SHA-256 `d5ace8f67c2c12c065b91ce7b3a18f9da485aeddf5e79743a065d782d26c3405`。
- Intel Mac ZIP：`build/PhotoBridge-0.3.8-M4-Final/PhotoBridgeMac-Intel-M4.zip`，SHA-256 `7fdca36d0bbe19781babb06b66b64d82a7ebd258f2e67bda1aed26ceeab0314d`。
- 云端产物包：[Actions #54](https://github.com/loterr298/PhotoBridge/actions/runs/40010990092)，artifact digest `sha256:91a91abe1615471e3dfa3da4de211ceb48802e48e606efe59863fba8143b71d5`。

本地复核：iOS/Intel Swift 语法解析通过，Python 测试 63 项通过，`git diff --check` 通过；云端完整构建通过。未签名 IPA 仍需用户用自己的 Apple ID 签名安装，真机复测前不标“已通过”。

规格包从 `/Users/l/Downloads/PhotoBridge-AI-Project` 导入当前工作区 `PhotoBridge/`，原包未改动。私有 GitHub 仓库：[loterr298/PhotoBridge](https://github.com/loterr298/PhotoBridge)。

## 已完成的软件实现

- iOS SwiftUI：PhotoKit 全库/受限/拒绝权限，自建普通相簿、真实懒加载缩略图，nil / empty 两种不指定排序的读取。逐项输出相簿名、相簿 ID、ordinal、localIdentifier、时间、权限、系统/构建版本；可保存本地 JSON 并主动分享。读取本身永远不自动标为顺序通过。
- iPhone / Mac 各自生成 100 MiB 合成文件，流式 SHA-256 / 回读校验。USB-only House Arrest / AFC PoC，新 UUID 目录、部分写入处理、大小/hash 检查、不覆盖现有文件；iPhone 独立回读上传文件。2026-10-18 已取得真机双向合成文件大小/hash 证据；完整闸门状态见文末。
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

下表是当时闸门的原始快照，保留用于审计历史；当前源码的逐项结论以 [FINAL_DELIVERY_AUDIT.md](FINAL_DELIVERY_AUDIT.md) 和本文件顶部“当前交付快照”为准。

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

## 安装载荷交付修复（2026-10-18）

- 更正下载状态：浏览器下载事件超时不代表文件未落盘。本轮在 Downloads 找到首轮产物，SHA-256 与 artifact #1 一致；又实际下载了 artifact #4，SHA-256 为 `be560da205b8d48994fa712a62115620a90f51a2e377dd658f45d736f642d870`。
- 实际检查 #4 的编译后 Info.plist，发现 `CFBundleShortVersionString` 和 `CFBundleVersion` 缺失。因此此前仅构建成功，不足以宣称安装载荷完整；原始失败记录见 `evidence/ios-package-check-red.json`。该草稿 IPA 已单独保留为 INVALID，不交付给用户。
- 修复：XcodeGen 显式设置 MARKETING_VERSION=0.1.0 / CURRENT_PROJECT_VERSION=1；CI 对编译后的版本、bundle ID、照片权限、文件共享和可执行文件实际断言，并输出标准 Payload 结构的未签名 IPA 与 SHA-256。实际提交 `76c0924`。
- 用户本轮明确要求先拿打包 App，并表示有免费 Apple ID；不再等待连接真机。当前本机有一个可用开发签名身份，但现有描述文件已过期且 bundle 不匹配，不用于签名；未导出私钥、不上传凭据。设备安装仍为 NOT_RUN。
- [Actions #6](https://github.com/loterr298/PhotoBridge/actions/runs/39080542370) 已 SUCCESS，commit `775ce274e36893f44957de5fc4f0fc22c64acd5f`；4 项 XCTest、12 项核心检查、6 项 Python 测试和双端构建通过，编译后安装字段断言通过。#5 被后继构建按既有并发策略取消，不算失败或通过。


### 本轮实际交付的 App 文件

已下载 #6 artifact `12119220003` 并验证 SHA-256 `7215543e7a29deb8d543c5dc34cd2a47fc6e92da211d8c767acd50ef8b48166c`，同时对内部 IPA / Mac ZIP 与 CI SHA256SUMS 逐个核对。

- `build/PhotoBridge-0.1.0-M0/PhotoBridgeOrderProbe-0.1.0-unsigned.ipa`：标准 Payload；arm64；版本 0.1.0 / build 1；包内 Info.plist 权限及文件共享键验证通过，文件可执行权限与 ZIP CRC 校验通过。未签名，未装机。
- `build/PhotoBridge-0.1.0-M0/PhotoBridgeMac-Intel.zip`：实际二进制 x86_64，ZIP CRC 通过，ad-hoc 签名，未公证。
- `build/PhotoBridge-0.1.0-M0-Apps.zip`：两端 App、中文安装说明与 SHA256SUMS。SHA-256 `8a173c579ce6b70d4970083b002570987f429bfd1d79ff58c2767c9474d5af69`。

详细载荷校验记录 `evidence/ios-package-local.json`。签名前检查只保存不含证书/账号/设备标识的摘要 `evidence/signing-readiness.json`；未导出私钥，不使用过期或不匹配的描述文件。本轮按用户要求交付未签名 IPA，不等待连接设备；相簿及 USB 真机验收仍 NOT_RUN。


## 首轮真机联调与 Documents 路径修复（2026-10-18 晚）

- 用户已安装双端 App；实际 USB-only 发现 iPhone16,1 / iOS 27.2，并成功打开已安装 iPhone App 的 House Arrest `VendDocuments`。读取到 build `775ce274`、full 权限及真实相簿清单，故 C-02 的安装/启动/照片读取已有真机证据；未将其等同全部界面验收。
- 首次访问容器根目录返回 AFC error 10（权限拒绝）。对照 ifuse / House Arrest 路径实现确认共享根目录仍为容器，授权路径为 `/Documents`。统一映射 list/read/write/mkdir/rename 到该路径，拒绝绝对路径、空路径、NUL 和点段。先记录 2 项缺失 helper 的 RED 错误，再实现修复；真实 list/download/upload 均已执行成功。日志 `evidence/usb-documents-path-{red,green}.log`。
- iPhone → Mac：104,857,600 bytes，SHA-256 一致，含校验约 2.660 秒 / 37.592 MiB/s。Mac → iPhone：独立 104,857,600 bytes，AFC 写入及回读 SHA-256 一致，含生成/校验约 3.782 秒 / 26.439 MiB/s。两份均为随机合成探针，**不是原图导出/回写证据**。脱敏摘要 `evidence/device-usb-20261018.json`。
- 用户确认手机无线已关闭；Mac 按联调安排保持联网。已记录 USB-only 设备在 13:02:01 UTC 消失、13:02:06 UTC 恢复（约 5.2 秒）；重连后另行下载同一 100 MiB 探针，大小/hash 再次通过。这证明连接恢复，不是中断续传。手机 App 独立收件校验仍待收集，不将严格双端无线关闭测试标为通过。AFC 双向大小/hash 已验证，G2 完整验收仍待手机记录。
- 用户指定的现有相簿实际有 19,335 项，已完整读取 ordinal/localIdentifier；私人清单只留 `private-diagnostics/`。没有系统照片独立基准，不能据此通过 O-01/O-02。已请用户准备独立 20 张测试相簿，不改变现有大相簿顺序。
- 修复后本地 Python **8 tests / 0 failures**，Swift CoreChecks **12 项通过**；Intel Release 重打包及 ad-hoc 签名检查通过。日志 `evidence/python-device-fix.log`、`core-device-fix.log`、`mac-device-fix.log`。更新产物 `build/PhotoBridgeMac-Intel.zip` SHA-256 `af05f0c13f6ebb7dca3c0e6aa3119c42f1afa3d633f951386b4f57ec815741a1`；本轮云构建结果见下。
- G1 未通过，M1–M4 未标完成；未删除、覆盖或改写任何原始照片/内部元数据，未向云端提交照片或私人标识。

已将实际安装的 `/Applications/PhotoBridgeMac.app` 内 AFC 脚本同步为修复版；旧脚本在本地 build/ 备份，重新 ad-hoc 签名并验证。未改 iPhone App，当前装机版本可继续此轮测试。证据 `evidence/installed-mac-script-fix.json`。


### 同轮 20 项诊断清单与云端回归结果

已通过 USB 收集新建测试相簿的真实 20 项清单（full / nil-options）。20 个位置及完整 localIdentifier 已保存本地 `private-diagnostics/dw-photokit-positions.md`，**该表来自 PhotoKit，不是系统照片的独立顺序基准**。O-01 仍待人工逐项观察，O-02 的移动五项复测仍 NOT_RUN；不能用大相簿或新建 20 项清单直接替代闸门。

[Actions #8](https://github.com/loterr298/PhotoBridge/actions/runs/39129847063) **SUCCESS**，源码 commit `c094ab75c1bbd1f373b4ab15e8ec830b821ba2a8`，包含路径修复及回归测试；此前修复提交 `6f39404987be2fdde162d609491d6c1c1aadf46c` 的 #7 同样 SUCCESS。#8 实际执行 **4 XCTest / 12 核心 / 8 Python**，iOS arm64 BUILD SUCCEEDED，Intel x86_64 App 打包通过。实际工具链 Xcode 16.4 / iOS 18.5 SDK；不猜测 Beta SDK。

[云端产物](https://github.com/loterr298/PhotoBridge/actions/runs/39129847063/artifacts/12137229230) 已下载并验证 SHA-256 `c4f4224893509b9cde031cdc965f6ce2811af74116ffcea9789de8cecce0ec6c`、ZIP CRC、内部 SHA256SUMS；位于 `build/cloud-8/build/`，含未签名 IPA、Intel App、完整构建/测试日志。状态、日志及成功截图在 `evidence/cloud-build-8.json`、`cloud-8-*.log`、`cloud-build-8-success.png`。iOS 源码未改，不要求用户为本次 Mac 脚本修复重复装机。


### M0 真机闸门阶段结论（以前述历史状态为准的更新）

- G1 / O-01：用户独立观察当前 20 张测试相簿在系统照片自定义排序与 App 逐项一致。最终采用 13:08:10 UTC 的 20 项清单作为新基准。
- G1 / O-02：13:10:12 UTC 新清单仍为同一相簿、同一批 20 个唯一 localIdentifier，变化位置为 3、4、5、7–14、19、20（13 个位置）；用户在明确要求“仅拖动至少五张，不增删替换成员，逐项核对”后回复“一致”。记为 **TARGET_DEVICE_MANUAL_PASS**，依据是用户人工观察加真实 JSON，不声称存在自动化系统照片基准或公共 API 全场景保证。
- 期间一次 15 项、另一次恢复 20 项但替换了 5 个成员，均被实际检查拒绝。未掩盖为通过；最终重新建立固定 20 成员基准后再测。
- G2：双向各 100 MiB SHA-256 通过，手机 App 保存的 3 份独立 HASH_PASS 文件已通过 USB 取回并与 Mac 源文件核对一致；设备拔线消失 / 重插恢复，重连后 100 MiB 下载再次 hash 通过。记为 **SYNTHETIC_USB_PASS**。手机无线关闭由用户确认；Mac 保持联网，严格双端无线关闭场景没有执行。USB 客户端仅启用 USBMUX 标记，不启用网络设备查找。
- 验证范围只覆盖此 iOS 27.2 设备、build 775ce274、full 权限普通相簿 / nil-options；empty options、Limited/拒绝、其他相簿与系统版本不能据此标通过。没有原图导出/导回、Live Photo、元数据往返或断点续传通过宣称。
- 私人照片、相簿名、localIdentifier 与原始快照保留本地；GitHub 仅同步脱敏汇总。进入 M1 的原始资源导出实现与测试；M1 设备验收仍 NOT_RUN。


## M1 开发开始：原始资源清单与校验（2026-10-18）

M0 已取得限定范围的 G1/G2 真机证据后进入 M1。新增版本化资源清单，逐资产 ordinal / localIdentifier / 资源组，逐资源原始文件名 / UTI / PhotoKit 类型原值 / 安全保存路径 / byteCount / SHA-256；未知类型不丢弃。校验拒绝缺项、成员替换、资源缺失、hash 错误及无效路径。五秒逻辑时间独立计算，恢复状态固定为 NOT_RUN。

本地 Swift 核心原 12 项 + 新 7 项通过（总 19 项）；RED 为新增 API 缺失的编译失败，并未伪称这是行为断言失败。日志 `evidence/m1-manifest-red.log` / `m1-manifest-green.log`。设计和执行计划 `superpowers/plans/2026-10-18-original-export.md`。原生 PhotoKit 原图导出、Mac 下载工程正在接入，**M1 真机原始资源验收仍 NOT_RUN**。


### M1 原生暂存与 Mac USB 下载实现（0.2.0 / build 2）

- iOS 新增真实导出页：显示实际成员数量和本机可用空间，默认关闭 iCloud 下载；逐项获取 PHAssetResource 全部资源，PHAssetResourceManager.writeData 顺序写入新 UUID 目录，工具线程逐文件 hash，独占提交资源及最终 album-order.json。保留所有资源原始名称、UTI、类型原值和 Live Photo 组关联，不重编码或修改内部元数据。
- 资源边界停止、权限撤回、资源为空/写入失败均保留失败日志和部分文件，不生成完整清单；导出后重新读取成员/顺序/modificationDate，变化时拒绝提交。阶段清单与原始资源只写入本地 Documents/Exports，未自动上传。
- Mac 新增 scripts/album_export.py：USB-only AFC 流式下载，严格校验完整清单、UTC、路径、资源大小/hash；重复目标直接失败；最终 transfer-manifest.json 以独占硬链接提交。新副本 mtime 按 ordinal 的 5 秒 UTC 步长设置，设置前后重新确认 bytes hash。创建时间 **NOT_SET：尚未实现**，旧/新文件属性记录 JSONL。
- 独立审查发现并修复：不完整清单可能被接受、进度日志随资源数平方增长。增加全字段/类型拒绝测试与固定大小 progress / 追加式 JSONL 结构检查。真实 RED 日志 m1-review-red.log，修复后 Python **13 tests / 0 failures**，CoreChecks **19 项通过**，Intel 包已编译；详见 m1-code-review.md / m1-python-green.log / m1-manifest-green.log。
- 原图/Live Photo/编辑资源/iCloud/权限中断等真机导出均 **NOT_RUN**；尚未装新版 iPhone App。尚无导回、相簿恢复、可靠续传或海量性能通过声明。当前 iOS SDK 实编译将在本轮 CI 中验证，不能拿本地 Swift 核心编译替代。


### M1 云端实编译与新版安装包（2026-10-19）

[Actions #9](https://github.com/loterr298/PhotoBridge/actions/runs/39145285063) **SUCCESS**，实际源码 commit `2a09ad0b263309105f4e1b130b7d44d81f97b94b`。实际执行 4 项 XCTest、19 项 Swift 核心检查、13 项 Python 测试，iOS device BUILD SUCCEEDED，Intel x86_64 App 打包通过。仍为 Xcode 16.4 / iOS 18.5 SDK，不以目标设备系统版本猜测 SDK。

[构建产物](https://github.com/loterr298/PhotoBridge/actions/runs/39145285063/artifacts/12142264594) 已实际下载，SHA-256 `d2d6240dc7b5fa4bdc0c28933f6ebe17f541ee757ccd15de4f0612e389eaeeaa`；内部 SHA256SUMS / ZIP CRC 已逐个验证。IPA 编译后版本 0.2.0 / build 2，build commit 精确匹配，arm64 Mach-O 与可执行权限已核对；Mac 包内下载脚本逐字节等于本地已审查源码。详细证据 `evidence/cloud-build-9.json`、`cloud-9-*.log`、成功截图。

- 新 iPhone 包：`build/PhotoBridge-0.2.0-M1/PhotoBridgeOrderProbe-0.2.0-unsigned.ipa`，SHA-256 `67316220babec6a6ae4fecff2834afc1935842675aa5197b284c598593ca2a00`。未签名；已请用户用原来的个人签名方式覆盖更新，再在测试相簿运行导出。
- 新 Intel 包：`build/PhotoBridge-0.2.0-M1/PhotoBridgeMac-Intel.zip`，SHA-256 `38efe000abf138aea7b37011e13c1a027e4661738bb4db4d943fb1dcc44e433e`。
- 已对本机旧 Mac App 做完整 ZIP 备份，使用上述云包更新 `/Applications/PhotoBridgeMac.app`，验证 ad-hoc 签名并实际启动新进程。证据 `evidence/m1-mac-install.json`。不将启动进程冒充 GUI/原图功能验收。
- 两端安装包、SHA256SUMS 与实测说明：`build/PhotoBridge-0.2.0-M1-Apps.zip`。具体步骤 `M1_DEVICE_RUNBOOK.md`。

本地实际提交 `454f9ad`（真机路径修复）、`b38c86f`（限定范围 M0 设备证据）、`be1db55`（资源清单）、`7cc95e1`（原生导出和 USB 备份）。私人照片和完整标识没有进入 GitHub。**当前 M1 状态：代码已实现、自动化检查与双端实编译通过；新版原图真机导出/元数据与 Live Photo 实测待用户安装运行。照片库导回、相簿恢复、创建时间设置、断点续传仍未完成。**


## M1 device failure and 0.2.1 correction (2026-10-19)

The user installed 0.2.0 and completed staging. Actual AFC reads: source-order.json and export-progress.json were regular files with nlink=1 and readable (STAGED); album-order.json and its .part both had nlink=2 and both returned AFC open error 1. This was a real M1 USB failure, not a passed backup. Original Photos data and old staging were left intact. Evidence: m1-device-hardlink-failure.json.

Root cause: native hard-link commits are incompatible with this target AFC. Shared StagingFiles.commit now requires an adjacent owned .part, regular file and nlink=1, syncs it, then uses public Darwin renamex_np(RENAME_EXCL). Existing destinations are never replaced. Both iOS resource and final manifest commits use this helper. SDK availability is iOS10/macOS10.12, below our platform floors.

New regression genuinely failed against the prior link implementation, then passed after the fix. All 23 CoreChecks and 13 Python tests passed. Conflicts preserve destination and partial bytes; symbolic links are rejected. Independent review rechecked dangling destinations and multiply-linked sources, with no remaining Critical/Important finding. Logs: m1-staging-single-link-{red,green}.log and m1-python-hotfix.log. Version 0.2.1/build3 requires cloud compile and another device export before original USB acceptance can pass. 0.2.0 is no longer the acceptance payload.

### 0.2.1 修复包实际云编译结果

[Actions #10](https://github.com/loterr298/PhotoBridge/actions/runs/39146581328) SUCCESS，源码 `403aae1e2139e107c103744399f3ce7839409bb0`。实际 4 项 XCTest、23 项核心检查、13 项 Python 通过，iOS arm64 与 Intel x86_64 实编译通过。产物 `12143961459` 已实际下载，整体 SHA-256 `6270aa5b22dc23e1ab9db1f4ade7197cabf8f46a51dbb563bc403961353e2a31`，内部校验值/ZIP CRC/编译后版本 0.2.1 build 3 和可执行权限通过。

- 新 IPA：`build/PhotoBridge-0.2.1-M1/PhotoBridgeOrderProbe-0.2.1-unsigned.ipa`，SHA-256 `a10a87d891b312c2e5a844db95566bf70eddb8d945bac8c34bd0619810033508`。已交用户覆盖签名更新并请求重新导出 dw，旧暂存保留。
- 新 Intel 包：`build/PhotoBridge-0.2.1-M1/PhotoBridgeMac-Intel.zip`，SHA-256 `e3863e968a10b877c3126d19794b48c4bbb1eb50f5938f6e8a21ecff8ea0aec9`。本机已备份旧 App、更新并验签启动。
- 证据 `cloud-build-10.json`、`cloud-10-*.log`、成功截图及 `m1-mac-hotfix-install.json`。修复实际提交 `2cc55e0`。

**此处只确认软件修复、测试及编译，不把尚未执行的 0.2.1 真机 USB 原图复测标为通过。** 原图导回、相簿恢复、创建时间设置和断点续传仍未实现。


### 0.2.1 真机原始资源 USB 复测与文件创建时间实现（2026-10-19）

- 新版真机暂存已成功读取：source build 403aae1e、20 个资产、30 份资源、77,450,231 bytes。包含 20 份 JPEG 原图、5 份编辑后 JPEG、5 份 plist 编辑附件；全部保留资源角色与组关系。20 个来源成员及位置与上一轮人工通过的最终清单一致。私人清单和原图仅存本机 ignored private-diagnostics/。
- 第一次实际 USB-only AFC 下载 COMMITTED，独立 shasum -a 256 逐文件复核 30/30 一致，20 项 mtime 间隔 5 秒，同组资源同时间。此前 iOS 硬链接导致 AFC 不可读的故障，在 0.2.1 单链接独占重命名修复后未再出现。证据 m1-device-backup-verified.json。
- 新增 Mac 公开 Darwin fsetattrlist 创建时间设置，使用 O_NOFOLLOW 文件描述符、限定常规新副本，并回读 st_birthtime。平台不支持/系统错误明确记录 NOT_SET，回读不符标 NOT_VERIFIED；不静默宣称时间均通过。新会话本地目录权限 0700。
- 创建时间回归测试先因旧实现 NOT_SET 失败，再修复通过；完整 Python **14 tests / 0 failures**、Swift CoreChecks **23 项通过**。包含符号链接不得影响指向原件的检查。独立审查核对 Darwin 结构体 ABI 及系统函数参数，无剩余 Critical/Important 问题。日志 m1-creation-time-{red,green}.log / m1-core-timestamps.log。
- 第二次真实 USB 下载到另一个新目录，30 份资源全部校验，含校验 **1.444 秒 / 51.163 MiB/s**。另用系统 shasum 独立复核 30/30，实际创建时间和修改时间均 30/30 符合 capturedAt UTC + (ordinal−1)×5 秒，附件不占新序号。证据 m1-device-filesystem-times-verified.json。该速度仅为此约 73.86 MiB 小样本，不推广到其他数据量或设备。
- 当前结论为 **限定 JPEG 与编辑附件样本的原图备份及文件系统时间通过**。样本未达原图 100 MiB，Live Photo/HEIC/PNG/RAW/iCloud/权限和磁盘中断验收尚未执行；M1 全格式验收仍未完成。照片库导回、相簿恢复、断点续传及万张压力测试未实现/未通过。未删除或修改手机原图，未写入媒体内部 EXIF/GPS/MakerNotes/私人字段。
- 当前 Mac 创建时间代码已在本机实测，新增云编译与打包结果待下文记录。已安装的手机 0.2.1 无需为了 Mac 时间功能再次更新。


### Live Photo / HEIC 新样本与第 11 次云构建

用户另外暂存 3 张 Live Photo，实际读取为 3 组、6 份资源（3×public.heic / photo 类型 1，3×QuickTime MOV / pairedVideo 类型 9）。USB-only AFC 下载 19,968,426 bytes，COMMITTED；系统 shasum 独立复核 6/6，创建与修改时间均 6/6 按组 5 秒通过。记录 m1-device-live-resources-verified.json。这里只证明关联资源完整下载及 bytes 保留，不声称已经验证嵌入配对标识、导回后动态播放或往返完整性。PNG/RAW/iCloud/错误注入仍未执行。

[Actions #11](https://github.com/loterr298/PhotoBridge/actions/runs/39147856877) SUCCESS，源码 fb7c4086822a731501998bcf6d63870d8c52a0f2；实际 4 XCTest / 23 CoreChecks / 14 Python，iOS arm64 与 Intel x86_64 构建通过。产物 12144375229 SHA-256 cd80a5ae4ed92f3cfc5776edd135959a3ed9b2ff624d4298a640d904707ce536 已下载，CRC、内部校验、IPA 编译版本/commit/架构/权限及 Mac 包内源码全部核对通过。

更新 Mac 包位于 build/PhotoBridge-0.2.1-M1-times/PhotoBridgeMac-Intel.zip（SHA-256 4da058a9d747df9f60913e7e8140931a98661ee8dc271ef3f3e8b372ba318798），本机旧 App 已完整备份后更新并验签启动，记录 m1-mac-filesystem-time-install.json。手机当前 0.2.1 可继续使用，无需为了 Mac 时间功能重装。新云构建证据 cloud-build-11.json / cloud-11-*.log。


## USB 回传与新相簿恢复首版（0.3.0 / build4，2026-10-19）

按原要求继续进入回传/恢复模块，设计与验证计划见 superpowers/plans/2026-10-19-verified-restore.md。不因缺少 PNG/RAW 样本虚构全格式通过。

- 新增 RestoreSafety：逐资源大小/hash、路径及符号链接拒绝、永久一次尝试标记、保留重复数量的资源集合比较、严格来源→新标识顺序核对。新增 8 检查，本地总 **32 CoreChecks** 通过。先运行真实缺失 API 编译失败，再实现通过；不把编译 RED 说成设备行为失败。m2-restore-core-{red,green}.log。
- 新增 album_restore.py：仅接受已 COMMITTED 且清单 hash/数量/总大小匹配的本地备份，先逐文件复核再写手机。只创建 RestoreInbox/新UUID；流式写入.part、USB 回读大小/hash 后重命名，完整 ready 请求最后发布。错误保留日志和部分文件，不能把单个上传成功当成照片库已恢复。
- 文件系统边界测试覆盖完整资源含未知类型、损坏/未提交本地备份无手机写入、USB 损坏无 ready、符号链接拒绝。新增 4 测试，本地总 **18 Python tests / 0 failures**；日志 m2-usb-return-{red,green}.log。
- 实际通过 USB 回传先前校验的 3 张 Live Photo（6 份 HEIC/MOV，19,968,426 bytes），AFC 回读全部一致，含校验约 0.546 秒 / 34.889 MiB/s。只写入 App 新收件目录，未写照片库，未删除任何原件。m2-live-usb-return-verified.json。
- 新 iOS RestoreView：完整资源/清单预检，全部资源组合先询问 PhotoKit supportsAssetResourceTypes；不支持就拒绝整个恢复，不剔除附件。用户点击后只创建新相簿，每资产一笔事务添加全部资源，shouldMoveFile=false，并按 ordinal 插入。使用清单记录的原照片库日期（现有清单 ISO8601 秒精度），不写入 Mac 5 秒逻辑日期。
- 事务前永久标记防止崩溃后自动重复导入；逐资产记录映射、真实进度、失败及回读资源。新资产通过 PHAssetResourceManager 再导出，核对完整资源的类型/名称/UTI/大小/hash 多重集，重新读取相簿位置和最后编辑时间；只有全部匹配才生成 restore-report。系统照片人工自定义顺序与 Live 播放字段仍固定 NOT_RUN，待独立观察。
- 本机 macOS SDK 已对 RestoreView 做真实类型检查（仅兼容旧系统保留的 onChange 弃用提示）；不把它当 iOS 实编译或真机导入通过。新版云编译与 IPA 交付待后文记录。手机仍是 0.2.1，预检、照片库写入、资源往返和 Live 播放均 **NOT_RUN**。
- 首版不自动恢复已尝试的照片库事务，不做失败后删除、不提供无证据的续传/万张性能承诺。最终产品化 UI 和恢复健壮性继续后续阶段。

独立审查指出预检解析与 hash 使用两次文件读取可能产生时序差异。已改为 RestoreSafety.decodeManifest 对同一 Data 验 hash 后再解析，并在恢复启动及最终提交前逐字节确认 manifest/request 与预检时完全一致。增加错误 hash 拒绝检查；修复两个遗漏 try 的真实本地类型检查错误后再次类型检查通过。完整 32 核心 / 18 Python 通过，无剩余 Critical/Important 审查项。


### 0.3.0 实际云构建、安装包与当前验收边界

[Actions #12](https://github.com/loterr298/PhotoBridge/actions/runs/39149748307) 与修正过时界面说明后的最终 [Actions #13](https://github.com/loterr298/PhotoBridge/actions/runs/39149841441) 均 SUCCESS。交付使用最终源码 **3768816d24b1dfceceeb3c5b0b24e96816018632**，实际 **4 XCTest / 32 CoreChecks / 18 Python** 通过，iOS BUILD SUCCEEDED，Intel App x86_64 编译和 ad-hoc 验签通过。实际 Xcode 16.4 / iOS 18.5 SDK，未假称使用 iOS 27 SDK。

[云产物](https://github.com/loterr298/PhotoBridge/actions/runs/39149841441/artifacts/12144548414) 已下载并逐个验证，整体 SHA-256 a0fff1ee6f21116d22e4bd15b43eda0b139d0c6d37ec36c3600e87cc82602a38，ZIP CRC / 内部 SHA256SUMS 通过。IPA 编译后版本 **0.3.0/build4**、稳定 bundle ID、arm64 Mach-O、执行权限和源码 commit 已核对；Intel 包内 3 份 USB 脚本与本地审查源码逐字节相同。

- `build/PhotoBridge-0.3.0-M2/PhotoBridgeOrderProbe-0.3.0-unsigned.ipa`：SHA-256 3419cfc9893e575ab1cb76e37aa653ca51db44b61e38db164959e78feb10f0f3。已提供用户按原个人签名方式覆盖安装；不能直接安装未签名 IPA，不卸载旧 App。
- `build/PhotoBridge-0.3.0-M2/PhotoBridgeMac-Intel.zip`：SHA-256 31bbc1d4876d1f248208ed55d2ce12e3878803e3f456d32fbee565f145cbff33。本机旧 App 完整备份后更新、验签并启动；`m2-mac-install.json`。
- `build/PhotoBridge-0.3.0-M2-Apps.zip`：双端包、SHA256SUMS 和具体真机流程。云日志/成功截图/校验记录在 cloud-build-13.json、cloud-13-*.log、cloud-build-13-success.png。

**当前已实测：** 限定样本真实 USB 原图/编辑附件/Live HEIC-MOV 导出和 5 秒 Mac 创建/修改时间；Live 资源 USB 反向回读 hash。
**设备待验证：** 新版手机收件预检、PhotoKit 完整资源导入、导入后资源 bytes/顺序、系统照片人工顺序及 Live 动态播放。已请用户使用预先回传的 3 项/6 资源完成该验证，未把云编译或 AFC 收件标为 Photos 恢复通过。
**未完成：** PNG/DNG/复杂编辑/iCloud/权限与空间故障验收、原图单次 100 MiB 场景、可靠断点续传/事务恢复、万张稳定性能、最终极简产品 UI。原图和私人清单仅本机保存，不进云端。


### Live Photo 照片库闭环实测通过；20 张含编辑附件恢复如实失败

- 手机实际产生 restore-report.json，状态 PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED，3 个新资产/6 份资源回读校验通过。Mac 经 USB 独立取回全部 6 份 Photos 回读文件，系统 shasum 再验 6/6 与原始备份一致；完整类型/原名/UTI/大小/hash 多重集、旧→新标识及 nil-options 顺序匹配。用户回复“能播放”，随后明确回复“3 张顺序一致”。限定为 **3 张 HEIC/MOV Live Photo 样本闭环通过**，证据 m2-live-photos-roundtrip-verified.json。报告未独立包含运行时 build，本次软件交付源码版本另有构建证据，不臆造运行时字段。
- 随后 USB 发送原 dw 的完整 20 项/30 份资源，AFC 读回均一致，m2-dw-usb-return-verified.json。手机实际在第 12 张首次包含编辑附件的资产回读失败：新相簿已创建 12 项，前 11 项回读通过，第 12 项不匹配，未生成 restore-report，未重放或删除这些新副本。
- 已定位具体差异：第 12 项原图 JPEG 和编辑后 JPEG 均逐字节一致；1035-byte plist（PhotoKit 类型 7）的 hash 不一致。只读解析及严格递归类型/值比较确认，唯一变化是顶层 adjustmentTimestamp，Photos 在导入时重新生成系统编辑记录时间。所有其他解析字段、未知附件数据保持一致；仍不能将该附件标为字节一致。未尝试改写原件、伪造 hash、忽略差异或使用私有 setter。详见 m2-dw-restore-resource-difference.json / m2-dw-adjustment-timestamp-difference.json。
- 新增只读 scripts/inspect_adjustment.py，默认不写任何媒体或附件；只输出分类和变化键，不泄露原始值。3 项测试覆盖仅时间变化、未知私有数据/类型变化和畸形 plist，先记录缺失模块 RED 后实现；完整 **21 Python tests / 0 failures**，m2-adjustment-inspection-{red,green}.log。此工具不放宽 RestoreSafety.sameResources 的严格字节标准。
- 已检查当前公开 PHAssetCreationRequest / PHAssetResourceCreationOptions / PHAdjustmentData 接口：没有找到可指定该系统编辑记录时间的公开入口；尚未证实可以保留该字段原值。不将此观察夸大为所有未来 SDK 永远不可能。
- 按用户“只允许明确授权的时间设置”要求，已提供具体字段差异并询问是否授权仅接受新副本这一系统编辑记录时间变化。默认维持原要求；未取得授权前不放宽验证、不重复导入这个含编辑附件相簿。独立的 USB 续传模块继续实现，未标完成。


### 已授权编辑记录时间选项与安全下载继续执行（0.3.1/build5 开发）

用户明确回复“授权仅接受新副本的系统编辑记录时间重置”。已实现默认关闭的独立选项，完整边界见 PRESERVATION_POLICY.md。无授权时含编辑附件的备份在写入前拒绝；有授权也只接受类型7、相同名称/UTI/长度的无歧义 XML plist 顶层 adjustmentTimestamp 改变，其他字段/类型/opaque 编辑配方仍一致，所有媒体 bytes 仍严格。日志记录授权、运行时版本/build、附件差异数；使用独立的 NON_TIME_DATA... 状态，绝不把附件差异称为字节一致。

新增 Swift 核心策略测试，先记录缺失 API RED；审查发现 Foundation 会折叠重复 plist 键，已用根与嵌套重复键实测 RED 重现并修复，拒绝实体声明/CDATA 键及其他歧义。变化的非 XML sidecar 保持严格失败。Python 只读诊断器同样加入唯一键字典防护，避免误分类。当前 **41 核心检查 / 27 Python** 通过。实际设备 1035-byte XML 侧车经同一 Swift 核心在本机再次验证：无授权拒绝，有授权仅识别一处系统时间变化，strictBytesIdentical 仍 false。新手机策略验收尚 NOT_RUN，不能用主机 fixture 检查替代。

新增 album_resume.py 与 AFC 受限 seek：在新目录继续旧下载，以旧 progress 中精确 manifest hash 绑定源；完整文件仅在实际 hash 一致后本地复用，部分前缀保留复制后从真实 AFC 偏移继续，最终沿用完整 hash/时间/最终清单校验。旧目录不写入。审查发现目标嵌套于旧目录会违反保留约束，已 RED 重现后加入 resolved 路径/符号链接别名拒绝。说明及可复现脚本 USB_RESUME_RUNBOOK.md / tests/device_usb_resume.py。

首次硬件尝试 USB-only 返回未发现设备（-3），续传未执行，已如实记录 m2-usb-resume-device-attempt.json。用户重新连接后，真实 USB 受控接收中断测试成功：复用1份完整文件、从 **3,024,889 bytes** 前缀处继续，实际重新从 USB 读取 **15,582,759 bytes**，新建 AFC 连接后6份资源 COMMITTED，系统 shasum 6/6及新副本创建/修改时间验证通过，旧文件 bytes/mtime/birthtime 未变。证据 m2-usb-download-resume-device.json。该测试未物理拔线，不证明上传、iPhone 暂存或照片库事务续传。

0.3.1/b5 已准备源代码及 CI 元数据；新云构建、交付和 dw20 全部恢复复测结果待下文记录。原图及旧失败新相簿继续保留，未自动删除或重放。


### 0.3.1 实际云构建及交付

[Actions #14](https://github.com/loterr298/PhotoBridge/actions/runs/39188333981) SUCCESS，源码 **a3fe36c93e1f0f25a8c02098a47fe78a716b1edd**，实际 **4 XCTest / 41 核心 / 27 Python** 通过；iOS arm64 BUILD SUCCEEDED，Intel x86_64 编译通过。实际工具链 Xcode16.4 / iOS18.5 SDK，未猜测 Beta SDK。

[云产物](https://github.com/loterr298/PhotoBridge/actions/runs/39188333981/artifacts/12158792218) 已下载：SHA-256 ba2953cf66c3bbcccae7a9949d676bc9f520e813f6b93bffebee15b9d353b096；CRC、内部 SHA256SUMS、IPA 编译后 0.3.1/build5/源码 commit/稳定 bundle ID/arm64/权限全部核对。Mac 包内完整下载、回传、继续执行和只读 plist 诊断源码与本地审查版本一致；打包已排除 Python bytecode 缓存。

- `build/PhotoBridge-0.3.1-M2/PhotoBridgeOrderProbe-0.3.1-unsigned.ipa`：SHA-256 295fd223face567ae9fee52c488d1b71733ced89f9b15e6f915eee51af1b8441，已提供按原个人签名覆盖安装。
- `build/PhotoBridge-0.3.1-M2/PhotoBridgeMac-Intel.zip`：SHA-256 ffd51bb3daf13d6192ad5e045dd68ef44e0d1a1de8f981903db0e495c1c675b7。本机旧 App 同时保存 ZIP 和目录备份后安装干净云包，验签并启动；m2-policy-resume-mac-install.json。
- `build/PhotoBridge-0.3.1-M2-Apps.zip`：双端包、SHA256SUMS、恢复/授权/续传具体说明。详见 cloud-build-14.json、cloud-14-*.log 及成功截图。

dw 的新会话已通过真实 USB 发送并回读 20 项/30 份资源/77,450,231 bytes，旧失败会话及其12个新副本保留；m2-dw-authorized-usb-return-verified.json。已请求用户安装 0.3.1、开启已授权选项，用新会话完成全20项恢复及独立顺序/编辑效果核对。**新策略手机验收仍 NOT_RUN**，没有将主机 fixture、CI 或 Mac→App 收件当成该恢复已通过。新 App 会把实际运行时版本/build写入报告，后续读取再确认。


### dw 20 项完整往返验收：仅已授权的编辑记录时间例外

手机实际报告运行时 **0.3.1 / a3fe36c93e1f0f25a8c02098a47fe78a716b1edd**，20 项全部创建及回读通过，状态 PHOTO_LIBRARY_NON_TIME_DATA_AND_ORDER_VERIFIED_WITH_AUTHORIZED_EDIT_TIMESTAMPS，authorizedAdjustmentTimestampDifferences=5，strictBytesIdenticalForVerifiedAssets=false。此为设备实际报告，不再使用前文尚 NOT_RUN 的历史状态。

新增可复现的只读硬件审计 `tests/device_restore_audit.py`：绑定精确来源清单，验证全部旧→新标识及顺序，检验资源类型/原名/UTI/长度的完整多重集，经 USB 取回全部实际 Photos 回读文件，在 Mac 用系统 shasum 独立检验每份 SHA-256。源目录和手机均不写入，目标只能是全新本地目录。

实际 **20 项 / 30 份资源 / 77,450,231 bytes** 独立审计通过：20 份原图 JPEG + 5 份编辑后 JPEG 与原备份字节完全相同；5 份 XML 编辑附件只有顶层 adjustmentTimestamp 变化，其余递归解析值、类型及 opaque 编辑配方一致。源附件原始字节仍保留，严格字节一致标记仍 false。最新私有回读保存在 private-diagnostics/dw-authorized-roundtrip-independent-05，不上传媒体、文件名或标识。

用户先回复“顺序一致”，随后独立回复“5 张编辑效果一致”。记录为本机此20项自建相簿的人工顺序/可见编辑效果通过，不泛化到其他编辑、格式、系统视图。公开脱敏证据 `m2-dw-authorized-photos-roundtrip-verified.json`。

审查发现 Python plistlib 会忽略未知 XML 标签；合成 unknown BAD→XYZ 加时间变化可错误分类，仅属于诊断/独立审计工具边界，未据此隐瞒或改动真实资源。已先运行回归 RED，再加入标准库 expat 严格 plist XML 文法（tag、父子结构、属性、深度，拒绝实体、CDATA 与额外注释/处理指令），保留重复键拒绝。完整审计路径也加入拒绝回归。Swift 同类未知标签实测原已拒绝，但 Foundation 也会忽略 base64 尾随内容，已记录真实 RED 并同步收紧 Swift 产品校验。两端验证已知 tag、结构/属性及完整标量；日期必须有效、base64 必须 canonical、数字拒绝溢出和非有限值。额外比较完整 XML 结构及每个非授权标量的文本，仅允许根字典 adjustmentTimestamp 的日期文本不同，防止解析归一化隐瞒差异；未知字段即使不能理解也保留比较。真实30份资源在修复后重新经 USB 独立检查，结果相同。

本地 **47 CoreChecks / 33 Python tests** 通过，日志 `m2-native-unknown-xml-check.log` / `m2-independent-audit-tests.log`，真实 RED `m2-unknown-xml-red.log` / `m2-scalar-xml-red.log` / `m2-native-scalar-xml-red.log`。当前更严格 Swift 核心针对真实侧车的主机检查另记录 m2-strict-xml-actual-sidecars.json，不当作新版手机运行时验收。0.3.2/build6 新审计及双端解析收紧的云检查结果另行记录，不冒充原云14已运行新测试。

下一步仍为上传/手机暂存/照片库事务的安全恢复、真实物理拔线续传、PNG/DNG/更多编辑/iCloud/权限和空间故障、大规模与最终双端极简 UI。现有证明限于上述 JPEG/Live 样本和受控下载中断；未宣称完整产品已完成。


### 0.3.2 双端云构建及审计交付

代码/测试/设备证据本地提交 **dfbd8b2**，独立审查所发现的未知 XML、标量尾随内容及数值/日期归一化问题均已修复；最终复核无剩余 Critical/Important。父子文法与非时间文本签名进一步拒绝歧义，不放宽已有授权。原件及旧失败会话全部保留。

[Actions #15](https://github.com/loterr298/PhotoBridge/actions/runs/39190177844) **SUCCESS**，远端源码 **6087a6cf76fcdb7cb7216769e9c0e8fce73485ed**，实际 **4 XCTest / 47 CoreChecks / 33 Python** 通过，iOS BUILD SUCCEEDED，Intel x86_64 编译通过。工具链实际 Xcode16.4 / iOS18.5 SDK，未冒称 Beta SDK。GitHub 部分 upload 请求出现网络错误后，使用正常文件编辑页完成提交；全部源文件已同步后才触发本轮。

[产物](https://github.com/loterr298/PhotoBridge/actions/runs/39190177844/artifacts/12158724769) 下载 SHA-256 c637ec701c3465d5bf53eea31c0fb354dba794e9ba0f5212daf9d098c92d91b1。ZIP CRC、内部 SHA256SUMS、IPA 0.3.2/build6/源码 commit/稳定 bundle ID/arm64/可执行权限、Mac 版本与 x86_64 已独立核对；包内 Python/构建脚本逐字节与本地源码匹配，无 __pycache__。

- `build/PhotoBridge-0.3.2-M2/PhotoBridgeOrderProbe-0.3.2-unsigned.ipa`，SHA-256 c826b03cc099ae668436021fd947d4c559801bd60b3027b4af4850b5b1d3a689。
- `build/PhotoBridge-0.3.2-M2/PhotoBridgeMac-Intel.zip`，SHA-256 f85c6223e716e22535bb3dab4316b3e817c3b114dd69fb27e107cc6330e7beee。
- `build/PhotoBridge-0.3.2-M2-Apps.zip` 汇集双端包与最新保护/恢复/继续下载说明。云日志 `cloud-15-*.log`，核对记录 `cloud-build-15.json`，实际成功截图 `cloud-build-15-success.png`。另有 Intel 本地构建日志 m2-strict-xml-mac-build.log。

当前更严格 Swift 核心已在主机重新检查全部5份真实附件，结果仍为仅授权时间变化；新版 iPhone 二进制尚未由用户安装，明确 **NOT_RUN**。已完成的20项真机证据属于0.3.1；不挪用为0.3.2真机验收。下一次手机恢复前应沿用原个人签名覆盖更新，不卸载旧 App。上传/Photos 事务恢复、真实物理拔线/大规模及最终 UI 等后续项目仍未完成。

下一项已准备两步只读硬件脚本 `tests/device_usb_cable_resume.py`，用于同时记录 IOUSB 真消失与 AFC 传输失败，再新连接继续并独立复核全部资源及新/旧文件时间。CLI 帮助与语法检查已执行；协调用户实际拔线时机后再启动。**物理拔线结果仍 NOT_RUN**。该手工验收脚本不在云15应用包内，不改其已验证的应用二进制或测试计数。


### 物理拔线测试及共享 AFC 异常修复（0.3.3/build7 开发）

新增只读两步硬件脚本及故障分类检查。独立 IOUSB 观察、真实资源读协议失败、两者时间关联、非空部分文件及没有 COMMITTED 缺一不可；本地 sink/写盘/hash/属性异常不得冒充 USB 读失败。接收限速只为用户操作留时间，不用限速吞吐宣称产品性能。继续执行仍使用原严格清单绑定和新输出目录，不修改旧现场。

第一次实际拔线已观察设备消失，但 `AFC.read` 的 finally 关闭错误覆盖了原始读异常，严格记录 PHYSICAL_INTERRUPTION_NOT_PROVEN；用户回复“已重新连接”。无续传通过宣称，原目录保留；m2-physical-usb-first-attempt-not-proven.json。审查首先合成复现了本地异常误判，修复后新增完整 harness 路径测试；随后自动化 RED 复现 read+close 双失败覆盖根因。共享 read/write 两条路径均已修复：保留原始协议或本地异常，附加关闭错误码；没有原始错误时关闭错误仍报告。m2-afc-primary-error-red.log。

完整 **35 Python / 47 CoreChecks（核心未改）**，Python 本轮实际运行退出0，m2-physical-harness-tests.log；共享 AFC 和脚本独立复审无剩余 Critical/Important。新逻辑尚未打入云15的0.3.2包，准备0.3.3云编译，不拿旧包冒充。

用户同意再测。第二次实际中断记录到 **AFC read error30（32.4669秒）**，**IOUSB iPhone消失（32.5928秒）**，存在非空部分文件，未 COMMITTED，满足中断证据。用户回复“第二次已重新连接”，但下一次实际 IOUSB/USB-only 检测仍无设备（-3），所以 **续传 NOT_RUN、物理闭环未通过**。已保留状态并请求恢复连接；m2-physical-usb-device-interruption.json。不得把“中断证据有效”写成“断线恢复已通过”。


#### 第二次物理拔线后实际继续成功

用户随后回复“已连接并保持不拔”，本机 IOUSB 已重新发现 iPhone。另建 USB-only AFC 连接，把第二次现场只读继续到新 completed 目录：**30 份 / 77,450,231 bytes COMMITTED**；复用 **8** 份已完成且 hash 相符的资源，从 **3,145,728 bytes（3 MiB）** 部分前缀继续，实际新读取 **46,209,239 bytes** USB 资源数据。系统 shasum **30/30** 与原清单一致，所有新副本创建/修改时间及5秒间隔均验证，旧现场所有文件 bytes/mtime/birthtime 不变。手机、照片库及来源未写入。

证据 `m2-physical-usb-download-resume-verified.json`，附当前实际 CLI 源文件 SHA-256 和用户拔插说明。中断前为操作时间限速1MiB/s，不将本次吞吐当性能基准。**本机该20项样本的真实物理拔线下载续传通过**；上传、手机暂存、Photos事务恢复及万张负载仍未验证。第一轮失败和第二轮短暂无设备的记录均保留，未覆盖为成功。


### 0.3.3 最终云编译、包核对及 Intel 安装

[Actions #16](https://github.com/loterr298/PhotoBridge/actions/runs/39212122893) **SUCCESS**；源码 **c786f22119a320bebbb6b76a518616a3e567494c**，实际 **4 XCTest / 47 CoreChecks / 35 Python**，iOS arm64 编译及 Intel x86_64 编译通过。工具链日志保留实际选择的 Xcode/SDK，不臆造 Beta SDK。

[产物](https://github.com/loterr298/PhotoBridge/actions/runs/39212122893/artifacts/12168430346) 已下载，整体 SHA-256 **75997c9053b0a071cf86c4da6e9f3d8f7723a690d2de01d1a601d666472f507a**。CRC、内部 SHA256SUMS、IPA 0.3.3/build7/commit/稳定 bundle ID/arm64/可执行权限、Mac x86_64/版本、无 bytecode 缓存及所有包内脚本与本地已测源码逐字节一致均核对。`cloud-build-16.json`、`cloud-16-*.log`、`cloud-build-16-success.png`。

- `build/PhotoBridge-0.3.3-M2/PhotoBridgeOrderProbe-0.3.3-unsigned.ipa`：SHA-256 **0266a6a3833e96ce4ca3b716671f54cd247941527f7a3e68a0f05f1b290da0ad**。
- `build/PhotoBridge-0.3.3-M2/PhotoBridgeMac-Intel.zip`：SHA-256 **8fb6c7dfa33b62aba96bd1b4de9f47b758eca80d3c130856bc5b7f33157a7970**。
- `build/PhotoBridge-0.3.3-M2-Apps.zip`：双端包、SHA256SUMS、保护策略及真实恢复/继续下载说明；不含私人照片或清单。

本机原 `/Applications/PhotoBridgeMac.app`（0.3.1）先完整保存 ZIP 及目录备份，再装入干净的0.3.3云包；严格验签、Intel架构及安装后脚本源码均核对，`m2-afc-fix-mac-install.json`。没有宣称现有GUI进程已重启或界面已验收。iPhone0.3.3运行时仍 **NOT_RUN**；不要求为Mac下载修复重复导入照片。下一次手机恢复前沿用原个人签名方式覆盖更新，不卸载旧App。

当前可信范围：目标设备自建相簿20项手动顺序及改位复测；限定 JPEG/编辑附件与3组Live的往返，编辑附件仅明确授权时间例外；双向USB样本；Mac文件系统5秒时间；受控和真实物理拔线后的Mac下载继续。尚未完成：上传/iPhone暂存/Photos事务安全恢复、PNG/DNG/更多编辑/iCloud与权限空间故障、大规模及最终极简双端操作UI。原始媒体、全部失败现场和私人数据保持在本机。


### 0.3.3 手机实际运行确认；Mac 上传续传（0.3.4/build8）

用户完成覆盖安装并保存诊断后，经 USB 取回新 JSON，capturedAt=2026-10-19T06:58:31Z，运行源码 c786f22119a320bebbb6b76a518616a3e567494c，full/nil-options/20项，符合云16的0.3.3。只证明该版已运行并读取相簿；没有把旧0.3.1 Photos恢复结果挪用为新恢复通过。公开 m2-ios-0.3.3-runtime-album-read.json 不包含标识。

新增 scripts/upload_resume.py；复用已 COMMITTED 本机备份的全量字节验证。不可变 owner 绑定 session/nonce/精确清单 hash，原生 AFC 排他锁限定合作写入者，所有父目录和文件类型检查，拒绝 symlink/多链接/歧义文件、已发布请求及 Photos 尝试。完整资源实际回读核验后只读复用；部分资源逐字节比对前缀，以非截断 RW 模式打开并校验 EOF 后追加。全量 USB hash 后提交，ready 请求最后；旧日志保留、每次生成新日志。仅限新收件目录，不重放 Photos。旧版无 owner 的会话拒绝续传。

已先记录缺失模块 RED，实现后完整测试通过。独立复审发现新会话父目录 symlink 绕过，已增加父目录及新 session 检查，移除防护后回归确实失败，修复后通过；m2-upload-symlink-red.log。另一处验收边界：完整大小 .part 可能因回执丢失而存在，不能冒充实际续写；新增回归 RED，再要求严格部分 0<size<expected，并观察正数后缀实际追加，m2-upload-full-part-red.log。最终独立复核无剩余 Critical/Important。

真实 USB-only 两客户端验证原生排他锁：第二客户端 error19，首客户端关闭后可重新获得；m2-upload-native-afc-lock.json。实际 Live 3项/6资源受控读取中断后新 AFC 继续：复用1份、保留3,024,889 bytes、实际上传15,582,759 bytes；独立系统 shasum 6/6、原备份字节/mtime/birthtime、旧日志及已完成手机文件均不变。此受控测试没有拔线，m2-usb-upload-controlled-resume-verified.json。

用户同意物理上传测试，提示后拔插并回复“已连接”。真实 dw 上传记录 **IOUSB消失14.0832秒 / AFC write error30 14.7056秒**，没有提前发布请求。重连新 USB-only AFC，严格部分 **3,145,728 bytes** 通过前缀检查并实际追加 **1,284,958 bytes**，复用3份已完成文件，本次新上传资源总 **65,413,565 bytes**；全部 **30份 / 77,450,231 bytes** USB 回读和系统 shasum 30/30通过，源字节/mtime/birthtime、旧日志、已完成手机文件不变，ready最后。**本机此样本物理USB上传续传通过，Photos NOT_RUN**。源读取为人工操作限速1MiB/s，不能当性能基准。m2-physical-usb-upload-resume-verified.json；私有文件及会话留本地。

本轮实际 **41 Python / 47 CoreChecks** 通过，m2-upload-full-tests.log / m2-upload-core-checks.log；Intel x86_64 App 本地编译、严格签名检查完成，m2-upload-mac-build.log。0.3.4/build8 元数据及上传工具准备完毕，新云编译/产物尚未核对（下文另记）。手机现有0.3.3无需为纯Mac上传工具再安装；没有要求重复导入。

继续待办：iPhone暂存恢复、Photos事务不确定状态协调、PNG/DNG/更多编辑/iCloud/权限和空间故障、万张压力与速度优化、可实际操作的最终极简双端UI。当前 Mac GUI 仍是诊断入口，实际传输由随附CLI执行，未冒充最终产品。原媒体内部 EXIF/GPS/MakerNotes 等未写入；唯一额外Photos编辑记录时间授权边界不变。


### 0.3.4 云编译、产物核对与电脑端安装

本地功能提交 **01cf256**。远端源码 **103996d252a11d7c43ad98cab5f74e92833d3572** 的 [Actions #17](https://github.com/loterr298/PhotoBridge/actions/runs/39214737400) **SUCCESS**，实际 **4 XCTest / 47 CoreChecks / 41 Python**，iOS arm64 与 Mac x86_64 均编译通过；实际选中 Xcode16.4 / iOS18.5 SDK。云日志保存于 cloud-17-*.log，成功截图 cloud-build-17-success.png。

[云产物](https://github.com/loterr298/PhotoBridge/actions/runs/39214737400/artifacts/12168289317) 已下载，整体 SHA-256 **400ccf1f6466229e0b29b4bb1170eefb4de580692bb585916fc41d0d276a8964** 与 Actions 摘要一致；CRC、内部 SHA256SUMS、IPA 0.3.4/build8/commit/稳定 bundle ID/执行权限/arm64、Mac版本/执行权限/x86_64及包内全部脚本与本地已测源码一致均核对，无 bytecode 缓存。cloud-build-17.json。

- `build/PhotoBridge-0.3.4-M2/PhotoBridgeMac-Intel.zip`：SHA-256 **f54bfd9bff1e0844c91e9ce88602a0fc52fc176c1ecad98167af60739dfaf920**。
- `build/PhotoBridge-0.3.4-M2/PhotoBridgeOrderProbe-0.3.4-unsigned.ipa`：SHA-256 **b71981abb804e8c780d80baa86a6faec2e73774ad0781bbd95561a1a0ce80219**，本轮手机二进制运行时 **NOT_RUN**。已运行0.3.3可继续使用本次Mac功能，无需手机重复安装或重新导入。
- `build/PhotoBridge-0.3.4-M2-Apps.zip`：双端包、校验、恢复/下载/上传继续执行与保护说明；SHA-256 **b489c42056e63bab32b4464512ae2f0a9e6826ec3f83e5a363c1e6558dc3f158**。

本机旧0.3.3 App已保存独立目录及ZIP后，在 `/Applications/PhotoBridgeMac.app` 装入0.3.4云包；严格签名、Intel架构、所有脚本源码及安装后上传CLI --help实际运行均通过。m2-upload-resume-mac-install.json。未声称旧GUI进程已重启，未声称最终界面验收。

本阶段已完成受控及真实物理断线后的双向USB继续执行，范围均限已完整暂存备份与App收件目录。iPhone暂存/Photos事务安全恢复、更多格式及故障/规模、性能和最终UI仍待完成；不把此里程碑写成全项目通过。


### 电脑端自动更新确认

用户要求“电脑端自动帮我更新”。实际重新核对 `/Applications/PhotoBridgeMac.app` 已为0.3.4/build8，安装目录每个云包文件与已验SHA-256的0.3.4 ZIP逐字节一致；严格签名和Intel架构通过。已有旧App目录及ZIP备份保留，无需重复覆盖。随后实际启动该安装路径，进程可执行路径已确认为 `/Applications/PhotoBridgeMac.app/Contents/MacOS/PhotoBridgeMac`。此前“GUI进程未观察”的历史记录已由本次新进程观察补足，但仍未把进程存活当成最终GUI视觉验收。未进行照片库写入。证据 m2-mac-0.3.4-auto-update-confirmed.json。


### iPhone 暂存中断恢复实现（0.3.5/build9，真机待测）

新增 StagingResume 核心、OriginalExportService 及继续入口。每次导出保存完整来源计划（相簿/成员顺序、亚秒级创建及修改日期、尺寸/媒体属性、按原顺序的全部资源类型/原名/UTI），每个资源真实写完、SHA-256及单链接提交后再独占提交绑定session/精确计划hash的检查点。检查点前崩溃留下的完整文件也不凭文件名跳过；没有检查点就重新读取。

继续前校验当前PhotoKit来源完全一致及所有旧完整资源的实际hash，之后只在新的UUID会话复制已验证资源，其余通过PhotoKit重新读取完整资源。旧会话、旧.part及日志不写入；没有资源内偏移续读宣称。新会话全资源再验、来源相簿重新fetch核对、权限/停止边界检查后才最终发布album-order.json。原件或照片库无写入；Photos恢复事务不在本功能范围。旧版无plan/检查点会话拒绝继续。缺失modificationDate时可新导出，但不能据此授权缓存复用。

内部plan使用Foundation数值日期编码，避免ISO8601秒精度丢失编辑版本；现有对外清单/5秒Mac新副本属性策略不变。新日志明确记录实际运行commit、复用完整资源数、重新读取完成资源数、partialResourceBytesReused=0及来源计划hash；旧snapshot的capturedAt和逻辑时间基准保持。

先运行缺失类型编译RED，随后23项新的实际Swift可执行检查通过。补测发现Int.min检查点下标会在减1时算术trap，实际exit -4记录m3-ios-staging-index-red.log；改为减1前guard正数/范围，两项回归通过。其他检查覆盖亚秒编辑、顺序/成员/改名/资源目录、hash损坏/缺失、foreign检查点、symlink、复制不覆盖/嵌套拒绝、旧bytes/mtime/部分资源不变、单链接及完成会话拒绝。独立只读复审无其他Critical/Important；同一collection对象的旧标题快照问题也已改为重新fetch相簿，未据旧对象宣称改名可检测。

实际本地 **23 StagingChecks / 47 CoreChecks / 41 Python**，iOS源码语法parse与Intel x86_64构建通过；日志m3-ios-staging-{red,index-red,green,core,python,mac-build}.log。新增云端XCTest来源绑定case，尚未在本机无完整Xcode环境宣称XCTest通过。CI已增加StagingChecks，并准备0.3.5/build9；云构建及产物另记。

新增默认关闭的诊断停止开关，可让新导出在1资源完成后确定停止，用于用户覆盖安装后强制退出App/重启并继续；继续按钮不受该测试开关影响。runbook IOS_STAGING_RECOVERY_RUNBOOK.md列出分步证据与预期20项/30资源、复用1/重新读取29。**新手机二进制、资源边界停止/重启/继续以及实际PhotoKit变化/权限/空间故障均NOT_RUN**。诊断停止不冒充写入中杀进程或系统故障；完整产品和Photos事务恢复仍未完成。


### 0.3.5 双端云产物交付；暂存恢复等待手机安装

功能实现本地提交 **820dbe9**。远端源码 **37798f7ae000fadffab9949ad684b0ee5691ef18** 的 [Actions #18](https://github.com/loterr298/PhotoBridge/actions/runs/39217101320) **SUCCESS**；实际 **5 XCTest /47 CoreChecks /23 StagingChecks /41 Python**，iOS arm64及Mac x86_64编译通过；实际Xcode16.4/iOS18.5 SDK，源码中的OriginalExportService确实加入生成工程并参与编译。日志cloud-18-*.log与cloud-build-18-success.png。

[云产物](https://github.com/loterr298/PhotoBridge/actions/runs/39217101320/artifacts/12170171052) 已下载，整体SHA-256 **86b28e7eff689e26f9502235d9035cdd3ccb94044aaa3d93e93a558dd1d3d112**与Actions摘要一致；CRC、内部SHA256SUMS、IPA编译版本0.3.5/build9/源码commit/稳定bundleID/可执行权限/arm64、Mac版本/x86_64/可执行权限、全部包内脚本与已测源码一致及没有bytecode缓存均核对。cloud-build-18.json。

- `build/PhotoBridge-0.3.5-M3/PhotoBridgeOrderProbe-0.3.5-unsigned.ipa`，SHA-256 **5c1cde3f330121139b3a4f0086e29e08d9c9a1190c1e59af86cd022a845476bf**；需用户沿用个人签名覆盖安装，新手机运行时与暂存恢复仍NOT_RUN。
- `build/PhotoBridge-0.3.5-M3/PhotoBridgeMac-Intel.zip`，SHA-256 **807a30a0907ccd279e3532892ee5f40c4888fb1376293d9345dd579e512884dd**。
- `build/PhotoBridge-0.3.5-M3-Apps.zip`，SHA-256 **6585ac4d7ec2baf8d037425bf4df196fffb05e68feea80bc233f15efa1e7201b**，含保护/暂存恢复/USB继续说明与内部校验，不含私人媒体或清单。

沿用用户已授权的电脑自动更新：先保留旧0.3.4目录及ZIP备份，核对新云包，停止准确路径的旧诊断GUI进程，再装入 `/Applications/PhotoBridgeMac.app` 0.3.5；严格签名、架构、所有随附脚本核对并实际启动，确认进程来自该安装路径。m3-staging-mac-install.json。未以进程存活当作最终UI验收，也没有执行Photos写入。

本轮实际USB-only检测错误-3（无设备），没有启动任何手机暂存/恢复；m3-staging-device-availability.json。已提供具体IPA并请求覆盖安装、dw诊断停在1资源，先保留旧现场供Mac取基准，再做重启/继续与独立USB全资源校验。**该功能真机结果仍NOT_RUN**。用户配合安装前继续准备独立审计，不把云检查写成设备成功。


### 0.3.5 资源边界停止、重启后继续：dw 真机样本已通过

用户先回复“已停止”，首次USB只有3个旧版已完成会话，无新plan；安装服务只读确认实际安装为0.3.5/build9。未把该回复直接当作新流程通过。用户随后回复“点了”，实际发现目标运行commit37798f7的STOPPED/1资源会话，无album-order.json；先通过USB保存其全部6个文件及检查点、实际SHA-256和size/mtime/birthtime/nlink基准。另两次完整新导出仍保留，未删除。

请求用户完整关闭App再打开、选择该来源并继续，用户回复“以重启继续”（原话）。实际新会话STAGED，resourcesCompleted=30、reusedVerifiedResources=1、photoKitResourcesRead=29、partialResourceBytesReused=0、runtimeBuild=37798f7ae000fadffab9949ad684b0ee5691ef18。旧计划和新计划的来源快照/完整资产目录相同，新日志绑定来源session及精确旧plan SHA-256；最终manifest再与新plan的session、完整来源快照、成员与资源目录相互绑定。

真实USB下载新会话 **20项/30资源/77,450,231 bytes COMMITTED**，系统shasum **30/30**。与既有dw完整备份的相簿身份、成员顺序及全部资源类型、原名、UTI、大小、hash、像素/媒体字段逐项一致，严格资源字节相同，无时间附件例外。旧停止会话6个文件在继续前后 bytes/size/mtime/birthtime/nlink 均未变。审计脚本没有手机写操作；新原图读取和新暂存复制是手机App自身工作。原相簿/原照片及Photos均未写入。公开脱敏证据 m3-ios-staging-{baseline-captured,device-recovery-verified}.json；真实标识/文件/计划仅在private-diagnostics/ios-staging-stop-recovery-dw-01。

该样本的“资源边界停止→用户确认App重启→新会话继续”通过。复用数来自目标App运行日志，Mac独立证明输出字节及绑定一致，不把字节相同本身当作PhotoKit调用次数的外部跟踪。旧目录属性NOT_AUDITED，只主张已列出的文件属性。写入中强杀、系统终止、iCloud/权限/空间异常及Photos事务恢复仍NOT_RUN，未把诊断开关冒充这些故障。

新增可复现只读 tests/device_staging_recovery.py（在云18后添加，不属于已交付二进制变化）。其独立复审发现原审计未把final manifest与plan完整绑定的假通过边界；新增RED后补完整快照/session/资产资源目录绑定，日期按既有交换精度转换。新增测试覆盖另一相簿名/标识、不同session、资产与UTI变化的拒绝。当前本地主机 **42 Python**通过，m3-staging-audit-{binding-red,tests}.log；云18的真实计数仍为41，不回填成42。产品代码/手机二进制未因该手工审计改动而替换。

下一项为Photos导入事务的不确定状态协调，以及单资源写入中终止与权限/空间/iCloud等故障测试。更多格式、规模性能、最终可操作极简UI仍未完成。

真机验收后仅更新交付包说明和DEVICE_ACCEPTANCE.json，iOS/Mac二进制未变；旧6585ac4d…双端ZIP已保留为before-device-audit包。当前 `build/PhotoBridge-0.3.5-M3-Apps.zip` SHA-256 **9b53fc7109df10282b876797f59e673ef8b7a63c65c72e6b7c802608f02f6041**，CRC/内部校验及不含私人文件再次通过，m3-device-verified-delivery.json。

### Photos 导入事务恢复实现（0.3.6/build10，真机 NOT_RUN）

新增 RestoreRecovery 原生不可变计划与意图/placeholder/回读版本记录，绑定收件/尝试 UUID、精确清单和请求 SHA-256、源相簿/成员、新名称及原授权。事务前持久化意图，PhotoKit changes block 内同步独占保存 placeholder；持久化失败不能撤销已排队 Photos 请求，缺失标识或对象不可见一律停止，不因“找不到”而自动重建。合作写入者使用原生非阻塞 flock。旧版失败会话没有新计划，继续拒绝。

RestoreService 从视图拆出，真实流程支持重新预检已记录新协议会话。新运行先核对精确相簿名称/成员前缀/顺序、明确 ID 的实际可见性和已回读修改版本；全部已有资产完整回读到新 verification-attempts/UUID 后，才创建剩余项。每个副本仍 shouldMoveFile=false，源日期原值，原资源不主动改写。每次运行独立 run 日志，旧最新进度先保存快照；不可变映射、旧回读/part/日志保留。元数据提交使用唯一 .pending-UUID、同步后 renamex_np(RENAME_EXCL)，不覆盖既有记录；断电耐久性不作保证。

新增默认关闭“首个 Photos 事务完成后停止”诊断：首个副本提交且 ID 保存后、资源回读前停止。下次必须用户重新预检并继续，没有后台重放。每次报告记录本次新建/复用、实际回读目录，仍要求人工独立检查 Photos 顺序及 Live 播放。含 type7 时维持默认关闭、仅既有明确授权的新副本 adjustmentTimestamp 例外；恢复时不得改变原授权。

先记录核心缺失类型编译 RED、重复 ID 回归 RED；独立 USB 审计新增回读目录测试先 RED（旧路径硬编码及未拒绝越界），修复后使用仅 legacy verification 或 verification-attempts/UUID 的安全路径。当前实际本机 44 Python /47 CoreChecks /23 StagingChecks 通过，Intel x86_64 App 编译及严格签名检查成功；iOS 源码 parse 通过。本机 XCTest 因 no such module XCTest 未执行成功，待云端完整 Xcode 实际运行。恢复检查最终计数与云构建下文另记，绝不将模拟测试填为真机通过。

独立只读复审没有确定的 Critical/Important 缺陷；据建议补新 Store 重开、请求 hash 变化、丢失意图/placeholder、保留 pending、独占提交不覆盖及硬链接拒绝。真实 Photos 提交失败/placeholder 持久化失败、资源损坏阻止后续创建、提交中强杀/系统终止、权限/空间/iCloud 故障尚未验证。原生检查只能证明记录协议；不能代替 PhotoKit 集成与设备验收。

运行说明 PHOTOS_TRANSACTION_RECOVERY_RUNBOOK.md。下一步 Actions 编译0.3.6并核对产物，用户覆盖安装后用全新3-Live收件做提交后停止/重启/继续，Mac独立核对6资源、首个 ID 不变且仅新建剩余2项。当前新手机二进制运行、事务恢复及人工观察全为 NOT_RUN。更多格式、规模与最终可操作极简双端 UI 仍未完成。

### 0.3.6 云产物已核对、电脑已更新；Photos 恢复真机待测

功能本地提交5cdf28a。远端源码3ca3a8c8978d8c4e79edf330ce1cd1f6529996b4 的 Actions #19（https://github.com/loterr298/PhotoBridge/actions/runs/39247734331）SUCCESS。真实6 XCTest /47 CoreChecks /23 StagingChecks /33 RecoveryChecks /44 Python；iOS arm64、Mac x86_64 编译通过。实际选中Xcode16.4/iOS18.5 SDK，未因runner另装Xcode26声称使用新版SDK。cloud-19-*.log、cloud-build-19-success.png及cloud-build-19.json保存日志与证据。

下载artifact12183683845，整体SHA-256 71d31238858fa8038f8a389dfdff034aed3409e3d74b2543de3c7145777a1429，与Actions摘要一致。CRC、内部SHA256SUMS、iOS编译Info版本0.3.6/build10/commit/稳定bundleID/文件共享/隐私键/执行权限/arm64，Mac版本/x86_64/执行权限/严格签名及全部随附脚本与已测源码一致均核对。RestoreService.swift实际加入工程并编译。

手机IPA：build/PhotoBridge-0.3.6-M3/PhotoBridgeOrderProbe-0.3.6-unsigned.ipa，SHA-256 233251107519eacb7e3fa1aae74d306424a3ad6c8a8f99799e50866d017eada8；需用户沿用原个人签名覆盖安装，不卸载。Mac ZIP：同目录PhotoBridgeMac-Intel.zip，SHA-256 ccc4731a999d7ba0cda3ebf53a524b641881d4ee7cddecc5655a5fdc15958ebf。双端包及安装/验收说明：build/PhotoBridge-0.3.6-M3-Apps.zip；精确hash记m3-photos-recovery-delivery.json。

按已授权的电脑自动更新先保存旧0.3.5目录及ZIP，停止准确路径旧进程，安装逐文件相同的已验云包，严格签名/Intel架构再次通过；已启动并观察到准确安装路径进程，m3-photos-recovery-mac-install.json。进程存活不代表最终GUI视觉验收，仍为NOT_RUN。

本轮USB-only实际检测错误-3，无设备；没有向手机上传新收件，没有Photos写入。新手机运行时、Photos提交后停止/重启继续、人工顺序及播放均NOT_RUN。旧0.3.5暂存恢复证据仍成立，不能替代0.3.6照片库事务恢复验收。待覆盖安装并重新连接后，先准备全新3-Live收件，然后受控停止并保存基准，不能直接跳到继续或宣称通过。

双端交付 ZIP 最初使用 ditto 时中文说明文件名在标准 ZIP 读取中编码不一致，内部校验明确失败，未将失败包当作通过。保留该包以供排查，改用 ASCII 说明文件名和标准 ZIP（不写 AppleDouble），二进制输入不变。最终 CRC/逐文件内部 SHA-256 校验通过；build/PhotoBridge-0.3.6-M3-Apps.zip SHA-256 **9c7045a4d6854a4d73bccbd9040c38b71e9d32dfb50e9482d0dc1820b83a25b0**。具体说明、真实失败与云检查均已包含，私人照片/标识未包含。

### 0.3.6 首个 Photos 事务提交后停止、用户重启再继续：Live 样本通过独立审计

用户覆盖安装并连接后，USB-only 安装服务只读确认0.3.6/build10。先向全新收件会话上传原3-Live已完成备份，6资源/19,968,426 bytes再次实际USB回读及系统shasum 6/6通过，未写照片库；m3-photos-recovery-new-inbox-verified.json。随后按步骤由用户在手机开启首个Photos提交后停止诊断并启动。

用户回复“已停止”，手机实际进度 INCOMPLETE、diagnosticStopWindow=AFTER_FIRST_PHOTOS_COMMIT_BEFORE_RESOURCE_VERIFICATION、createdAssets=1/newAssetsCreatedThisRun=1/resourcesVerifiedAssets=0，运行commit3ca3a8c...、0.3.6。Mac保存18文件完整bytes与size/mtime/birthtime/nlink，连续两次只读snapshot稳定；独立核对精确manifest/request/plan hash、尝试与源身份、相簿/首个placeholder事件及严格授权，未凭用户回复直接推断通过。m3-photos-recovery-first-commit-captured.json；真实IDs和媒体仅本地private-diagnostics/photos-transaction-recovery-live-036。

要求用户完全关闭App重开、同一会话重新预检继续，用户回复“以重启并继续”（原话）。手机真实完成报告严格 PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED、总3/已回读3、本次新建2/复用1，运行commit同云19。新独立只读审计将**实际下载并验证资源的那一份最终报告**绑定到停止现场的同一相簿、标题、首个副本ID、来源/尝试及原授权；防止先检查一份报告、后下载另一份的假通过。全部6资源/19,968,426 bytes实际USB回读并系统shasum 6/6，与来源全部严格字节一致；3成员映射/nil顺序一致。旧18文件中仅最新进度镜像允许更新，其余17个 bytes/size/mtime/birthtime/nlink完全不变；旧目录属性NOT_AUDITED。m3-photos-transaction-device-recovery-verified.json。计数为App运行报告，不冒充外部跟踪PhotoKit API调用；首个身份、旧文件与完整输出字节独立核对。

新增 tests/device_photos_recovery.py 与7项回归（云19后新增，不改变已交付二进制）。审查先发现4项Important证据假通过边界：报告切换、空/不完整基准导致空检查通过、无重启确认也标重启通过、最终标题/非首项源ID身份约束不足。先记录RED，再修复；流式校验保存现场的完整文件keyset/hash/大小及属性记录，强制用户重启确认，绑定实际审计报告，拒绝源/相簿身份混入。独立复核无剩余Critical/Important。当前本地**51 Python**通过；云19真实计数仍为44，不回填。m3-photos-recovery-device-audit-{red,review-red,green,full-tests}.log。

该样本“提交后/回读前停止→用户确认重启→同一会话继续”通过。**不是Photos提交中强杀、系统终止、磁盘满、权限撤销或iCloud故障通过**；这些仍NOT_RUN。新恢复相簿的系统照片人工顺序/逐张Live播放已请求用户确认，当前尚未回填。此项不等于完整产品/全格式/万张性能/最终UI验收。

用户随后确认“顺序一致且都能播放”（原话）：此新恢复相簿3张系统照片自定义顺序、每张Live播放均已由用户观察通过。m3-photos-transaction-device-recovery-verified.json已补本次确认。计划该受控验收步骤完成；没有把此前旧版本人工确认挪用到新样本。

仅更新交付说明并加入脱敏DEVICE_ACCEPTANCE.json，iPhone/Mac二进制与云19完全相同，无需重装。旧9c7045a4…包保留为before-device-audit，当前双端ZIP精确hash见m3-photos-recovery-device-verified-delivery.json，CRC/内部SHA及两二进制hash再次通过。源代码/证据真实提交，新的7项审计测试属于云19之后本地检查，当前51 Python通过；云19仍44。

下一步待验证：Photos提交中/资源写入中终止、权限/空间/iCloud故障、PNG/RAW及更多编辑资源、规模性能；Mac当前GUI仍是诊断入口，真实传输由随附CLI完成，最终极简可操作双端UI仍未实现。本阶段通过仅覆盖该3-Live样本受控提交边界恢复，不宣称全产品完成。

### 恢复权限和空间前置保护（0.3.7/build11，设备待测）

新增 OperationPreconditions：full/limited/denied/restricted/notDetermined/unknown明确区分，仅full接受；恢复写预算为剩余新Photos副本+本轮所有未完成回读+128MiB余量，未知/负容量、大小/计数异常及溢出拒绝。恢复前、创建相簿/资产前及每份回读资源前重新检查权限和真实容量（清除URL缓存）。容量未预留，不保证系统开销/其他写入后仍够；失败保留旧数据和部分文件。导出仅共享权限检查，因资源长度未知，不宣称导出完整空间估算。

先缺失类型RED，首批17新检查通过。独立审查发现当前资产全量预算在每份资源前重复计算，会把已经占用的资源再次算入，同时遗漏后续资产预算；补RED后改成全局预算扣除实际已inspect/提交的当前资源bytes，并保留未来创建和回读。增加精确边界、外部空间下降、无有效当前资产等回归。最终57 RecoveryChecks（含24新增）通过；47 CoreChecks/23 StagingChecks/51 Python及Intel构建另按实际日志记录。iOS本机仅parse，完整SDK/XCTest待云端，不把模拟当真机故障通过。

新增“仅预检：模拟零可用空间”，只替换本次预检输入，保存实际容量和模拟值，ready=false，不创建填充文件或Photos请求、不占用恢复声明；下一次须正常预检。预检失败/成功均留独立UUID报告；修复已有恢复会话却提示“尚未导入”的文案，明确已有副本数量。容量诊断默认存在ApplicationSupport私有目录，手机显著展示容量/估算/模拟及报告范围，用户每次点击“允许Mac读取这份诊断报告”才复制到共享Documents。共享恢复日志不保存实际容量，仅保留源清单计算的预算和错误代码。独立复审无剩余Critical/Important；服务层写报告/共享失败注入尚未测。

新增PrivacyInfo.xcprivacy公开所用API用途及工程资源/CI包内检查，不宣称完整商店审查完成。操作及验收边界见RESTORE_PRECONDITIONS_RUNBOOK.md；新3-Live收件已完成三项精简真机预检：模拟零空间、撤销权限、恢复全部权限正常预检。三份报告均通过 Mac 独立审计，session 前缀 FB8C64EE、runtime 0.3.7/build11 与源清单绑定，三项均确认未发起 Photos 写入；公开脱敏证据见 m3-preconditions-device-verified.json。真实磁盘耗尽/事务中撤权/提交中强杀仍NOT_RUN。

实际本机最终57 RecoveryChecks /47 CoreChecks /23 StagingChecks /57 Python通过，Intel x86_64 release编译、严格签名检查成功（0.3.7/build11）；新增6项前置报告审计测试并修复共享报告路径读取错误，日志见 m3-preconditions-{green,core,staging,python,mac-build}.log 与 m3-preconditions-device-verified.json。iOS完整编译/7 XCTest仍待云端；已准备0.3.7/build11及PrivacyInfo包内断言。


本轮根据用户要求压缩真机配合：只保留新版安装/连接、零空间模拟预检、撤销权限预检、恢复全部权限正常预检三步；照片库导入/相簿排序不重复执行。独立设备预检审计脚本与6项回归通过；夹具首轮失败日志保留，修复共享 `RestoreChecks` 根目录读取路径后全套 Python 57 项通过。三份真实报告均为同一 session，未创建相簿。

随后修正恢复页的可见状态：在收件 Picker 下直接显示当前选中 session 前缀，避免随机“新相簿名”遮蔽实际收件身份。提交 `70daeb9` 已同步 GitHub；Swift 语法解析通过。本机没有完整 Xcode/XcodeGen，iOS 类型编译交由 Actions，阻塞日志保留在 `m3-restore-session-label-{xcodegen,ios-build}.log`。

UI 修正已由 GitHub Actions #21 实编译通过：run `39805966543`，main 提交 `0380b54`，job `diagnostics` 成功，artifact `12437198019`，外层 digest `sha256:50de082fe7a1fa66109c1fabca8139dacbb04fb1c1fabe8624dbc9f523d7a041`。本次没有新增 Photos 或 USB 真机操作；Actions 页面保留 Node.js 20 弃用提示和 macOS arm64 runner 容量提示，均未导致失败。

### 0.3.8/build12 云编译交付

将已验证的恢复收件 session 可见标识修复提升为 0.3.8/build12：iOS 工程版本、Mac Info.plist、CI 编译后版本断言与未签名 IPA 文件名已同步更新。该版本没有新增照片库或 USB 行为，也不要求重复真机预检。本机可执行检查：57 Python、57 RecoveryChecks、15 CoreChecks、23 StagingChecks，Intel x86_64 Mac release 构建通过。

GitHub Actions #24 已成功完成：run `39810559102`，main 提交 `cc1cf66ed62952680fdbaaf8bda2ae9036c02f9`，diagnostics job 成功，耗时 1m19s；artifact `12440086673`，大小 1.15 MB，外层 digest `sha256:0492a3eb8fbd24061cec69671eda7a127de46092d080bb8c3ee220a3aa916ce1`。该云包包含 0.3.8/build12 的未签名 iOS IPA 与 Intel macOS ZIP，并执行了完整 Swift/Python 检查、XcodeGen 生成、iOS unsigned build、版本/隐私键断言和 x86_64 Mac 构建。Actions 仍显示 Node.js 20 弃用提示及 macOS arm64 runner 容量提示，但本次没有失败。未新增 Photos 或 USB 真机操作；现有真机预检证据继续有效。

### M4 极简可操作界面第一轮

Mac SwiftUI 已从只读说明页升级为可操作的传输工作台：可在 App 内检测 USB-only House Arrest/AFC、读取 iPhone 原始资源暂存会话、选择 Mac 目录下载并运行逐资源大小/SHA-256/5 秒文件时间校验，也可选择已提交备份目录上传到新的 iPhone 收件会话。ImageCaptureCore/PTP 相机目录仍单独显示，明确不冒充 PhotoKit 相簿顺序。失败输出保留在界面中，不显示伪完成状态；照片库写入仍需 iPhone 恢复页明确启动。

iPhone 首页补充真实状态边界、原图只读与 SHA-256 提示，并提供“读取照片相簿”和进入恢复页的主要入口；不在手机端虚构 USB 已连接。现有相簿顺序诊断、原始资源导出、预检和恢复逻辑保持不变。SwiftUI 源码解析、57 Python、57 RecoveryChecks、15 CoreChecks、23 StagingChecks 与 Intel x86_64 release 构建通过；iOS 完整编译仍交由下一次 Actions。M4 尚未完成：批量选择/速度图表、macOS 13/14 实机兼容、所有格式压力测试和最终视觉验收。

M4 云编译验证：iPhone 首页提交 `f4640d7f48c9e77c9eb86183f766acb88cbdb334` 的 Actions #25 成功，run `39819409819`，耗时 1m16s，artifact `12443921629`，digest `sha256:aafb694d01c7983301fa28b4efc0497659be246100ba4e716ebbaa2f42e59e0c`。Mac 传输工作台提交 `b6fae79db6ec4d508296f42ba39c96c477def0d4` 的 Actions #26 成功，run `39819964248`，耗时 1m19s，artifact `12444076831`，digest `sha256:a97ffbe6f037a12bdc76505a235ae8932b69478ab5285edbca49c89be57659a9`。两次均执行 iOS unsigned build、Swift/Python 检查、Mac x86_64 build 和包内断言；警告仍只有 Actions 的 Node.js 20 弃用和 macOS arm64 runner 容量提示。

### M4.1 成品审计与真实传输进度补齐（当前工作区）

重新按 `AGENTS.md`、`PROJECT_PROMPT.md`、`docs/UI_DESIGN.md` 和验收矩阵审计后，确认当前产品仍有明确边界：PhotoKit 顺序诊断、原始资源清单/SHA-256、AFC 双向样本、5 秒文件系统时间、受控续传和 3-Live Photo 恢复样本已有真实证据；但双端还不是完整的一体化传输产品。iPhone“传输”页仍是合成 USB 探针，Mac 端此前只能等待一次性脚本结束，缺少实时字节/速度/剩余时间；批量相簿选择、传输历史、暂停/取消、PNG/RAW/大规模压力、macOS 13/14 真机和最终视觉验收仍未完成。上述缺口不能用 M4 云构建成功替代。

本轮先修复最直接的成品缺口，同时保持数据路径不变：新增 `scripts/transfer_progress.py` 的真实进度计算；`album_export.py` 和 `album_restore.py` 在原子进度日志中记录总资源/总字节、当前资源、已校验字节、真实吞吐和可计算时的 ETA；Mac SwiftUI 在下载或上传运行期间轮询这些日志，显示真实进度、速度、当前资源和剩余时间，无法测量时显示“测量中/待测量”，不填随机值。未新增删除、覆盖、媒体转码或 EXIF/GPS/MakerNotes 写入路径。

验证：本机 Python **59 项**通过；`CoreChecks` 11、`StagingChecks` 23、`RecoveryChecks` 57 通过；Intel `PhotoBridgeMac` x86_64 release 构建、严格签名和打包通过。新 Mac 包尚未经过 GitHub Actions 云构建和用户真机视觉验收，不能标记 M4 完成。下一步仍是将该进度状态接入 iPhone 的真实导出页，并补传输取消/安全停止、批量选择和历史记录，再做新的云包与最小真机复验。

### M4.2 iPhone 真实传输任务中心（当前工作区）

将 iPhone 底部“传输”页从合成 USB 探针改为真实本机暂存任务中心：读取 `Documents/Exports/<session>` 的 `export-progress.json` 和最终 `album-order.json`，展示已完成资源、总资源、字节进度、错误和会话前缀；从任务中心选择真实 PhotoKit 相簿进入原始资源导出。原 USB/AFC 合成文件探针保留为单独“USB / AFC 诊断”入口，并明确不代表原图传输。

新增 `TransferSessionSummary`，同时解析 iPhone 的 `resourcesCompleted/bytesCompleted` 和 Mac 的 `resourcesVerified/bytesVerified` 日志；缺少总量时显示待定，不计算虚假百分比。`CoreChecks` 新增两项解析检查，先记录缺失类型的编译 RED，补实现后通过。iOS 源码 parse、Python 59 项和 CoreChecks 均已执行；完整 iOS Xcode 编译、真机安装与视觉验收待下一次云构建，不能标记 M4 完成。

相簿诊断页也补上真实成员网格和点按详情：缩略图来自对应 `PHAsset`，每格保留 PhotoKit 原始返回位置，详情继续显示 `localIdentifier`、创建日期和资源角色；人工顺序核对提示仍明确为待独立观察，不把视觉改动当作验收通过。iOS 源码 parse 已通过，完整 Xcode 编译和最终视觉验收仍待云端与真机。

Mac 传输工作台新增“从旧备份续传”：选择已有未完成目录后，`album_resume.py` 只读验证旧文件并写入新的目标目录，旧目录不覆盖；新目录沿用同一份真实进度日志，USB 断线后的续传能力不再只存在命令行入口。Intel release 构建已重新通过；物理拔线续传仍需真机重新执行，不能用 GUI 编译替代。

M4.3 增加协作式安全停止：Mac 工作台向下载、续传和上传脚本传入一次性取消标记；脚本只在资源边界检查标记，失败现场写为 `STOPPED`，不发布完成清单、不强杀进程、不覆盖旧目录。新增 2 项取消标记检查，当前本机 Python **61 项**通过，Intel x86_64 构建通过。正在写入的单个底层 AFC/PhotoKit 操作仍会先返回或失败后才响应停止；这不是强杀故障验收，物理拔线和系统终止仍需真机测试。

### M4.4 批量相簿导出队列（当前工作区）

iPhone 传输中心新增“批量选择多个相簿”。队列使用 `BatchQueuePlan` 保持用户选择的相簿标识顺序并拒绝空值/重复项，然后逐个调用现有 `OriginalExportService`；每个相簿仍独立生成 PhotoKit 顺序清单、原始资源 SHA-256 和检查点。某个相簿失败或安全停止时队列停止，已完成相簿不回滚，也不会把未处理相簿显示为完成。

新增 3 项 CoreChecks（队列顺序、重复、空队列），本机 Python **61 项**、CoreChecks（含批量队列）和 Intel x86_64 构建通过；iOS 只完成源码 parse，完整 Xcode 编译、批量真机运行和大型队列性能仍待云构建/设备验证。

批量队列页进一步绑定现有 `OriginalExportService` 的真实运行状态：运行期间同步显示当前相簿名、PhotoKit 已读取资源数、字节数和服务原始消息；队列级完成数与资源级进度分开显示。没有新增模拟进度，iOS 完整编译和设备运行仍待云端验证。

Mac 恢复工作台现已同时支持“继续未完成上传”：自动选择备份目录中最近的 `restore-uploads/*.json`，调用已有 `upload_resume.py`，继续前重新验证源清单、已完成文件和部分前缀；上传续传也接受同一安全停止标记并保持 `STOPPED` 日志。Python 61 项和 Intel x86_64 构建通过，物理 USB 上传续传仍以设备证据为准。

任务历史现在从真实 `source-order.json`/`album-order.json` 读取相簿名，批量或单相簿暂存记录不再只显示 UUID 前缀。新增下载取消回归：取消标记在创建本地备份前即停止，绝不产生伪造目录；本机 Python 检查计数更新为 **62 项**。完整 iOS 编译仍待云端。

Mac 工作台记住最近 8 个由用户选择的备份目录（仅本机 UserDefaults 路径），重启后展示目录名，方便继续下载/续传；不保存照片内容、清单或设备标识。Intel 构建重新通过，属于本地用户体验改进，未改变传输安全边界。

iPhone 单相簿导出页现在在 PhotoKit 捕获当前资源目录后计算真实总资源数，显示资源级进度条；相簿为空、权限不足或目录不稳定时仍停止并显示错误，不显示估算百分比。iOS 源码 parse 通过，完整 Xcode/真机验证仍待云端。

恢复页同步显示真实照片事务进度（已提交/总资产），总数来自已校验收件清单；权限、空间或 PhotoKit 事务失败时保持失败现场，不将进度条当作恢复成功。iOS 源码 parse 通过，真实设备验证仍按既有样本边界记录。

补充格式回归覆盖：单个资产可包含 PNG、RAW/DNG 与 MOV 配对资源，清单校验保持同一 `resourceGroupId`、独立资源索引和安全扩展名；新增 Python 检查后本机总计 **63 项**通过。README 增加当前用户端完整操作路径和停止/续传边界。

### M4.5 用户端页面视觉收口（当前工作区）

iPhone 首页状态文案明确为“未连接 · USB 由 Mac 检测”，设备卡增加轻阴影和更清晰的主次操作层级；相簿成员网格收紧为照片式间距并保留动态缩略图。Mac 工作台新增真实下载完成后的备份内容预览表（位置、原始文件名、资源数、大小），只读取已校验的 `album-order.json`，不展示假缩略图或假完成状态。Intel 构建、iOS 源码 parse、Python **63 项**通过；最终 iOS 视觉验收仍需云包和真机。

恢复页新增两个独立验收卡：`文件完整性` 和 `自建相簿顺序`。前者只在真实收件预检或照片库资源回读达到对应状态时改变，后者明确区分 PhotoKit 回读顺序与系统照片人工观察；不再用单一完成文案覆盖未执行的人工核对。

设置页完成产品化：展示真实版本/构建号、原图只读、SHA-256、元数据保护、5 秒逻辑时间、权限和签名边界，并提供 USB/AFC 诊断入口。固定安全策略使用说明卡而非无效开关；iOS 源码 parse 和 Python 63 项通过。

### 最终交付闸门（2026-10-23）

| 项目 | 当前状态 | 证据/剩余动作 |
| --- | --- | --- |
| 本地 iOS 用户界面 | **代码完成，待云编译** | 相册、传输、批量导出、恢复双状态、设置页均为真实 SwiftUI；本机 `swiftc -parse apps/iOS/*.swift` 通过。 |
| 本地 Mac 用户界面 | **已构建** | 真实 USB/AFC、进度/速度/ETA、安全停止、下载/上传续传、备份内容预览；Intel x86_64 包已生成。 |
| 自动化检查 | **通过** | Python 63 项；CoreChecks、StagingChecks、RecoveryChecks 持续通过。 |
| GitHub Actions 当前源码 | **阻塞** | 本机没有 Xcode，且 Git HTTPS/CLI 没有写入凭据；当前本地提交 `68468e2` 尚未进入 `main`，不能把旧的 0.3.8 云包当作本轮 UI 包。 |
| iOS 签名 IPA | **待云包** | 云端 unsigned IPA 仍需用户 Apple ID 个人签名；仓库不保存证书或密码。 |
| 真机最终视觉验收 | **待安装当前云包** | 需要安装包含本轮 UI 的新包后检查窄屏、动态字体、VoiceOver、暗色模式和真实任务状态。 |
| 广泛设备验收 | **未完成** | PNG/RAW/DNG 真实资源、万张压力、macOS 13/14、Photos 提交中强杀、iCloud/磁盘故障仍需对应设备和样本。 |

因此当前“完整成品”还差一个外部交付闭环：推送 `68468e2`（及其父提交）到 GitHub `main` → Actions 云编译 → 下载新 IPA/Mac 包 → 个人签名安装 → 最小真机视觉复验。代码端不再需要用户逐步操作才能继续开发；这些剩余项分别受 GitHub 写权限、Apple 签名和真实设备状态限制。

已手动触发远端 Actions #28：run `39952582245`，状态 **Success**，耗时 1 分 16 秒，远端提交为 `4b22c46`。该 run 的 iOS unsigned build、Swift/Python 检查和 Intel Mac 构建均完成；GitHub 仅报告 Node.js 20 弃用和 macOS arm64 runner 容量提示。由于本机最新提交 `252cdb8` 尚未推送，#28 只能作为远端基线构建证据，不能作为本轮最新 UI 交付包。

### M4.7 云编译交付（2026-10-24）

已将 iOS 16 兼容修复提交到远程 `main`（GitHub commit `6f5f4778985058089d8457101671ffa9d059bbeb`）。GitHub Actions run **#32**（`39998331913`）完成且成功，包含 Xcode iOS 真机目标编译、Intel x86_64 Mac 构建及自动化检查。云端产物归档摘要：`sha256:5a1a97f71b7b938962dd3acb77696c422549b670935cdcd4b2b0f7373b4196ff`。

云端归档内的可交付文件：

- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`6b967dac62ce7d60ecfe8cbae070fa6f910e2612b0c1a69e905f367595a3977f`
- `PhotoBridgeMac-Intel.zip`：`99266db8fe9c0def3dfb2992b9ba8cd3a930e68ef5644c284c10cffda09dcf12`
- `PhotoBridgeOrderProbe-unsigned.app.zip`：`e859d8268523da8b488cc525991a25e2eb3c1633fe8211f277329cd2186c97e1`

IPA 仍是 unsigned，需要用户自己的 Apple ID 签名；Mac 包为 Intel x86_64。云端检查通过不等于已完成真机视觉验收，真机仍需安装本包后按文档验收。

### M4.8 交付收口修复（2026-10-24）

恢复页验收卡已改为依据真实恢复完成状态显示“已完成”和“顺序已恢复”，不再依赖已经移除的旧提示文本。iOS 源 Info.plist 统一为用户看到的 `PhotoBridge`、0.3.8/build12；CI 增加编译后显示名称断言。源码解析、CoreChecks 11、StagingChecks 23、RecoveryChecks 57、Python 63 和 Intel x86_64 构建均通过。

远程 Actions #36（run `40001623654`）成功，提交 `322e61a900b251aed9bee40d82c0541d4cd6f88f`。最新云包归档 digest：`sha256:c87203594569ca378afb9b1ed351885922a4e656b826c2eddfa3c1b7096fc4a6`。

- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`51a8204d04318823cc5f2f85a7e76b8c0a8bb9122c76852287ad74360c051082`
- `PhotoBridgeMac-Intel.zip`：`4467e6074384333d6ad3c80dfb0290dabd3c67de4c869f73f80252a1ed6367d8`

### M4.9 双端应用图标（2026-10-24）

新增原创浅蓝相册图标：单一相册轮廓、单个照片窗口、低对比度留白。iOS 使用 `Assets.xcassets/AppIcon.appiconset`，Mac 使用 `PhotoBridge.icns` 并由打包脚本复制到 `.app/Contents/Resources`。云端 Actions #46（run `40005853139`）成功，已检查 IPA 内含 `Assets.car` 与 AppIcon 文件，Mac ZIP 内含 `Contents/Resources/PhotoBridge.icns`。

- 云端归档 digest：`sha256:53fbad07af026f997c92954f732830c266207d601ebb0da247df3f123bc2a47c`
- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`df3d21c0156edf7d9a5cab97c74caf4b838e105f265afd90f7e70b985a8a44e1`
- `PhotoBridgeMac-Intel.zip`：`26e2e6764b758ef354da7d611e4bf406e028777643bd1b9244c91148ea9b11c1`

### M4.10 核心流程收口与大相册稳定性（2026-10-24）

根据真机反馈收口用户端：iPhone 主界面只保留“保存到 Mac”和“恢复到 iPhone”；Mac 主界面只保留“iPhone → Mac”和“Mac → iPhone”，隐藏相机目录、诊断输出、测试暂停和内部清单字段。恢复仍按原相册顺序写入新相册。

导出末尾的内存峰值已修复：`OriginalExportService` 不再把整个相簿的 `ExportAsset` 数组留在内存后一次性编码，而是在每个资源组完成时增量写入 `album-order.json.part`，最后只做原子收尾。保存页明确显示照片暂存在 iPhone 的 PhotoBridge 文件区，Mac 通过“查找手机保存”选择目标文件夹。

本机验证：iOS/macOS Swift 语法解析通过；Intel x86_64 Mac 构建通过；Python 63 项通过。iOS 完整 Xcode 编译和大相册真机复测待下一次云包，不能提前标记设备通过。

### M4.11 iPhone 照片信息编辑（2026-10-24）

iPhone 端新增独立“照片信息”标签，保留 PhotoBridge 原有备份、恢复和相簿顺序页面。新页面使用 PhotosPicker 读取最多 20 张照片，ImageIO 读取/写入相机与曝光元数据，支持 EV=0、日期、分辨率和 3:4 中心裁切；保存通过 PhotoKit 直接创建到 iPhone 照片相册，不覆盖原照片。新增 `NSPhotoLibraryAddUsageDescription`。

本机 `swiftc -parse apps/iOS/*.swift`、git diff 检查、CoreChecks、StagingChecks、RecoveryChecks 和 Python 63 项通过。当前机器无完整 Xcode/XCTest，云端 Xcode 编译、真实 iPhone 保存、HEIC/Live Photo、相机信息系统显示和大图压力测试待验证。

### M4.12 iPhone 照片信息编辑云编译交付（2026-10-24）

修复 XcodeGen 工程同步和 Xcode 16.4 编译错误后，GitHub Actions run **#91**（run `40078706187`，commit `9729c9e`）成功完成 iOS arm64 未签名 IPA、Intel x86_64 Mac 包、Swift/Python/CoreChecks/RecoveryChecks/StagingChecks。云端实际使用 Xcode 16.4、iPhoneOS SDK 18.5；CI 仍报告 GitHub Actions 的 Node.js 20 弃用提示和 runner 容量提示，但不影响构建结果。

交付产物哈希（Actions 归档 `sha256:2afdc8fe49a9733b9f1728bb845ac7e94b3c70a932ef342348983a74c747ba1c`）：

- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`a6ddc0390a6746e9c525ae28b65b0f039cea234eed721cb9b6478df4ffb91d94`
- `PhotoBridgeMac-Intel.zip`：`79c85ee149f3eb355188c6af04aeabd68dfb94ba66b8fad770baa68f4dfec8f9`
- `PhotoBridgeOrderProbe-unsigned.app.zip`：`20a6e285c191ae6196bfbbe9d57935084e91f116912870fbb485473fda69dd5e`

状态边界：云端编译和自动化检查已完成；IPA 仍需用户 Apple ID 个人签名后安装。照片信息页的真实保存、HEIC/Live Photo 的系统显示与大图压力仍需真机验证；保存操作只新增照片副本，不覆盖原照片。

### M4.13 备份到 Mac 用户页面收口（2026-10-24）

根据真机截图重做 `OriginalExportView`：页面只保留相册名称、照片数量、手机可用空间、原图下载选项、开始备份和真实备份进度。移除“继续上次备份”、未完成会话选择、内部诊断文字和面向开发者的技术说明；扫描阶段显示明确的“正在读取照片”进度提示，资源写入阶段显示实际已备份文件数。远程 Actions run **#94**（run `40090556003`，commit `1ead48b`）成功完成 iOS 与 Intel Mac 构建。

本轮产物哈希：

- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`b0267fda9d89049bddb459384563703e754051675cd5ad20d1783f093e1238c8`
- `PhotoBridgeMac-Intel.zip`：`c15e2e013d7cb341de230b5d9fa51a405e3c4072143f3c40a6a7acc87826fdf0`

本机 Swift 解析、Python 63 项和 git diff 检查通过。IPA 仍需 Apple ID 个人签名；真机安装后的窄屏视觉验收和万张相册长时间备份仍需实际设备确认。

### M4.14 备份页重新设计为单任务用户界面（2026-10-24）

移除上一版仍接近系统表单的排版，改为独立的极简单任务流程：相册封面与数量、一个大圆角“开始备份到 Mac”按钮、收起的高级选项，以及独立状态卡。扫描阶段立即显示“正在准备照片”和旋转进度；资源导出阶段显示真实百分比、已保存文件数和暂停入口；完成状态只说明下一步回到 Mac 选择保存文件夹。技术字段、续传会话和内部诊断不出现在普通用户页面。

GitHub Actions run **#96**（run `40101028874`，commit `4c03de7`）成功完成 iOS arm64 与 Intel x86_64 Mac 构建。云端日志确认 `OriginalExportView.swift` 已进入 SwiftCompile；仅有 Swift 并发提示和照片信息页的弃用 API 警告，没有编译错误。

本轮最终产物哈希：

- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`12d8f338b106b43be70c7d8d36f70801532329487093ecda6c3734d481bf7bda`
- `PhotoBridgeMac-Intel.zip`：`1b3fffe16fef421fbd1c90b2b08e866574967a6c062c5e69f7c21af1f6ba253c`

本机 Swift 解析、Python 63 项和 diff 检查通过。IPA 仍需 Apple ID 个人签名；真机视觉和万张长时间备份仍需安装后确认。

### M4.15 备份失败提示修复（2026-10-24）

修复普通用户无法判断失败原因的问题。原页面把 PhotoKit 权限不足、空间不足、资源变化和其他失败都显示成“备份没有完成”；现在会显示实际可操作原因。全部照片权限不足时提供“打开照片权限设置”按钮，并说明已完成文件和原照片都会保留。

GitHub Actions run **#97**（run `40101991025`，commit `ab23811`）成功完成 iOS 与 Intel Mac 构建。自动化测试 63 项通过，Swift 解析通过。

本轮产物哈希：

- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`610372d31b598ebd9846c93517b0d6db952c6eb1a9103201171169263ef5582c`
- `PhotoBridgeMac-Intel.zip`：`a98859ede4e2ed2288273a46e7747e672f72153948f4b35b9e9f820713443867`

### M4.16 移除 iPhone 虚假的“等待数据线”状态（2026-10-24）

iPhone 端此前把“照片已准备 · 等待数据线”写死在首页，实际没有读取 Mac USB 会话，因此即使数据线已连接也会显示等待。现在改为真实可确认的“照片权限已准备”，移除假的断线指示；连接状态和保存进度由 Mac 端真实传输工作台显示。GitHub Actions run **#98**（run `40102693780`，commit `077388e`）成功。

- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`0f3cf56c9c524003b7323dada4814403fa17c97d71ebe1cfdd3d83976b57dfd4`
- `PhotoBridgeMac-Intel.zip`：`989a1ee52e2f6d4a54638014d4888fd31f5e356d7905cd0b25dd18169c773210`

### M4.17 修复备份启动时临时清单文件不存在（2026-10-24）

真机截图中的 `NSCocoaErrorDomain / 4: album-order.json.part doesn't exist` 已定位：流式清单写入器使用 `FileHandle(forWritingTo:)` 打开尚未创建的临时文件，导致备份在第一步就失败。现在在打开句柄前原子创建 `album-order.json.part`，保留原有流式写入与最终原子提交策略。

GitHub Actions run **#99**（run `40103375439`，commit `a4a8489`）成功完成 iOS 与 Intel Mac 构建，63 项测试和 Swift 解析通过。

- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`2d021cc30a570d8f65c7188ff0605cd93e79d51ab23e75a386b4fb5e01c12a75`
- `PhotoBridgeMac-Intel.zip`：`43681e0f95da5a14eace7ed28f045708f5252497cf747bb5facdd7c5f6395aa0`

### M4.18 修复大相册 100% 收尾卡住/闪退（2026-10-24）

针对大相册在 100% 后卡住并闪退的问题，收尾校验改为逐项对照当前 Photos 相簿，不再在内存中重新创建第二份完整资源目录。这样保留顺序、编辑状态和资源目录校验，同时降低最终阶段内存峰值；已保存资源和原照片仍保持不变。

GitHub Actions run **#100**（run `40104408210`，commit `bb689b9`）成功完成 iOS 与 Intel Mac 构建。

- `PhotoBridgeOrderProbe-0.3.8-unsigned.ipa`：`231b9ce59fe76625ee2b311a040dbf2171b9dbaf22dba4deb0c0bb092775db73`
- `PhotoBridgeMac-Intel.zip`：`a692f18c6b2671966025c76b364c92beb15d51963fce8501ec7d3d50eec62770`
# Mac-first 导出流程（2026-10-25）

- **已实现**：Mac 端新增“读取 iPhone 相册”和“选择文件夹并开始导出”。Mac 通过 USB/AFC 写入一次性控制请求，iPhone 前台服务被动返回 PhotoKit 相册清单并启动原图读取；用户不需要再先在 iPhone 点“开始备份”。
- **已实现**：Mac 端在选定文件夹下按 `album-order.json` 的 ordinal 顺序逐个资源写入 `.part`，完成大小与 SHA-256 校验后原子提交，并显示手机准备进度、Mac 写入进度、速度、剩余时间和当前文件。原图字节和内部元数据不改写。
- **已实现**：新增 `scripts/mac_control.py`，请求/响应使用 `.part` + AFC rename，拒绝半写入 JSON；底层仍使用既有 USB-only House Arrest/AFC，不启用网络设备查找。
- **已验证**：`swift build -c debug --product PhotoBridgeMac`；Python 测试 63 项全部通过。当前本机没有完整 Xcode，iOS 编译需由 GitHub Actions 验证；真实设备上的大相簿 Mac-first 全流程仍待本轮新包安装后复测。
- **用户操作**：保持 iPhone 解锁并打开 PhotoBridge（仅作为 USB 数据端），在 Mac 点“读取 iPhone 相册”→选择相册→“选择文件夹并开始导出”。文件会出现在所选目录的 `PhotoBridge-导出` 文件夹中。
