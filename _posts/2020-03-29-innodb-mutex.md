---
layout: post
title: InnoDB mutex 变化历程
summary: InnoDB mutex 变化历程
 
---


InnoDB 中的mutex 和 rw_lock 在早期的版本都是通过系统提供的cas, tas 语义自己进行实现, 并没有使用pthread_mutex_t, pthread_rwlock_t,  这样实现的好处在于便于统计, 以及为了性能考虑, 还有解决早期操作系统的一些限制.

大概原理是:

在mutex_enter 之后, 在spin 的次数超过 innodb_sync_spin_loops=30 每次最多 innodb_spin_wait_delay=6如果还没有拿到Mutex, 会主动yield() 这个线程, 然后wait 在自己实现的wait array 进行等待.

这里每次spin 时候, 等待的时候执行的是ut_delay, 在ut_delay 中是执行 "pause" 指定, 当innodb_spin_wait_delay = 6 的时候, 在当年100MHz Pentium cpu, 这个时间最大是1us.

wait array 也是InnoDB 实现的一种cond_wait 的实现, 为什么要自己实现?

早期的MySQL 需要wait array 是因为操作系统无法提供超过100000 event, 因此wait array 在用户态去进行这些event 维护, 但是到了MySQL 5.0.30 以后, 大部分操作系统已经能够处理100000 event, 那么现在之所以还需要 wait array, 主要是为了统计.

在wait array 的实现里面其实有一把大wait array mutex, 是一个pthread_mutex_t, 然后在wait array 里面的每一个wait cell 中, 包含了os_event_t, wait 的时候调用了os_event_wait_low(), 然后在 os_event_t 里面也包含了一个mutex,  因此在一次wait 里面就有可能调用了两次pthread_mutex_t 的wait.

并且在os_event_t 唤醒的机制中是直接通过pthread_cond_boradcast(), 当有大量线程等待在一个event 的时候, 会造成很多无谓的唤醒.



大致代码实现:

```c++
  void enter(uint32_t max_spins, uint32_t max_delay, const char *filename,
             uint32_t line) UNIV_NOTHROW {
    // 在try_lock 中通过 TAS 比较是否m_lock_word = LOCKED
    // TAS(&m_lock_word, MUTEX_STATE_LOCKED) == MUTEX_STATE_UNLOCKED
    // 在InnoDB 自己实现的mutex 中, 使用m_lock_word = 0, 1, 2 分别来比较unlock,
    // lock, wait 状态
    // 在InnoDB 自己实现的rw_lock 中, 同样使用 m_lock_word 来标记状态,
    // 不过rw_lock 记录的状态就不止lock, unlock, 需要记录有多少read 等待,
    // 多少write 等待等待, 不过大体都一样
    if (!try_lock()) {
      // 如果try_lock 失败, 就进入spin 然后同时try_lock 的逻辑
      spin_and_try_lock(max_spins, max_delay, filename, line);
    }
  }

  void spin_and_try_lock(uint32_t max_spins, uint32_t max_delay,
                         const char *filename, uint32_t line) UNIV_NOTHROW {
    for (;;) {
      /* If the lock was free then try and acquire it. */

      // is_free 的逻辑很简单, 每spin 一次, 就检查一下这个lock 是否可以获得,
      // 如果不可以获得, 那么就delay (0, max_delay] 的时间
      if (is_free(max_spins, max_delay, n_spins)) {
......
      }
        // 如果尝试了max_spins 次, 那么就将当前cpu 时间片让出
      os_thread_yield();

      // 最后进入到wait 逻辑, 这个wait 是基于InnoDB 自己实现的wait array 来实现
      if (wait(filename, line, 4)) {
        n_spins += 4;

  }

```



2012 年的时候, Mark 在这边文章中说, 现有的mutex 实现会导致cpu 利用过高, 差不多比使用pthread mutex 高16%, 并且上下文切换也会更高

https://www.facebook.com/notes/mysql-at-facebook/green-mutexes/10151060544265933/

主要的原因是:

1. 因为Mutex 的唤醒在os_event 里面, os_event 实现中, 如果需要执行唤醒操作, 那么需要执行pthread_cond_boradcast() 操作, 需要把所有等待的pthread 都唤醒, 而不是只唤醒一个. 

   Innam 在底下回复: 当然只唤醒一个也并不能完全解决问题, 如果使用 pthread_cond_signal, 那么等待的线程就是一个一个的被唤醒, 那么所有等待的线程执行的时间就是串行的

   在当前InnoDB 的实现中, 如果使用pthread_cond_boradcase 会让所有的线程都唤醒, 然后其中的一个线程获得mutex, 但是其他线程并不会因为拿不到mutex马上进入wait, 而是依然会通过spin 一段时间再进入wait,这样就可以减少一些无谓的wait.

   所以这里官方到现在一直也都没有改.

2. 在wait array 的实现中,  需要有一个全局的pthread_mutex_t 保护 sync array, 

3. 在默认的配置中, innodb_spin_wait_delay=6 是ut_delay 执行1us,  innodb_sync_spin_loops=30 会执行30次, 那么每次mutex 有可能都需要spin 30us, 这个太暴力了

   

然后 sunny 在这个文章里面回复, 

https://www.facebook.com/notes/mysql-at-facebook/green-mutexes-part-2/10151061901390933

sunny 的回复很有意思:

 It is indeed an interesting problem. I think different parts of the code have different requirements. Therefore, I've designed and implemented something that allows using the mutex type that best suits the sub-system. e.g., mutexes that are held very briefly like the page mutexes can be pure spin locks, this also makes them space efficient. I've also gotten rid of the distinction between OS "fast" mutexes and InnoDB mutexes. We can use any type of mutexes in any part of the code. We can also add new mutexe types. I've also been experimenting with Futexes, implemented a mutex type for Linux which uses Futexes to schedule the next thread instead of the sync array 



这里主要核心观点有两个

1. **不同场景需要的mutex 是不一样的, 比如buffer pool 上面的page 的mutex 希望的就是一直spin. 有些mutex 其实则是希望立刻就进入等待,  只用使用这些mutex 的使用者知道接下来哪一个策略更合适**
2. 操作系统提供了futex 可能比InnoDB 自己通过wait array 的实现方式, 对于通知机制而言会做的更好.



所以就有了这个worklog: 

worklog: https://dev.mysql.com/worklog/task/?id=6044

总结了现有的 mutex 实现存在的问题

1. 只有自己实现的ib_mutex_t, 并没有支持futex 的实现
2. 所有的ib_mutex_t 的行为都是一样的, 通过两个变量 innodb_spin_wait_delay(控制在Test 失败以后, 最多会delay 的时间), innodb_sync_spin_loops(控制spin 的次数). 不可以对某一个单独的ib_mutex_t 设置单独的wait + loop 次数
3. 所有的ib_mutex_t 由两个全局的变量控制, 因为mutex 在尝试了innodb_sync_spin_loops 次以后, 会等待在一个wait array 里面的一个wait cell 上, 所有的wait cell 都会注册到一个叫wait array 的队列中进行等待, 然后等



**最后到现在在 InnoDB 8.0 的代码中总共实现了4种mutex 的实现方式, 2种的策略**

1. TTASFutexMutex 是spin + futex 的实现,  在mutex_enter 之后, 会首先spin 然后在futex 进行wait

2. TTASMutex 全spin 方式实现, 在spin 的次数超过 innodb_sync_spin_loops=30 每次最多 innodb_spin_wait_delay=6us 以后, 会主动yield() 这个线程, 然后通过TAS(test and set 进行判断) 是否可以获得

3. OSTrackMutex, 在系统自带的mutex 上进行封装, 增加统计计数等等

4. TTASEevntMutex, InnoDB 一直使用的自己实现的Mutex, 如上文所说使用spin + event 的实现.


```c++
#ifdef HAVE_IB_LINUX_FUTEX
UT_MUTEX_TYPE(TTASFutexMutex, GenericPolicy, FutexMutex)
UT_MUTEX_TYPE(TTASFutexMutex, BlockMutexPolicy, BlockFutexMutex)
#endif /* HAVE_IB_LINUX_FUTEX */

UT_MUTEX_TYPE(TTASMutex, GenericPolicy, SpinMutex)
UT_MUTEX_TYPE(TTASMutex, BlockMutexPolicy, BlockSpinMutex)

UT_MUTEX_TYPE(OSTrackMutex, GenericPolicy, SysMutex)
UT_MUTEX_TYPE(OSTrackMutex, BlockMutexPolicy, BlockSysMutex)

UT_MUTEX_TYPE(TTASEventMutex, GenericPolicy, SyncArrayMutex)
UT_MUTEX_TYPE(TTASEventMutex, BlockMutexPolicy, BlockSyncArrayMutex)
```



同时在8.0 的实现中定义了两种策略, GenericPolicy, BlockMutexPolicy. 这两种策略主要的区别在于在show engine innodb mutex 的时候不同的统计方式.

BlockMutexPolicy 用于统计所有buffer pool 使用的mutex, 因此该Mutex 特别多, 如果每一个bp 单独统计, 浪费大量的内存空间, 因此所有bp mutex 都在一起统计, 事实上buffer pool 的rw_lock 也是一样

GenericPolicy 用于除了buffer pool mutex 以外的其他地方



**使用方式**

目前InnoDB 里面都是使用 TTASEventMutex

只不过buffer pool 的mutex 使用的是 BlockMutexPolicy, 而且他的mutex 使用的是 GenericPolicy, 不过从目前的代码来看, 也只是统计的区别而已



**问题**

但是从目前来看, 并没有实现sunny 说的, 不同场景使用不同的mutex, Buffer pool 使用 TTASMutex 实现, 其他mutex 使用 TTASEventMutex, 
并且新加入的 TTASFutexMutex, 也就是spin + futex 的实现方式其实也不是默认使用的
而且wai array 的实现方式也并没有改动

