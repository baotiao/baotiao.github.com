---
layout: post
title: "Libprocess source intorduce"
description: "Libprocess source intorduce"
category: tech
tags: [mesos, libprocess, c++]
---

最近由于项目的需要, 在看Mesos 的代码,
把Mesos底下的进程管理库libprocess大概过了一遍

* libprocess 主要包含
    * process and PID 跟erlang 类似, PID可以用来唯一追踪这个process, 然后每一个process其实是一个线程里面的任务
    * local message via dispatch, delay, defer
    * functional composition via promise/futures
    * remote messaging via send, route and install


* libprocess 这个库的基础是include/process/event.hpp 这个文件. 这个里面定义了两个基类

    * Event

        * 那么定义各种类型的Event 就是对应各种Process, 对应的Process 处理Event
        * MessageEvent, HttpEvent, DispatchEvent 等等

    * EventVisitor
    
        * EventVisitor 会对Event进行访问, 延伸出来 进程就是一个Visitor
        * EventVisitor -> ProcessBase -> Process -> ProtobufProcess -> ReqResProcess


* libprocess 里面进程的创建是在spawn 的时候调用
    * spawn 在src/process.cpp 里面实现, spawn 调用dispatch 进行创建
    * spawn 的时候会指定ProcessManager 里面创建, 指定的ProcessManager 会管理一组对应的进程

* libprocess 定义了一些全局变量
    * static SocketManager* socket_manager = NULL;
        * 就是用来管理全局的Socket 信息的

    * static ProcessManager* process_manager = NULL;
        * 全局唯一的Process Manager, 那么接下来所有的spawn 等等操作都在这个ProcessManager 里面

    * PID gc;
        * 全局唯一的负责做gc的进程


* src/process.cpp 里面的schedule 是最主要的schedule 的函数, 负责调度所有的线程的执行
    * schedule 是在 process.cpp 里面的, schedule 的主要执行过程就是不断的从process_manager 里面取出这个process, 然后运行
    * 取出这个process 以后, 会运行process_manager->resume 函数, 这个resume 基本就是一个个任务的生命周期过程
    * resume 里面主要就是调用 event->visit(&visitor); 对每一个process 里面的事件, 去让process具体执行这个事件. 这里事件分几种类型
        * HttpEvent
        * MessageEvent
        * DispatchEvent
    * 在visit 函数实现里面, 由ProcessBase 注册了handlers, 这个handlers 里面注册了message类型, http类型的所有的对应的处理方法
    
    * 可以看出, 由于ProcessBase这个基类里面实现了所有对于消息的处理方法, 那么继承来的子类就不需要自己去实现如何访问这个Event的方法了
    * 从这个resume 函数的设计可以看出, 假设这个工作的线程里面某一个Process 有很多任务, 那么会出现把其它的工作线程堵住的情况, 因为这里处理的时候是默认把某一个线程里面所有的任务都执行完的


* ProcessManager 是负责管理所有的正在运行的线程的
    * list runq 是所有正在运行的线程的队列

* Gate 类是类似于futex 的实现
* src/process.cpp 里面的initialize() 是整个cpp 的初始化函数, 应该一开始在某个地方就被调用, 初始化了主要的全局变量
    * 那么这个initialize 是什么时候运行的呢?
        * 通过gdb可以看出这个函数运行的时间是当你定义了一个 class MyProcess : public Process, 那么在ProcessBase的构造函数里面, 默认都会去执行一下这个initialize函数的. 

    * 那么initialize 里面是如何保证这个initialize 一次?
        * 这里简单的是通过一个变量, 每次运行前都执行一次来进行这个判断是否初始化过. 如果初始化过就直接返回了

    * 至此这个最重要的initialize 就启动了, 也就是任意第一次建立这个进程的时候, 都会去执行这个初始化的操作
    * 从initialize 里面可以看出启动的时候就会默认去启动线程, 然后线程数至少是8个, 可以猜出来, 以后运行的线程应该在这几个初始化出来的线程上面执行
    * 每个线程启动以后, 执行的函数就是schedule 函数, 那么接下来就是任务过来由这个schedule 来执行这个函数

* include/process/future.hpp 主要定义了future这个类
    * 其中有定义了一个叫 promise 这个类, 这个类其实就是一个has-a的关系, 就是这个类只包含一个future这个对象, 所以是一个has-a的关系,  然后对future 这个类进行了操作包装
    * 在future这个类里面, 主要的几个 onReady, onFailed, onDiscarded, onAny 这几个函数都在某一个state的时候调用, 比如 

        ```
          future
            .onReady(std::tr1::bind(&Future<T>::set, f, std::tr1::placeholders::_1))
            .onFailed(std::tr1::bind(&Future<T>::fail, f, std::tr1::placeholders::_1))
            .onDiscarded(std::tr1::bind(&Future<T>::discard, f));
        ```

    * 就是说在Ready 这个state的时候, 这行Future<T>::set 这个函数. 这里因为onReady, onFailed等等状态都是返回的*this指针, 所以就是相当于注册了个各种判断的返回

    * 在注册这个执行方法的时候, 如果不是这个状态的话, 那么就把这个执行方法放入到这个执行队列里面去, 比如onFailedCallbacks 等到了相应状态再去执行
    * 如何做到调用这个Callbacks 队列里面的方法呢?
        * onAnyCallbacks->front()(*this);
        * std::queue<AnyCallback>* onAnyCallbacks; 是一个队列, 而里面的元素 就是一个个的AnyCallback, 而AnyCallback 其实是一个function
        
        * typedef std::tr1::function<void(const Future<T>&)> AnyCallback;

* dispatch 实现
    * 在dispatch 低下都会执行到internal::dispatch, 主要做的就是生成一个DispatchEvent, 然后由process_manager 进行deliver(pid, event, __process__); 这样就把对应的事情发送给对应的进程去处理了

* defer 实现
    * defers a dispatch to current process, 就是向这个process本身发送任务的一个方法, 比如 defer(self(), &Self::_launch, containerId)
    



