---
layout: post
title: cpu cache tutorial
summary: cpu cache tutorial

---

### cpu cache

reference:

http://cenalulu.github.io/linux/all-about-cpu-cache/

http://igoro.com/archive/gallery-of-processor-cache-effects/

一般来说cpu cache line 的大小是64byte.

Cache Line可以简单的理解为CPU Cache中的最小缓存单位。目前主流的CPU Cache的Cache Line大小都是64Bytes。假设我们有一个512字节的一级缓存，那么按照64B的缓存单位大小来算，这个一级缓存所能存放的缓存个数就是`512/64 = 8`个。

cpu 的cache line 会有很多, 然后不同的 cache line 组成一个set, 也就是说同一个set 里面的多个cache line, 如果一个set 有8个cache line, 那么这个set 能够缓存的数据就是512 byte

所以cache coherence 指得就是由于 cpu 从内存中获取数据的时候, 一般都是64byte 的方式获取, 会提前prefetch, 那么比较好的做法是让cpu 顺序访问内存, 这样就可以充分利用到cpu prefetch 的特性, 如果是随机访问的话, 就无法利用这个特性了

**那么我们写代码的时候如何更好的使用cache line 呢?**

1. 尽可能的顺序访问内存, 不要随机访问内存. 因为一个cache line 的大小是64btye, 如果访问的内存不连续, 那么就浪费了这个prefetch 的内容, 同样对于写入也是如此, 顺序写入, 可以批量提交给cache, 能够最大限度利用总线带宽.

2. 在组织一个struct 的时候, 尽可能将有可能被一起访问, 因为这样能够保证cpu 从内存读取数据的时候都在一个 cache line 里面, 并且cpu 默认会进行预取 

3. 做好一个struct 内部的padding,  也就是尽可能按照64 bytes 做padding, 这样可以避免的问题是一个struct 在64 btyes 之内的不同的变量如果被多个cpu 获得, 也可能跨cache line, 那么在修改其中一个的时候, 需要把另外一个invalidate 掉才行.  特别是多核的场景, 这个问题就很明显.

   但是这里也有一个折衷, 就是我们设计struct 的结构体应该是尽可能的紧凑, 这样才能更有效的利用cpu cache line. 但是这里增加了padding 以后, 这个struct 就不紧凑了, 那么怎么权衡呢?

   在读多写少的场景中, 是不用在意 cache 冲突, 更在意的是内存的紧凑, 或者是局部性. 因为很少发生多个核修改同一个变量的场景, 通过padding 的设计反而需要cpu 进行两次读取.

   但是在写多读少的场景中,  就更多的需要注意padding, 因为多核场景大量的写入很容易导致cache invalidate, 因此需要更注重padding

   当然具体的如何设计struct 还是需要通过具体的benchmark 来统计.

   典型的代码dpdk 中 rte_ring struct 的设计比如:

   ```c
   struct rte_ring {
   	/*
   	 * Note: this field kept the RTE_MEMZONE_NAMESIZE size due to ABI
   	 * compatibility requirements, it could be changed to RTE_RING_NAMESIZE
   	 * next time the ABI changes
   	 */
   	char name[RTE_MEMZONE_NAMESIZE] __rte_cache_aligned; /**< Name of the ring. */
   	int flags;               /**< Flags supplied at creation. */
   	const struct rte_memzone *memzone;
   			/**< Memzone, if any, containing the rte_ring */
   	uint32_t size;           /**< Size of ring. */
   	uint32_t mask;           /**< Mask (size-1) of ring. */
   	uint32_t capacity;       /**< Usable size of ring */

   	/** Ring producer status. */
   	struct rte_ring_headtail prod __rte_aligned(PROD_ALIGN);

   	/** Ring consumer status. */
   	struct rte_ring_headtail cons __rte_aligned(CONS_ALIGN);
   };

   ```

   ```c
   /*
    * Open file table structure
    */
   struct files_struct {
     /*
      * read mostly part
      */
   	atomic_t count;
   	struct fdtable *fdt;
   	struct fdtable fdtab;
     /*
      * written part on a separate cache line in SMP
      */
   	spinlock_t file_lock ____cacheline_aligned_in_smp;
   	int next_fd;
   	struct embedded_fd_set close_on_exec_init;
   	struct embedded_fd_set open_fds_init;
   	struct file * fd_array[NR_OPEN_DEFAULT];
   };

   ```

   这里也是把常读的部分和写的部分分开,  来让这部分的数据在不同的cache line 中的目的

4. 尽可能的只让一个cpu 去访问某一个变量的内存, 这样cache line 被失效的情况就少很多, 代码里面尽可能减少全局变量

5. 类似于cpu 的体系结构那样, 做batch, pipeline.

http://www.lighterra.com/papers/modernmicroprocessors/

比如内核代码里面也有这样的代码



#### 那么在我们做存储相关的项目中, 关注cpu cache 带来的收益大么?

从延迟上考虑, 其实是不大.

写的好的对cpu cache 较为友好的代码, 而不关注cpu cache 友好的代码可能只有性能一倍差距(数据非自测), 但是对于存储服务来说, 通常的瓶颈要么在网卡, 要么是在磁盘上, cpu 是整个路径中非常小的一部分.

那么对于内存访问优化cpu cache 有意义么?

![Imgur](https://i.imgur.com/CKWdOb1.png)

比如从这种图中可以看到, 即使是l2 cache : main memory 也差不多是 1:10. 也就是说如果对于某一次访问 l2 cache 时间是 10ns, 然后内存访问的时间是100ns, 在没有优化前总的访问时间是 10 + 100 = 110ns, 在优化后访问的时间是 10/2 + 100 = 105 ns. 看起来对于延迟其实没有多大的提升. 只有5% 的性能优化. 

这么说其实对于优化cpu cache 确实意义不大了?

其实还有一个维度我们没有考虑了, 那就是 cpu 的利用率.

我们只考虑了延迟, 但是我们没有考虑的是如果cpu 从内存中访问数据的时候, 其实cpu 是hang住的,  也就是说会加大了 cpu 的利用率, 其实无形中也会影响cpu 对其他指令的执行. 也就是说如果在cpu 无压力的场景, 那么其实对 cpu cache 友好的代码差不多在内存访问上能带来5% 的性能提升, 但是在cpu 利用率比较大的场景中, 如果代码对 cpu cache 不友好, 那么会导致cpu 流水线中, 所有的指令都慢下来, 进一步的加大对cpu 的压力.


最后感谢 @望澜 同学的指点, 望澜对cpu 这块真的非常在行
