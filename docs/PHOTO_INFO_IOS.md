# iPhone 照片信息编辑

PhotoBridge 的 iPhone 端新增独立“照片信息”标签，不改变备份到 Mac、相簿顺序或恢复流程。

功能对应原网页照片信息页的核心流程：

- 从系统照片选择最多 20 张 JPEG、HEIC 或 PNG；
- 读取相机品牌、型号、镜头、软件、ISO、焦距、等效焦距、光圈、快门、EV 和拍摄时间；
- EV 为 `0` 时仍写入 EXIF；
- 调整分辨率，开启 3:4 后按中心裁切并缩放；
- 用 ImageIO 写入新文件，不覆盖原照片；
- 用 PhotoKit `PHAssetCreationRequest` 直接保存到 iPhone“照片”相册。

网页端的 ExifTool 服务不能直接放进 iOS，因此 iOS 版本使用 ImageIO/PhotoKit。保存后的相册记录由系统生成，原照片不会被修改。当前源码检查通过；完整 Xcode 编译和实体 iPhone 的相机信息显示、HEIC/Live Photo、权限和大图压力仍需云端构建与真机验收。
