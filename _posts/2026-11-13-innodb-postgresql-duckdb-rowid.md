---

layout: post
title: MySQL, PostgreSQL 和 DuckDB 的行定位
summary: InnoDB 按主键查找记录, PostgreSQL 通过tid定位 tuple, DuckDB 通过rowid定位列值. 这些引用方式决定了 page 整理, 删除空间回收和索引维护的范围.

---

InnoDB 的二级索引通过主键回表. PostgreSQL 的 heap 索引引用 tid 包含 block number和line pointer, DuckDB 的 ART 引用表内row. 三种引擎在 page 整理时, 要维护各自的行引用和实际记录之间的对应关系.

#### InnoDB 的主键

以有显式主键的表为例, 主键 B-tree 的叶子页存的就是主键记录. 内部节点用子页号向下路由. 到了叶子页, page_cur_search_with_match 先在 page directory 上二分, 再沿候选记录链比较主键.

```text
主键查询     主键 → primary key B-tree → 叶子页内按主键查找 → record
二级索引查询 二级键 → 二级索引记录里的主键 → primary key B-tree → record
```

页内整理维护页目录, 记录链和相关的记录锁. 页分裂时, 记录可以搬到另一个页, B-tree 会更新路由. 主键保持原值时, 二级索引可以用同一个键找到搬过的记录.

InnoDB 可以用主键或合适的唯一非空键组织btree. 表里没有合适的键时, InnoDB 生成一个 6 字节的隐藏 DB_ROW_ID 作为主键. [InnoDB 的主键索引与二级索引](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html)

#### PostgreSQL 的 heap TID

从索引和数据分开存放这一点看, PostgreSQL 普通 heap 表的索引都类似二级索引, 主键索引也是一样. Heap 页里的记录独立于各个索引的键顺序. 如果索引只存 heap 页号, 回表还得遍历页里的 record 找匹配. InnoDB 的记录按主键组织在聚簇树里, 二级索引拿到主键后可以继续查主键树, 到叶子页按主键顺序找记录.

PostgreSQL 的 B-tree 叶子项保存 heap TID. 6 字节的 TID 由 block number 和 line pointer 槽号组成, 取到 heap 页后可以直接访问这个槽.

```text
索引键 → B-tree 叶子项 → TID (42, 7)
       → heap block 42 → line pointer slot 7 → tuple
```

Heap 直接取 pd_linp[slot - 1]. 一条 line pointer 占 4 字节, 普通槽的 lp_off 存 tuple 的字节偏移. 有了槽号, 各个索引可以直接定位 tuple, heap 页可以独立于索引的键顺序组织数据. HOT pruning 可以把根槽改成 LP_REDIRECT, 从这个槽进入同页的版本链. [PostgreSQL 页布局](https://www.postgresql.org/docs/current/storage-page-layout.html) · [HOT 说明](https://www.postgresql.org/docs/current/storage-hot.html)

PageRepairFragmentation 压紧 tuple 字节区, 保留仍在使用的槽号. 移动 tuple 后, 更新原槽的 lp_off, 索引保存的 TID 继续有效. 有索引引用的死亡槽可以先保留为 LP_DEAD, 待 VACUUM 清理对应的索引项后转为 LP_UNUSED.

INSERT 可以复用中间的空槽和页内空闲字节. 槽号为 1, 2, 3 的三条记录, 删除槽 2 对应的 tuple 并完成安全回收后, 新记录可以使用槽 2, 原来槽 3 的记录继续使用原 TID. 连续位于槽数组尾部的空槽可以通过收缩 pd_lower 截掉.

普通 VACUUM 可以整理页内的 tuple 字节, 存活 tuple 仍使用原来的 TID. VACUUM FULL 持有目标表的 AccessExclusiveLock, 把存活行写到新的 heap, 再为新 TID 重建索引. [PostgreSQL VACUUM](https://www.postgresql.org/docs/current/routine-vacuuming.html)


这里很容易有一个问题, PostgreSQL 为什么不像 InnoDB 一样, 指向 page 就够了, 然后再 page 里面查找, 而需要一个 line pointer slot, 这样如果我对这个 page 做整理, 删除掉一些 page 里面的 record 以后, 这些 line pointer slot 顺序改变了以后, 这些 tid 也就也需要跟着修改了. 这样成本不是很大么? 并且这些 line pointer slot 永久都不能删除呢?

本质还是 pg 上面类似都是二级索引, 所以如果跳转到 heap 页上面需要遍历所有的 record 才可以找到匹配的, 而 mysql 是 pk 索引, 二级索引也是通过主键找到 pk, 然后再通过 pk 找对应的 record 的,  这样就不需要存具体位置, 因为已经按照 pk 排好序了.

#### DuckDB 的 rowid

DuckDB 的 rowid 是一个 int64_t. RowIdColumnData 直接根据 RowGroup 起点和组内行序号生成这个虚拟列.

```text
rowid = RowGroup.row_start + 组内行序号

ART(key) → rowid → 找覆盖该编号的 RowGroup
                 → rowid - RowGroup.row_start
                 → 对每列找 ColumnSegment
                 → 按段内行序号解码列值
```

一个 RowGroup 覆盖一段行编号范围, 各列可以存放在不同的 block. 组内行序号用来对齐各列. ColumnData::FetchRowsAtSegmentLevel 对每列按行号找 segment, 减掉 segment 起点后把段内行号交给 codec. 每个 segment 单独维护 block_id, block_offset 和压缩方式. [DuckDB 列内定位源码](https://github.com/duckdb/duckdb/blob/d54cbbe3df17e8e5ce68312f483b4155836112aa/src/storage/table/column_data.cpp#L783-L805)

列段重写可以重新分配 block, 改变压缩方式和段边界. 只要行编号保持原值, ART 就可以继续引用同一个 rowid. 连续且没有删除洞的 RowGroup 也可以合并, 保留原来的全表行编号.

UPDATE, DELETE 和 late materialization 都用 rowid 定位行. WAL 的删除和更新记录也带 rowid, 重放时用它找到目标位置. [WAL 写入源码](https://github.com/duckdb/duckdb/blob/d54cbbe3df17e8e5ce68312f483b4155836112aa/src/storage/write_ahead_log.cpp#L515-L535)

#### DuckDB 的 page 整理

DuckDB 的 DELETE 在 RowGroup 的版本信息里标记删除. 普通 INSERT 按 next_row_id 从表尾追加. 原有 rowid 为 0, 1, 2 时, 删除 1 再插入一行, 新行拿到 3, 表里可见的 rowid 为 0, 2, 3. 删除位置继续留在原组中. [追加位置的分配](https://github.com/duckdb/duckdb/blob/d54cbbe3df17e8e5ce68312f483b4155836112aa/src/storage/data_table.cpp#L1055-L1064)

DuckDB 通过 RowGroup 合并重写清理这些删除位置. Checkpoint 根据相邻候选组的活行数, 判断能否把存活行装进更少的新组. 调度条件是 target_count < merge_count, 即输出组数少于输入组数. 删除越多, 活行就越容易装进更少的组, 具体任务还受容量, 尾部最小合并规模, max_vacuum_tasks 和索引策略约束. [RowGroup 整理调度](https://github.com/duckdb/duckdb/blob/d54cbbe3df17e8e5ce68312f483b4155836112aa/src/storage/table/row_group_collection.cpp#L1580-L1708)

一个部分删除的 RowGroup, 即使只剩很少的活行, 单组的 1 → 1 整理也不满足这个调度条件. 没有合适的邻组时, 删除洞会继续保留. 保留组仍可以重写列段和压缩 MVCC 版本信息. 全部删除的 RowGroup 则走单独的丢组路径, 是否能保留它留下的 rowid gap 取决于存储格式和索引维护策略. [全删组处理](https://github.com/duckdb/duckdb/blob/d54cbbe3df17e8e5ce68312f483b4155836112aa/src/storage/table/row_group_collection.cpp#L1517-L1575)

合并移除删除位置以后, 部分存活行可能得到新的行序号. 如果索引采用 REMAP 策略, DuckDB 收集实际改了编号的行, 对每个索引先删除旧 (key, rowid), 再插入新的引用. 其他策略可以重建索引, 或保留行编号并限制会改号的整理. [ART remap 源码](https://github.com/duckdb/duckdb/blob/d54cbbe3df17e8e5ce68312f483b4155836112aa/src/storage/index_entry.cpp#L439-L454)
这也是在 DuckDB 里面如果有了 ART 索引以后, rowgroups 的整理就需要考虑对应的ART 指向的 rowid 也要修改了.


其实这里的设计和 PostgreSQL 是很像的, PostgreSQL 里面用 tid 指向 heap page 上的 heap number 和 line pointer, 区别的地方在于 PostgreSQL 在 page 整理的时候, 如果这个record 在这个 page 上面没有被删除, 那么它的 tid 是一直不会变的, 被删除的空间在经过 vacuum 以后会留给后续的写入复用, 所以上面对应的 index 就都不需要修改.
但是 DuckDB 的 checkpoint 的时候, 是有可能把相邻的 rowgroup 进行合并的, 那么合并以后这个记录所在的 rowid 就发生了变化了, 那么 ART Index 就必须跟着修改了.

