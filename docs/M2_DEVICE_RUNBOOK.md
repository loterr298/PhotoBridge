# USB 回传与新相簿恢复真机验收

目标版本 0.3.1 / build5。编译和 USB 回传不等于照片库恢复通过。原照片、现有相簿与所有暂存文件保留；本轮只创建新相簿及照片副本。

1. 沿用原来的个人签名方式覆盖安装未签名 IPA，保持 bundle ID 和签名身份，不卸载旧 App。旧的 Exports / RestoreInbox 数据应保留。手机全部照片权限、解锁、前台与 USB 连接保持。
2. 3 张 Live Photo（HEIC/MOV）闭环已通过。含编辑附件的 dw 先前在第 12 张严格停止，旧失败会话保留；修复版必须选择新发送、尚未尝试的会话，不重放旧会话。
3. 打开底部“恢复”→“刷新收件箱”→“校验收件与 PhotoKit 支持”。本轮 dw 应显示 **20 项、30 份资源**。先开启用户已明确授权的“允许新副本的系统编辑记录时间重置”，再预检；默认关闭时含编辑附件的备份会在写入前拒绝。预检会核对完整清单、每份文件及系统支持的完整资源组合；不支持时整个操作停止，不移除附件。
4. 查看新相簿名。点“创建新相簿并导入全部资源”后才向照片库添加副本；不会修改原相簿。为照片库副本和本地回读校验另留约两倍资源空间。保持 App 前台。
5. 实际导入完成后，App 逐份重新导出系统提供的全部资源，核对类型/原名/UTI/长度/SHA-256，回读 nil-options 相簿位置和来源→新标识映射。成功应产生 `restore-report.json`，全字节一致时状态为 `PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED`；仅存在已授权编辑记录时间差异时为 `PHOTO_LIBRARY_NON_TIME_DATA_AND_ORDER_VERIFIED_WITH_AUTHORIZED_EDIT_TIMESTAMPS`，另报附件 hash 不同，不能称为全部资源字节一致。仅出现“已导入”或进度计数不能替代最终资源验证。
6. 在系统照片找到该新相簿，选择自定义排序，与来源 dw 的 20 张逐项核对，特别检查其中编辑照片的显示效果是否一致；Live 样本另逐张播放。回复 App 最终文字、20 张顺序及编辑效果是否一致。人工观察与 App 自动校验分别记录。
7. 私人结果保存在 `Documents/RestoreInbox/UUID`：固定大小 `restore-progress.json`，`restore-records/` 旧→新标识，`verification/` 真实回读文件与 hash 记录，最终 `restore-report.json`。Mac 通过同一 USB 路径读取证据；不得上传私人文件至 GitHub。
8. 出错或停止时保留已创建的新副本和日志，不自动删除或重试。一次尝试标记 `restore-started.json` 防止崩溃后盲目重复导入；此版尚未提供可靠恢复照片库事务的续传。若 Photos 重打包、漏资源、改名或 UTI 改变，必须如实记录为差异，不标字节往返通过。

手动发送其他备份可在 Mac 使用：

```bash
python3 scripts/album_restore.py --local private-diagnostics/已经COMMITTED的备份目录
```

CLI 只准备 USB 收件，不调用 Photos。发送失败不会发布 ready 请求，重复执行创建新 UUID，不覆盖旧会话。原备份媒体必须仍与原 manifest 的 byteCount/SHA-256 一致。

原照片库创建日期按现有清单的 ISO8601 秒精度设置到新副本；不把 Mac 5 秒逻辑日期传入照片库，不改任何媒体内部 EXIF/GPS/MakerNotes。PNG、DNG、编辑状态、iCloud、故障注入及大量照片各有独立验收，不能从 3 张 Live 样本外推。

授权范围详见 [PRESERVATION_POLICY.md](PRESERVATION_POLICY.md)；Mac 下载继续执行详见 [USB_RESUME_RUNBOOK.md](USB_RESUME_RUNBOOK.md)。
