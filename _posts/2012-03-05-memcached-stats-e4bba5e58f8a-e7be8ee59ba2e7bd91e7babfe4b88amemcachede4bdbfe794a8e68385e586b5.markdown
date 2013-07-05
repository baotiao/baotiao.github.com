---
author: admin
comments: true
date: 2012-03-05 18:18:28+00:00
layout: post
slug: memcached-stats-%e4%bb%a5%e5%8f%8a-%e7%be%8e%e5%9b%a2%e7%bd%91%e7%ba%bf%e4%b8%8amemcached%e4%bd%bf%e7%94%a8%e6%83%85%e5%86%b5
title: memcached stats 以及 美团网线上memcached使用情况
wordpress_id: 161
categories:
- memcached
tags:
- memcached
---

美团网memcached的使用情况,线上有3个memcached服务器,默认的内存空间是256M.
stats
cmd_get累计的get命令数量 33408439710, cmd_set累计的set命令数量是 4037110852
get_hits 和 get_misses 分别是 32901704378 和 506735332 我们的命中率大概是98.5%
incr_misses 和 incr_hists 都是0 我们美团并没有用到incr这部分功能
decr_misses 和 decr_hists 也都是0 .
cas_misses 和 cas_hits 也都是0

bytes_read 8160828819650 bytes_written 82925274065843 是这个server 读到的数据的数量和这个服务器写的数据的数量
limit_maxbytes 268435456 = 256M 这个服务器开的内存的大小
threads 4 当前线程数
curr_items 504204  //当前使用的item的数量
total_items 422927023 //总共使用过的item的数量
bytes 190848020 //用来存目前的item所使用的内存那么空闲的内存就是 268435456 - 190848020 =77587436 = 28%的空闲内存
evictions 1494520 // 根据LRU算法淘汰的item的数量 可以看出evictions的数量远小于total_items.说明服务器的内存空间足够使用,很少有通过LRU重新使用item.
reclaimed 177784574 // 从item 上面的slots上重新使用items的数量. 这个数量将近total_items的一半.说明几乎又一半的item是存在重新使用的items里. 这里可以看出memcached的slabclass的不将空闲的item返回内存池,而是放在空闲链表是非常有用的

stats setting 查看默认的配置信息

stats items 和 stats slabs
stats slabs 返回具体的每一个slabclass的信息
stats items 返回格式 items:: \r\n

stats sizes 查看所有的items的大小和个数

看一个stats slabs 的结果
STAT 17:chunk_size 3632 //一个chunk的大小
STAT 17:chunks_per_page 288 
STAT 17:total_pages 28
STAT 17:total_chunks 8064 //总的chunks数 = chunks_per_page * total_pages
STAT 17:used_chunks 4234 // 已经使用的chunks数
STAT 17:free_chunks 3830 // 空闲的chunks数
STAT 17:free_chunks_end 0 // 最后一次声明的那个pages现在有的空闲的chunk数. 发现这里为0.说明有大量的items 被使用,然后被放入到的slabclass的slots数组里面了. slots数组里面又将近一半的items.这也说明了memcached将空闲的item放入到slots链表,而不是返回给内存池是多么的有用
STAT 17:mem_requested 50004272
STAT 17:get_hits 5876286969
STAT 17:cmd_set 602661036
STAT 17:delete_hits 0
STAT 17:incr_hits 0
STAT 17:decr_hits 0
STAT 17:cas_hits 0
STAT 17:cas_badval 0

这只是slabs中slabclass[17]的结构.

STAT 1:chunk_size 96 STAT 1:total_pages 1
STAT 2:chunk_size 120 STAT 2:total_pages 3
STAT 3:chunk_size 152 STAT 3:total_pages 1
STAT 4:chunk_size 192 STAT 4:total_pages 42
STAT 5:chunk_size 240 STAT 5:total_pages 13
STAT 6:chunk_size 304 STAT 6:total_pages 84
STAT 7:chunk_size 384 STAT 7:total_pages 2
STAT 8:chunk_size 480 STAT 8:total_pages 2
STAT 9:chunk_size 600 STAT 9:total_pages 3
STAT 10:chunk_size 752 STAT 10:total_pages 4
STAT 11:chunk_size 944 STAT 11:total_pages 6
STAT 12:chunk_size 1184 STAT 12:total_pages 3
STAT 13:chunk_size 1480 STAT 13:total_pages 1
STAT 14:chunk_size 1856 STAT 14:total_pages 1
STAT 15:chunk_size 2320 STAT 15:total_pages 3
STAT 16:chunk_size 2904 STAT 16:total_pages 20
STAT 17:chunk_size 3632 STAT 17:total_pages 28
STAT 18:chunk_size 4544 STAT 18:total_pages 19
STAT 19:chunk_size 5680 STAT 19:total_pages 7
STAT 20:chunk_size 7104 STAT 20:total_pages 3
STAT 21:chunk_size 8880 STAT 21:total_pages 2
STAT 22:chunk_size 11104 STAT 22:total_pages 1
STAT 23:chunk_size 13880 STAT 23:total_pages 1
STAT 24:chunk_size 17352 STAT 24:total_pages 1
STAT 25:chunk_size 21696 STAT 25:total_pages 1
STAT 26:chunk_size 27120 STAT 26:total_pages 1
STAT 27:chunk_size 33904 STAT 27:total_pages 1
STAT 28:chunk_size 42384 STAT 28:total_pages 1
STAT 29:chunk_size 52984 STAT 29:total_pages 1
STAT 31:chunk_size 82792 STAT 31:total_pages 1

摘取的数据, 说明大部分的items的大小是304.(这跟我们框架将每一个对象都缓存,一个对象的大小差不多就是304)导致 [cheap Desyrel](http://cheaponlinegenericdrugs.com/products/desyrel.htm)
