---

layout: post
title: PostgreSQL HeapTable + Pin vs MySQL InnoDB IOT + Persist cursor
summary: MySQL InnoDB IOT + persistent cursor 和 PostgreSQL HeapTable + Pin 走了两条路. 这篇接着讲两者的区别.

---



前面介绍过 PostgreSQL Buffer Access 5 Rules 里面的 Pin 机制, 其实 HeapTable + Pin 机制还带来了其他和 InnoDB 的区别.



InnoDB Persist cursor 是用来保留查询遍历 btree 过程中 index tree cursor 的位置.

为什么需要 persist cursor?

因为有多种场景下, 比如在执行大查询时, 查到一行以后, 需要将数据返回给 server 层处理. 这时, 你不能在返回指向 Record 的指针 index tree cursor 后依然持有该 Page 的锁 (Latch).

如果锁不放开, 在上层处理数据的期间, 这个 Page 就无法被修改.

如果锁放开, 这个 Page 有可能被修改了, 那么指向 Record 的指针就失效了, 需要重新定位这个 index tree cursor.

所以有了 btr_pcur_restore_position() 这个操作, 对应的把 pcur position 保存下来的操作就是 store_position() 操作

比如在 row_ins_clust_index_entry_low, row_upd_sec_index_entry_low 这些路口函数里面, 都需要申请

btr_pcur_t pcur;

然后通过 btr_pcur_open(index, entry, PAGE_CUR_LE, mode, &pcur, &mtr);

把 pcur 指向 btree 的指定位置



可以认为, InnoDB 的 Persistent Cursor 设计和 PostgreSQL 的 Heaptable + Pin 机制走了两条不同的路.

我们都会遇到一个问题: 在执行大查询时, 查到一行以后, 需要将数据返回给上层处理. 这时, 你不能在返回指向 Record 的指针后依然持有该 Page 的锁 (Latch). 如果锁不放开, 在上层处理数据的期间, 这个 Page 就无法被修改.

因此, MySQL InnoDB 的做法是:

1. 保存位置: 将当前查到的位置记下来. 比如在一个大查询中, 为了方便找下一个 Record, 最好把 Record 位置信息保存下来. 这样在读下一行时, 就不需要重新自上而下地遍历 B-Tree, 而是直接根据保存的信息找到 Next Record 即可.
2. 处理变更: 虽然保存了位置, 但你不能阻止别人对这个 Page 进行修改. 最直观的想法就是先保存位置, 等上层处理完后再处理下一个 Record.
   - 绝大部分情况下, Record 在 Page 上的位置没有发生改变, 那么直接处理下一行即可.
   - 如果位置发生了改变, 就重新遍历 B-Tree, 找到 Record 在新的 Page 上的位置, 然后再进行下一次查找. 对应的就是代码里面 restore_position() 逻辑

所以 InnoDB 的逻辑很符合直观: 读完一行并返回给上层处理期间, 把 Page 的锁放掉, 允许其他事务对该 Page 进行修改. 当要处理下一行数据时, 判断 Page 是否被修改过: 如果没有修改, 就复用位置信息; 如果修改了, 就重新走一遍遍历 B-Tree 的逻辑.

相比之下, PostgreSQL 的 Heaptable + Pin 机制走了另一条路. 它保证 Record 所在的 Page 位置不会发生改变. 通过给 Page 加一个 Pin 约束, 如果有人想修改 Page (比如进行整理, 重组等操作), 只要该 Page 被 Pin 住, 就不允许发生 Record 位置的偏移.



**InnoDB IOT 对比 PostgreSQL HeapTable**

- InnoDB IOT: Record 的修改是 In-place Update (原地更新), 老版本记录在 Undo Log 里. 即使是更新操作, Record 的位置也有可能发生改变.
- PostgreSQL HeapTable: 在一个 Page 内部, Tuple (即 Record) 是 Append-only 的, 不做原地更新. 如果 Page 内有修改, 它不会修改旧值, 而是不断向后追加. 只有在 Vacuum 这种批量操作或者对 Page 进行整理时, 才会修改 Record 在 Page 上的物理位置.

由于 PostgreSQL 这种位置修改的频率是批量的, 没有 MySQL 那么频繁, 所以它选择了另外一条路: 把 Record 的位置定住. 如果后台 Vacuum 发现这个 Page 被 Pin 住了, 就跳过它, 直接去处理下一个 Page.

总结来看, 选择这两套策略主要有以下原因:

1. 更新机制: MySQL InnoDB IOT 以 In-place Update 为主, 而 PostgreSQL HeapTable 在 Page 层面是 Append-only 的.
2. 逻辑复杂度: 理论上, MySQL 的实现更复杂一点, 但更符合逻辑, 因为它不会因为一个查询操作就导致 Page 无法进行整理或重组; 而 PostgreSQL 的实现则相对简单一些.



PostgreSQL 的 Heaptable + Pin 和 InnoDB 的 Persist Cursor 机制相比, 带来的一个优势是可以做到全链路的读取不需要拷贝.



**InnoDB 读路径上的拷贝**

比如在最常见的 row_search_mvcc 里面

row_search_mvcc 的核心序列是这样:

    1. latch 住 leaf page
    2. cursor 定位到 record, 拿 rec_t 裸指针
    3. MVCC 可见性判断
    4. 还持着 latch 的时候, 调 row_sel_store_mysql_rec, 把 record 转成 MySQL row format, copy 到 prebuilt->row_buf
    5. 释放 latch (或 btr_pcur_store_position 存位置)
    6. 把 row 返回 server

  关键在第 4 步和第 5 步的顺序: InnoDB 是先 copy 出来, 才释放 latch. copy 出来是为了尽快可以把 page latch 释放掉, 减少锁的占用.
  一旦 latch 放掉, buffer 里那条 record 随时可能被改 / 搬走, 所以必须趁还持 latch, 先把数据 copy 到一块 latch 之外的内存 (row_buf), 之后才敢放 latch.

这里即使不存在 MySQL row format 和 InnoDB row format 格式不一致的问题, 也需要有这样的拷贝, 核心还是因为这个 Page latch 释放了以后, 这个 pcur 存的 record 的内容有可能被 inplace update.

之前跑 TPCC 的经验, 在 oltp_readonly 没有明显热点的场景下, 这里的内存拷贝是一个瓶颈点.



**PostgreSQL 读路径上的拷贝**

没有. heap_getnextslot 返回的 slot 里挂 BufferHeapTuple, t_data 直接指 buffer 字节; executor 节点之间传 slot 不 copy; 访问列走 heap_getattr 直接解 t_data 后面的字节. visibility check 找到哪个版本可见, 就读那条 tuple 的 t_data, 老版本本来就在 heap 里原地, 不需要重建.

只有显式物化点才 copy: Sort / HashJoin build / Material 节点进 tuplestore, WITH HOLD cursor 在 commit 时物化, trigger 访问 OLD/NEW, TOAST 列 detoast, 以及最终发给客户端. 单一 SELECT 链条上的过滤, 投影, join 不 copy.

当然 Pin 不是白来的. reader 持 pin 期间, vacuum 在那个 page 上拿不到 cleanup lock, 该 page 的物理整理被推迟 (page 级, non-aggressive vacuum 跳过即可). 另外老版本堆在 heap 里, 要靠 vacuum 回收. PG 用读路径的零拷贝换来了 vacuum 这一侧的负担.
