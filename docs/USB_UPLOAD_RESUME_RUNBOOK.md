# Mac → iPhone USB 上传继续执行

只使用 USB-only House Arrest/AFC，向 PhotoBridge Documents 的新 `RestoreInbox/<UUID>` 写入已校验备份；不调用 Photos、不覆盖照片或已完成的资源。手机 0.3.3 已支持所需收件目录，本次无须重新安装手机 App。

新上传：

```bash
python3 scripts/upload_resume.py --local private-diagnostics/已COMMITTED的备份
```

断线后保持原备份和 `restore-uploads` 中的日志，重新连接、解锁并信任手机，然后使用**该次新上传生成的日志**：

```bash
python3 scripts/upload_resume.py --local private-diagnostics/同一备份 \
  --resume-journal private-diagnostics/同一备份/restore-uploads/实际日志UUID.json
```

日志保存私有会话信息，不提交 GitHub。每次继续生成新日志，旧日志不改写。旧版 `album_restore.py` 会话没有所有权标记，不能用此功能继续；应保留旧现场，另开新会话。

1. 先复核本机全部资源和精确清单摘要；源变化直接拒绝。会话 UUID、随机 nonce、清单摘要绑定手机只读 owner 文件，并持有原生 AFC 排他锁。并发客户端拿不到锁就停止。
2. 已完成资源必须实际 USB 回读、大小及 SHA-256 一致，随后跳过写入。部分资源必须为单链接普通文件，逐字节比对本地前缀；以不截断模式打开，核对 EOF 后追加剩余字节。
3. 所有目录拒绝符号链接，完整与部分文件并存、错误前缀、过长文件、所有权不一致等均拒绝。全资源写后回读校验，才将 `.part` 提交为正式文件。
4. `album-order.json` 与 `restore-request.json` 最后提交，ready 请求必须最后。已经发布请求或出现 `restore-started.json` 的会话不能继续，避免重放不确定的 Photos 写入；不要自行删标记绕过检查。
5. `USB_VERIFIED` 仅表示 App 收件通过。手机照片库导入仍须在恢复页由用户启动；原相簿和全部旧失败副本保留。

计数分别报告复用完整资源、保留前缀、实际上传后缀及 USB 校验读取量；不把缓存复用算作 USB 速度。

已执行：Live 3 项/6资源受控源读取中断，独立重建 AFC 后继续；dw 20 项/30资源真实拔线、IOUSB 消失及 AFC 写错误30关联，再重连、实际追加严格部分文件后缀、独立系统 shasum 30/30。见 `evidence/m2-usb-upload-controlled-resume-verified.json` 与 `evidence/m2-physical-usb-upload-resume-verified.json`。受控测试不冒充物理拔线；限速只为人工操作，不是性能基准。

可复现硬件脚本（只在协调好拔插时运行；每轮使用新输出目录）：

```bash
python3 -u tests/device_usb_upload_cable_resume.py interrupt \
  --local private-diagnostics/已校验备份 --output private-diagnostics/新的物理上传测试
# 显示 USB_UPLOAD_STARTED 后，用户拔线约5秒再连接
python3 tests/device_usb_upload_cable_resume.py resume \
  --output private-diagnostics/同一次物理上传测试
```

只有 USB 写协议错误和独立 IOUSB 消失关联、重连后存在 `0 < 部分大小 < 资源大小`、实际追加正数剩余字节、全资源独立 SHA-256 及原备份/旧日志/已完成文件不变，才记录样本通过。只有完整大小 `.part` 不算部分续传通过。iPhone 暂存恢复、Photos 事务协调、空间与大规模故障仍待实现或验证。

实现依据：[libimobiledevice 公共 AFC API](https://libimobiledevice.org/docs/libimobiledevice/latest/afc_8h.html)。动态使用独立安装的库；本包不嵌入 GPL 的 pymobiledevice3。
