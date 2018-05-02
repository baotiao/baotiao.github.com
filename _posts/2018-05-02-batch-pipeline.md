---
layout: post
title: Paper Review Optimizing Paxos with batching and pipelining
summary: Optimizing Paxos with batching and pipelining

---

### Paxos batch pipeline

使用batch, pipeline 一直是优化包含state machine 一致性协议的方法, 比如paxos, raft 等等, 这篇文章主要是提出了模型(cpu 利用率, 网络延迟, 网络带宽), 然后结合实际测试和仿真为我们提供了实际环境中如何使用batch, pipeline 的方法.



首先看结论

#### 结论

在同机房的场景中, 由于网络延迟较低, 即使在小包的情况下, 系统的瓶颈主要是是cpu, 因此**只需要通过batch 就可以达到系统最大的吞吐**,  而且batch 实现又较为简单, 因此几乎在任意的包含状态机的系统中, batch 是第一步要做的优化.

pipeline 的效果决定于节点的性能和网络延迟,  节点花越多的时间等待从副本的返回, 那么pipeline 带来的效果是越好的. pipeline 在上面的实验中可以看出, 如果允许选择过多的pipeline 会导致系统性能反而下降

那么在网络延迟比较高的跨机房场景中, 可以通过batch + pipeline 可以达到最大的吞吐.  那么该如何进行选择参数呢

1. 在用户能够接受的延迟下, 选择一个最大的batch size
2. 使用上述的模型, 选择一个合理的Pipeline 的值

为什么这样做呢?

首先batch 带来的优化是非常明显, 但是batch 过大会拉大返回的时间. 所在可以在给定带宽和相应时间的情况下, 我们可以很快的算出这个batch 的大小,  然后可以根据上述的模型, 可以算出设置pipeline 多少个的时候,可以获得最大的吞吐. 

比如在下面跨机房的模型里面,  如果平均请求的大小是1KB,  那么根据上述做法 batch 大小应该设置成8kb, 然后pipeline 的个数应该设置成16



### TLDR; 接下来是论文具体的内容



模型主要参数:

主要关注3个瓶颈点

1. 网络延迟

其实就是网络带宽的占用

2. cpu time

也就是cpu 的利用

3. 网络带宽



在局域网中,  主要的瓶颈是cpu, 在广域网中, 主要的瓶颈是网络延迟. 如果请求都是大包的场景中, 瓶颈主要是带宽

![Imgur](https://i.imgur.com/5q6zGJE.jpg)

出现瓶颈的过程基本是这样, 如果cpu 是瓶颈, 那么可以通过调整batch 的大小, 因为加大batch 的size 可以提高cpu 的利用率, 如果延迟是瓶颈, 那么可以增加Pipeline 的个数, 来减少延迟带来的影响.  如果带宽是瓶颈, 那么说明我们已经达到极限了.



最后如何设定这个pipeline 的个数呢? 

w = ⌈min(wcpu,wnet)⌉.

这里也就是看cpu 先达到瓶颈, 还是网络先打到瓶颈. 如果cpu 先打到瓶颈, 那么 w = wcpu, 如果是网络, 那么w = wnet. 



接下来就是通过实际的实验和仿真对模型的正确性进行了验证.

这里instance 值得是执行一整个batch 的时候, 所包含的所有请求, 也就是一个instance 包含多个client request

* 首先是同机房场景下的验证

这里的测试环境是同机房下netperf 940Mbit/s 的网络,

![Imgur](https://i.imgur.com/dEev8CP.jpg)



这里主要三个参数 WND 就是最大的pipeline 的个数, BSZ 就是最大的batch size, 三角形B是最大的batch 时候的timeout

从上面这个图可以看到

1. 无论 request size 是多少, pipeline 个数对qps 几乎没有影响, 主要原因是因为这个时候的主要瓶颈是cpu, 因此提高pipeline 个数对结果没有影响



![Imgur](https://i.imgur.com/mGfwchr.jpg)



上面这几图可以看出

1. 4(a) 图中, 随着batch size 的增加,  平均每一个客户端请求的延迟是立刻降低的, 比如这里从最开始的500ms 降低到了100ms 左右
2. 4(b) 图中, 随着batch size 的增加, 执行每一个instance 的延迟是增加的,  因为这个batch 的大小增加了, 也可以理解
3. 4(c) 随着这里batch size 的提高, qps 虽然在降低, 但是因为每一个instance 中包含的请求数是增加的, 因此整体的吞吐是增加的, 比如这里batch size 最小的时候 只有2000, 那么也就是只有200 的qps, 而3(a) 图中可以看到, 在有一定的batch 大小以后, qps 是可以达到12000 的

这里仍然可以看出, pipeline 的大小在同机房的场景下,是没有影响的

![Imgur](https://i.imgur.com/ZkwUDm5.jpg)

这个图中w = ⌈min(wcpu,wnet)⌉. w 表示的是在当前环境下, 最大化的利用资源时, pipeline 的个数, 可以看出, 在同机房的网络中, 几乎不需要pipeline 都可以达到最大值吞吐, 最大的资源利用率, 因此这里都可以看出wcpu 都会小于wnet, 因此cpu 一直都是瓶颈, 提高pipeline 是没有效果的.



* 在跨机房的场景中的仿真

这里测试场景中replicas 的带宽是10Mbits, 延迟是50ms



![Imgur](https://i.imgur.com/m1eRSDn.jpg)

从上图可以看到, 在高延迟的跨机房场景中, 虽然通过batch 还是能够有非常明显的性能提升, 比如在WND=1 的情形下, 无论batch size 的大小都从只有个位数的 qps 到了 request size = 128 的时候有3000, request size = 1kb 的时候到达了 600 等等, 但是还是无法达到最大的吞吐,  在request size = 1kb, 8kb 的时候, 甚至只有最大吞吐的一半的性能,  因此可以看出在跨机房的场景中, 仅仅通过batch 是达不到最大的吞吐



![Imgur](https://i.imgur.com/mW1cTR7.jpg)

从上面图中可以看到, 

上图(a) 中, 在高延迟的跨机房场景中, 在request size 比较小的时候, 仅仅通过pipeline 也同样达不到最大吞吐(这里k 表示的是一个batch 请求里面request 的个数),  但是在request size = 8kb 的时候, 是可以达到最大吞吐的.  为什么这样?

在request size 比较小的时候, 主要的瓶颈是cpu, 因此batching 能够降低平均每一个request 的cpu 利用率. 所以请求数就上来了, 但是当request size 比较大的时候, 那么这个时候主要瓶颈就是网络带宽或者网络延迟, 这个时候batch 就没用了. 当瓶颈是网络延迟的时候, pipeline 能够有效的提高吞吐, 但是当瓶颈是带宽的时候, 就没办法了

图(b),(c)还有一个结果是随着 pipeline window 大小的提高, 反而有性能的下降. 原因是pipeline 过多, 超过了网络的容量, 那么会导致包的丢失和重传, 进而影响了网络的效率.



![Imgur](https://i.imgur.com/zZrOYlo.jpg)

上图(a)可以看到在跨机房的网络中, 无论pipeline 的个数是多少, 使用batch 都能够明显降低客户端的延迟, 从原来的10s 降低到0.5s 左右,  pipeline 个数虽然也影响客户端的延迟, 但是影响的没有batch 那么明显. 

同样这里的测试可以看到其实 WND=5的时候, Latency 就已经差不多是最小的了, 所以在polarstore 里面Praft 里面的LBA 的大小是2~5 其实就够了, 之前我一直以为pipeline 的话, 一般都需要有上百个pipeline 并行才会达到最大的吞吐, 但是在praft 中LBA 从1=>2 就有了几乎翻倍的性能提升,  所以pipeline 其实不需要特别大, 有几个同时并行就够了.

上图(c) 可以看到通过batch 和 pipeline, 在跨机房的网络中,  同样如果batch size 比较小, 那么执行的instance 个数就比较多, 但是由于instance 中只包含1个request, 那么其实获得的qps 是不够高的, 需要选择合理batch size 才可以获得最大的qps. 比如这里合理的batch size 应该是20kb



![Imgur](https://i.imgur.com/EDamqgm.jpg)

从这里图里面可以看出 w 在request size 比较小并且batch size 也比较小的时候,  pipeline 个数需要 20~35 来实现最大的吞吐,  但是随着batch size 的增加, 其实还是只需要1~2 个来达到最大的吞吐. batch size 唯一的缺点是在压力不大的时候, request 也需要等待一段时间.


**Reference:** 
https://pdfs.semanticscholar.org/a0d0/cdd2e8af1945c03cfaf2cb451f71f208d0c9.pdf
