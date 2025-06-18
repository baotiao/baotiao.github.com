---
layout: post
title: MySQL Repeatable-Read 的一些误解
summary: MySQL Repeatable-Read 的一些误解
---


##### 背景

首先1992 年发表的SQL Standard 对隔离级别进行的定义是根据几个异象(Dirty Read, Non-Repeatable Read, Phantom Read) , 当然这个定义非常模糊, 后面Jim Grey 也有文章说这个不合理, 然而此时MVCC, snapshot isolation 还没被发明. 等有snapshot isolation 以后发现snapshot isolation 能够规避Dirty Read, Non-Repeatable Read, 因此认为snapshot isolation 和 Repeatable-read 很像, 所以MySQL, Pg 把他们实现的snapshot isolation 就称为了Repeatable-read isolation.

另外snapshot isolation 其实也没有准确的定义, 因此MySQL 和 PG, Oracle 等等的实现也是有很大的区别的.



关于**snapshot isolation** 的定义:

> A transaction running in Snapshot Isolation is never blocked attempting a read as long as the snapshot data from its Start-Timestamp can be maintained.The transaction's writes (updates, inserts, and deletes) will also be reflected in this snapshot, to be read again if the transaction accesses (i.e., reads or updates) the data a second time.

这里对于snapshot isolation 的定义不论对于读操作和写操作都是读取snapshot 的版本, 这也是pg, oracle 等等版本实现的, 但是InnoDB 不是这样的. InnoDB 只有读操作读取到的是snapshot 的版本, 但是DML 操作是读取当前已提交的最新版本.



> When the transaction T1 is ready to commit, it gets a *Commit-Timestamp,* which is larger than any existing Start-Timestamp or Commit-Timestamp. The transaction successfully commits only if no other transaction T2 with a Commit-Timestamp in T1’s *execution interval* [*Start- Timestamp*, *Commit-Timestamp*] wrote data that T1 also wrote. Otherwise, T1 will abort. This feature, called *First- committer-wins* prevents lost updates (phenomenon P4).

对于 first-committer-wins 的定义, 在si 模式下, 如果在Start-Timestamp -> Commit-Timestamp 这之间如果有其他的trx2 修改了当前trx1 修改过的内容, 并且在trx1 提交的时候, trx2 已经提交了. 那么trx1 就会abort, 这个叫first-committer-wins. 

但是InnoDB 也不是这样的. InnoDB 并不遵守这个规则, 在repeatable read 模式下, 如果trx1, trx2 都修改了同一行, trx2 是先提交的, 那么trx1 的提交会直接把trx2 覆盖. 而在类似PG, Oracle 实现的snapshot isolation 里面, 则是遵守first-committer-wins 的规则.

所以InnoDB 的snapshot isolation 

1. 仅仅Read 操作读的是历史版本 
2. 不遵守first-committer-wins 规则

官方把这种实现叫做**Write committed Repeatable Read**.



MySQL 开发者对于InnoDB repeatable-read 实现的介绍:

> But when InnoDB Repeatable Read transactions modify the database, it is possible to get phantom reads added into the static view of the database, just as the ANSI description allows.  Moreover, InnoDB relaxes the ANSI description for Repeatable Read isolation in that it will also allow non-repeatable reads during an UPDATE or DELETE.  Specifically, it will write to newly committed records within its read view.  And because of gap locking, it will actually wait on other transactions that have pending records that may become committed within its read view.  So not only is an UPDATE or DELETE affected by pending or newly committed records that satisfy the predicate, but also 'SELECT … LOCK IN SHARE MODE' and 'SELECT … FOR UPDATE'.

> This WRITE COMMITTED implementation of REPEATABLE READ is not typical of any other database that I am aware of.  But it has some real advantages over a standard 'Snapshot' isolation.  When an update conflict would occur in other database engines that implement a snapshot isolation for Repeatable Read, an error message would typically say that you need to restart your transaction in order to see the current data. So the normal activity would be to restart the entire transaction and do the same changes over again.  But InnoDB allows you to just keep going with the current transaction by waiting on other records which might join your view of the data and including them on the fly when the UPDATE or DELETE is done.  This WRITE COMMITTED implementation combined with implicit record and gap locking actually adds a serializable component to Repeatable Read isolation.





PG 社区对于repeatable-read 实现的介绍:

> `UPDATE`, `DELETE`, `SELECT FOR UPDATE`, and `SELECT FOR SHARE` commands behave the same as `SELECT` in terms of searching for target rows: they will only find target rows that were committed as of the transaction start time. However, such a target row might have already been updated (or deleted or locked) by another concurrent transaction by the time it is found. In this case, the repeatable read transaction will wait for the first updating transaction to commit or roll back (if it is still in progress). If the first updater rolls back, then its effects are negated and the repeatable read transaction can proceed with updating the originally found row. But if the first updater commits (and actually updated or deleted the row, not just locked it) then the repeatable read transaction will be rolled back with the message

>  https://www.postgresql.org/docs/13/transaction-iso.html#XACT-READ-COMMITTED



所以这里我们看一下MySQL repeatable-read 的具体行为, 也了解MySQL社区为什么要做这样的实现.



```mysql
mysql> create table checking (name char(20) key, balance int) engine InnoDB;
Query OK, 0 rows affected (0.03 sec)

mysql> insert into checking values ("Tom", 1000), ("Dick", 2000), ("John", 1500);
Query OK, 3 rows affected (0.00 sec)
Records: 3  Duplicates: 0  Warnings: 0

Client #1                               Client #2
=====================================   =====================================
mysql> begin;
Query OK, 0 rows affected (0.00 sec)

mysql> select * from checking;
+------+---------+
| name | balance |
+------+---------+
| Dick |    2000 |
| John |    1500 |
| Tom  |    1000 |
+------+---------+
3 rows in set (0.00 sec)

mysql> begin;
Query OK, 0 rows affected (0.00 sec)

mysql> update checking
   set balance = balance - 250
   where name = "Dick";
Query OK, 1 row affected (0.00 sec)
Rows matched: 1  Changed: 1  Warnings: 0

mysql> update checking
   set balance = balance + 250
   where name = "Tom";
Query OK, 1 row affected (0.00 sec)
Rows matched: 1  Changed: 1  Warnings: 0

mysql> select * from checking;
+------+---------+
| name | balance |
+------+---------+
| Dick |    1750 |
| John |    1500 |
| Tom  |    1250 |
+------+---------+
3 rows in set (0.02 sec)
                                        mysql> begin;
                                        Query OK, 0 rows affected (0.00 sec)

                                        mysql> select * from checking;
                                        +------+---------+
                                        | name | balance |
                                        +------+---------+
                                        | Dick |    2000 |
                                        | John |    1500 |
                                        | Tom  |    1000 |
                                        +------+---------+
                                        3 rows in set (0.00 sec)
																				
                                        mysql> update checking
                                           set balance = balance - 200
                                           where name = "John";
                                        Query OK, 1 row affected (0.00 sec)
                                        Rows matched: 1  Changed: 1  Warnings: 0
																				
                                        mysql> update checking
                                           set balance = balance + 200
                                           where name = "Tom";

                                        ### Client 2 waits on the locked record
mysql> commit;
Query OK, 0 rows affected (0.00 sec)
                                        Query OK, 1 row affected (19.34 sec)
                                        Rows matched: 1  Changed: 1  Warnings: 0
mysql> select * from checking;
+------+---------+
| name | balance |
+------+---------+
| Dick |    1750 |
| John |    1500 |
| Tom  |    1250 |
+------+---------+
3 rows in set (0.00 sec)
                                        mysql> select * from checking;
                                        +------+---------+
                                        | name | balance |
                                        +------+---------+
                                        | Dick |    2000 |
                                        | John |    1300 | 
                                        | Tom  |    1450 |
                                        +------+---------+
                                        3 rows in set (0.00 sec)
																				# 这里可以看到Tom = 1450, 而不是从上面 1000 + 200 = 1200, 因为update 的时候, InnoDB 实现的是write-committed repeatable, 不是基于场景的snapshot isolation的实现, write 操作是直接读取的已提交的最新版本的数据1250, 而不是snapshot 中的数据1000.
																				
                                        mysql> commit;
                                        Query OK, 0 rows affected (0.00 sec)

mysql> select * from checking;
+------+---------+
| name | balance |
+------+---------+
| Dick |    1750 |
| John |    1300 |
| Tom  |    1450 |
+------+---------+
3 rows in set (0.02 sec)
```



这里可以看到Tom = 1450, 而不是从上面 1000 + 200 = 1200, 因为update 的时候, InnoDB 实现的是write-committed repeatable, 不是基于常见的snapshot isolation的实现, write 操作是直接读取的已提交的最新版本的数据1250, 而不是snapshot 中的数据1000.

对比在PG里面, 由于PG是使用常见的 snapshot isolation 实现repeatable-read, 那么trx2 在修改Tom 的时候, 同样必须等待trx1 commit or rollback, 因为PG 读取和修改基于trx 开始时候的snapshot 的record.

因此如果trx1 rollback, 那么trx2 则会基于开始snapshot 时候的值进行修改, 也就是Tom = 1200

```sql
zongzhi.czz@sbtest=# select * from checking;
┌──────────────────────┬─────────┐
│         name         │ balance │
├──────────────────────┼─────────┤
│ Dick                 │    2000 │
│ John                 │    1300 │
│ Tom                  │    1200 │
└──────────────────────┴─────────┘
```

如果trx1 commit, 那么trx2 会报如下错误, 也就是该条语句执行失败, 其他语句依然可以继续执行

ERROR:  could not serialize access due to concurrent update
```sql
# Client #1
zongzhi.czz@sbtest=# CREATE TABLE checking (
    name CHAR(20) PRIMARY KEY,
    balance INT
);
CREATE TABLE
Time: 2.733 ms
zongzhi.czz@sbtest=# INSERT INTO checking (name, balance)
VALUES
  ('Tom', 1000),
  ('Dick', 2000),
  ('John', 1500);
INSERT 0 3
Time: 1.123 ms
zongzhi.czz@sbtest=# begin;
BEGIN
Time: 0.081 ms
zongzhi.czz@sbtest=# update checking
   set balance = balance - 250
   where name = 'Dick';
UPDATE 1
Time: 0.470 ms
zongzhi.czz@sbtest=# update checking
   set balance = balance + 250
   where name = 'Tom';
UPDATE 1
Time: 0.206 ms

zongzhi.czz@sbtest=# select * from checking;
┌──────────────────────┬─────────┐
│         name         │ balance │
├──────────────────────┼─────────┤
│ John                 │    1500 │
│ Dick                 │    1750 │
│ Tom                  │    1250 │
└──────────────────────┴─────────┘
(3 rows)

Time: 0.124 ms
                                                # Client #2
                                                zongzhi.czz@sbtest=# select * from checking;
                                                ┌──────────────────────┬─────────┐
                                                │         name         │ balance │
                                                ├──────────────────────┼─────────┤
                                                │ Tom                  │    1000 │
                                                │ Dick                 │    2000 │
                                                │ John                 │    1500 │
                                                └──────────────────────┴─────────┘
                                                (3 rows)
                                                
                                                Time: 0.254 ms
                                                zongzhi.czz@sbtest=# update checking set balance = balance - 200 where name = 'John';
                                                zongzhi.czz@sbtest=# update checking set balance = balance + 200 where name = 'Tom';

zongzhi.czz@sbtest=# commit;
COMMIT
Time: 0.126 ms
zongzhi.czz@sbtest=# select * from checking;
┌──────────────────────┬─────────┐
│         name         │ balance │
├──────────────────────┼─────────┤
│ John                 │    1500 │
│ Dick                 │    1750 │
│ Tom                  │    1250 │
└──────────────────────┴─────────┘
(3 rows)
                                                ERROR:  could not serialize access due to concurrent update
                                                Time: 7686.578 ms (00:07.687)
                                                zongzhi.czz@sbtest=# select * from checking;
                                                ┌──────────────────────┬─────────┐
                                                │         name         │ balance │
                                                ├──────────────────────┼─────────┤
                                                │ Tom                  │    1000 │
                                                │ Dick                 │    2000 │
                                                │ John                 │    1300 │
                                                └──────────────────────┴─────────┘
                                                (3 rows)
                                                
                                                Time: 0.131 ms
                                                zongzhi.czz@sbtest=# commit;
                                                COMMIT
                                                Time: 0.114 ms
                                                zongzhi.czz@sbtest=# select *from checking;
                                                ┌──────────────────────┬─────────┐
                                                │         name         │ balance │
                                                ├──────────────────────┼─────────┤
                                                │ Dick                 │    1750 │
                                                │ Tom                  │    1250 │
                                                │ John                 │    1300 │
                                                └──────────────────────┴─────────┘
                                                (3 rows)
```


这里可以看到在 PG 里面最终的结果 Tom =1250, 而在 MySQL 里面 Tom =1450.  PG 实现了严格的基于快照的实现, 如果遇到冲突那么就报错, 而 mysql 是直接基于已提交的最新版本的数据进行更新.


那么MySQL 为什么要这么做呢?

MySQL 社区的观点是在常见的通过snapshot isolation 来实现repeatable Read 的方案里面, 经常会出现如果两个事务修改了同一个record, 那么就需要后提交的事务重试这个流程. 这种在小事务场景是可以接受的, 但是如果后提交的事务是大事务, 比如trx1 修改了1个record rec1并先提交了, 但是trx2 修改了100 行, 正好包含了rec1, 那么常见的snapshot isolation 的实现就需要trx2 这个语句报错, 然后重新执行这个事务. 这样对冲突多的场景是特别不友好的.

但是Innodb 的实现则在修改rec1 的时候, 如果trx1 已经提交了, 那么直接读取trx1 committed 的结果, 这样就可以避免了让trx2 重试的过程了. 也可以达到几乎一样的效果.

当然这样带来的后果是MySQL 的repeatable read 实现是不能规避Lost update 情况发生的.

当然这个仅仅MySQL InnoDB 是这样的实现, 其他的数据库都不会这样.

两种方案都有优缺点吧, 基于常见SI(snapshot isolation) 实现会存在更多的事务回滚, 一旦两个事务修改了同一个row, 那么必然有一个事务需要回滚, 但是InnoDB 的行为可以允许和其他trx 修改同一个record, 并且可以在其他trx 修改后的结果上进行更新, 不需要进行事务回滚, 效率会更高一些, 但是基于常见的snapshot isolation 的实现更符合直观感受.

