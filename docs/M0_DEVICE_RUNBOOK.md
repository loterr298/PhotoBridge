# M0 真机验证手册

所有真实照片、localIdentifier 和设备识别信息只保存在本地 `private-diagnostics/`。不要提交或上传 CI。合成探针不含照片。

## O-01 / O-02：20 张逐项核对

1. 创建专用普通相簿，放入 20 张画面印有唯一编号 01–20 的测试照片。文件名、拍摄日期故意与编号顺序不同。记录设备型号、iOS 完整版本及诊断 App build commit。
2. 在系统照片 App 将该相簿排序切换到“自定义”，拖动成明确乱序，例如 17,03,12,01,20,04,09,02,15,05,18,07,14,06,19,08,16,10,13,11。独立记录画面编号顺序，保存系统截图在本地。
3. 在诊断 App 给予**全库**权限。选同一个相簿，使用默认 nil options。完整显示相簿名、相簿 ID、20 个 ordinal、完整 localIdentifier 和真实缩略图。根据缩略图上编号建立“编号→localIdentifier”对照表（不要把 App 的返回位置当作系统基准）。
4. 根据步骤 2 的独立编号顺序查表，将系统照片对应标识填入 `photos-order.csv`：表头为 `ordinal,localIdentifier`，随后 20 行；ordinal 从 1 到 20。保存本地诊断 JSON 并主动分享到 Mac 本地目录，或 Finder 文件共享复制。
5. 执行：

   ```bash
   python3 scripts/compare_order.py private-diagnostics/order-probe.json private-diagnostics/photos-order.csv \
     --observer tester --test-id O-01 --evidence-note '设备型号 / iOS版本 / 自定义排序 / 截图本地路径'
   ```

   相同只会标 `MANUAL_COMPARISON_PASS`；不是恢复通过。错位必须输出具体 ordinal。不能直接从 JSON 生成基准 CSV 然后声称独立比对。
6. 切换“空 PHFetchOptions”重做，记录两种模式是否一致。两份快照保留分别的时间与 fetchMode。
7. 回到系统照片移动至少五项，重新独立记录。回诊断 App 点击重新读取，导出新 JSON，使用 `--test-id O-02` 复测。不能用旧截图验证新顺序。
8. 将权限改成 Limited、拒绝，再测试明确提示；Limited 的子集不能通过 O-01/O-02。智能/共享相簿、主图库按日期视图不属于支持范围，M0 不列出它们。

## U-01 / U-02：100 MiB 双向真 USB

先签名安装 iOS App，解锁 iPhone、连接线缆、在系统确认信任。关闭 Mac/iPhone Wi-Fi、个人热点及其他无线设备通道，记录线材/USB 接口。脚本查找仅使用 `IDEVICE_LOOKUP_USBMUX=2`，但物理拔线测试仍是独立证据。

需要 Python 3.9+ 和独立安装的兼容 libimobiledevice/libplist；本项目不携带这些二进制，不调用私有 Apple Framework。正常配对/House Arrest 是逆向协议客户端，Beta 兼容性和分发许可需进一步审查。

```bash
python3 scripts/usb_probe.py discover
```

无设备或库错误时返回 2 / `BLOCKED`，不能转成 PASS。

1. 在 iPhone 传输页点击“生成 iPhone → Mac 100 MiB 文件”。这会在 Documents/USBProbe/Outbox/UUID 生成 probe.bin 和 receipt.json，不读取照片。
2. Mac 执行：

   ```bash
   python3 scripts/usb_probe.py list-outbox
   python3 scripts/usb_probe.py download --remote USBProbe/Outbox/实际UUID --local private-diagnostics/phone-to-mac-01
   ```

   本地要求新目录，下载到 `.part`，逐资源大小/SHA-256 与 iPhone 生成清单一致后独占创建最终文件，保留 part 作为诊断痕迹，不覆盖现有数据。
3. Mac 生成另一份 100 MiB 随机数据并上传：

   ```bash
   python3 scripts/usb_probe.py upload --local private-diagnostics/mac-to-phone-01
   ```

   写入全新 Inbox/UUID，先 `.part`，AFC 回读完整 hash 后提交。此时只记 AFC_READBACK_HASH_PASS。
4. 在 iPhone 点击“校验 Mac → iPhone 收件文件”，App 独立读取完整文件、核对大小及 hash，显示 HASH_PASS/FAIL，并保存 iPhone 回读 JSON。保存本地证据。
5. 拔掉数据线后 `discover` 必须失败；重插能发现。记录关闭无线的设置证据及上述双向 hash，再按验收模板判定 U-01/U-02。传输吞吐包含生成/校验开销，不能当作峰值 USB 速度。
6. 中断、锁屏、未配对、App 未安装、错误 bundle ID 都必须报告失败。本探针不自动恢复，断线后的 partial 留存；可靠续传属于后续阶段。

这些检查不代表原图/Live Photo/PhotoKit 导回或相簿恢复通过。M0 不修改照片库。
