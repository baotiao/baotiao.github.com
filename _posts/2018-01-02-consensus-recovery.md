---
layout: post
title: difference between consensus algorithm's recovery phase
summary: 一致性协议recovery 阶段不同做法

---


在我看来包含 log, state machine, consensus algorithm 这3个部分, 并且是有 electing, normal case, recovery 这3个阶段都可以称为paxos 协议一族.

raft 里面比较巧妙的做法是把 recovery 包含在了 normal case里面, 也就是在normal case 的初始阶段是进行recovery 的过程.

那么recovery 阶段需要注意什么呢?

在paxos 成为一个新leader 以后, 为什么需要对之前的提案用新的term 号来进行确认呢? 如果不用新的提案号来确认会有什么问题?

会存在以下这种场景:

```
第一阶段:
m1:   1 2
m2:   1
m3:   1 2
m4:   1
m5:   1

第二阶段:
m1:   1 2 down
m2:   1 3
m3:   1 2 down
m4:   1
m5:   1	

第三阶段: 在当前这个阶段2是已经被提交了
m1:   1 2 
m2:   1 3 down
m3:   1 2
m4:   1 2
m5:   1	

第四阶段:
m1:   1 2  down
m2:   1 3
m3:   1 2  down
m4:   1 2
m5:   1

第五阶段:
m1:   1 2  down
m2:   1 3
m3:   1 2  down
m4:   1 3
m5:   1 3

```

这里2这个值已经在第三阶段的时候被确认提交了, 但是最后却又被覆盖了, 这与协议里面的规定提案一旦被提交, 就不会被撤回是相违背的. 所以其实在 recovery 主要要解决的就是这个问题.

那么按照paxos 的做法, 这个过程是怎样的呢? 

```
第一阶段:
m1:   1 2
m2:   1
m3:   1 2
m4:   1
m5:   1

第二阶段:
m1:   1 2 down
m2:   1 3 (这里3成为当前的提案term 的时候. 4, 5肯定知道目前的term 是3了, 那么后续1 或者3 想成为新的leader 的时候, 这个term 号一定是大于3 的)
m3:   1 2 down
m4:   1
m5:   1	

第三阶段:
m1:   1 4  
m2:   1 3 down
m3:   1 4
m4:   1 4
m5:   1	

第四阶段:
m1:   1 4  down
m2:   1 3
m3:   1 4  down
m4:   1 4
m5:   1

第五阶段:
m1:   1 4  down
m2:   1 4  (这里server 2 成为了新的leader, 但是因为4 的log 的term 号比自己要来得高, 因此会使用term 4 的log 的内容替换掉自己的)
m3:   1 4  down
m4:   1 4
m5:   1 4
```

这里也可以看出 paxos 在recevory 之后, 需要进行的重确认过程, 而且重要的是这个重确认的过程要使用新的term号, 而不是当时写入这个log 时候的term 号(在raft 里面叫term, 在paxos 里面叫 ballot number)

在raft 里面如何解决这个问题?

raft 的做法是只有新的leader 写入了一条正常用户的操作记录以后, 才可以把之前未确认的log 重新提交, 其实也是在避免 paxos 中出现的这个问题

```
第一阶段:
m1:   1 2
m2:   1
m3:   1 2
m4:   1
m5:   1

第二阶段:
m1:   1 2 down
m2:   1 3
m3:   1 2 down
m4:   1
m5:   1	

第三阶段:
m1:   1 2 4  (这里4 这个新内容是用户新的要写入了内容, 当然为了防止用户没有数据写入, raft 建议的做法是写入一条空记录, 这里在AppendEntry 的时候, 在同步2 的时候 是不会更新commitIndex, 也是为了避免出现2 这条记录被提交, 又被覆盖的问题. 因此只有等4 提交了以后, 才直接把这个commitIndex 更新到 Term 4 这个位置, 这也是raft 里面为什么值提交当前term 的log 的原因,其实适合Paxos 里面遇到的recovery 的问题是一直的)
m2:   1 3 down
m3:   1 2 4
m4:   1 2 4
m5:   1	

第四阶段:
m1:   1 2 4 down
m2:   1 3 
m3:   1 2 4 down
m4:   1 2 4
m5:   1

第五阶段:
m1:   1 2 4 down
m2:   1 2 4
m3:   1 2 4 down
m4:   1 2 4
m5:   1 2 


```

那么zab 中如何处理这个问题, 据我所了解, 在zab 中, 因为zab 默认存储数据的内容都很小,  所以zab 的做法是在一个节点成为新的leader 以后, 新的leader 会将自己节点所有的内容直接拷贝给其他的节点, 这种简单, 粗暴的做法就避免了不一致情况的出现.
