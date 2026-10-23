# PhotoBridge 应用图标

当前图标是 iOS 与 Intel macOS 共用的原创相册标志：一册浅蓝色相册、单个照片窗口、低对比度留白。图标不包含文字、Apple 标志、设备外形、USB 或云同步符号，缩小后仍保持“相册”这一单一含义。

## 资源

- 母版：`assets/AppIcon/PhotoBridge-icon-master.png`
- iOS：`apps/iOS/Assets.xcassets/AppIcon.appiconset/PhotoBridge-icon-1024.png`
- macOS：`apps/macOS/PhotoBridge.icns`
- macOS 打包脚本会把 `.icns` 复制到 `PhotoBridgeMac.app/Contents/Resources`，并由 `CFBundleIconFile` 指定。

## 设计与许可

设计参考了 Apple 的 App Icons、Icon Composer 和 SF Symbols 公开设计说明；没有复制 Apple 图形或第三方图片。网上搜索到的 Unsplash 渐变图只用于了解色彩方向，没有进入工程。最终位图由本项目生成并保存为项目资源。

参考：

- https://developer.apple.com/design/human-interface-guidelines/app-icons
- https://developer.apple.com/icon-composer/
- https://developer.apple.com/sf-symbols/
- https://help.unsplash.com/en/collections/1463188-unsplash-license
