---
layout: post
title: "storage type"
description: "storage type"
category: tech
tags: [nosql, storage]
---

## 常见的存储类型

我的观点是, 这些存储类型的分类其实是人工的分类, 不存在一个绝对正确的分类.
分类只是为了有一个系统的认识
这里主要以aws上面提供的服务来进行分类

### kv

Example: dynamo, simpleDB, DynamoDB, Bada

### object storage
Example: amazon s3, amazon glacier

object storage 与 kv的区别是, kv是数据库, 而object storage 面向的则是存储, 所以在amazon的观点看来, object storage 存的是冷数据, 访问以对象形式, 常见的比如云盘存音频, 图片等等信息, amazon glacier 更是可以用来存归档很久的历史信息. 而且存储更是要存储海量的数据, 因此一般都是用普通的saas盘来存储

kv常见的用途就是用来提供线上的快速的存储服务, 以提供高性能的服务为目的, 所以一般配合SSD盘来使用, 比较适合存储小value的数据, 因为比较节省资源

当然两者也有同样的地方, 比如多副本保证数据的可靠性, 不过这里在我看来kv比较适合用多副本, 而object storage比较适合用erasure code方法

object storage 可能包含一些历史版本的数据, 因为作为storage 可能必须提供回滚等方案, 因此需要保留历史版本信息

### block storage  
Example: amazon EBS

Block storage is a type of data storage typically used in storage-area network (SAN) environments where data is stored in volumes, also referred to as blocks.  
Each block acts as an individual hard drive and is configured by the storage administrator. These blocks are controlled by the server-based operating system, and are generally accessed by Fibre Channel (FC), Fibre Channel over Ethernet (FCoE) or iSCSI protocols.  
Because the volumes are treated as individual hard disks, block storage works well for storing a variety of applications such as file systems and databases. While block storage devices tend to be more complex and expensive than file storage, they also tend to be more flexible and provide better performance.

**block level storage devices are accessible as volumes and accessed directly by the operating system, they can perform well for a variety of use cases.**

block storage 是把所有的原生的硬盘连接在一起, 然后有一个server提供对所有硬盘的访问, 访问的协议是ECoe, iSCSI等. 然后每一个硬盘的部分或者多个硬盘可以组成一个block, 这个block就可以安装任何的文件系统, NFS, VMFS.  
其实可以看成block storage 时间裸磁盘进行分隔, 然后一块磁盘上可以使用多种格式, 比如nfs,smb 等等.  
对应的file storage, 就是一块磁盘上面本身就设定了一个格式, 然后再在上面进行应用.   
