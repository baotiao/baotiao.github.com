---
layout: post
title: Paper Review - Amazon Aurora
summary: Amazon Aurora 介绍

---

### [Paper review] Amazon Aurora 



最近Amazon 在 SIGMOD 发了AWS 上面号称比mysql 快5倍的RDS Aurora 的论文. 当年Amazon 发布Dynamo的论文时候, 让大家知道了原来Nosql 还可以这么搞, 就有了后来的百家齐放, 不知道Aurora 的效果如何.



Aurora 主要结构由 database 和 storage service 组成

Aurora 使用叫做以服务为中心的架构设计. 其实就是 database 节点都是无状态节点, 也就是只包含了(SQL + Transactions) 这两层. 所有的数据都存在storage service.  这里的storage service 使用的是Amazon S3 服务. 

Aurora 的核心思想还是把 sql 里面的计算和存储分开, 并且是直接通过修改mysql 5.6 代码的方法. 看图1 里面的核心架构就可以看得出来, 但是这样带来的问题是之前 中心化的结构都在单机上, 肯定没有问题, 那么这样计算和存储拆开以后, 性能问题如何解决, 所以一开始论文也是, 到最后瓶颈就在网络上了

![Imgur](http://i.imgur.com/6xY047A.jpg)





从上图可以看出AZ 有主从结构, 然后所有

* 那么接下来就是如何持久化数据的问题. 

Aurora 提供的也是Quorum 机制, Qurora 认为(2 + 2 > 3) 的quorum 机制是不安全的, 因此使用的是 (4 + 3 > 6) 的副本机制, 数据分布在3个AZ(Availability zone)(可以理解为Amazon 的每一个机房), 每一个Availability Zone 里面有两个副本的数据. 为什么2 + 2 > 3 的quorum 不安全呢?

在AZ A, B, C 三个副本的情况下, 每一个AZ 肯定都存在一些坏盘情况存在, 这个时候后台正在修复这些数据, 如果这个时候 AZ C 由于某些原因整个AZ挂了, 那么这个时候这些正在后台修理的这部分数据就无法满足 2/3 的Quorum, 因为可能这个数据写入在AZ C, 同时另一个副本在AZ A, 但是这块盘坏了,  剩余的一个在AZ B 里面的数据我们不知道是否是最新的, 只能等AZ C 恢复我们才能够知道.

因此我们使用 (4 + 3 > 6) 的机制, 这样能够处理即使整个AZ 都坏了, 并且有一个副本坏了, 也不影响一致性.  因此有了数据分布在3个AZ, 每个AZ有两个副本的设计. 这样的设计肯定能够保证在坏掉一个AZ 和一个storage node 的时候可以保证正常的读取, 在挂掉任意两个storage node 的时候能够保证写入.

* 另外一个就是数据恢复时间的问题?

为了解决数据恢复时间比较慢的问题, 将数据切成了10G 大小的PG(Protection Group), 和分片一样. 为什么要切的这么小呢? 

为了保证模型的可靠性, 那么我们必须满足连续两次的平均失效时间(MTTF Mean Time to Failure)小于修复他们其中任何一个的平均修复时间(MTTR Mean Time to Repair), 这也能理解 因为如果修复时间不能小于这个连续连个的失败时间, 就有可能照成第3个节点, 第4个节点失败, 而修复还没有结束, 那么就无法保证上诉的4/6 的qurom 的要求了.

那么如何减小MTTF 比较麻烦, 那么我们就想办法加快MTTR, 做法就是把数据裁剪成10G 大小的PG(Protection Groups), 这样对于一个PG 修复的时间在万兆网卡下, 差不多10s能够恢复.

什么时候我们能看到这种问题呢? 因为10G segment 可以在10 内修复. 那么我们需要有2个node 在10s 同时出错, 并且有一个不包含他们两个的AZ 也同时出错, 才会出问题. 这个在我们观察到的可能性很小

综上 storage service 整体架构

![Imgur](http://i.imgur.com/BhzOkP3.jpg)

可以看出Aurora AZ是有主从结构的存在, 数据被切分成多个PG(Protection Groups), 每一个PG 由6个segment 组成, segment大小是10G. 每个PG的6个segment分散在3个AZ 中, 每一个AZ的storage node 由多个 segment 组成, 所有的这些PG 的redo log最后都会存储在Amazon S3上



* 接下来就是核心叫 The log is the database

熟悉Raft 协议的同学就不会陌生, 就是raft 协议里面Log 和状态机的关系. 只要顺序apply log, 那么就可以生成对应时刻的状态机. 在Aurora 里面log 就是mysql 的redo log, 状态机就是这个Segment. 当然Aurora 并没有使用Raft/Multi-paxos 协议, 但是我感觉有点类似, 我们下面分析.

每一条redo log 有一个唯一的单调递增的 Log Sequence Number(LSN), 这个LSN 是由database 来生成, 从上面的架构图看估计是Dynamo DB. spanner 里面用的是时间戳. 

每一个独立的storage node 都需要保留自己的redo log stream, Aurora 认为 2PC 太繁琐,  容错太差, 因为写入并没有走2PC. 写入是Quorum 的, 不会保证每一个storage node 都有完整的redo log stream. 然后Aurora 通过gossip 协议不断去把每一个storage node 里面空缺的redo log 补上, 并更新DB 里面的内容. 这里就更Multi-Paxos 的写入过程基本一样

storage service 会确认一个最大的保证之前操作都已经写入的 LSN VCL(Volume Complete LSN). 像Raft 里面的log 一样, 可能存在写入的log, 最后没提交的情况. 

database 会通过标记的LSN 来对这些log 进行截断, 这种标记的LSN 叫做CPL(consistency Point LSNs), 这些CPL 里面比VCL 小的最大的那个叫做VDL(Volume Durable LSNs).  这个就跟Raft 里面的全局commit Index 类似. 一般每一个MTR(mini-transactions) 里面的最后一个记录是一个CPL.

SCL(segment complete LSN) 记录着每一个segment 已经确认commit 的 LSN, 相当于raft 里面的每一个节点自己的commit Index. Aurora 也会使用这个commit Index 来进行节点间交互去补齐log.

那么事务commit 的过程就是这样, 每一个事务都有一个对应"commit LSN", 那么这个事务提交以后就去做其他的事情, 什么时候通知这个事务已经提交成功呢? 就是当VDL(VDL 由databse 来发送, storage service来确认更新) 大于等于"commit LSN" 以后, 就会有一个专门的线程去通知这个等待的client, 你这个事务已经提交完成了. 

如果这个事务提交失败, 那么接下来的Recovery 是怎么处理的呢?

首先这个Recovery 是由storage node 来处理的,  是以每一个PG 为维度进行处理, 在database 起来的时候通过 quorum 读取足够多的副本, 然后根据副本里面的内容得到VDL, 因为每一个时候最后一条记录是一个CPL, 这些CPL 里面最大的就是VDL,  然后把这个VDL 发送给其他的副本, 把大于VDL 的redo log 清除掉, 然后恢复这个PG的数据



* 亮点

1. 项目直接从mysql 5.6 版本的代码剥离出来, 那么这样的换, SQL 协议兼容这块会做的比较容易了.
2. 计算和存储分开, 目前是这些分布式系统的通用实现了吧
3. Aurora 用了大量AWS 内部非常成熟的服务, 和 spanner-sql 类似, 目前来看基于稳定的Nosql 去实现Newsql 大家基本都是这个路子. 当然得有一个足够稳定的底层存储才行.
4. 每一个Protect Group 的内容是一个状态机, 对应的redo log 保存在Amazon S3 里面, 只需要通过顺序apply redo log 的内容就可以恢复这个Protect Group
5. 将redo log 做成异步, 这样带来好处可以惰性更新. 读取的时候如果这个page 还有没apply 的redo log, 就等待redo log apply 完成. 还有就是Rocovery 的时候非常的快, 不需要等redo log apply 完成再起来. 其实这又和raft 里面log 和 状态机的关系一样
6. 支持分布式的事务并没有通过2PC, 而是通过gossip+Quorum 机制来保证(跟Dynamo 通过gossip 来保证元信息的一致性一样的暴力, 哈哈), 在加上每一个redo log 有一个唯一的LSN 等等机制来实现强一致. 当然其实这里已经很类似raft 协议了

不过整个文章都没有讲到针对这种将storage, log 与计算层面分离以后, SQL 层面针对性的改动, 因为如果有范围查询的话以前在单机就本地执行就好, 但是现在这种架构需要生成多个请求去不同的storage-node 去请求数据. 倒是 Spanner: Becoming a SQL System 有大量的介绍, 回头可以看看

