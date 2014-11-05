---
layout: post
title: "libevent demo"
description: "libevent demo"
category: tech
tags: [network, libevent, c++]
---

libevent 就是对select的封装.

select 比一般的阻塞调用厉害的地方在于,它能够阻塞在多个调用上.比如read阻塞了以后,程序只能当有新的输入以后,程序才继续运行,socket accept阻塞以后,当socket有请求,这个阻塞才会停止. 而select的叫IO多路复用,就是说调用select 以后可以同时监听这些阻塞.调用select以后,当有新的输入或者有新的socket请求程序都会停止阻塞,继续运行.

read/write 操作

libevent 编译时候加-levent

main 开始的时候event_init();

event_set(struct event *ev, int fd, short event, void (*fn)(int, short, void *), void *arg);

1. construct struct event for event_add and event_del, the fourth parameter is the callback function we should implement.
2. event type: EV_TIMEOUT,EV_SIGNAL,EV_READ,EV_WRITE

-->The additional flag EV_PERSIST makes an event_add() persistent until event_del() has been called.
如果没有用EV_PERSIST那么这个时间触发一次以后,这个事件就不再被注册了.所以基本都有EV_PERSIST

    event_add(struct event *ev, struct timeval *tv)
    event_del(struct event *ev):
    add or del an event.

    event_dispatch():
    In order to process events, an application needs to call it.This function only returns on error, and should replace the event core of the application program.

表示监听多个event type的时候 用| EV_READ | EV_TIMEOUT      

    /* 这个是libevent 的一个例子. 先建立一个FIFO,将其设置为非阻塞.注册这个event,
    event_set(&evfifo, socket, EV_READ | EV_PERSIST, fifo_read, &evfifo);
    意思是监听socket这个描述符的读请求,并且设置EV_PERSIST. 触发以后调用fifo_read这个函数.
    等待管道的另一端写数据.
    此时在另外一个终端执行echo "heihei" > event.fifo 这个就会输出这个heihei.
    
    #include <stdio.h>
    #include <unistd.h>
    #include <sys/types.h>
    #include <sys/stat.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    #include <signal.h>
    #include <event.h>
    #include <errno.h>
    #include <string.h>
    #include <fcntl.h>
    
    void fifo_read(int fd, short event, void *arg)
    {
        char buf[255];
        int len;
        struct event *ev = arg;
        static int count = 0;
    
        /* Reschedule this event */
    //    event_add(ev, NULL);
    
        fprintf(stderr, "fifo_read called with fd: %d, event: %d, arg: %p\n",
            fd, event, arg);
        if (++count == 20) {
            len = read(fd, buf, sizeof(buf) - 1);
    
            if (len == -1) {
                perror("read");
                return;
            } else if (len == 0) {
                fprintf(stderr, "Connection closed\n");
                return;
            }
    
            buf[len] = '\0';
            fprintf(stdout, "Read: %s\n", buf);
        }
    printf("over...\n");
    }
    
    int main()
    {
        struct event evfifo;
        char* fifo = "event.fifo";
    
        unlink(fifo);
        if (mkfifo(fifo, 0777) == -1) {
            perror("mkfifo");
            exit(1);
        }
    
        int socket = open(fifo, O_RDWR | O_NONBLOCK, 0);
        if (socket == -1) {
            perror("open");
            exit(1);
        }
    
        fprintf(stderr, "Write data to %s\n", fifo);
        event_init();
        /* Initalize one event */
        event_set(&evfifo, socket, EV_READ | EV_PERSIST, fifo_read, &evfifo);
        /* Add it to the active events, without a timeout */
        event_add(&evfifo, NULL);
    
        event_dispatch();
    
        return 0;
    }

今天做了一堆的实验 可以得出一些结论:

1. libevent 的event_base是基于线程的.也就是说一个thread只能有一个event_base.如果有多个event_base 那么后来的event_base则会跑到栈的开头,等这个event_base结束以后,这个event_base会结束,原来的event_base又会顶上来. 表现出来的就是 如果在call_accept 里面新建立一个event_base.那么 当telnet成功连接一次,新过来的telnet的连接就不会进入到call_accept这个事件里面. 

2. event_base_loop 启动以后,就不能再往这个event_base添加新的事件了.添加了以后会segmentfault.

3. 基于上面这种情况,所以单线程实现不了能够为多个telnet 提供call_accept的服务. 只能一个telnet->call_accept->str_echo 然后再处理一个新的telnet的请求.

    所以想实现这种为多个telnet 提供服务的,要做成多thread这种,然后每个thread有一个自己的event_base.然后就telnet 连接成功以后的 sfd 传给每个线程,让每个线程在自己的event_base里面监听这个sfd的输入.

4. 还有就是 在memcached里面,dispatch_thread 往 work_thread 写入1个字节的数据.这个时候如果work_thread在忙,没有办法立刻处理这个事件会怎么办. libevent是这样做的. 在dispatch_thread 往 work_thread notify_receive_fd 写入事件后, 如果work_thread 正在忙,那么这个事件会保存在改线程的内存空间里面,一旦该线程没有阻塞.那么又会立刻执行这个事件.

5. TCP断开连接的过程中client会保持一段时间在TIME_WAIT状态. 因为最后的阶段是srv往cli发一个fin,然后cli返回一个ack给srv. 然后会保持一段时间的TIME_WAIT状态,这个时候如果cli又在这个端口建立新连接会出错.得等会.

```
    #include <stdio.h>
    #include <stdlib.h>
    #include <fcntl.h>
    #include <event.h>
    #include <unistd.h>
    #include <netinet/in.h>
    #include <sys/socket.h>
    #include <string.h>
    #include <fcntl.h>
    
    typedef struct sockaddr * SA;
    struct event_base *main_base;
    
    void str_echo(int fd, short event, void *arg)
    {
        char buf[100];
        int n;
    
        n = read(fd, buf, 100);
            fputs("a socket has come\n", stdout);
            write(fd, buf, n);
        if (n < 0) {
            return ;
        }
        return ;
    }
    void call_accept(int fd, short event, void *arg)
    {
        sleep(10);
        printf("come in a new accept\n");
        struct sockaddr_in cliaddr;
        socklen_t clilen;
        int connfd;
        connfd = accept(fd, (struct sockaddr *) &cliaddr, &clilen);
        printf("accept from cliaddr\n");
        char buf[100];
    //    read(fd, buf, 100);
        //str_echo(connfd);
    //    printf("%d\n", (void *)base);
    //    struct event read_ev;
    //    //fcntl(connfd, F_SETFL, O_NONBLOCK);
    //    event_set(&read_ev, connfd, EV_READ, str_echo, &read_ev);
    //    //event_base_set(main_base, &read_ev);
    //    event_add(&read_ev, NULL);
    
    //    event_base_loop(base, 0);
    }
    int main()
    {
        int listenfd, connfd;
        struct sockaddr_in cliaddr, servaddr;
        socklen_t clilen;
    
        listenfd = socket(AF_INET, SOCK_STREAM, 0);
        memset(&servaddr, 0, sizeof(servaddr));
        servaddr.sin_family = AF_INET;
        servaddr.sin_addr.s_addr = htonl(INADDR_ANY);
        servaddr.sin_port = htons(9877);
        bind(listenfd, (struct sockaddr *) &servaddr, sizeof(servaddr));
        listen(listenfd, 10);
    
        struct event ev;
        main_base = event_init();
        event_set(&ev, listenfd, EV_READ | EV_PERSIST, call_accept, &ev);
        //event_base_set(main_base, &ev);
        event_add(&ev, NULL);
        printf("block before accept\n");
        event_base_loop(main_base, 0);    
        printf("after event_dispatch\n");
        return 0;
    }

```

