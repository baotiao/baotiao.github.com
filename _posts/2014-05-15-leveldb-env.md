---
layout: post
description: "Leveldb env 对文件系统的封装"
category: tech
---
LevelDB的Env主要封装了操作系统的文件接口, 后台线程的调度, 以及锁等实现
主要封装了如下三个文件类型  

为什么要封装不同的文件类型, 因为只有根据文件的类型不同, 进行不同的封装才可以把性能提高, 比如:随机写文件和顺序写文件, 顺序写我们就知道这个文件的修改只有在文件的末尾, 那么我们就可以Mmap文件末尾的部分空间, 然后进行文件写入, 这样既不会浪费空间, 性能也较高.

1. RandomAccessFile  随机读文件 (sst文件的读取) 
2. SequentialFile 顺序读文件 (DB的日志文件, mainfest文件 这些文件的读取)
3. WritableFile 顺序写文件 (DB的日志文件, sst文件, mainfest文件. 这些文件的写入都是这个WritableFile 封装的)

### RandomAccessFile
RandomAccessFile 有两种实现, 一种是Mmap, 一种是pread

1. Pread 的实现方式很简单, 之所以用Pread 就是为了防止多线程读写, lseek和read之间不是原子操作产生的问题

```c++
virtual Status Read(uint64_t offset, size_t n, Slice* result,
        char* scratch) const {
    Status s;
    ssize_t r = pread(fd_, scratch, n, static_cast<off_t>(offset));
    *result = Slice(scratch, (r < 0) ? 0 : r);
    if (r < 0) {
        // An error: return a non-ok status
        s = IOError(filename_, errno);
    }
    return s;
}
```


2. Mmap 的实现方式是将新建的文件Mmap到虚拟内存空间, 然后在内存里面读取, 从代码里面可以看出默认的RandomAccessFile用的是Mmap的方式, 具体的原因肯定是Mmap的性能优于Pread 的方式

```c++
virtual Status NewRandomAccessFile(const std::string& fname,
        RandomAccessFile** result) {
    *result = NULL;
    Status s;
    int fd = open(fname.c_str(), O_RDONLY);
    if (fd < 0) {
        s = IOError(fname, errno);
    } else if (mmap_limit_.Acquire()) { // 这里是判断是否还能够继续Mmap, 规定默认的Mmap文件的个数是1000个
        uint64_t size;
        s = GetFileSize(fname, &size);
        if (s.ok()) {
            void* base = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
            if (base != MAP_FAILED) {
                *result = new PosixMmapReadableFile(fname, base, size, &mmap_limit_);
            } else {
                s = IOError(fname, errno);
            }
        }
        close(fd);
        if (!s.ok()) {
            mmap_limit_.Release();
        }
    } else {
        *result = new PosixRandomAccessFile(fname, fd);
    }
    return s;
}
```
 
在Mmap的实现方式里面, 有一个MmapLimiter, 这个MmapLimiter主要用处就是防止你Mmap的文件过多, 造成虚拟内存空间被跑满, 或者是由于虚拟内存空间使用过多, 造成内核的性能问题. 所以这里最多允许Mmap 1000个文件. 其中在MmapLimiter里面需要用到Mutex, AtomicPointer主要为了保证修改这个Mmap的限制文件个数是原子操作

### SequentialFile
SequentialFile 主要就是fread来实现

### WritableFile
WritableFile 的主要封装是顺序写文件, PosixMmapFile就是用Mmap的封装来实现, 主要思路是因为是顺序写, 所以Mmap一个writefile大小的空间, 那么每次的写入就是Append()操作, 这个操作就直接通过memcpy来拷贝到内存中即可. 如果写入数据超过了writefile的大小, 那么就先ftruncate 将writefile的大小扩大(这里每次扩大的范围是一个增长因子, 从65535开始, 2倍的增长, 最大是1M),然后将原先Mmap的空间释放的, 把writefile新添加的地址Mmap到新的地址空间. 这样做的好处有

1. 性能比write快. 具体的测试数据  
每次写入1024字节, 总共写入1000000次  
[----------debug--------][writable.cc:224]mmap cost time 6594890  
[----------debug--------][writable.cc:239]write cost time 15244794  
可以看出mmap 写1G的数据需要6.5s, 而write则需要15.2s

2. 通过动态的扩展Mmap的空间的方式, 不会使用过多的虚拟内存空间.

当然这个PosixMmapFile 也支持随时将写入的内存flush到磁盘上. 通过msync随时将结果Flush到磁盘

主要的Append()函数实现方式:

```c++
virtual Status Append(const Slice& data) {
    const char* src = data.data();
    size_t left = data.size();
    while (left > 0) {
        assert(base_ <= dst_);
        assert(dst_ <= limit_);
        size_t avail = limit_ - dst_;
        if (avail == 0) { // 这里判断当前Mmap的空间是否还有可用的空间, 也就是当前writefile是否被写满了
            if (!UnmapCurrentRegion() || // 被写满以后先Unmap将当前的Mmap去掉
                    !MapNewRegion()) { // 重新Mmap新的地址空间, 这里Mmap的初始地址从file_offset_开始, 也就是从
                                      // writefile文件新增的地址开始Mmap
                return IOError(filename_, errno);
            }
        }

        size_t n = (left <= avail) ? left : avail;
        memcpy(dst_, src, n);
        dst_ += n;
        src += n;
        left -= n;
    }
    return Status::OK();
}
```
