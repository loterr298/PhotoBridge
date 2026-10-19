# 已授权的系统编辑记录时间差异

2026-10-19，用户在查看真实差异后明确授权：“授权仅接受新副本的系统编辑记录时间重置”。此授权只补充下列一项，不改变原件保护和其他校验规则。

- 手机恢复选项默认关闭。开启后，日志记录明确授权；仅接受新资产的 PhotoKit 类型 7 编辑附件中顶层 `adjustmentTimestamp` 的值变化。
- 原图、编辑后图像、视频、Live Photo 资源仍逐文件核对类型、原名、UTI、长度和 SHA-256。非附件资源没有该例外。
- 附件要求类型/原名/UTI/长度仍一致；验证实际读入数据与各自 hash/长度一致，再比较全部非时间字段及类型，包括不理解的嵌套字段和 opaque 编辑配方 bytes。任何其他变化仍失败。
- 当前只对不超过 4 MiB、结构无歧义的 XML plist 检查该例外。重复键（含嵌套）、实体声明、CDATA 键、过深结构及畸形数据拒绝；变化的二进制/其他 plist 格式保持严格拒绝，未宣称已支持。
- 原始附件完整留在原备份及收件目录。App 不修改、重打包或覆盖附件；Photos 在导入后生成的新附件另行回读。附件有二进制差异时明确记录 `strictBytesIdentical=false` 和差异数量。
- 全部资源字节一致的恢复仍用 `PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED`；有该授权差异时使用单独的 `PHOTO_LIBRARY_NON_TIME_DATA_AND_ORDER_VERIFIED_WITH_AUTHORIZED_EDIT_TIMESTAMPS`，不得称为全部资源字节往返一致。
- EXIF、GPS、MakerNotes、厂商私有数据和编辑参数均无改写授权。不改变原相簿；新副本的原照片库日期沿用备份记录的精度，不应用 Mac 5 秒逻辑时间。

证据：`evidence/m2-dw-adjustment-timestamp-difference.json`；实际设备附件经同一 Swift 核心检查 `evidence/m2-real-adjustment-policy-check.json`。这是一个目标设备上特定 XML 编辑附件的实测结论，不保证所有编辑格式或未来系统相同行为。

Apple 公开的 PHAdjustmentData 描述编辑配方，暴露 formatIdentifier/formatVersion/data；当前接口中未找到指定系统编辑记录时间的入口：[PHAdjustmentData](https://developer.apple.com/documentation/photos/phadjustmentdata)。未使用私有接口恢复该值。
