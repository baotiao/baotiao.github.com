---
layout: post
title: "File System Summarize"
description: "File System Summarize"
category: tech
tags: [os, filesystem]
---



最近在看关于file system 的一些东西, 总觉得这个领域发展的比较成熟, 应该可以从这个领域学到东西应用到其他地方. 看了一些论文发现没有综述性质的文章, 只能自己进行分类了, 后续继续更新...

### journal file system

xfs, ffs(unix fast file system), ext3, ext4

为了防止磁盘文件的丢失, 磁盘不可能每次都刷新. 所以有两种思路做recovery

* synchronous meta-data update + fsck
* logging (xv6 and linux ext3)

journal 不能保证所有的数据都不丢失, 但是journal 可以让让file system 保证一个一致的, 可用的状态, 不会出现某一个垃圾的block

journal file system 一般会把journal 日志放在不同于data的盘上, 这样可以用journal 日志来恢复data目录上的数据, 而log-structure file system 因为Log 也是它的数据, 所以所有的数据放在同一个目录下面

一般用 journal 来记录的只有metadata 的信息, 不会记录具体的数据信息, 因为如果记录具体的数据信息的话. 一次正常的写入就相当写入了两次, 就会有明显的写放大的问题

ffs
使用cylinder group 的目的是因为, 使用cylinder group 来存数据的话, 那么磁头是不需要旋转的.
磁盘移动的比较慢的原因:
1. 横向移动, 就是从一个track 移动到 另一个 track
2. rotational movement, 就是在sector 之间移动, 这个也是比较慢, 不过比横向移动还是要来得快

cylinder group: All of the data that can be read on the disk without moving the head. Comes from multiple patters

ffs 是第一个考虑到了具体的数据文件的位置和磁盘的具体位置的关系
ffs superblock contained datailed disk geometry information allowing FFS to attempt to perform better block placement

ffs 是把所有的inode map的信息放在disk 上面的一个固定的位置, 而lfs 则是把这个imap信息一直更新, 放在Log的最末尾
![](http://i.imgur.com/KbfeHJD.png)



在磁盘结构里面的 inode, direct blocks, double-indirect blocks, single-indirect block 的结构存在的目的都是为了允许文件系统里面存在任意多的动态的block. 如果都只是存在direct blocks 的话, 那么需要提前分配好所有的inode 和 block 的空间, 然后inode 指向对应的block, 这样就是old filesystem 的做法, 这样的做法首先浪费大量的空间, 第二整个磁盘的大小就受到了限制

我们可以具体算一下这个single-level indirect table, double-level indirect table 所能索引的磁盘的大小, 以及ffs具体的磁盘的大小
![](http://i.imgur.com/i0ZllJp.png)

### log-structured file system

NILFS(New implementation of log-structure file system)
F2FS

在lfs 的观点看来, ffs 最大的一个问题就是每一次创建一个文件, ffs 需要存在5次的写入操作, 又因为ffs 的文件的meta信息, 文件的data信息是在不同的block上, 因此那么大量的时间就花费在seek到相应的Block的时间上了

而lfs的做法就是将这5次操作缓存在一个cache里面, 那么等写入的时候一次顺序的写入到磁盘上, 因为lfs 不会将meta信息和data信息分开, 所以只需要一次的磁盘io操作就可以

log-structured 的最基本的思路就是一直将数据顺序写入到磁盘中, 那么对应的就是一个文件有一个inode信息, 然后一个inode负责多个block, 那么在进行过一次更新以后, 会生成一个新的inode. 那么如果知道哪些inode 是新的, 哪些inode是旧的呢, 就会有imap, 用来记录哪些inode 是新的, 哪些inode是旧的, 并且每次更新以后都会去更新这个imap的信息. 这里会将imap的信息切成多份, 然后有一个checkpoint 会记录这个所有的imap存放的地方, 并且操作系统经常会将这个imap的地址放在内存中, 所以读取的时候还是很快的. 因为这个imap只是保存了inode的信息, 所以是足够小的

In Unix FFS each inode is at a fixed location on disk; given the identifying number for a file, a simple calculation yields the disk address of the file’s inode. In contrast, Sprite LFS doesn’t place inodes at fixed positions; they are written to the log. Sprite LFS uses a data structure called an inode map to maintain the current location of each inode.
这个解释了为什么FFS 不需要一个inode map, 而 lfs 需要一个inode map的原因

lfs 做cleaning 的时候, 是把所有的disk 分成多个segment, 然后是以segment 为维度做cleaning. 为什么这么做呢?
1. 做cleaning 的时候, 一般是拿一个有脏数据的磁盘 和 一个空闲的磁盘直接做cleaning, 这样比较方便, 不用在只有一个内存里面做
2. 如果以一整个disk 为维度来做, 太大

在每一个segment 里面会有一个 segment summary 记录这个segment 里面的信息

所以 lfs 最大的devil 就是clean, 什么时候做clean
因为cleaning 的存在, 所以我们很难对lfs 系统进行benchmark

lfs 的checkpoint 就是用来解决ffs在crash 以后如何恢复数据的问题, 因为ffs 在crash 以后只能全部重新扫描磁盘才能恢复

Sprite LFS uses a two-phase process to create a checkpoint. First, it writes out all modified information to the log, including file data blocks, indirect blocks, inodes, and blocks of the inode map and segment usage table. Second, it writes a checkpoint region to a special fixed position on disk. The checkpoint region contains the addresses of all the blocks in the inode map and segment usage table, plus the current time and a pointer to the last segment written.

但是只是从checkpoint 恢复解决不了在checkpoint 之后写入数据的问题, 而且lfs 默认的checkpoint 的时间是30s. 所以为了尽可能多的恢复数据, 引入了Roll-forward 机制

Roll-forward 机制就是为了恢复尽可能多的在checkpoint 以后的数据

ffs 的数据的回复基本是通过fsck来做的. fsck 做的方法就是将整个磁盘需要扫描一遍

### copy-on-write file system
zfs, btrfs

### other:

1. fsck(file system consistency check) 是一个用来检测文件系统是否正常的一个工具

2. debugfs 一个用来看文件系统是否有问题的工具
sudo debugfs -R "show_super_stats" /dev/sdd
可以查看某一个磁盘的具体信息

3. 目前现在还在争论之中的事情是, 有os 来控制这个disk的具体的写入, 还是由disk 控制数据的写入, 原因1, os更知道哪些时刻的负载等信息, 那么可以具体的告诉disk 你把这个数据放哪. 而disk的优势在于disk对disk自己的内部的结构更加的了解

- 为什么文件系统需要存在attribute 和 data区分开来的概念, 原因也是因为 attribute 比较小, 所以可以直接将这部分的信息存放在inode里面, 而data信息是实际存放的地址. 因此会将这两个内容区分开来
