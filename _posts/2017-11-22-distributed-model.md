---
layout: post
title: when we talk about distributed system, what are we talking about
summary: when we talk about distributed system, what are we talking about

---

做了这么多年的分布式存储, 那到底什么是分布式系统?

是一致性hash么? 是3副本策略的? 是一致性协议, paxos, raft, 最终一致性,  是CAP 理论么?  

我认为分布式系统首先要了解系统的模型, 就像我们对比lsm tree 和 b+ tree 哪一个在磁盘上表现更优的时候, 我们就必须是基于某一个模型来进行比较, 比如DAM (Disk access model)模型,  DAM 模型是用来描述不同外存算法的时候只需要去考虑访问磁盘的次数, 而不需要考虑具体的内存的大小, 所有的模型都是对现实的一个抽象, 考虑因素越少的模型, 抽象出来越简单. 所以在理论分析领域, 其实提出模型比验证模型是一个更难的事情

那分布式系统有哪些模型, 又是哪一个模型最符合我们的认可呢?

这里主要引用自Nancy 的Distributed Algorithm 里面的内容

1. syschronous model
2. asynchronous message-passing model
3. asynchronous shared-memory model
4. partially synchronous model


注意这里所说的同步网络跟异步网络跟我们讲操作系统里面的同步操作和异步操作不是一个意思. 计算机领域有很多这样的例子, 比如堆这个字, 在数据结构里面表示"堆" 这个数据结构, 这内存分配里面, 又表示这个是从"堆"空间来分配的内容

**syschronous model**

指的是在这个模型里面, 消息的送达和消息的执行是按照规定的时间完成的, 整个系统是按照round 运行, 某一条指令肯定在当前这个round要么执行成功, 要么执行失败.  可以看出这个模型非常理想, 只存在于理论分析领域.

**asynchronous message-passing model**

指的是在这个网络模型里面, 消息的送达和消息的执行没有时间上限. 比如一条消息有可能因为延迟的原因, 在网络中存在很长一段时间, 不能保证什么时候到达, 有可能永远都到达不了, 也有可能经过一段时间以后有送达了. 比如Java 在执行某一条命令的时候, 由于GC 的原因导致某一条命令卡主, 经过很长一段时间以后, 有可能继续恢复执行了, 也有可能是永久的失败了.

在这种网络模型下面, 最大的问题是无法判断某一个节点是真的failure 还是因为只是由于网络的原因, 探测这个节点的包延迟了.

这就是我们经常说的"第三态"问题, 就是一个请求永远有三个状态, 1. 返回成功 2. 返回失败 3. 返回超时

**Partially synchronous system model**

半同步网络模型指的是对于这个系统里面消息的送达, 以及消息的执行时间是有一定的上限, 虽然这个上限不是绝对的精确. 超过这个时间上限以后, 这些操作都是失败的.



#### 结论



目前在理论研究领域大部分认可的是asynchronous network model 比较适合现实场景, 我们很多的算法都是对于asynchronous message-passing model 上面的研究, 比如我们所说的Byzantium 问题无法解决, 我们所说的FLP 结论也都是在asynchronous message-passing model 上面的结论.

在同步网络的场景下面这些结论都是不合适的, 比如在Byzantium 在同步网络中故障节点数不超过1/3的时候, 是可以解决的, 但是解决成本非常高.

但是其实在很多工程实现的时候, **我们会认为我们所在的网络模型是Partially synchronous system model.** 我们会采用lease 等机制, 比如在 chubby, 很多multi-paxos/raft, red-lock 的实现中. 

为什么要这样实现呢?

因为在工程环境中, 虽然不同的机器和节点虽然可能有时间飘逸, 或者说java 的GC 存在一定的时间, 但是我们会认为这些时间存在一定的上限, 因此我们设计系统的时候, 可以利用这个特性, 在不同机器之间, 把主节点的lease 时间设计的相对早一点, 这个时间是允许容忍不同节点之间时间飘逸差异的时间.

当然很可能会访问这样设计的系统不安全. 但是其实如果这个概率足够低, 我们应该是可以容忍的.  比如为什么我们在设计很多系统的不会考虑Byzantium 错误, 也是因为我们认为这个出现概率极其低. 这里就涉及到工程实现和理论的区别的. 并且目前也有大量的系统是这么做的, 比如chubby, floyd, redlock, zookeeper 等等



Reference:

[Distributed Algorithm](http://groups.csail.mit.edu/tds/distalgs.html)

[FLP Impossibility](https://groups.csail.mit.edu/tds/papers/Lynch/jacm85.pdf)

