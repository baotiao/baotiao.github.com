---
layout: post
title: "CAP theorem"
description: "CAP theorem"
category: tech
tags: [throrem]
---


###CAP theorem (摘自维基百科)

* Consistency (all nodes see the same data at the same time)
* Availability (a guarantee that every request receives a response about whether it was successful or failed)
* Partition tolerance (the system continues to operate despite arbitrary message loss or failure of part of the system)

这里 Availability 可以这么理解, 就是在单位的时间内, 这个分布式系统能否给你返回一个成功或者失败.


### 实际工作例子  
1. 数据的一致性
  当客户端写入数据, 考虑可用性和一致性的折中  
  可以配置是要eventual consistency 还是 strict consistency.
    * 方案一: 主写入BinLog, 直接返回成功. 然后是将记录插入到DB中, 然后同步给从BinLog, 然后从将数据插入到DB中
    * 方案二: 主写入BinLog, 然后写入DB成功后返回成功. (Dynamo 在W参数 = 1 的时候情形). 然后从同步BinLog, 然后从将数据插入到DB中
    * 方案三: 主写入BinLog, 写DB同步数据给从的BinLog. 然后返回成功. (Mola, BigTable, Dynamo在W参数= 2 是这个情形). 然后从将数据插入到DB中

    可以看出方案一到三是 一致性越来越强, 可用性越来越弱的过程.(这里指的是用户的写会越来越慢, 只有之前的事物完成,才算完成) 我们最后选择的方案二, 因为我们这里对一致性的需求没有那么强烈, 如果等到将数据同步. 我们的性能是不允许的
