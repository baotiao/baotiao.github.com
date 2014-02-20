---
title: Paper
layout: page
pagetitle: paper
comments: yes
---

- [SEDA][1]

    一个分阶段事件驱动的框架的论文. 核心思想是把一个网络请求分成多个阶段, 每一个阶段称为Stage.  
    然后每一个Stage内部包含一个事件队列, 一个Event Handler, 一个线程池. 然后将不同的Stage 类似Pipe 一样串联起来.  
    与普通的网络模型不同的是普通的多线程+事件驱动的模型是一个请求过来建立连接以后, 则专门交给一个线程去处理这个请求. 比如Memcache 就是这种. 与这种分阶段的事件驱动对比.
    1. 由于每一个Stage内部的线程池专注于某一个任务, 所以不同线程之间的锁比较少.
    2. 不同的Stage阶段的线程池需要的磁盘, 网络, CPU 可以动态的调整. 这样更能合理的利用资源

- [Paxos Make Simple][2]

[1]: http://www.eecs.harvard.edu/~mdw/papers/seda-sosp01.pdf
[2]: http://research.microsoft.com/en-us/um/people/lamport/pubs/paxos-simple.pdf
