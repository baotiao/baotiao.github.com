---
layout: post
title: page reclaim wartermark
summary: linux 的 page reclaim 操作在什么时候触发

---

首先我们知道操作系统的物理页主要被两部分使用, 一部分是实际使用的物理内存, 也叫anonymous page, 另一部分是 page cache. 同时我们还有 swap 区, 用来在内存不够的时候将 anonymous page 里面的页面置换到 swap 上. 

那么kernel 什么时候认为内存是不够的, 需要做 page reclaim呢?

我们通过 cat /proc/zoneinfo 可以看到这样的信息

```
Node 1, zone   Normal
  pages free     19387934
        min      11289
        low      14111
        high     16933
```
这里这几个 min, low, high 又是什么意思?

首先需要了解的一个概念是The Pool of Reserved Page Frames. 意思是每一个 zone 都需要保留一些 page frame. 为什么每一个 zone 都需要保留一些 page frames 呢? 我们知道操作系统在内存不够的时候, 可以直接进行 direct page reclaim, 回收部分的page frame, 那为什么还需要保留一些 page frames 呢?

因为在 kernel 内部有一些操作是不允许切换的, 比如在处理一个中断的时候或者执行代码的某一临界区域. 在这个时候kernel 的内存申请操作必须是 atomic 的(这个在内存申请的 flag 里面有GFP_ATOMIC). 为了满足这个 atomic 内存申请的需求, 因此我们必须在每个 zone 保留一定数目的 page. 所以低于这个数目的 free pages frame 以后, kernel 就认为自己处于 low_memory 状态了. 我们管这个数叫 min_free_bytes. 那么这个数是怎么算的?

每一个 zone 的初始化的时候都需要执行

mm/wmark_alloc:init_per_zone_wmark_min() 


在init_per_zone_wmark_min 里面主要初始化设置了 min_free_kbytes 

The amount of the reserved memory (in kilobytes) is stored in the min_free_kbytes variable. Its initial value is set during kernel initialization and depends on the amount of physical memory that is directly mapped in the kernel’s fourth gigabyte of linear addresses—that is, it depends on the number of page frames included in the ZONE_DMA and ZONE_NORMAL memory zones:

min_free_kbytes = int_sqrt(16 × directly mapped memory)     (kilobytes)

```c
// 这里 lowmem_kbytes 就是映射在操作系统的实际物理内存上面的 physical memory 的 page 数, 其实就是 ZONE_DMA + ZONE_NORMAL 的 page
lowmem_kbytes = nr_free_buffer_pages() * (wmark_SIZE >> 10);
min_free_kbytes = int_sqrt(lowmem_kbytes * 16);
```

However, initially min_free_kbytes cannot be lower than 128 and greater than 65,536.

这个min_free_kbytes 最大64M 最小128k,  所以一般 kernel 里面为 atomic 操作留的 page 数有几十 M. 这个 min_free_kbytes 是对于全部的 zone 而言,  因为希望满足 kernel 的 atomic 类型的内存申请操作肯定是对于全部的物理内存而言的

有了这个概念以后, 我们就知道每一个 zone 里面的 wmark_min, wmark_low, wmark_high 这些 watermark 数值是什么意思了

然后接下来设置wmark_min, wmark_low, wmark_high 这几个watermark 主要在setup_per_zone_wmarks() 这个函数里面

那么具体的计算 wmark_min, wmark_low, wmark_high 过程

```c
unsigned long pages_min = min_free_kbytes >> (PAGE_SHIFT - 10);
unsigned long lowmem_pages = 0;
struct zone *zone;
unsigned long flags;

/* Calculate total number of !ZONE_HIGHMEM pages */
for_each_zone(zone) {
  if (!is_highmem(zone))
    lowmem_pages += zone->present_pages;
}

for_each_zone(zone) {
  u64 tmp;

  spin_lock_irqsave(&zone->lock, flags);
  tmp = (u64)pages_min * zone->present_pages;
  do_div(tmp, lowmem_pages);
  zone->watermark[WMARK_MIN] = tmp;
  zone->watermark[WMARK_LOW]  = min_wmark_pages(zone) + (tmp >> 2);
  zone->watermark[WMARK_HIGH] = min_wmark_pages(zone) + (tmp >> 1);

```

可以看出这里每一个 zone 的 wmark_min 的根据自己的内存大小比例分配对应百分比的 min_free_kbytes. 也就是所有 zone 的 wmark_min 加起来就是这个 min_free_kbytes

wmark_low = 5/4 * wmark_min

wmark_high = 3/2 * wmark_min

每一个zone 还有一个reserve page, 用来限制在 high level zone 满足不了请求的情况下, low level zone 自己需要保留的page数.具体的初始化在

setup_per_zone_lowmem_reserve()

那么这里来理解一下设置这些wmark_min, wmark_low, wmark_high 的目的了.

这里min_free_kbytes 主要是kernel 为了留给`__GFP_ATOMIC` 类型的内存申请操作, 因为在操作系统里面有一些内存申请操作是不允许切换的,也就是不能在这个时候把当前这个 cpu 交给别的进程, 比如handling an interrupt or executing code inside an critical region. 那么这时候肯定也是希望kernel 内存申请操作应该是非阻塞的. 因此希望系统至少能够留下 min_free_kbytes 的空间用户`__GFP_ATOMIC` 类型的内存申请操作.

wmark_min 是说当前的这个空闲的 page frame 已经极地了, 当有内存申请操作的时候, 如果是非内核的内存申请操作, 那么就返回失败, 如果申请操作来自kernel, 比如调用的是 __alloc_pages_high_priority() 的时候, 就可以返回内存

wmark_low 是用来唤醒 kswap 进程, 当我们某一个__alloc_pages 的时候发现 free page fram 小于 wmark_low 的时候, 就会唤醒这个kswapd 进程, 进行 page reclaim

wmark_high 是当 kswapd 这个进程进行 page reclaim 了以后, 什么时候停止的标志, 只有当 page frame 大于这个 pagh_high 的时候, kswapd 进程才会停止, 继续sleep

所以其实wmark_min, wmark_low, wmark_high 都是为了kernel 能够允许atomic 类型的申请操作成功服务的

注: 代码都是基于 linux2.6.32版本
