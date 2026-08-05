---

layout: post
title: CloudJump III\: Optimizing Cloud Databases for Tiered Storage(SIGMOD 2026)
summary: 如何让数据库真正利用好这个层级结构, 把热数据放在快的介质上, 把冷数据放在便宜的介质上, 同时保证性能稳定且不牺牲正确性, 这就是 CloudJump III 要回答的问题.
---



在云原生数据库的演进中, 计存分离让计算层和存储层可以独立扩展, 共享存储让多个计算节点访问同一份数据成为可能.

在《CloudJump: Optimizing Cloud Databases for Cloud Storages》(VLDB 2022) 中, 我们分析了存储介质从本地盘变成云存储之后, 数据库在 IO 路径上需要做的一系列重新设计;

在《CloudJump II: Optimizing Cloud Databases for Shared Storage》(SIGMOD 2025) 中, 我们提出 MVD (Multi-Version Data) 技术, 解决了共享存储架构下多计算节点的数据一致性问题. 

沿着这条路线继续往前走, 一个自然的问题浮现出来:

云上的存储从来就不是单一介质, 而是一个天然的层级结构——从本地 NVMe SSD, 到网络块存储 ESSD, 再到几乎无限容量的对象存储 OSS, 每一层都处在成本、延迟、吞吐曲线上的不同位置. 

如何让数据库真正利用好这个层级结构, 把热数据放在快的介质上, 把冷数据放在便宜的介质上, 同时保证性能稳定且不牺牲正确性, 这就是 CloudJump III 要回答的问题.

这篇论文已经发表在 2026 SIGMOD 上, 感兴趣的同学可以下载阅读:《CloudJump III: Optimizing Cloud Databases for Tiered Storage》



#### 云存储的天然层级

现代云数据库运行在一个层级化的存储体系之上. 以典型的云厂商产品为例, 各层的延迟和成本大致如下:

![image-20260805110807731](https://raw.githubusercontent.com/baotiao/bb/main/uPic/image-20260805110807731.png)



可以看到, 离计算越近的层级延迟越低、带宽越高, 但成本也越贵. 随着用户数据量的持续增长, 存储开销 (包括 DRAM) 已经成为数据库服务总拥有成本 (TCO) 的主要构成. 所以问题已经不是"要不要做分层", 而是"如何做分层": 在动态变化的 OLTP 负载下, 数据放置策略要如何保证性能和成本都稳定可控.



#### 现有分层方案的困境

冷热分离的想法并不新, 业界已有大量实践: 主机侧的 NVMe 缓存 (dm-cache、bcache、LVM Cache), ILM/HSM 生命周期管理管道, 存储阵列和云服务的自动分层, 以及以对象存储为底座、只把最热的块留在 SSD 上的设计. 但这些方案有一个共同的特点: 它们都工作在数据库内核之外——块层、文件系统层或者网关层. 它们能观察到 IO 模式, 却看不到存储引擎的内部状态, 而这恰恰是正确、高效分层的关键. 在内核之外分层会造成系统性的误判:

1. 最热的页面常驻在 DRAM Buffer Pool 中, 几乎不产生外部 IO, 在基于 IO trace 的分析中反而显得"冷";
2. 结构上重要的索引页、元数据页会被过早地降级到慢介质;
3. ILM/HSM 的粒度太粗, 一个小的读取会触发整个文件或大 extent 的召回 (recall), 周期性的批量迁移又会和前台 IO 争抢带宽, 引发召回风暴;
4. 分层的数据移动和内核的恢复、备份协议是解耦的, 不与 LSN 语义、快照协议协同, 零停机场景下的正确性很难保证.

分层之后, 每一次快层 miss 的代价是残酷的: 目标页要么暂时不可用, 要么必须同步地从慢几个数量级的层级取回, 给查询注入不可控的抖动. 手工的时间分区、表级重组都是粗粒度且被动的, 跟不上分钟级的负载变化. 

所以运维侧真正需要的, 是一种既保留多层存储性能成本收益, 又能约束 miss 代价、不增加运维脆弱性的分层机制.

#### CloudJump III: 引擎集成的分层设计

CloudJump III 的核心思路是把分层决策搬进存储引擎内部, 在 Buffer Manager 的天然控制点 (eviction 和 flush) 上做数据放置决策, 利用引擎可见的元信息——页类型和存活时间、页表关系和配额、临时表识别、脏页状态、Buffer Pool 驻留情况——来决定数据的准入和写入路由. 这个设计我们称之为 eviction-centric、engine-aware.

整体架构划分成四层, 并明确了缓存层 (易失) 与存储层 (持久) 的边界:

<img src="https://raw.githubusercontent.com/baotiao/bb/main/uPic/image-20260805110741707.png" alt="image-20260805110741707" style="zoom:67%;" />

1. **InnoDB Buffer Pool (DRAM)**: 传统的内存缓存, 持有热页, 在 eviction/flush 这些天然控制点上触发分层决策;
2. **Buffer Pool Extension (BPE, 本地 SSD)**: Buffer Pool 的只读扩展, 只缓存干净页, 属于易失的缓存层, 丢失不影响持久性;
3. **OSS Buffer (ESSD)**: 存储层的前端, 接受页面刷脏的写入, 把页粒度的更新聚合成块级写入, 在数据被同步到远端之前先在这里持久化, 既降低写放大, 也把对象存储与小随机 IO 隔离开;
4. **OSS 对象存储**: 最终的持久层, 低成本、容量无限, 通过 HTTP PUT/GET 访问.

读路径是一个层级化的流水线: DRAM → BPE → OSS Buffer → 远端 OSS, 逐层回退, 命中后向上提升 (promotion).

写路径则是一个多阶段的管道: Buffer Pool 刷脏先落到 OSS Buffer 对应的 ESSD 上 (近端持久化), 之后由后台线程把脏页合并成 2 MB 的对象, 以 append-only 的版本化方式异步 PUT 到远端 OSS. 每张 OSS-backed 表被逻辑切分成固定大小的 2 MB 对象 (128 个 16 KB 页), OSS Buffer 为每个对象分配一个 block, 内部结构参考 InnoDB Buffer Pool 的页管理逻辑: page-to-block hash 做快速查找, LRU 做替换, flush list 追踪待写回 IO.



#### BPE: 基于 S3-FIFO 的准入策略

本地 SSD 作为 Buffer Pool 的扩展缓存, 最大的敌人是缓存污染: 大量只被访问一次的页 (one-hit wonder) 被无差别写入 SSD, 既浪费写寿命, 又挤占了真正可复用页的空间. BPE 的设计借鉴了 S3-FIFO 的选择性准入和 second-chance 思想:

在 DRAM Buffer Pool 中, 传统的 young/old 双链表之外增加一个 **ghost 链表**, 只记录最近被淘汰页的 ID (纯元数据, 不含数据). 页从 old 链表淘汰时先进入 ghost; 只有当它在 ghost 中被再次访问, 证明了自己的复用价值, 才会被提升进 BPE 的 SSD 空间. 这个延迟的、基于复用验证的准入机制, 天然过滤掉了 one-hit 页. BPE 内部则采用改良的 CLOCK 替换算法, 用环形指针和 second-chance bit 替代 LRU 链表, 降低同步开销的同时让淘汰顺序对齐 SSD 布局, 实现顺序写、减少磨损.

消融实验里这个策略的效果很直接: 相比 full-admit (全部准入), ghost 准入策略把 TPS 提升了 12%, 命中率从 63.4% 提升到 72.7%, 而 BPE 的 IOPS 从 22369 降到 2082, 下降约 91%——更少的细粒度写入, 更平稳的写回.

工程上 BPE 还有两个值得一提的细节: 一是元数据压缩, 64 GB 的 BPE 实例只需要约 184 MB 的控制元数据, 且消除了 per-page 的锁结构; 二是 chunk-based resizing, BPE 空间按 64 MB 的 chunk 划分, 可以秒级在线增减, 热点实例可以临时扩容缓存, 用完释放, 不需要重启.



#### OSS Buffer: 写合并与 crash consistency

![image-20260805165827221](https://raw.githubusercontent.com/baotiao/bb/main/uPic/image-20260805165827221.png)

OSS Buffer 的职责是把数据库的页级写入转换成对象存储友好的块级写入. 脏块的刷写走一个三阶段的异步流水线: 

先更新块级元数据 (记录版本、标记 in-flight), 再把块内脏页合并成连续的 2 MB 段异步 PUT 到 OSS (每次刷写携带单调递增的版本号), 成功后块状态从 Dirty 转为 Clean 进而 Free.

这里的关键是 crash consistency 的保证. 同一个逻辑页可能同时存在于内存、BPE 和 OSS Buffer 中, CloudJump III 通过一组互补的写序约束保证可恢复性: **本地写入时, 元数据先于数据更新** (记录意图); **远端同步时, 数据先传输, 元数据后标记 clean**. 这种交叉的顺序设计保证了任何一个块要么完整持久, 要么可以安全重放——元数据更新了但数据缺失, 恢复时重放 redo; 数据在但元数据陈旧, 重新刷写即可, 两条路径都是幂等的.

刷写调度上结合了批量聚合、时间延迟 (避免热块反复写)、水位监控和限速 (在 OSS QPS 和多租户公平性约束下调节吞吐). 干净块只有在 OSS 同步完成后才成为淘汰候选, 保证空间复用永远发生在持久化之后.

#### 快照版本与零停机备份

![image-20260805165812162](../Library/Application Support/typora-user-images/image-20260805165812162.png)

分层之后, 备份和恢复的正确性是最容易被忽视也最容易出问题的地方.

CloudJump III 用一个快照版本协议把分层状态的演进和备份协同起来. 系统维护一个全局的 next_snapshot_version, 备份开始时短暂加锁、递增版本号, 之后所有 OSS 写入都携带这个版本; 对每个 2 MB 对象, 如果在新快照纪元之后被修改, 则写出一个新版本的对象 (如 file_0002_v2), 旧版本保留给备份读取. 每张表维护一个 .meta 文件, 记录每个块的 dirty bit 和版本号, 增量备份只复制自上次备份以来变化的对象.

备份流程走 lock–version–copy 的序列: 锁定元数据固定版本视图, 递增快照计数, 然后通过 OSS 的 fast-copy API 做桶内影子拷贝——fast-copy 只复制对象元数据不搬数据, 所以即使是数 TB 的表, 快照创建也在秒级完成. 

实测数据: CloudJump III 的快照创建耗时 0.64 秒, 接近纯 ESSD 的 0.52 秒, 远快于纯 OSS 路径的 53.73 秒, 而备份和恢复总时长与 OSS baseline 持平 (瓶颈在远端带宽, 分层本身没有引入额外开销).

#### 实验结果

我们在两种规格上评估了 CloudJump III: 小规格 (8 核、1 GB Buffer Pool、50 GB 数据) 和大规格 (64 核、100 GB Buffer Pool、5 TB 数据), 快层容量覆盖数据集的 5% 到 50%, 负载包括 Sysbench、YCSB (Zipf 偏斜 0.8–2.0)、Voter 以及一个来自阿里云线上游戏客户的真实负载 (大 BLOB 更新 + 突发写入).

几个有代表性的结论:

1. TPS 随缓存比例和偏斜度单调上升, 在热数据能装进快层时出现明显的拐点. 中等偏斜 (Zipf α ≥ 1.4) 下, 20%–30% 的缓存比例就能逼近全 ESSD 的吞吐上界, 而单位成本的性能 (CP) 显著更高;
2. Voter 负载在 64 线程下维持全 ESSD 吞吐的 79%–80%, 游戏负载则全程保持在 baseline 的 ±5% 以内, 在中等并发下甚至反超 3%–4%——大写入直接 bypass 到 ESSD 避免争抢共享刷写队列, 小更新由 OSS Buffer 合并成 2 MB 对象平滑带宽需求;
3. 消融实验验证了各机制的贡献: ghost 准入 (+12% TPS, −91% BPE IOPS)、临时表排除 (短时分析型突发不再冲击远端存储带宽)、DDL/BLOB bypass (消除了 DDL 阶段前台吞吐的深度下跌).

#### 一些经验

三年的线上部署给了我们一些超出论文本身的体会:

**快层应该是共享缓存, 而不是专属存储.** 按表刚性划分快层容量会导致容量利用低效和性能不稳定. CloudJump III 把快层重新解释为全局共享的缓存, 由统一的淘汰和配额策略治理, 逻辑归属和物理放置解耦, 容量随负载动态分配.

**Eviction-centric 优于主动迁移.** 依赖预测模型和后台控制器搬数据的架构, 工程代价远比理论收益大: 迁移线程引入独立的锁层级, 和 Buffer Pool 锁交互可能死锁; 迁移和前台查询的带宽仲裁在突发时容易饿死一方; 迁移中途 crash 的恢复需要额外的处理路径, 复杂化 redo/undo 逻辑. 把放置决策限制在 eviction 和 flush 这两个天然控制点上, 复用现有的 Buffer Manager 控制路径, 不引入额外同步, 运维人员面对的是一个单一的、被充分理解的控制回路.

**分层必须和恢复、备份协议协同.** 脱离恢复逻辑的独立数据移动, 只更新元数据而没有事务上下文, crash 后可能出现页面重复或丢失. CloudJump III 让放置变化只影响页面的物理位置, 与 LSN 标识的逻辑版本完全正交——这类正确性风险在测试中往往暴露不出来, 到了生产环境才会以严重故障的形式出现.

#### 总结

从 CloudJump I 的 IO 路径重构, 到 CloudJump II 的 MVD 多版本共享存储, 再到 CloudJump III 的引擎集成分层, 这条线索的内核是一致的: 基于标准云存储服务构建云原生数据库的存储底座, 把复杂度留在计算层/引擎层, 让存储层保持简单和通用, 这也是解耦数据库/存储层的好处, 对比 Aurora 的架构, CloudJump 可以充分享受到存储层的发展带来的收益, 而不需要开发自己的 Page Server 层去对接不同的存储介质.

CloudJump III 证明了在分层存储上获得可预期的性能, 关键在于把分层放进和缓存、恢复同一个控制回路里——用引擎可见的方式做准确的放置, 用 eviction-centric 的机制约束 miss 的代价, 用快照版本协议保证零停机备份的正确性. 最终的效果是: 用一小部分快层容量, 换来接近本地盘的吞吐和稳定的访问延迟, 以及显著更优的单位成本性能.

更多的内容可以参考论文:《CloudJump III: Optimizing Cloud Databases for Tiered Storage》.

#### 相关论文

Chen, Z., Sha, M., Li, F., Wang, S., Huang, B., Ma, G., ... & Wang, Y. (2026). CloudJump III: Optimizing Cloud Databases for Tiered Storage. In Proceedings of the 2026 International Conference on Management of Data (SIGMOD).

Chen, Z., Yang, X., Sha, M., Li, F., Wang, K., Miao, Z., ... & Wang, S. (2025, June). CloudJump II: Optimizing Cloud Databases for Shared Storage. In Companion of the 2025 International Conference on Management of Data (pp. 336-349).

Chen, Z., Yang, X., Li, F., Cheng, X., Hu, Q., Miao, Z., ... & Wang, S. (2022). CloudJump: optimizing cloud databases for cloud storages. Proceedings of the VLDB Endowment, 15(12), 3432-3444.

