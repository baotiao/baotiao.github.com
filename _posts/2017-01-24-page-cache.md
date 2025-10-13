---
layout: post
title: page cache dirty_expire_interval 参数的一些问题 
summary: page cache dirty_expire_interval 一些问题
---


昨天分享[disk and page cache](https://www.slideshare.net/baotiao/disk-and-page-cache) 遗留了几个问题, 回去又看代码加实际验证了一下, 得到如下结论:

1. dirty_expired_interval 确实和我们昨天所说的是一样的效果

从代码层面上来看, 所有的dirty_inode 会被放入到 bdi_writeback 这个结构体, 保存在 b_dirty 这个list 里面, 然后在进行queue_io() 的时候会比较这个 dirty_expire_interval, 只有超过这个时间的dirty inode 才会放入到b_io 这个lish 里面, 接下来对于在b_io 这个list 进行刷盘操作.

从具体的验证层面来看, 我们写一个example

```c++
#include <iostream>
#include <sys/time.h>
#include <unistd.h>
#include <fcntl.h>
#include <string>
#include <stdio.h>

#include <stdint.h>

uint64_t NowMicros() {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return static_cast<uint64_t>(tv.tv_sec) * 1000000 + tv.tv_usec;
}


using namespace std;

int main()
{
  int fd = open("./czzres", O_RDWR | O_CREAT, 0644);

  uint64_t st = NowMicros();
  char buf[18];
  while (1) {
    st = NowMicros();
    snprintf(buf, sizeof(buf), "%ld\n", st);
    write(fd, buf, sizeof(buf));
  }

  return 0;
}
```

这个程序做的事情只有一个, 一直获得当前的时间戳, 然后把当前的时间戳写到这个 czzres, 这个文件里面.

然后我们做的事情就是让这个进程不断的写入数据, 然后突然将这个机器给关机, 然后记录关机的时间, 重启以后判断这个时间戳和我们关机的时间是否一致, 如果一直说明这个参数并不起作用, 如果里面的数据比我们关机的时间要来得晚, 这说明这个参数生效了

验证的结果

![Imgur](https://i.imgur.com/BhzgVrQ.png)

最后对应的时间是 2017/1/24 17:1:31

而我们的关机时间是

[vagrant@haoli-d1 ~]$ date
Tue Jan 24 09:01:39 UTC 2017

再次验证, 运行这个进程不到10s 以后, 直接重启机器, 在这个机器上甚至都没有生成过这个文件czzres, 进一步验证了我们的猜想

调整dirty_expire_interval 为 5, 也就是50ms, 看是否生效

得到的结论是czzres 里面的内容是

1485250286839995
1485250286839996
1485250286839996 = 2017/1/24 17:31:26

然后我们的时间date 是

[vagrant@haoli-d1 ~]$ date
Tue Jan 24 09:31:44 UTC 2017

证明也是生效的

### 结论

所以如果使用默认的配置, 也就是dirty_expired_interval, dirty_writeback_interval 分别是 30s, 5s 的时候, 那么最大有可能丢失的是35s 左右的数据. 

**那为什么线上的pika, mysql 等等不会有这么大量的数据丢失呢?**

因为这些引擎内部默认都会主动的去调用fsync() 将脏数据刷到磁盘, 比如pika 的引擎rocksdb, 在每一次compact 生成文件以后是会将sst 文件主动调用fsync 刷新到磁盘的. 比如mysql 的innodb 引擎每次执行完一个事务以后, 也是主动的调用fsync, 写binlog 的时候也是每写一次就调用fsync, 因此不会有大量的数据丢失

另外在page cache 的flush 策略里面, 如果一个文件有一个脏页, 那么他这个时候是将整个文件都进行flush 操作的, 而不是只flush 脏页的这一部分.

并且智昊昨天问题如果一个文件不断的写入, 那么岂不是这个30s 永远都打不到了, 不是这样的, 这里只会记录第一次变dirty 的时间, 后续如果是dirty 就不再更新这个时间了, 见kernel mailing list

> Well, let me explain the mechanism in more detail: When the first page is dirtied in an inode, the current time is recorded in the inode. When this time gets older than dirty_expire_centisecs, all dirty pages in the inode are written. So with this mechanism in mind the behavior you describe looks expected to me.
