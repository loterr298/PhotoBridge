# 实施状态记录

更新：2026-10-19。**M0 取得限定设备的人工顺序及合成 USB 通过证据。M1 0.2.0 实编译通过，但首次原图真机测试暴露硬链接 AFC 问题；0.2.1 已修复代码，仍需新包设备验证。原图与恢复尚未验收，详见文末。**

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
