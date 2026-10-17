# 构建与安装

从 PhotoBridge 目录操作，云端只上传源码与合成测试，不包含私人照片。

## Intel Mac

```bash
swift run CoreChecks
python3 -m unittest discover -s tests -v
bash scripts/build-mac.sh
open build/PhotoBridgeMac.app
```

最低 macOS 13，产物 `build/PhotoBridgeMac-Intel.zip` 内为 x86_64 App，ad-hoc 签名，未公证。仅当前 macOS 15.7.9 的构建与启动可实测，13/14 的运行兼容要另测。USB AFC 探针脚本随包位于 Contents/Resources/scripts，依赖外部 Python 及 libimobiledevice。

本地只有 Command Line Tools 时 XCTest 不存在，`swift test` 会失败；保留日志，`swift run CoreChecks` 是实际执行相同核心算法的可运行检查，不等同于 XCTest 已通过。

## iOS 工程 / 云构建

XcodeGen 2.44.1：

```bash
xcodegen generate
xcodebuild -project PhotoBridge.xcodeproj -scheme PhotoBridgeOrderProbe -destination 'generic/platform=iOS' \
  -configuration Release -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions `PhotoBridge diagnostics` 支持 push、PR、手动运行，实际打印 Xcode/SDK/runner，并执行 XCTest、核心检查、Python 检查、iOS device build、Intel build；产物中有 unsigned .app.zip、Mac App zip、校验值、工具链与构建日志。可选最低 SDK major 只检查实际版本，不假设有 27.2 Beta SDK。

App 只使用 iOS 16 已公开接口；较早 SDK 构建可在更新 iOS 运行仍需目标 Beta 真机验证，不能等同于认证支持 iOS 27.2。

## 真机签名

unsigned .app.zip **不能直接安装**。付费开发者可在受信任的 Xcode 环境配置 Team、开发证书及设备 provisioning，或配置 TestFlight 合法分发。免费 Personal Team 需要 Xcode 登录、设备注册和个人签名，有有效期与能力限制，不能由本 CI 自动提供。第三方侧载工具也仍需有效签名，且 Beta 兼容未测试；不提供绕过签名的路径。

仓库不保存 Apple ID、私钥、profile 或密码。后续签名工作流只通过 GitHub Secrets 或本机 Keychain 注入。
