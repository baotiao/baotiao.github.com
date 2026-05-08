---

layout: post
title: Slot-based Buffer Manager 的设计 — 从 Pin 的本质说起
summary: 从 Slot-based Buffer Manager 这个共同的架构选择出发, 看清 InnoDB 和 PostgreSQL 里 Pin 这个语义为什么必须存在, 以及它到底保护的是什么

---

最近在看 PostgreSQL 的 buffer manager 代码, 把 InnoDB 那边对应的实现也对照着读了一遍, 发现两边其实是同一种架构: **Slot-based Buffer Manager**. 这种架构直接决定了 Pin (PG 里叫 `PinBuffer`, InnoDB 里叫 `buf_block_fix`) 这个语义为什么必须存在, 以及它真正保护的是什么.

我自己有一个直觉上的误区, 之前一直没想通: 既然内存里的 clean page 和磁盘上一致, 那 Pin 这个开销是不是可以省掉, 用的时候再从磁盘读一份就行了? 把这个问题彻底想清楚, 必须先把 Slot-based Buffer Manager 这个架构本身讲明白.

#### Slot-based Buffer Manager 的核心结构

Buffer Manager 解决的是同一个问题: 数据在磁盘上, 内存远比磁盘快, 用一块固定内存作磁盘的缓存. 但具体怎么管理这块内存, 不同系统选择不一样.

InnoDB 和 PG 选的都是 Slot-based: 启动时把 buffer pool 切成 N 个固定大小的 slot (InnoDB 是 16K, PG 是 8K), 每个 slot 由一个固定的描述符和一段固定的数据区组成. slot 的总数 N 在启动时确定, 之后不再变化.

数据结构上分三层:

```
[ slot / 描述符 ]      <-- 启动时静态分配, 地址永不变
       │
       │ 永久指向
       ▼
[ frame / 页面内存 ]    <-- 启动时静态分配, 地址永不变
       │
       │ 当前装着哪个逻辑 page
       ▼
[ page identity ]       <-- (rel, fork, blkno) / (space_id, page_no), 流动的
```

这三层中, **第一层和第二层之间是启动时绑定的, 终身不变. 第三层才是会变的**. 这个区分是后面理解 Pin 本质的关键.

#### InnoDB 和 PostgreSQL 的对应关系

把上面三层映射到两边的代码:

| 概念 | PostgreSQL | InnoDB |
|------|-----------|--------|
| slot / 描述符 | `BufferDesc` (`BufferDescriptors[buf_id]`) | `buf_block_t` |
| frame / 页面内存 | `BufferBlocks[buf_id * BLCKSZ]` | `buf_block_t->frame` (16KB) |
| page identity | `BufferDesc.tag = (rel, fork, blkno)` | `buf_page_t->id` |
| Pin 计数 | `BufferDesc.state` 内的 refcount | `buf_page_t->buf_fix_count` |
| Page hash | `SharedBufHash` | `page_hash` |
| Replacement | clock-sweep (`StrategyGetBuffer`) | LRU (`buf_LRU_get_free_block`) |
| Frame 字节保护 | content lock (LWLock) | `block->lock` (rw_lock) |
| 描述符元数据保护 | buffer header spinlock | `buf_block_t::mutex` |

注意 slot 和 frame 之间的绑定是永久的:

- **PG**: `BufferDesc[i]` 永远对应 `BufferBlocks[i*BLCKSZ]` 这一段 8K 内存. 描述符数组和数据区数组是平行的, 用同一个 `buf_id` 索引.
- **InnoDB**: `buf_block_t.frame` 这个指针在 `buf_chunk_init()` 给每个 block 赋值后就再也不动了. chunk 一次性分配 N 个 `buf_block_t` 和对应的 N × 16K 内存, 一一对应到 buffer pool 销毁为止.

会变的只有 page identity. evict 的本质就是把 slot 上挂的 page identity 改成另一个, 然后把磁盘上新 page 的内容读到这个 slot 对应的那段 frame 内存里 — frame 地址不变, frame 内容被覆盖.

#### 为什么选 Slot-based

Slot-based 的好处直接来自它的两个静态绑定 (slot 数固定 + slot ↔ frame 永久绑定):

1. **Frame 地址稳定**. 上层代码可以放心持有 record 指针 / byte 指针 / cursor — 只要 page identity 不被换掉, 这些指针就一直有效. 不需要每次解引用都去查 hash table, 也不需要每次都过一遍 buffer manager 接口. 这是 OLTP 热路径的命根子.
2. **避免运行时分配 16K / 8K 页**. 不用 malloc / free, 没有内存碎片, 没有分配器的 lock contention, 也没有 latency 抖动.
3. **元数据稳定挂在 slot 上**. `block->lock` 上的等待队列, `modify_clock`, debug_latch — 都依赖 slot 是稳定 identity 才有意义. 如果 slot 换 page 时连这些元数据都重建, 一切持有它们的线程都会失效.

代价是 slot 数固定. buffer pool 满了想读新 page 进来, 必须找一个现有 slot 把它现在装的 page 换掉. **这个"换"的动作就是 evict, 也是 Pin 这个语义存在的根本原因**.

#### Pin 的本质: 锁定 slot ↔ page_id 映射

很多文档会把 Pin 描述成"防止 page 被 evict", 这个说法太抽象, 容易让人误以为 Pin 是用来保留 page 的内存副本的. 准确的表述是:

> Pin 锁定的是 "slot ↔ 当前装的 page_id" 这个映射. 在我持有 Pin 期间, 这个 slot 装的还得是同一个 page_id, 不能被换走.

**Pin 不是用来固定 slot ↔ frame address 的, 这个映射根本不需要保护 — 启动时就永久绑定了, 谁也动不了.**

InnoDB 这边在 `buf_page_can_relocate` (buf0buf.ic:503) 直接体现这个语义:

```cpp
static inline bool buf_page_can_relocate(const buf_page_t *bpage) {
  return (buf_page_get_io_fix(bpage) == BUF_IO_NONE &&
          bpage->buf_fix_count == 0);
}
```

只有 `buf_fix_count == 0` 而且 `io_fix == BUF_IO_NONE` 时, 这个 slot 才能被复用 — 即 evict 当前的 page_id, 换成新的. `buf_flush_ready_for_replace` (buf0flu.cc:457) 调用 `buf_page_can_relocate`, LRU 扫描在选 victim 时同样依赖这个判断.

PG 那边对应的是 `BufferDesc.state` 里的 refcount, clock-sweep 在 `StrategyGetBuffer` 里同样只挑 `refcount == 0` 的 buffer 作为 victim.

两边的 Pin 都是 atomic counter:

- InnoDB: `buf_block_fix(block)` → `bpage->buf_fix_count.fetch_add(1)` (buf0buf.ic:758)
- PG: `PinBuffer(buf)` → `pg_atomic_compare_exchange_u64(&buf->state, ...)` 增加 refcount

为什么必须是 counter 而不是 flag? 因为 N 个线程可能同时 Pin 同一个 page (典型场景: B+tree 非叶子 page 被几十个 backend / 用户线程持 S latch 并发读). flag 表达不了"还剩几个引用", 只有 counter 能.

#### clean page 为什么也要 Pin

直觉上 clean page 内存和磁盘一致, evict 了重读一遍不就行了吗? Pin 这个开销看起来可以省.

把 dirty page 的因素排除掉, 这个想法在**正确性**上确实可以推下去. 但在 PG / InnoDB 的实际架构里这个方案根本行不通, 真正的原因不是"内容是否一致", 而是 **整个上层代码大量持有指向 Page Frame 内部偏移的裸指针, 这些裸指针的有效性完全依赖 slot ↔ page_id 映射不变**.

InnoDB 里随手就能列出一堆这种裸指针:

- `rec_t *rec` — 指向 page 内某条 record 的偏移
- `btr_pcur_t.page_cur.rec` — 持久化游标, 跨函数甚至跨 statement 保留位置
- mtr 中跨函数传递的 `byte *` — 通过 `page_align(ptr)` 反算 frame 起点
- `page_cur_t::block` 和 `page_cur_t::rec` — page cursor 上挂的 frame 指针

PG 同理. SeqScan 拿到 `Page page` 之后:

```c
ItemId iid = PageGetItemId(page, offnum);
HeapTuple htup = (HeapTuple) PageGetItem(page, iid);
```

后面遍历几百个 tuple, 每一个都是直接的指针解引用, 完全不走任何 buffer manager 接口. 这是热路径上**每行数据访问 0 次 hash lookup, 0 次 IO** 的根本原因.

这些裸指针的有效性都依赖一件事: **slot 当前装的 page identity 在我用完之前不变**. 一旦不 Pin, slot 被 evict 后哪怕同一个 page_id 又被读回来, 分配到的可能是另一个 `buf_block_t` — frame 起始地址完全不同, 所有手上的裸指针立刻成野指针. 即使运气好分配回同一个 `buf_block_t`, 中间 ABA 一次 — slot 在我不注意的瞬间被别的 page 占用过又被我的 page 占用, 我手里的 record 指针指向的内容意义已经变了.

而且 clean page 反而是 clock-sweep 最爱的目标 — 因为 evict 它不用 flush, 成本最低. 所以你越是认为 clean page 安全, 实际上它越容易被换走.

进一步, "现在 clean" 也不代表"我访问期间一直 clean":

- 你打算读 page 上的 tuple, 看了一眼 `BM_DIRTY` 没置位, 觉得 "clean, 不 Pin"
- 这一瞬间另一个 backend 跑 HOT prune, 拿 cleanup lock, 物理重排 line pointer 和 tuple
- 你接着按之前看到的 ItemId 去解 tuple → 读到一半 tuple, 或者 ItemId 指向了一个被 redirect 后空出来的 hole

判断 page 是否 clean 这个动作本身就需要同步, 而 PG / InnoDB 里能给你这个同步保证的最便宜的原语就是 Pin. 鸡生蛋蛋生鸡.

所以真正的关键是: **Pin 不是为了"page 内容不丢", 是为了"我手里的裸指针不失效"**. 跟内容是否和磁盘一致毫无关系 — 跟 slot 这块物理身份还属于我引用的那个 page 有关系.

换个角度看, Pin 真正提供的契约是:

> 我手上这个 Page 指针可以被反复 dereference, 不需要每次都重新 lookup.

`ReadBuffer` / `buf_page_get` 做一次 hash lookup + atomic, 之后这个线程在 unpin 之前对这个 page 的所有访问都是裸指针, 0 额外开销. **Pin 的本质价值是把一次 buffer 查找的成本摊给一长串后续的内存访问**. 去掉 Pin = 失去这个摊销 = 每次访问都得自己付一次 lookup 的钱. 这跟 dirty / clean 无关, 是 Slot-based Buffer Manager 这个架构本身要求的.

#### Pin 和 latch 是正交的三层保护

Slot-based 架构里 Pin 解决"slot 不被复用", 但 frame 内部的字节内容怎么保护? 这是另一个独立的问题, 用另一个独立的原语. 实际上整个保护体系是三层正交的:

| 保护对象 | InnoDB | PostgreSQL |
|---------|--------|-----------|
| slot ↔ page_id 映射 (Pin) | `buf_fix_count` | `BufferDesc.refcount` |
| frame 内部字节 (content) | `block->lock` (rw_lock) | content lock (LWLock) |
| 描述符元数据本身 | `buf_block_t::mutex` | buffer header spinlock |

每一层保护一种东西, 粒度不同, 持有时间不同, 竞争模式也不同:

- **Pin** 最长, 跨越整个 mtr / query 的生命周期. atomic counter, 极轻量.
- **content lock** 中等, 跨越一次 page 修改的 critical section. rw_lock / LWLock.
- **header lock** 最短, 仅保护 BufferDesc / block 元数据的瞬时一致性. spinlock.

这种分离的好处是 Pin 比 content lock 廉价得多, 而且**可以只持 Pin 不持 content lock**. PG 的 BTree 索引扫描就是典型例子: scan 在每个 page 上读完 tuple 之后释放 content lock, 但保留 Pin, 这样别的 backend 可以正常拿 X content lock 修改页面 (split / insert), 但 vacuum 不能 recycle 这个 page — 因为 vacuum 要的是 cleanup lock, 即 refcount == 1 (只有自己 Pin). 这给了 BTree scanner 一种"我可以暂时放手 page 内容, 但保证我的扫描位置不会被回收成别的 page"的语义, 这是 PG 实现 lock-coupling-free BTree scan 的关键之一.

InnoDB 这边一个对应的场景是 mtr 跨函数调用持有 record 指针: 中间可能没持 page latch (latch 已经按 latch order 释放掉了), 但 `buf_fix_count > 0` 保证 page identity 不变, 直到 `mtr_commit` 末尾统一 unfix. 所以 record 指针在整个 mtr 生命周期内都是稳定的.

> 注: 学术界还有 OLFIT / Optimistic Lock Coupling (CIDR'17) 这类基于 version validation 的并发控制, 有时候会被拿来跟 Pin 类比. 但需要注意它们解决的是 **"读 page 内容时不取 content lock"** 的问题, 不是 **"slot 不被复用"** 的问题. 它们替换的是上面表格里的第二行 (content lock), 不是第一行 (Pin). 一个 slot-based 系统完全可以同时用 Pin (管 slot) + OLFIT (管 content), 这两件事是正交的.

#### PG 的 private_refcount: Pin 的极致优化

既然 Pin 是热路径, PG 还在它上面叠了一层优化, 叫 `private_refcount` (bufmgr.c:113-254). 这个 InnoDB 没有对应实现, 值得单独看看.

##### 它要解决什么

每次 `PinBuffer` 都要在 `BufferDesc.state` 上做 CAS:

```c
buf_state += BUF_REFCOUNT_ONE;
if (pg_atomic_compare_exchange_u64(&buf->state, &old_buf_state, buf_state))
```

这是全局共享的 cache line. 高并发下所有 backend Pin 同一个 hot page (BTree root, visibility map page) 时会反复抢同一条 cache line, 引发严重的 cache coherence ping-pong. 这正是单条 cache line 在多核上的 scalability 杀手 — 跟 latch-free vs latch-based 这种讨论无关, 锁不锁都一样.

观察: 同一个 backend 在同一个查询里反复 Pin 同一个 buffer 是非常常见的. index scan 沿一棵树往下走, root / 上层 internal 节点会被反复访问; nested loop join 内层重复扫一棵小表. 如果只有共享计数, 每一次 Pin / Unpin 都打一次 atomic.

##### 核心思路

**同一个 backend 对同一个 buffer 的多次 Pin, 共享 BufferDesc 上只记一次, 中间次数走 backend 本地的计数**.

数据结构:

```c
#define REFCOUNT_ARRAY_ENTRIES 8       /* 64B, 一条 cache line */

static Buffer            PrivateRefCountArrayKeys[REFCOUNT_ARRAY_ENTRIES];
static PrivateRefCountEntry PrivateRefCountArray[REFCOUNT_ARRAY_ENTRIES];
static HTAB             *PrivateRefCountHash;          /* 溢出 */
static int               PrivateRefCountEntryLast;     /* MRU */
```

几个细节值得记:

1. **Keys 数组和 Entry 数组分开**. 查找时只扫 8 个 Buffer 整型 (32 bytes), 编译器可以 auto-vectorize, cache 友好.
2. **MRU 优化**. 大多数 Pin / Unpin 是连续访问同一个 buffer, fast path 直接命中上次那个槽:

```c
if (likely(PrivateRefCountEntryLast != -1) &&
    likely(PrivateRefCountArray[PrivateRefCountEntryLast].buffer == buffer))
    return &PrivateRefCountArray[PrivateRefCountEntryLast];
```

3. **数组 + 哈希表的 hybrid**. 8 个槽内全用线性扫描, 超过就用 clock-like 替换淘汰一个旧 entry 到 hash table. 热的 entry 不会被困在 hash table 里, 总能在数组里命中.
4. **Reserve / Fill 两阶段**. `PinBuffer_Locked` 是在持有 buffer header spinlock 的状态下调的, 此时不能做内存分配. 所以 `ReservePrivateRefCountEntry` 提前预占一个槽, `NewPrivateRefCountEntry` 真正写入.

##### fast path 的效果

PinBuffer 的关键判断:

```c
ref = GetPrivateRefCountEntry(b, true);

if (ref == NULL) {
    /* 第一次 pin: 走 CAS 改 BufferDesc.state */
    pg_atomic_compare_exchange_u64(&buf->state, ...);
} else {
    /* 已经 pin 过: 只动 backend 本地 */
    ref->data.refcount++;
}
```

UnpinBuffer 对称:

```c
ref->data.refcount--;
if (ref->data.refcount == 0) {
    /* 最后一次 unpin: 才回到共享 BufferDesc.state 上做 atomic */
    ...
}
```

**N 次 Pin + N 次 Unpin, 共享 cache line 只被碰 2 次**. 中间 2(N-1) 次完全是 backend-local 的内存写, 没有任何 atomic, 没有任何 cross-core traffic. 这是把 cache line contention 从 O(访问次数) 降到 O(buffer 进出次数).

##### 顺带承担的几个职责

private_refcount 在工程上还顺带做了几件事:

1. **content lock mode 的本地记录** (`PrivateRefCountData.lockmode`). PG 有些路径需要知道"我自己当前对这个 buffer 持的是 share 还是 exclusive lock" (例如 `BufferIsExclusiveLocked`). 全局 LWLock 不直接告诉你, 所以在本地记一份.
2. **事务结束时的 pin leak 检测**. ResourceOwner 在事务 / subtxn 结束时遍历自己记的 pin, 通过 PrivateRefCount 验证没有忘记 unpin 的 buffer.
3. **VACUUM cleanup lock 的精确判定**. `LockBufferForCleanup` 要求 refcount == 1 (只有自己 Pin), 这里需要的是 **shared refcount == 1 而我自己只 Pin 一次**. private_refcount 让 "我自己 Pin 了几次" 有准确答案.

InnoDB 这边也有同样的 cache line ping-pong 问题, 但目前没有等价的 private fix count 机制. 这是 InnoDB 后续可以借鉴的优化点 — 特别是在 V8 / V9 大核机器上, 热点 page 的 atomic contention 会越来越明显.

#### Slot-based 之外的另一条路: 动态分配

把视野放大一些, Slot-based 不是数据库管理 buffer 的唯一选择. 它的对立面不是"用更聪明的同步机制替代 Pin", 而是 **完全不预分配 slot, 改成动态, 按需分配 page**:

- **RocksDB block cache**: 是 hash table + LRU, block 是 `Cache::Handle*` 动态对象, 每次 cache miss 就堆上 new 一块出来. 没有"slot"概念, block 只是堆上的对象. ref count 挂在对象上 (`cache->Lookup()` / `cache->Release()`), 表达的是 **对象生命周期**, 不是 **slot 占用**. ref 降到 0 且 cache 容量超了, 对象就被释放回堆.

- **mmap-style buffer management** (HyPer, Umbra): 让 OS page fault 处理 demand paging. 应用层不维护 slot 数组, 不需要显式 Pin — 因为 OS 的 page table 已经把 virtual address 和物理 page 绑定好了. 代价是失去对 IO 时机和 eviction 策略的控制, 也丢掉了 prefetch / async IO 的精细调度能力.

- **Query-time materialization** (Snowflake, BigQuery): 一个 query 把数据拉进内存, query 结束就丢. 没有跨 query 共享的 buffer pool, 也就没有 Pin. 但访问模式是"批量拉 + 顺序读一次", 跟 OLTP 完全不同.

这几种方案都绕开了"slot 复用"这个问题, 但走的是不同的路:

- RocksDB: slot 概念被对象生命周期替代, ref counting 还在, 但 ref 的是对象不是位置
- mmap-based: 把 slot 管理转嫁给 OS
- materialization: 干脆不复用, 每次重新拉

OLTP 体系几乎都选 slot-based — PG, InnoDB, TDSQL, OB, Aurora 都是. 原因前面讲过, 它给热路径提供了"裸指针稳定性 + 分配开销摊销". 一旦你的访问模式是**多线程共享 + 反复随机访问 hot page**, 动态分配的开销和指针不稳定会把性能拖垮, slot-based 几乎是唯一现实选择.

#### 总结

回到一开始的问题. Pin 的本质是什么?

**Pin 锁定的是 slot ↔ 当前装的 page_id 这个映射, 让 evictor / replacement 不能在我持有期间把 frame 重新指给另一个 page**.

它是 Slot-based Buffer Manager 这个架构的天然产物:

- slot 是 identity, 是地址稳定的对象 (启动时和 frame 一对一绑定, 终身不变)
- slot 上挂的 page identity 是流动的
- Pin 锁的是 "我现在看到的这个 slot 装的还是我想要的那个 page identity"

而 frame 内容 / 描述符元数据有自己独立的保护原语 (content lock / header lock), 跟 Pin 是正交的三层.

这个设计 InnoDB 和 PG 高度一致, 不是巧合 — 是同一种问题在同一种架构选择下的同一种解. 理解了这一层, 后面这些都自然有了答案:

- 为什么 Pin 必须是 atomic counter (多并发引用的需求)
- 为什么 Pin 和 page latch 是两件事 (Pin 保护 slot 占用, latch 保护 frame 字节)
- 为什么 clean page 也要 Pin (跟 dirty 无关, 跟"代码里大量裸指针的稳定性"有关)
- 为什么"反正内容一样, 重读就行"不成立 (重读拿到的可能是不同 slot, 旧裸指针全废, 而且每次访问都要做 lookup, 完全打破 buffer pool 的使用契约)
- 为什么 PG 的 private_refcount 这种"本地 Pin"优化有意义 (热点 cache line 的 ping-pong 才是真正的瓶颈)
- 为什么 PG 和 InnoDB 长得这么像 (同一种设计范式)

整个架构是自洽的: 你只要选了 slot-based + in-place update + 共享 buffer pool 这三个条件, Pin 就一定要存在. 想绕开 Pin, 真正的方向是换成动态分配的 cache 体系 (RocksDB / mmap / materialization), 而不是在 slot-based 框架内找替代品.
