---
layout: post
title: "event + 线程池模型的 server 类似 Memcache线程池模型"
description: "event, memcache"
category: tech
tags: [network]
---

    /*
        main.h
        定义了三个数据结构 conn_queue_item,work_thread,dispatch_thread.
        conn_queue_item 只是存dispatch_thread accept 以后的描述符,然后
        dispatch_thread 将conn_queue_item 存入某一个work_thread.
        work_thread 真正负责work的thread.
        dispatch_thread 监听9877端口,并且将accept后的fd传给work_thread.
    */
    #ifndef MAINH
    #define MAINH

    #include <stdio.h>
    #include <stdlib.h>
    #include <fcntl.h>
    #include <event.h>
    #include <unistd.h>
    #include <netinet/in.h>
    #include <sys/socket.h>
    #include <string.h>
    #include <fcntl.h>
    #include <pthread.h>
    #include <errno.h>

    typedef struct conn_queue_item CQ;

    struct conn_queue_item {
        int sfd;
    };

    struct WORK_THREAD {
        pthread_t thread_id;
        struct event_base *base;
        struct event notify_event;
        int notify_receive_fd;
        int notify_send_fd;
        struct conn_queue_item cq;
    };
    typedef struct WORK_THREAD wk_thread;

    struct DISPATCH_THREAD {
        pthread_t thread_id;
        struct event_base *base;
    };
    typedef struct DISPATCH_THREAD dh_thread;

    #endif

    主要的执行函数main.c
    #include <stdio.h>
    #include <stdlib.h>
    #include <fcntl.h>
    #include <event.h>
    #include <unistd.h>
    #include <netinet/in.h>
    #include <sys/socket.h>
    #include <string.h>
    #include <fcntl.h>
    #include <pthread.h>
    #include <errno.h>
    #include "main.h"

    static struct event_base *main_base;

    void call_accept(int fd, short event, void *arg)
    {
        fputs("a socket has come\n", stdout);
        struct sockaddr_in cliaddr;
        socklen_t clilen;
        int connfd;
        connfd = accept(fd, (struct sockaddr *) &cliaddr, &clilen);
        dispatch_new_thread(connfd);
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

        struct event_base *mb;
        struct event ev;
        mb = event_init();
        event_set(&ev, listenfd, EV_READ | EV_PERSIST, call_accept, &ev);
        //event_base_set(main_base, &ev);
        event_add(&ev, NULL);
        printf("add the event\n");

        thread_init(10, mb);

        printf("block before accept\n");
        event_base_loop(mb, 0);

        return 0;
    }

    线程池模型. 每一个work_thread监听自己的notify_receive_fd READ 事件,然后dispatch_thread 往notify_receive_fd 写入一字节的数据.接着 work_thread
    就处理从dispatch_thread 传送过来的fd 的请求
    #include <stdio.h>
    #include <stdlib.h>
    #include <fcntl.h>
    #include <event.h>
    #include <unistd.h>
    #include <netinet/in.h>
    #include <sys/socket.h>
    #include <string.h>
    #include <fcntl.h>
    #include <pthread.h>
    #include <errno.h>
    #include "main.h"


    static dh_thread dispatch_thread;

    static wk_thread *threads;

    static int last_thread = -1;

    void dispatch_new_thread(int fd)
    {
        int tid = (last_thread + 1) % 10;
        wk_thread *thread = threads + tid;

        thread->cq.sfd = fd;
        write(thread->notify_send_fd, "", 1);
    }


    void thread_libevent_process(int fd, short which, void *arg)
    {
        wk_thread *work_thread = arg;
        char unuse[1];
        if (read(fd, unuse, 1) != 1) {
            fprintf(stderr, "Can't read from libevent\n");
        }
        char buf[100];
        int n;
        n = read(work_thread->cq.sfd, buf, 100);
        write(work_thread->cq.sfd, buf, n);
    }

    void setup_thread(wk_thread *work_thread)
    {   
        work_thread->base = event_init();
        if (!work_thread->base) {
            fprintf(stdout, "Can't allocate event base\n");
            exit(1);
        }

        event_set(&work_thread->notify_event, work_thread->notify_receive_fd, EV_READ | EV_PERSIST, thread_libevent_process, work_thread);
        event_base_set(work_thread->base, &work_thread->notify_event);
        if (event_add(&work_thread->notify_event, 0) == -1) {
            fprintf(stdout, "Can't add libevent notify pipe\n");
            exit(1);
        }
    }

    void worker_libevent(void *arg)
    {
        wk_thread *work_thread = arg;
        event_base_loop(work_thread->base, 0);
    }

    void create_worker(void *(*func)(void *), void *arg)
    {
        pthread_t thread;
        pthread_attr_t attr;
        int ret;
        pthread_attr_init(&attr);

        if ((ret = pthread_create(&thread, &attr, func, arg)) != 0) {
            fprintf(stdout, "Can't create thread: %s\n", strerror(ret));
            exit(1);
        }
    }


    void thread_init(int t_num, struct event_base *main_base)
    {
        dispatch_thread.base = main_base;
        dispatch_thread.thread_id = pthread_self();
        int i;
        threads = calloc(t_num, sizeof(wk_thread));
        if (!threads) {
            perror("Can't alloc so many thread\n");
            exit(1);
        }

        for (i = 0; i < t_num; i++) {
            int fds[2];
            if (pipe(fds)) {
                perror("can't pipe\n");
                exit(1);
            }
            threads[i].notify_receive_fd = fds[0];
            threads[i].notify_send_fd = fds[1];

            setup_thread(&threads[i]);
        }

        for (i = 0; i < t_num; i++) {
            create_worker(worker_libevent, &threads[i]);
        }

    }
