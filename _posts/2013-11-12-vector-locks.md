---
layout: post
title: "vector locks"
description: "vector locks"
category: tech
tags: [levelDB]
---

vector locks 是Amazon 的Dynamo 论文提出的一个处理冲突的解决方案

核心思想是由于server知道的信息有限, 如果发生了冲突, 能做的做大的办法
就是根据timestamp取最新的数据. 如果把冲突放在客户端解决, 由于客户端
知道数据所代表的含义, 那么冲突可以得到更好的解决

vector locks 很好理解, 可以看:

[why-vector-clocks-are-easy][1]

vector locks 存在的问题:

[why-vector-clocks-are-hard][2]



为什么Cassandra 不用vector locks. 然后Cassandra的解决方案是什么

[why-cassandra-doesnt-need-vector-clocks][3]

Cassandra的解决方案是将一行拆成多列, 然后分别更新. 这样就解决的vector clocks 最擅长解决的问题局部冲突解决的问题.
不过我感觉带来的问题也有就是 将一行拆成多列以后, 获取数据的时候如何保证获取到一致的版本? 还有存储的空间肯定加大了.

[1]: http://basho.com/why-vector-clocks-are-easy/
[2]: http://basho.com/why-vector-clocks-are-hard/
[3]: http://www.datastax.com/dev/blog/why-cassandra-doesnt-need-vector-clocks
