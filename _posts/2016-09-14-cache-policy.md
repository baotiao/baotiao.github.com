---
layout: post
title: cache policy
summary: cache policy

---

### cache policy

近期在做ceph cache-tier 相关的事情, 在cache-tier 里面cache有多种更新策略

其实更缓存相关的系统里面, 都存在这几种策略, 比如操作系统的page cache,
业务层使用memcache, redis 作为后端数据库的缓存的时候,
也都要考虑缓存和后端存储的数据一致性问题. 其实就是更新操作的时候,
什么时候去更新缓存, 什么时候去更新后端存储的问题?

那么这个时候一般会有3种策略

1. no-write
2. write-through
3. write-back

* no-write

no-write 的实现方式是写入数据的时候是直接将数据写入到后端存储, 并且标记cache 中的数据是无效的, 那么后续的某一次读取发现无效以后, 会发起一次读取请求, 将后端存储中的数据更新到cache 中, 并且标记有效

这个策略其实很少使用

* write-through

write-through 实现方式是写入的时候将cache 和 后端存储的数据一起更新, 这种方法最能够保证cache 数据的一致性. 并且也是简单的方法, 但也是性能最低的一个方法

* write-back

write-back 也是linux page cache采用的方式, 我觉得也是最通用的一种方式, 在write-back 策略里面, 写入操作是直接更新到cache 里面的,  后端存储不会马上更新. 然后这些需要更新的page 会被标记成dirty, 放到一个dirty list 里面, 然后周期性的有pdflush(2.6.32 以后就是flush per device)进行将cache 里面的数据刷回后端存储,  然后这些page 就不在标记dirty.

write-back 方案可以看成是write-through 的一个优化版本,  其实就是通过lazy write 一次写入比较大的数据来提高这个写入的性能, 但是带来的问题可能就是缓存中的数据有可能丢失了. 所以在linux 里面可以通过fsync 来强制某一次的写入写到磁盘, 也就是从write-back 变成write-through了

