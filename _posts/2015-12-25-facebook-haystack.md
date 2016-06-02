---
layout: post
title: "Haystack object storage"
---

### HayStack
HayStack 是facebook 的一个针对图片存储的object storage. 以下大概是HayStack设计


- 图片大部分的应用场景是 只写一次, 然后经常读取, 以及从来不会对图片进行修改. 并且极其少的可能去修改这个图片
- Haystack 主要包含Haystack Directory, Haystack Cache, Haystack Store. 那么读写的流程分别是
![Imgur](http://i.imgur.com/Xa1E5zg.png)

![Imgur](http://i.imgur.com/Hjn71u5.png)

可以看出这里Haystack Directory 里面应该保存的是数据的元信息

- Haystack Store 可以说自己实现了一套存取图片的引擎. 如果只是用操作系统的文件系统, 存在的问题是.
    - 某一个目录下面存放大量的图片的文件, 那么由于文件系统里面目录也是跟保存在一个block里面, 那么就会造成这个目录的node下面的data block的内容过大, 那么为了取到这个目录的meta信息, 就需要读取多个block 才能读取得到需要的内容
    - 只是用文件系统来保存图片的话, 为了读取到一次图片, 我们需要首先读取对应的目录的inode数据, 然后是目录的data block, 然后从里面找到我们需要的文件, 然后读取这个文件的inode, 然后是读取这个文件的data block. 从这里可以看出, 我们为了找到一个文件, 需要经过多次的磁盘IO最终才能找到这个数据.
    - 如果我们存的图片不大, 那么就会找出大量的小文件的情况发生
    - 通过后续的计算可以看出,比如在xfs系统下面建立一个文件xfs inode 信息大小是536 byte, 而如果可以通过自己实现我们需要的元信息的的大小可以做到40 bytes

   那么Haystack Store 的主要的一个事情就是建立一个大文件, 然后在这个大文件头建立SuperBlock的信息, 然后底下的数据模块具体放文件的内容. 那么在这个大文件里面找到某一个文件的信息就需要一个Index 的信息
![Imgur](http://i.imgur.com/Hyowus5.png)

这个是Index File 的信息, Index File 里面needle 的数据的顺序必须严格和数据文件的needle 一致
![Imgur](http://i.imgur.com/OyAWZOt.png)
Since index records do not reflect deleted photos, a Store machine may retrieve a photo that has in fact been deleted. To address this issue, after a Store machine reads the entire needle for a photo, that machine can then inspect the deleted flag. If a needle is marked as deleted the Store machine updates its in-memory map- ping accordingly and notifies the Cache that the object was not found.

所以从这里可以看出来, 具体的文件是否被删除的信息是存放在volume file里面的, 我有一个疑惑? 为什么不直接将这个文件是否被删除的flag存放在index file 里面呢

总结: HayStack Store的核心其实是自己来分配这个磁盘空间, 就是memcache 一样, 因为作为应用层, 我自己对我当前的应用的需求更加的了解, 而kernel的内存分配规则是针对通用的应用的需求. 因此memcache的做法就是自己提前申请一块大内存, 然后在这块大内存上面自己进行内存分配. 那么HayStack Store 的做法就是自己提前申请一块大的磁盘空间, 然后在这个大的磁盘空间上面进行空间分配, 因为HayStack Store 对这个磁盘的需求的理解是由于kernel的

- Haystack 的优化也主要在于会对文件进行compact, 这里的compact指的是将这个volume file里面标记成删除的文件删除掉, 还有一个是尽可能的减少一个文件需要的inode信息的大小
- Haystack 的思想和 log struct file system 很像, 就是顺序写入到磁盘, 然后大部分的读取是会命中cache的, 这样读的时候虽然需要查找多次才能读到数据, 由于cache的命中率高. 所以还是可以接受的. 并且Haystack 由于应用的场景是图片. 所以这种场景对于写入的数据修改的情况就更少了.
