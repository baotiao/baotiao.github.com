---
layout: post
title: Note tcpip 15 TCP Data Flow and window management
summary: tcpip 15 TCP Data Flow and window management

---

这一章数据流已经窗口管理主要解决的是如何合理的在不考虑网络带宽的限制情况下, 只考虑发送端和接收端的处理能力, 通过滑动窗口的控制, 能够达到最大吞吐的目的. 也就是说既可以避免发送端发送过多消息, 但是接收端处理不过来, 也不会说发送的消息太慢, 接收端一直在等待这样的场景

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
