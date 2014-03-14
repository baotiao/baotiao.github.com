---
layout: post
title: "多IDC冲突常见解决方案"
description: "Cross IDC conflict solution"
category: tech
tags: [distribute]
---
## 多IDC冲突常见解决方案

在分布式系统里面我们会经常遇到多个Client对同一个Key进行了修改, 如果系统不想解决冲突, 那么默认的解决方案是选取时间戳最新的那个结果. 不过有时候业务经常会对一个Key进行局部修改,然后保存. 这个时候其实业务想要的是几次操作的合并.   

比如Key=name:baotiao|age:18 一个Client更新了这个Key, 变成Key=name:chenzonghzi|age:18. 另外一个Client同时也更新了这个Key, 变成 Key=name:baotiao|age:20 这个时候常见的按照最后的时间戳的解决方案会带来问题是只能获得其中一个的结果. 有什么比较好的解决方案么?

这里介绍三个解决方案.

1. ###Dynamo Vector Lock解决方案  
    Vector Lock的核心思想就是Client对这个数据的了解是远远超过服务端的, 因为对于服务端而言, 这个Key 对应的Value 对于Server 端只是一个字符串. 而Client 端能够具体了解这个Value 所代表的含义, 对这个Value 进行解析. 那么对于这个例子. 当这两个不一样的Value写入到两个副本中的时候, Client进行一次读取操作读取了多个副本. 
    
    Client 发现读到的两个副本的结果是有冲突的, 这里我们假设原始的Key的Vector Lock信息是[X:1], 那么第一次修改就是[X:1,Y:1], 另一个客户端是基于[X:1]的Vector Lock修改的, 所以它的Vector Lock信息就应该是[X:1,Z:1]. 这个时候我们只要检查这个Vector Lock信息就可以可以发现他们冲突, 这个就是就交给客户端去处理这个冲突.并把结果重新Update即可
    
2. ###Cassandra 的解决方案  
    Cassandra 的解决方案就是讲一个Key尽可能小粒度的拆分, 所以我们看到在Cassandra里面有RowKey的概念, 通常将一个data分成多个部分. 比如这里存的Key_name=name:baotiao, Key_age=age:18. 那么两次修改分别修改了两个表, 那么最后我们查询的时候在Key_name列里面我们看到的最新时间戳的肯定是Key_name=name:chenzongzhi, Key_age=age:20. 这样我们就可以得到这个Key最新的结果

3. ###Yahoo! Pnuts 的Primary Key解决方案  
    这里我们对每一个Key 有一个Primary IDC, 也就是这个Key的修改删除等操作都只会在当前这个IDC完成, 然后读取可以有多个IDC去读取. 那么因为对于同一个Key的修改, 我们都在同一个IDC上. 我们通过给每一个Key加上一个Version信息, 类似Memcached的cas操作, 那么我们就可以保证做到支持单条数据的事务.  
    如果这条数据的Primary IDC是在本机房, 那么插入操作很快.  
    如果这条数据的Primary IDC不是本机房, 那么就有一个Cross IDC的修改操作, 延迟将会比较高.不过我们考虑一下我们大部分的应用场景, 90%的数据的修改应该会在同一个机房. 比如一个用户有一个profile信息, 那么和修改这个信息的基本都是这个用户本人, 90%的情况下应该就是在同一个地点改, 当然写入也会在同一个机房. 所以大部分的修改应该是同一个机房的修改.  
    当然为了做优化, 有些数据可能在一个地方修改过了以后, 多次在其他地方修改, 那么我们就可以修改这个Key的Primary IDC 到另外这个机房
    
###后话
这里提到的方案只是我个人的理解, 有不对的地方,还望大家支出
目前我觉得Yahoo!这套方案比较适合用来处理业务对数据的丢失比较敏感的方案, 虽然牺牲了10的写的性能不过我感觉能够接受
Dynamo 的方案问题在于有时候客户端虽然可以获得这个数据, 但是客户端也不知道如何处理这个冲突, 简单的方案可以做Merge, 复杂的结构就不好处理了.
Cassandra 的方案在读取方面性能可能有损失, 因为毕竟将一个Key 分成了多个Key以后, 每一次的读取操作都要合并多个Key的结果

