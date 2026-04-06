---
layout: post
title: 从 PostgreSQL fsync EIO 失败处理说起
summary: 从 PostgreSQL fsync EIO 失败处理说起

---

2018 年, PostgreSQL 社区发现了一个存在了 20 年的严重问题: 当 `fsync()` 失败时, PostgreSQL 的处理方式可能导致**静默数据丢失**. 这个被称为 "fsyncgate" 的事件, 不仅揭示了 PostgreSQL 自身的架构缺陷, 更暴露了 Linux 内核, 文件系统与数据库之间在 I/O 错误处理上的深层矛盾.

在云原生时代, 这个问题的影响被显著放大 -- 因为云存储上 I/O 错误的发生频率远高于本地存储. 本文将完整梳理这一问题的发现, 讨论, 解决方案, 以及它在云原生环境下带来的新挑战.

#### 问题的发现

##### Craig Ringer 的报告

2018 年 3 月底, Craig Ringer 在 pgsql-hackers 邮件列表中报告了一个用户遭遇的数据损坏案例 [1]. 问题的核心在于: PostgreSQL 使用 Buffered I/O, 在写入数据后调用 `fsync()` 来确保数据落盘. 当 `fsync()` 失败时, PostgreSQL 的做法是重试 `fsync()` -- 然而第二次 `fsync()` 返回了成功, 但数据实际上并没有写入磁盘.

为什么会这样? 因为 Linux 内核在 `fsync()` 失败后, 会将相关的 dirty page 标记为 **clean** -- 即使数据并没有成功写入磁盘. 当 PostgreSQL 重试 `fsync()` 时, 内核发现没有 dirty page 需要刷盘, 直接返回成功. PostgreSQL 以为数据已经安全落盘, 继续截断了 WAL -- 数据就这样丢了.

Craig Ringer 的结论很直接: **Pg should PANIC on fsync() EIO return.**

##### PostgreSQL 社区的反应

PostgreSQL 开发者们对此非常愤怒. Tom Lane 称之为 "kernel brain damage", Robert Haas 认为这种行为 "100% unreasonable". 他们最初认为内核的正确行为应该是: `fsync()` 失败后保持 page 的 dirty 状态, 以便后续重试.

但随着讨论深入, 事情变得复杂了.

#### 为什么内核要把失败的 page 标记为 clean?

##### USB 拔出场景

Ted Ts'o (ext4 maintainer) 给出了内核行为背后的主要理由: 触发 `fsync()` EIO 最常见的场景是用户拔掉 USB 盘.

当用户往 USB 盘上拷贝大文件时突然拔掉设备, 内核 page cache 中可能有 GB 级的 dirty page 等待写入一个已经不存在的设备. 如果保持这些 page 为 dirty, 它们永远无法被写出去, 也无法被内存回收器释放, 最终可能导致系统 OOM.

##### 内存管理的架构约束

Neil Brown 解释了更底层的问题: Linux 的内存管理建立在一个核心假设之上 -- dirty page 可以通过 writeback 变成 clean page, clean page 可以被回收释放. 如果允许 "永远 dirty 但永远写不出去" 的 page 存在, 整个内存管理子系统的假设就被打破了, 可能导致死锁.

##### FreeBSD 的做法

有趣的是, FreeBSD 确实做了 Linux 没做的事情: `fsync()` 失败后保持 page 为 dirty, 后续 `fsync()` 会重新尝试写入. 这个行为从 1999 年就存在了, 证明 "保持 dirty" 在技术上是可行的. 但 FreeBSD 也做了妥协 -- 如果设备彻底消失, 较新版本会最终放弃这些 page.

##### 本质是需求冲突

内核开发者面对的是所有 Linux 用户: 桌面, 手机, IoT, 服务器. 对于 99% 的场景, USB 拔出后的内存回收比数据库的 `fsync()` 可靠性重要得多. 数据库开发者面对的是数据持久化的最严格要求. 两个需求在 Buffered I/O 语义下是根本矛盾的. Linux 选择了优先照顾大多数场景, 把数据库推向 Direct I/O.

#### PostgreSQL 的解决方案

##### PANIC on fsync failure

2018 年 11 月, PostgreSQL 合入了 commit `9ccdd7f6`: "PANIC on fsync() failure." [2]. 作者是 Craig Ringer, Thomas Munro 做了调整. 核心逻辑如 commit message 所述:

> On some operating systems, it doesn't make sense to retry fsync(), because dirty data cached by the kernel may have been dropped on write-back failure. In that case the only remaining copy of the data is in the WAL. A subsequent fsync() could appear to succeed, but not have flushed the data. Therefore, violently prevent any future checkpoint attempts by panicking on the first fsync() failure.

这个改动被 backport 到了所有受支持的版本 (PG 11, 10, 9.6, 9.5, 9.4), 对应的 GUC 参数是 `data_sync_retry`, 默认为 `off` (即 fsync 失败直接 PANIC).

##### PANIC 策略的代价

这个方案在正确性上是安全的 -- 避免了静默数据损坏. 但代价是可用性下降: 一次 I/O 错误就导致整个数据库实例 crash, 需要进行 WAL recovery, 可能耗时数分钟到数十分钟.

##### WAL 本身也走 Buffered I/O

值得注意的是, PostgreSQL 的 WAL 在默认配置下也是通过 Buffered I/O 写入的 (`wal_sync_method` 默认为 `fdatasync`). PANIC 后依赖 WAL replay 恢复数据, 但 WAL 本身的写入也经过了 page cache. 虽然 PostgreSQL 对 WAL 的 fsync 失败处理更早就做了 PANIC, 但仍存在 "后台 writeback 失败 → page 被标记为 clean → fdatasync 返回成功" 的边界窗口. 4.13+ 内核的 errseq_t 机制缓解了这个问题, 但无法根治.

##### Direct I/O: 尚未落地的根本解决方案

内核开发者 (Dave Chinner, Ted Ts'o 等) 一致认为, 正确的长期方案是 PostgreSQL 切换到 Direct I/O, 绕过 page cache, 让数据库自己完全控制 I/O 和错误处理. PG 开发者也承认这是正确方向, 但 Andres Freund 称之为 "a metric ton of work" -- 至今仍未落地.

#### 不仅仅是 PostgreSQL 的问题

##### Wisconsin 大学的系统性研究

Wisconsin 大学 Arpaci-Dusseau 组在 USENIX ATC 2020 发表了论文 "Can Applications Recover from fsync Failures?" [3], 系统性测试了五个广泛使用的数据管理应用在 fsync 失败时的行为.

**LevelDB**: LevelDB 使用 CRC 校验和检测损坏的 log entry. 但问题在于, fsync 失败后数据留在 page cache 中, 当前进程的读操作能正常返回新值. 只有当 page 被 evict 或应用重启后, CRC 才检测到损坏, LevelDB 拒绝这条 log entry, 出现 KeyNotFound 或 OldVersion 错误 -- 一个 "薛定谔" 状态.

**SQLite (Rollback Journal 模式) **: SQLite 往 rollback journal 写原始页面备份时如果 fsync 失败, journal 中的数据实际没有落盘. 后续如果需要回滚事务, SQLite 会从 journal 中读取数据 -- 如果 page 已被 evict, 读到的是垃圾数据, SQLite 用这些垃圾覆盖了数据库中原本正确的页面, 造成数据库损坏.

**Redis**: 甚至不检查 `fsync()` 的返回值.

论文结论: 尽管这些应用使用了多种错误处理策略 (CRC, journal header 顺序写入等), 但没有一个是充分的. 只要使用 Buffered I/O, fsync 错误不被正确处理, 数据持久性就无法保证.

##### 为什么这些数据库没有在 fsync 失败后 crash?

原因是多方面的:

1. **认知盲区**: 2018 年之前, 几乎所有数据库开发者都不知道内核会在 fsync 失败后丢弃 dirty page.
2. **本地存储极少触发**: EIO 在本地 SSD/HDD 上几乎只在物理损坏时才出现, 一辈子可能遇不到.
3. **crash 后未必能恢复**: LevelDB 的 log 和 SQLite 的 journal 也走 Buffered I/O, crash 后的 recovery source 本身可能就是损坏的.
4. **产品约束**: SQLite 和 LevelDB 是嵌入式数据库, 因一次瞬态 I/O 错误就把宿主应用杀掉, 在移动端和桌面端不可接受.

#### PostgreSQL 的其他类似问题

fsyncgate 并非 PostgreSQL 第一次因为对 OS 层行为做了过多假设而踩坑:

##### Torn Page 问题

PostgreSQL 使用 8KB 页, 但 Linux 文件系统通常用 4KB 页. 写一个 8KB 页时如果系统 crash, 可能只有 4KB 被写入, 页面混合了新旧数据. PostgreSQL 通过 Full Page Writes (FPW) 机制来解决这个问题 -- 在 checkpoint 后每个页面第一次被修改时, 把完整的 8KB 页面写入 WAL.

我在之前的工作中用 Claude Code 在 PostgreSQL 中实现了 MySQL 风格的 Doublewrite Buffer (DWB), benchmarks 显示 DWB 的性能是 FPW 的约 2.3 倍 (write_only 128 并发场景) [4]. DWB 的优势在于它在后台路径执行, 不影响前台 SQL latency, 并且不与 Checkpoint 频率冲突.

##### LVM Write Barrier 问题

Linux 2.6.33 之前, device-mapper (LVM 的基础) 对 write barrier 的支持不完整. 文件系统发出的 write barrier 被 device-mapper 层静默吞掉, 底层磁盘缓存中的数据顺序不确定. 断电后可能丢失最近写入的文件系统元数据和 journal 数据 (每块 SATA 盘可能丢失 32MB), 导致大量文件系统损坏和数据丢失 [5].

##### glibc locale 变更导致索引损坏

通过 pg_basebackup 或 streaming replication 从一个 OS 版本迁移到另一个版本时 (如 CentOS 7 → CentOS 8), 如果底层 glibc 的 locale collation 实现发生变化, 会导致 B-tree 索引静默损坏 [6].

这些问题的共同根源是: PostgreSQL 的 Buffered I/O 架构对 OS 层行为做了过多乐观假设.

#### 云原生时代: 问题被显著放大

##### EIO 的语义变化

在本地存储时代, `fsync()` 返回 EIO 几乎只在磁盘物理损坏时才会发生 -- 这是一个极其罕见的永久性故障. 本地 SSD 的 I/O 路径很短: 应用 → 内核 page cache → 文件系统 → block 层 → 磁盘控制器 → 物理介质. 中间环节很少, 能出错的基本就是物理介质本身.

但在云存储环境下, I/O 路径变成了: 应用 → 内核 page cache → 文件系统 → block 层 → virtio 驱动 → 宿主机内核 → 网络栈 → 交换机 → 存储节点 → 分布式存储引擎 → 多副本复制 → 物理介质. 这条路径上每一个环节都可能产生瞬态错误: 网络超时, 交换机切换, 存储节点 GC, 虚拟机热迁移等.

**关键区别在于瞬态性**: 本地存储的 EIO 几乎总是永久性的; 云存储的 EIO 大量是瞬态的 -- 100ms 到几秒后可能就会自动恢复.

##### PlanetScale 的实证数据

PlanetScale 在 2025 年 3 月发表的 "The Real Failure Rate of EBS" [7] 提供了大规模生产数据的实证. AWS 官方文档承认 gp2/gp3 EBS 卷在一年中有 1% 的时间性能低于预期 -- 每天约 14 分钟, 每年约 86 小时. 这个降级率远超单块本地磁盘或 SSD.

更关键的是规模效应: 对于一个 256 shard, 每个 shard 一主两从共 768 个 gp3 EBS 卷的大型数据库, 在任何给定时间有至少一个节点遇到生产级影响事件的概率是 99.65%. 即使使用价格 4-10 倍的 io2 卷, 一年中大约三分之一的时间仍然会处于某种故障状态.

PlanetScale 最终的选择是构建 PlanetScale Metal, 用 shared-nothing 架构配合本地存储来替代 EBS.

##### 来自中国云的实践反馈

Hacker News 上也有用户分享了中国云环境的经验: 在阿里云, 腾讯云, 华为云上, 每块云盘每个月至少会经历一次致命故障或断连, 最终不得不放弃在云盘上直接运行数据库负载 [8].

##### 对 PostgreSQL PANIC 策略的影响

结合 PostgreSQL 的 fsync-failure-PANIC 行为和云存储天然更高的 I/O 错误率, 在云上运行 PostgreSQL 面临显著的可用性风险: 数据库可能因为一次几百毫秒后就自动恢复的网络抖动而 PANIC 整个实例, 每次 PANIC 后的 WAL recovery 可能需要数分钟到数十分钟 -- 这对于一个本来只持续几百毫秒的瞬态故障来说是完全不对等的代价.

#### CloudJump: 云存储与数据库的系统性适配

在我们发表于 VLDB 2022 的论文 CloudJump [9] 中, 我们系统性地分析了云存储与本地存储的特性差异对数据库设计的影响, 并提出了七条优化准则. 其中与本文讨论直接相关的几个点:

**I/O 延迟与隔离性问题**: 云存储的 I/O 延迟显著高于本地 SSD, 且不同 I/O 请求之间的隔离性较低. CloudJump 提出了多 I/O 任务队列和优先级调度机制, 为 WAL 写入保留专用的 Private 队列, 确保关键 I/O 路径的性能.

**WAL 写入优化**: 针对云存储高延迟的特点, CloudJump 提出了 Redo 日志分片和 I/O 任务并行打散 -- 将 WAL 按 page 分片写入不同文件, 利用分布式存储的聚合带宽. 这些优化使得 WAL 写入路径对云存储的瞬态延迟抖动有更好的容忍度.

**I/O 格式对齐**: 云存储有更大的 block size (4-128KB), 传统的 I/O 对齐策略不适合. CloudJump 提出在数据库内核层面对 WAL I/O 和 Data I/O 进行对齐, 减少 read-on-write 问题.

CloudJump 的优化框架在 PolarDB 和 RocksDB 上均获得了显著的性能提升, 验证了针对云存储特性进行数据库层面系统性适配的必要性和有效性.

然而, CloudJump 主要关注的是性能优化层面. fsyncgate 揭示的问题则处于更深的正确性层面: **云存储的瞬态 EIO 需要数据库有完全不同的错误处理语义**. 这是 CloudJump 框架的一个自然延伸方向.

#### 面向云原生的 fsync 错误处理

##### 核心洞察

**在云原生环境中, 大部分 EIO 是瞬态的, 100ms 到几秒后就会恢复. ** 这改变了 fsync 失败处理的整个决策框架.

PostgreSQL 当前的 PANIC 策略本质上是一个悲观策略: 把所有 EIO 都当作最坏情况处理. 这在正确性上是安全的, 但在云环境下代价过高.

##### 改进思路: 区分 WAL 和数据文件

要在 PANIC 和忽略之间找一个中间地带, 需要分开讨论 WAL 文件和数据文件两种情况 -- 它们面临的约束完全不同.

##### WAL 文件的 fsync 失败

WAL 文件的 fsync 失败后, PANIC 是正确的, 没有优雅重试的空间. 原因很明确: WAL 在默认配置下走 Buffered I/O (`wal_sync_method=fdatasync`). fsync 失败后, 内核将这些 WAL page 标记为 clean. WAL 是 append-only 的, 你就算重新 `write()` 同样的内容, page cache 认为这部分内容是 clean 的 (没有被修改), 不会重新标记为 dirty, 后续的 fsync 也不会触发任何刷盘操作. 数据就这样丢了, 无法恢复.

除非 WAL 路径改用 Direct I/O 或 `O_SYNC`/`O_DSYNC` -- 在这些模式下, write 失败就是真的失败, 重试 write 就是真的重写, 不存在 page cache 状态不一致的问题.

##### 数据文件的 fsync 失败

数据文件和 WAL 有一个关键区别: WAL 是 append-only 的, 而数据文件是 in-place update 的. 这意味着数据文件的同一个 page 会被反复修改. 那么一个自然的问题是: fsync 失败后, 虽然内核把这些 page 标记成了 clean, 但既然数据文件的 page 是可以被重新修改的, 有没有办法通过重新写入这些 page, 让它们重新变成 dirty, 从而在下一次 fsync 时被刷到盘上?

这个思路理论上是可行的 -- 毕竟对于 in-place update 的文件, 你对同一个 offset 重新 `write()`, 内核会把对应的 page 重新标记为 dirty. 这和 append-only 的 WAL 不一样: WAL 重新写同样的内容, page cache 认为没有修改; 但数据文件重新写同一个 page 的内容, page cache 会认为这是一次新的修改.

但深入分析后会发现, 要把这个思路落地, 面临一系列非常棘手的问题:

**哪些 page 需要重写?** `fsync()` 返回的 EIO 只告诉你 "这个文件的某些 page 没刷成功", 不告诉你具体是哪些 page. 要实现精确重试, PG 需要在 checkpoint 刷脏时额外记录 "本次 checkpoint 写出了哪些 page", 这是目前没有的机制.

**shared buffers 中的状态已经不对了.** 这些 page 在 shared buffers 中可能已经不再是 dirty 了 -- 因为 `write()` 调用本身是成功的, PG 认为它们已经被写出到 page cache. 要重新刷这些 page, 需要在 shared buffers 中把它们重新标记为 dirty, 再重新 `write()` + `fsync()`. 但前面说了, PG 不知道哪些 page 受影响.

**buffer 替换问题.** 即使你选择不推进 checkpoint LSN, 如果这些 page 在 shared buffers 中已经被标记为 clean, 它们可能被 buffer pool 的替换算法选中并 evict 掉. 一旦被 evict, 这些 page 的内存副本就丢了 -- 盘上又是旧数据 -- 最终还是只能从 WAL replay 来恢复, 这就等价于一次延迟的 PANIC + recovery.

要让 "不推进 + 重试" 在数据文件上真正工作, 你需要同时满足:

1. 不推进 checkpoint LSN, 保留对应的 WAL
2. 记录本次 checkpoint 写出了哪些 page
3. fsync 失败后把这些 page 在 shared buffers 中重新标记为 dirty
4. 这些 page 不允许被 evict (需要 pin 住)
5. 重新 `write()` + `fsync()` 来重试

这实际上是一个运行时的 "mini crash recovery" -- 复杂度很高. 而且即使实现了上述所有机制, 在 Buffered I/O 下仍然面临一个根本问题: 如果底层瞬态错误还没恢复, 下一次 fsync 可能又失败, page 又被标记为 clean, 陷入循环. 所以结论是: 虽然数据文件的 in-place update 特性在理论上给重试打开了一扇门, 但要真正走通这条路, 工程复杂度极高, 在 Buffered I/O 下很难做到可靠.

##### 根本出路: Direct I/O

分析到这里, 结论其实很清楚: **在 Buffered I/O 下, 无论是 WAL 还是数据文件, fsync 失败后的优雅重试都非常困难** -- 因为 page cache 的状态和 shared buffers 的状态都可能已经不一致了. PANIC 虽然粗暴, 但它通过 "回退到上一个成功的 checkpoint + WAL replay" 绕过了所有这些状态一致性问题.

要做到优雅重试, 最终还是绕不开 Direct I/O. 使用 `O_DIRECT` 时, `write()` 失败就是真的失败 (不存在 "write 成功但 fsync 失败" 的中间状态), 重试 `write()` 就是真的重写, 数据库对 I/O 的控制力完全不同. 这也是 MySQL/InnoDB 的做法 -- `innodb_flush_method=O_DIRECT` 下, 数据文件的 I/O 不经过 page cache, 错误处理的语义清晰得多.

##### 云厂商的独特优势

对于同时掌握存储层和数据库层的云厂商, 除了推动 Direct I/O 之外, 还有另一个维度的解法: 让存储层向数据库提供更丰富的错误语义 -- 区分瞬态错误和永久性错误, 提供预计恢复时间, 甚至在存储层面实现 "transient-EIO-tolerant" 语义 (瞬态 EIO 在几秒内自动恢复时不向上层报错). 这是开源社区在一个盲盒般的 OS 存储栈上难以做到的事情.

#### 内核与数据库的沟通鸿沟

##### 长期缺失的文档和指导

2019 年 Linux Plumbers Conference 首次举办了 Databases 微型会议, SQLite 作者 Richard Hipp 和 PostgreSQL 的 Andres Freund 都在会上表达了对 Linux I/O 接口文档缺失的不满 [10].

Andres Freund 的发言直击要害: "如果 fsync 失败了重试会怎样? 原来的数据会被重试还是被丢弃? 应用开发者必须去读内核邮件列表的讨论帖才能搞清楚. 你不能在只有这么差的指导文档下还指责别人写了烂代码. "

##### 推荐阅读

以下资源有助于深入理解内核与数据库的交互问题:

- LWN: "PostgreSQL's fsync() surprise" (2018) [1]
- LWN: "Better guidance for database developers" (LPC 2019) [10]
- LWN: "A discussion between database and kernel developers" (LSFMM 2014) [11]
- LWN: "The end of block barriers" (2010) [12]
- Dan Luu: "Files are hard" and "Filesystem errors" series [13][14]
- OSDI 2014: "All File Systems Are Not Created Equal" [15]

#### 总结

从 fsyncgate 到 LVM write barrier, 从 torn page 到 glibc locale 损坏, PostgreSQL 的历史反复说明了一个道理: 依赖 OS 层的隐式保证是危险的. 在本地存储时代, 这些问题被低错误率掩盖了; 在云原生时代, 它们被高频的瞬态 I/O 错误暴露无遗.

MySQL/InnoDB 的 `O_DIRECT` + Doublewrite Buffer 架构在这些问题上有天然优势, 但也并非完美. 真正的解决需要存储层和数据库层的协同演进: 更丰富的错误语义, 更精细的 I/O 控制, 以及对云存储瞬态错误的正确处理.


#### 参考资料

1. Jonathan Corbet, "PostgreSQL's fsync() surprise", LWN.net, April 2018. https://lwn.net/Articles/752063/
2. PostgreSQL commit 9ccdd7f6, "PANIC on fsync() failure", November 2018. https://www.postgresql.org/message-id/E1gObQY-00021d-L6@gemulon.postgresql.org
3. Anthony Rebello et al., "Can Applications Recover from fsync Failures?", USENIX ATC 2020 / ACM Transactions on Storage 2021. https://www.usenix.org/conference/atc20/presentation/rebello
4. baotiao, "Claude Code 改写 PostgreSQL 内核, Full Page Write vs Doublewrite Buffer, 性能差 3 倍", February 2026. https://baotiao.github.io/2026/02/05/fpw-dwb.html
5. "LVM dangers and caveats". https://www.baeldung.com/linux/logical-volume-management-problems
6. PostgreSQL Wiki, "Corruption". https://wiki.postgresql.org/wiki/Corruption
7. PlanetScale, "The Real Failure Rate of EBS", March 2025. https://planetscale.com/blog/the-real-fail-rate-of-ebs
8. Hacker News discussion on EBS failure rates. https://news.ycombinator.com/item?id=43399811
9. Zongzhi Chen, Xinjun Yang, et al., "CloudJump: Optimizing Cloud Database For Cloud Storage", VLDB 2022. https://baotiao.github.io/2022/07/04/polardb-innodb.html
10. Jonathan Corbet, "Better guidance for database developers", LWN.net, LPC 2019. https://lwn.net/Articles/799807/
11. Mel Gorman, "A discussion between database and kernel developers", LWN.net, LSFMM 2014. https://lwn.net/Articles/590214/
12. Jonathan Corbet, "The end of block barriers", LWN.net, August 2010. https://lwn.net/Articles/400541/
13. Dan Luu, "Files are hard". https://danluu.com/file-consistency/
14. Dan Luu, "Filesystem errors". https://danluu.com/filesystem-errors/
15. Thanumalayan Sankaranarayana Pillai et al., "All File Systems Are Not Created Equal: On the Complexity of Crafting Crash-Consistent Applications", OSDI 2014.
16. PostgreSQL Wiki, "Fsync Errors". https://wiki.postgresql.org/wiki/Fsync_Errors
17. Percona, "PostgreSQL fsync Failure Fixed – Minor Versions Released Feb 14, 2019". https://www.percona.com/blog/postgresql-fsync-failure-fixed-minor-versions-released-feb-14-2019/
18. USENIX, "Detecting Fail-Slow Failures in Large-Scale Cloud Storage Systems (PERSEUS)", 2023. https://www.usenix.org/publications/loginonline/detecting-fail-slow-failures-large-scale-cloud-storage-systems

