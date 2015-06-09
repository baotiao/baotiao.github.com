---
layout: post
title: "Summarize of mesos paper"
description: "Summarize of mesos paper"
category: tech
tags: [mesos, paper, schduler]
---

以下是看mesos paper 总结的一些东西.

目前Mesos 已经支持Docker的调度, 不过从代码上面来看属于增加的额外的一种Container,
官方是系统对Docker的支持与原有的自带的MesosContainer有区别,
比如官方自带的Container的隔离和限制都是自己做的, 而DockerContainer
是在Docker启动的时候在命令行里面指定的, 也由于这样, 目前Mesos
支持的所有的限制必须是Docker本身支持才行.

后续会加入和Borg 的对比, 以及我对资源调度领域的一些理解.

### Mesos Paper

* Overview 资源调度过程
    * slave 主动汇报资源给 master, framework 向master 申请资源
    * master 返回资源给 framework, 这里面会描述这些资源的构成, 比如内存有多少, cpu 有多少, 以及这些机器是不是都是一个机器上面的等等
    * 然后framework's scheduler 告诉给master 具体它要的这些资源怎么分, 每个任务占多少的cpu, 内存. 总共几个任务等等
    * master 将framework 告诉给自己的任务, 分配在对应的slave机器上,然后用framework's executor执行起来

* Mesos 允许各个framework 设置filter,  比如说某些任务只在某些机器上面执行等等
* Resource Allocation
    * Mesos 提供两种资源分配的算法, 第一种是max-min fairness 调度算法, 另一种是严格的资源限制
    * Mesos 提供两种删除资源的方法, 比如这个framework长时间的占用资源, 这个时候怎么办, 比如想MapReduce 这样的任务, 那么就直接杀死, 因为对MapReduce这种架构而言, 单个任务的影响是不大的. 但是对MPI这种任务就不行, 因为MPI里面任务都不独立.  所以对于想MPI这种任务, allocation module提供了guaranteed allocation 的保证. 现在Mesos的做法比较简单, 如果一个framework在它保证的资源一下, 都不杀死, 如果超过了 全部杀死

* Isolation
    * 主要由isolation moduler 模块提供, 这个也是一个插件是模块, 就是LXC下面的那一套. 不过现在基本都被Docker取代了吧


* Making Resource offers scale and robust
    * 因为framework 会拒绝某些资源, 比如来自某些机器上的资源不要等等, 为了让这个拒绝的更快, 以免影响资源的等待等等问题, 所以支持框架一些简单的资源判断来达到快速拒绝的目的, 比如框架可以配置只要那些机器上的资源, 或者资源必须来自某一个机架等等
    * Mesos本身会计算自己有多少资源, 所以能够并行的提供资源, 也能够快速决定是否满足framework的需求
    * 如果一个framework 在一定的时间没有返回, 那么Mesos 会取消这个资源, 然后分配给其他framework

* Fault Tolerance
* Mesos 实现了主的状态叫soft state, 也就是一个新的主能够根据slave的信息, framework scheduler信息, 完全恢复这个信息, 可以不用担心宕机, 其实mesos master 里面主要包含active slaves, active frameworks, running tasks. 所以一般mesos 的master 把所有的节点信息放在zk上, 通过zk来选主, 但是里面的信息是通过与slave, framework 来恢复的
* 如果是其他节点的错误或者executor crash, 那么Mesos master 会返回各种错误信息给framework scheduler, 然后让framework scheduler来处理这个信息
* 如果是framework 挂了, 那么mesos 的建议是注册多个framework 在这个mesos上, 如果一个framework 挂了, 那么其他framework 来执行这个任务, marathon 就是这种做法, 把主信息放在zk里面

* Mesos Behavior
    * Placement Preferences
        * 每一个framework 都有自己希望运行任务在哪些节点上, 由于Two Level 调度不可能了解到其他Framework 的 Preference, 所以与中心和调度相比, 不能很好的分配
        * 虽然这样, 但是因为我们可以多次随机的分配任务给这个framework, 如果不满足. 那么重新在分配其他的资源给这个framework, 因为最后还是能满足不同framework 的 preferences. 只是可能需要多次的重试

    * Homogeneous tasks 相同任务的框架
        * 从对比可以看出, 支持任务弹性, 并且每一个任务运行时间都相同的框架, 任务的启动时间, 任务完成的时间, 资源的使用率都比较高. 相反, 需要一定资源才能运行, 并且需要的运行任务时间是指数级变化的框架 各项指标都比较低

    * Heterogeneous tasks 各种不同任务的框架
        * 因为存在有些任务运行时间长, 有些任务运行时间短, 因此会存在长的任务把短任务全部占用的情况
        * 为了减少这样的影响, Mesos 提供了一些策略, 比如当向框架提供资源的时候, 限制这些资源的使用时间, 如果超过这个使用时间, 就把上面的任务给杀掉. 当然, 肯定是部分机器上的资源是这样, 如果都是这样的话, 那么长任务就跑不完了

    * Framework Incentives
        * Mesos 毕竟是一个无中心化的调度系统, 肯定这个系统对某些framework 支持的比较好
            * 运行时间短的任务, 因为运行时间短的任务在任务失败, 或者丢失任务的时候影响比较小
            * 支持弹性扩容的任务, 就是任务不需要全部的资源达到了才能运行起来, 因为这样的任务在资源还没有满足的情况下就能够运行起来, 不需要等待资源到位, 而且资源利用率也会比较高
            * 不接受不认识的资源, 这样就不会造成资源浪费, 因为Mesos 是会统计哪些资源被占用, 来统计是否有资源, 如果framework 占用了没有使用的资源, 肯定就兰妃 

        * 满足了以上这些支持的framework, Mesos 会支持的更好, 资源的利用率肯定也会更高, 现在很多的开源框架基本满足这些需求, 比如Hadoop, Dryad. 

    * Two Level 调度的局限性 
        * 碎片化
            * 由于不同framework需要的资源不一样, 这种Two level 调度, 不能把多种类型打包起来, 分配资源不够合理
            * 因为在运行各种不同类型的framework的时候, 容易把所有的资源碎片化, 导致有一些framework需要大任务运行不起来. 如果是中心化调度的话, 因为他知道所有的需要调度的请求, 因为不存在这个问题

        * 互相依赖的framework 限制
            * 有些framework 需要互相配合才能运行的好, 由于Two Level 调度各自的scheduler 都在各自里面, 因此很难很好的配合. 不过这种情况很少见

        * framework 的复杂性
            * 中心化调度的话, framework 想中心申请资源就可以了. 而这种Two Level 调度需要Master offer resource 给framework, 然后framework来判断是否使用, 或者接受哪一个offer
            * 还有就是有些framework 不能预知这个任务的时间, 还有就是framework 必须处理任务失败等情况


