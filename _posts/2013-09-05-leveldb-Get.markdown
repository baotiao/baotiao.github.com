---
layout: post
title: "levelDB Get过程"
description: "leveldb"
category: tech
tags: [leveldb]
---

    Status DBImpl::Get(const ReadOptions& options,
            const Slice& key,
            std::string* value) {
        Status s;
        MutexLock l(&mutex_); //这里初始化levelDB的锁, 默认把锁加上
        SequenceNumber snapshot; //这里就是定义一个最新的一个操作号, 有一个全局
        唯一的SequenceNumber
        if (options.snapshot != NULL) { //如果要求取的是某一个版本的数据
            snapshot = reinterpret_cast<const SnapshotImpl*>(options.snapshot)->number_;
        } else {
            snapshot = versions_->LastSequence(); //否则就是最新的数据, 也就是当
            前versions_里面最大的SequenceNumber的数据
        }

        MemTable* mem = mem_; //mem table
        MemTable* imm = imm_; //imm table
        Version* current = versions_->current(); //当前的version
        mem->Ref(); //对mem的引用+1, 这个ref主要是用来删除文件的时候判断, 如果这
        个ref引用为0了, 那么就可以删除掉.
        if (imm != NULL) imm->Ref();
        current->Ref(); //同样对当前版本的ref引用+1

        bool have_stat_update = false; //用来是否有更新, 如果有更新再判断是否启动compaction线程
        Version::GetStats stats;

        // Unlock while reading from files and memtables
        {
            mutex_.Unlock(); //把锁放开, 可以看到 正真加锁部分只有获得当前版本号
            , 以及获得当前最新的版本这一部分, 也就是说在具体的get操作之前就已经
            可以支持多个线程进行读取了. 为什么可以这么做呢? 首先获得了当前最新的
            current以后, 并把这个current 的引用+1, 就可以保证当前的这个version
            是不会被删除的, 同样对于当前的这个imm, mem ref+1 以后可以保证是不会
            呗删除掉得. 所以只要在这段时间锁住就可以. 如果这个时候又有新的key写
            入, 那么他这个时候写入的key 是一个新的SequenceNumber. 不会影响我们接
            下来读的结果.

            // First look in the memtable, then in the immutable memtable (if any).
            LookupKey lkey(key, snapshot);
            if (mem->Get(lkey, value, &s)) { //从mem里面读取这个key的 value  这
            里要注意memtable里面的kv 是如何排序的. 这里面key的排序是 首先按照
            SquenceNumber排序, 然后是操作类型(删除排在最前面), 然后是key的大小(
            具体再看一下Compaction里面)
                // Done
            } else if (imm != NULL && imm->Get(lkey, value, &s)) {
                // Done
            } else {
                s = current->Get(options, lkey, value, &stats); //如果mem 和
                imm 都找不到, 那么这个时候我们要从一个一个level里面去找.
                have_stat_update = true;
            }
            mutex_.Lock();
        }

        if (have_stat_update && current->UpdateStats(stats)) { //
        这里如果有更新, 那么会判断是否启动后台的Compaction() 进程
            MaybeScheduleCompaction();
        }
        mem->Unref(); //分别把 mem, imm, current 的ref - 1
        if (imm != NULL) imm->Unref();
        current->Unref();
        return s;
    }
