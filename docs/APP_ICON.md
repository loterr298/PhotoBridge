# PhotoBridge 应用图标

当前图标是 iOS 与 Intel macOS 共用的轻玻璃彩色花瓣标志：白色玻璃方盒、八片半透明彩色花瓣和白色中心。资源直接取用户最新参考图左上角图标区域，按原比例裁切并生成多尺寸版本。外部背景使用透明 alpha，Finder 不再显示整块白色方形底。

## 资源

- 母版：`assets/AppIcon/PhotoBridge-icon-master.png`
- iOS：`apps/iOS/Assets.xcassets/AppIcon.appiconset/PhotoBridge-icon-1024.png`
- macOS：`apps/macOS/PhotoBridge.icns`
- macOS 打包脚本会把 `.icns` 复制到 `PhotoBridgeMac.app/Contents/Resources`，并由 `CFBundleIconFile` 指定。

## 设计与许可

设计遵循 Apple App Icons 和 Icon Composer 的留白、玻璃材质与缩放原则。工程使用用户最新提供的参考图左上角图标作为几何母版，裁切成标准 1024px 资源，再生成 iOS 资源和 macOS 多尺寸 `.icns`，没有引入 Apple SDK 图形或第三方运行时资源。

参考：

- https://developer.apple.com/design/human-interface-guidelines/app-icons
- https://developer.apple.com/icon-composer/
- https://developer.apple.com/sf-symbols/
- https://help.unsplash.com/en/collections/1463188-unsplash-license
