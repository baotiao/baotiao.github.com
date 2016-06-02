---
layout: post
title: "swappiness 是否需要设置成0" 
description: "swappiness 是否需要设置成0 "
---

在我们的线上机器里面, 为了避免内存对性能的影响, 经常会将 swappiness 设置成0.  这个 swappiness 具体含义是什么? 这里就能够完全避免 swap 么? 这样做好么?

#### 结论:
 
1. swappiness 的具体含义是当物理内存不够的时候, 有两种选项

* 将一部分 anonymous page 置换到 swap区 
* 将 page cache 里面的数据刷回到磁盘, 或者直接清理掉

在这两种选项里面, 置换到swap 的权重, 但不是 swap 和 page cache 的比例, 比如 swappiness = 100 意思是swappiness 和 page cache 的比例是相同的. swappiness = 20 就是 swappiness 和 page cache 比例是1:9, 当然具体 kernle 还做的更细. 具体的计算公式就是, 

	anon_prio = sc->swappiness;
	file_prio = 200 - sc->swappiness;

2. 这样不能避免swap, 当内存不够的时候还是会 swap. 需要执行 swapoff -a 才是完全关闭 swap 的方法  
3. 不建议线上将 swappiness 设置成0, 因为kernel 对于该 reclaim 的页还是做了很多工作, 选择的是最不活跃的页, 而且 kernel 还会比较每一次 reclaim 的效果.

#### 具体分析

这个问题主要涉及到操作系统是如何做 page reclaim 的

首先我们知道操作系统的物理页主要被两部分使用, 一部分是实际使用的物理内存, 也叫anonymous page, 另一部分是 page cache. 同时我们还有 swap 区, 用来在内存不够的时候将 anonymous page 里面的页面置换到 swap 上.

那么在操作系统内存不够(下一篇文章介绍, 什么时候是内存不够的时候)的时候, 有两个选择. 一个是将 page cache里面的脏页刷回到磁盘, 将干净的页直接丢弃掉. 一个是将实际使用的物理内存里面的不常用的页刷回到 swap 区. 那么操作系统怎么做选择的?

这里最重要的需要判断是否需要swap 的在 get_scan_ratio 这个函数

```c
   这里可以看到如果把swap 给关闭了, 那么确实就不会进行swap 这个操作了
   所以这里想把 swap 完全关闭的方法应该是 swapoff -a  
	if (!sc->may_swap || (nr_swap_pages <= 0)) {
		noswap = 1;
		percent[0] = 0;
		percent[1] = 100;
	} else
		get_scan_ratio(zone, sc, percent);

```

那么在这个get_scan_radio 里面, 就是计算这次 swap 和 page cache 的比例的时候了

```c

  /*
   * 首先获得anon 页的个数 和 page cache页的个数
   */
	anon  = zone_nr_lru_pages(zone, sc, LRU_ACTIVE_ANON) +
		zone_nr_lru_pages(zone, sc, LRU_INACTIVE_ANON);
	file  = zone_nr_lru_pages(zone, sc, LRU_ACTIVE_FILE) +
		zone_nr_lru_pages(zone, sc, LRU_INACTIVE_FILE);


	if (scanning_global_lru(sc)) {
		free  = zone_page_state(zone, NR_FREE_PAGES);
		/* If we have very few page cache pages,
		   force-scan anon pages. */
    /*
     * 这里就是如果我们的page cache page 和我们的 free
     * page数小于high_wmark_pages, 也就是3/2 的min_free_pages 的时候, 那么这个时候即使swapiness是0
     * 也是强制的让这次都走这个swapiness, 也就是swapiness 被设置成100
     *
     */
		if (unlikely(file + free <= high_wmark_pages(zone))) {
			percent[0] = 100;
			percent[1] = 0;
			return;
		}
	}
   .....

	/*
	 * With swappiness at 100, anonymous and file have the same priority.
	 * This scanning priority is essentially the inverse of IO cost.
   * 这里可以看到 swappiness 设成100的时候, 意思是从匿名页释放 page 和从 page
   * cache 里面释放 page 是相同的比例 
	 */
	anon_prio = sc->swappiness;
	file_prio = 200 - sc->swappiness;

	/*
   * 这里从获得了 anon 和 file 的比例以后继续的优化, 根据的是历史的 scanned 和
   * rotated page 的比例, 来计算这些 page 是否有效
   *
   * 这里比如我再 anon 区域扫描了100个 page, 然后 rotated 就是从 swap
   * 里面又置换到内存里面50 个 page, 另外我在 page cache 区域里面扫描了100个 page,
   * 又置换了10个 page, 这说明在 anon 区域里面的内容是比较经常访问的,
   * 换出去了以后又要换回内存, 所以应该尽量不要让 anno 区域里面的 page 换出 
	 */

  /*
   *   80 * 100 / 50 = 160
   *   120 * 100 / 10 = 1200
   *   percent[0] = 100 * 160 / 1360 = 11
   *   percent[1] = 89
   * 
   *   如果没有经过这一步, percent 应该是
   *   percent[0] = 80 / (80 + 120)  * 100 = 40
   *   percent[1] = 60
   * 
   *   这样可以看出这样就再一次减少了从 anon 区域 reclaim 的比例, 因为 anan里面的 page 是更经常访问的 
   */
	ap = (anon_prio + 1) * (reclaim_stat->recent_scanned[0] + 1);
	ap /= reclaim_stat->recent_rotated[0] + 1;

	fp = (file_prio + 1) * (reclaim_stat->recent_scanned[1] + 1);
	fp /= reclaim_stat->recent_rotated[1] + 1;

	/* Normalize to percentages */
	percent[0] = 100 * ap / (ap + fp + 1);
	percent[1] = 100 - percent[0];
}

```

