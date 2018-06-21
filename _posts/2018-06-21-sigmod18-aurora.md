---
layout: post
title: Paper Review Amazon Aurora-On Avoiding Distributed Consensus for I/Os, Commits, and Membership Changes
summary: Paper Review Amazon Aurora-On Avoiding Distributed Consensus for I/Os, Commits, and Membership Changes
---

这个是Amazon Aurora 发的第二篇文章, 发在2018 年SIGMOD上, 题目很吸引人避免在I/O, commit, 成员变更的过程使用一致性协议. 在大家都在使用一致性协议(raft, multi-paxos)的今天, Aurora 又提出来了不用一致性协议来做, 主要观点是现有这些协议太重, 而且会带来额外的网络开销, 也可以理解, 毕竟Aurora 是6副本, 主要的瓶颈是在网络上. 那么他是怎么做的?

**因为Aurora 很多细节还是没有揭露, 所以很多内容是我自己的解读, 以及问的作者, 如果错误, 欢迎探讨**

这篇文章也主要回答这个问题.

Aurora is able to avoid distributed consensus during writes and commits by managing consistency points in the database instance rather than establishing consistency across multiple storage nodes. 

在Aurora 中, storage tier 没有权限决定是否接受write, 而是必须去接受database 传过来的write. 然后都是由database tier 去决定是否这个 SCL, PGCL, VCL 是否可以往前推进, 也就是说 storage tier 本身并不是一个强一致的系统, 而仅仅是一个quorum 的系统, 需要database tier 来配合实现强一致. 

这个也是与当前大部分的系统设计不一样的地方, 当前大部分的系统都是基于底层强一致, 稳定的KV(当然也可以叫Block storage) 存储, 然后在上层计算节点去做协议的解析和转换. 而Aurora 提出底层的系统只需要是一个quorum 的系统, storage tier + database tier 实现一个强一致的方案. 

比如像Spanner 里面, 每一个spanservers 本身是多副本, 多副本之间通过multi-paxos 来保证数据的一致性, 然后上层的F1 这一层主要做的协议转换, 把SQL 协议转换成kv 请求去请求spanserver.

我们的PolarDB 也是这样的一套系统, 底层的存储节点 polarstore 是一个稳定可靠的强一致系统, 上层的计算节点PolarDB 是一个无状态的节点.



接下来具体的 Aurora 是如何实现的呢?

**Term:**

* LSN: log sequence number

  每一条redo log 有一个唯一的单调递增的 Log Sequence Number(LSN), 这个LSN 是由database 来生成, 由于Aurora 是一写多读的结构, 很容易满足单调递增
  
* SCL: segment complete LSN

  SCL(segment complete LSN) 表示的是当前这个segment 所知道的最大的LSN, 在这个SCL 之前的所有记录当前这个节点已经收到, 到SCL 位置的数据都是连续的. **这里与VCL 的区别是, VCL 是所有节点确认的已经提交的LSN, 而SCL 是自己认为确认已经提交的LSN, VCL 可以认为是storage node 的commit index, 而SCL只是记录当前节点的LastLogIndex** Aurora 也会使用这个SCL来进行节点间交互去补齐log.

* VCL: volume complete LSN

  这个VCL 就是storage node 认为已经提交的LSN, 也就是storage node 保证小于等于这个VCL 的数据都已经确认提交了, 一旦确认提交, 下次recovery 的时候, 这些数据是保证有的. 如果在storage node recovery 阶段的时候, 比VCL 大于的数据就必须要删除, VCL 相当于commit Index.  这个VCL 只是在storage node 层面保证的,  有可能后续database 会让VCL 把某一段开始的 log 又都删掉. 

  这里VCL 只是storage node 向database 保证说, 在我storage node 这一层多个节点已经同步, 并且保证一致性了.这个VCL 由storage node 提供.
  
* PGCL: Protection Group Complete LSN 

  每一个分片都有自己的SCL, 这个SCL 就叫做PGCL.  等于说SCL 是database 总的SCL, 每一个分片有各自的PGCL, 然后这个database 的SCL 就等于最大的这个PGCL

* CPL: consistency point LSN

  CPL 是由database 提供, 用来告诉storage node 层哪些日志可以持久化了, 其实这个和文件系统里面保证多个操作的原子性是一样的方法.

  为什么需要CPL, 可以这么理解, database 需要告诉storage node 我已经确认到哪些日志, 可能有些日志我已经提交给了storage node了, 但是由于日志需要truncate 进行回滚操作, 那么这个CPL就是告诉storage node 到底哪些日志是我需要的, 其实和文件系统里面保证多个操作原子性用的是一个方法, 所以一般每一个MTR(mini-transactions) 里面的最后一个记录是一个CPL. 

* VDL: volume durable LSN

  因为database 会标记多个CPL, 这些CPL 里面最大的并且比VCL小的CPL叫做VDL(Volume Durable LSNs). 因为VCL表示的是storage node 认为已经确认提交的LSN, 比VCL小, 说明这些日志已经全部都在storage node 这一层确认提交了, CPL 是database 层面告诉storage node 哪些日志可以持久化了,  那么VDL 表示的就是已经经过database 层确认, 并且storage node层面也确认已经持久化的Log, 那么就是目前database 确认已经提交的位置点了.

  所以VDL 是database 这一层已经确认提交的位置点了, 一般来说VCL 都会比VDL 要来的大, 这个VDL 是由database 来提供的, 一般来说VDL 也才是database 层面关心的, 因为VCL 中可能包含一个事务中未提交的部分.


* MTR: mini transaction

  那么事务commit 的过程就是这样, 每一个事务都有一个对应"commit LSN", 那么这个事务提交以后就去做其他的事情, 什么时候通知这个事务已经提交成功呢? 就是当VDL(VDL 由databse 来发送, storage service来确认更新) 大于等于"commit LSN" 以后, 就会有一个专门的线程去通知这个等待的client, 你这个事务已经提交完成了. 

  如果这个事务提交失败, 那么接下来的Recovery 是怎么处理的呢?

  首先这个Recovery 是由storage node 来处理的,  是以每一个PG 为维度进行处理, 在database 起来的时候通过 quorum 读取足够多的副本, 然后根据副本里面的内容得到VDL, 因为每一个时候最后一条记录是一个CPL, 这些CPL 里面最大的就是VDL,  然后把这个VDL 发送给其他的副本, 把大于VDL 的redo log 清除掉, 然后恢复这个PG的数据


* SCN: commit redo record for the transaction

  也就是一个transaction 的 commit redo record, 每一个transaction 生成的redo record 里面最大commit LSN. 主要用于检查这个事务是否已经被持久化了

  这里就是通过保证SCN 肯定小于VCL 来进行保证提交的事务是一定能够持久化的, 所以Aurora 一定是将底下的VCL 大于当前这个transaction 的SCN 以后才会对客户端进行返回

* PGM-RPL: Protection Group Minimum Read Point LSN 

  这个LSN 主要是为了回收垃圾使用, 表示的是这个database 上面读取的时候最低的LSN, 低于这个LSN 的数据就可以进行清理了. 所以storage node 只接受的是PGMRPL -> SCL 之间的数据的读请求



**那么写入流程是怎样?**

在database tier 有一个事务需要提交, 那么这个事务可能涉及多个分片(protection group), 那么就会生成多个MTRs, 然后这些MTRs 按照顺序提交log records 给storage tier. 其中每一个MTR 中有可能包含多条log records, 那么这多条log records 中最后一条的LSN, 也称作CPL. storage tier 把本地的SCL 往前移. database tier 在接收到超过大多数的storage node 确认以后, 就把自己的VCL 也往前移. 下一次database tier 发送过来请求的时候, 就会带上这个新的VCL 信息, 那么其他的storage node 节点就会去更新自己的VCL 信息.



**那么读取的流程是怎样?**

在aurora 的quorum 做法中, 读取的时候并没有走quorum. 

从master 节点来说, master 在进行quorum 写入的时候是能够获得并记录每一个storage node 当前的VDL, 所以读取的时候直接去拥有最新的VDL 的storage node 去读取即可.

对于slave 节点, master 在向storage node 写redo record 的同时, 也异步同步redo log给slave 节点, 同时也会更新VDL, VCL, SCL 等等这些信息给从节点, 从节点本身构造本地的local cache. 并且slave 节点也拥有全局的每一个storage node 的VDL 信息, 因此也可以直接访问到拥有最新的storage node 的节点.



个人观点:

这篇文章开头讲的是通过 quorum I/O, locally observable state, monotonically increasing log ordering 三个性质来实现Aurora, 而不需要通过一致性协议. 那我们一一解读

![Imgur](https://i.imgur.com/wpoedTb.jpg)

这里的monotonically increasing log ordering 由LSN 来保证, LSN 类似于Lamport 的 logic clock(因为这里只有一个节点是写入节点, 并且如果写入节点挂了以后有一个恢复的过程, 因此可以很容易的保证这个LSN 是递增的)

locally observable state 表示当前节点看到的状态, 也就是每一个节点看到的状态是不一样的, 每一个节点(包含database node 和 storage node) 都有自己认为的 SCL, VCL, VDL 等等信息, 这些信息表示的是当前这个节点的状态, 那么就像Lamport logic clock 文章中所说的一样, 在分布式系统中没有办法判断两个不同节点中的状态的先后顺序, 只有当这两个状态发生消息传递时, 才可以确定偏序关系. 那么在这里就是通过quorum I/O 确定这个偏序关系

quorum I/O  在每一次的quorum IO达成确认以后, 就相当于确认一次偏序关系. 比如在一次写入成功以后, 那么我就可以确定当前的data node 的状态一定是在其他的storage node 之前.  在一次gossip 节点间互相确认信息以后, 主动发起确认信息的节点的状态也一定在其他节点之前.  所以整个系统在写入之后或者在重启之后的gossip 一定能够存在一个在所有节点最前面的状态的节点, 那么这个节点的状态就是当前这个系统的状态, 这个状态所包含的SCL, VCL, VDL 信息就是一致性信息



刚开始看会觉得这个系统比较琐碎, 不像Paxos/raft 那样有一个比较完备的理论证明, 不过问过作者, 实现这一套过程也是经过TLA+的证明一章数据流已经窗口管理主要解决的是如何合理的在不考虑网络带宽的限制情况下, 只考虑发送端和接收端的处理能力, 通过滑动窗口的控制, 能够达到最大吞吐的目的. 也就是说既可以避免发送端发送过多消息, 但是接收端处理不过来, 也不会说发送的消息太慢, 接收端一直在等待这样的场景

16章拥塞阻塞 主要是增加了网络带宽的限制. 因为毕竟网络带宽是有限的, 即使接收端和发送端的处理能力非常快, 但是有可能网络先达到瓶颈, 就是发送出去的数据并不是因为接收端处理不过来, 而是这个网络通道处理不过来导致这个包必须丢弃, 那么为了防止这个网络拥塞,  也就是发送过多的包, 导致网络一直堵住, 那么就有了网络的拥塞阻塞, 用来调整发送端的发送速率.

所以15章处理的是发送端和接收端的合理的发送速度, 16章处理的事发送端和网络这个通道的合理发送速度

**Nagle 算法**

The Nagle algorithm says that when a TCP connection has outstanding data that has not yet been acknowledged, small segments (those smaller than the SMSS) cannot be sent until all outstanding data is acknowledged. 

Nagle 算法指的是当一个tcp 连接有一些正在发送的数据没有返回ack 的时候, 小于SMSS 的小包是不允许发送出去了, 除非这个发送出去的数据已经被ack 了.

The beauty of this algorithm is that it is *self-clocking*: the faster the ACKs come back, the faster the data is sent. On a comparatively high-delay WAN, where reducing the number of tinygrams is desirable, fewer segments are sent per unit time. Said another way, the RTT controls the packet sending rate.

这里说 Nagle 算法优雅的地方在于他是一个 **自动计时** 的算法, 也就是说如果对端ack 回来的越快, 那么在发送端这边Nagle 算法是几乎不积压任何的数据, 那么下次发送的就是一个小包.  如果对端ack 回来的越慢, 那么发送端这边肯定就积压挺多数据, 下次一起发送过去.  这样就可以看出这个算法是会自我调整, 也就是在网络条件好的情况下, Nagle 对发送基本没有影响, 在网络情况比较差的情况, 会自动进行batch, 积攒更多的小包进行发送.  并且还能够适应网络场景不断变化, 也就是网络延迟时而卡, 时而不卡的场景, 他就会自动调整下一次发送包的batch 大小.

其实在默认的floyd 里面的batch 实现就可以达到这个目的, 也就是AppendEntry完成以后, 如果AppendEntry 的结果返回的比较快, 那么下一次AppendEntry 就发送小包, 如果AppendEntry 返回结果比较慢, 那么在AppendEntry 返回结果这个过程, 就可以积攒比较大的包, 然后一次发送出去, 这样就可以有效的利用网络.





tcp 的流控制和窗口管理



The *Window Size* field in each TCP header indicates the amount of empty space, in bytes, remaining in the receive buffer.

![Imgur](https://i.imgur.com/LkOtHQ1.jpg)



tcp 里面的 Win 这个参数表示的就是 Window size

**tcp 里面往对端发送数据的时候, 会把自己的Window Size field 发送给对方, 告诉对方我这里有多大的空闲空间你可以往我这里发数据, 如果我这里的window size 非常小了, 你应该停止一会, 不然就算你发送了 我也处理不过来, 就直接把这里面的内容都丢弃了**



tcp 中的滑动串口分 sender 端的滑动窗口和receiver 端的滑动窗口, 其实可以把滑动窗口看出是对batch, pipeline 的一个更细致的实现, 其实发送端发送的时候其实不只是一个一个的发, 其实应该是SND.UNA 到 SND.NXT 这一批是已经发送的等待ack的, 而 SND.NXT到SND.UNA + SND.WND 这一段的区间的元素应该是batch + pipeline 发送的, 然后这里等待对端的ack.  但是batch, pipeline 只是一股脑的发送数据, 但是并没有考虑接收端的接收能力, 有可能

其实raft 在多条tcp 连接上发送消息和 tcp 基于允许有丢包ip 协议进行可靠的数据传输关系是一样的. 因为有可能raft 中多条连接中的一条阻塞住了, 这就跟tcp 里面其中某一个包丢了, 那么后续的包如何处理是一样的. 这就跟如果tcp 协议中的某一个包丢失了以后, 那么tcp 层面如何发起这个重传, 但是这里不一样的地方在于 raft 中的多条tcp 连接会阻塞住, 而tcp 协议中, 如果有一个包丢失了, 那么直接重新发送就行



同样raft 在多条连接的场景下可以想tcp 一样有发送滑动窗口和接收的滑动窗口, 也就是说发送这边可以同时pipeline 的发送多条内容, 然后等待接收端确认以后, 这个滑动窗口向右移动. 同样接收端也保存一个滑动窗口, 那么就可以允许有少量的乱序, 也就是在RCV.NXT 到 RCV.NXT + RCV.WND 之间这一部分的内容是可以乱序到达的, 就不需要进行重试.



发送端的滑动窗口:

![Imgur](https://i.imgur.com/wUaLMpQ.jpg)

接收端的滑动窗口:

![Imgur](https://i.imgur.com/DRdD8Jl.jpg)



有了滑动窗口以后还需要解决一个问题, 就是如果接收端的窗口已经满了, 那么这个时候发送端会怎么办, 那么tcp 里面的做法就是也很简单, 就是这个发送端每5s 发送一个probe 包过来, 探测一下









其实tcp 里面的流控制和窗口控制主要是为了解决在大量发送小包的时候需要在延迟和每次发包需要发额外的信息中折中.

其实这个和常见的batch 的优化类似, 就是这里更加明显的是因为tcp 中包含了大量的头信息, 如果不做batch 的话, 那么比如一个发包中冗余信息就多很多, 

