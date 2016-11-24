---
layout: post
title: 将this 指针传给子类的问题
summary: 将this 指针传给子类的问题

---
### 将this 指针传给子类的问题

最近实现代码的时候经常会遇到这种问题需要大量的将this指针传给类底下的成员变量, 因为成员变量需要用到父类里面的成员. 抽象出来是这种情况

```c++
class A {
  class B {};
  B *b(d_, e_, str_);
  class C {};
  C *c(e_, str_);

  int d_;
  int e_;
  std::string str_;
};

```

这里A 类的两个子类 B, C 都会使用到A类里面的成员 d\_, e\_, str\_. 所以我们经常要初始化的时候去给两个子类去传这个变量, 那么这个时候经常为了方便就直接将this 指针往下传, 变成这种

```c++
class A {
  class B {};
  B *b(this);
  class C {};
  C *c(this);

  int d_;
  int e_;
  std::string str_;
};

```

ceph 的代码里面就大量的这种将this 指针往下传的代码, 比如FileStore 里面sync_thread, op_wq 就是这种关系. 

#### 直接传this 指针有什么不好呢?

1. 父类和子类互相依赖, 封装的不是很好
2. 由于子类需要访问父类里面的成员, 常见的做法就是把这些变量做成public, 或者将B, C作为A类的friend 类, 这样就违法的封装的特点. 第一版floyd 就是这个做法

```c++
class RaftConsensus {
public:
	class LeaderDiskThread : public pink::Thread {
	public:
		LeaderDiskThread(RaftConsensus* raft_con);
		~LeaderDiskThread();

		virtual void* ThreadMain();

	private:
		RaftConsensus* raft_con_;
	};
	LeaderDiskThread* leader_disk_;
	friend class LeaderDiskThread;
	friend class ElectLeaderThread;
	friend class PeerThread;
...
```

最简单的做法就是将B, C 类里面的内容往外提, 那么B, C类里面的内容就可以直接访问d\_, e\_, str\_这些内容了, 但是更多的情况是 B, C 类是从其他类继承的, 这个时候就不能把B, C 类里面的内容往外提

```c++
class A {
  class B : public Thread {};
  B *b(this);
  class C : public Thread{};
  C *c(this);

  int d_;
  int e_;
  std::string str_;
};

```



#### 那么比较好的解决方法是什么样子的呢?

我觉得leveldb 里面的Options 这个封装就比较好, Options 将需要访问的公共的成员变量都放在一个对象里面, 然后将Options 这个对象往子类传, 比如

DBImpl 这个对象里面有 options, env\_

DBImpl 底下的TableCache, VersionSet 也需要这个options, env\_ 这两个对象, 那么Leveldb 的做法就是将子类都需要访问的内容放在一起, 然后将这个对象以指针的形式往下传, 因为通常如果子类对这些对象进行了修改以后, 其他对象应该也是要能够看到的.

```c++
class DBImpl : public DB {
public:
...
  Env* const env_;
  const InternalKeyComparator internal_comparator_;
  const InternalFilterPolicy internal_filter_policy_;
  const Options options_;  // options_.comparator == &internal_comparator_

  // table_cache_ provides its own synchronization
  TableCache* table_cache_;

  VersionSet* versions_;
};

TableCache::TableCache(const std::string& dbname,
    const Options* options,
    int entries)
  : env_(options->env),
  dbname_(dbname),
  options_(options),
  cache_(NewLRUCache(entries)) {
  }

VersionSet::VersionSet(const std::string& dbname,
    const Options* options,
    TableCache* table_cache,
    const InternalKeyComparator* cmp)
  : env_(options->env),
  dbname_(dbname),
  options_(options),
  table_cache_(table_cache),
  icmp_(*cmp),
...
```

所以比较好的解决方法是把这些要把子类访问的对象放在一个struct 里面, 比如Options 这种, 或者像Env 这种里面都是一些Public的方法, 然后传给子类的对象自己去.

这样写以后代码就清晰多了, 但是做的也就更细了

所以还是看到一个东西是这个样子不重要, 最重要的应该是了解这个东西为什么是现在这个样子.
