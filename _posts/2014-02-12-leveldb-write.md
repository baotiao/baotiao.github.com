---
layout: post
title: "Leveldb write "
description: "Leveldb write"
category: tech
tags: [throrem]
---

年前分享了LevelDB的时候遗留了一个问题
就是在LevelDB Write操作的时候, 如何做到线程安全的, 以及在代码里面为什么要同时通知这么多个的线程

```c++
while (true) {
  Writer* ready = writers_.front();
  writers_.pop_front();
  if (ready != &w) {
    ready->status = status;
    ready->done = true;
    ready->cv.Signal();
  }
  if (ready == last_writer) break;
}
```

重新看了一下代码应该是这个样子的

```c++
Status DBImpl::Write(const WriteOptions& options, WriteBatch* my_batch) {
  // 这里用到的就是标准的 condition variable 配合 mutex 使用的例子,
  // 这里在这个while 里面添加的 w != writes_.front() 同时又保证了只有一个写
  Writer w(&mutex_); // 这个w锁是一个条件变量, 传入的mutex_是交给条件变量里面的mu_的
  w.batch = my_batch;
  w.sync = options.sync;
  w.done = false;

  // NICE
  // 这里写的也很精妙, 之所以用MutexLock 来实现, 是因为这样只要在中途退出就会自动
  // 触发这个MutexLock的析构函数, 析构函数里面写了unLock这个锁的操作, 那么就可以不用在
  // 每个中间的return 前面都加上这个l->unLock()操作
  MutexLock l(&mutex_); // 这里的操作是在做pthread_cond_wait之前把mutex_锁住的操作, 这样保证pthread_cond_wait的时候不会死锁
  writers_.push_back(&w);
  //这里用一个队列, 并且只有在队列最头部的那个writeBatch才会被写. 所以进入到下面Write的过程只会有一个线程
  while (!w.done && &w != writers_.front()) {
    w.cv.Wait(); //这里是condition varaible, 这里wait 的时候会同时把mu_这个锁放开
  }
  /* 之前解释说这里w.done 是写代码写的很小心, 是错误的, 具体解释见下面 */
  if (w.done) {
    return w.status;
  }
  // 接下来处理的就是这个writers_ 里面最头的那个的信息

  // May temporarily unlock and wait.
  // 这里是检查memtable有没有空间可以写入, 如果没有就换一个buffer 和 compaction等操作
  Status status = MakeRoomForWrite(my_batch == NULL);
  uint64_t last_sequence = versions_->LastSequence();
  Writer* last_writer = &w;
  if (status.ok() && my_batch != NULL) {  // NULL batch is for compactions

    /*  主要的地方就是这个BuildBatchGroup 函数, 这个函数做的是将这个队列里面前几个的Writer, 合并成一个Batch.
        这么做的原因我想主要也是为了性能考虑, 因为这里我们每一次的Put, 都是一个batch, 所以这里会将多个的batch
        合并成一个Batch来进行处理, 主要是为了减少写log 的时候写磁盘的次数,
        因此比较这次write 里面磁盘IO 是占用最大的.
        所以这里将队列的前几个Batch合并成了一个Batch, 由当前的Batch处理了. 所以刚才上面那个代码会判断一下当前的这个
        Write 是否已经被处理好了

        代码见下面
     */

    WriteBatch* updates = BuildBatchGroup(&last_writer);

    WriteBatchInternal::SetSequence(updates, last_sequence + 1);
    last_sequence += WriteBatchInternal::Count(updates);

    // Add to log and apply to memtable.  We can release the lock
    // during this phase since &w is currently responsible for logging
    // and protects against concurrent loggers and concurrent writes
    // into mem_.
    {
      //因为到这里的时候 只有一个writers_里面的一个能到达这里. 所以这里可以保证这有一个线程到了可以AddRecord这一步了.
      //所以这里把锁release掉

      mutex_.Unlock();
      status = log_->AddRecord(WriteBatchInternal::Contents(updates));
      if (status.ok() && options.sync) {
        status = logfile_->Sync();
      }
      if (status.ok()) {
        status = WriteBatchInternal::InsertInto(updates, mem_);
      }
      mutex_.Lock();
    }
    if (updates == tmp_batch_) tmp_batch_->Clear();

    versions_->SetLastSequence(last_sequence);
  }

  /*  这里循环判断已经被处理掉的batch, 设置done = true, 并从队列里面取出, 并Pop()掉, 可以看出
      这里都是因为上面做了Batch合并, 同时处理了多个Batch. 所以这里可以直接将这个done = true. 并
      触发这个线程, 然后线程进入刚才的Wait()判断成功. 然后
      if (w.done) {
      return w.status;
      }
      就直接退出了
      就相当于队里头部的这个线程, 完成多其他线程的几个的写操作
   */

  while (true) {
    Writer* ready = writers_.front();
    writers_.pop_front();
    if (ready != &w) {
      ready->status = status;
      ready->done = true;
      ready->cv.Signal();
    }
    if (ready == last_writer) break;
  }

  // 这里之前已经把合并一起的Batch都处理完了, 并且已经处理的Batch都从队列里面Pop()出去了, 然后现在就
  // 唤醒当前队列最前面的线程
  if (!writers_.empty()) {
    writers_.front()->cv.Signal();
  }

  return status;
}

WriteBatch* DBImpl::BuildBatchGroup(Writer** last_writer) {
  assert(!writers_.empty());
  Writer* first = writers_.front();
  WriteBatch* result = first->batch;
  assert(result != NULL);

  size_t size = WriteBatchInternal::ByteSize(first->batch);

  // Allow the group to grow up to a maximum size, but if the
  // original write is small, limit the growth so we do not slow
  // down the small write too much.
  size_t max_size = 1 << 20; // 这个size 是设置合并的WriteBatch 的大小
  if (size <= (128<<10)) {
    max_size = size + (128<<10);
  }

  *last_writer = first;
  std::deque<Writer*>::iterator iter = writers_.begin();
  ++iter;  // Advance past "first"
  for (; iter != writers_.end(); ++iter) {
    Writer* w = *iter;
    if (w->sync && !first->sync) {
      // Do not include a sync write into a batch handled by a non-sync write.
      break;
    }

    if (w->batch != NULL) {
      size += WriteBatchInternal::ByteSize(w->batch);
      if (size > max_size) {
        // Do not make batch too big
        break;
      }

      // Append to *reuslt
      if (result == first->batch) {
        // Switch to temporary batch instead of disturbing caller's batch
        result = tmp_batch_;
        assert(WriteBatchInternal::Count(result) == 0);
        WriteBatchInternal::Append(result, first->batch);
      }
      WriteBatchInternal::Append(result, w->batch);
    }
    *last_writer = w;  // 同时更新最后的last_writer 到队列里面最新的last_writer
  }
  return result;
}
```

### 总结:    

LevelDB Write 的线程安全是通过引擎的加锁保证, 如果有多个写的时候,
有且只有一个线程可以进行数据的消费, 其他的线程都会阻塞

和标准的队列的生产者消费者模型不一样的地方在于, leveldb
这个队列消费的时候会把队列里面的多个对象合成一个大对象进行消费,
主要是因此消费对象的时候需要进行AddRecord 操作, 需要进行磁盘IO,
因此将多次小的磁盘IO 合成一个大的磁盘IO 能够有效的提高性能
