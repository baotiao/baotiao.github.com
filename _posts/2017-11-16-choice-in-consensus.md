---
layout: post
title: choices in consensus algorithm
summary: choices in consensus algorithm

---

![Imgur](https://i.imgur.com/VdyJpHX.jpg)

在我看来包含 log, state machine, consensus algorithm 这3个部分, 并且是有 electing, normal case, recovery 这3个阶段都可以称为paxos 协议一族. 

为什么说raft 也是3个阶段, 因为其实raft 在重新选举成leader 以后, 也是需要一段recovery 的时间, 如果超过半数的follower 没有跟上leader 的日志, 其实这个时候raft 写入都是超时的, 只不过raft 把这个recovery 基本和normal case 合并在一起了, zab 不用说有一个synchronization 阶段, multi-paxos 因为选举的是任意一个节点作为leader, 那么需要有一个对日志重确认的阶段

1. 选择是primary-backup system 或者是 state machine system

   对于具体primary-backup system 和 state machine system 的区别可以看这个文章 http://baotiao.github.io/2017/11/08/state-machine-vs-primary-backup/ , 在这里primary-backup system 也叫做 passive replication, state machine system 也叫做 active replication

2. 是否支持乱序提交日志和乱序apply 状态机

   其实这两个乱系提交是两个完全不一样的概念. 
   是否支持乱序提交日志是区分是raft 协议和不是raft 协议很重要的一个区别
   在我看来multi-paxos 与raft 对比主要是能够乱序提交日志, 但是不能够乱序apply 状态机. 当然也有paxos 实现允许乱序apply 状态机, 这个我们接下来说, 但是乱序提交日志带来的只是写入性能的提升, 是无法带来读性能的提升的, 因为只要提交的日志还没有apply, 那么接下来的读取是需要等待前面的写入apply 到状态机才行. 并且由于允许乱序提交日志, 带来的问题是选举leader 的时候, 无法选举出拥有最多日志的leader, 并且也无法确认当前这个term/epoch/ballot 的操作都提交了, 所以就需要做重确认的问题. 因此raft/zab/vsp 都是要求日志连续, 因为新版本的zab 的FLE 算法也是默认选举的是拥有最长日志的节点作为leader
   支持乱序apply 日志是能够带来读取性能的提升, 这个也是Generalized Paxos 和 Egalitarian Paxos 所提出的做法. 但是这个就需要在应用层上层去做这个保证, 应用层需要确定两次操作A, B 完全没有重叠. 如果大量的操作都互相依赖的话, 这个优化也很难执行下来. 换个角度来考虑的话, 其实支持乱序 apply 日志, 其实是和multi group 类似的一个做法, 都是在应用层已经确定某些操作是互相不影响的. 比如PhxPaxos 团队就是用的是multi group 的做法, 所以有些宣传raft 不适合在数据库领域使用, 其实我觉得有点扯, 乱序提交日志带来的收益其实不高, 想要乱序apply 状态机的话, multi group 基本是一样的

3. 是否支持primary order

   primary order, 也叫做FIFO client order, 这是一个非常好的功能,  也是zab 特别大的宣称的一个功能. 但是这里要主要这里所谓的FIFO client order 指的是针对单个tcp 连接, 所以说如果一个client 因为重试建立了多个channel, 是无法保证FIFO order. 其实想做到client 级别的FIFO order 也是挺简单, 就是需要给每一个client request 一个id, 然后在server 去等待这个id 递增. 目前基于raft 实现的 Atomix 做了这个事情 http://atomix.io/copycat/docs/client-interaction/#preserving-program-order  
   具体讨论: http://mail-archives.apache.org/mod_mbox/zookeeper-user/201711.mbox/%3cCAGbZs7g1Dt6QXZo1S0DLFrJ6X5SxvXXFR+j2OJeyksGBVyGe-Q@mail.gmail.com%3e
   所以我认为 tcp + 顺序apply 状态机都能够做到单个tcp连接级别的FIFO order, 但是如果需要支持 client 级别的FIFO order, 那么就需要在client 上记录一些东西. 

4. 在选举leader 的时候, 是否支持 designated 大多数. 选举leader 的时候如何选举出leader

   designated 有什么用呢? 比如在 VSR 的场景里面, 我们可以指定某几个节点必须apply 成功才可以返回. 现实中的场景比如3个城市5个机房, 那么我们可以配置每个城市至少有一个机房在这个designated 里面, 那么就不会出现有一个城市完全没有拷贝到数据的情况.
   如何选举出leader 这个跟是否支持乱序提交日志有关, 像raft/zab/vsr 这样的场景里面, 只能让拥有最长日志的节点作为leader, 而paxos 可以在这里增加一些策略, 比如让成为leader 的节点有优先级顺序等等
   
5. 也是和选举相关, 在选举完成以后, 如何执行recovery 的过程.  以及这个rocovery 的过程是如何进行的, 是只同步日志, 还是根据快照进行同步,  是单向同步, 还是双向同步.

   早期的zab 实现就是双向同步, 任意选取一个节点作为新的leader, 那么这个时候带来的问题就是需要找到其他的follower 里面拥有最长日志的节点, 把他的日志内容拉取过来, 然后再发送给其他的节点, 不过后来zab 也改成FLE(fast leader election), 也只需要单向同步日志内容. raft/vsr 也都只需要单向的同步日志了. paxos 因为允许乱序提交日志, 因此需要和所有的节点进行重确认, 因此需要双向的同步日志. 
   这里要注意的是 paxos 这种做法需要重新确认所有的他不确认是否有提交的日志, 不只是包含他没有, 还包含他有的也有可能没有提交.  因此一般paxos 会保存一下当前已经提交到哪里了, 然后成为新的leader 以后, 需要重新确认从当前的commitIndex 以后的所有的日志.  这个成本还是很高的, 因此就是我们所说的重确认问题.    那么这个重确认什么时候到头呢? 需要确认到所有的server 都没有某一条日志了才行 

6. 读取的时候的策略, 包括lease 读取或者在任意一个replica 读取, 那么可能读到旧数据. 然后通过版本号进行判断是否读取到的是最新数据.

   lease 做法其实和协议无关, 任意一种的paxos 都可以通过lease 的优化读取的性能, 当然lease 做法其实是违背分布式系统的基础理论, 就是分布式系统是处于一个asynchronization network 里面, 无法保证某一条消息是到达还是在网络中延迟
   zookeeper 的实现里面为了提高读取的性能, 就允许client 直接去读取follower 的内容, 但是这样的读取是可能读取到旧数据, 所以有提供了一个sync 语义, 在sync 完之后的读取一定能够读取到最新的内容, 其实sync 就是写入操作, 写入操作成功以后, 会返回一个最新的zxid, 那么client 拿这个zxid 去一个follower 去读取的时候, 如果发现follower 的zxid 比当前的client 要来的小, 那么这个follower 就会主动去拉取数据
   目前在raft phd thesis 里面读取的优化就包含了 lease 读取和只需要通过Heartbeat 确认leader 信息进行读取
   如何尽可能减少leader 的压力,  是一致性协议都在做的一个事情, 想zookeeper 这种通过上层应用去保证, 允许读取旧数据也是一个方向, 当然还有的比如像Rotating leader, Fast Paxos 给client 发送当前的proposal number 的做法.

7. 在检测leader 是否存活的时候是单向检测还是双向检测

   比如在raft 里面的心跳只有leader 向follower 发送心跳,  存在这样的场景. 如果有5个节点,  只有leader 节点被割裂了, 其实4个节点网络正常,  新的这4个节点选举出一个leader, 旧的leader 由于完全与其他节点割裂, 所有的AppendEntry 都是失败的, 不会收到一个新的Term号, 因此一直保持着自己是leader 的状态. 那么这样系统就会同时存在两个leader, 但是这个不影响协议正确性, 因为旧的leader 是无法写入成功的.
   在zab 里面心跳是双向的, 也就是说leader 向follower 发送心跳, 如果超过半数的follower 没有应答, 那么leader 会进入到electing 状态. 同时follower 也会向leader 发送心跳, 如果leader 没有回应, 那么这个follower 节点同样会进入到electing 状态. 那么对应于上述的场景, zab 就不会出现像raft 一样, 长期同时存在两个leader 的情况.
   通过上述对比, 我还是觉得raft 实现更简洁, 而双向心跳检测这种做法增加了大量的复杂度



最后的结论是这样

对于计算密集型任务, 也就是写入量比较大的场景, 建议选择passive replication strategy, 那么也就是选择VSR 或者 ZAB 这样.其实主要就是考虑到passive replication 只需要更新的是state 的修改, 而不是用于操作, 那么就可以少做很多操作.

对于对性能比较敏感的场景, 那么应该选择active replication stategy, 那么也就是选择mulit-paxos, raft 这样, 并且不需要designated majorities. 因为passive replication strategy 在rocovery 需要更多的时间, 因为client 的操作是需要写入到状态机, 如果这个client 的操作最后没有被提交, 因为log 可以提供一个回滚操作, 而状态机很少能够提供这种回滚操作, 因此就需要将这个节点的状态机的内容重写, 所以会导致recovery 需要较长的时间.



Reference:

1. http://www.tcs.hut.fi/Studies/T-79.5001/reports/2012-deSouzaMedeiros.pdf
2. https://arxiv.org/pdf/1309.5671.pdf
3. https://ramcloud.stanford.edu/raft.pdf
4. http://www.read.seas.harvard.edu/~kohler/class/08w-dsi/chandra07paxos.pdf
5. http://research.microsoft.com/en-us/um/people/lamport/pubs/paxos-simple.pdf
6. http://research.microsoft.com/en-us/um/people/lamport/pubs/lamport-paxos.pdf
7. http://baotiao.github.io/2017/11/08/state-machine-vs-primary-backup/

