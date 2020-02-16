---
layout: post
title: MySQL lock-free hashtable implementation
summary: MySQL lock-free hashtable implementation
 
---


### MySQL lf_hash



核心想法:

首先, 实现一个无锁的有序 list 在操作系统支持cas 是atomic 的场景下是很容易的, 最差的做法就是对list 上所有元素执行 cas, 然后插入到对应的位置



实现lock hash table 困难点在于如何处理扩容操作, 因为扩容的那个时候需要迁移的item 个数肯定不止一个, 需要有大批量的迁移, 这个时候就只能加一个mutex, 等元素迁移完成以后, 再把锁放开, 这样就无法lock free

lf_hash 核心想法:

our algorithm *will not move the items among the buckets*, rather, it *will move the buckets among the items*.

也就是说不去移动buckets 里面的item, 而是去移动这个bucket, 具体到实现中就是所有的hash_table 中的元素都是在一个有序链表里面, 然后每一个bucket 有一个哨兵指针指向list 里面的元素, 哨兵指向的元素就是该bucket 的第一个元素

![Imgur](https://i.imgur.com/EuFYlxN.jpg)



那么这里如何解决的呢?

lf_hash 核心思想在相同bucket 下面的元素是有序的,  然后扩容的时候, 必须是按照2倍扩容.   比如原来的bucket size = 4,   有三个item 取完hash 是 9, 13, 17. 那么在bucket size = 4 的时候, 他们是在同一个bucket 上,  在这个bucket 上这个list 的顺序是 9 => 17 => 13.  为什么这样排列呢?

因为当扩容的时候bucket size = 8 的时候,  9, 17 依然还在同一个bucket 1中, 而 13 在bucket 5 中, 那么这个时候只需要在17 前面插入一个哨兵隔离开就可以, 这样子就是一个atomic 操作就可以实现的了



在FIG 1 中,  有4 个bucket,  上面的list 就是所有的元素. 可以想象在这个bucket size = 2 的时候, 两个队列是

0: 8(00010001)=>2(01000001)

1: 9(10010001)=>13(10110001)=>7(11100001)

这里排列的方法就是二进制的reserve 顺序(最后一位是标志位, 用来标志是item 还是 bucket 的哨兵slot).

为什么可以这样?

因为当bucket size 扩大一倍了以后, 就是根据最后一位mod 2 是0, 1 区分开来而已, 比如bucket size = 2 的时候,

9(1001), 13(1101), 7(0111)  mod 2 都是看最后一位, 都是1 因此到了同一个bucket.

当bucket size * 2 的时候,  也就是 mod (size * 2),  那么就是看前面一位, 这里 9(1001), 13(1101) 是0, 而7(0111)是1, 因此在Bucket size 扩容的时候, 他们是在不同的bucket 中.

知道了这样的关系以后, 就可以提前按照这样的顺序将元素进行排列.

可以看到在不断扩容的过程, 就是看二进制的从后到前排列的过程, 因为排序就可以根据二进制的reverse 进行排列就可以了.


然后当bucket 扩容的时候, 其实就是 2, 3 这两个bucket 的指针插入队列中的某个位置


Reference:

http://people.csail.mit.edu/shanir/publications/Split-Ordered_Lists.pdf
