---
layout: post
title: "Basho levelDB 改进"
summary: "Basho levelDB 改进"
---

### 整体改进目标
1. 服务方面: Riak 需要在压力比较大的互联网环境使用. 所以增加了硬件的CRC校验, 增强了Bloom filter 的命中率, 还有默认的数据的完整性的检查
2. 多数据库支持: Riak 会同时打开 8-64个数据库. Google的leveldb也支持这些, 不过他的compaction 线程不支持这些.
具体的做法是当这个 compaction thread 有太多的事情要做的时候, 就停止让用户写入这些数据.
Basho 的leveldb 的改进包括多个线程同时锁住, 让优先级更高的的线程进行compaction 操作

### Basho 与 官方对比
* 官方: 只限制sst文件的大小

Basho: 限制sst文件的大小同时限制sst文件key的个数<75000

原因: 为了控制bloom filter中key的个数, 反正key过多bloom filter的命中率降低


* 官方: LevelDB 的每个级别的sst文件大小

Basho: 定制了每个级别的sst文件大小

原因: 因为一个进程需要打开64个levelDB实例, 所以需要限制levelDB单个实例的open_files.


* 官方: 没有统计当前DB的key个数等方法

Basho: 增加统计工具. 通过在sst文件的头部添加统计结构, 可以统计每一个sst文件中key 的个数

原因: 方便管理统计


* 官方: 没有DB的操作数的记录统计

Basho: 在Leveldb进程加入shared memory segment, 用来统计Get, Put, OpenFile 等当前信息

原因: 方便管理


* 官方: 当Compaction线程落后很多的时候, 会不可写

Basho: 增加Compaction线程, 每个线程有优先级.优先级最高的是imm_ 到 Level 0的Compaction

原因: 因为当imm_满的时候, 写入是不允许的. 增加Compaction的优先级, 可以优先满足imm_到Level 0 的Compaction
具体的做法是这样:
有4个线程 normal,  level0 => level1, background unmap (目前没用), imm_ => level0

每个线程各自维护着自己要Compaction的Item, 当出现imm_到level0 的线程需要Compaction 而normal 线程正在Compaction的时候,

会把normal这个线程里面的Item删除, 加入imm_ => level0 的需要Compaction的Item. 这样能有效的提高了imm_ => level0 Compaction的效率


## 具体参数调整
1. write_buffer_size: Riak 会随机把这个write_buffer_size 设置在30MB ~ 60MB 之间, 而默认大小是 4MB.
这样带来的影响是log文件的大小变大, 同样level0 的文件的大小也相应的增大了
2. max_open_files: Riak 考虑了max_open_files 对内存的影响, 因为这个 max_open_files 对应的是打开的table_cache的数量, 因此Riak 减少了这一部分的cache
3. 具体计算哪一个级别需要进行compaction的 score上进行了修改
4. 对每个级别的sst 文件的大小,  每个级别的MaxBytes, m_DesireBytesForlevel 进行了调整, 而原来leveldb 是每个级别的sst 的大小均为2M,
#### 可以看出 eleveldb 调整了 write_buffer_size 的大小, 调整了每个级别的sst 文件的大小, 调整了每个级别能有MaxBytesForLevel 等等参数都是为了减少sst 文件的数目.因为Riak 的实现里面也是一个进程开了多个 eleveldb 的实例, 所以如果文件比较多, 那么打开的open_files 就比较多.很容易超出进程的open files.
