---
layout: post
title: "levelDB中用到的迭代器模型"
---

### 迭代器的设计模式是一种很常用的设计模式. leveldb的实现里面就用到了.

Iteartor模式:提供一种方法顺序访问一个聚合对象中的各个元素, 而又不暴露其内部的表示.

在leveldb 里面include/iterator.h 定义了 iterator.h 的基类, leveldb 里面有memtable, block 等数据格式. 都是通过定义一个自己的iterator来实现对这一个数据的访问.


比如这里的block类:
在每一个类的里面都定义了一个             

```c++
Iterator* NewIterator(const Comparator* comparator);
```

然后在 NewIterator 的实现里面

```c++
Iterator* Block::NewIterator(const Comparator* cmp) {
    if (size_ < 2*sizeof(uint32_t)) {
        return NewErrorIterator(Status::Corruption("bad block contents"));
    }
    const uint32_t num_restarts = NumRestarts();
    if (num_restarts == 0) {
        return NewEmptyIterator();
    } else {
        return new Iter(cmp, data_, restart_offset_, num_restarts);
    }
}
```
会具体的返回一个在这个类内部的一个指针, 这个指针在这个block类的内部具体定义的.
这个Iter指针实现了需要的所有的操作

```c++
class Block::Iter : public Iterator {
  private:
    const Comparator* const comparator_;
    const char* const data_;      // underlying block contents
    uint32_t const restarts_;     // Offset of restart array (list of fixed32)
    uint32_t const num_restarts_; // Number of uint32_t entries in restart array


    // current_ is offset in data_ of current entry.  >= restarts_ if !Valid
    uint32_t current_;
    uint32_t restart_index_;  // Index of restart block in which current_ falls
    std::string key_;
    Slice value_;  // 这里就会直接存这个value_的值
    Status status_;
```

Next(), Prev(), Value() 等等操作

比如这里Next()的实现的时候, 没进行一个Next()操作, 就会调用ParseNextKey(), 然后这个函数就会更新value_的值. 所以调用Value()的时候直接返回 value_即可.

```c++
virtual void Next() {
  assert(Valid());
  ParseNextKey();
}
```



同样在这个dbImpl这个类里面, dbImpl的iterator的定义就在db_impl.cc里面定义.


使用这种迭代器模型, 我们调用的时候就可以不用知道这个具体的结构, 直接用一个Iterator, 就可以使用这个类

```c++
    Iterator* iter = mem->NewIterator(); //这个是memtable 
    Iterator* iter = table_cache_->NewIterator(ReadOptions(), output_number, current_bytes); //table_cache 这个类
```
