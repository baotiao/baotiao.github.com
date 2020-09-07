---
layout: post
title: InnoDB page management
summary: InnoDB 物理页管理
---


这个图片可以看到InnoDB 里面涉及的文件:

从 tablespace => segment => extent => page=>row

![Imgur](https://i.imgur.com/U8lbbM5.jpg)

在一个tablespace 里面, 每一个segment 也是有一个唯一的id 的标识的

**Tablespace**

一个唯一的Tablespace 会由这个file space 的第一个Page来描述

![Imgur](https://i.imgur.com/K5HswIh.jpg)

这里主要有几个重要的list

**维护Inode 的FULL_INODE, FREE_INODE list, 和维护 extent 的 FREE List, FREE_FRAG List, FULL_FRAG List 都在FSP Header里面, 我们可以理解成这两个资源是这个file space 的meta信息**



**Tablespace => segment**

一个tablespace 里面包含了多个segment, 特别是tablespace 0, sys tablespace, 里面还包含了rollback segment,  用户创建的table 所对应的table space 里面, 一般有segment, left node segment 和 non-leaf node segment. 如果用户创建了索引, 又会增加两个新的segment. 

tablespace 是如何找到segment 的呢?  这些segment 的描述信息在哪里呢? 

一个Inode Entry 用来描述一个 segment,  然后所有的这些Inode Entry 都在一个Inode page 里面, 默认这个Inode page 在tablespace 的第2个page. 如果这个tablespace 里面有过多的segment 了, 那么就创建更多的Inode page, 这些Inode page 通过FSP header 里面的FULL_INODE list 和 FREE_INODE list 连接在一起

所以tablespace 通过Inode Page 找到所有的segment.

底下这个图是Inode Page 结构

![Imgur](https://i.imgur.com/bE5NM0m.jpg)

一个Inode Page 里面包含84个Inode Entry





**segment=>extent**

一个segment 里面包含了多个extent,  所以每一个extent 都有一个属于的segment id.

那么segment 如何找到属于它的extent, 这些extent 的描述信息在哪里呢?

![Imgur](https://i.imgur.com/ofrhlCX.jpg)

在Inode Entry 里面, 也就是每一个segment 的描述结构里面, 有3个List, NOT_FULL List, Free List, NOT_FULL List,  这3个List 就把对应的 extent 连在一起了.

所以通过遍历Inode Entry 里面的3个List, 就可以找到这个Segment 的所有的 extent了, 然后extent 对应的描述符就是XDES Entry.





**Extent => Page**

一个extent 里面包含了64 个page,  只有一个index 的root page, 也就是根节点这个page, 会记录该page 所对应的两个segment 的Inode Entry 在Inode page 里面的具体位置. 

![Imgur](https://i.imgur.com/hQqvXoP.jpg)

那么一个extent 是如果管理这64个page 是否空闲呢? 是也通过InnoDB List 么?

不是的, 和一个segment 对应一个Inode Entry 类似, 一个extent 也对应一个XDES Entry. 

类似有一个Inode Page 存储了所有的Inode Entry, XDES Entry 也存在XDES page 里面(如果这个XDES page 是这个file space 的第一个XDES, 这个XDES 又叫做FSP_HDR, 一个file space 只会有一个FSP_HDR). 类似Inode Page 存在第2个Page, 这个XDES Entry 存在256MB XDES 的第一个page 上.



对应的XDES Entry 的结构:

![Imgur](https://i.imgur.com/KkDOOCy.jpg)

这里标记了 XDES对应的extent 属于的File Segment ID. XDES List 就把一个segment 对应的多个extent 连成一个链表, 然后State 标记这个extent 是FREE, FREE_FRAG, FREE_FULL, 然后在FSP_HDR 里面有FREE_LIST, FREE_FRAG, FREE_FULL list 把这些extent 也连在一起了.

在一个XDES Entry 里面包含了 Page State Bitmap=16 字节 = 128 byte. 每两个byte 用来描述1个page. 所以一个XDES 可以描述连续的61 个page, 这也是为什么extent = 64page 的原因.

所以Extent 通过Page State Bitmap 来管理64 个空闲page

对应的XDES Page 的结构:

![Imgur](https://i.imgur.com/ebBjQW3.jpg)

一个XDES Page 里面保存了 256 个XDES Entry. 

这里与Inode page 不一样的地方, 因为每256M 的第一个page 都是XDES page. 所以不需要动态的分配XDES Page.



这里可以看出对于 Extent, FSP_Header 里面有3个List 可能把它连在一起 FREE_FRAG, FULL_FRAG, FREE. Inode Entry 里面同样有3个List FREE, NOT_FULL, FULL.

当一个extent 完全被某一个segment 使用的时候, 就会连在Inode Entry 里面, 如果这个extent 完全空的, 就连在FREE. 一般被这个segment 使用, 连在NOT_FULL, 全部连在FULL.

如果一个extent 被多个segment 混用, 这里面还没满, 就连在FREE_FRAG, 被混用满了, 就连在FULL_FRAG, 这个extent 完全空闲, 有可能后续被分配给某一个segment 连在Inode Entry里面的FREE, 也有可能分配给 FREE_FRAG 使用



所以当我需要新的segment 的时候, 就从Inode Page 上面去找一个空闲的Inode Entry, 如果没有, FSP 就会分配一个新的Inode Page, 然后从这个新的Inode Page 去找新的Inode Entry

当我需要新的extent的时候, 就从XDES Page/FSP_HDR 上去找, XDES Page 有每一个XDES Entry 的状态, 如果没有, 就从下一个256M 的 XDES Page 上去找

当我需要新的page 的时候, 就从XDES Entry 上面找, XDES 里面的Page State Bitmaps 记录着里面是否有空闲page, 如果没有空闲page, 就申请一个新的 extent.这个新的extent 是从XDES Page 上去申请.



**问题**

由于一个用户创建的table 对应一个file space, 那么这个file space 里面就只会有两个segment, left page segment, non-leaf page segment, 那么这个这个file space 对应的Inode page 就只有两个Inode entry 是有用的吧

但是如果给这个table 建立一个索引, 就会增加两个segment, 所以最多给这个表建立42个索引以后, 这个Inode page 里面的Inode entry 就会用用满了, 然后这个file space 里面所对应的FSP_HEADER 里面就会去创建一个新的Inode page, 所以在file space 这个level, 也有两个InnoDB list, FREE_INODES, FULL_INODES, 记录在FSP header 这个结构体, 所以我们也可以看到Inode page 里面也有12 字节的InnoDB LIst 结构体

虽然大部分情况下一个Inode page 都是用不满的



可以这么理解, 只有redo log 是脱离Innode page management 这一套, undo log 里面的rollback segment page, undolog segment page, undolog normal page 都是走的Inode page management 这一套的

