---
layout: post
title: Innodb Physiological Logging
summary: Innodb Physiological Logging
---


为什么InnoDB 的redo log 是**Physiological logging**?

有一个存储的同学来问, 如果redo log 是纯physical log 的话, 那么就可以省去double write buffer 的开销, 保证每一次修改都是在4kb以内(由操作系统保证4kb以内的原子操作), 那么就不存在应用redo 到不新不旧的page 上的问题, 就不需要double write buffer.

目前主要有两种Logical logging and Physical logging.

Logical logging 像Binlog 这种, 记录的是操作, 跟物理格式无关, 所以通过binlog 可以对接不同的存储引擎.

Physical logging 是纯物理格式, byte for byte 的记录数据的改动, 比如 [start, end, 'xxxxx'] 这样的格式内容改动.



**Physical logging** 的优点是高效率, 并且可以直接修改物理格式, 任何操作都不需要重新遍历btree 到指定page.

但是缺点也很明显, 记录的内容非常冗余, 比如一次delete 操作, logical logging 只需要记录MLOG_COMP_REC_DELETE offset 就可以, 实际执行的过程中会修改prev record->next_record, next_record->prev_record, checksum, PAGE_DIR_SLOT_MIN_N_OWNED, 可能还需要更新dir slot 信息等等. 如果改成physical logging 那么这些信息涉及到的内容在page 不同位置, 那么需要记录的日志就非常多了.

另外在page reorgnize 或者 SMO 场景需要记录大量的无用日志, 比如当一个page 内部有过大量的删除, 有碎片需要整理的时候, 因为需要重新组织page结构, 如果physical logging 那么就需要一个一个record 重新insert 到当前page, offset 需要重新记录, 而logical logging 就只需要记录MLOG_PAGE_REORGANIZE 就可以了. 对比一下16kb 的page 只需要记录几个字节, 而physical logging 需要写差不多16kb 的内容了.



**Logical logging** 的优点是记录非常高效, 如上面说的delete 操作, 只需要记录几个字节, 在SMO, page reorgnize 等场景更加明显.

但是最大的缺点也很明显, 因为记录的是record_id, 那么所有改动就需要重新遍历btree, 因为都需要对btree 进行修改, 那么就得走加index lock, 串行修改的逻辑. 而物理日志因为page 之前完全没有依赖, 那么就可以并行回放, 这样crash recovery 的效率最高的.



在[ARIES](./https://cs.stanford.edu/people/chrismre/cs345/rl/aries.pdf) 文章之后, 大部分的商业数据库选择的是"Physiological Logging",  也就是"physical to a page, logical within a page.", InnoDB 也是这样, 尽可能将Logocal logging 和 Physical logging 的优点结合在一起.

记录的redo log 的格式是操作类型, 有些操作类型需要修改record 的话会记录offset. 大量的操作是一些逻辑操作, 比如 MLOG_1BYTE/MLOG_2BYTE/MLOG_INIT_FILE_PAGE 等等.

对于insert/update/delete 等等操作可以保证到记录到page level, 那么在crash recovery 的时候, 就可以并行的回放日志不需要重新执行btree 遍历找到page逻辑, 从而加快crash recovery.

当然现在InnoDB 的日志还有一些冗余的地方, PolarDB 也做了一些改进, 比如增加了record 长度信息, 减少了连续mtr 里面page id 记录等等, MariaDB Marko 也一直在优化这块 [MDEV-12353](./https://jira.mariadb.org/browse/MDEV-12353). 整体而言都是为了在page 内部的Logical redo 尽可能高效并且减少冗余.



**Reference:**

1. C. Mohan, Don Handerle**.** ARIES: A Transaction Recovery Method Supporting Fine-Granularity Locking and Partial Rollbacks Using Write-Ahead Logging.
2. C. Mohan, Frank Levine. ARIES/lM: An Efficient and High Concurrency index Management Method Using Write-Ahead Logging.
