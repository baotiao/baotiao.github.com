---
layout: post
title: "About TCP keepalive"
description: "About TCP keepalive"
category: tech
tags: [tcp, network]
---


这两天正好看到了TCP keepalive的一些疑惑, 具体就查看了一下

首先, 在建立tcp 连接以后, 就算你不使用这个连接, 这个连接是会一直保留着, 那么一般来说操作系统的句柄数是有限的, 所以我们有必要关闭那些虽然连着, 但是已经没有人使用的连接.

一般会有两种检查

1. 有应用层面做这个检查, 比如当这个连接有操作的时候, 更新最后一次操作的时间. 那么如果在规定时间内没有操作, 就将这个连接关闭掉. Bada的服务端关闭连接操作就是这么做的, Redis 的timeout 选项也是这样实现的.
2. 使用tcp keepalive 选项来检查

后续我们会看到, 这两个选项是有区别的

tcp 的 keepalive 选项比较适合用来检测一个连接是否断开, 但是这个keepalive是会消耗流量的.


其实理论上tcp 某一个端关闭连接, 另外的一端是会收到一个空包, 但是为什么还是需要这个tcp keepalive 这个选项呢? tcp keepalive 和 直接关闭tcp 连接的关系?

#### 场景1
首先当这个进程正常退出, 或者被kill 掉的时候, 这个时候关闭的这个进程所在的socket 会由操作系统来发出一个FIN 包给对端的socket的
因此只有由于直接挂机 或者 网络断开的情况下 这个包才是无法发送出去的. 所以也就是在这种情况下 tcp keepalive 会发挥作用.

这里如果A 已经挂掉了, 而A重新起来以后, B会认为这个连接还在, 因此会继续往这个连接发送信息, 那么A就会拒绝这个连接, 因为在A看来不存在过这个连接的.就回复B一个RST packet, 导致B最终去关闭这个连接

#### 场景2
另一个场景就是经常在proxy 里面经常用. 因为Proxy 经常需要保留固定个数的连接, 因为硬件肯定有限制的, 常见的做法就是将这些连接放在一个队列里面, 那么当连接不够用的时候, 常见的做法就是将这个队列里面的最老的连接删除掉. 所以如果你的连接使用keepalive 就可以保持自己的连接在队列里面较开始的位置

不过我觉得这个作用比较牵强, 如果所有连接都用keepalive,那基本等于没用了

### 总结

所以tcp keepalive 常见的用途
1. 检查peers 是否存活
2. Preventing disconnection due to network inactivity

而第一种应用层来检查连接存活经常用来检查客户端连接的存活, 因为客户端经常会保持发送连接


### 后续
可以修改 tcp keepalive 的三个参数

tcp_keepalive_time 开始发送keepalive包的时间, 这里的时间是距离最后一次这个连接发包的时间 这个默认参数是 7200

the interval between the last data packet sent (simple ACKs are not considered data) and the first keepalive probe; after the connection is marked to need keepalive, this counter is not used any further

tcp_keepalive_intvl 开始发送keepalive以后, 间隔多长时间可以发送下一个keepalive 包

the interval between subsequential keepalive probes, regardless of what the connection has exchanged in the meantime

tcp_keepalive_probes 总共发送keepalive 包的个数

the number of unacknowledged probes to send before considering the connection dead and notifying the application layer

可以通过 /proc 接口查看

      # cat /proc/sys/net/ipv4/tcp_keepalive_time
      7200

      # cat /proc/sys/net/ipv4/tcp_keepalive_intvl
      75

      # cat /proc/sys/net/ipv4/tcp_keepalive_probes
      9

setsockopt 对应的几个选项

    TCP_KEEPCNT: overrides tcp_keepalive_probes

    TCP_KEEPIDLE: overrides tcp_keepalive_time

    TCP_KEEPINTVL: overrides tcp_keepalive_intvl


写了一个程序验证了一下, 服务端添加keepalive 的支持以后, 并在建立连接以后, 用iptable把往客户端发送连接的端口关闭, 在经过TCP_KEEPINTVL的发送消息次数以后, 服务端会自动的关闭这个连接

EPOLLERR 8 EPOLLHUP 16 EPOLLIN 1 EPOLLOUT 2 EPOLLPRI 4

经过测试
客户端正常关闭的时候, 服务端收到的时间是
tfe->mask_ 1
也就是 EPOLLIN
也就是说正常的关闭逻辑, 只是返回一个EPOLLIN 1, 表示有数据到达, 然后这个时候read这个socket 的数据发现是空, 就知道是关闭的事件

如果是因为keepalive 收到事件, 那么返回的结果是这样
tfe->mask_ 25
也就是 EPOLLIN | EPOLLERR | EPOLLHUP
也就是说epoll 返回的事件是 有读, 错误, 并且挂断
这个时候其实程序也能读取这个fd 发现是空, 就知道是关闭的事件, 不过这里我认为这个事件应该是本地操作系统通知给这个fd的.
就是说当这个keepalive 发现对端失败的时候会notifying the application layer

参考资料: http://tldp.org/HOWTO/TCP-Keepalive-HOWTO/usingkeepalive.html

