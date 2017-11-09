---
layout: post
title: state machine replication vs primary backup system
summary: state machine replication vs primary backup system
 

---

最近在看zab, vr, raft, paxos 这些一致性协议的对比, 想找出共同点. 然后zab, vr 经常提到他们的一个primary backup system, 与replicate state machine 还是有不同的. 虽然他们都有state machine, consensus  module, log.

这里的对比主要来自 raft 作者的phd 论文里面的观点:

![Imgur](https://i.imgur.com/u3fWIjm.jpg)

从这个图可以看出primary backup system 的做法是, 当有client 请求到达的时候, primary 会立刻将这个请求apply 到自己的 state machine, 然后将这个结果发送给自己的backup, 而不是这个client 的请求(比如这里就是将y=2 发送给backup, 而不是发送y++ 这个操作), 然后这里发送给自己多个backups 的时候是通过一致性协议来进行发送.

然而这里还是有几个不同点

1. 在primary backup system 里面,  primary 在接收到client 的请求以后, 会立刻apply 到自己的state machine, 然后计算出这个结果, 写到自己的log, 以及发送给所有的backups. 而在state machine replication 系统里面, 是直接将这个操作发送给各个replication的. 那么带来的两个结果

   * 如果某一个操作最后并没有提交, 那么这个state machine 必须将这次的操作给回滚掉
   * 如果一个新的节点成为primary, 那么旧的primary 的state machine 必须将最近的未提交的操作给回滚掉

   可以看出zab 怎么解决这个问题的呢? zab 的解决方法就是当recovery 的时候, 将leader 上面的所有日志都拉去过来, 然后丢弃自己state machine 的内容, 直接使用新leader state machine 的内容

2. primary backup system 里面, log只需要保存对state machine 有修改的操作, 而state machine replication 需要记录所有的操作. 比如如果某一次操作set y = 2, 而其实y 在DB 里面就是2, 那么在primary backup system 里面, 就不会给replication 发送这个操作. 而在state machine replication 里面则会发送这个操作, 这样带来的影响是可能state machine replication 会有较多的log, 但是通过log compaction 其实带来的影响可以忽略

3. state machine replication 需要保证每一个操作都是确定性的, 因为每一个server 都必须保证apply 这一系列的client 操作以后, 所有server 的结果必须是一样的. 因此想比如跟时间, random 相关的这些不确定性操作在这里就无法实现, 而在primary back system 里面, 这些不确定性的操作会通过apply 到 state machine 转化成确定性的操作, 所以不会有这个问题. 因此常见的state machine replication 会将这些不确定性的操作给拒绝来解决这个问题. 也就是client 请求的时候就必须保证这些操作是确定性的




在 "Vive La Diffe ́rence:Paxos vs. Viewstamped Replication vs. Zab" 这个论文里面, state machine replication 也称作active replication, 而primary-backup system 也称作passive replication, 这样更加的形象, 也就是 state machine replication 是主动去同步数据, 通过达成一致性协议来返回给client, 而primary-backup system 是primary 做了所有了事情, 只是通过一致性协议把数据保存在backups 里面

![Imgur](https://i.imgur.com/bbWksIz.jpg)





在zookeeper 的wiki 上面同样有state machine replication 和 primary backup system 的对比, 不过我感觉他主要想表达的是通过multi-paxos 实现的state machine replication 是无法满足有序提交这个问题的, 但是其实在raft 实现的state machine replication 里面是可以满足这个条件的. 所以是否满足有序提交这个问题更多的如上图所示是支持不支持primary-order 的问题

https://cwiki.apache.org/confluence/display/ZOOKEEPER/Zab+vs.+Paxos
