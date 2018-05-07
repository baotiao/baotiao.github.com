---
layout: post
title: Raft phd 论文中的pipeline 优化
summary: raft phd 论文里面是如何做 Pipeline 优化的? 

---
raft phd 论文里面是如何做 Pipeline 优化的? 

貌似这里Pipeline 的做法也是不会让日志产生洞, 日志仍然是有序的

leader 和follower 在AppendEntry 的时候, 不需要等待follower 的ack 以后, 立刻发送下一个log entry 的内容. 但是在follower 收到这个AppendEntries 的内容以后,  因为AppendEntries 会默认进行consistency check(这里AppendEntries consistency check 指的是在执行AppendEntries 的时候, 会把之前的一个log 的index, term 也都带上, follower 在收到这条消息以后, 会检查这里的index, term 信息是否与自己本地的最后一个log entry的index, term 一致, 不一致的话就返回错误) 那么即使是pipeline 执行AppendEntries, 仍然会保证如果这个follower 接受后面一个entry 的时候, 必定把之前pipeline 的entry 接受了才行, 不然是不会满足这个 AppendEntries 的约束的, 也就是说即使使用pipeline 依然可以保证Log 是不需要带洞的.  当然raft 作者这里的做法依然是保证简单, 所以让没有通过AppendEntries concsistency check 之后, 默认就让这个AppendEntries 错误, 然后让他重试. 当然也可以有其他的处理方法


同时这里也强调, 使用 pipeline 的话, 必须至少一个leader 与一个follower 建立多个连接? 

**如果一个leader 与一个follower 共用一个连接使用pipeline 的话, 那么效果会是怎样的呢?**

其实这样的pipeline 适合batch 是没有多大区别的, pipeline 最大的目的应该是在latency 比较高的情况下, 也可以充分的利用带宽,  但是如果共用一个连接的话, 在tcp 层面其实就已经是串行的, 因为tcp 同样需要对端的ack, 才会发送下一段的报文, 虽然tcp 有滑动窗口来运行批量发送, 然后在对端重组保证有序, 其实这个滑动窗口就和batch 的作用类似. 因此如果使用单挑连接, 其实是和batch 的效果是差不多的,  使用单条连接的pipeline 其实也不会出现包乱序, 因为tcp 层面就保证了先发送的包一定是在前面的.

说道这里其实raft 同步log和tcp 做的事情类似, 也是希望可靠有序的进行数据同步, 又希望尽可能的利用带宽.

**那么使用多条连接的话可能存在什么问题?**

如果是一个leader 和 follower 建立多个连接的话,  即使因为在多个tcp 连接中不能保证有序,  但是大部分情况还是先发送的先到达, 即使后发送的先到达了, 由于有AppendEntries consistency check 的存在, 后发送的自然会失败, 失败后重试即可. 其实这里完全也可以像tcp 那样, 有类似滑动窗口的概念,  也就是说AppendEntries 的时候, 如果发现之前的内容还没到达, 那么完全可以在本地的内存中保留一份buffer, 那么可以利用这个buffer 就不需要进行重传了, 当然简单的办法仍然是重传.

当然这里如果引入了类似滑动窗口的概念, 在follower 端保留一份数据的话, 那么自然也就需要拥塞阻塞算法的存在了, 也就是说如果一个follower 节点在前面某一个连接缺少了某一个log 以后, 其他的连接一直发送数据, 这个时候该如何处理, 也就是follower 需要告知leader, 让这个leader 不要再发送内容了, 那么其实就和tcp 里面的拥塞阻塞是一样了.


