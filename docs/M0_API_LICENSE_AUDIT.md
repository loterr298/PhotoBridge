# M0 API / 许可证复核（2026-10-17）

实际浅克隆当前默认分支并读 LICENSE、README、相关源码。精确 commit 与许可证文件 SHA-256 见 `evidence/upstream-revisions.json`。未把候选项目源码复制进产品；本项目授权由拥有者决定，不自动选择第三方许可证。

| 项目 | 实际核查 | 决策与风险 |
|---|---|---|
| [iphone-syncronizer](https://github.com/thechandanbhagat/iphone-syncronizer) | MIT；README macOS 13+；DeviceManager 用 ICCameraDevice、相机 catalog | 可借鉴 USB 相机发现。README 明确自建相簿及成员可能不暴露；不能据此证明相簿手动顺序 |
| [sideroll](https://github.com/naplesblue/sideroll) | MIT；README macOS 15.4+；CameraFolderScanner 按时间窗、相机 RAW 类型筛选 | 不采用时间猜测映射，不把最低 15.4 直接带入本产品；Intel 构建需独立检查 |
| [Media](https://github.com/chris-swift-dev/Media) | MIT；LazyAlbum.swift 多处显式赋值 options.sortDescriptors | 不引入封装，直接用 PhotoKit，防止默认排序掩盖真实系统返回次序 |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | LICENSE GPL version 3；HouseArrestService 使用 VendDocuments/AFC | 不嵌入、不捆绑、不运行其源码。进程隔离本身不等于免除 GPL 再分发义务；成品如需依赖须单独审查 |
| [ifuse](https://github.com/libimobiledevice/ifuse) | COPYING LGPL-2.1；src/ifuse.c LGPL-2.1-or-later；VendDocuments 与 VendContainer 不同 | 仅读协议调用方式，无 FUSE 依赖。沙盒文件访问不等于系统照片库读取 |
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) | src/afc.c 等 LGPL-2.1-or-later；仓库同时有 COPYING/GPL2、COPYING.LESSER，README 概述不够替代逐文件审查 | 独立 ctypes PoC 动态调用本机已有库。未携带二进制、未修改或复制源文件；对外捆绑前必须补许可通知、对应源代码、替换/重链接条件及各依赖审查。不能从动态调用推导绝对的合规保证 |

## Apple 公开接口与通道边界

- [PHAsset.fetchAssets(in:options:)](https://developer.apple.com/documentation/photos/phasset/fetchassets(in:options:)) 文档能确认相簿成员获取、nil 使用默认选项；本次文档未提供“等于系统 Photos 当前自定义显示顺序”的跨版本承诺。因此 G1 是待真机测试的假设，不是实现保证。
- [PHFetchOptions](https://developer.apple.com/documentation/photos/phfetchoptions) 会影响过滤和排序。本诊断不写 sortDescriptors，分别使用 nil 与空 options，记录返回位置，不按日期/文件名猜顺序。
- [ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore) 用于发现相机及其目录/媒体；本 Mac 诊断仅发现设备，不声称目录包含 Photos 的相簿成员关系。
- [UIFileSharingEnabled](https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled) 是 App Documents 文件共享配置。它不授予系统照片库访问，必须另外取得 PhotoKit 权限。
- House Arrest/AFC 的第三方客户端属于独立实现的设备协议，不是苹果公开 PhotoKit USB API，亦不能宣称经 Apple 官方许可。仅使用系统正常信任配对，服务拒绝时停止，不绕过权限。
- [PHAssetResourceManager](https://developer.apple.com/documentation/photos/phassetresourcemanager) 才是后续原始资源导出的接口。M0 不导出照片，不将缩略图代替原图。

## 本机实测与限制

本机 macOS 15.7.9 / x86_64 / Swift 6.1.2，只有 Command Line Tools。旧 libimobiledevice.dylib 依赖缺失 libusbmuxd.dylib；已改成依次尝试可用动态库，本机 libimobiledevice-1.0.6.dylib 能加载，USB lookup 返回 -3（无设备）。失败与修复日志均保留。尚无 AFC 读写及目标 iOS 27.2 Beta 证据。

G1/G2 未通过，后续原图、5 秒文件时间、PhotoKit 导回、恢复、续传/性能及正式 UI 暂不宣称完成。
