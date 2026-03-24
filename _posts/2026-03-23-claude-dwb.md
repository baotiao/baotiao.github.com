---
layout: post
title: 用 Claude Code 在 PostgreSQL 实现 Double Write Buffer 遇到的一些问题 
summary: DuckDB 的 MVCC 设计与 HyPer 模型
---

最近一直在探索怎么用 Claude Code 来帮忙写数据库内核的代码.  一开始是直接让 Claude code 在 PostgreSQL 上实现一套 Double Write Buffer, 参考 InnoDB 的实现. 代码 Claude 确实写得挺快, 但过程中发现一个问题: 它不会做设计.

**Buffer I/O 和 Direct I/O 的差异**

我让 Claude 参考 InnoDB 的 DWB 实现方式, 在 PG 里面搞一份. 它很快就写出来了, 但其实有一个根本性的问题它完全没有意识到: InnoDB 是 Direct I/O, PostgreSQL 是 Buffer I/O.

在 InnoDB 里面, 因为是 Direct I/O, 脏页写到 DWB 之后 fsync 一次, 然后把脏页写到数据文件再 fsync 一次, 链路很清晰. 每次写入都是直接落盘的.

但 PG 不一样. PG 的刷脏只是把数据写到操作系统的 Page Cache 里面, 原来用的是 `sync_file_range`, 这个调用只是 "建议" 操作系统去刷盘, 并不保证一定成功. 以前有 Full Page Write 兜底, 所以这样没问题 — 即使 Page Cache 到磁盘写了一半 crash 了, WAL 里面有完整的页面镜像可以恢复.

但现在你要用 DWB 替代 FPW, 问题就来了. 脏页写到 DWB 并 fsync, 然后脏页通过 Buffer I/O 写到 Page Cache, 这时候 DWB 里面对应的 slot 就可以回收了. 但如果这时候还没来得及从 Page Cache 刷到磁盘就 crash 了呢? 脏页发生 partial write, DWB 里面的副本又已经被覆盖了, 那 DWB 就白写了.

所以在 Buffer I/O 下面, 脏页必须强制 fsync 到磁盘之后, DWB 的 slot 才能回收. 这一点和 InnoDB 的 Direct I/O 有本质区别, Claude 完全没考虑到.

**单进程刷脏跟不上**

这个问题是从上面那个问题推出来的.

PG 之所以只有一个 BG Writer 进程做刷脏, 是因为 Buffer I/O 下写脏页只是写到 Page Cache, 非常轻量, 一个进程就够了. Page Cache 到磁盘的刷盘是操作系统内核的多个线程并发去做的, 数据库不用管.

但你现在引入了 DWB, 每次写完脏页还得 fsync, 这就从一个轻量的 CPU 操作变成了重量级的 I/O 操作. 一个 BG Writer 做 fsync 显然跟不上. 理论上如果 Claude 懂设计的话, 它应该意识到需要把 BG Writer 改成多个进程并发刷脏. 但它没有, 只是在原来单进程的框架下面把 DWB 的写入逻辑塞进去了.

**多余的 Batch 策略**

InnoDB 在写 DWB 的时候会做 Batch 优化, 攒一批脏页一起写进去再 fsync, 摊薄 fsync 的开销. Claude 在 PG 的实现里面也照搬了这个策略.

但其实在 PG 里面这完全没必要. 因为上层的 `BufferSync` (Checkpointer 调的) 和 `BgBufferSync` (BG Writer 调的) 本身已经做了批量处理, 每次下来就是一批页面. 到 DWB 这一层的时候, 进来的已经是一批了, 没必要在 DWB 内部再加一层等待和攒批. 多一层 Batch 只会增加延迟和复杂度.

**怎么用 Claude 写内核代码**

这几个问题都不是代码 bug, 是设计上的问题. Claude 不理解 Buffer I/O 和 Direct I/O 在刷脏语义上的差异, 不会从 "需要 fsync" 推导出 "单进程跟不上, 需要多进程", 也会机械地照搬参考实现里面的优化策略而不管目标系统里是不是已经有类似的机制.

所以目前比较靠谱的方式还是人做设计, Claude 做实现. 把关键的设计约束和架构决策想清楚, 让 Claude 在这个框架下面去写代码.
