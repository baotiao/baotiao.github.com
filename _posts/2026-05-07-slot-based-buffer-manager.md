---

layout: post
title: MySQL/PostgreSQL Slot-based Buffer Manager Pin/buf_block_fix operator
summary: 从 Slot-based Buffer Manager 这个共同的架构选择出发, 看清 InnoDB 和 PostgreSQL 里 Pin 这个语义为什么必须存在, 以及它到底保护的是什么

---

在 MySQL/PostgreSQL Buffer Pool 里面有一个 Pin 操作 — PostgreSQL 叫 Pin, MySQL InnoDB 叫 buf_block_fix / io_fix. 这些操作本质上都是把一个 page "pin" buffer pool 的某个位置上.

为什么在其他系统里很少见到这种代码? 答案是 PG 和 InnoDB 的 buffer pool 都用了同一种架构 — Slot-based Buffer Manager. 这种架构直接决定了 Pin 这个操作必须存在.

#### Slot-based Buffer Manager 结构

启动时, buffer pool 被切成 N 个固定大小的 slot (InnoDB 是 16KB, PG 是 8KB). slot 总数 N 在启动后不再变化.

数据结构上分三层:

* Slot / 描述符: 启动时静态分配, 地址永不变 (buf_block_t / BufferDesc)
* Frame / 页面内存: 启动时静态分配, 地址永不变 (buf_block_t->frame / BufferBlocks[i*BLCKSZ])
* Page Identity: 当前 slot 装的是哪个磁盘 page ((space_id, page_no) / (rel, fork, blkno)), 这个会变

```cpp
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

slot 和 frame 之间是启动时永久绑定的, 终身不变. 真正会变的只有 page identity — evict 的本质就是把 slot 上挂的 page identity 改成另一个, 然后把磁盘上新 page 的内容读到这个 slot 对应的 frame 内存里.

Pin 锁定的就是 slot ↔ 当前装的 page identity 这个映射. 在我持 pin 期间, 这个 slot 装的还得是同一个 page, 不能被换走.

#### 为什么要 Pin 住 page

**1. 固定内存物理位置**

page 被 pin 住, 它所在的 slot 位置就固定了. slot 固定 → 对应的 frame 内存地址固定 → page 内任何字节的物理地址都固定.

**2. 支持裸指针操作**

PG 和 MySQL 的代码里到处都是直接指向 page 内部地址的裸指针:

* PG 的 HeapTuple.t_data — 指向 buffer 内某条 tuple 的 header
* InnoDB 的 rec_t *rec — 指向 page 内某条 record 的偏移
* 跨函数传递的 byte * / Page 字节指针

只要 page 被 pin 住, 这些裸指针就一直有效, 上层可以反复 deref. 这是 OLTP 热路径上每行数据访问 0 次 hash lookup, 0 次 IO 的根本原因.

**3. 防止被淘汰或置换**

pin 住以后, 这个 page 不会被 LRU 淘汰 (InnoDB), 也不会被 clock-sweep 选作 victim (PG). buffer replacement 算法在挑牺牲者时直接跳过持 pin 的 slot.

#### 如果不 Pin 会怎样

假设上层手里有一个指向 page 内某条 tuple 的裸指针, 但没有 pin 住这个 page. 这时 buffer replacement 把这个 slot 选成牺牲者, evict 当前 page, 换上别的 page.

即便这个 page 稍后又从磁盘读回 buffer pool, 分配到的可能是另一个 slot, frame 起始地址完全不同. 上层手里的裸指针指向的还是原来那个 slot 的 frame, 但那段内存里已经是别的 page 的字节了. 之前存储的所有裸指针都失效, 直接崩.

所以 Pin 的最大意义就是确保 page 所在的内存物理位置不变. 没有 pin, slot-based buffer manager 就不能给上层暴露裸指针 API, 也就失去了它最大的性能优势.

#### 三层保护机制

Pin 不是 buffer manager 唯一的同步原语. 完整体系是三层正交保护, 每层各管一块:

| 保护对象 | InnoDB | PostgreSQL |
|---|---|---|
| slot ↔ page identity 映射 | buf_fix_count | BufferDesc.refcount |
| frame 内部字节内容 | block->lock (rw_lock) | content lock (LWLock) |
| 描述符元数据本身 | buf_block_t::mutex | buffer header spinlock |

每一层粒度和持有时间都不一样:

* Pin 持有时间最长, 跨整个 mtr / query 都行. 原子计数器, 极轻量.
* Frame latch (block->lock / content lock) 持有时间中等, 覆盖一次 page 修改的 critical section.
* Header lock 持有时间最短, 仅保护描述符元数据自身的瞬时一致性.

三个原语相互独立, 不能互相替代. Pin 保护 slot 占用, latch 保护字节内容, header lock 保护描述符自身. 任意一层失守, 上层都会出问题.

#### PostgreSQL pin 的额外语义

InnoDB 和 PostgreSQL 的 Pin 在 "锁定 slot ↔ page identity 映射" 这个核心语义上是一致的, 但 PG 还多做了一件事: 持 Pin 期间, page 内 tuple 的物理位置也不能被搬动. InnoDB 没有这个保证.

下一篇专门讲这个差异, 以及 PG 的 buffer/README 里的 5 条 access rules 是怎么把这个额外契约表达出来的.
