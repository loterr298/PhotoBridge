# Mac 平铺相册格式 v1

用户目录只有文件，没有子目录。正常 Finder 视图显示 `000001_原名.扩展名`、`000002_原名.扩展名`，按名称升序为来源相册 ordinal 顺序。Mac 原生照片查看页按相同序号排列，用 Quick Look 小缩略图和 LazyVGrid 按需显示，缓存最多 120 项 / 24 MiB。不会加载整批原图来绘制网格。Finder 其他排序方式由用户控制，不声称能强制所有应用的显示排序。

每项仅公开一个可查看的主文件：照片优先使用 PhotoKit fullSizePhoto（保留系统照片中的可见编辑效果），否则原始 photo/alternatePhoto；视频优先 fullSizeVideo，否则 video；未知组合完整保存并使用首资源作为后备。公开文件是已校验资源的独占新名称硬链接，不重新编码或写入媒体元数据。

所有原始资源、Live Photo MOV、编辑附件、检查点仍在同一层，使用隐藏文件名：

| 原清单中的逻辑路径 | Mac 实际路径 |
| --- | --- |
| Resources/000001/0001.HEIC | .photobridge-resource-000001-0001.HEIC |
| asset-records/000001.json | .photobridge-asset-000001.json |
| album-order.json | .photobridge-album-order.json |
| transfer-progress.json | .photobridge-transfer-progress.json |
| transfer-manifest.json | .photobridge-transfer-manifest.json |

`.photobridge-layout.json` 为版本标记，未知版本及符号链接标记拒绝读取。权威 `album-order.json` 的内容、来源标识和资源 hash 不改写。上传/恢复通过本地布局映射读取隐藏资源，再写回 iPhone 既有标准 Resources 路径，iPhone 不需要了解 Mac 的呈现格式。上传续传日志也在根层，以 `.photobridge-upload-*.json` 隐藏，不创建日志子目录。

`album_export.py live --flat` 为 Mac 用户流程默认；保留原无 flat 参数的诊断工具行为，以兼容既有测试和老格式。`album_export.py organize --previous OLD --local NEW` 仅本机复制，可整理已完成备份或具有逐项记录的未完成备份，校验每份资源并使用相同的 5 秒文件系统时间。旧目录只读；未完成相册整理后仍为 STOPPED，不能生成 COMMITTED 或假装全部相册已经导出。以后继续导出可校验复用这些文件。

完整往返仍以原始资源 hash 和清单为准；单独取走公开文件并不包含全部 Live Photo/编辑附件。复制整个相册目录会保留隐藏辅助文件。用户若自行修改公开硬链接文件，可能改变同一资源的 bytes，之后严格 hash 校验将拒绝损坏的备份。
