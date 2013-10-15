---
layout: post
title: "levelDB Compaction 相关"
description: "level source code"
category: tech
tags: [levelDB]
---

# levelDB

## level DB 如何选择要Compaction的级别

这个计算级别的函数在version_set::Finalize() 里面

在Finalize里面, 有一个算score的过程

看了一下这个 算Finalive的过程, 根据官方配置

    level 0: 差不多 4 个 sst 文件的时候分数 = 1
    level 1: 差不多 5 个 sst 文件的时候分数 = 1
    level 2: 差不多 50 个 sst 文件的时候分数 = 1
    level 3: 差不多 500 个 sst 文件的时候分数 = 1
    ……

Finalize 只会在 LogAndApply 和 VersionSet::Recover() 的时候被调用, 也就是生成一个新的Version 的时候被调用.

结论: 所以可以这么说 每次生成一个新的Version 的时候 我们都已经初始化好了这个分数, 判断这一个version 是否需要 compaction 以及那个级别需要compaction

## level DB 会触发Compaction的操作

触发这个MaybeScheduleCompaction() 的地方应该就是有可能触发后台这个Compaction的地方了, 目前会调用到这个MaybeScheduleCompaction() 的地方有

* 在进行了一次Compaction 以后, 也就是在DBImpl::Background()函数里面 

为什么要做Compaction 因为可能会产生太多的新文件在新的一个级别, 所以会检查一下是否需要再进行一次Compaction

* 在进行了一次 DBImpl::Get 操作了以后, 如果这个数据是在sst的文件里面找到的. 
get的时候找到的这个key存在多个level 0 的文件里面那么就会触发compaction

为什么要做Compaction 因为如果一个key在多个文件里面找到,那么说明这个key在多个level 0的文件里面重复了, 所以检查一下是否需要进行compaction
    if (have_stat_update && current->UpdateStats(stats)) { // 这里如果有更新, 那么会判断是否启动后台的Compaction() 进程

* 在 DBImpl::Write 的 MakeRoomForWrite 函数里面, 当immutable 生成一个level 0 文件的时候, 会检查一下是否需要Compaction, 这样会防止level 0 文件过多.

为什么要做Compaction 这时候做Compaction, 主要为了防止不断的从immutable 生成到level 0 文件, 一直触发immutable到level0 过程, 而没有时间进行其他级别的合并 并且在MakeRoomFroWrite 的时候, 我们会检查一下 如果level0 的文件数 > config::kL0_SlowdownWritesTrigger 这个数据的大小的话. 那么我们 就会sleep 一段时间, 也是为了让出时间给其他级别进行Compaction

* 在DB::Open() 这里函数里面, 如果Recover 成功以后, 并且进行了
s = impl->versions_>LogAndApply(&edit, &impl>mutex_);

为什么要做Compaction 这里会将可以上次DB关闭以后没有来得及写入的数据重新回放, 所以这里可能会生成新的level 0的文件, 所以这里也会进行 检查 MaybeScheduleCompaction().

## 具体的MaybeCompaction() 过程
#### 函数入口

    void DBImpl::MaybeScheduleCompaction() {
    mutex_.AssertHeld();
    // 如果后台有Compaction 线程, 那么直接退出
    if (bg_compaction_scheduled_) {
                // Already scheduled
                // 如果db 要被 shut_down, 直接退出
            } else if (shutting_down_.Acquire_Load()) {
                // DB is being deleted; no more background compactions
                // 如果 imm_ 这个文件还是空的, 并且是manual_compaction是空的, 这里
                // TODO
            } else if (imm\_ == NULL &&
    manual_compaction\_ == NULL &&
    \!versions_->NeedsCompaction()) {
                // No work to be done
            } else {
                // 设置这个后台有compaction 线程已经启动
                bg_compaction_scheduled_ = true;
                env_->Schedule(&DBImpl::BGWork, this); //调用下面的 BGWork函数. 这里虽然是env_, 当时这env_里面会调用这个函数指针, 调用DBImpl::BGWork 这个函数
            }
    }

    * 在PosixEnv::Schedule 这个函数里面

    void PosixEnv::Schedule(void (*function)(void*), void\* arg) {
    PthreadCall("lock", pthread_mutex_lock(&mu_));

    // Start background thread if necessary
    // 看是否有后台线程已经启动, 如果没有启动就启动这个后台线程, 并执行一个死循环
    // 具体的执行是BGThreadWrapper \-> BGThread 这个函数,
    // 在BGThread 函数就是一个死循环, 不断的从这个queue\_ 里面读出, 这个是FIFO的形式
    // 读出, 先进先出. 没有做一个优先级的概念.
    if (\!started_bgthread_) {
                    started_bgthread_ = true;
                    PthreadCall(
                            "create thread",
                            pthread_create(&bgthread_, NULL,  &PosixEnv::BGThreadWrapper, this));
                }

    // If the queue is currently empty, the background thread may currently be
    // waiting.
    // 如果这个queue\_ 里面的数据当前是空的, 则等待cond 锁让它起来
    if (queue_.empty()) {
                    PthreadCall("signal", pthread_cond_signal(&bgsignal_));
                }

    // Add to priority queue
    queue_.push_back(BGItem());
    queue_.back().function = function; // 这里注册的函数是 &DBImpl::BGWork
    queue_.back().arg = arg; // 这里arg 是 db->this指针

    PthreadCall("unlock", pthread_mutex_unlock(&mu_));
    }


#### 接下来是具体执行 函数 BackgroundCall() -> BackgroundCompaction().

在BackgroundCompaction() 函数里面

优先 compaction immutable -> level0 sst

然后 我们都是!is_manual 的, 那么我们就要选择去Compaction() 那个级别的.

在versions_->PickCompaction().

这里我们有之前在Finalfize() 里面算出来的compaction_score_, 如果这个score < 1 就不进行compaction.

这里可以看到并不是每次检查是否需要Compaction 的时候都会进行. 只有score >= 1 的时候levelDB才会选一个级别进行Compaction()

在选择好Compaction的级别以后. 就调用BackgroundCompaction

如果生成的这个Compaction 是空的, 那么就不进行Compaction
选择是否能直接将这个文件移动到level + 1, 而不用与level + 1 的文件进行归并的计算
进行真正的Compaction DoCompactionWork() 函数

#### 在DoCompactionWork()函数里面

* 对这些指针进行归并, 归并出一个MergeIterator input. 

具体的iterator 看leveldb iterator

* 遍历获得的需要合并的数据, 如果这个key以前是否出现. 

如果已经出现过了就不会再进行处理 因为leveldb 里面对相同的key是进行过排序的. 默认squencenumber 最大的排在最前面, 也就是最新的数据排在最前面.

    如果这个key 的squenctNumber < 当前快照的版本号, 说明这个key 是旧的了.
    如果这个key 的类型是delete, 并且更高级别已经没有这个key的数据了, 那么这个key也会被drop掉
    可以看出, levelDB 这里做了这些操作也都是尽可能的减少key的数量

* 接下来就把这些剩余的key插入到新的version里面

