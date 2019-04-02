---
layout: post
title: How to write file faster
summary: How to write file faster
---

结论:

同样写1G 大小的文件, 4k memory and file address aligned 写入:

buffer write: 16920538 us

fallocate + buffer write: 13469360 us

fallocate + filling zero + buffer write: 4028809 us 



可以看出fallocate + filling zero +buffer write 的写入时间只有普通buffer write 的1/4



原因是: 在fallocate 阶段,  当我用fallocate 对一个文件预先分配空间的时候, 只是从文件系统中获得了对应的free extents, 但是并不保证把这些extents 里面中的原有数据filling zero. 只有在第一次写入的时候, 会把这个extents 标记成当前这个file 使用, 所以当进行writing 需要分片新的extents的时候, 需要修改文件中的meta data.



```c
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/time.h>
#include <stdint.h>
#include <random>


uint64_t NowMicros() {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return static_cast<uint64_t>(tv.tv_sec) * 1000000 + tv.tv_usec;
}
int main()
{
  uint64_t st, ed;
  off_t file_size = 1 * 1024 * 1024 * 1024;
  int fd = open("/disk11/tf", O_CREAT | O_RDWR, 0666);
  st = NowMicros();
  // int ret;
  int ret = fallocate(fd, 0, 0, file_size);
  if (ret != 0) { 
    printf("fallocate err %d\n", ret);
  }
  ed = NowMicros();
  printf("fallocate time microsecond(us) %lld\n", ed - st);
  lseek(fd, 0, SEEK_SET);
  int dsize = 4096;
  unsigned char *aligned_buf;
  ret = posix_memalign((void **)&aligned_buf, 4096, 4096 * 10);
  for (int i = 0; i < dsize; i++) {
    aligned_buf[i] = (int)random() % 128;
  }
  st = NowMicros();
  int num;
  for (uint64_t i = 0; i < file_size / dsize; i++) {
    num = write(fd, aligned_buf, dsize);
    fsync(fd);
    if (num != dsize) {
      printf("write error\n");
      return -1;
    }
  }
  ed = NowMicros();
  printf("first write time microsecond(us) %lld\n", ed - st);

  sleep(10);
  lseek(fd, 0, SEEK_SET);
  st = NowMicros();
  for (uint64_t i = 0; i < file_size / dsize; i++) {
    num = write(fd, aligned_buf, dsize);
    fsync(fd);
    if (num != dsize) {
      printf("write error\n");
      return -1;
    }
  }
  ed = NowMicros();
  printf("second write time microsecond(us) %lld\n", ed - st);
  return 0;
}

```

FALLOC_FL_ZERO_RANGE mode 是在内核3.15 版本才引入, 也就是在fallocate 以后, 会做filling zero 操作.



所以在write 的时候, 用fallocate 还是能够提高性能的, 因为write 操作主要修改3个部分的信息

1. 文件的总metadata, 包含文件的大小等等
2. 文件的metadata 中具体的文件所对应的extents 信息, 之所以要和上面的meta 信息区分开来, 是因为1 中的metadata 是每一次write 的时候都需要修改的, 但是2 中的metadata 只是具体有数据写入的时候动态修改的. 
3. 文件的具体数据

 所以fallocate 的时候只能够指定的是文件大小的meta 信息,  但是具体data block 所对应的磁盘中extents的信息是否属于当前文件还需要等有数据写入是才知道.  因此使用fallocate 以后可以减少每次修改文件大小的metadata, 但是还是会有更新data block 和磁盘中extent 的关系的metadata

因此 buffer write < fallocate + buffer write < fallocate + filling zero + buffer write

从blktrace 中可以看到这样的信息.

buffer write:

```shell
# jbd2 修改元信息相关IO
259,6   33      200     0.000755218  1392  A  WS 1875247968 + 8 <- (259,9) 1875245920
259,9   33      201     0.000755544  1392  Q  WS 1875247968 + 8 [jbd2/nvme8n1p1-]
259,9   33      202     0.000755687  1392  G  WS 1875247968 + 8 [jbd2/nvme8n1p1-]
259,6   33      203     0.000756124  1392  A  WS 1875247976 + 8 <- (259,9) 1875245928
259,9   33      204     0.000756372  1392  Q  WS 1875247976 + 8 [jbd2/nvme8n1p1-]
259,9   33      205     0.000756607  1392  M  WS 1875247976 + 8 [jbd2/nvme8n1p1-]
259,6   33      206     0.000756920  1392  A  WS 1875247984 + 8 <- (259,9) 1875245936
259,9   33      207     0.000757191  1392  Q  WS 1875247984 + 8 [jbd2/nvme8n1p1-]
259,9   33      208     0.000757293  1392  M  WS 1875247984 + 8 [jbd2/nvme8n1p1-]
259,6   33      209     0.000757580  1392  A  WS 1875247992 + 8 <- (259,9) 1875245944
259,9   33      210     0.000757834  1392  Q  WS 1875247992 + 8 [jbd2/nvme8n1p1-]
259,9   33      211     0.000758032  1392  M  WS 1875247992 + 8 [jbd2/nvme8n1p1-]
259,9   33      212     0.000758333  1392  U   N [jbd2/nvme8n1p1-] 1
259,9   33      213     0.000758425  1392  I  WS 1875247968 + 32 [jbd2/nvme8n1p1-]
259,9   33      214     0.000759065  1392  D  WS 1875247968 + 32 [jbd2/nvme8n1p1-]
# 对当前jbd2 IO 进行提交, 可以看出这次总共写了32 * 512 = 16kb 大小的数据
259,9   33      215     0.000769924     0  C  WS 1875247968 + 32 [0]
259,6   33      216     0.000775814  1392  A FWFS 1875248000 + 8 <- (259,9) 1875245952
259,9   33      217     0.000776110  1392  Q  WS 1875248000 + 8 [jbd2/nvme8n1p1-]
259,9   33      218     0.000776207  1392  G  WS 1875248000 + 8 [jbd2/nvme8n1p1-]
259,9   33      219     0.000776609  1392  D  WS 1875248000 + 8 [jbd2/nvme8n1p1-]
# 对当前的jbd2 IO 进行提交, 可以看出这次总共写了8 * 512 = 4k 大小的数据
259,9   33      220     0.000783089     0  C  WS 1875248000 + 8 [0]
# 用户IO 的开始
259,6    2       64     0.000800621 121336  A  WS 297152 + 8 <- (259,9) 295104
259,9    2       65     0.000801007 121336  Q  WS 297152 + 8 [a.out]
259,9    2       66     0.000801523 121336  G  WS 297152 + 8 [a.out]
259,9    2       67     0.000802355 121336  U   N [a.out] 1
259,9    2       68     0.000802469 121336  I  WS 297152 + 8 [a.out]
259,9    2       69     0.000802911 121336  D  WS 297152 + 8 [a.out]
259,9    2       70     0.000810247     0  C  WS 297152 + 8 [0]
# 用户IO 的结束
```



buffer write + fallocate

```shell
# jbd2 修改元信息相关IO
259,6   33      333     0.001604577  1392  A  WS 1875122848 + 8 <- (259,9) 1875120800
259,9   33      334     0.001604926  1392  Q  WS 1875122848 + 8 [jbd2/nvme8n1p1-]
259,9   33      335     0.001605169  1392  G  WS 1875122848 + 8 [jbd2/nvme8n1p1-]
259,6   33      336     0.001605627  1392  A  WS 1875122856 + 8 <- (259,9) 1875120808
259,9   33      337     0.001605896  1392  Q  WS 1875122856 + 8 [jbd2/nvme8n1p1-]
259,9   33      338     0.001606108  1392  M  WS 1875122856 + 8 [jbd2/nvme8n1p1-]
259,9   33      339     0.001606465  1392  U   N [jbd2/nvme8n1p1-] 1
259,9   33      340     0.001606622  1392  I  WS 1875122848 + 16 [jbd2/nvme8n1p1-]
259,9   33      341     0.001607091  1392  D  WS 1875122848 + 16 [jbd2/nvme8n1p1-]
# 对当前jbd2 IO 进行提交, 可以看出这次总共写了16 * 512 = 16kb 大小的数据
259,9   33      342     0.001614981     0  C  WS 1875122848 + 16 [0]
259,6   33      343     0.001619920  1392  A FWFS 1875122864 + 8 <- (259,9) 1875120816
259,9   33      344     0.001620237  1392  Q  WS 1875122864 + 8 [jbd2/nvme8n1p1-]
259,9   33      345     0.001620443  1392  G  WS 1875122864 + 8 [jbd2/nvme8n1p1-]
259,9   33      346     0.001620694  1392  D  WS 1875122864 + 8 [jbd2/nvme8n1p1-]
# 对当前的jbd2 IO 进行提交, 可以看出这次总共写了8 * 512 = 4k 大小的数据
259,9   33      347     0.001627171     0  C  WS 1875122864 + 8 [0]
259,6   49      146     0.001641484 119984  A  WS 119802016 + 8 <- (259,9) 119799968
259,9   49      147     0.001641825 119984  Q  WS 119802016 + 8 [a.out]
259,9   49      148     0.001642057 119984  G  WS 119802016 + 8 [a.out]
259,9   49      149     0.001642770 119984  U   N [a.out] 1
259,9   49      150     0.001642946 119984  I  WS 119802016 + 8 [a.out]
259,9   49      151     0.001643426 119984  D  WS 119802016 + 8 [a.out]
259,9   49      152     0.001649782     0  C  WS 119802016 + 8 [0]
```

从上面的对比可以看出, buffer write 在修改元信息阶段会比buffer write + fallocate 多增加了16kb 大小的IO, 我理解这个额外的16KB 大小的IO 是修改file 的meta 数据, 比如文件的大小. 而额外的4k 是两种IO 都需要的写入free extents 的信息



fallocate + filling zero + buffer write

```shell
# 一个IO 的开始

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

可以看出, 两个IO 之间不需要jdb2 进行元信息的修改, 从而比buffer write + fallocate 又节省了 20kb 大小的IO



* 如果使用dsize = 512, blktrace 看到的信息更加明显

当写入数据的大小是512 的时候, 没有fallocate 之前, 每写一次数据, 就需要有jbd2 的IO, 每次都需要去修改文件的大小. 有了fallocate 之后, 写8次才需要有一个jdb2 的IO, 写到4k 大小的数据, 才需要更新free extent信息. 在第二次写入的时候, 就完全没有jbd2 的IO 了.



总结: 所以在顺序写这样的场景中, 比较好的方式是复用当前文件, 在创建新文件的时候通过rename 的方式, 将旧文件复用, 在没有文件可以复用的场景, 通过后台线程提前创建文件并且filling zero 从而达到高效的写入, 这也是我们线上的做法.
