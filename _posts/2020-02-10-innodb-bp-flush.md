---
layout: post
title: InnoDB buffer pool flush 策略
summary: InnoDB buffer pool flush 策略
 
---
### InnoDB buffer pool flush 策略



**1. 刷脏整体策略**

 

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





**2. 具体刷脏方法**



**当free list 里面没有空闲page 的时候, 从LRU list 上面淘汰数据和从flush_list 上面刷脏, 这个策略是如何控制的呢? **

当需要获得一个free page 的时候, 是从LRU List 上去获得free page, 这里分两个阶段.

1. 找到一个page 可以被replace, 不需要执行page flush 操作, 因为page flush 操作的开销是比较大的
2. 在找不到一个可以被replace 的page以后, 那么需要找到一个可以被flush 的page



阶段1 找一个page 是否可以被 replace 在 buf_flush_ready_for_replace() 函数中, 主要

这里判断一个page 是否能够被replace, 也就是被释放的方法
如果这个page 是被写过, 那么oldest_modification == 0, 表示这个page已经被flush 到磁盘了.
bpage->buf_fix_count 表示的是记录这个bpage 被引用次数, 每次访问bpage,都对引用计数buf_fix_count + 1, 释放的时候 -1. 也就是这个bpage 没有其他人访问以后,才可以被replace
并且这个page 的io_fix 状态是 BUF_IO_NONE, 表示的是page 要从LRU list 中删除, 在page 用完以后, 都会设置成 BUF_IO_NON.如果是BUF_IO_READ, BUF_IO_WRITE 表示的是这个page 要从底下文件中读取或者写入, 肯定还在使用, 所以不能被replace

如果可以replace, 则执行 buf_LRU_free_page()



阶段2 判断page 是否可以被flush 在 buf_flush_ready_for_flush() 中, 主要

这个page 的oldest_modification != 0, 表示这个page 肯定已经被修改过了, 并且 io_fix == NONE, 不然这个page 可能正要被read/write

如果可以flush, 则执行 buf_flush_page()



为什么不直接从LRU list 上面拿出一个被modify 并且未执行flush 的page 执行flush 呢? 

因为在LRU list 上是按照access_time 排序的, 所有有可能page 被修改以后, 又有读, 因为这个page 被排在了很前面. 但是有可能这个page 很早被修改, 但是一直没有读, 反而排在了后面了, 因此从flush_list 里面找page 进行flush 是更靠谱的, 保证flush 的是最早修改过的page



那么什么时候会从flush_list 上面去执行flush page 操作呢?

在系统正常运行的过程中, 就不断会有page clean 线程对page 执行 flush 操作, 这样可以触发用户从LRU list 里面找page 的时候, 只需要replace 操作, 不需要flush single page 操作, 因为flush single page 操作如果触发, 对用户的请求性能影响很大.

所以在page cleaner thread 执行flush 操作以后, 在写IO 完成以后, 是否会把page 同时从flush_list, LRU list 同时删除, 还是只是将oldest_modification lsn 设置成0 就可以了?

这里分两种场景考虑:

1. 如果这个page 是从flush_list 上面写IO 完成, 那么就不需要从flush_list上面删除, 因为从flush list 上面删除要完成的操作是刷脏,既然只是为了刷脏, 那么就没必要让他从lru list 上面删除, 有可能这个page 被刷脏了, 还是一个热page 是需要访问的

2. 如果这个page 是从lru_list 上面写IO 完成, 那就需要从lru list 上面删除

   原因: 从lru_list 上面删除的page 肯定说明这个page 不是hot page 了,更大的原因可能是buffer pool 空间不够, 需要从lru list 上面淘汰一些page了, 既然这些page 是要从lru list 上面淘汰的, 那么肯定就需要从LRU list 上面移除
   

具体代码在buf_page_io_complete() 中
