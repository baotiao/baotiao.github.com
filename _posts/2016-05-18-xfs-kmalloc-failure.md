---
layout: post
title: "xfs kmalloc failure problem"
description: "xfs kmalloc failure problem"
category: kernel, memory, xfs
tags: [kernel, memory, xfs]
---

记录一次线上实体机的xfs kmem_alloc 操作一直失败排查

Hi all:


### 问题现象

线上有些实体机dmesg出现xfs 报错

```
Apr 29 21:54:31 w-openstack86 kernel: XFS: possible memory allocation deadlock in kmem_alloc (mode:0x250)
Apr 29 21:54:33 w-openstack86 kernel: XFS: possible memory allocation deadlock in kmem_alloc (mode:0x250)
Apr 29 21:54:34 w-openstack86 kernel: INFO: task qemu-system-x86:6902 blocked for more than 120 seconds.
Apr 29 21:54:34 w-openstack86 kernel: "echo 0 > /proc/sys/kernel/hung_task_timeout_secs" disables this message.
Apr 29 21:54:34 w-openstack86 kernel: qemu-system-x86 D ffff88105065e800     0  6902      1 0x00000080
Apr 29 21:54:34 w-openstack86 kernel: ffff880155c63778 0000000000000086 ffff88099719d080 ffff880155c63fd8
Apr 29 21:54:34 w-openstack86 kernel: ffff880155c63fd8 ffff880155c63fd8 ffff88099719d080 ffff88099719d080
Apr 29 21:54:34 w-openstack86 kernel: ffff88081018de10 ffffffffffffffff ffff88081018de18 ffff88105065e800
Apr 29 21:54:34 w-openstack86 kernel: Call Trace:
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff8163a879>] schedule+0x29/0x70
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff8163c235>] rwsem_down_read_failed+0xf5/0x170
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa0256a30>] ? xfs_ilock_data_map_shared+0x30/0x40 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff81301764>] call_rwsem_down_read_failed+0x14/0x30
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff81639a90>] ? down_read+0x20/0x30
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa02569bc>] xfs_ilock+0xdc/0x120 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa0256a30>] xfs_ilock_data_map_shared+0x30/0x40 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa023f4f4>] __xfs_get_blocks+0x94/0x4b0 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff810654f2>] ? get_user_pages_fast+0x122/0x1a0
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa023f944>] xfs_get_blocks_direct+0x14/0x20 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff8121d704>] do_blockdev_direct_IO+0x13f4/0x2620
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa023f930>] ? xfs_get_blocks+0x20/0x20 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff8121e985>] __blockdev_direct_IO+0x55/0x60
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa023f930>] ? xfs_get_blocks+0x20/0x20 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa023f210>] ? xfs_finish_ioend_sync+0x30/0x30 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa023e5ca>] xfs_vm_direct_IO+0xda/0x180 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa023f930>] ? xfs_get_blocks+0x20/0x20 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa023f210>] ? xfs_finish_ioend_sync+0x30/0x30 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff8116afed>] generic_file_direct_write+0xcd/0x190
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa027f1fc>] xfs_file_dio_aio_write+0x1f3/0x232 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa024bd2d>] xfs_file_aio_write+0x13d/0x150 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff811ddde9>] do_sync_readv_writev+0x79/0xd0
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff811df3be>] do_readv_writev+0xce/0x260
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffffa024bbf0>] ? xfs_file_buffered_aio_write+0x260/0x260 [xfs]
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff811ddca0>] ? do_sync_read+0xd0/0xd0
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff810e506e>] ? do_futex+0xfe/0x5b0
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff811df5e5>] vfs_writev+0x35/0x60
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff811df9e2>] SyS_pwritev+0xc2/0xf0
Apr 29 21:54:34 w-openstack86 kernel: [<ffffffff816458c9>] system_call_fastpath+0x16/0x1b
```

进而导致虚拟机因为文件系统的内存申请操作出现了问题, 导致这个虚拟机挂掉

解决办法:

sync && echo 3 > /proc/sys/vm/drop_caches

将page cache 里面的内容清空, 那么就不再报错. 但是为什么简单的清空page cache 就可以解决这个问题, 如果系统被page cache 占用着难道不应该申请内存操作的时候将一部分page cache 里面的内存刷回, 然后让出部分空闲空间么?



### 问题分析

看了一下代码, 出现这个报错在xfs module里面, 这个错误是在kmalloc 失败以后就会报出来, 并且会重试100次, 如果100 次以后还是失败, 就直接return error. 那么为什么kmalloc 会失败呢?

```
void *
kmem_alloc(size_t size, xfs_km_flags_t flags)
{
  int retries = 0;
  gfp_t lflags = kmem_flags_convert(flags);
  void  *ptr;

  do {
    ptr = kmalloc(size, lflags);
    if (ptr || (flags & (KM_MAYFAIL|KM_NOSLEEP)))
      return ptr;
    if (!(++retries % 100))
      xfs_err(NULL,
    "possible memory allocation deadlock in %s (mode:0x%x)",
          __func__, lflags);
    congestion_wait(BLK_RW_ASYNC, HZ/50);
  } while (1);
}
```

这里首先我们必须知道如果一个操作kmalloc() 是向slab allocator 申请具体的小块的内存, 而slab allocator 是想buddy system 通过`__alloc_pages()` 去申请连续的内存. 那么肯定就是在`__alloc_pages()` 申请内存的时候失败了, 那为什么进行`__alloc_pages()` 操作的时候会失败呢? 即使实际物理内存里面还有page cache页以及swap 空间还没占满

从出现问题的机器上面我们可以看到, 机器的状态大概是这个样子

```
[chenzongzhi@w-openstack86 ~]$ free -m
              total        used        free      shared  buff/cache   available
Mem:          64272       26298        4379         129       33595       37051
Swap:         32255           0       32255
```

这里我们同时看一下机器的内存碎片状态

```
这里并不是现场的机器, 只是另一台线上内存用的差不多的机器 
[chenzongzhi@w-openstack81 ~]$ cat /proc/buddyinfo
Node 0, zone      DMA      0      0      0      1      2      1      1      0      1      1      3
Node 0, zone    DMA32   2983   2230   1037    290    121     63     47     61     16      0      0
Node 0, zone   Normal  13707   1126    285    268    291    160     64     21     11      0      0
Node 1, zone   Normal  10678   5041   1167    705    316    158     61     22      0      0      0
```

我们可以看到这里比较大块的连续的page 是基本没有的. 因为在xfs 的申请内存操作里面我们看到有这种连续的大块的内存申请的操作的请求,  比如:

```
6000:   map = kmem_alloc(subnex * sizeof(*map), KM_MAYFAIL | KM_NOFS);
```

因此比较大的可能是线上虽然有少量的空闲内存, 但是这些内存非常的碎片, 因此只要有一个稍微大的的连续内存的请求都无法满足. 但是为什么不使用page cache呢?

到这里. 我们可以看到整个系统的内存基本全部被使用, 有少量的空闲. 但是这里面包含了大量的page cache. 理论上page cache 里面只会包含几M的需要刷回磁盘的内容, 大量的page cache 只是为了加快读, 里面的内容应该可以随时清空掉. 所以在kmalloc申请内存的时候应该能够把page cache 里面的内容清空, 然后给kernel 留出空闲的连续的大内存空间才是. 那么为什么这次申请内存操作`__alloc_pages()`的时候不把page cache 里面的内容清空一部分, 然后给这次`__alloc_pages()` 预留出来空间呢?

这里xfs 的申请内存操作因为是文件系统的申请内存操作, 所以一般带上GFP_NOFS 这个参数, 这个参数的意思是

GFP_NOFS

These flags function like GFP_KERNEL, but they add restrictions on what the kernel can do to satisfy the request. A GFP_NOFS allocation is not allowed to perform any filesystem calls, while GFP_NOIO disallows the initiation of any I/O at all. They are used primarily in the filesystem and virtual memory code where an allocation may be allowed to sleep, but recursive filesystem calls would be a bad idea.

也就是说如果带上这个GFP_NOFS的flag, 那么本次 `__alloc_pages()` 是不允许有任何的filesystem calls的操作的, 那么如果物理内存不够了, 也就是不能触发这个page_reclaim 的操作. 具体的实现是在page reclaim 的 do_try_to_free_pages 里面shrink_page_list 的时候会判断这次的scan_control 里面有没有这个 __GFP_FS flag, 如果是没有GFP_FS flag, 就不会就行这个page_reclaim

为什么要这样, 因为如果在文件系统申请内存的时候, 你又触发了一次文件系统相关的操作, 比如把page cache 里面的内容刷会到文件, 那么刷会到文件这个操作必然又会有内存申请相关的操作, 这样就进入是循环了. kernel 为了避免这样的死循环尝试, 所以在文件系统相关的内存申请就不允许有任何filesystem calls. 也就是这个原因导致kernel 本身kmalloc 一直失败

那么接下来 sync && echo 3 > /proc/sys/vm/drop_caches 操作为什么能够成功, 并且后续就不会有报错了呢?

因为drop_caches 这个操作属于外部操作, 不属于文件系统本身的操作, 因此没有GFP_NOFS这个flag, 因此可以很轻松的就把page cache 里面的内容清空, 让Kernel 有足够多的连续的大内存. 线上自然就不报错了

