---
layout: post
title: my experience of distributed storage and the designed of zeppelin
summary: 关于我做存储的一些经验和zp 的设计考虑

---

### zeppelin introduce

大家好, 我是来自360基础架构组技术经理陈宗志. 主要负责360 存储, 中间件, 推送相关技术的实现

本次分享主要向大家介绍我们这一年多做的另外一个存储项目 zeppelin. 各位可能知道我们团队有bada, Pika. Pika (https://github.com/Qihoo360/pika) 已经开源, 目前应该也有各个大公司使用到他们的线上环境中, 在线上我们有800+ 实例在线上稳定运行. 为什么我们还要开发另一套存储系统呢?

我一直觉得不同的场景需要有不同的存储系统去解决, 有在线存储的需求, 有离线存储的需求. 因此肯定不是一套存储系统能够通吃所有的场景(不过貌似spanner 在做这个事情)

本次分享将阐述 Zeppelin 系统产生的背景，重点介绍 Zeppelin 系统的整个设计过程，并分享在分布式系统开发中的一些经验。通过带领大家重走 Zeppelin 的设计之路，让大家了解如何设计一个分布式存储系统，会遇到哪些问题，有哪些可能的解决思路。

我们公司的github 地址

https://github.com/Qihoo360

我们团队开发的 pika, pink, zeppelin, floyd 等等代码都在上面

我们先来谈谈在线存储和离线存储的区别

离线存储的需求很统一, 就是离线数据分析, 产生报表等等. 也因为这统一的需求, 所以目前hdfs 为首的离线存储基本统一了离线存储这个平台. 离线存储最重要的就是吞吐, 以及资源的利用率. 对性能, 可靠性的要求其实并不多. (所以这也是为什么java系在离线存储这块基本一统的原因, java提供的大量的基础库, 包等等. 而离线存储又对性能, 可靠性没有比较高的要求, 因此java GC等问题也不明显)

所以我们可以看到虽然现在离线的分析工具一直在变, 有hadoop, spark, storm 等等, 但是离线的存储基本都没有变化. 还是hdfs 一统这一套. 所以我认为未来离线存储这块不会有太大的变化

![Imgur](https://i.imgur.com/RakQFWE.jpg)


在线存储

指的是直接面向用户请求的存储类型. 由于用户请求的多样性, 因此在线存储通常需要满足各种不同场景的需求.

比如用户系统存储是提供对象的服务, 能够直接通过HTTP接口来访问, 那么自然就诞生了对象存储s3这样的服务

比如用户希望所存储的数据是关系性数据库的模型, 能够以SQL 的形式来访问, 那么其实就是mysql, 或者现在比较火热的NewSql

比如用户只希望访问key, value的形式, 那么我们就可以用最简单的kv接口, 那么就有Nosql, bada, cassandra, zeppelin 等等就提供这样的服务

当然也有多数据结构的请求, hash, list 等等就有了redis, 有POSIX文件系统接口了请求, 那么就有了cephfs. 有了希望提供跟磁盘一样的iSCSI 这样接口的块设备的需求, 就有了块存储, 就是ceph.

从上面可以看到和离线存储对比, 在线存储的需求更加的复杂, 从接口类型, 从对访问延期的需求, 比如对于kv的接口, 我们一般希望是2ms左右, 那么对于对象存储的接口我们一般在10ms~20ms. 对于SQL, 我们的容忍度可能更高一些, 可以允许有100 ms. 处理延迟的需求, 我们还会有数据可靠性的不同, 比如一般在SQL 里面我们一般需要做到强一致. 但是在kv接口里面我们一般只需要做到最终一致性即可. 同样对于资源的利用也是不一样, 如果存储的是稍微偏冷的数据, 一定是EC编码, 然后存在大的机械盘. 对于线上比较热的数据, 延迟要求比较高. 一定是3副本, 存在SSD盘上

从上面可以看到在线存储的需求多样性, 并且对服务的可靠性要求各种不一样, 因此我们很难看到有一个在线存储能够统一满足所有的需求. 这也是为什么现在没有一个开源的在线存储服务能够像hdfs 那样的使用率. 因此一定是在不同的场景下面有不同的存储的解决方案

**总结一下在线存储的要求**

![Imgur](https://i.imgur.com/PcxKWOj.jpg)

可以看到Facebook infrastructure stack 里面就包含的各种的在线存储需求. 里面包含了热的大对象存储Haystack, 一般热的大对象存储f4, 图数据库Tao. key-value 存储memcached 集群等等

![](http://i.imgur.com/LpZw633.jpg)

对应于google  也会有不同的在线存储产品. 对应于Google 有MegaStore, Spanner 用于线上的SQL 类型的在线存储, BigTable 用于类似稀疏map 的key-value存储等等

![](http://i.imgur.com/aUTxFTN.jpg)



个人认为对于在线存储还是比较适合C++来做这一套东西, 因为比较在线存储一般对性能, 可靠性, 延迟的要求比较高.

那么这些不同的存储一般都怎么实现呢?

很多在线存储比如对象存储的实现一般都是基于底下的key-value进行封装来实现对象存储的接口. ceph 就是这方面这个做法的极致.

ceph 底下的rados 本质是一个对象存储, 这里的对象存储跟s3 的对象存储还不一样, 只是提供了存储以为key 对应的value 是对象的形式. 然后基于上层基于librados 封装了librbd 就实现了块设备的协议, 那么就是一个块存储. 基于librados 实现了Rados Gateway 提供了s3 的对象存储的协议就封装成s3对象存储. 基于librados 实现了POSIX 文件系统的接口, 就封装成了分布式文件系统Ceph FS. (不过我认为ceph 底下的rados实现的还不够纯粹, 因为rados对应的value 是类似于一个对象文件. 比如在基于librados 实现librbd的时候很多对象属性的一些方法是用不上的)

![](http://i.imgur.com/grsvIND.png)

同样google 的F1 是基于spanner 的key-value 接口实现了SQL了接口. 就封装成了NewSql

因此其实我们也可以这么说对于这么多接口的实现, 其实后续都会转换成基于key-value 接口实现另一种接口的形式, 因为key-value 接口足够简单, 有了稳定的key-value 存储, 只需要在上层提供不同接口转换成key-value 接口的实现即可. 当然不同的接口实现难度还是不太一样, 比如实现SQL接口, POSIX文件系统接口, 图数据库肯定要比实现一个对象存储的接口要容易很多

但是我认为底下这一层并不应该叫key-value stroage, 这样说不够准确, 更好的说法应该是block storage, 为什么这么说?

在zeppelin 提供给 s3 使用的场景里面, zeppelin 应该提供的是一个类似于物理磁盘这样的基础存储, 然后s3 就类似于磁盘上面的文件系统.

比如文件系统有目录信息, 在linux 下面, 对于目录的处理和文件是一样的, 一个目录也是inode, 目录下面的文件是存储在这个inode 的data 字段里面, 那么访问这个文件下面有哪些目录的时候就是把这个inode 的data 按照一定的格式解析开来就可以了. 一个文件的目录的访问频率是远高于某一个文件的. 这个和zeppelin 之上搭建一个s3 遇到的问题也是一样, s3 里面需要存储某一个bucket 下面所有的object 的信息, 那么如果和文件系统一样的做法, 应该是在zeppelin 里面有一个专门的key 用于存储这个bucket 下面有哪些object, 然后需要读取的时候去访问这个key 就可以. 那么为什么目前zeppelin-gateway 的做法是把这些meta 信息存储在redis 上面.

1. 为了性能考虑
2. 因为redis 提供了list 这样的操作接口, zeppelin 还不支持
3. 因为目前简单的做法只能把这个bucket 下面的文件信息都放在一个key 上, 那么这个key 的访问压力一定特别大, 并且修改的话肯定特别频繁, 所以需要细致的设计如何存储这个bucket的meta信息, 暂时没开始做

其实当初文件系统也遇到类似的问题, 比如当初的ext2 文件系统上面就有一个目录下面能够存储的文件个数的限制这个问题, ext4 目前也是有文件个数的限制.

不过这个问题在s3 上面会比在文件系统上面更加的突出, 因为文件系统毕竟是树形接口, 底下不会有太多的文件. 而s3 是一个打平的结构, 这个目录下面的文件个数以及元信息的访问必然比文件系统更多

但是最后我们还是会像文件系统一样, 把这个信息放回在zeppelin 里面

还有一个原因是我们所说的key-value store 更多偏向于里面的内容是没有关系的, 而在zeppelin 提供给s3 使用的场景里面, 这些key-value 是有关系的, 所以我更倾向于说目前的存储的架构是:

底层提供block store, 然后上层基于各个接口实现不同的封装, 提供amazon s3 的接口就是 s3, 提供POSIX 文件访问的接口就是分布式文件存储, 提供sql 接口就是newsql

所以**zeppelin 定位的是高可用, 高性能, 可定制一致性的block storage 服务**, 上层可以对接各个协议的实现, 目前zeppelin 已经实现支持key-value 接口, 用于线上搜索系统中. 标准的S3 接口实现, 并且用于公司内部存储docker 镜像, 代码发布系统等等

这个是目前360 的存储体系

![Imgur](https://i.imgur.com/erViCCp.jpg)

讲了这么多我对存储的了解, 我们对zeppelin 的定位. 那么接下来聊聊zeppelin 具体的实现

![Imgur](https://i.imgur.com/AHyKVqG.jpg)

CAP 理论指的是 CAP 并不能同时满足, 而P 是基本都需要满足的, 所以基本都是AP, CP. 但是这里并不是说只能选AP 就没有C, 而是Consistency 的级别不一样, 同样CP 也值得并不是A, 只是A的级别不一样而已

![Imgur](https://i.imgur.com/UapFfNc.jpg)


#### 数据分布

* 均匀性(uniformity)
* 稳定性(consistency)

所有的分片策略都是在均匀性和稳定性之间的折衷

**常见策略**

* 一致性Hash
* 固定Hash 分片
* Range Hash
* crush

**zeppelin 的选择**

固定Hash 分片

1. 实现简单
2. Partition Number > Server Number 可以解决扩展性问题
3. 固定Hash 分片便于运维管理
4. 通过合理设置Hash 函数已经Server 对应的Partition数, 解决均匀性问题

![Imgur](https://i.imgur.com/flAeBEP.jpg)

![Imgur](https://i.imgur.com/JM1Pad3.jpg)

**有中心节点的设计**

* 为什么这么做?
* 目前主流的设计一般是两种
  * Bigtable 为代表的, 有MetaServer, DataServer的设计, MetaServer存储元数据信息, DataServer存储实际的数据. 包括 百度的Mola, bigtable, Hbase等等
  * Dynamo 为代表的, 对等结构设计. 每一个节点都是一样的结构, 每一个节点都保存了数据的元信息以及数据. 包括 cassandra, Riak 等等

**zeppelin 的选择**

有中心节点优点是简单, 清晰, 更新及时, 可扩展性强. 缺点是存在单点故障

无中心节点优点是无单点故障, 水平扩展能力强. 缺点是消息传播慢, 限制集群规模等等

因为后续我们会考虑支持zeppelin 到千个节点的规模, 因此无中心节点的设计不一定能够满足我们后期的扩展性, 所以zeppelin 是有中心节点的设计, 那么我们就需要做大量的事情去减少对Meta Server 的压力

zeppelin 选择有中心节点的设计,  但是我们操作大量的优化去尽可能避免中心节点的压力, 同时通过一致性协议来保证元数据更新的强一致

1. Client 缓存大量元信息, 只有Client 出错是才有访问Meta Server
2. 以节点为维度的心跳设计



#### 副本策略

1. Master - Slave

以MongoDB, redis-cluster, bada 为主的, 有主从结构的设计, 那么读写的时候, 客户端访问的都是主副本, 通过binlog/oplog 来将数据同步给从副本

2. Quorum(W+R>N)

以cassandra, dynamo 为主的, 没有主从结构的设计, 读写的时候满足quorum W + R > N, 因此写入的时候写入2个副本成功才能返回. 读的时候需要读副本然后返回最新的. 这里的最新可以是时间戳或者逻辑时间

3. EC (erasure code)

EC 其实是一个CPU 换存储的策略, ec 编码主要用于保存偏冷数据, 可以以减少的副本数实现和3副本一样的可用性. ec编码遇到的问题是如果某一个副本挂掉以后, 想要恢复副本的过程必须与其他多个节点进行通信来恢复数据, 会照成大量的网络开销.

zeppelin 的选择

目前zeppelin 只实现的Master-Slave 策略, 后续会根据业务场景, 存储成本的需求实现EC, Quorum. 

#### 存储引擎

![Imgur](https://i.imgur.com/SlpS0ZE.jpg)

![Imgur](https://i.imgur.com/BFCcOmg.jpg)

![Imgur](https://i.imgur.com/TMffXEl.jpg)

![Imgur](https://i.imgur.com/qVgeEcL.jpg)

Manos Athanassoulis  [**Designing Access Methods: The RUM Conjecture**](http://101.96.8.165/stratos.seas.harvard.edu/files/stratos/files/rum.pdf)

RUM 是 写放大, 读放大, 空间放大 之前的权衡

写放大: 写入引擎的数据和实际存储的数据大小比

读放大: 读放大是一次读取需要的IO 次数大小比

空间放大: 实际的数据总量和引擎中存储的数据总量关系大小比



![Imgur](https://i.imgur.com/Ocmwdt2.jpg)

当然这里主要根据DAM 模型(disk access model), 得出结论

当然这里并没有考虑 LSM Tree 里面场景的 bloom filter 等等

这里B+ tree 主要用在 数据库相关, 支持范围查找的操作, 因为B+ Tree 在底下有序数据是连续的

zeppelin 的选择

zeppelin 目前使用的是改过的rocksdb, nemo-rocksdb.  nemo-rocksdb 支持TTL, 支持后台定期compaction 等等功能

https://github.com/Qihoo360/nemo-rocksdb

#### 一致性协议

floyd 是c++ 实现的raft 协议, 元信息模块的管理主要通过floyd 来维护. 

![Imgur](https://i.imgur.com/C9hvAP0.jpg)

1. 关于paxos, multi-paxos 的关系

   其实paxos 是关于对某一个问题达成一致的一个协议. paxos make simple 花大部分的时间解释的就是这个一个提案的问题, 然后在结尾的Implementing a State Machine 的章节介绍了我们大部分的应用场景是对一堆连续的问题达成一致, 所以最简单的方法就是实现每一个问题独立运行一个Paxos 的过程, 但是这样每一个问题都需要Prepare, Accept 两个阶段才能够完成. 所以我们能不能把这个过程给减少. 那么可以想到的解决方案就是把Prepare 减少, 那么就引入了leader, 引入了leader 就必然有选leader 的过程. 才有了后续的事情, 这里可以看出其实lamport 对multi-paxos 的具体实现其实是并没有细节的指定的, 只是简单提了一下. 所以才有各种不同的multi-paxos 的实现

   那么paxos make live 这个文章里面主要讲的是如何使用multi paxos 实现chubby 的过程, 以及实现过程中需要解决的问题, 比如需要解决磁盘冲突, 如何优化读请求, 引入了Epoch number等, 可以看成是对实现multi-paxos 的实践

2. 关于 multi-paxos 和 raft 的关系

   从上面可以看出其实我们对比的时候不应该拿paxos 和 raft 对比, 因为paxos 是对于一个问题达成一致的协议, 而raft 本身是对一堆连续的问题达成一致的协议. 所以应该比较的是multi-paxos 和raft

   那么multi-paxos 和 raft 的关系是什么呢?

   raft 是基于对multi paxos 的两个限制形成的

   * 发送的请求的是连续的, 也就是说raft 的append 操作必须是连续的. 而paxos 可以并发的. (其实这里并发只是append log 的并发提高, 应用的state machine 还是必须是有序的)
   * 选主是有限制的, 必须有最新, 最全的日志节点才可以当选. 而multi-paxos 是随意的 所以raft 可以看成是简化版本的multi paxos(这里multi-paxos 因为允许并发的写log, 因此不存在一个最新, 最全的日志节点, 因此只能这么做. 这样带来的麻烦就是选主以后, 需要将主里面没有的log 给补全, 并执行commit 过程)

   基于这两个限制, 因此raft 的实现可以更简单, 但是multi-paxos 的并发度理论上是更高的.

可以对比一下multi-paxos 和 raft 可能出现的日志

**multi-paxos**

![](http://i.imgur.com/SsIeodM.jpg)

**raft**

![](http://i.imgur.com/2KO9khV.jpg)

可以看出, raft 里面follower 的log 一定是leader log 的子集, 而multi-paxos 不做这个保证

3. 关于paxos, multi-paxos, raft 的关系

所以我觉得multi-paxos, raft 都是对一堆连续的问题达成一致的协议, 而paxos 是对一个问题达成一致的协议, 因此multi-paxos, raft 其实都是为了简化paxos 在多个问题上面达成一致的需要的两个阶段, 因此都简化了prepare 阶段, 提出了通过有leader 来简化这个过程. multi-paxos, raft 只是简化不一样, raft 让用户的log 必须是有序, 选主必须是有日志最全的节点, 而multi-paxos 没有这些限制. 因此raft 的实现会更简单.

因此从这个角度来看, Diego Ongaro 实现raft 这个论文实现的初衷应该是达到了, 让大家更容易理解这个paxos 这个东西



zeppelin 的选择

zeppelin MetaServer 一致性是由自己实现的raft 库floyd 来保证. 写入和读取可以通过raft 协议实现强一致, 同时为了性能考虑我们在读取的时候还提供DirtyRead 的接口, floyd 已经在github上面开源, 是用c++实现的raft 协议, 实现的非常的简介明了

https://github.com/Qihoo360/floyd

floyd 的压测报告

https://github.com/Qihoo360/floyd/wiki/5-性能测试



#### 整体实现

![Imgur](https://i.imgur.com/lMM7BGK.jpg)

#### Meta Server 总体结构

![Imgur](https://i.imgur.com/UZRTuit.jpg)



#### 2. Data Server 总体结构

![Alt text](http://i.imgur.com/ZhXXi33.png)

Zeppelin自上而下的层次如图所示。
- Network Proxy：负责网络的压包解包，采用Protobuf协议通Meta Server, Client, 及其他Node Server进行交互；
- Zeppelin Process：Zeppline主要逻辑处理层，包括分表分片，数据同步，命令处理等；
- Binlog：操作日志，同时是同步模块的数据来源；
- 存储层：采用Rocksdb进行数据存储。

#### 3. 线程模型

![Alt text](http://i.imgur.com/9vbUPjd.png)

Zeppelin采用多线程的方式进行工作，Zeppline中的所有线程都是与Node绑定的，不会随着Table或Partiiton的个数增加而增加。根据不同线程的任务及交互对象将线程分为三大类：

1，元信息线程，包括Heartbeat Thread及MetaCmd Thread
- Heartbeat Thread：负责与Meta Server保持的心跳连接，并通过PING信息感知Meta Server元信息的更新；
- MetaCmd Thread：Heartbeat Thread感知到元信息的更新后由MetaCmd Thread从Meta Server获取最新的元信息。通过元信息中的副本信息，MetaCmd Thread会负责修改和维护改Node Server与其他Node Server的Peer关系；

2，用户命令线程，包括Dispatch Thread及Worker Thread
- Dispatch Thread：接受用的链接请求并将客户端链接交个某个Worker Thread线程处理；
- Worker Thread：处理用户请求，写命令会先写Binlog，之后访问DB完成用户命令的执行。

3， 同步线程，包括服务于副本间数据同步功能的多个线程
- TrySync Thread: 负责发起主从同步请求。MetaCmd Thread修改副本状态后，TrySync Thread会一次对当前Node Server负责的所有需要建立主从关系的Partition的主Partition发送Sync命令，该Sync命令会首先获取本地的binlog位置作为当前主从同步的同步点；
- Binlog Sender Thread：Partition的不同副本之间建立主从关系后会由Binlog Sender Thread读取并向从Parition的Binlog Receiver Thread 发送binlog项。这个过程通用户命令的执行异步进行，所以从的Partition可能会落后于主。同一个Sender会负责多个Partition；
- Binlog Receiver Thread：接受Binlog Sender Thread发来的Binlog项，写Binlog并将写DB的操作分发给不同的Binlog BgWorker；
- Binlog Receive BgWorker：接受Binlog Receiver Thread发来的请求，写DB完成操作。

![Alt text](http://i.imgur.com/lNlLS2a.png)


4，后台工作线程，包括BGSave and DBSync Thread，Binlog Purge Thread
- Binlog Purge Thread：为了减少对磁盘空间的占用，Binlog Purge Thread会定期删除过期的Binlog
- BGSave and DBSync Thread：建立主从关系时，如果主Partition发现同步点已经落后于当前保留的最早的binlog，则需要进行全量同步。该线程会首先将整个数据内容dump一份并发送给对应从Partition。全同步过程利用Rsync实现。

#### 4. 客户端请求
客户端需要访问针对某个业务Table进行操作时，会先向Meta Server请求改Table的元信息。之后每个访问请求，都会根据key计算出其所属于的Partition，通过元信息计算器Master所在的Node Server。直接请求改Node Server

![Alt text](http://i.imgur.com/dO3puHH.png)



#### 5. 故障检测及处理
Node Server定期向Meta Server发送PING消息，当节点宕机或者网络中断发生时。Meta Server会感知并修改其维护的元信息，并将元信息Epoch加一。元信息修改后，其他Node Server会从PING消息的回复中获得新Epoch，由于与本地记录不同，Node Server会由MetaCmd Thread向Meta Server 发送PULL消息主动拉去最新元信息。
元信息中记录各个Table中每个Partition所负责的Master Node Server及两个Slave Node Server。Node Server获得最新的元信息，并根据该信息修改自己维护的Partitions的主从角色，建立主从关系，提供服务。
