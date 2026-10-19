# Mac USB 下载继续执行

当前支持 **App 已完整暂存 → Mac 下载** 的继续执行。尚不支持 iPhone 暂存续传、Mac 上传续传或不确定的照片库事务重放。

```bash
python3 scripts/album_resume.py --remote Exports/实际UUID \
  --from-directory private-diagnostics/上次下载目录 \
  --local private-diagnostics/新的继续下载目录
```

新目标必须不存在，并且在旧目录之外（包含符号链接别名检查）。旧目录仅被读取；新的已完成备份另存，不覆盖或删除旧文件。

1. 手机当前清单的精确 SHA-256 必须与旧 transfer-progress.json 相同。相簿名称、顺序、资源声明或其他清单字节改变时拒绝继续。
2. 旧目录已完成文件先校验完整大小/hash，再从本机复制到新备份；仅凭文件名不会跳过 USB 读取。
3. 旧 .part 的前缀复制到新备份，再用 AFC 文件 seek 从对应偏移下载余下字节。最终完整资源 hash 必须匹配；错误前缀不能完成。旧部分文件保留，不就地修补。
4. 新备份沿用已有完整下载校验、5 秒文件时间记录及最终 COMMITTED 清单。创建时间不支持/未验证时仍如实记在属性报告，不把字节 COMMITTED 等同每个文件系统字段都通过。
5. resume-report.json 记录本机复用文件数、部分前缀字节、实际重新读取的 USB 资源字节；不把本机缓存吞吐宣称为 USB 速度。

可复现的手动硬件检查（照片和清单必须只放本地私有目录）：

```bash
python3 tests/device_usb_resume.py --remote Exports/实际UUID \
  --output private-diagnostics/新的续传硬件测试目录
```

该脚本主动在第二个资源中断接收、关闭并重建 AFC，然后继续，并用系统 shasum 独立复核全部资源和文件时间。**不是物理拔线测试**；不会写入照片库或删除源数据。实际已通过 3 张 Live Photo / 6 资源测试，具体范围见 `evidence/m2-usb-download-resume-device.json`。物理拔线、存储不足和规模测试仍需独立验收。
