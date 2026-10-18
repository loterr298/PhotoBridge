# M1 原始资源导出实测

版本 0.2.1 / build 3。编译成功不等于下列设备测试通过。默认只复制，原图、内部 EXIF/GPS/MakerNotes 及照片库时间不改。

1. 使用原来的个人签名方法更新安装新版 IPA，保留同一签名身份和 bundle ID，不卸载旧 App。进入测试相簿（先用 20 张 dw，暂不开始 19,335 项大相簿），点“导出原始资源到本机暂存”。确认实际成员数量和可用空间。
2. 默认关闭 iCloud 下载。保持 App 前台，点开始；待真实完成信息出现。若原件不在本地，应记录错误；只有你显式开启下载后才可联网重试。每次新 UUID 会话，不复用或删除前次数据。停止按钮在当前资源结束后停止；本版尚不续传。
3. 成功应在 Documents/Exports/UUID 下产生 album-order.json。失败仅有 source-order / progress / 部分文件，不能当作完整导出。Live Photo 的全部资源要归属同一个 ordinal，未知资源类型仍保留原值。
4. 已信任/解锁 USB 连接，Mac 执行：

   ```bash
   python3 scripts/album_export.py list
   python3 scripts/album_export.py download --remote Exports/实际UUID --local private-diagnostics/originals-session-01
   ```

   只允许新本地目录。每个资源先下载 .part，核对长度和 SHA-256，通过后独占提交。新的 Mac 副本修改时间为清单 capturedAt UTC + (ordinal−1)×5 秒；不写入媒体内部时间。Darwin 上使用公开 fsetattrlist 为新副本设置创建时间，并回读验证；逐资源报告 SET_AND_VERIFIED。磁盘不支持或验证失败时明确记录 NOT_SET / NOT_VERIFIED，不能把 COMMITTED 当作所有文件时间字段均通过。
5. 成功只有 transfer-manifest.json 的 COMMITTED 才算整个备份校验完成；transfer-progress.json 只记录固定大小进度，filesystem-attributes.jsonl 为逐文件旧/新时间及内容 hash 未变的记录。失败保留部分文件及 FAILED 日志，不自动覆盖、删除或跳过。
6. 先分别验证 JPEG/HEIC/PNG、DNG/ProRAW、3 组 Live Photo 和编辑过的照片。逐组检查资源数、UTI/PhotoKit 类型、原始名称、尺寸和全部 hash；真实数据及元数据报告只留本地。照片库重新导入、Live 播放、相簿恢复、字节级往返尚属后续阶段，不能用备份 COMMITTED 代替。
7. 记录离线 iCloud 原件缺失、权限撤回、资源边界停止、存储不足和断线失败。确认失败没有 COMMITTED 清单。此版没有中途断线后续传或批量性能验收。

Mac App 包内 Contents/Resources/scripts 也携带上述工具。外部 libimobiledevice/libplist 依赖独立安装，未静态捆绑第三方协议库；仅选择 USBMUX，不选择网络设备。
