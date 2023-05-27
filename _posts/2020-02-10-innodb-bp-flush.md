---
layout: post
title: InnoDB adaptive IO flushing
summary: InnoDB adaptive IO flushing
 
---


首先从整体上来说, 刷脏的coordinator_thread 会判断进入哪一种场景刷脏

在 buf_flush_page_coordinator_thread() 函数里面 刷脏主要有3个场景

1. 如果 buf_flush_sync_lsn  > 0, 则因为redo log free space 不够了, 那么我们需要进入同步刷脏阶段了. 所以这个时候pc_request(ULINT_MAX, lsn_limit). 第一个参数直接是ULINT_MAX, 那么 slot->n_pages_requested = ULINT_MAX; 这个时候每一个刷脏线程都尽可能的全部进行刷脏, 所以这个时候是可能超过io_capacity_max 的限制的, 因为并不去检查一个buffer pool 能刷多少脏页了
2. 最常见逻辑 srv_check_activity(last_activity),  也就是系统有正常活动, 这个时候会通过 page_cleaner_flush_pages_recommendation() 函数去合理的判断应该刷多少个page, 既不抖动, 也能够满足刷脏需求, 但是不会超过io_capacity 的限制
3. ret_sleep == OS_SYNC_TIME_EXCEEDED  也就是如果系统没有活动, 那么就把srv_io_capacity 尽可能的用上, 100% 的全力去刷脏, 但是不会超过io_capacity_max 的限制.



所以3个场景的刷脏速率依次是

2<3<1

限制的刷脏速率

io_capacity < io_capacity_max < 无限制



buf_flush_sync_lsn 这个是在什么时候设定的? 

是在做checkpoint 的时候,  log_checkpointer 打checkpoint 之前, 都会检查一下, 是否需要做同步刷脏操作 => log_consider_sync_flush



在第二种就是我们场景的处于adaptive flushing 中

这里内存占用百分比是多少的时候触发刷脏? 以及内存占用百分比是多少的时候触发更激进的刷脏策略?

主要在 coordinator_thread 里面的 page_cleaner_flush_pages_recommendation() 函数决定这次要flush 多少的page



pct_for_dirty = af_get_pct_for_dirty() 根据dirty page 的多少来决定是否要进行刷脏

buf_get_modified_ratio_pct() 计算得出脏页比.

如何计算脏页的百分比?

**所以lru_list + free_list 代表了整个buffer pool page 的数量**

  ratio = static_cast<double>(100 * flush_list_len) / (1 + lru_len + free_len);

这里计算脏页的百分比就是 flush_list / (lru_list + free_list)

因为所有在flush_list 上面的page 都会在free_list 上, flush_list 上面的page 是 free_list 的一个子集而已, 所以可以这样计算



pct_for_lsn = af_get_pct_for_lsn() 根据redo log 产生的多少来决定是否要进行刷脏.

因为在upstream 里面, redo log 是循环使用的, 所以redo log 的大小也是有限的, 因此需要检查现在还有多少可以使用的redo log 空间, 如果太少了, 就需要进行刷脏了.

所以当没有开启adaptive flushing 的时候, 只有超过了 log.max_modified_age_async = 7/8 * (free redo log) 的时候, 会根据redo log 是否有空闲空间, 开始进行刷脏

当开启了 adaptive flushing, 如果超过了 srv_adaptive_flushing_lwm(默认10%) 的大小, 就开始进行刷脏了.  也就是会在达到redo log 没有空闲空间之前, 就触发了刷脏的流程



page_cleaner->slot 和 page cleaner thread 并不会相等

而且page cleaner 去page_cleaner->slot 里面去领任务, 比如我们有8个buffer pool 那么这个page_cleaner->slot = 8.  我们配置了innodb_page_cleaner = 4, 那么一个thread 就需要flush 2 个buffer pool.



在POLARDB 里面, 因为没有的Redo log 的限制, 但是还是有checkpoint 的限制, 因此增加了 polar_log_max_checkpoint_files 这个参数



```c++
n_pages = (PCT_IO(pct_total) + avg_page_rate + pages_for_lsn) / 3;

printf("baotiao n_pages %d %d %d %d %d\n", PCT_IO(pct_total), avg_page_rate,  pages_for_lsn, srv_io_capacity, srv_max_io_capacity);
	if (n_pages > srv_max_io_capacity) {
    n_pages = srv_max_io_capacity;
}  
// 打印出来是 baotiao n_pages 291 189 400 100 200
// 所以可以看到 pct_total 是可以超过100 的, 并且最后的这个n_pages 是经常会超过 srv_io_capacity 的, 只要avg_page_rate 足够快, 就很容易超过srv_io_capacity 限制.
// 但是最后这里会有判断如果n_pages > srv_max_io_capacity, 会把n_pages 设置成 srv_max_io_capacity
```



所谓的adaptive flushing 指的是什么?

所谓的 adaptive flushing 值得就是在脏页还没有达到一定需要刷脏的时候, 就提前开始刷脏, 避免等到内存不够的时候大量刷脏, 影响性能

