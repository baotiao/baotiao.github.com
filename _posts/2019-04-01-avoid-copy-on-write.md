---
layout: post
title: How InnoDB avoid "read-on-write" problem?
summary: How InnoDB avoid "read-on-write" problem
---

### avoid read-on-write


什么是 "read-on-write" problem?

在我们使用最常见的buffer write 中 "read-on-write" 问题指的是当我需要进行小于4k
大小buffer write 的时候, 需要先将数据所在的page 从disk 中读取出放入到page cache,
在page cache 中修改好, 然后再将这4k 数据写入回去. 这样在buffer write
的时候就多了一次磁盘IO

InnoDB 的做法是, 判断这个4k page 是不是第一次写入, 如果是第一次写入的话, 那么我会将这次写入填0, 变成4k 大小的size, 然后进行写入, 这样就可以避免了一次 "read-on-write" 操作, 后续继续写入的时候, 就不需要进行4k 大小的io, 因为这个时候数据已经在page cache 中,  直接写入就可以的. 

我原先的想法是在内存中保留这个4k 大小的buffer, 每次修改都修改4k 大小的buffer, 每次写入也都进行4k 大小的写入, 这样做法反而不过InnoDB 的做法来得好, 因为每次写入都变成4k, 从用户空间拷贝到page cache 也需要拷贝4k 大小的数据, 而InnoDB 的做法只需要拷贝数据大小的size 就可以, 做的更细


下面两个例子可以看出同样写1G 大小的文件. InnoDB 的做法比标准追加写入做法提高40%

t.cc

write time microsecond(us) 51668825

t2.cc

write time microsecond(us) 29358162

```c
// t.cc
// 标准的通过pwrite 的写入方法
// 如果将这里的pwrite 改成write, 我们获得的还是几乎一样的performance
// num = pwrite(fd, aligned_buf, dsize, off);
// 估计在pwrite 内部实现, 如果只有一个线程写入, 并且这个offset 并没有移动, 就不需要先进行seek, 再write 了

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/time.h>
#include <stdint.h>
#include <random>

#include <linux/falloc.h>
#include <sys/syscall.h>

uint64_t NowMicros() {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return static_cast<uint64_t>(tv.tv_sec) * 1000000 + tv.tv_usec;
}
int main()
{
  uint64_t st, ed;
  uint64_t file_size = 1LL * 1024LL * 1024LL * 1024LL;
  int fd = open("/disk11/tf", O_CREAT | O_RDWR, 0666);
  int ret;
  unsigned char *aligned_buf;
  int dsize = 512;
  ret = posix_memalign((void **)&aligned_buf, 4096, 4096 * 10);
  for (int i = 0; i < dsize; i++) {
    aligned_buf[i] = (int)random() % 128;
  }

  lseek(fd, 0, SEEK_SET);
  st = NowMicros();
  int num;
  off_t off = 0;
  for (uint64_t i = 0; i < file_size / dsize; i++) {
    num = pwrite(fd, aligned_buf, dsize, off);
    off += 512;
    fsync(fd);
    if (num != dsize) {
      printf("write error num %d\n", num);
      return -1;
    }
  }
  ed = NowMicros();
  printf("write time microsecond(us) %lld\n", ed - st);

  return 0;
}
```

iostat 上, 可以看到nvme8n1有明显的磁盘read IO 存在

![Imgur](https://i.imgur.com/FTpsY4H.jpg)



```c
// t2.cc
// InnoDB 优化做法, 在遇到第一个4k 对齐地址的时候, 将当前这一次IO 对齐成4k, 空闲的部分filling zero. 从而避免了这一次需要将该page 从文件中读取到Page cache
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/time.h>
#include <stdint.h>
#include <random>
#include <stdlib.h>
#include <string.h>

#include <linux/falloc.h>
#include <sys/syscall.h>

uint64_t NowMicros() {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return static_cast<uint64_t>(tv.tv_sec) * 1000000 + tv.tv_usec;
}
int main()
{
  uint64_t st, ed;
  uint64_t file_size = 1LL * 1024LL * 1024LL * 1024LL;
  int fd = open("/disk11/tf", O_CREAT | O_RDWR, 0666);
  int ret;
  unsigned char *aligned_buf;
  int dsize = 512;
  ret = posix_memalign((void **)&aligned_buf, 4096, 4096 * 10);
  for (int i = 0; i < dsize; i++) {
    aligned_buf[i] = (int)random() % 128;
  }

  lseek(fd, 0, SEEK_SET);
  st = NowMicros();
  int num;
  off_t off = 0;
  for (uint64_t i = 0; i < file_size / dsize; i++) {
    if (i % 8 == 0) {
      memset(aligned_buf + 512, 0, 4096);
      num = pwrite(fd, aligned_buf, 4096, off);
    } else {
      num = pwrite(fd, aligned_buf, dsize, off);
    }
    off += 512;
    fsync(fd);
    if (num != dsize && num != 4096) {
      printf("write error num %d\n", num);
      return -1;
    }
  }
  ed = NowMicros();
  printf("write time microsecond(us) %lld\n", ed - st);

  return 0;
}
```

iostat 可以看到这个时刻nvme8n1是没有磁盘的read IO 存在的

![Imgur](https://i.imgur.com/hsrB0oT.jpg)



通过 blktrace 可以看到每一个IO的过程, 可以看详细的看到在t2 中是有read IO 的存在, 并且可以看到
在t 中read IO : write IO = 1:8


这是通过blktrace 看到的 t2 的IO

```shell
259,9    2      357     0.001166883     0  C  WS 75242264 + 8 [0]
## 一个IO 的开始
259,6    2      358     0.001173249 113640  A  WS 75242264 + 8 <- (259,9) 75240216
259,9    2      359     0.001173558 113640  Q  WS 75242264 + 8 [a.out]
259,9    2      360     0.001173664 113640  G  WS 75242264 + 8 [a.out]
259,9    2      361     0.001173939 113640  U   N [a.out] 1
259,9    2      362     0.001174017 113640  I  WS 75242264 + 8 [a.out]
259,9    2      363     0.001174249 113640  D  WS 75242264 + 8 [a.out]
259,9    2      364     0.001180838     0  C  WS 75242264 + 8 [0]
## 一个IO 的结束
259,6    2      365     0.001187163 113640  A  WS 75242264 + 8 <- (259,9) 75240216
259,9    2      366     0.001187367 113640  Q  WS 75242264 + 8 [a.out]
259,9    2      367     0.001187477 113640  G  WS 75242264 + 8 [a.out]
259,9    2      368     0.001187755 113640  U   N [a.out] 1
259,9    2      369     0.001187835 113640  I  WS 75242264 + 8 [a.out]
259,9    2      370     0.001188072 113640  D  WS 75242264 + 8 [a.out]
259,9    2      371     0.001194495     0  C  WS 75242264 + 8 [0]
259,6    2      372     0.001200968 113640  A  WS 75242264 + 8 <- (259,9) 75240216
259,9    2      373     0.001201164 113640  Q  WS 75242264 + 8 [a.out]
259,9    2      374     0.001201268 113640  G  WS 75242264 + 8 [a.out]
259,9    2      375     0.001201540 113640  U   N [a.out] 1
```

从上面可以看出, 这个IO 从开始到结束都不会有Read 相关的IO

对比于t 产生的IO 是这样的

```shell
# 一个IO 的开始, 从这里可以看到这里有读IO 的出现, 并且其实这里是每产生1个读IO, 后续跟着8个 write IO

259,6    0      184     0.001777196 58995  A   R 55314456 + 8 <- (259,9) 55312408
259,9    0      185     0.001777463 58995  Q   R 55314456 + 8 [a.out]
259,9    0      186     0.001777594 58995  G   R 55314456 + 8 [a.out]
259,9    0      187     0.001777863 58995  D  RS 55314456 + 8 [a.out]
259,9    0      188     0.002418822     0  C  RS 55314456 + 8 [0]
# 一个读IO 结束
259,6    0      189     0.002423915 58995  A  WS 55314456 + 8 <- (259,9) 55312408
259,9    0      190     0.002424192 58995  Q  WS 55314456 + 8 [a.out]
259,9    0      191     0.002424434 58995  G  WS 55314456 + 8 [a.out]
259,9    0      192     0.002424816 58995  U   N [a.out] 1
259,9    0      193     0.002424992 58995  I  WS 55314456 + 8 [a.out]
259,9    0      194     0.002425247 58995  D  WS 55314456 + 8 [a.out]
259,9    0      195     0.002432434     0  C  WS 55314456 + 8 [0]
```



