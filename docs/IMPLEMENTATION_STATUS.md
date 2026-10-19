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
