---
layout: post
title: InnoDB startup redo log optimize in 8.0
summary: InnoDB startup redo log optimize in 8.0
---


InnoDB 启动的时候主要做的事情就是将redo log 里面, checkpoint 之后的数据恢复到内存buffer pool以后, 就可以对外提供服务, redo log 中的内容包含btree page, undo page. 具体的将buffer pool 刷到disk 的事情在后台线程flush page 和 undo purge 两个模块做

其中将redo log 恢复到buffer pool 过程又分成3个部分

1. scan redo log
2. parse redo log
3. apply redo log



InnoDB 在Parse Redo log 以后, 会把对应的page 放入到hash table 中, 等待后台线程将hash table 中的数据进行apply 到buffer pool. 这一个步骤需要将数据中Disk 中读取出来, 然后和hask table 中的数据进行Merge, 然后写入到buffer.  InnoDB 在奔溃恢复的过程中, 并不需要等到这些hash table 中的数据都apply 到disk 才能提供服务, 而是提供了一个变量 recv_recovery_on. 

如果 recv_recovery_on = true, 那么在IO 去读取这个page 的时候, InnoDB 知道此刻disk 中的数据不是最新的, 会把对应的disk page 取出来然后和hash table 中的数据进行merge, 然后才能获得最新的page 数据.

所以在 recv_recovery_from_checkpoint_start 的时候, 会把 recv_recovery_on = true

然后在 recv_recovery_from_checkpoint_finish 的时候, 设置 recv_recovery_on = false



具体读取page IO 路径是:

buf_page_get_gen() =>  

当前page 不在buffer 中, 那么执行 buf_read_page(page_id, page_size) => 

buf_read_page_low() =>  

 1.  buf_page_init_for_read() 初始化一个page 的内存用来保存从disk 读取到的数据

 2.  fio_io(request, sync,...) 同步的从文件中读取page, 这里sync = true

 3.  buf_page_io_complete() 在上面的IO 完成, 从disk 中读取出page 以后, 需要进行的操作 =>

     这里判断 recv_recovery_is_on() is true, 就走 recv_recover_page(true, block); => recv_recover_page_func() => recv_get_rec() 获得这个page 在hash_table 中对应的recv_addr, 然后通过 recv_parse_or_apply_log_rec_body() 将这个recv_addr 中的record apply 到之前通过fio_io() 获得的page, 从而得到最新的page()

     

**总结:**

为什么InnoDB 要做这么细节的优化呢?

因为apply redo log 的过程需要从Disk 中读取数据并且和hash table 中的数据进行Merge 才行, 这一步需要大量的随机磁盘IO, 而前面redo log scan 和 parse 都其实只需要顺序的磁盘IO, 因此速度是很快的. InnoDB 为了加快奔溃恢复的过程, 尽可能快的对外提供服务, 因此就不等apply redo log 完成就对外提供服务了, 只不过如果读取到的page 在hash table 中, 还没有和disk 中Page merge, 还是需要等待的


