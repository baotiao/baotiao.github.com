---
layout: post
title: MySQL 常见死锁场景 -- 并发Replace into导致死锁 

---



在之前的文章 [#issue 68021 MySQL unique check 问题](https://zhuanlan.zhihu.com/p/503880736)中, 我们已经介绍了在 MySQL 里面, 由于唯一键的检查(unique check), 导致 MySQL 在 Read Commit 隔离级别也需要添加 GAP lock, 导致有些比较奇怪情况下有一些锁等待.

另外一类问题是由于唯一键检查导致的死锁问题, 这类问题也非常多, 也是我们处理线上经常收到用户反馈的问题, 这里我们就分析几个这样死锁的 Case.



Replace into 操作是非常常用的操作, 很多时候在插入数据的时候, 不确定表中是否已经存在数据, 有没有唯一性的冲突, 所以会使用 replace into 或者 insert .. on duplicate update 这样的操作, 如果冲突就把对应的行给自动更新.

但是这样的操作在并发场景, 当存在唯一键的时候容易有死锁问题场景, 那么为什么会这样, 我们来看一个简单的 case:

通过GDB 和脚本可以复现以下死锁场景.

```mysql
create table t(a int AUTO_INCREMENT, b int, PRIMARY KEY (a), UNIQUE KEY (b));

insert into t(a, b) values (100, 8);
	
session1:
replace into t(a, b) values (10, 8);

session2:
replace into t(a, b) values (11, 8);
(40001): Deadlock found when trying to get lock; try restarting transaction
```



当然也可以通过这个脚本, 不需要 GDB 就可以随机复现:

```shell
#! /bin/bash

MYSQL="mysql -h127.0.0.1 -P2255 -uroot test"

$MYSQL -e "create table t(a int AUTO_INCREMENT, b int, PRIMARY KEY (a), UNIQUE KEY (b))"

while true
do

  $MYSQL -e "replace into t(b) values (8)" &
  $MYSQL -e "replace into t(b) values (8)" &
  $MYSQL -e "replace into t(b) values (8)" &

  wait;
done
```



这里在并发session1 和 session2 插入的时候, 就容易出现 Deadlock Lock 的问题, 类似用户并发插入数据的场景.

![image-20230608205808520](https://raw.githubusercontent.com/baotiao/bb/main/uPic/image-20230608205808520.png)

上面的死锁信息 Trx HOLDS THE LOCK 和 WAITING FOR THIS LOCK TO BE GRANTED 是一个错误的误导信息, 官方版本在新的版本中已经修复, 这里 HOLDS THE LOCK 是不对的, 其实还未持有 X lock.

这里看到 Trx 1 waiting 在 8, 100 next-key X lock 上.

然后 Trx2 持有 8, 100 next-key X lock, 但是 WAITING FOR 8, 100 insert_intention lock.

那么为什么会有死锁呢?

我们先看一下单个 replace into 的流程

**整体而言, 如果replace into 第1遍insert 操作的时候, 遇到unique index 冲牧, 那么需要重新执行update 操作或者delete + 重新insert 操作, 但是第1遍insert 操作失败添加的事务锁并不会释放, 而是等到整个事务提交才会释放, 原因当然是现在MySQL 2Phase Lock 机制要做的保证**

 replace into 大概代码如下:

```c++
所有replace into/on duplicate key update 这里execute_inner 执行的是Sql_cmd_insert_values => execute_inner() 方法

这里replace into/on duplicate key update 执行在这个循环里面

  if (duplicate_handling == DUP_REPLACE || duplicate_handling == DUP_UPDATE) {
    DBUG_ASSERT(duplicate_handling != DUP_UPDATE || update != NULL);
    while ((error = table->file->ha_write_row(table->record[0]))) {
		// ...
      if (duplicate_handling == DUP_UPDATE) {

	这里 branch 就是处理 on duplicate key update 的duplicate key 场景
	判断如果是 on duplicate key update 逻辑, 那么遇到error 以后, 就是用 table->file->ha_update_row 通过 update 进行更新
	      } else /* DUP_REPLACE */ {
	duplicate_handling == DUP_REPLACE 就是处理 replace into 错误场景
	在replace into场景中, 如果插入的key 遇到冲突的, 是如何处理的, 其实是分2种场景的:
	如果是 replace into 逻辑, 遇到 error 以后, 如果是冲突的是最后一个 unique index, 并且没有外键约束, 并且没有delete trigger 的时候, 那么和 on duplicate key update 一样, 使用 ha_update_row 通过 update 进行更新

	否则通过 delete + 重新 insert 来进行更新, 操作更多, 消耗也就更多.

	具体代码:
	如果ha_write_row() 失败, 那么会执行delete_row() 操作, 等这个操作执行完成以后, 又跳到这个while 循环进行重新insert
	if ((error = table->file->ha_delete_row(table->record[1]))) goto err;
	/* Let us attempt do write_row() once more */
	}
```



接下来是2个replace into 操作的时候, 如果Thread 1 停在replace into 第一个阶段, 也就是insert 遇到unique index 冲突, 此时持有8, 100 next-key lock.

这个时候第2个Thread 2也进行replace into 操作, 在进行唯一键冲突检测, 执行row_ins_scan_sec_index_for_duplicate() 的时候需要申请8, 100 next-key lock. 该lock 被thread 1持有, 那么只能进行等待.

接下来Thread 1 继续执行, 执行update 操作, 在InnoDB 里面, 对于二级索引而言需要执行delete, 然后再insert 操作, 在insert 的时候需要持有8, 100 insert intention lock. 目前 InnoDB insert intention lock 判断是否冲突的时候, 对应的 record 不论是有事务等待或者已经持有 next-key lock, 都算冲突. 此时Thread 已经等在8, 100 next-key lock 上, 那么 Thread 1 就无法获得 insert intention lock, 只能进行等待.

这里有一个问题: 为什么申请insert_intention 的时候,  如果有其他事务提前等待在这个 lock 的 next-key lock 上面, 那么这个 insert_intention 会申请失败?

![image-20230611025844248](https://raw.githubusercontent.com/baotiao/bb/main/uPic/image-20230611025844248.png)

在函数rec_lock_check_conflict() 解释了这个问题, 因为如果申请 intention lock 成功, 那么接下来的 insert 操作也就会成功, 那么原来等待这个 record 上面的trx 就变成需要等待 2 个 record 了.

比如如果之前 trx2 wait 在(4, 10] 这个 next-key lock 上, 如果允许 trx1 插入了 7,这个 record, 那么根据锁继承机制, 7 会继承 10 这个 record 上面的 next-key lock, 那么 trx2 就变成 wait 在两个 record 上, 也就变成 2 个 waiting lock 了, 那么现有这套锁等待唤醒机制就也要改了,  现在这套锁等待唤醒机制因此一个 trx 只会等待一个 lock, 在一个 lock 释放以后, 相应等待在这个 Lock 上面的 trx 就可以唤醒了.

因此为了规避这样的问题, MySQL InnoDB 里面如果申请 insert_intention lock 的时候, 如果有其他事务提前等待在这个 lock 的 next-key lock 上, 那么 insert_intention lock 是无法申请成功的.

那么现在的就过就是 Thread 2 等待 Thread 1 next-key lock 释放, Thread 1 等待 Thread 2 next-key lock 获得并释放, 出现了 Thread1 <=> Thread2 互相等待的情况 因此出现的死锁.

