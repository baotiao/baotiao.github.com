---
layout: post
title: Linux physical page note
summary: Linux physical page FAQ

---

### linux page frame management

物理内存的管理最基本的概念就是 page frame, zone.

然后物理内存的地址也是从0 开始, 其中其实的一部分内存会有特殊的用途, 比如第一个page frame 就是用来给BIOS 系统用来记录系统的硬件配置的的, 比如640KB 到 1MB 的内存在兼容IBM的机器里面都是没用的.

那么这些内存信息是怎么获得的呢? 是在boot 阶段通过machine_specific_memory_setup() -> setup_memory() 函数来获得的.  在执行setup_memory() 完成以后, 会同时执行去获得一些参数的设定, 为的是更好的管理这个物理内存

![Imgur](http://i.imgur.com/do8QNwb.jpg)

下面是内存从0~3M 的物理内存的布局, 可以看出

_text ~ _etext 是内核的代码段, 内核的data 区分成了两个部分, 一部分是initialized, 一部分是 uninitialized. initialized 在 _etext ~ _edata 之前, uninitialized 在 _edata ~ _end 区间

![Imgur](http://i.imgur.com/7MbmEXF.jpg)



**为什么上下文切换的代价比价高?**

因为每一个进程都有自己的page tables, 然后TLB 保存的是linear address => physical address 的映射cache,  TLB 就是一层缓存, 一旦反思context switch 以后, 缓存里面的内容就清空了, 也就无法使用了, 因此上下文切换以后又要重新填充缓存里面的内容, 因此切换成本是比较高的

**在linux 里面如何管理这些page frames?**

**这个page frame 结构体用 mmzone.h:struct page 来维护的, 然后所有的page 是通过全局变量 mem_map 来把所有的page frame 连在一起的, 这个 page 结构体里面的flag 表示这个page 目前的状态, 是否是dirty, 是否可以reclaim 等等, 应该是最重要的结构体了**

这些page frame 都存在zone 里面的zone_mem_map 里面了

mmzone.h:extern struct page *mem_map;

![Imgur](http://i.imgur.com/2l2SuxJ.jpg)

![Imgur](http://i.imgur.com/lrzFJt9.jpg)

![Imgur](http://i.imgur.com/EFucoxv.jpg)

在linux 里面是根据 zone 来进行page frame 的管理的,  在每一个zone 内部都通过buddy system algorithm 来进行页的管理, 那么具体的每一个页存在哪里呢? 

可以从申请物理内存的这几个申请函数来看, 主要由这几个方法, alloc_pages, alloc_page, __get_free_pages, \_\_get_free_page

这里申请physical address 就设计到了 page reclaim, water mark 等等这些东西了, 主要通过 __alloc_pages_nodemask 来申请, 具体的每一个page frame 是存在两个

所有的pages 是根据zone来管理, 那么对应的page 在mmzone.h:struct zone:free_area[MAX_ORDER] 里面, 可以看到, 根据buddy system algorithm 每一个层级大小的page 都有一个list, 然后有请求的时候就去对应大小的list 里面去申请(这里free_area 结构同时记录了当前这个list 有多少的free number). 然后在kernel 做page reclaim 的时候, 每一个page 又被两个list 连在一起, 一个list 是 free, 一个 list 是used, 所以page frame 这个struct 上才有一堆

真正的alloc_page, \_\_get_free_pages 等函数到最后都是调用\_\_rmqueue() 从对应的zone 里面的free_area 里面去获得对应大小的page, 那么__rmqueue() 是如何做的呢?

这里我们知道, 



> 最近看管理物理内存这块, 有一个困惑 
>
> 我们知道kernel 申请物理内存的时候是在不同的zone 上面去申请, zone 里面有 zone_mem_map 连接着所有的page frame 信息, 然后从这个zone 里面的free_area  根据 Buddy algorithm 去获得对应大小的页.  我的问题是 那这些zone 的信息是存在哪, 因为zone 这个结构体是提供后续kernel 有内存申请操作的时候, 由zone 提供的,  所以我想zone 应该是在bootloader 阶段就初始化好的. 然后这个zone 对应的结构的应该是固定在物理内存的某一个位置, 是这样理解么?
>
> 所以就是内核在初始化的时候会初始化pglist_data 这个变量, 这个变量存在就是所有zone 的list. 
>
> static int __build_all_zonelists(void *data)
>
> 这个函数里面就是初始化这个zonelists, 
>
> ```c
> for_each_online_node(nid) {
> 	pg_data_t *pgdat = NODE_DATA(nid);
>   
>   
> extern struct pglist_data contig_page_data;
> #define NODE_DATA(nid)		(&contig_page_data)
>
> struct pglist_data __refdata contig_page_data = { .bdata = &bootmem_node_data[0] };
>
> bootmem_data_t bootmem_node_data[MAX_NUMNODES] __initdata;
>   
> // 这里有__initdata 标识的就是在boot 阶段初始化的data, 所以是保存在内核代码的_data 区域也就是静态全局变量区
> // 具体可以看 include/linux/init.h
> ```

![Imgur](http://i.imgur.com/tdRlX2S.jpg)

* **内核申请的物理内存是否和用户空间申请的物理内存在不同的位置?**

在kernel 内部申请的physical address 和在用户空间申请 physical address 是走一样的流程么? 他们保存的地址是一样的么. 其实用户空间申请的malloc 最后也是调用brk, brk 底下也是调用__alloc_pages_nodemask() 来申请了

> 嗯嗯  跟你确认一下 其实对于物理内存来说, 用户空间通过malloc 到 brk 最后什么的物理内存 和 kernel 空间申请的物理内存其实是一样的对吧, brk 最后肯定也有调用 page_alloc() 函数, 唯一不一样的时候 gfp_mask 不一样而已吧
>
> 
>
> 那有一个问题  所谓的内核保护只是虚拟内存的保护, 实际物理内存也是没做什么保护的, 因为其实在物理内存上 内核空间和用户空间是并没有区分的, 还是存在用户空间映射的物理内存搞错了把内核空间的物理内存给写坏了的情况.  当然这里只是极端情况, 因为虚拟地址空间到物理地址空间的映射是内核自己控制的, 用户控制不了的, 所以只要这个映射方法没错, 还是可以起到保护作用的



> 因为所有的 进程都共享 内核地址空间, 比如内核里面保存着所有的进程列表, 这些列表也是在zone 初始化完成以后, 从zone 里面的free_area 里面申请的内存吧. 所以这个zone 的初始化一定是最开始做的

其实主要的区别就是通过这个gfp_mask 来区分的,  比如有GFP_USER, GFP_KERNEL, 所以走的是一样的流程, 只是这个gfp_mask 不一样而已.

![Imgur](http://i.imgur.com/In0neK1.jpg)

![Imgur](http://i.imgur.com/HACFIWZ.jpg)

**kernel 的page table是保存在哪里的, 是如何维护的?**

那么问题来了, 这个kernel page table 到底有什么用?

理论上因为所有进程的内核空间都一样, 那么就不需要kernel page table, 因为page table 的存在于用户空间的目的就是为了节省内存, 用比较小的内存来记录 linear address 到 physical address 的映射. 而所有的kernel 空间都一样的话, 就不需要这个了. 因为只需要一份就够了. 而不是用户空间的page table 一样, 每一个进程都需要有一份

但是这里kernel 还是有这样的需求, 就是在物理内存上不是连续的空间, 但是kernel 还是需要在虚拟地址空间上提供一个连续的地址.  有了kernel page table 的存在, kernel page table 就可以做这个事情, 有kernel page table 提供映射, 在linear address 上是连续的, 而底下的physical address 是不连续的

kernel page table 的地址是这个

```c
/*
 * 这里设置的是初始化时候的mm_struct 结构
 */
struct mm_struct init_mm = {
	.mm_rb		= RB_ROOT,
	.pgd		= swapper_pg_dir,
	.mm_users	= ATOMIC_INIT(2),
	.mm_count	= ATOMIC_INIT(1),
	.mmap_sem	= __RWSEM_INITIALIZER(init_mm.mmap_sem),
	.page_table_lock =  __SPIN_LOCK_UNLOCKED(init_mm.page_table_lock),
	.mmlist		= LIST_HEAD_INIT(init_mm.mmlist),
	.cpu_vm_mask	= CPU_MASK_ALL,
};

```

后续实现vmalloc 的时候, 当我们需要修改进程的内核地址空间的时候, 都是去这个init_mm 上面去修改, 因此kernel page table 是存在这个init_mm 结构上的

```c
asm("movl %%cr3,%0":"=r" (pgd_paddr));
pgd = pgd_index(address) + (pgd_t *) __va(pgd_paddr); 
pgd_k = init_mm.pgd + pgd_index(address); // 这里init_mm.pgd + 当前这个地址的偏移量就是kernel 这个address 的偏移量地址
```



那么修改kernel page table 是什么时候呢?

任何process 修改kernel page table 的时候都是修改master kernel page table, 然后在进程访问自己的page table的kernel 空间的时候, 触发缺页中断来处理. 在缺页中断的处理过程中, 上来会首先判断这个缺页中断是来自内核空间还是用户空间, 如果来自内核空间, 那么回去从master kernel page table 里面把这个内容拷贝过来

![Imgur](http://i.imgur.com/3ssZ2pi.jpg)



**是否所有的进程都共享内核空间的地址?**

是, 有一个master kernel page table, 所有的改动都会改动到这个master kernel page table, 然后会同步到所有的其他进程上面. 但是每一个进程的pgd 都是自己4G 大小的空间的

Whereas the lower part is modified during a context switch (between two user processes), the kernel part of virtual address space always remains the same. 

The kernel uses the auxiliary function vmalloc_fault to synchronize the page tables. I won’t show the code in detail because all it does is copy the relevant entry from the page table of init — this is the kernel master table on IA-32 systems — into the current page table. If no matching entry is found there, the kernel invokes fixup_exception in a final attempt to recover the fault; I discuss this shortly.

说明这个master kernel page table 是保存在 init 进程的page table 里面的. 然后如果init 进程的master kernel page table 也没有这个从linear address 到 physical address 的映射, 那么就会调用fixup_exception() 函数来修补. 这个init 进程的mm_struct 是这样的

```c
/*
 * 这里设置的是初始化时候的mm_struct 结构
 * 也是init 进程的 mm_struct 结构
 */
struct mm_struct init_mm = {
	.mm_rb		= RB_ROOT,
	.pgd		= swapper_pg_dir,
	.mm_users	= ATOMIC_INIT(2),
	.mm_count	= ATOMIC_INIT(1),
	.mmap_sem	= __RWSEM_INITIALIZER(init_mm.mmap_sem),
	.page_table_lock =  __SPIN_LOCK_UNLOCKED(init_mm.page_table_lock),
	.mmlist		= LIST_HEAD_INIT(init_mm.mmlist),
	.cpu_vm_mask	= CPU_MASK_ALL,
};

```

**kernel 是怎么分配物理内存的? 就是哪一部分物理内存分别用作什么?**

![Imgur](http://i.imgur.com/Q1fTnHL.jpg)

这里看到内核的代码是从第一个1M以后开始放的, 然后内核的代码的大小差不多只有2.5MB((00381ecc -00100000)/1024/1024), 然后kernel 的data 段差不多有0.9M


**为什么操作系统1G的linear address 要分成这么几个部分?**

我的理解是比如前面的PAGE_OFFSET->high_memory  这部分的直接映射是为了physical address -> linear address 非常的快, 不需要经过MMU, 必须要有一个page table 来做这个映射的过程.

其实下面这个图获得不精确, 前面的PAGE_OFFSET ~ high_memory 其实占用了896M的内容, 从high_memory ~ 4G值占用了 128M 的内容

![Imgur](http://i.imgur.com/tQMWbTV.jpg)



**为什么内核的linear address 需要 high_mem 这样的地址空间**

这里这个概念需要理解一下 PAGE_OFFSET ~ high_memory 映射到物理内存的ZONE_HIGHMEM, 那么这里的问题就变成为什么需要ZONE_HIGHMEM?

那我们就知道物理内存里面包含ZONE_DMA, ZONE_NORMAL, ZONE_HIGHMEM 这三个部分. (ZONE_NORMAL 也叫做low memory, ZONE_HIGHMEM 也叫做high memory)其中ZONE_NORMAL是映射到kernel linear address 里面的896M的内容, 那么物理内存里面超过896M以后的怎么办呢? 这部分的内容就主要是用户空间使用的内容了. 但是有一个问题是比如有2G的内存, 内核空间其实没有使用满896M的内容, 用户空间一直在使用内存, 这个时候用户空间的进程可以去使用这个896M里面的内容么? 应该是可以吧, 用户空间申请内存的时候是优先申请ZONE_HIGH, 如果没有其实也还是会向ZONE_HIGH 里面申请内存的

其实这个映射896M的物理内存也不是从0开始的, 其实是从16M的地方开始的, 前面有一些内存用户kernel 代码段,  BIOS配置等等

"High memory" and "low memory" do not apply to the virtual address space of processes, it's about physical memory instead.

Every article explains only the situation, when you've installed 4
 GB of memory and the kernel maps the 1 GB into kernel space and user processes uses the remaining amount of RAM.

**为什么我们需要direct mapping, 并且这个896M的空间会不是一个浪费**

有了direct mapping 以后, 那是不是一种浪费, 比如在1G的内核空间里面, 有896M 虚拟内存空间被用作其他的用途了

或者这么说这个direct mapping 跟kernel page table 的关系, 因为我们知道page table 就是用来确定linear address 和 physical address的关系的, 有了这个东西以后, 还需要kernel page table 了么?

这里kernel page table 是必须存在的, 因为开启了保护模式以后, CPU发送出来的地址都是linear address, 需要通过MMU 进行linear address 到 physical address 的转换, 而这个转换又需要page table 的支持. 那为什么还需要这个direct mapping呢?

其实direct mapping 和 kernel page table 都是提供了一种linear address 到 physical address 的一种映射. 用户空间只有page table 提供linear address 到 physical address 的映射, 内核空间增加了direct mapping 完全是为了方便, 因为直接用 linear address - 0xc0000000 就可以获得对应的physical address, 直接 + 0xc0000000 就可以获得对应的linear address. 不需要去查找page table, 而内核空间为了获得linear address 到 physical address 是需要去查这个page table 的. 但是有了这个方便也同样带来问题, 内核里面存在大量的这个 trade-off. 因为有了这个映射关系以后, kernel page table 的内存其实是提前确认下来的. 如果用户进程先使用了 这个物理地址, 当时这个kernel linear address 就不能用了, 那么就浪费了这个linear address.但是这个时候说明这个内存已经吃紧了, 因为正常用户优先从ZONE_HIGHMEM 去申请物理内存的. 同时, 如果没有这个映射关系 就不存在这个问题了, 其实这里也就是拿这个获得linear address 到 physical address 的方便和当内存不够用的时候, 浪费linear address 之间的一个trade off. 所以其实一定程度上也减少了这个kernel 使用Linea address 的自由

其实这里的kernel page table 主要是为了处理vmalloc 这样的请求, 也就是在内核地址空间上是非连续的

**为什么内核需要Persistent kernel mappings**

**为什么内核需要Fix-mapped linear address**

**为什么如果page frame 没有直接映射到kernel linear address 就无法使用呢?**

因为我们不管到哪一步返回物理地址的address 的时候也是一个0x... 这样的地址, 但是其实这样的地址内存是怎么识别的呢?

因为内核开启了保护模式以后, CPU 发送出来的地址都是虚拟地址, 需要通过MMU 来进行地址转换

但是page frame 映射到linear address 只是为了更方便的去请求这个physical address

**page frame 是怎么和对应的物理内存建立关系的呢**

这里其实搞混了, 应该是struct page 如何和page frame(page frame 就是物理内存). 所以不要把struct page 和 page frame 搞混.

其实所谓的alloc_pages, __get_free_page 等等这些函数最后所获得的东西都是这个struct page, 包括Buddy system 等等所管理的也是这个struct page, 每一个物理的 page 都有一个这个struct page进行管理着. 然后后续真的访问的时候是通过这个page fault 来进行真的访问物理内存, 缺页中断的时候是 Linear address 去page table 里面去查找有没有对应的 pte, 如果没有就去申请



**virtual address 真正和 physical address 建立关系的时候**

The association between virtual and physical memory is not established until the data of an area are actually needed. If a process accesses a part of virtual address space not yet associated with a page in memory, the processor automatically raises a *page fault* that must be handled by the kernel.

这里建立联系指的是通过\__get_free_page(), page_allocs() 申请函数么? 应该是, 所以一般这个__get_free_pages(), page_alloc() 等等一般都是在page fault 的时候被调用的, 因为page fault 的时候才是真正的分配物理内存的时候, 然后这个pte 里面一般都是直接存的是physical 的地址, 而不是page frame 的地址, 因此经常有page frame 与 physical address 的转换过程.

**当缺页中断的时候, 返回回来的是physical address 么**

确认一下缺页中断要做的事情是更新page table 里面的内容, 那么page table 里面具体的内容是什么呢? 存的应该是物理内存的地址吧, 嗯应该是 physical address, 然后如果想知道这个physical address 的情况, 可以通过查找对应struct page 来知道

确认, 返回回来的是 physical address



**在内核里面struct page 是如何和physical page(page frame) 管理起来的**

struct page 里面并没有address 说我这个struct page 对饮的physical page 是在哪里, 而是因为mem_map(struct page 构成的数组) 数组和物理内存是一一对应的, 我们知道mem_map 地址 对应的物理内存的其实地址, 那么每一个page 在mem_map 对应的偏移量就是对应的物理页对应物理内存的偏移量了, 因此通过简单的加减就可以得到了. virt_to_page(addr) 做的就是这个事情, 通过pfn_to_virt(pfn) 就是从physical page 到 struct page

因为每一个物理的page frame 都有一个struct page 关联, 然后所有的struct page 组成一个mem_map 这个数组,  然后可以通过virt_to_page(address), pfn_to_virt(pfn) 来进行转换, 也就是说我们知道了struct page 是可以直接找到具体的物理内存的地址的.

上面这段话哪里不对? 不对的地方在于这里只是struct page 和 page frame 的映射, 并没有linear address 和 physical address 的映射. 这里只是解决了page frame 和 struct page 的相互关系. 所以这里要记住有两个mapping关系 一个是struct page 和 page frame 的映射关系, 一个是linear address 和physical address的映射(linear address 和physical 通过page table 映射)

**为什么内核有了kernel page table还需要有direct mapping**

我们知道kernel 里面有896M 的direct mapping 部分对吧, 那既然kernel 已经有了direct mapping 那么为什么还需要kernel page table(我们知道page table 存在的意义也是为了从linear address 映射到 physical address).

因为一旦开了分页，CPU就无法直接访问物理地址了，必须要走MMU.

使用MMU, 而MMU 是根据页表进行寻址的, 所以kernel page table 存在的意义就是提供给 MMU寻址方式

![Imgur](http://i.imgur.com/6VDAfAA.jpg)

上面这张图可以看出cpu 访问内存的方式都是通过virtual address 的方式, 然后MMU(Address translation) 通过page table 去获得对应的physical address.

Dedicated hardware on the CPU chip called the memory management unit (MMU) translates virtual addresses on the fly, using a look-up table stored in main memory whose contents are managed by the operating system.

这里可以看出MMU 是一个专门的硬件, 然后这个page table 是存在内存里面的

有一个要注意的是用户空间的进程访问内存都是通过page table 来进行访问的, 并不需要关注NODE_NORMAL, NODE_HIGH. 只是在申请内存的时候优先从某一个区域申请罢了

所以可以说direct mapping 只是为了内核获得某一个linear address 对应physical address 比较方便的一个方法



**这个mem_map 一般保存在哪里**

这个mem_map 在有了zone 以后是每一个zone 有自己的mem_map. 然后这个mem_map 一般保存在ZONE_NORMAL 的起始位置, 也就是位置一定是定好的

and all the structs are kept in a global mem map array, which is usually stored at the beginning of ZONE NORMAL or just after the area reserved for the loaded kernel image in low memory machines. 

the global mem map is treated as a virtual array starting at PAGE OFFSET.

也就是说mem_map 是从PAGE_OFFSET 这个位置开始的



**关于page table 分配内存的时机**

由于不管是kernel 还是用户空间的page table, 由于这个page table 只是负责linear address 到physical address. 所以也只是在需要的时候实时申请就可以了
