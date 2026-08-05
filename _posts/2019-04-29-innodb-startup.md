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



InnoDB 在Parse Redo log 以后, 会把对应的page 放入到hash table 中, 等待后台线程将hash table 中的数据进行apply 到buffer pool. 这一个步骤需要将数据中Disk 中读取出来, 然后和内存中parsed buffer(以 hash table 格式存储) 中的数据进行Merge, 然后写入到buffer pool page 中.  InnoDB 在奔溃恢复的过程中, 并不需要等到这些hash table 中的数据都apply 到disk 才能提供服务, 而是提供了一个变量 recv_recovery_on. 

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

但是目前官方的版本是 apply redo完才可以提供服务，并不是在 parse redo 完就对外提供服务的。

其实理论上，如果在 parse redo 完成就提供服务，是可以更早地对外提供服务的。

之前也和官方讨论过这个问题，官方希望的是尽早把 redo apply 的流程做完，如果 redo 有问题，尽早把问题暴露出来，而不是等到 I/O 路径上具体读到某一个 page、再把该 page 对应的 redo apply 到 page 上时才暴露问题。所以官方其实希望在 crash recovery 的恢复阶段，就把 redo 的 apply 做得干干净净，再对外提供服务。

但是，如果这里在 parse 完就可以提供服务，理论上会更快。因为在整个流程中，scan redo log 和 parse redo log 的阶段都只需要顺序读取磁盘就够了，而 apply redo log 才是最消耗时间的阶段。

而且，既然事务的回滚已经放在了后台慢慢做，那我理解，理论上 apply 应该也可以放在后台做，这样就能尽快地对外提供服务了。
