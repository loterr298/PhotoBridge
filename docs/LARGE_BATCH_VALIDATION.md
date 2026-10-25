# 大批量顺序、性能与稳定性验证

本轮版本：两端 0.3.14 / build18。优先保留完整性和恢复安全检查，再减少重复计算；不通过跳过 SHA-256 或扩大无界并发来提高速度。

## 已改动的路径

- 恢复空间预算：一次建立不可变的前缀和索引，每次写入前 O(1) 计算剩余空间，继续实际查询可用容量；资源大小、计数、部分回读和整数溢出仍失败关闭。
- 恢复日志：来源/副本身份用 Set 查重；placeholder 校验只读取一次目录名称快照；逐事件 JSON 解析使用 autoreleasepool。仍读取并验证所有原有记录，不缓存旧 hash 或跳过完整前缀检查。
- 实时导出：正常状态轮询合并到 250ms，取消信号仍每次检查，等待文件仍轮询；提交前强制重新读取手机状态，失败不能被缓存隐藏。
- 旧版下载：同一份不可变清单只计算一次摘要，结束仍重新读取原始清单并比对；每份资源的校验不减少。
- 上传：本地资源检查和远端复用预扫描均可在文件边界安全暂停；旧日志不改写，未通过时不发布恢复请求。
- 日期闭环：来源成员和资源组的照片库创建日期必须一致；导入回读检查创建日期（仅容忍 1ms 的平台数值表示误差）。不写 EXIF，不把 Mac 5 秒逻辑时间写入照片库。
- 手机恢复：完整清单检查、日志回放及事务记录准备移至 utility 任务并逐一等待；保持原来的意图→占位标识→Photos 提交→回读→记录顺序，避免大批文件处理长期占据主线程。真实手机交互尚待新包安装验证。

## 可复现命令

```sh
bash scripts/verify-delivery.sh
PHOTOBRIDGE_LEDGER_COUNT=50000 swift run -c release ScaleChecks
python3 tests/scale_transfer.py --assets 50000 --report build/scale-transfer-50000.json
```

门禁持续执行五万成员的顺序/空间算法检查、1000 项日志回放、1000 张合成资源往返及中断续传；完整五万文件测试独立运行，不在普通单元测试中重复大量磁盘写入。

## 压力测试的含义

`ScaleChecks` 对 50000 个成员验证整序列，拒绝首/中/末位置互换、缺项、重复和错误日期；旧空间算法与新索引在相同边界逐项比较。128MiB 额外内存限制只覆盖顺序和空间计算，不包含后续日志文件回放。

`RecoveryScale` 以真实本地文件构造连续恢复日志，运行生产代码读取、校验、JSON 解码和新进程重开；注入中间副本标识重复必须拒绝。构造样本时不执行真实持久化事务写入，也没有调用 PhotoKit。

`scale_transfer.py` 使用生产导出/上传/续传代码及真实本地平铺文件，AFC 端点为模拟边界。每个资产/资源有独立内容和 hash；混合普通、Live 配对、编辑资源角色，文件名刻意重复、来源 ID 顺序反向。内容是合成二进制，**不代表实际 HEIC/MOV 解码、Live 播放或真实格式往返通过**。10%/50%/90% 注入服务读取中断；上传中途停止后验证精确偏移、旧日志不变和最终清单/全资源一致。峰值内存包含模拟端持有的小文件，不能推断实际 USB 或 iPhone 内存。

## 不可省略的真机验收与限制

当前 Mac USB-only 检测没有设备（-3）。本轮没有执行照片库写入，没有将私人照片传到云端。此前真实 20 项与 Live 样本证据保留，不能推广成新版五万张真机通过。

恢复端仍在每次事务执行完整日志及 PhotoKit 成员前缀复核，总工作量随规模增长较快；五万张真实恢复吞吐未验收。采用增量恢复账本或 PhotoKit 变更观察属于下一项独立优化，需要保留外部变更、崩溃歧义和重复创建保护，不能简单降低检查频率。原始资源、暂存和恢复回读也需要实际磁盘空间；64MiB 清单上限仍有效，资源组合特别多的超大清单会明确拒绝，不保证所有 50000 张组合都能导入。

真实验收必须覆盖完整五万张资源数据、Photos 最终成员与位置、逐份原图 hash、Live 播放、编辑效果、容量、后台/返回、拔线及重连。未执行项保持 NOT_RUN，不能用模拟吞吐代替 USB MB/s。


## Large-manifest memory follow-up

The first 50000-file run passed all integrity/order/interruption checks but peak RSS was 1391517696 bytes, including in-memory synthetic peers. This prompted removal of two redundant full JSON object graphs during upload publication. The source manifest is still checked byte-for-byte and every media resource is rehashed. This is metadata reuse only, not a cached-media integrity shortcut. An identical full-size rerun measures the result; figures will be recorded after completion.


## Final measured result and delivery state

Both complete 50000-asset / 82500-resource synthetic file round trips passed the order/integrity and interruption checks. Peak RSS in the identical runner: 1391517696 -> 1022763008 bytes (-26.5002%), including fake peers. Runtime numbers are not a controlled USB speed comparison; export code was unchanged in the memory follow-up and cache/concurrent disk load differed.

Local Mac 0.3.14/build18 is installed and native About/gallery smoke checks passed. Full local gate and Python 92 tests passed. Final 0.3.14 cloud publication and iPhone IPA are incomplete because the desktop browser bridge failed; #112 is the prior 0.3.13 source. Exact records: [final memory evidence](evidence/m4-large-batch-memory-0.3.14.json).

This is not a completed 50000-photo product acceptance: real Photos writes/order/format playback, real USB speed, phone staging capacity and large-album restore throughput remain unverified. Full-prefix-per-transaction restore validation and the 64MiB manifest bound are material remaining limits.
