---
layout: post
title: leveldb code review
summary: 又看leveldb 的代码, 确实是c++程序员必读的代码
---

* leveldb 一般用继承的时候只有接口继承, 比如DB 和 DBImpl, Comparator 和 BytewiseComparatorImpl 的关系, 然后同时会提供一个函数创建这些类别, 比如

    extern const Comparator* BytewiseComparator();

   返回一个BytewiseComparator() 给.h 文件对外暴露出去

   基本上所有的include 下面都是提供接口继承的方式来使用, 然后在.h 文件提供创建接口

* 对比block_builder.h 和 table_builder.h 可以发现, block_builder 并没有使用Pimpl 的形式来做, 因为block_builder.h 是给内部自己使用的, 而table_builder.h 是给外部使用的. 可以看到BlockBuilder 所有的函数都不需要virtual, 因为已经能够确认这些函数是给自己使用的

* 在DB 里面的GetSnapshot() 确实返回就是类里面的一个成员变量的指针, 

   virtual const Snapshot* GetSnapshot() = 0;

   那么这种唯一的做法只能是给返回的指针加 const

* 关于virtual 的使用

   因为提供的include 文件里面, 大量的都是提供接口继承方式,  所以需要使用virtual 修饰函数, 如果明确知道这个类不会被继承, 那么就不要使用virtual 来修饰函数, 因为毕竟 virtual 是有开销的

* 如果有一些常量只在某一个.cc 文件里面使用到, 那么可以只在这个.cc 文件里面去定义就可以了比如:
  static const size_t kFilterBaseLg = 11;

   static const int kTargetFileSize = 2 * 1048576;

* 比如设计在函数内部会申请一个对象, 并且这个对象需要外部去删除, 那么最好在这个头文件的注释里面说明这个对象需要在外部显示的去调用delete

  ```c++

  // Pick level and inputs for a new compaction.
  // Returns NULL if there is no compaction to be done.
  // 这里说明的返回的对象是在heap 上面创建的一个Compaction 对象,
  // 并不是返回类里面的成员变量, 如果是这样的请求,
  // 那么最好写好注释说明需要外部主动的释放申请的这个对象
  // Otherwise returns a pointer to a heap-allocated object that
  // describes the compaction.  Caller should delete the result.
  Compaction* PickCompaction();
  // 同意底下的compactRange 也一样, 返回的是在heap 上面申请的Compaction 对象, 外部函数需要负责删除
  // Return a compaction object for compacting the range [begin,end] in
  // the specified level.  Returns NULL if there is nothing in that
  // level that overlaps the specified range.  Caller should delete
  // the result.
  Compaction* CompactRange(
     int level,
     const InternalKey* begin,
     const InternalKey* end);
  // 基本上leveldb 里面所有的指针都是在类里面进行一个new的操作
  //   Iterator* result = NewMergingIterator(&icmp_, list, num);
  // 然后作为这个函数的返回, 所以这个时候一定是在函数的头里面去声明当这个指针没用的时候, 跟上面的Compaction 对象一样, 需要显示的去删除掉
  // Create an iterator that reads over the compaction inputs for "*c".
  // The caller should delete the iterator when no longer needed.
  Iterator* MakeInputIterator(Compaction* c);

  ```

* 如果确认某一个对象只可以指向传进来的某一个变量, 并且无法修改变量里面的内容, 那就必须使用

    const Options* const options_;

    TableCache* const table_cache_;

    这里table_cache_的意思是你可以修改table_cache\_ 里面的内容, 但是table_cache\_ 必须是指向的初始化的时候传进来的table_cache

    但是这个table_cache_ 的内容是可以被修改的


* 在Iterator 里面的 EmptyIterator 和 env 里面的EnvWrapper 的用途?

   在Iterator 问题中, 因为Iterator是以虚基类, 不能实例化, 因此在这样的函数中 NewMergingIterator, Block::NewIterator 函数中出错的时候如何返回一个指针, 因此需要一个EmptyIterator

  ```c++
  // 这里当出错的时候就可以返回这个EmptyIterator() 了
  Iterator* NewMergingIterator(const Comparator* cmp, Iterator** list, int n) {
    assert(n >= 0);
    if (n == 0) {
      return NewEmptyIterator();
    } else if (n == 1) {
      return list[0];
    } else {
      return new MergingIterator(cmp, list, n);
    }
  }
  ```

  在EnvWrapper 里面把所有的Env 作为变量传入进来, 把所有的接口都实现了一边这个有什么用呢?

  ```c++
  class EnvWrapper : public Env {
  public:
    // Initialize an EnvWrapper that delegates all calls to *t
    explicit EnvWrapper(Env* t) : target_(t) { }
    virtual ~EnvWrapper();
  ```

  这样在实现一个新的Env 的时候, 可以只实现哪些想要实现的接口, 如果不想实现这个接口, 那么你的这个接口就是你默认传进来的那个Env* t 里面的那个实现
  比如
  class InmemoryEnv : public EnvWrapper {
  }

  然后这里InmemoryEnv 的构造函数是传进来的是 PoxisEnv, 那么这个时候如果我InmemoryEnv 里面不需要写任何东西, 这里InmemoryEnv 都包含了所有的PosixEnv 的实现. 所以是非常方便的, 但是也需要看到这里是有性能损失的

* 在leveldb 的DB 类里面同样看到了基类是虚基类, 但是在实现子类的时候, 又去把虚基类里面的纯函数给实现的情况?

   就像函数上面的注释所说的是为了方便集成下来子类有一个默认的实现方式, 同时又提醒子类必须自己去实现这个函数的一种做法

  ```c++
  // Default implementations of convenience methods that subclasses of DB
  // can call if they wish
  Status DB::Put(const WriteOptions& opt, const Slice& key, const Slice& value) {
    WriteBatch batch;
    batch.Put(key, value);
    return Write(opt, &batch);
  }

  Status DB::Delete(const WriteOptions& opt, const Slice& key) {
    WriteBatch batch;
    batch.Delete(key);
    return Write(opt, &batch);
  }

  ```

* 为什么同样是接口类 db.h, iterator.h, filter_policy.h. 而只有db.h 里面提供static 方法来进行创建, 而iterator.h 和 filter_policy.h 都是提供在函数外的方法

  ```c++
  // db.h
  class DB {
  public:
   // Open the database with the specified "name".
   // Stores a pointer to a heap-allocated database in *dbptr and returns
   // OK on success.
   // Stores NULL in *dbptr and returns a non-OK status on error.
   // Caller should delete *dbptr when it is no longer needed.
   static Status Open(const Options& options,
       const std::string& name,
       DB** dbptr);

  // filter_policy.h
  extern const FilterPolicy* NewBloomFilterPolicy(int bits_per_key);

  // iterator.h
  // db_impl.h:
  virtual Iterator* NewIterator(const ReadOptions&);

  // two_level_iterator.h
  // Return a new two level iterator.  A two-level iterator contains an
  // index iterator whose values point to a sequence of blocks where
  // each block is itself a sequence of ke	y,value pairs.  The returned
  // two-level iterator yields the concatenation of all key/value pairs
  // in the sequence of blocks.  Takes ownership of "index_iter" and
  // will delete it when no longer needed.
  //
  // Uses a supplied function to convert an index_iter value into
  // an iterator over the contents of the corresponding block.
  extern Iterator* NewTwoLevelIterator(
     Iterator* index_iter,
     Iterator* (*block_function)(
         void* arg,
         const ReadOptions& options,
         const Slice& index_value),
     void* arg,
     const ReadOptions& options);

  ```

    总结出来就是如果你只是实现接口, 并且只需要唯一的一个实现的话, 比如 db->DBImpl, 那么只要在类里面提供一个静态的方法就可以, 如果DBImpl 有多种实现方式的话, 使用这种方式是有问题的, 因为各个使用方式里面都需要实现一个DB::Open 这个方法, 肯定有冲突的. 但是比如想Iterator, FilterPolicy 这种需要提供多种的实现方式的, 就在不同的方式里面提供一个不同的类似Create 的函数.

    同时这里由于DB::Open() 这个函数需要访问类里面的私有成员函数, 因此必须写成类里面的静态成员函数才可以, 如果写成外部函数是不可以的
