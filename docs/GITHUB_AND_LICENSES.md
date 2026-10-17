# GitHub / 官方技术资料及许可核查（2026-10-17）

## 候选 GitHub 工程（代码使用前必须复核当前分支）

| 仓库 | 推荐用途 | 重要限制 |
| --- | --- | --- |
| https://github.com/thechandanbhagat/iphone-syncronizer | macOS SwiftUI、ImageCaptureCore/USB 目录读取、下载状态 | README 明确 PTP 不保证能访问所有自建相簿及关联信息；MIT License |
| https://github.com/naplesblue/sideroll | Mac USB 原图拷贝、Live Photo、ProRAW 等参考 | 主要是从 iPhone 相机目录导出；macOS 15.4+；MIT License |
| https://github.com/chris-swift-dev/Media | iOS PhotoKit wrapper 参考 | MIT License；开发人员需确认库当前 API 能否支持顺序诊断，不应为“容易用”而失去系统行为可控性 |
| https://github.com/doronz88/pymobiledevice3 | AFC、House Arrest、配对/连接调查 | GPL-3.0 license，架构和再分发合规性要审查；iOS Beta 兼容性未知 |
| https://github.com/libimobiledevice/ifuse | 底层文件共享研究 | 不是系统 Photos 手动相簿管理 API；需检查依赖与授权 |

## 苹果官方文档（边界一定要区分）

- `PHAsset.fetchAssets(in:options:)`：https://developer.apple.com/documentation/photos/phasset/fetchassets(in:options:)
  - 能读取相簿成员；默认返回顺序是否与当前系统照片 App 的自定义排序一致，仍须目标设备实测。
- `PHFetchOptions`：https://developer.apple.com/documentation/photos/phfetchoptions
  - 允许按字段排序；按 `creationDate` 排序 ≠ 原相簿手动顺序。
- `PHAssetCollectionChangeRequest.insertAssets`：https://developer.apple.com/documentation/photos/phassetcollectionchangerequest/insertassets(_:at:)
  - 可按指定索引插入自建相簿资源；完整一致仍需写回后比对。
- `PHAssetResourceManager`：https://developer.apple.com/documentation/photos/phassetresourcemanager
  - 访问底层媒体资源，不是缓存图片/缩略图。
- `PHAssetCreationRequest.addResource(fileURL:)`：https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource(with:fileurl:options:)
  - 把资源导回照片库时建议以文件形式提供数据并做对应媒体类型处理。
- `PHAssetResourceCreationOptions.shouldMoveFile`：https://developer.apple.com/documentation/photos/phassetresourcecreationoptions/shouldmovefile
  - 默认 false：应当复制资源，避免移动后丢失暂存的源数据。

## GitHub Actions / 构建

- 官方 runner 镜像：https://github.com/actions/runner-images
- GitHub Actions `xcode-27` 镜像发布说明：https://github.com/actions/runner-images/issues/14404
- Xcode 27 image inventory：https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md

请在 CI 里打印版本并明确是否存在目标 SDK；不要假定镜像已有 Xcode 27.2 Beta。支持最新 iOS 的 app 不等于必须用同号 Xcode 构建，但新增 SDK API 则有工具链条件限制。

## 许可证纪律

- 主仓库许可证由用户/实际开发人员最终决定，不能拿别人的 MIT 或 GPL 项目做完后声称“全是原创”。
- MIT 源码复用遵守版权和许可留存要求，记录原始依赖及更改。
- GPL-3.0 的 `pymobiledevice3` 不应未经法律/架构审查直接嵌入计划闭源再分发的成品；可以先做独立诊断原型，再决定合规架构，必要时另选库或自己实现 Apple 许可的数据通道。
- 任何第三方项目都需要查看最新许可证文件、发行情况和所需最低系统版本。

## 验证状态

本文是来源调查与工程要求，不包含本人的目标 iPhone 与 Mac 真机测试结果。所有真实兼容性和传输速度都必须由后续开发运行报告确认。
