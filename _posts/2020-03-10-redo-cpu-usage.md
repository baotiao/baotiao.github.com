---
layout: post
title: InnoDB redo log  thread cpu usage
summary: InnoDB redo log  thread cpu usage
 
---

InnoDB 在8.0 里面把写redo log 角色的各个线程都独立出来, 每一个thread 都处于wait 状态, 同样用户thread 调用log_write_up_to 以后, 也会进入wait 状态.

这里的wait 等待最后都是通过调用 os_event_wait_for 来实现, 而 os_event_wait_for 是标准 spin + wait 的方式实现.



**os_event_wait_for**

inline static Wait_stats os_event_wait_for(os_event_t &event,
                                           uint64_t spins_limit,
                                           uint64_t timeout,
                                           Condition condition = {})

所以这里有两个参数会影响os_event_wait_for 函数

1. spins_limit
2. timeout



在include/os0event.ic 里面, **os_event_wait_for 是把spin 和 os_event_t 结合起来使用的一个例子**.

简单来说就是先spin 一段时间, 然后在进入pthread_cond_wait() 函数, 所以spins_limit 控制spin 的次数, timeout 控制pthread_cond_wait()  wait的时间



具体来说

在进行pthread_cond_wait 之前, 先通过PAUSE 指令来做spin loop, 在每一次的spin loop 的时候, 同时检查当前的条件是否满足了, 如果满足 当前这个os_event_wait_for 就不经过pthread_cond_wait 的sleep 就可以直接退出了, 如果不满足, 才会进入到 pthread_cond_wait

在具体执行pthread_cond_wait 的时候, 当超时被唤醒的时候, 也会动态调整pthread_cond_wait 的timeout 时间, 在每4次超时返回以后, 会把当前的timeout 时间\* 2. 然后最大的timeout 时间是100ms

// 1. timeout
// 2. timeout
// 3. timeout
// 4. timeout
// 5. 2 * timeout
// ...
// 9. 4 * timeout
// ...
// 13. 8 * timeout



InnoDB 这里做的很细致, 8.0 新增加的这几个log_writer, log_flusher, log_write_notifier, log_flusher_notifier, log_closer 等等thread 都可以调整spin 的次数, 以及每次spin 的时间.



| 线程名称           | innodb_log_xxx_spin_delay            | innodb_log_xxx_timeout            |
| :----------------- | :----------------------------------- | :-------------------------------- |
| log_writer         | innodb_log_writer_spin_delay         | innodb_log_writer_timeout         |
| log_flusher        | innodb_log_flusher_spin_delay        | innodb_log_flusher_timeout        |
| log_write_notifier | innodb_log_write_notifier_spin_delay | innodb_log_write_notifier_timeout |
| log_flush_notifier | innodb_log_flush_notifier_spin_delay | innodb_log_flush_notifier_timeout |
| log_closer         | innodb_log_closer_spin_delay         | innodb_log_closer_timeout         |



**srv_log_spin_cpu_abs_lwm && srv_log_spin_cpu_pct_hwm**

同时 InnoDB 也会统计运行过程中的cpu 利用率来判断spin 最多可以执行多少次.

struct Srv_cpu_usage {
  int n_cpu;
  double utime_abs;
  double stime_abs;
  double utime_pct;
  double stime_pct;
};



在这里主要用到 srv_cpu_usage.utime_abs和srv_cpu_usage.utime_pct. 

innodb主线程会每隔一段时间（>= 100ms）, 执行 srv_update_cpu_usage() 更新cpu_usage, 记录在srv_cpu_usage内.

srv_cpu_usage.utime_abs表示平均每微秒时间内所有用户态cpu 执行的时间总和, 比如一个进程使用了16core, 那么就会统计16core 上总的时间

比如说，系统是4核，这一次的更新间隔是200us，cpu 0-3的用户态时间分别为100us, 80us, 110us, 110us，则srv_cpu_usage.utime_abs 为（100+80+110+110）* 100 / 200 = 200；

srv_cpu_usage.utime_pct则是平均每微秒时间内用户态cpu 的百分比, 其实就是总的时间除以cpu 个数, srv_cpu_usage.utime_pct = srv_cpu_usage.utime_abs / n_cpus.



可以调整的两个参数对于cpu 的利用率限制:

srv_log_spin_cpu_abs_lwm（默认值80）

srv_log_spin_cpu_pct_hwm （默认值50）

**srv_log_spin_cpu_abs_lwm: 表示的是平均每微秒时间内, 用户态cpu 时间的最小值, 平均每微秒用户态cpu 时间超过这个值, 才会spin**

**srv_log_spin_cpu_pct_hwm: 表示的是用户态cpu 利用率, 当cpu 使用率小于这个值的时候, 才会spin**



在 log_wait_for_write 和log_wait_for_flush 中

会同时判断 srv_log_spin_cpu_abs_lwm 和 srv_log_spin_cpu_pct_hwm 这两个参数,

729 static Wait_stats log_wait_for_write(const log_t &log, lsn_t lsn) {
......
738   if (srv_flush_log_at_trx_commit == 1 ||
739       srv_cpu_usage.utime_abs < srv_log_spin_cpu_abs_lwm ||
740       srv_cpu_usage.utime_pct >= srv_log_spin_cpu_pct_hwm) {
741     max_spins = 0;
742   }
......
763 }

769 static Wait_stats log_wait_for_flush(const log_t &log, lsn_t lsn) {
......
775   if (log.flush_avg_time >= srv_log_wait_for_flush_spin_hwm ||
776       srv_flush_log_at_trx_commit != 1 ||
777       srv_cpu_usage.utime_abs < srv_log_spin_cpu_abs_lwm ||
778       srv_cpu_usage.utime_pct >= srv_log_spin_cpu_pct_hwm) {
779     /* Average flush time is too big, don't spin,
780     also don't spin when trx != 1. */
781     max_spins = 0;
782   }
......
809 }



同时所有的 log_writer, log_flusher, log_write_notifier, log_flush_notifier, log_closer 等等8.0 新增加的redo log 相关的线程在执行os_event_wait_for 之前都会判断

如果 srv_cpu_usage.utime_abs < srv_log_spin_cpu_abs_lwm

也就是当前cpu 用户态执行的时间小于就不允许进行spin 了, 

```c++
auto max_spins = srv_log_writer_spin_delay;

if (srv_cpu_usage.utime_abs < srv_log_spin_cpu_abs_lwm) {
  max_spins = 0;
}

const auto wait_stats = os_event_wait_for(
    log.writer_event, max_spins, srv_log_writer_timeout, stop_condition);
```



在低core 的场景中, cpu 本身就少, 所以要尽可能避免cpu 的使用, 因此线上可以把这两个参数设置成规格参数



因此可以综合调整这两个参数, 当cpu 利用率高的时候 调大 srv_log_spin_cpu_abs_lwm, 调小 srv_log_spin_cpu_pct_hwm 降低资源的利用率
