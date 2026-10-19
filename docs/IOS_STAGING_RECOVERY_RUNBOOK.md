# iPhone 原始资源暂存的中断恢复

0.3.5 开始为每份完成资源保存独立检查点；旧版没有 staging-plan.json 的会话不支持继续，原文件保留，可以另开新导出。

“继续”会创建新的 UUID 会话。先核对当前来源相簿及精确计划，再逐一复核旧资源的实际大小和 SHA-256，把通过的完整资源复制到新会话。未完成或没有已提交检查点的单个资源从 PhotoKit 重新完整读取；**不从资源内部字节偏移继续，也不修改旧 .part**。新会话需额外存储空间。Photos 原件、相簿及媒体内部字段均不改写。

拒绝条件：全库权限不可用、来源相簿不可访问/改名、成员或顺序变化、任一资产的创建/编辑日期或资源类型/原名/UTI/顺序/媒体字段变化、编辑版本标记不可用、旧资源损坏/缺失、符号链接或多链接、计划/检查点不匹配。权限和停止请求在资源边界及最后发布前检查。所有完成资源复查后才发布 album-order.json；没有该文件就不能当成完整暂存让 Mac 下载。

检查点属于内部数据，日期使用 Foundation 数值编码以保留亚秒级修改版本；对外 album-order.json 沿用现有 ISO8601 格式及5秒文件系统时间策略。继续会保留最初来源顺序和逻辑时间基准，新会话日志另写实际运行 commit、复用数和重新读取数。

## 真机复验步骤（本机 dw 样本已验证，其他故障范围仍待测）

1. 沿用原个人签名方式覆盖安装0.3.5，不卸载旧 App；允许全部照片，进入 dw 的原始资源暂存页，保持相簿内容不变，iCloud下载默认关闭。
2. 展开“中断恢复诊断”，打开“新导出完成1个资源后停止”，然后开始新的本机暂存。应显示停止、完成1个资源且没有完整清单。记录来源会话前8位。
3. 完全关闭再打开 App，回到 dw 的暂存页，点“刷新未完成会话”，选择刚才来源会话，点“校验并继续到新会话”。继续操作不受诊断开关影响。
4. 应使用新的会话，最后显示20项/30资源，复用1、PhotoKit重新读取29。实际资源数量若因来源变化不符，按真实提示记录，不强行宣称通过。
5. Mac 经USB读取来源/新会话的计划、检查点和进度，确认源会话媒体、部分文件、日志字节/mtime/birthtime不变；新会话资源下载到全新本地目录，系统 shasum 全部匹配，且源顺序/资源类型/原名/UTI/大小/hash 与旧完整备份逐项对应。原样本变化时不能跳过差异。

这只证明资源边界停止、进程重启后恢复。真实系统在单个资源写入中强制终止、iCloud/权限撤销/空间不足仍应分别测试，不把诊断开关当成这些故障通过。Photos 导入事务的中断协调仍待实现；此功能从不自动重放导入。

实现依据：[Apple PHAssetResourceManager](https://developer.apple.com/documentation/photos/phassetresourcemanager)，读取原始资源而非缩略图。本版使用完整资源 writeData 接口，没有公开字节偏移参数；上述完整重读边界始终明确报告。


本机实际结果：0.3.5/37798f7，dw20项30资源、77,450,231 bytes。停1资源，用户确认重启后继续，新会话日志复用1/PhotoKit读取29；Mac下载及系统shasum30/30，并与既有完整备份全部资源类型、原名、UTI、尺寸、媒体字段、大小、hash和成员顺序逐项一致。旧会话6个文件的bytes/mtime/birthtime/nlink/size均未变。复用数来自App运行日志，输出字节由Mac独立验证；旧目录属性不在本次审计范围。设备证据见 evidence/m3-ios-staging-device-recovery-verified.json。

独立只读审计脚本（不会写手机；所有输出保持本机私有）：

```bash
python3 tests/device_staging_recovery.py capture --remote Exports/刚停止会话UUID \
  --expected-build 实际手机源码commit --output private-diagnostics/新审计目录
# 用户明确完全关闭再打开App，然后在手机继续；保存该用户确认
python3 tests/device_staging_recovery.py verify --remote Exports/继续后新会话UUID \
  --output private-diagnostics/同一个审计目录 --reference private-diagnostics/既有完整备份 \
  --relaunch-confirmed
```

只有用户实际确认重启时才提供 --relaunch-confirmed；该字段单独记录，不据文件自行推断。核对最终manifest与新plan的session、完整来源快照（日期转换为既有ISO8601交换精度）、所有成员/资源目录，并与reference相簿身份、顺序和完整元数据相互绑定；不能只凭相同成员/hash接受另一相簿名或标识。
