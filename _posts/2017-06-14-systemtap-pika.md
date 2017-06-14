---
layout: post
title: 使用systemtap 找内存泄露问题
summary: 使用systemtap 查找pika 内存泄露的问题

---


前几周搞了好多天pika 内存泄露的问题, pika 在使用的过程中,在非正常关闭连接的情况下, 由于pika 网络编程框架Pink 在代码实现中没有正确处理, 导致非正常关闭的情况下, 只把这个句柄关闭, 而这个时候对应的连接指针依然是NULL, 导致这个连接的指针丢失, 导致了内存泄露.

程序的内存泄露是一个写c++程序常见的棘手的问题, 特别是在测试环境难以复现, 线上环境需要运行很长一段时间以后才可以出现的问题. 不稳定复现的bug 不是好bug

在排查这个问题的过程中, 发现systemtap 是一个好东西, 除了可以用来看内核的调用栈以外, 还可以用来观测用户空间的函数调用并进行统计,  并且systemtap 与valgrind 相比, 无需编译的时候加任何参数, 直接在线上就可以使用(当然了线上需要安装debuginfo debuginfo-common), 不需要业务的配合也可以观测

```shell
#!/usr/bin/stap

# 这里核心的想法就是通过systemtap 找到malloc, realloc 返回的地址, 
# 可以通过systemtap 里面的$return 来获得, 并记录, 然后再记录free 的时候是否对这些地址进行过free. 
# 可以通过 $ptr 来获得. 具体的systemtap 用法可以看官网

probe begin
{
  log("begin to probe\n")
}

# 对某一个地址调用的malloc, free的次数. 
# 如果 = 0, 说明正常free掉, 
# 如果 = 1, 说明malloc, 但是还没被free
# 如果 > 1, 说明这个地址被多次给malloc返回给用户, 肯定不正常
# 如果 < 1, 说明这个地址被多次free 也就是我们常说的double free 问题
global g_cnt
# 用来记录前一次调用的时候的 ubacktrace 信息
global g_stack
# 用来记录上次操作的时间
global g_time

# 每一次malloc, realloc 最后都会调到glic 里面的__libc_malloc, __libc_calloc
probe process("/usr/local/pika22/lib/libtcmalloc.so.4").function("__libc_malloc").return, process("/usr/local/pika22/lib/libtcmalloc.so.4").function("__libc_calloc").return

{
	if (tid() == 11808) {
			g_cnt[$return]++
			g_stack[$return] = sprint_ubacktrace()
			g_time[$return] = gettimeofday_s()
	}
}

probe process("/usr/local/pika22/lib/libtcmalloc.so.4").function("__libc_free") {
	if (tid() == 11808 && g_time[$ptr] != 0) {
    # 这里对于之前没有进行过处理的节点忽略
    g_cnt[$ptr]--
    # 正常的malloc free 分支
		if (g_cnt[$ptr] == 0) {
			if ($ptr != 0) {
				printf("A normal malloc and free\n")
				g_stack[$ptr] = sprint_ubacktrace()
			}
      # 可能出现的double free 分支
		} else if (g_cnt[$ptr] < 0 && $ptr != 0) {
				printf("double free problem address %d cnt %d\n", $ptr, g_cnt[$ptr])
				printf("%s\n", g_stack[$ptr])
				printf("the destructure \n")
				print_ubacktrace() 
      # 多次malloc 返回同一个地址的分支, 这种情况很少见
		} else if (g_cnt[$ptr] > 1 && $ptr != 0) {
			printf("malloc large than 0\n")
			print_ubacktrace()
		}
	}
}

probe timer.s(5) {
	foreach (mem in g_cnt) {
    # 这里可以根据定义来调整这个10 的大小, 也就是说这里想打印出 10s 之前申请过内存
    # 但是 10s 之内没有被free 的情况, 这里因为 pika 在短连接的时候都是10之内申请 然后就释放
    # 如果10s 之内没有释放, 那肯定就是内存出现了问题
		if (g_cnt[mem] > 0 && gettimeofday_s() - g_time[mem] > 10) {
			printf("\n\n%s\n\n", g_stack[mem])
		}
	}
}
```



可以看到有这样的输出结果:

```
_ZN4pink9RedisConnC2EiRKSs+0x8d [pika]
_ZN14PikaClientConnC1EiSsPN4pink6ThreadE+0x11 [pika]
_ZN4pink12WorkerThreadI14PikaClientConnE10ThreadMainEv+0x33c [pika]
_ZN4pink6Thread9RunThreadEPv+0x9d [pika]
start_thread+0xd1 [libpthread-2.12.so]
__clone+0x6d [libc-2.12.so]



_ZN4pink9RedisConnC2EiRKSs+0x7c [pika]
_ZN14PikaClientConnC1EiSsPN4pink6ThreadE+0x11 [pika]
_ZN4pink12WorkerThreadI14PikaClientConnE10ThreadMainEv+0x33c [pika]
_ZN4pink6Thread9RunThreadEPv+0x9d [pika]
start_thread+0xd1 [libpthread-2.12.so]
__clone+0x6d [libc-2.12.so]



_ZN4pink9RedisConnC2EiRKSs+0x8d [pika]
_ZN14PikaClientConnC1EiSsPN4pink6ThreadE+0x11 [pika]
_ZN4pink12WorkerThreadI14PikaClientConnE10ThreadMainEv+0x33c [pika]
_ZN4pink6Thread9RunThreadEPv+0x9d [pika]
start_thread+0xd1 [libpthread-2.12.so]
__clone+0x6d [libc-2.12.so]
```

以上就是在这个stap 起来以后, 申请的内存在10s 内没有被正常free 的操作, 这样根据这个堆栈信息就可以知道是我们申请了RedisConn 以后, 并没有被释放导致的内存泄露, 具体看代码我们可以发现

具体代码如下:

```c++
		  // 这里声明获得对应的连接的指针
          in_conn = NULL;
          int should_close = 0;
          std::map<int, void *>::iterator iter = conns_.begin();
          if (pfe == NULL) {
            continue;
          }
          iter = conns_.find(pfe->fd_);
          if (iter == conns_.end()) {
            pink_epoll_->PinkDelEvent(pfe->fd_);
            continue;
          }
          if (pfe->mask_ & EPOLLIN) {
            // 如果有读事件, 则对这个连接进行赋值
            in_conn = static_cast<Conn *>(iter->second);
            ...
          }
          if (pfe->mask_ & EPOLLOUT) {
            // 如果有读事件, 则对这个连接进行赋值
            in_conn = static_cast<Conn *>(iter->second);
            ...
             
          }
          if ((pfe->mask_  & EPOLLERR) || (pfe->mask_ & EPOLLHUP) || should_close) {
            {
            RWLock l(&rwlock_, true);
            pink_epoll_->PinkDelEvent(pfe->fd_);
            // 这里这两行关闭这个句柄, 并清空对应的连接
            // 由于如果没有接收到读或者写事件, 那么这里的in_conn 依然是NULL
            // 因此就造成了内存泄露
            close(pfe->fd_);
            delete(in_conn);
            in_conn = NULL;

            conns_.erase(pfe->fd_);
            }
          }
 
```

从上面的代码注释中就可以看出内存泄露的原因了.  目前已经修改了Pika 的网络编程框架Pink.

修改后

```c++
		   // 这里声明获得对应的连接的指针
          in_conn = NULL;
          int should_close = 0;
          std::map<int, void *>::iterator iter = conns_.begin();
          if (pfe == NULL) {
            continue;
          }
          iter = conns_.find(pfe->fd_);
          if (iter == conns_.end()) {
            pink_epoll_->PinkDelEvent(pfe->fd_);
            continue;
          }
          // 不论有什么事件到达, 先对对应的连接赋值
          in_conn = static_cast<Conn *>(iter->second);
          if (pfe->mask_ & EPOLLIN) {
            // 那么这里就不需要赋值了
            ...
          }
          if (pfe->mask_ & EPOLLOUT) {
            // 那么这里就不需要赋值了
            ...
          }
```

不过上面依然有困惑我们的地方在于, 无论是调用close() 关闭连接, 还是通过Kill 强行杀死进程, 都会产生读事件, 因此对应的in_conn 能够赋值, 也就能够正常释放了. 可是出现问题的时候关闭一个连接并没有读事件产生. 后续再看看吧 
