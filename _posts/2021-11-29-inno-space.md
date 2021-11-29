---
layout: post
title: MySQL InnoDB space file
summary: MySQL InnoDB 物理文件管理
---

InnoDB 最后的数据都会落到文件中.

整体而言InnoDB 里面除了redo log 以外都使用统一的结构进行管理, 包括system tablespace(ibdata1), user tablespace(用户表空间), undo log, temp tablespace. 这个结构我们统称space file.



接下来会4篇文章介绍InnoDB 主要的从文件, page, index, record 在具体文件里面是如何分布的, 这里大量引用了Jeremy Cole 里面的图片和文章的内容.

同时介绍的过程会结合inno_space 工具直观的打印出文件的内部结构.

什么是inno_space?

[inno_space ](./https://github.com/baotiao/inno_space) 是一个可以直接访问InnoDB 内部文件的命令行工具,  可以打印出文件的内部结构.

Jeremy Cole 用ruby 写了一个类似的工具, 不过不支持MySQL 8.0, 并且ruby 编译以及改动起来特别麻烦, 所以用cpp 重写了一个. inno_space 做到不依赖任何外部文件, 只需要make, 就可以得到可执行文件, 做到开箱即用.

inno_space 除了支持打印出文件的具体结构之外, 同时还支持修复 corrupt page 功能, 如果遇到InnoDB 表文件中的page 损坏, 实例无法启动的情况, 如果损坏的只是leaf page, inno_space 可以将corrupt page 跳过, 从而保证实例能够启动, 并且将绝大部分的数据找回.

inno_space 还提供分析表文件中的数据情况, 是否有过多的free page, 从而给用户建议是否需要执行 optimize table 等等

具体可以看代码, 在github 上面开源: https://github.com/baotiao/inno_space/commits/main



1. InnoDB space file 也就是整个InnoDB 文件系统的管理, 介绍.ibd 文件的基础结构. [InnoDB space file](./InnoDB space file.md)
2. InnoDB page management  具体的在InnoDB file space 这些16kb 大小的page 是如何管理的 [Page management](./InnoDB page management.md)

3. InnoDB Index page 上面讲了这16kb 的page 如何管理, 那么我们细看一下最常见的page 类型, Index Page 存的是用户表空间的数据,  这些Index Page 是如何维护成一个table 的数据 [Index page](./InnoDB Index page.md)

4. InnoDB record 是具体在InnoDB page 里面, Mysql 里面的record 是如何保存在InnoDB page 里面的 [InnoDB record](./InnoDB record.md)



这篇文章只描述InnoDB file space, 接下来会有文章介绍InnoDB page management,  InnoDB page, InnoDB record


#### 1. InnoDB space file 基本结构



**Page**

在InnoDB 里面, 16kb 大小的page 是最小的原子单元

其他的大小都是在page 之上, 因此有:

1 page = 16kB = 16384 bytes

1 extent = 64 pages = 1 MB

FSP_HDR  page = 256 extents = 16384 pages = 256 MB



page 有最基础的38字节的 FIL Header, 8字节的FIL Trailer

<img src="https://i.imgur.com/NxR6eb3.jpg" alt="Imgur" style="zoom: 50%;" />

主要的内容包括:

1. Checksum: 这个page 的checksum, 用来判断page 是否有corrupt

2. Page Number: Page Number 可以计算出在文件上的偏移量, 一个page 是否初始化了, 也可以看这个page number 是否设置对了, 这个值其实是冗余的, 根据file offset 可以算出来, 所以这个值是否正确, 就可以知道这个page 是否被初始化了

3. Previous Page/Next Page: 这个只有在Index page 的时候才有用, 而且只有leaf page 的时候才有用, non-leaf page 是没用的, 大部分类型的page 并没有使用这个字段.  

4. LSN for last page modification: 刷脏的时候, 写入这个page 的 newest_modification_lsn

   ​	mach_write_to_8(page + FIL_PAGE_LSN, newest_lsn);

5. Page Type: 这个page 具体的类型, 比如是btree index leaf-page, undo log page,  btree index non-leaf page, insert buffer, fresh allocated page, 属于ibdata1 的system page 等等. Page Type 最重要, 决定这个page 的用途类型, 里面很多字段就不一样了

6. Flush LSN:  保存的是已经flush 到磁盘的page 的最大lsn 信息. 只有在space 0 page 0 这个page 里面有用, 其他地方都没用.. 什么用途?什么时候写入? 什么时候读取?

   在进行shutdown 的时候, 或者执行force checkpoint的时候通过 fil_write_flushed_lsn_to_data_files 写入.

   用途是在启动的时候, 读取这个flush lsn, 可以确保这个lsn 之前的page 已经刷到磁盘了, 从这个flush lsn 之后的redo log 才是uncheckpoint redo log, 但是其实redo log 里面已经有了 checkpoint 的信息了, 为何还需要这个字段?

   logs_empty_and_mark_files_at_shutdown => 

   在实例启动的时候, innobase_start_or_create_for_mysql => open_or_create_data_files => fil_read_first_page

   fil_read_first_page 里面会读取出这个lsn 信息, 用于更新启动的时候的 min_flushed_lsn, max_flushed_lsn. 因为这个时候redo log 模块还没有初始化,  可以拿这个两个Lsn 做一些简单的判断

   整体来看, 这个字段目前已经没啥用了, 但是每一个page 都占用了8字节的空间, 还是比较浪费, 可以充分复用

7. Space ID: 当前Page 所属space ID (8.0 里面已经将该字段删除了)



通过inno_space 可以看到相应的结构:

```
./inno -f ~/git/primary/dbs2250/sbtest/sbtest1.ibd -p 10

==========================block==========================
FIL Header:
CheckSum: 2065869235
Page number: 10
Previous Page: 9
Next Page: 11
Page LSN: 554513658770
Page Type: 17855
Flush LSN: 0
```





**Space file**

一个space file 就是2^32 个page 的合集, 连续64个page 叫做extent, 256个连续的extent 会有一个XDES(extent descriptor) 进行管理, 第一个XDES 又叫做FSP_HDR, 还有一些额外的信息.

下图就是这个基本文件组织结构的描述, 无论是undo space, system space, 用户的table space 都是这样结构

<img src="../../../Library/Application Support/typora-user-images/image-20211118052832966.png" alt="image-20211118052832966" style="zoom:40%;" />

所有的space file 前3个page 都是一样.

page 0 是 FSP_HDR(file space header)

page 1 是 insert buffer bitmap

page 2 是 inode page, 下一节会介绍



**The system space**

system space 的space id = 0, 文件名叫 ibdata1, 也就是系统文件.



![Imgur](https://i.imgur.com/l3UHMqR.jpg)

page 0, 1, 2 这3个page 所有的space file 都一样

在system space 里面接下来的3, 4, 5 等等page 也都是有指定的用途

page 3 存放的是insert buffer 相关信息

page 4 存放的是insert buffer tree 的root page

page 5 存放的是trx_sys 模块相关信息, 比如最新的trx id, binlog 信息等等.

page 6 存放的是FSP_FIRST_RSEG_PAGE_NO, 也就是undo log rollback segment的header page. 其他的undo log rollback segment 都在不同的undo log 文件中

<img src="https://i.imgur.com/ScLs3Oj.jpg" alt="Imgur" style="zoom:40%;" />

page 7 存放的是 FSP_DICT_HDR_PAGE_NO, 存放的是DD 相关的信息

page 64-127 是first 64 个double write buffer 的位置

page 128-191 是second 64个double write buffer 的位置

剩下的其他page 就有可能被申请成Undo log page 等等了



通过inno_space 打开 ibdata1文件可以观察到如下的信息

```
File path /home/zongzhi.czz/git/primary/log2250/ibdata1 path
File size 209715200
start           end             count           type
0               0               1               FSP HDR
1               1               1               INSERT BUFFER BITMAP
2               2               1               INDEX NODE PAGE
3               3               1               SYSTEM PAGE
4               4               1               INDEX PAGE
5               5               1               TRX SYSTEM PAGE
6               7               2               SYSTEM PAGE
8               8               1               SDI INDEX PAGE
9               12799           12790           FRESHLY ALLOCATED PAGE
```



打开一个普通的用户表空间, 可以看到如下的结构.

```
└─[$] ./inno -f ~/git/primary/dbs2250/sbtest/sbtest1.ibd -c list-page-type
File path /home/zongzhi.czz/git/primary/dbs2250/sbtest/sbtest1.ibd path, page num 0
page num 0
==========================space page type==========================
File size 2604662784
start           end             count           type
0               0               1               FSP HDR
1               1               1               INSERT BUFFER BITMAP
2               2               1               INDEX NODE PAGE
3               3               1               SDI INDEX PAGE
4               16383           16380           INDEX PAGE
16384           16384           1               XDES
16385           16385           1               INSERT BUFFER BITMAP
16386           31990           15605           INDEX PAGE
31991           31999           9               FRESHLY ALLOCATED PAGE
32000           32767           768             INDEX PAGE
32768           32768           1               XDES
32769           32769           1               INSERT BUFFER BITMAP
32770           49151           16382           INDEX PAGE
49152           49152           1               XDES
49153           49153           1               INSERT BUFFER BITMAP
49154           65535           16382           INDEX PAGE
65536           65536           1               XDES
65537           65537           1               INSERT BUFFER BITMAP
65538           81919           16382           INDEX PAGE
81920           81920           1               XDES
```

下一篇物理页管理我们会更详细的介绍.



**File Per Table**

InnoDB 常见的file per table 模式下. 一个table 对应一个.ibd 文件.

![Imgur](https://i.imgur.com/I2vFSGn.png)

page 0, 1, 2 这3个page 所有的space file 都一样

page 3 一般是 primary index root page.

page 4 一般是 secondary index root page. 当然这里是create table 就指定的时候, 比如如下 page 4 一般是k_1 这个index 的root page

```mysql
Create Table: CREATE TABLE `sbtest1` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `k` int(11) NOT NULL DEFAULT '0',
  `c` char(120) NOT NULL DEFAULT '',
  `pad` char(60) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `k_1` (`k`)
) ENGINE=InnoDB AUTO_INCREMENT=237723 DEFAULT CHARSET=latin1
1 row in set (0.00 sec)
```

如果后面运行过程中再加的新的 secondary index, 新的Index的root page 那就不会是连续着的, 而是分散在其他page 上了

alter table sbtest1 add index idx_c(c);

比如执行alter table 以后, 额外增加的一个index, 通过inno_space 工具可以看到每一个index 的root page 所在等等

```
Example 2:
./inno -f ~/git/primary/dbs2250/sbtest/sbtest1.ibd -c index-summary
File path /home/zongzhi.czz/git/primary/dbs2250/sbtest/sbtest1.ibd path, page num 0
==========================Space Header==========================
Space ID: 15
Highest Page number: 158976
Free limit Page Number: 152256
FREE_FRAG page number: 24
Next Seg ID: 7
File size 2604662784
========Primary index========
Primary index root page space_id 15 page_no 4
Btree hight: 2
<<<Leaf page segment>>>
SEGMENT id 4, space id 15
Extents information:
FULL extent list size 2140
FREE extent list size 0
PARTIALLY FREE extent list size 1
Pages information:
Reserved page num: 137056
Used page num: 137003
Free page num: 53

<<<Non-Leaf page segment>>>
SEGMENT id 3, space id 15
Extents information:
FULL extent list size 1
FREE extent list size 0
PARTIALLY FREE extent list size 1
Pages information:
Reserved page num: 160
Used page num: 116
Free page num: 44

========Secondary index========
Secondary index root page space_id 15 page_no 31940
Btree hight: 2
<<<Leaf page segment>>>
SEGMENT id 6, space id 15
Extents information:
FULL extent list size 7
FREE extent list size 0
PARTIALLY FREE extent list size 219
Pages information:
Reserved page num: 14465
Used page num: 12160
Free page num: 2305

<<<Non-Leaf page segment>>>
SEGMENT id 5, space id 15
Extents information:
FULL extent list size 0
FREE extent list size 0
PARTIALLY FREE extent list size 0
Pages information:
Reserved page num: 19
Used page num: 19
Free page num: 0

**Suggestion**
File size 2604662784, reserved but not used space 39354368, percentage 1.51%
Optimize table will get new fie size 2565308416

```

1. 这里tablespace id 是15
2. Btree 的高度是3层
3. secondary Index 由于只存索引, 所以primary index 占用的空间是secondary index 的10倍
4. primary Index 上面大量的page 都是用满的状态, 而secondary 会20% 左右的空闲page
5. 整体而言, 空闲page 只占了文件的1.51% 左右, 所以不需要做optimize table 操作的

