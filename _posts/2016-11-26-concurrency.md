---
layout: post
title: talk about event based concurrency
summary: 谈谈对multi thread 和 event based concurrency 的看法
---


**比如像redis 单线程基于epoll 这种模型, node.js 这种模型都可以归结为Event-base Concurrency, 那么这种模型和multi-thread 对比有什么区别呢?**

从调度角度来看multi-thread 是kernel 来决定下一个要调度处理的thread 是哪一个. 而kernel cpu scheduler 又是一个很大的模块, 很难肯定下一个要调度的thread 是哪一个.

event-based 是当要监听的fd 有事情到达的时候, 由当前这个thread 来决定下一个要执行的event 是谁, 也就是说event-based 是可以实现用户自己决定下一个要执行的任务是谁. 比如简单的可以记录我这次到达的fd里面哪些是优先级高的fd即可.

因为multi-thread 会考虑到每一个thread 的优先级等等, 而且如果thread 数目过多那么肯定会影响到具体的调度.虽然kernel scheduler 能够做到O(1) 的级别. 对比event-base, 切换线程需要切换上下文, 因此肯定会有性能的损耗. 

而在event-base 里面, 所有的event 的优先级都是一样的, 然后在处理event 的handler 里面决定先处理哪一个event. 但是同样有一个问题就是如果这个event-base 里面event 比较多, 那么性能肯定也会下来.

那么event-base 缺点也有, 如果要使用多核的cpu的时候, 想要同时并行的运行多个event server 的时候, 需要用lock 进行同步的问题又来了. 

另外其实有些系统调用并不能支持异步, 比如如果一个处理 event handler 访问内存的时候触发了page fault, 那么这个时候是并不能把这个event handler 切换出去了, 必须等待这个page fault 执行完才可以. 所以kernel 还是不能做到全异步话, 还是有一些逻辑同步的.

pink 里面的设计, 其实是综合上面考虑的结果, 不是一个纯 multi-thread, 也不是一个纯even based. 会有多个work thread, 然后每一个work thread 内部是event-base concurrency.

![](http://i.imgur.com/XXfibpV.png)

