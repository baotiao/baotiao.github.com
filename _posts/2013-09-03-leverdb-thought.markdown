---
layout: post
title: "levelDB thought"
description: "leveldb"
category: tech
tags: [leveldb]
---

1. 在ENV 里面可以把levelDB的结果从写入到本地 改成写入到 hdfs 来实现数据的备份, 复制等操作 具体的做法就是调用hdfs的写入这些库来实现.  这样实现levelDB的分布实话非常方便
2. levelDB的VersionSet 是管理者 version. 然后 每一个version 有一个列表, 这个列表是这个version 的对应的所有的SST文件.  所以你要查找某一个Version的数据的时候.  先会在这个VersionSet里面查找一遍包含这个当前快照的一个版本, 然后再从这个version 的这个list里面去具体的文件查找具体的内容
3. 在一台机器上面getInstance()出来1000 levelDB的实例的话, 只会有一个compaction线程, 然后一个机器1000 个levelDB 实例和1个机器1个levelDB的实例的话 带来的好处是在机器挂掉得时候recovery的非常的快.  不过这样compaction起来就很费劲
4. 在将本地文件写入到hdfs的节点中, 因为hdfs的写入性能比较慢.  所以在本地应该是writrBranch. 然后20ms向hdfs写一次. 这样比较适合.
5. levelDB 如何实现原子的getAndSet.  因为levelDB不是再内存层面实现这个对具体某一个key操作. 所以这个levelDB 的getAndSet操作不是通过汇编层面实现的.
