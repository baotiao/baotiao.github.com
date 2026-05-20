---

layout: post
title: PostgreSQL Buffer Access 5 Rules
summary: src/backend/storage/buffer/README 里的五条 buffer access rules 是 PG 并发协议的基本要求.

---

src/backend/storage/buffer/README 是 PG 社区维护 buffer manager 的官方设计文档. 它在开头列了 5 条 buffer access rules, 提 patch / review 时直接引用. 这 5 条规则合起来定义了 PG 的 Pin 协议, 也是 PG 和 InnoDB buffer manager 设计上真正分叉的地方.

#### 同步原语先看清楚

PG 的 buffer 上有两个独立的同步原语:

- Pin — atomic refcount, 防止 slot 被 evict 换成别的 page. 持有时间可长可短, 甚至跨函数 / 跨节点传递都行.
- Content Lock — LWLock, share / exclusive 两种模式, 保护 page 字节内容的并发访问. 持有时间应当尽量短.

PG 的关键设计选择是: 这两个原语可以脱钩. 拿到一个 buffer 之后, pin 和 content lock 是分别 acquire / release 的, 中间可以出现 "只持 pin 不持 content lock" 这种状态, 而且这种状态在 OLTP 主流路径里到处都是.

后面 5 条规则全是在 "pin / content lock 怎么组合使用" 这个空间里画出几条边界.

#### Rule 1: 访问 tuple 的基本条件

> To scan a page for tuples, one must hold a pin and either shared or exclusive content lock.

要访问一个 page 上的 tuple, 必须同时持有 pin + content lock (share 或 exclusive 都行). 这是基线, 后面 4 条规则都是在这个基线上做加减.

#### Rule 2: Pin 保证 tuple 物理位置稳定

> Once one has determined that a tuple is interesting (visible to the current transaction) one may drop the content lock, yet continue to access the tuple's data for as long as one holds the buffer pin. Therefore the tuple cannot go away while the pin is held (see rule #5). Its state could change, but that is assumed not to matter after the initial determination of visibility is made.

这条是 Pin 协议里最有意思的一条. 它明确允许这种状态 — 只持 Pin, 不持 Content Lock.

在这个状态下, tuple 的物理位置 (line pointer + tuple bytes 在 page 内的偏移) 保证不变. 所以上层代码可以拿着 HeapTuple 这样的 in-buffer 裸指针跨函数 / 跨执行节点传递, 只要 Pin 还在就一直有效.

这个保证不是 Pin 自己提供的, 是 Pin 通过 Rule 5 间接提供的. Pin 本身只阻挡 slot 被换 page, 阻挡不了 page 内的物理整理. 但是物理整理 (HOT prune / vacuum / PageRepairFragmentation) 需要 cleanup lock, 而 cleanup lock 要求 refcount = 1, 所以只要我还持 Pin, 没人能进来搬 tuple.

"Its state could change, but that is assumed not to matter after the initial determination of visibility is made" 的意思是:

1. Visibility check 在持 content lock 期间已经做完, 决策已经定. 后续即使 hint bit / xmin / xmax 被并发改, reader 不会回头重做 visibility check.
2. Tuple 的 data payload 不会变, 因为 PG 是 immutable tuple — UPDATE 不是原地改, 是删一个 + 插一个新的. Reader 通过 t_data 后续访问 payload 拿到的值跟做 visibility check 那一刻的是同一个 tuple 实体.
3. 物理位置不变, 由 Pin 通过 Rule 5 保证.

三件事合起来才让 "释放 content lock 之后继续用 t_data 访问 tuple" 是安全的.

**带来的副作用: long reader 阻塞 vacuum**

这条规则给上层很大便利 (executor 可以裸用指针, 不用 cursor 抽象), 但代价付在 vacuum 一侧:

- 前台一个大的 Heap Scan 持续持有当前 page 的 Pin (随扫描往后推, 逐 page 持 Pin)
- 后台 autovacuum 想清理某个 page, 需要拿 cleanup lock (Rule 5: refcount = 1)
- 这个 page 上有 scan 的 Pin, cleanup lock 拿不到, autovacuum 卡住

PG 用户经常报 "long query 让 autovacuum 进度被卡, bloat 失控", 根源就在这里.

#### Rule 3: 修改 header 多字段必须持 exclusive content lock

> To add a tuple or change the xmin/xmax fields of an existing tuple, one must hold a pin and an exclusive content lock on the containing buffer. This ensures that no one else might see a partially-updated state of the tuple while they are doing visibility checks.

Rule 3 解决的不是 "指针已经传给上层" 的问题 (那是 Rule 2). Rule 3 解决的是 visibility check 的多字段一致性.

**为什么是多字段问题**

PG 的 visibility check (HeapTupleSatisfiesVisibility 系列) 是一个读多个字段然后组合判断的过程, 典型路径要读:

- t_xmin (32 bit)
- t_xmax (32 bit)
- t_infomask (flag 集合)
- t_infomask2
- t_ctid (跟 HOT chain 时)

判断逻辑是 "xmin 提交了吗? xmax 提交了吗? 在我的 snapshot 范围内吗? 是 lock-only 的 xmax 还是真删除? 是 HOT update 吗?" — 这些字段必须作为一个整体保持一致, 否则会得出错误的可见性结论.

**具体场景**

T1 在做 HOT update, 要修改老 tuple X 的几个字段:

```
写入 1: t_xmax    = T1.xid           /* 标记 X 被 T1 删 */
写入 2: t_infomask 加 HEAP_HOT_UPDATED + 调整 lock 信息
写入 3: t_ctid    = new_tid          /* 指向 HOT 链下一版本 */
```

如果 T2 (reader) 持 share content lock 就能进来做 visibility, 可能撞到这个序列中间:

```
T1 已写 t_xmax = T1.xid              ← 这一步做完
T1 还没写 t_infomask / t_ctid        ← 还没做
T2 进来 visibility check:
   读 t_xmin = 老的, committed       → 之前可见
   读 t_xmax = T1.xid, in-progress   → "正在被 T1 删"
   读 t_infomask                     → HEAP_HOT_UPDATED 没设
   读 t_ctid                         → 还是老的 (指自己)
   结论: "这是一个被删的 tuple, 不是 HOT 链头" → 不跟随 HOT
   返回错误结果, 看不到 T1 的新版本
```

任何写顺序都有类似的中间状态. Exclusive content lock 就是堵这个窗口.

**Rule 2 vs Rule 3 的分工**

把两条规则放一起看:

| | 保护对象 | 同步原语 | 解决的问题 |
|---|---|---|---|
| Rule 2 | tuple 的物理位置 | Pin (通过阻挡 cleanup lock) | 上层裸指针在 Pin 期间继续 deref |
| Rule 3 | tuple header 的多字段一致性 | Exclusive content lock | reader 不读到 writer 半完成的 header 状态 |

两条规则保护的是正交的两件事. 一个典型协作场景:

- BTree 索引扫描读完 tuple, 释放 content lock, 保留 Pin (Rule 2 生效)
- 这时另一个 backend 拿 exclusive content lock 去改这个 tuple 的 xmax (合法, Rule 3 满足)
- 但它做不了 HOT prune (Rule 5 要 refcount = 1, 我还 Pin 着)
- 索引扫描手上的 t_data 仍指向同一段字节 (Rule 2)
- 期间 tuple header 被改 — 没关系, 索引扫描早就做完了 visibility check, 后续只访问 immutable 的 payload

这套分工让 PG 的 reader 能把重的同步 (content lock) 控制在最短时间, 轻的同步 (Pin) 可以长持有.

#### Rule 4: hint bit 可以在 shared lock 下 OR

> It is considered OK to update tuple commit status bits (i.e. OR the values HEAP_XMIN_COMMITTED, HEAP_XMIN_INVALID, HEAP_XMAX_COMMITTED, HEAP_XMAX_INVALID into t_infomask) while holding only a shared lock and pin on a buffer. This is OK because another backend looking at the tuple at about the same time would OR the same bits into the field, so there is little or no risk of conflicting update; what's more, if there did manage to be a conflict it would merely mean that one bit-update would be lost.

Rule 4 是 Rule 3 的一个特例放宽: 在 4 个特定的 hint bit 上, 允许只持 shared lock + Pin 就改 (用 OR 操作). 这条放宽不是简单因为 "是单字段", 而是因为 hint bit 满足四个性质同时成立.

**性质一: 写的是单 bit, 方向单一 (只置位)**

```c
tuple->t_infomask |= HEAP_XMIN_COMMITTED;   /* 单 bit OR */
```

跟 Rule 3 写 4 byte 的 t_xmin = 12345 是完全不同的事. 单 bit OR 不存在多 byte 撕裂的问题, 也不存在 "A 想置 1, B 想置 0" 的方向冲突.

**性质二: 操作幂等**

所有 backend 想 set 同一个 hint bit 的内容都一样, 因为来源是同一个 CLOG 查询结果:

- HEAP_XMIN_COMMITTED: 当 xmin 这个 txn 在 CLOG 里查到 committed 时才会去 OR. CLOG 查询结果是确定的, 任何 backend 查都查到同一个答案
- 其它三个同理

多个并发 OR 同一个 bit 的最终结果 = 单个 OR. Idempotent.

**性质三: Hint bit 是 cache, 不是权威**

这条最关键. Hint bit 的语义是 "CLOG 查询结果的缓存", visibility 真正的兜底是 CLOG:

```c
/* 简化的 visibility check */
if (tuple->t_infomask & HEAP_XMIN_COMMITTED) {
    /* fast path: hint bit 说 committed, 信它 */
} else if (tuple->t_infomask & HEAP_XMIN_INVALID) {
    /* fast path: hint bit 说 aborted, 信它 */
} else {
    /* slow path: 查 CLOG */
    if (TransactionIdDidCommit(xmin)) {
        tuple->t_infomask |= HEAP_XMIN_COMMITTED;  /* 顺手设上 hint bit */
    }
}
```

即使 hint bit 没设, visibility check 也不会得错, 只是慢一点. 跟 Rule 3 保护的 t_xmin / t_xmax (读错就直接错) 性质完全不同.

**性质四: 丢失 OR 操作可接受**

如果两个 backend 同时 OR 同一个 bit, 在 16-bit OR 不真正原子的极端情况下, 可能其中一个 OR "丢了". 但这没关系 — 下一次 visibility check 进 slow path, 重新查 CLOG, 再尝试设 hint bit. README 原话: "one bit-update would be lost" — PG 直接承认会丢, 但丢得起.

**四条性质必须全部满足**

t_infomask 里不是所有 bit 都满足这四条性质. 比如:

- HEAP_HOT_UPDATED: 决定要不要跟 HOT chain, 是权威的, 不是 cache, 必须走 Rule 3 用 exclusive lock
- HEAP_XMAX_LOCK_ONLY: 决定 xmax 是真删除还是只 lock, 权威, 必须 exclusive
- HEAP_KEYS_UPDATED, HEAP_XMAX_IS_MULTI: 同样权威, 必须 exclusive

所以 Rule 4 明确列了只有那四个 hint bit (XMIN/XMAX × COMMITTED/INVALID) 适用, 其它 bit 一律走 Rule 3.

**Rule 4 为什么必须存在 — 性能动机**

如果没有 Rule 4, 每次 SELECT 遇到一个 hint bit 还没设上的 tuple, 都要把 shared lock 升级到 exclusive lock 才能设 hint bit. 这对 OLTP 灾难性:

- 第一次 SELECT 一个新插入的 page, 全部 tuple 的 hint bit 都没设, 全部需要 exclusive lock
- 多个 SELECT 并发, 互斥, 串行化
- SELECT 看起来是只读操作, 突然变成需要 exclusive lock 的写操作

Rule 4 让 SELECT 在逻辑上仍然是只读 (从锁的语义看 shared lock 就够), 顺手做 hint bit 写入是个 best-effort 的副作用. 实际跑 benchmark 时大家观察到的 "首次 SELECT 比后续 SELECT 慢" 现象就是 hint bit 在第一次访问时被设上.

#### Rule 5: cleanup lock — 物理整理需要 refcount = 1

> To physically remove a tuple or compact free space on a page, one must hold a pin and an exclusive lock, and observe while holding the exclusive lock that the buffer's shared reference count is one (ie, no other backend holds a pin). If these conditions are met then no other backend can perform a page scan until the exclusive lock is dropped, and no other backend can be holding a reference to an existing tuple that it might expect to examine again.

这是 cleanup lock 的语义, 也是 Rule 2 的兑现机制.

物理整理 = HOT prune / vacuum 删 line pointer / PageRepairFragmentation 搬 tuple. 这些操作会改变 line pointer 数量或 tuple 物理偏移, 任何持有这些"过时"指针的 backend 会得出错误结论. 所以必须:

1. 持 exclusive content lock (排除并发字节级访问)
2. 观察 refcount = 1 (确认没有 backend 持有 Pin)

**LockBufferForCleanup 的实现**

> Obtaining the lock needed under rule #5 is done by the bufmgr routines LockBufferForCleanup() or ConditionalLockBufferForCleanup(). They first get an exclusive lock and then check to see if the shared pin count is currently 1. If not, ConditionalLockBufferForCleanup() releases the exclusive lock and then returns false, while LockBufferForCleanup() releases the exclusive lock (but not the caller's pin) and waits until signaled by another backend, whereupon it tries again. The signal will occur when UnpinBuffer decrements the shared pin count to 1. As indicated above, this operation might have to wait a good while before it acquires the lock, but that shouldn't matter much for concurrent VACUUM.

实现上的关键序列是这样:

```c
for (;;) {
    LockBuffer(buffer, BUFFER_LOCK_EXCLUSIVE);   /* 1. 拿 X content lock */

    refcount = ...;
    if (refcount == 1)
        return;                                  /* 2a. 成功, 拿到 cleanup lock */

    /* 2b. 失败: 别人持 pin. 必须释放 X lock */
    LockBuffer(buffer, BUFFER_LOCK_UNLOCK);

    /* 注意: 这里释放的是 content lock, 不释放 caller 自己的 pin */

    /* 3. 把自己挂到 BM_PIN_COUNT_WAITER, 等别人 unpin 时唤醒 */
    ProcSleep(...);

    /* 4. 醒了重试 */
}
```

几个关键细节:

1. 先拿 X content lock, 再查 refcount, 不是反过来. 这个顺序很重要 — 如果反过来 "先查 refcount 再拿 X lock", 中间会有窗口让别的 backend pin 进来, 查到 refcount = 1 但真正拿到 X lock 时已经 refcount > 1.
2. 失败时只释放 X content lock, 不释放 caller 的 pin. 这意味着 VACUUM 自己也持着 pin 在等. 这是设计上的考虑 — VACUUM 必须先 pin 这个 page 才能锁定 "我要清理的就是这个 page", 失败重试期间放 pin 没意义.
3. 唤醒机制走 UnpinBuffer. 别的 backend UnpinBuffer 把 refcount 减到 1 时, 检查 BM_PIN_COUNT_WAITER flag, 给挂在上面的 waiter 发信号. 整个机制不需要 polling, 是 event-driven 的.
4. VACUUM 等 cleanup lock 期间, 自己处于 "pin 不持 content lock" 状态. 这其实让 vacuum 不会阻塞别的 reader 拿 share lock 读 page — 别人照样读, 只是物理整理推迟. 这是协议设计很温和的一点.

**single-waiter 限制**

> The current implementation only supports a single waiter for pin-count-1 on any particular shared buffer. This is enough for VACUUM's use, since we don't allow multiple VACUUMs concurrently on a single relation anyway. Anyone wishing to obtain a cleanup lock outside of recovery or a VACUUM must use the conditional variant of the function.

BM_PIN_COUNT_WAITER 这个 flag 是 BufferDesc.state 里的一个 bit, 在 buffer header 上只能挂一个 waiter 的 backend pgprocno. 这就是 single-waiter 限制的物理原因 — 这一个 bit 决定的, 不是别的设计.

这个限制带来两条约束:

1. 同一个 relation 上不允许有多个并发 VACUUM. PG 通过 relation 级别的 lock (ShareUpdateExclusiveLock) 来保证这一点, autovacuum / 手动 VACUUM 都拿这把 relation lock, 互斥. 这是规避 cleanup lock single-waiter 限制的上层保护.
2. Recovery 和 VACUUM 之外的 cleanup lock 必须用 conditional 版本. 比如 HOT prune 在 heap_page_prune_opt 路径上用的就是 ConditionalLockBufferForCleanup, 拿不到就跳过这个 page, 不阻塞前台查询. 这是工程上很务实的妥协 — HOT prune 是机会主义的, 不是必须做.

只有 LockBufferForCleanup 这个阻塞版本会用到 single-waiter slot, conditional 版本根本不挂 waiter 直接返回 false. 所以 single-waiter 真正限制的是 "谁能阻塞等待", 不是 "谁能尝试 cleanup".

#### 5 条规则整体串起来

把它们按 "什么时候用什么原语" 组织:

| 场景 | 需要 | 来自规则 |
|---|---|---|
| 读 tuple 内容 (含 visibility check) | Pin + shared content lock | Rule 1 |
| 读完 tuple 之后只想留住指针 | 只需 Pin (释放 content lock) | Rule 2 |
| 写 tuple header 多字段 (xmin/xmax/HOT 标志) | Pin + exclusive content lock | Rule 3 |
| 只置位 4 个特定 hint bit | Pin + shared content lock | Rule 4 (Rule 3 的特例放宽) |
| 物理整理 page (HOT prune / vacuum / defrag) | Pin + exclusive content lock + refcount = 1 | Rule 5 |

设计精髓是让 "短同步" 和 "长引用" 分离:

- Pin = 长引用: 持有时间跨整个 query 也行, 用于保护 tuple 物理稳定
- Content lock = 短同步: 持有时间只覆盖一次字节级读写, 用于保护字节一致性
- Cleanup lock = 短同步 + 长引用确认: vacuum 这种偶尔做的重活才用, 需要等所有长引用退出

#### InnoDB 对比

InnoDB 没有 "Pin 独立于 latch 存在" 这个能力. InnoDB 的 buf_fix_count 只防 evict, block->lock (page latch) 提供短同步, 但长引用必须靠 persistent cursor 重新建立 — btr_pcur_store_position 存逻辑身份 (key + modify_clock), btr_pcur_restore_position 重新搜或乐观校验.

两条路线代价方向相反:

| | PG | InnoDB |
|---|---|---|
| 跨原语周期保留位置 | 隐式, 持 Pin 即可 | 显式 store + restore |
| Reader 路径开销 | 0 重搜 | 每次 restore 一次 modify_clock 校验, 失败时全树重搜 |
| Vacuum / Purge 自由度 | 受 reader 阻塞 (cleanup lock) | 不受阻塞 (X latch 直接拿) |
| 上层 API 形态 | 可以用裸 HeapTuple 指针 | 必须用 cursor 抽象 |
| 实现复杂度 | cleanup lock + BM_PIN_COUNT_WAITER 唤醒机制 | pcur 5 种 enum + 乐观/悲观分支 + modify_clock |

PG 选择把复杂度集中在 buffer manager 这一层 (cleanup lock 协议), 换上层 executor 用裸指针的简洁; InnoDB 选择 buffer manager 简单 (buf_fix_count 只防 evict), 把跨原语的位置管理推到 cursor 这一层.

两条路都自洽. 体感上的差异主要落在 PG 的 long reader 会阻塞 autovacuum, InnoDB 没有这个问题. 这是 PG 用户最常遇到的与这套设计直接相关的 production 现象.

#### 总结

PG 这 5 条 buffer access rules 是它整个并发协议的基本要求. vacuum 进度被卡, autovacuum 调度逻辑, hint bit 引起的 dirty page 写放大, FPW 跟 hint bit 的交互, BTree scan 的 kill_prior_tuple 等等, 都是在这个设计下出现的结果.

核心是理解两件事:

1. Pin 和 content lock 是独立的两个原语, 可以脱钩, "pin 不持 lock" 是 OLTP 主流状态而非边缘情况
2. Rule 2 把 "pin 期间 tuple 位置稳定" 作为契约暴露给上层, Rule 5 通过 cleanup lock 兑现这个契约, 让 executor 可以用裸指针访问 buffer 内字节

这套设计跟 InnoDB 走的是不同路线 — PG 在 buffer manager 这一层多做了 cleanup lock 这套复杂度, 换上层 executor 几乎零拷贝的指针传递; InnoDB 在 buffer manager 这一层保持简单, 把跨原语的位置管理推给 cursor 这一层显式处理. 两套都自洽, 各有代价, 体感上最大的差异是 PG long reader 会卡 autovacuum, InnoDB 没有这个问题.
