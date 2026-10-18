# USB 回传与新相簿恢复真机验收

目标版本 0.3.0 / build4。编译和 USB 回传不等于照片库恢复通过。原照片、现有相簿与所有暂存文件保留；本轮只创建新相簿及照片副本。

1. 沿用原来的个人签名方式覆盖安装未签名 IPA，保持 bundle ID 和签名身份，不卸载旧 App。旧的 Exports / RestoreInbox 数据应保留。手机全部照片权限、解锁、前台与 USB 连接保持。
2. 本机已将验证过的 3 张 Live Photo（3 份 HEIC + 3 份配对 MOV）经 USB 回传到独立 RestoreInbox 会话，并实际回读 hash。不要再次导出或重建测试相簿。
3. 打开底部“恢复”→“刷新收件箱”→“校验收件与 PhotoKit 支持”。确认预检显示 **3 项、6 份资源**。预检会核对完整清单、每份文件及系统支持的完整资源组合；不支持时整个操作停止，不移除附件。
4. 查看新相簿名。点“创建新相簿并导入全部资源”后才向照片库添加副本；不会修改原相簿。为照片库副本和本地回读校验另留约两倍资源空间。保持 App 前台。
5. 实际导入完成后，App 逐份重新导出系统提供的全部资源，核对类型/原名/UTI/长度/SHA-256，回读 nil-options 相簿位置和来源→新标识映射。成功应产生 `restore-report.json`，状态 `PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED`。仅出现“已导入”或进度计数不能替代最终资源验证。
6. 在系统照片找到该新相簿，选择自定义排序，与来源 3 张逐项核对；逐张打开并长按播放全部 3 张 Live Photo。回复 App 最终文字、顺序是否一致、3 张是否均能动态播放。人工观察与 App 自动校验分别记录。
7. 私人结果保存在 `Documents/RestoreInbox/UUID`：固定大小 `restore-progress.json`，`restore-records/` 旧→新标识，`verification/` 真实回读文件与 hash 记录，最终 `restore-report.json`。Mac 通过同一 USB 路径读取证据；不得上传私人文件至 GitHub。
8. 出错或停止时保留已创建的新副本和日志，不自动删除或重试。一次尝试标记 `restore-started.json` 防止崩溃后盲目重复导入；此版尚未提供可靠恢复照片库事务的续传。若 Photos 重打包、漏资源、改名或 UTI 改变，必须如实记录为差异，不标字节往返通过。

手动发送其他备份可在 Mac 使用：

```bash
python3 scripts/album_restore.py --local private-diagnostics/已经COMMITTED的备份目录
```

CLI 只准备 USB 收件，不调用 Photos。发送失败不会发布 ready 请求，重复执行创建新 UUID，不覆盖旧会话。原备份媒体必须仍与原 manifest 的 byteCount/SHA-256 一致。

原照片库创建日期按现有清单的 ISO8601 秒精度设置到新副本；不把 Mac 5 秒逻辑日期传入照片库，不改任何媒体内部 EXIF/GPS/MakerNotes。PNG、DNG、编辑状态、iCloud、故障注入及大量照片各有独立验收，不能从 3 张 Live 样本外推。
