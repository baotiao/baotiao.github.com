---
layout: post
title: "Aerospike note"
description: "Aerospike note"
category: tech
tags: [nosql, aerospike, sourcecode]
---
## Aerospike 笔记
> 最近看了一下Aerospike的代码, 也做了一些测试, 记了点笔记, 有点乱, 后期再修整

### 先贴一个测试的性能测试结果

#### 测试机器

* CPU 24 * Intel(R) Xeon(R) CPU E5-2630 v2 @ 2.60GHz
* 内存 160G

#### 测试结果
数据存储方式全内存, 单机模式
1000000 total time 110807419 average 0.110807419 ms

数据存储方式全内存, 多机模式
10000 total time 2881574 average 0.288574ms

### 代码目录介绍

#### 主要代码在 as/src 下面

```
└─[$] ls as/src/
base  fabric  Makefile  storage
```

* base 目录主要是对Aerospike 的所有的各个角色的工作线程的封装. Aerospike 启动以后会开启140多个线程. 比如
    * thr_rw.c 主要是处理用户读写请求的线程
    * thr_info.c 保存的是用户的meta信息
* fabric 这个目录主要出路网络相关的事情
* storage 这个目录是aerospike 的各个存储引擎

#### module 目录下面主要放的是Aerospike这个公司的一个公共的代码.
比如目前有

```
└─[$] ls modules/common/src/main/citrusleaf/
cf_alloc.c  cf_bits.c   cf_crypto.c  cf_hooks.c  cf_queue.c           cf_random.c  cf_shash.c
cf_b64.c    cf_clock.c  cf_digest.c  cf_ll.c     cf_queue_priority.c  cf_rchash.c  cf_vector.c
```
这些包含 队列, 随机数, vector 等等东西

```
└─[$] ls modules/common/src/main/aerospike
as_aerospike.c                 as_buffer.c                  as_integer.c     as_module.c              as_rec.c         as_timer.c        internal.h
as_arraylist.c                 as_bytes.c                   as_iterator.c    as_msgpack.c             as_result.c      as_val.c
as_arraylist_hooks.c           as_hashmap.c                 as_list.c        as_msgpack_serializer.c  as_serializer.c  as_vector.c
as_arraylist_iterator.c        as_hashmap_hooks.c           as_logger.c      as_nil.c                 as_stream.c      crypt_blowfish.c
as_arraylist_iterator_hooks.c  as_hashmap_iterator.c        as_map.c         as_pair.c                as_string.c      crypt_blowfish.h
as_boolean.c                   as_hashmap_iterator_hooks.c  as_memtracker.c  as_password.c            as_stringmap.c   internal.c
```

这个下面的东西更多了, 比如有buffer, 迭代器呀等等东西,
感觉像是把STL自己实现了一套

### Server 代码
1. Aerospike 有一个后台扫描线程存在, 每10秒扫描一次

2. Aerospike 所有的线程之间的通信都是通过往对应的进程的队列发送信息来做到的  
在队列的实现里面, 队列里面有mutex, 以及cond.  
当队列是空的时候, 是阻塞在这个条件变量里面  
然后往队列中插入数据的时候, 会触发这个条件变量, 然后阻塞在这个条件变量的线程重新工作的  
所以这个队列还是封装的较好, 完全可以重新利用

3. All of the nodes in the Aerospike system participate in a Paxos distributed consensus algorithm, which is used to ensure agreement on a minimal amount of critical shared state. The most critical part of this shared state is the list of nodes that are participating in the cluster. Consequently, every time a node arrives or departs, the consensus algorithm runs to ensure that agreement is reached.  
所以 Aerospike 保存的是在这个集群里面, 运行的节点的信息, 如果运行的节点的信息发生了改变, 那么Aerospike 会通过走Paxos 来通知其他的节点

4. Aerospike 里面所有的角色都是对等角色的存在, 通过心跳来保持联系.
Aerospike 有两种定义集群的方式

5. Aerospike 的XDR这套基本有三个角色  
Aerospike daemon process (asd)  这个是程序本身  
XDR daemon process (xdr), which is composed of the following:  
Logger module  (记录日志模块)  
Shipper module (传输模块)  
Failure Handler module (失败处理模块)  
这里应该也是传输过去的日志 也可以加入压缩, 批量传输, 失败检查等功能, 然后写入到另一个IDC  
然后不同IDC之间的关系也可以是多种, 比如主从, 主主, 有些主, 有些从. 等等. 但是并没有解决核心的不一致的问题  
遇到不一致的问题的解决方案就是 想象不同的数据回去访问不同的机房, 但是不会再同一时刻.   
或者也是primary key的解决方案  

6. Aerospike 确实是写直接写入到服务端, 走一遍socket. 不过有个优化是如果key很长, 那么会将key压缩成比较短的

7. Aerospike 支持3中引擎  
memory: 全内存的引擎  
ssd: 直接写入到ssd盘的引擎  
kv: 写入到文件的kv引擎  
ssd_cold: 这个支持商业版的引擎  
感觉添加一个新的引擎也不难, 实现as/src/storage.c 下面实现相应的函数就可以了

8. Aerospike 就是一个c实现多态的例子, 支持多种引擎类型, 那么先实现基类storage.c, 然后每一个函数都有各自的不同的引擎的实现, 通过传进来的引擎类型来判断

9. thr_rw.c 是主要处理用户逻辑的线程  
as_read_start 是开始读取数据的逻辑  
as_write_start 是写入数据的逻辑  
他们两个都会调用as_rw_start, 然后在as_rw_start里面具体的去进行数据的读写  
然后as_rw_start 里面建立一个write_request_create(), 进行数据的读写  
然后最后调用internal_rw_start, 然后再调用write_local 进行数据的写入  
这个 thr_rw.c 是由主线程建立的  

10. 调用 thr_rw.c 的线程是 thr_tsvc.c 这个线程  
在thr_tsvc.c这个线程里面 thr_tsvc()函数有一个循环不断去队列里面去取元素, 取到元素就进行处理  
if (0 != cf_queue_pop(q, &tr, CF_QUEUE_FOREVER)) {  
在thr_tsvc.c这个线程 as_tsvc_init() 是这个线程的建立函数, 

11. 建立并调用thr_tsvc.c 这个线程的是主线程 as.c 来建立的, 所有的读写请求都经过这个thr_tsvc process_transaction 函数, 然后判断是读请求还是写请求, 然后交给thr_rw.c 来处理.  
这个process_transaction 函数里面同时会判断这个数据是在本地处理, 还是要交给其他的节点去处理

    其中读请求:  
    thr_tsvc_read() 函数处理
    在处理完读请求以后, 可以看出, 如果是这个proxy的线程的请求的话, 那么会将请求转    发会给这个线程, 然后由这个线程去回复这个请求

    写请求:


12. Aerospike 基本的思路就是各个事情都有各自的线程去负责, 然后核心的逻辑分两块, fabric 网络,  storage 存储

13. Aerospike 的heartbeat 里面有一个心跳, 方法是使用epoll监听这些事件的到来, 
主要逻辑在hb.c里面的  
```
nevents = epoll_wait(g_hb.efd, events, EPOLL_SZ,g_config.hb_interval / 3);
```
这个函数, 然后下面有各个业务逻辑的处理

14. Aerospike 的心跳的入口是 hb.c 下面的as_hb_init(), 然后里面建立一个线程执行mesh_list_service_fn这个函数

15. mesh host list 就是那个host的地址, 就是中心节点的地址

16. aerospike 里面的fabric节点之间的通信, income 和 send out 分别最多建立7个socekt, 然后超过的话就重复利用这7个socket

17. aerospike 里面的当有一个新节点到来的时候, mesh host 节点会调用fabric_accept_fn 来接受其他节点的请求, 然后在这个函数里面建立一个连接.

18. 基本aerospike 的实现里面都是一个线程有对应的队列, 然后去阻塞在去队列里面去数据的过程.  
另一种就是 直接sleep的等待的过程, 这种线程就是定时跑的线程

19. aerospike 是40ms 做一次心跳

20. fabric_worker_fn 这个是fabric 的work thread 函数线程的主要工作, 在as_fabric_start的时候会把这个主要的工作线程启动, 

    默认的fabric_worker 的线程数是64个
    然后fabric 线程都阻塞在epoll 上, 实时处理fabric的请求

21. partition的个数是4096个, 默认的情况

22. 在启动Paxos以后, 会自动做一个partition平衡的事情

23. thr_demarshal 这个线程负责就是做的路由的事情, 建立一个epoll, 监听这个socket在thr_demarshal 这个线程里面, 在epoll_wait以后, 如果建立的fd等于当前这个sock的fd

    同样负责accept的这个线程建立连接以后, 用轮询的方式查看当前有哪一个线程的epoll_fd[id] 是空的, 如果是空的, 就是这个accept以后的fd给这个线程, 让这个线程的epoll_fd 去监听这个事件

24. 是在thr_demarshal 这个线程里面打包好以后, 拼装成一个tranaction, 交给thr_tsvc这个线程来处理, 然后接下来就是具体的处理get, set请求了.
其中复制accept线程, 并且将accept以后评传成tranaction的线程有64个

25. 在thr_demarshal 里面, 第一个线程相当于负责accept的线程

26. 在thr_tsvc 里面的process_transaction() 会根据client的请求, 判断取的是哪一个namespace里面的内容

27. 在Aerospike 里面如何做分片的呢, 默认的分片数是4096个
也一样, 去获取这个partition的id, 就是一个Hash取模的操作

    ```
    /* as_partition_getid
     * A brief utility function to derive the partition ID from a         digest */
    static inline as_partition_id
    as_partition_getid(cf_digest d)
    {
        return( (as_partition_id) cf_digest_gethash( &d,     AS_PARTITION_MASK ) );
    //     return((as_partition_id)((*(as_partition_id *)&d.digest[0])     & AS_PARTITION_MASK));
    }
    ```
28. Aerospike 的partition信息放在 datamodel.h里面    
关于一个namespace, 就是一个整个库的信息都是放在namespace_s里面, 包括副本个数, 分片个数, 冲突解决方案, 每一个namespace 里面也有partition的信息    
在datamodel.h 里面的partition 包含了主从信息, 其中partition 里面cf_node origin, target就是主从的信息, 包括waiting_for_master 等等

29. 在读取或者写入的流程里面, 有一个操作是 as_partition_getreplica_readall, 这个函数将负责服务某一个partition的所有机器找出来

30. Aerospike里面的index 就是数据的索引, 存放在内存里面, 然后指向真正的数据的地址, 在base/index.h 这个文件里面, 一个index对应的就是一个record

31. Aerospike 里面两个角色是master prole

32. Aerospike vmapx 这个数据结果应该就是一个Hash结构, 然后存储的是一个records下面所有的Bin信息

33. 最后写入到 namespace里面某一个record添加bin的是thr_rw.c 里面as_bin_create, 这就是写入一个新bin的最后插入到storage的操作

34. particle.c 这个文件里面存的是bin 所对应的具体的字段

35. Aerospike 的某一个partition 启动的时候会有一个将主那边的数据拉过来的过程

36. Aerospike 里面的事件中, 发完一个AS_PAXOS_MSG_COMMAND_HEARTBEAT_EVENT 事件以后, 下面紧接着是AS_PAXOS_MSG_COMMAND_RETRANSMIT_CHECK, 这个事件是对HEARTBEAT_EVENT的检查,
在RETRANSMIT_CHECK这个事件中, 主要是对集群中各个主的元信息的检查, 应该是HEARTBEAT_EVENT中带着集群的主的信息

37. Aerospike 里面的fabric模块中, 也是分成两种线程, 一种是server, 一种是worker线程
server线程负责accept连接, 然后将这个accept以后的连接放入到工作线程的fd里面去

    这里 worker thread connect到这个server thread 建立的socket里面, 然后想这个server thread发送一个字节

38. As 里面所有的heartbeat的信息都保持在g_hb这个信息里面, 比如有多少个节点需要传播heartbeat信息, 比如多少个节点是支持udp等等. 以及hb 的callback函数, 以及保存的mesh host的信息等等

39. hb主要用来做节点探测, 当节点探测成功以后, 就会把新加入的节点加入到对应node的fabric_node_element_hash(FNE)里面去

40. 在建立完这个fabric 端口accept的sockfd 以后, (这里这个connect的请求应该是从heartbeat里面来的) 这里用这个accept以后的sockfd 建立 fabric_worker_add 是将建立好的fabric_buffer 添加到某一个工作线程去    
目前好像是这样子, 一个node上面有多个进程, 然后有8个端口负责和其他的各个节点进行fabric消息的通知

41. hb 和 fabric之间是通过 fabric_heartbeat_event 这个函数进行交互的, hb获得的新节点或者减少的节点通过这个函数通知给其他的节点   
在fabric_heartbeat_event 后, 会交给在fabric里面注册的as_paxos_event模块去处理. 

42. as_fabric_register_msg_fn 注册着所以在定时发送fabric信息过程中要做的事情, 里面有18种类型, 包含要处理的 Transaction, proxy, info 等等信息, 每一个类型就注册一个处理函数去进行相应的处理. 主要的逻辑都在这里了

43. heartbeat 的定时触发是通过epoll_wait来做的
```
nevents = epoll_wait(g_hb.efd, events, EPOLL_SZ, g_config.hb_interval / 3);
```
在heartbeat 启动以后, 轮询在这个epoll_wait的逻辑上

44. 触发fabric建立连接的过程是 
as_smd_init -> as_smd_create -> as_smd_thr -> as_smd_process_event -> as_smd_metadata_change -> as_smd_proxy_to_principal -> as_fabric_transact_start -> as_fabric_send -> fabric_connect

45. 在heartbeat 这块 as_hb_thr 是具体处理每一个节点发过来的消息, 是每 150 ms进行一次,    
然后在as_hb_thr 里面有可能会去修改 g_hb.adjacencies 也就是这个g_hb的全局的邻接表的信息,     
然后接下来是hb_monitor_thr 这个线程就是不断去检查邻接表有没有变化, 如果有变化的话, 那么会调用fabric.c里面的 fabric_heartbeat_event 这个函数, 这个函数里面又会调用注册的 paxos.c里面的as_paxos_event, 这个线程的时间是 150 ms 进行一次

    至此一个节点的加入, 与退出都明显了..
就是不断的heartbeat 去各个节点, 维护一个邻接表, 然后另外一个线程不断检查邻接表的信息, 如果邻接表信息出现变化的话, 那么就走到了fabric 的逻辑, 然后fabric里面的逻辑回去走paxos的逻辑

46. as_partition 存的就是每一个partition对应的信息, 一个partition对应的就是一个数据分片里面所有的信息

47. 迁移过程要考虑某一个partition 是否正在migrate中, 如果在迁移中, 要做相对应的处理

48. 在每一个partition的结构体里面, 有一个qnode字段. 这里字段指向某一个cf_node, 用来记录这个partition的负责查询的节点在哪

49. 在主要的as_partition_balance_new 里面, 主要的逻辑过程就是先算好每一个partition的node信息, 然后调整, 然后在迁移的过程中的节点要特殊处理一下

50. paxos 模块中, 有启动两个主要的线程, 一个是as_paxos_thr, 主要处理的是paxos的业务逻辑, 一个是as_paxos_sup_thr, 主要处理的逻辑就是不断的做 paxos_retransmit 然后往as_paxos_thr的队列里面发送数据

51. as_paxos_thr 是阻塞在不断从自己队列里面读取数据上面, 而as_paxos_sup_thr是周期性的往这个队列发送数据, 然后as_paxos_sup_thr是sleep 5秒一次

52. heart beat 进行以后, 会更新全局的g_config里面的 ha_paxos_succ_list_index, 以及hb_paxos_succ_list 这两个hv, hv_index 结构, 具体可以看partition.c 里面的解释, 然后在retransmit_check的时候, 会比较这两个list是否有变化

53. 每一个节点在加入的时候都会执行 as_paxos_init(), 然后在节点加入自己的paxos信息后, 会执行as_partition_balance_new()这个操作


54. 在paxos模块发现需要改变节点信息以后, 那么就是通知system_metadata模块改变smd. 通知smd的函数就是  
as_smd_paxos_state_changed_fn. 这个函数做的事情就是将一条internal + paxos的数据放到smd的队列里面, 那么不过轮询的这个队列就会发现有一个消息的到来, 然后在as_smd_thr函数里面, 将一条数据取出后, 执行as_smd_process_event() 去处理这个消息

55. 在 as_smd_process_event 里面处理两种类型的消息, 一种是普通的请求smd信息的API的请求, 还有一种就是Paxos发生改变的请求

56. 在system_metadata 模块, 将Paxos需要发送过来的消息执行以后, 会将这个结果返回给Paxos的principal节点, 在Paxos处理这些消息的过程中可以看到, 是需要等待所有节点返回以后. 才会表示这个操作成功的, 因此这里的操作可以看成是事务的


58. fabric 注册的两个模块, 一个处理到来的消息, 一个处理到来的事件

    as_fabric_register_msg_fn: 需要注册的消息函数在这块定义, 使用as_fabric_register_msg_fn 的地方是处理它队列里面的消息的时候
fabric_process_read_msg()
as_fabric_send()
这两块地方, 那么有消息过来的时候, 在相应的模块注册的事件就可以执行了

    as_fabric_register_event_fn: 需要注册的事件处理函数在这块, 比如 paxos_event就进行了注册
    fabric_heartbeat_event 这里面就调用了注册的这些事件的函数, 相应的事件有相应的注册函数
    目前注册了这个事件的函数只有 as_paxos_event 函数

    fabric_heartbeat_event 这个函数的调用是注册在   
    as_hb_register(fabric_heartbeat_event, fa);  
    也就是注册在 hb的系统里面, hb某一个事件的时候会调用这个    fabric_heartbeat_event这块  
那我们看看什么时候会调用注册在hb上面的这些事件  
这个是在 as_hb_monitor_thr, 这个函数里面会调用到的. 这个函数是专门有一个线程在执行的
这个线程是as_hb_init() 的时候建立的, 这个线程执行一次以后sleep 150ms

### Client 代码
1. aerospike client 主要的逻辑在citrusleaf:do_the_full_monte,
那么读取一个数据的过程是
* 根据cluster, ns 就可以获得对应这个ns的table
* 根据table, 要插入的key, 就可以获得对的partition id
* 然后根据table->partitions[partition_id] 获得保存下来的master as_node, 如果读的话, 可能是prole node
* 然后去获得这个node对应的fd, 这个node对应的fd可能有多个
* 然后就是cf_socket_write_timeout 进行数据的写入
* 这里如果出现问题的话就可能进行重试
* 写入以后还有一个读取的过程cf_socket_read_timeout, 用于读取写入数据的返回结果


2. 客户端的基本的类的包含过程是aerospike->cluster->(as_nodes -> as_node (as_node就是存的aerospike 服务端节点的具体信息了, 具体的Ip, partition的版本, 名字等等), as_partition_tables-> as_partition_table(每一个namespace对应一个partition_table)->as_partitions(这里就记录了某一个partition的master 和 prole 的指针) -> as_node(master, 以及prole) ) ->

3. client 在什么时候更新这个元信息. 
不断在后台执行的程序是 有一个线程执行 as_cluster_tend, 做的事情包括不断检查节点是否存活
as_lookup 做的事情就是检查某一个hostname:port 是否存活
通过不断检查node, 然后把这个node信息通过as_cluster_add_nodes_copy, 把这个node信息拷贝到cluster->nodes里面
