---

layout: post
title: DuckDB MVCC 简介 
summary: DuckDB MVCC 简介
---


 简单介绍一下 DuckDB MVCC 参考的 HyPer-style 设计

DuckDB 的 MVCC 实现参考 [Fast Serializable Multi-Version Concurrency Control for Main-Memory Database Systems](https://db.in.tum.de/~muehlbau/papers/mvcc.pdf) 实现

在这个 MVCC 实现里面, 有三个变量: transactionID, startTime-stamps, commitTime-stamps

transactionID 和 startTime-stamps 是启动的时候就赋值的.
transactionID 是从 2^63 次方开始增长, startTime-stamps 是从 0 开始增长, commitTime-stamps 是在提交的时候才会赋值, 用的是和startTime-stamps 相同的递增的变量.
所以 startTime-stamps 和 commitTime-stamps 都是一个比较小的值, 只有 transactionID 比较大.

为什么要这样设计?

主要用途是事务运行过程中对于每一个行的修改记录的是 transactionID, 而这个 transactionID 是一个非常大的值, 那么对于这个值就只有当前事务能够看到了.


**undo buffer 在事务运行的过程中先被 transactionID 赋值, 然后在事务提交的时候, undo buffer 会被commitTime-stamps 赋值, 从而保证了可见性.**


**Version Access 可见性判断函数**

v.pred = null ∨ v.pred.TS = T ∨ v.pred.TS < T.startTime

这个是读取到一个行的时候, 可见性判断条件

也就是如果这一行的没有older version  或者这一行的timestamp = 当前事务T 的transactionID 或者当前事务的timestamp < 当前事务 T的startTime-stamps

那么当前行对当前事务是可见的.





以下面的例子为例.

![image-20250616024701582](https://raw.githubusercontent.com/baotiao/bb/main/uPic/image-20250616024701582.png)

原本所有人的 Bal(balance) = 10, 发起了 3 个事务.

trx1: sally-> wendy 1 块钱

trx2: sally->Henry 1 块钱

trx3: sally->Mike 1 块钱.

trx4: 统计所有人的Bal, startTime = T4, transactionID = Tx

trx5: 统计所有人的 Bal, startTime = T7, transactionID = Tz

在 T3 的时间点trx1 提交了, 所以在 Undo buffer 里面可以看到 T3. 这个时候如果有事务trx4 在 T4 时间点进行读取, 读取到 sally, wendy 的 Bal 的时候, 都直接读取, 不需要读取 undo buffer 的内容.

重点是trx3, 由于 trx3 还未提交, Sally 指向的第一个undo buffer 记录sally -> Mike 这个操作, 但是还在进行中, Mike 还没有执行 Mike + 1 操作. 由于事务还未提交, 这个 undo buffer 时间戳就是 Ty, Ty 是trx3 的transactionID, 是一个非常大的值.

比如事务 trx5, 虽然 startTime = T7, 比 trx3 的startTime 要来的大, 但是根据下面的可见性判断可以看到, 由于trx5.transactionID != undo buffer of Ty, 并且trx5.startTime < undo buffer of Ty, 那么 undo buffer of Ty 对应的值 7 就是对trx5 是不可见的. 而 Undo buffer of T5 < T7, 那么 Ty, Bal,8 就是 trx5 可见的了.

(注意: 这里 Undo buffer timestamp 判断的是前向的 value, 如: undo buffer of Ty 对应的是 7 是否可见, undo buffer of T5 对应的是 8 是否可见)


DuckDB is an **in-process analytical database management system**. It is optimized for **OLAP** workloads, vectorized query execution, and **single-node performance**. DuckDB does not aim to support complex multi-user concurrent workloads like PostgreSQL or MySQL.

也就是 DuckDB 希望更加简单, 重点解决单节点写入+ OLAP 分析场景, 不希望解决在长事务+写热点场景的问题.

所以虽然 DuckDB 参考 HyPer-style MVCC, 但是 HyPer 更多定位的是内存数据库, 偏向于OLTP 场景.


在这个回答下面也看到对 DuckDB 的定位.  https://github.com/duckdb/duckdb/issues/1119

