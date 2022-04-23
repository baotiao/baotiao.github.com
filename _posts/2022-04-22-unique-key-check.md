---
layout: post
title: MySQL unique key check issue
summary: MySQL 历史悠久的unique check 问题, 官方一直没有解决的问题
---

### InnoDB unique check 的问题



unique secondary index 是客户经常使用的场景, 用来保证index 上的record 的唯一性. 但是大量的客户在使用unique secondary index 以后会发现偶尔会有死锁或者不应该锁等待的时候却发生锁等待的情况. 也有很多客户来问我们这个问题. 

理论上PolarDB 默认使用read-commit isolation level,  在rc 隔离级别下绝大部分场景不会使用GAP lock, 因此死锁的概率应该是比较低的. 这又是为什么呢?

关于InnoDB 事务锁介绍可以看这个[InnoDB lock sys](http://mysql.taobao.org/monthly/2016/01/01/)

其实这个问题是已经有十年历史的老问题, 也是官方一直没解决的问题. 

https://bugs.mysql.com/bug.php?id=68021



我们用这个bug issue 里面的case 描述一下这个问题



```sql
-- Prepare test data
CREATE TABLE `ti` (
  `session_ref_id` bigint(16) NOT NULL AUTO_INCREMENT,
  `customer_id` bigint(16) DEFAULT NULL,
  `client_id` int(2) DEFAULT '7',
  `app_id` smallint(2) DEFAULT NULL,
  PRIMARY KEY (`session_ref_id`),
  UNIQUE KEY `uk1` (`customer_id`,`client_id`,`app_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

INSERT INTO ti (session_ref_id, customer_id, client_id, app_id) VALUES (4000, 8000, 10, 5);
INSERT INTO ti (session_ref_id, customer_id, client_id, app_id) VALUES (4090, 9000, 10, 5);
INSERT INTO ti (session_ref_id, customer_id, client_id, app_id) VALUES (6000, 10000, 10, 5);
INSERT INTO ti (session_ref_id, customer_id, client_id, app_id) VALUES (7000, 14000, 10, 5);
```



session 1 删除这一行(4090, 9000, 10, 5); 然后再insert 一个二级索引一样的一行 (5000, 9000, 10, 5);

```mysql
-- session 1
session1 > start transaction;
Query OK, 0 rows affected (0.00 sec)

session1 > DELETE FROM ti WHERE session_ref_id = 4090;
Query OK, 1 row affected (0.00 sec)

session1 > INSERT INTO ti (session_ref_id, customer_id, client_id, app_id) VALUES (5000, 9000, 10, 5);
Query OK, 1 row affected (0.00 sec)
```



接下来问题出现了.

可以看到插入 (NULL, 8001, 10, 5) 这一行的时候出现了锁等待, 理论上不应该有锁等待的, 因为pk 是自增, 而二级索引(8001, 10, 5) 并没有和任何record 冲突, 为什么会这样呢?

而插入 (NULL, 7999, 10, 5) 却没有问题, 二级索引(7999, 10, 5) 同样也没有和任何二级索引冲突

```mysql
-- session 2
session2 > set innodb_lock_wait_timeout=1;
Query OK, 0 rows affected (0.00 sec)

session2 > start transaction;
Query OK, 0 rows affected (0.00 sec)

session2 > INSERT INTO ti (session_ref_id, customer_id, client_id, app_id) VALUES (NULL, 8001, 10, 5);
ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction

session2 > INSERT INTO ti (session_ref_id, customer_id, client_id, app_id) VALUES (NULL, 7999, 10, 5);
Query OK, 1 row affected (0.00 sec)
```



查看事务锁信息可以看到

```mysql
mysql> select ENGINE_TRANSACTION_ID, index_name, lock_type, lock_mode, LOCK_STATUS, lock_data  from performance_schema.data_locks;
+-----------------------+------------+-----------+------------------------+-------------+--------------+
| ENGINE_TRANSACTION_ID | index_name | lock_type | lock_mode              | LOCK_STATUS | lock_data    |
+-----------------------+------------+-----------+------------------------+-------------+--------------+
|              99537179 | NULL       | TABLE     | IX                     | GRANTED     | NULL         |
|              99537179 | uk1        | RECORD    | X,GAP,INSERT_INTENTION | WAITING     | 9000, 10, 5  |
|              99537176 | NULL       | TABLE     | IX                     | GRANTED     | NULL         |
|              99537176 | PRIMARY    | RECORD    | X,REC_NOT_GAP          | GRANTED     | 4090         |
|              99537176 | uk1        | RECORD    | X,REC_NOT_GAP          | GRANTED     | 9000, 10, 5  |
|              99537176 | uk1        | RECORD    | S                      | GRANTED     | 9000, 10, 5  |
|              99537176 | uk1        | RECORD    | S                      | GRANTED     | 10000, 10, 5 |
|              99537176 | uk1        | RECORD    | S,GAP                  | GRANTED     | 9000, 10, 5  |
+-----------------------+------------+-----------+------------------------+-------------+--------------+
```

session1 在uk1 上持有(10000, 10, 5), (9000, 10, 5) 上面的next-key lock.

session2 插入(8001, 10, 5) 这一行记录的时候, 走的是正常的insert 逻辑, 最后在插入的时候需要申请insert record 的下一个key 上面的GAP\| insert_intention lock.  和trx1 上面持有的(9000, 10, 5) next-key lock 冲突了, 所以需要等待.

而如果插入的记录是(7999, 10, 5) 需要申请的insert record 下一个key 是(8000, 10, 5) 的 GAP \| insert_intention lock, 那么自然没有冲突, 那么就能够插入成功.



那么为什么session1 需要持有 next-key lock, 我们需要先了解二级索引的unique check 的流程是怎样的?

以下是 pseudocode

```
    find the B-tree page in the secondary index you want to insert the value to
    assert the B-tree page is latched
    equal-range = the range of records in the secondary index which conflict with your value 
    if(equal-range is not empty){
      release the latches on the B-tree and start a new mini-transaction
      for each record in equal-range
        lock gap before it, and the record itself (this is what LOCK_S does)
      also lock the gap after the last(equal-range)
      also (before Bug #32617942 was fixed) lock the record after last(equal-range)
      once you are done with all of the above, find the B-tree page again and latch it again
    }
    insert the record into the page and release the latch on the B-tree page.
```

可以看到在二级唯一索引插入record 的时候, 分成了两个阶段

1. 判断当前的物理记录上是否有冲突的record(delete-marked 是不冲突)
2. 如果没有冲突, 那么可以执行插入操作

这里在阶段1 和 阶段2 之间必须有锁来保证(可以是lock, 也可以是latch), 否则阶段1 判断没有冲突可以插入的时候, 但是在阶段1和阶段2 之间另外一个事务插入了一个冲突的record, 那么阶段2 再插入的时候其实是冲突了.

所以当前的实现如果gap 上存在至少一个相同的record, 大概率是delete-marked record, 那么需要给整个range 都加上gap X lock, 加了gap X lock 以后就可以禁止其他事务在这个gap 区间插入数据, 也就是通过lock 来保证阶段1和阶段2的原子性.

如果gap 上没有相同的record, 那么就不需要进任何gap lock.

比如只包含pk, sk 的一个table.

已经存在的二级索引记录 <1, 1>, <4, 2>, <10(delete-mark), 3>, <10(d), 8>, <10(d), 11>, <10(d), 21>, <15, 9>  需要插入二级索引<10, 6>, 那么就需要给<10, 3>, <10, 8>,<10,11>,<10,21>, <15, 9> 都加上next-key lock.

注意: 这里<15, 9>也需要加上next-key lock, 为的是保证像<10, 100> 这样的record 也不允许插入的. 但是如果这里<15, 9> 是<15000, 9> 那么这里被锁住的gap 区间就非常非常大了, 也是上述issue 遇到的问题.

具体实现在row_ins_scan_sec_index_for_duplicate() 中.



如果把这个next-key lock 去掉会有什么问题?

其实官方做过这个改动, 但是这个改动带来了严重的 [bug#73170](https://bugs.mysql.com/bug.php?id=73170), 会导致二级索引的唯一性约束有问题, 出现unique-index 上面出现了相同的record. 所以官方后来快速把这个fix 又revert掉了, 这个问题也就一直没解决了. 为什么会这样呢?



我们简化一下上述的二级索引, 把(9000, 10, 5) 简化成9000, 因为(10, 5) 都是一样的. 下图是二级索引在page 上的一个简化结构.

红色表示record 已经被删除, 蓝色表示未被删除.

那么如果像官方一样把next-key lock 改成 record lock 以后, 如果这个时候插入两个record (99, 13000), (120, 13000). 

第一个record 在unique check 的时候对 (13000, 100), (13000, 102), (13000, 108)..(13000, 112) 所有的二级索引加record S lock, insert 的时候对 (13000, 100) 加GAP \| insert_intention lock.

第二个 record 在unique check 的时候对(13000, 100), (13000, 102), (13000, 108)..(13000, 112) 所有的二级索引加record S lock. insert 的时候对 (13000, 112)加 GAP \| inser_intention lock.

那么这时候这两个record 都可以同时插入成功, 就造成了unique key 约束失效了.



具体的mtr case 可以看[bug#68021](https://bugs.mysql.com/bug.php?id=68021) 上面我写的mtr.



![](https://raw.githubusercontent.com/baotiao/bb/main/uPic/%E6%9C%AA%E5%91%BD%E5%90%8D%E6%96%87%E4%BB%B6.png)


那官方打算如何修复这个问题呢?

主要是两个思路

1. 我们知道InnoDB 的lock 必须遵守2PL 的原则, 也就是这个原因这里next-key lock 用于做Unique check 判断完成以后不能马上释放, 必须等到事务结束才能够释放. 因此官方希望区分真正的用于事务的lock 和 用于Unique check 的lock, 这两种类型的lock 的生命周期应该是不一样的, 前者需要等到事务结束才能够释放, 后者可以在当前STATEMENT 结束以后就可以释放, 当然就像issue 里面Fungo 提出理论上应该昨晚unique check 判断以后就马上释放, STATEMENT这个生命周期还是太大了, 如果在insert into values 场景, 前面的insert 还是影响到后面的insert 了.

   官方已经在一些地方增加了 lock_duation_t::AT_LEAST_STATEMENT 这个类型, 但是这里麻烦的地方在于InnoDB 的lock 还存在锁继承和锁复用, 比如当前需要申请一个GAP lock 的时候, 当前事务因为unique check 已经有了该GAP lock, 那么这次申请直接返回ture 了, 因为当前的实现默认是所有的lock 都在事务提交的时候一起释放. 但是现在如果unique check 申请的GAP lock 提前释放了, 那么这里就冲突了, 因此锁复用的时候就也需要考虑声明周期了. 

   另外就是锁继承, 如果在gap 中间有record 被purge 或者插入了一个新的record, 那么就继承了一个生命周期是STATEMENT 的场景, unique check 引入的GAP lock 释放的时候该lock 也要释放.

   这些问题都非常的细碎, 所以官方也在慢慢的修复之中

2. 另外一个思路是通过latch 来做unique check 而不是lock. 我们知道latch 的生命周期远远小于lock, 通常来说latch=short-lived, lock=long-lived, 可以在mtr 提交的时候就可以释放.

   但是带来的问题是, 如果有大量的delete-marked record, 那么就会覆盖到多个page, 那么mtr 持有的latch 就会很多, 我们知道mtr 是InnoDB Btree 修改的最小单位, 如果mtr 持有的page latch 过多, 那么Btree 的并发性能是必然下降的.

   另外因为Undo purge 等等操作需要持有page latch 进行, 那么可能造成持有Page latch 的过程中是进行IO 操作, 那么持有latch 的时间肯定较长, 造成unique-check 判断时间过长. 对于latch 的冲突和lock 的冲突处理方式完全不一样, latch 冲突是当前线程等待的方式, lock 冲突以后, 当前事务会进入到事务锁等待, 等冲突的lock 释放以后重新唤醒的过程. 具体可以看[Goetz 的文章](https://15721.courses.cs.cmu.edu/spring2019/papers/06-indexes/a16-graefe.pdf).

   其实这也是Fungo 在issue 里面回复的PostgreSQL 的做法, PostgreSQL 在做unique check 的时候对于第一个page 是X latch, 后面的page 通过latch coupling 进行page latch 的持有和释放.



我在 issue 里面也提出我的改法.

在row_ins_scan_sec_index_for_duplicate() 函数里面将next_key lock 改成record lock, 然后在insert 阶段, 通过将 insert 时候申请的

LOCK_X \| LOCK_GAP \| LOCK_INSERT_INTENTION;  改成 => 

LOCK_X \| LOCK_ORDINARY \| LOCK_INSERT_INTENTION;

那么就变成持有record lock, 等待LOCK_ORDINARY \| LOCK_INSERT_INTENTION, 那么session2/session3 就会互相冲突, 那么就无法同时插入..

**insert 的时候为什么要持有LOCK_GAP 而不是 LOCK_ORDINARY ?**

比如原有record 1, 4, 10 需要插入record 6, 7

那么trx 去抢的都是record 10 的lock, 因为此时6, 7 都还未在btree 中, record 10 是next record..如果加的是10 上面的 LOCK_ORDINARY, 那么两个非常简单的insert 6, 7 就会互相等待死锁了..

因此只能加LOCK_GAP.

但是这里对于有可能冲突的SK, 互相死锁则是想要的, 比如如果现有的record



<1, 1>, <4, 2>, <10(delete-mark), 3>, <10(d), 8>, <10(d), 11>, <10(d), 21>, <15, 9>  需要插入

trx1: <10, 6>,  trx2: <10,7> 

trx1 先插入成功, 然后是trx2.

第一步的时候给 <10, 3><10,8><10,11><10,21> 加record s lock.

插入的时候判断 插入的位置在<10,3><10,8> 之间, 有10, 那么就可以申请的时候 <10, 8> 的 LOCK_X \| LOCK_ORDINARY \| insert_intention,   和已经持有record s lock 互相冲突, 已经是死锁了



如果插入<10,6><10,9> 也一样

第一步给所有<10, x> 都加record s lock

插入的时候,  trx1 申请<10, 8> LOCK_ORDINARY, 持有trx2 想要的<10, 11> record s lock, trx 申请<10, 11> LOCK_X \| LOCK_ORDINARY, 持有trx1 想要的<10, 8> record s lock 因此也是互相死锁冲突的.



最后再拓展一下, primary key 也是unique key index, 为什么primary key 没有这个问题?

本质原因是在secondary index 里面, 由于mvcc 的存在, 当删除了一个record 以后, 只是把对应的record delete marked, 在插入一个新的record 的时候, delete marked record 是保留的. 

在primary index 里面, 在delete 之后又insert 一个数据, 会将该record delete marked 标记改成non-delete marked, 然后记录一个delete marked 的record 在undo log 里面, 这样如果有历史版本的查询, 会通过mvcc 从undo log 中恢复该数据. 因此不会出现相同的delete mark record 跨多个page 的情况, 也就不会出现上述case 里面(13000, 100) 在page1, (13000, 112) 在page3.

那么在insert 的时候, 和上面的二级索引插入2阶段类似, 需要有latch 或者lock 进行保护, 这里primary index 通过持有page X latch 就可以保证两个阶段的原子性, 从而两次的insert 不可能同时插入成功, 进而避免了这个问题.



**结论:**

在delete + insert, insert ... on duplicate key update, replace into 等场景中, 由于在delete 之后, 在record 上还保留有next key lock, 那么在unique check 的时候会给所有的相同的record 和下一个record 加上next-key lock. 导致后续insert record 虽然没有冲突, 但是还是会被Block 住.


