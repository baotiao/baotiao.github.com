---

layout: post
title: DuckDB MVCC 和 two values limit issue
summary: DuckDB MVCC 和 two values limit issue

---

```c++
#include "duckdb.hpp"

#include <iostream>
#include <string>

using namespace std;
using namespace duckdb;

int main() {
  DuckDB db("/home/zongzhi.czz/git/duckdb/lab/a100");

  Connection conn0(db);
  Connection conn1(db);
  Connection conn2(db);
  Connection conn3(db);
  Connection conn4(db);

  conn0.Query("drop table employees");
  conn0.Query("CREATE TABLE employees (id INTEGER primary key, name VARCHAR, age INTEGER, department VARCHAR);");

  auto r1 = conn0.Query("INSERT INTO employees VALUES (1, 'Alice', 30, 'HR');");

  r1 = conn0.Query("begin;");
  r1 = conn0.Query("select * from employees;");
  //r1 = conn0.Query("commit;");


  // trx1
  r1 = conn1.Query("begin");
  r1 = conn1.Query("delete from employees where id = 1");
  r1 = conn1.Query("INSERT INTO employees VALUES (1, 'Alice', 30, 'HR');");
  r1 = conn1.Query("commit;");
  r1->Print();

  // trx2
  r1 = conn3.Query("begin;");
  r1 = conn3.Query("delete from employees where id = 1");
  r1 = conn3.Query("INSERT INTO employees VALUES (1, 'Ae', 30, 'HR');");
  r1 = conn3.Query("commit;");
  r1->Print();

  printf("end\n");
  return 0;
}
```



TransactionContext Error: Failed to commit: write-write conflict on key: "1"

这里会报错 write-write conflict on key: "1".  我们也管这个问题叫 two-value limit issue.

但是我们可以看到, trx0 开启了一个长事务并未提交, trx1 和 trx2 都对 id = 1 这一行进行了修改, 正常的数据库 MVCC 实现, 因为 trx1 已经 commit 了, 所以 trx2 是可以对 id = 1 这一行进行修改了, 但是在 DuckDB 这里却无法修改, 修改了会报  write-write conflict on key: "1".

这里需要回顾一下 DuckDB MVCC 参考的 HyPer-style 设计

DuckDB 的 MVCC 实现参考 [Fast Serializable Multi-Version Concurrency Control for Main-Memory Database Systems](https://db.in.tum.de/~muehlbau/papers/mvcc.pdf) 实现

在这个 MVCC 实现里面, 有三个变量: transactionID, starTime-stamps, commitTime-stamps

transactionID 和 starTime-stamps 是启动的时候就赋值的. starTime-stamps 是从 0 开始增长, transactionID 是从 2^63 次方开始增长. commitTime-stamps 是在提交的时候才会赋值, 用的是和startTime-stamps 相同的递增的变量.

为什么要这样设计?

主要用途是事务运行过程中对于每一个行的修改记录的是 transactionID, 而这个 transactionID 是一个非常大的值, 那么对于这个值就只有当前职务能够看到了.



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

比如事务 trx5, 虽然 starTime = T7, 比 trx3 的starTime 要来的大, 但是根据下面的可见性判断可以看到, 由于trx5.transactionID != undo buffer of Ty, 并且trx5.startTime < undo buffer of Ty, 那么 undo buffer of Ty 就是对trx5 是不可见的.



大部分的数据库都是 mvcc + latch 实现, 比如 InnoDB, PostgreSQL 这种, 但是在 duckdb 的实现里面, 并没有使用 latch, 而是单纯的 optimistic mvcc, 如果遇到冲突的 key, 那么就直接将 transaction abort 报错.

为什么可以这样的设计?

optimistic 适合冲突比较小的场景, pessimistic 适合冲突多一点的场景.

但是其实 optimistic 适合小事务多一些, 因为一旦回滚, 小事务的开销是小一些, 而 pessimistic 其实更适合大事物, 因为大事物回滚的开销大, 那么就尽可能在修改的时候提前加锁, 避免回滚.

但是其实同样是 SI,  PostgreSQL  和 MySQL 实现也不一样. PostgreSQL 在这样的场景下, 如果有部分事务冲突, 那么默认行为是整个事务都回滚, 但是 MySQL 实现的是"**Write committed Repeatable Read**." 部分事务冲突, 依然可以提交.



为什么 DuckDB 要这样设计? 是 DuckDB 的 MVCC 无法实现还是有什么其他的考虑?

从上面可以看到 Thomas Neumann 介绍的 HyPer-style MVCC 机制从上面会把历史版本保留在 undo buffer 里面, 通过把 undo buffer 串联起来就可以实现多个历史版本的存储, 只要内存允许, 可以有任意长度的 undo chain. 这样设计可以避免上述场景的 write-write conflict 错误. 为什么 duckdb 这里不这么做呢?



我理解主要是 DuckDB 这里的定位问题, 其实 DuckDB 完全也可以把 undo buffer 串联起来, 从而实现多版本的.

DuckDB is an **in-process analytical database management system**. It is optimized for **OLAP** workloads, vectorized query execution, and **single-node performance**. DuckDB does not aim to support complex multi-user concurrent workloads like PostgreSQL or MySQL.

也就是 DuckDB 希望更加简单, 重点解决单节点写入+ OLAP 分析场景, 不希望解决在长事务+写热点场景的问题.

所以虽然 DuckDB 参考 HyPer-style MVCC, 但是 HyPer 更多定位的是内存数据库, 偏向于OLTP 场景.



在这个回答下面也看到对 DuckDB 的定位.  https://github.com/duckdb/duckdb/issues/1119

