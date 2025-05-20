---
layout: post
title: PolarDB 一写多读架构下读取到未来页的问题
summary: PolarDB read future page
---

**背景:**

用户使用 PolarDB/Aurora 这样基于共享存储一写多读架构的时候, 很常见的想法是, 希望使用 PolarDB rw(读写节点), ro(只读节点) 和传统的 MySQL 主备节点一样. 用户认为可以在备节点上做任何复杂操作, 即使备节点有问题, 比如因为跑了复杂查询, 从而导致 CPU 升高, 导致复制有延迟, 但是也不应该影响到主节点.

但是, 其实在 PolarDB 里面, 其实不是这样的, 如果 RO 节点有复杂查询, 那么其实会影响到RW 节点的, 因为访问数据一致性的约束, 如果 RO 节点复制有延迟, 那么RW 节点的刷脏是存在约束的. 会导致 RW 节点无法进行刷脏.

目前 PolarDB的处理方法是如果RO 节点复制延迟过高, 影响了 RW 刷脏, 那么会让 RO 节点自动 crash 重启, 从而避免 RW 节点出现问题.

但是还是有用户希望使用 MySQL 主备一样使用 PolarDB 的 RW 和 RO, 那么如果出现了有延迟的 RO 节点, 又不想让 RO 节点重启, 那么有办法么? 

直观的想法是不限制 RW 节点刷脏, 那么就可能出现 RO 节点读取到 future page.



如果RO 节点读取到future page, 会有什么问题?

其实Aurora 这样的架构虽然有存储多版本的支持, 但是依然也有和 PolarDB 类似的问题, 他也要解决的.

<img src="https://raw.githubusercontent.com/baotiao/bb/main/uPic/image-20240622035130600.png" alt="image-20240622035130600" style="zoom:40%;" />

https://repost.aws/knowledge-center/aurora-read-replica-restart

Aurora 回答这个问题的时候也强调, Aurora 的 RW 和 RO 架构其实是和传统 MySQL 主备架构不一样.




Aurora/Socrate 依赖Page server 的多版本, 那么Page server必须保留最老的版本, 这样才能保证读取到想要的版本. 因此Page server 不能随意执行redo + page => new_page 逻辑, 需要等到所有的 RO 节点都已经同步到相同的 redo log 之后, 对应的 Page 才可以更新成 new_page. 其实是和PolarDB 里面限制RW刷脏是差不多的.

PolarDB 也一样, 存储节点保留的是最老版本, 从而保证ro 可以读取到指定的版本.

其实虽然 PolarDB/Aurora 架构有所区别, 但是这个问题是都有的.

也都存在分险, 也就是如果RO 节点延迟太多, 那么 PolarDB 由于刷脏约束可能导致节点crash, Aurora 由于刷脏约束也会导致 Page server 无法推进.

所以两边都有一个逻辑, 如果有一个慢RO 延迟太大, 那么RO 节点自动重启.

不过 Aurora 受到的影响会小很多, 因为将这些延迟的page 打散到多个 Page Server 上, 而 PolarDB 是聚集在一个节点上.



要解决这个问题, 可以从两个方面来解决. RW or RO 解决

1. 通过 RW 节点

   目前 PolarDB 和 Aurora 都选择类似的做法, 都是在 RW 节点进行限制. PolarDB 叫刷脏约束, Aurora 是限制 page server 生成新版本page.

   

   但是这个方案存在2个问题. 

   1. 因为内存都有限制, 因此如果一个 RO 阶段延迟太后, 那么内存可能撑不住, 所以 PolarDB 和 Aurora 都存在自动restart 逻辑
   2. 由于迟迟无法推进最新 Page, 那么读取最新 Page 需要old_page + redo => new page 那么性能可能受影响, 后面讲到的方案如果允许Redo log 放在磁盘上虽然可以规避内存问题, 但是增加了额外redo IO, 性能影响更大.

   两个方案都可以通过把redo log 持久化, PolarDB 通过刷脏的时候只写log index 但是不写Page, Aurora 可以通过Page server 内存中的redo log offload 到磁盘从而不会将内存打满.

   但是这样都会影响到latency.

   或者也可以实现类似.mibd 的解决方案, 核心还是不能对old page 原地更新, 将new_page 写入到新的文件里面, 等老 RO lsn 往前推进, 再进行把.mibd 写回到.ibd 文件中.

   多版本引擎实现类似方案, 但是这里问题在于page IO 写放大了 2 倍, 额外增加了一个读 Page IO 性能影响非常大.

   

2. 通过 RO 节点实现

   目前 Socrate 看过去是类似的做法, 不对 RW 节点刷脏进行限制, 允许 RW 节点任意刷脏, 那么就需要 RO 节点去处理不一致问题. 但是Socrates 里面提到访问到 Future Page 处理的方法非常简单, 就是一个简单的重试. 其实简单的重试是最直接的处理方法, 但是对性能有影响的. 需要有更细致的处理方法

   这里不一致问题主要有 2 个方面
   
   1. 逻辑不一致, 也就是可见性判断问题
   2. 物理不一致, 也就是 SMO 导致访问到的 Page 不一致问题.







**RO 读 Future Page**

如果希望去掉限制刷脏逻辑, 允许RO 读取到future page, 那么需要内核在这里处理两个问题



1. 逻辑一致性问题, 也就是可见性判断问题

   为什么在rw 上没有这个问题?

   rw 上面也会在没有事务commit 的时候, 提前就已经进行刷脏操作. 那么同样rw 也会读取到太新Page, 但是提前刷脏的page 里面的record 里面记录的trx_id 肯定在活跃事务数组里面, 那么就可以知道这个record 是不可见的, 可以通过readview 找到历史版本

   这个问题的本质是 rw 上更新readview 和 刷脏的先后顺序是可以保证的, 但是ro 上面不能保证. 出现了刷脏但是对应的trx_id 还没有传到ro. 导致读取到了未来 Page 的问题.

   为什么刷脏约束可以解决这个问题.

   因为刷脏约束保证了刷脏之前, 对应的redo log 已经传给ro 节点, 对应的 trx_id 也同步给 ro, 那么此刻ro 节点已经获得了正确的 readview, 那么此刻rw 再刷脏, 就和rw 的行为一致了

   

2. 物理一致性问题

   同样为什么rw 上没有这个问题?

   因为如果rw 上面发生了 SMO 操作, 如果有一个查询正在持有page s latch, 那么这个SMO 操作是无法进行的, 只有当查询操作将page s lock 释放了以后, 该 SMO 操作才可以进行.

   但是ro 上面的查询是无法限制SMO 的, 也就是 RO 上面的查询即使lock 了next_page, 但是这里next_page 还是有可能被更新.

   
   而如果有刷脏约束, 如何解决这个问题?

   有刷脏约束的情况下, 如果有SMO 情况发生, 那么根据 [PolarDB sync_counter](./PolarDB sync_counter) 介绍, 会去持有index x lock, 从而和RO 上面的查询互斥, 实现rw 类似的效果.

   如果没有刷脏约束, 该如何解决?

   可以通过在mtr 内部重试来解决, 类似Socrate 解决方案, 从而保证访问到的是同一个版本的btree. 这里重试的开销还是有的, 需要做的更加细致一些.

   1. 发生了 SMO, 这里也分 2 种
      1. 访问的 Record 还在当前 Page
      2. 访问的 Record 不在当前 Page


