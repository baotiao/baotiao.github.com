---
layout: post
title: [Worklog] InnoDB Faster truncate/drop table space
summary: InnoDB Faster truncate/drop table space
---

**问题**

在InnoDB 现有的版本里面, 如果一个table space 被truncated 或者 drop 的时候, 比如有一个连接创建了临时表, 连接断开以后, 对应的临时表都需要进行drop 操作.

InnoDB 是需要将该tablespace 对应的所有的page 从LRU/FLUSH list 中删除, 如果没有这个操作, 新的table 的table spaceid 如果重复的话, 那么就可能访问到脏数据.

为了将这些page 删除, 那么就需要全部遍历LRU/FLUSH list, 当bp 特别大的时候, 这样遍历的开销是很大的, 并且无论这个要删除的table 有多大, 都需要将这些LRU/FLUSH list 全部遍历.. 



**解决方法**

解决方法和之前解决undo ACID DDL 的方法类似, 核心思想就是**通过引用计数的方法, 对table_space 加reference, 然后后续lazy delete**

bp 上的每一个page 都有自己对应的version, 当table space 被drop/rename 的时候, 只需要对fil_space 的version + 1, 那么bp 中该fil_space 对应的page 就因为version < fil_space.current_version 而变得无效.

原先由drop/rename tablespace 触发的space_delete 操作就变的非常的轻量. 后续定期的将这些stable page 删除或者复用即可

不过带来的额外开销就是, 每一次访问bp 中的一个page 就需要确认当前page 是否过期.



**具体实现**

buf_page_t 增加 m_space, m_version.

```c++
Additions to buf_page_t {
 ...
 // 指向对应的fil_space_t
 fil_space_t *m_space{};

 // Version number of the page to check for stale pages. This value is
 // "inherited" from the m_space->m_version when we init a page.
 // page 的version number, 在page_init 的时候设置成m_space->m_version
 uint32_t m_version{};
};
```



fil_space_t 增加m_version,  m_n_ref_count.

m_version 就是当前fil_space_t 的版本号, 每次delete/truncate 就会 + 1

m_n_ref_count: bp 每增加一个page , m_n_ref_count + 1, 只能等到m_n_ref_count == 0 的时候, 改fil_space 才能被删除, 否则bp 里面的m_space 指针就会指向空

```c++
Additions to  fil_space_t {
 ...
 // Version number of the instance, not persistent. Every time we truncate
 // or delete we bump up the version number.
 lsn_t m_version{};

 // Reference count of how many pages point to this instance. An instance cannot
 // be deleted if the reference count is greater than zero. The only exception
 // is shutdown.
 std::atomic_int m_n_ref_count{};
};
```



增加了lazy delete fil_space 以后, 那么什么时候将内存中的fil_space_t 删除呢?

最后的删除操作在 master_thread 会定期执行, 将之前已经标记删除, 放入到m_deleted_spaces 中的space 一起删除

/* Purge any deleted tablespace pages. */
fil_purge();  => fil_shard.purge()

```c++
  void purge() {
    mutex_acquire();
    for (auto it = m_deleted_spaces.begin(); it != m_deleted_spaces.end();) {
      auto space = it->second;
      // has_no_references() 说明该fil_space 对应的bp 已经都删除了, 那么该space 就可以删除
      if (space->has_no_references()) {
        ut_a(space->files.front().n_pending == 0);
        space_free_low(space);
        it = m_deleted_spaces.erase(it);
		... }
    mutex_release();
  }
```



**drop/rename tablespace**

执行drop/rename tablespace 的时候需要执行 row_drop_tablespace => fil_delete_tablespace => space_delete(space_id, buf_remove)  

新增加 buf_remove_t 类型: BUF_REMOVE_NONE. 不需要移除该tablespace 的所有bp.

8.0.23 drop table 的时候, 执行 row_drop_tablespace => fil_delete_tablespace,  之前delete tablespace 的时候, 传入的是 BUF_REMOVE_ALL_NO_WRITE, 需要将该space 对应的bp 都清理才可以完成操作.

传入 BUF_REMOVE_NONE 就只需要将tablespace 标记删除, 放入到 m_deleted_spaces 中, 不需要清理bp, 然后将对应的物理文件删除即可. 该tablespace 对应bp 中的数据就变成 stale page, 后续会有操作将这些stale page 删除或者复用.

```c++
enum buf_remove_t {
  /** Don't remove any pages. */
  BUF_REMOVE_NONE,
  /** Remove all pages from the buffer pool, don't write or sync to disk */
  BUF_REMOVE_ALL_NO_WRITE,
  /** Remove only from the flush list, don't write or sync to disk */
  BUF_REMOVE_FLUSH_NO_WRITE,
  /** Flush dirty pages to disk only don't remove from the buffer pool */
  BUF_REMOVE_FLUSH_WRITE
};
```

BUF_REMOVE_ALL_NO_WRITE:

从flush list 和 LRU list 上面都删除, 数据不需要, 并且也不需要刷盘. 从LRU list 上面也都删除开销是比较大的, 因此更多的时候是使用BUF_REMOVE_FLUSH_NO_WRITE, 只删flush list, 不删LRU

一般来说truncate table 的时候是执行这个.  在5.6/5.7 里面, 由于truncate table 了以后, space id 是不会变的, 那么就必须把这些space 对应的page 都删除, 否则如果新的table 的space id 和老的space id 一致, 那就访问到脏数据了.

BUF_REMOVE_FLUSH_NO_WRITE:

从flush list 删除删除, 并且不需要刷盘, 直接丢弃掉. 和BUF_REMOVE_ALL_NO_WRITE 相比, 把从LRU list 上面删除的操作放到了后台来做, 因为lru list 的大小是远远大于flush list, 删除lru list 的成本是很大的, 因此放在后来执行

一般drop table 是执行这个操作, 让后台慢慢从lru list 里面把要drop 的tablespace 删除

BUF_REMOVE_FLUSH_WRITE:

从flush list 上删除, 并且刷脏, 那么就不需要从LRU list 上删除, 因为LRU list 上也是最新的

常用场景, 执行DDL 以后,  DDL 只需要确保这个DDL 产生的page 必须进行刷脏. 执行刷脏逻辑

BUF_REMOVE_NONE:

只需要将tablespace 标记删除, 不需要清理bp, 该tablespace 对应bp 中的数据就变成 stale page, 后续会有操作将这些stale page 删除或者复用.


**<那么什么时候会将这些 stale page 删除呢?**

总共有多个场景:

1. 在正常从bp 中读取page 的时候, 如果读取到的page 是 stale, 那么通过执行 buf_page_free_stale() 将该page 进行删除操作

2. 在从double write buffer Double_write::write_pages() 到磁盘的时候, 如果这个时候改page 的space file 已经被删除, 那么这个时候通过 buf_page_free_stale_during_write() 进行删除
3. 在刷脏操作buf_flush_batch()的时候, 从LRU_list 或者 flush_list 拿取page, 如果发现该page 是stale, 并且没有io 操作在这个page 上面, 那么通过 buf_page_free_stale() 进行删除操作
4. 在single page flush 的时候, 同样判断该page 是stale, 那么通过buf_page_free_stale() 进行删除
