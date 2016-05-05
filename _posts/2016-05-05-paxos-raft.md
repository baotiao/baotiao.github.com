---
layout: post
title: "谈谈paxos, multi-paxos, raft"
description: "谈谈paxos, multi-paxos, raft"
category: distribute, consensus
tags: [distribute, consensus]
---

本文假设你已经看过了paxos make simpe, paxos make live, 关于raft 你看过对应的paper, multi-paxos 其实我觉得介绍的最好的还是Diego Ongaro 为了对比raft 和multi-paxos 的学习的难易程度写的[视频][1]


1. 关于paxos, multi-paxos 的关系

    其实paxos 是关于对某一个问题达成一致的一个协议. paxos make simple 花大部分的时间解释的就是这个一个提案的问题, 然后在结尾的Implementing a State Machine 的章节介绍了我们大部分的应用场景是对一堆连续的问题达成一致, 所以最简单的方法就是实现每一个问题独立运行一个Paxos 的过程, 但是这样每一个问题都需要Prepare, Accept 两个阶段才能够完成. 所以我们能不能把这个过程给减少. 那么可以想到的解决方案就是把Prepare 减少, 那么就引入了leader, 引入了leader 就必然有选leader 的过程. 才有了后续的事情, 这里可以看出其实lamport 对multi-paxos 的具体实现其实是并没有细节的指定的, 只是简单提了一下. 所以才有各种不同的multi-paxos 的实现

    那么paxos make live 这个文章里面主要讲的是如何使用multi paxos 实现chubby 的过程, 以及实现过程中需要解决的问题, 比如需要解决磁盘冲突, 如何优化读请求, 引入了Epoch number等, 可以看成是对实现multi-paxos 的一些

2. 关于 multi-paxos 和 raft 的关系

    从上面可以看出其实我们对比的时候不应该拿paxos 和 raft 对比, 因为paxos 是对于一个问题达成一致的协议, 而raft 本身是对一堆连续的问题达成一致的协议. 所以应该比较的是multi-paxos 和raft

    那么multi-paxos 和 raft 的关系是什么呢?

    raft 是基于对multi paxos 的两个限制形成的

    * 发送的请求的是连续的, 也就是说raft 的append 操作必须是连续的. 而paxos 可以并发的. (其实这里并发只是append log 的并发提高, 应用的state machine 还是必须是有序的)
    * 选主是有限制的, 必须有最新, 最全的日志节点才可以当选. 而multi-paxos 是随意的
    所以raft 可以看成是简化版本的multi paxos(这里multi-paxos 因为允许并发的写log, 因此不存在一个最新, 最全的日志节点, 因此只能这么做. 这样带来的麻烦就是选主以后, 需要将主里面没有的log 给补全, 并执行commit 过程)

    基于这两个限制, 因此raft 的实现可以更简单, 因为raft 的但是multi-paxos 的并发度理论上是更高的.

    可以对比一下multi-paxos 和 raft 可能出现的日志

    **multi-paxos**

    ![](http://i.imgur.com/SsIeodM.jpg)

    **raft**

    ![](http://i.imgur.com/2KO9khV.jpg)

    可以看出, raft 里面follower 的log 一定是leader log 的子集, 而raft 不做这个保证

3. 关于paxos, multi-paxos, raft 的关系

    所以我觉得multi-paxos, raft 都是对一堆连续的问题达成一致的协议, 而paxos 是对一个问题达成一致的协议, 因此multi-paxos, raft 其实都是为了简化paxos 在多个问题上面达成一致的需要的两个阶段, 因此都简化了prepare 阶段, 提出了通过有leader 来简化这个过程. multi-paxos, raft 只是简化不一样, raft 让用户的log 必须是有序, 选主必须是有日志最全的节点, 而multi-paxos 没有这些限制. 因此raft 的实现会更简单.

    因此从这个角度来看, Diego Ongaro 实现raft 这个论文实现的初衷应该是达到了, 让大家更容易理解这个paxos 这个东西

4. 关于lock service 和 consensus library 的对比

chubby 是根据multi-paxos 实现的一个global lock service, 为什么是lock service 而不是一个consensus service 或者 consensus library呢?

1. 首先是library 和 service 的对比

    1. 当用户需要一个consensus 的需求的时候, 一般是随着业务的增长才需要, 那么如果是一个library 的话, 需要对用户的代码改动比较大才能够需求, 而如果是一个service 的话, 那么需要的改动量就非常的小, 仅仅是从consensus service 获得这个服务的地址等等
    
2. lock service 和 consensus library 区别

比如在选主的场景下面, 
我们使用lock service 的做法就是其中的某一个process 去获得这个lock, 然后由这个获得lock 的process 进行选主操作, 这里选主主要涉及每一个process 的log.

另一种是consensus library 的做法, 那么这个时候实现的过程就应该是任意一个process 都可以进行选举操作, 然后选举的过程通过consensus library 来进行.

从这里可以看出 consensus library 的做法是一个业务的本质需求, 但是实现起来对consensus library 需要有深入的了解, consensus library 和上层的逻辑耦合比较高, 而使用lock service 则是一个更简单, 更清晰的做法



最后推广一下我们实现的一个元信息管理模块 [floyd][2], 是一个Library, 而不是一个service. 提供consensus library, 也提供lock library


[1]: https://www.youtube.com/watch?v=JEpsBg0AO6o
[2]: https://github.com/baotiao/floyd

