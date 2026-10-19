# 恢复权限和空间前置检查（0.3.7/build11）

实现：只接受全部照片 readWrite 权限；恢复新运行估算剩余 Photos 副本 bytes + 本轮尚需回读的全部资产 bytes + 128 MiB。重启复用的已有副本不重复计 Photos 创建，但仍计本轮完整回读。每次事务/资源边界重新查询 ImportantUsage 可用容量，资源 inspect+独占提交后才扣除实际已写字节，同时保留后续资产预算。

这是估算和边界保护，**不是空间预留或 Photos 系统开销上限**。其他进程、系统开销及实际资源变化仍可能使写入失败；文件/部分资源/意图和旧副本保留，不删除腾空间。暂存导出没有公开可靠资源长度，本阶段只统一其权限检查，不宣称已实现导出全量空间估算。

## 安全诊断

先从 Mac 向全新 UUID 收件发送既有3-Live备份，保存收件所有文件的 bytes/size/mtime/birthtime/nlink 基准。用户覆盖安装后只执行预检，不点击创建相簿。

1. 全部照片权限下：恢复→新会话→中断恢复诊断→“仅预检：模拟零可用空间”。预期 BLOCKED / INSUFFICIENT_ESTIMATED_CAPACITY / simulatedZeroCapacity=true / effectiveAvailableBytes=0，actualAvailableBytes保留实际查询结果，ready=false。没有填充文件，没有Photos写请求，也没有 restore-started 或 restore-recovery。
2. 手机界面显示本次实际容量、估算需求和模拟标记。报告默认仅存 Application Support，用户点击“允许 Mac 读取这份诊断报告”才独占复制该报告到 Documents/RestoreChecks。Mac 按本次报告检查，不把模拟称为真实磁盘耗尽。
3. 用户在系统设置把本App照片权限改为“无”，回手机同一新会话正常预检。预期 FULL_PHOTO_ACCESS_REQUIRED，起止权限denied，未读取容量/未写Photos。用户查看并共享此份报告。
4. 用户恢复“全部照片”权限，回同一会话正常预检。预期READY、simulatedZeroCapacity=false、effective=actual且实际值>=预算、3项/6资源完整hash。查看并共享此份报告；**不要创建相簿**。
5. Mac只读验证三份独立报告的实际runtime commit/版本、会话/策略和空间字段，全部收件 bytes/可用属性仍与基准相同，没有任何恢复声明/Photos意图。报告本身新增于独立目录，不纳入收件不变的比较。

本次真实权限测试限定“预检前撤销，再恢复”；不是事务进行中撤权。空间测试限定“模拟零输入”，不是实际ENOSPC。真正写满磁盘、系统终止、Photos提交中强杀和iCloud故障仍NOT_RUN。日志默认私有，用户每次明确共享后才取回；不自动上传容量或私人媒体。

## API 来源

Apple volumeAvailableCapacityForImportantUsage 与 PHPhotoLibrary.authorizationStatus(for:) 为公开API。PrivacyInfo 声明 DiskSpace 的 E174.1（用户可见的写前检查）、85F4.1（显示）、7D9E.1（用户选择共享具体诊断），以及沙盒文件时间 C617.1。声明不等于完整 App Store 分发审查。真实容量不写入自动共享的恢复进度日志；预检报告仅用户按钮显式共享。

https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage
https://developer.apple.com/documentation/photos/phphotolibrary/authorizationstatus(for:)
https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
