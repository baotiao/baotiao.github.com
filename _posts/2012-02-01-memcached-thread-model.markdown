---
layout: post
title: "Memcache threads analysis"
description: "Memcache analysis"
category: tech
tags: [memcache, sourcecode]
---

memcached 启动时线程处理流程

[![](http://175.41.172.193/wp-content/uploads/2012/02/thread1-113x300.jpg)](http://175.41.172.193/wp-content/uploads/2012/02/thread1.jpg)

memcached 是利用libevent实现了一个线程池.有一个dispatch_thread 和 n 个work_thread构成.

主要的数据结构以及简单操作
在thread.c里面有

    /* An item in the connection queue. */
    typedef struct conn_queue_item CQ_ITEM;
    struct conn_queue_item {
        int               sfd;  //对应每个connection的 fd
        enum conn_states  init_state;
        int               event_flags;
        int               read_buffer_size;
        enum network_transport     transport;
        CQ_ITEM          *next;
    };

这个CQ_ITEM 是对每一个connection的描述.

    /* A connection queue. */
    typedef struct conn_queue CQ;
    struct conn_queue {
        CQ_ITEM *head;
        CQ_ITEM *tail;
        pthread_mutex_t lock;
        pthread_cond_t  cond;

    };

这个就是connection_queue 每个工作线程都有一个connection queue. CQ中的每个CQ_ITEM都是对一个socket连接的简单描述.

    /* * Looks for an item on a connection queue, but doesn't block if there isn't
     * one.
     * Returns the item, or NULL if no item is available
     */
    static CQ_ITEM *cq_pop(CQ *cq) {
        CQ_ITEM *item;

        pthread_mutex_lock(&cq-;>lock);
        item = cq->head;
        if (NULL != item) {
            cq->head = item->next;
            if (NULL == cq->head)
                cq->tail = NULL;
        }
        pthread_mutex_unlock(&cq-;>lock);

        return item;
    }

这个是对cq里面的item的pop操作. 可以看出cq只是指向了item,然后通过item之间的链表连接起来.从而获得每个工作线程需要处理的item.

有1个空闲的CQ_ITEM链表

    static CQ_ITEM *cqi_freelist; //这是空闲的cqitem 链表
    static pthread_mutex_t cqi_freelist_lock; //这个是链表的锁.用于对链表添加元素时加锁

    /* * Returns a fresh connection queue item.
     */
    static CQ_ITEM *cqi_new(void) {
        CQ_ITEM *item = NULL;
        pthread_mutex_lock(&cqi;_freelist_lock);
        if (cqi_freelist) {
            item = cqi_freelist;
            cqi_freelist = item->next;
        }
        pthread_mutex_unlock(&cqi;_freelist_lock);

        if (NULL == item) {
            int i;

            /* Allocate a bunch of items at once to reduce fragmentation */
            item = malloc(sizeof(CQ_ITEM) * ITEMS_PER_ALLOC);
            if (NULL == item)
                return NULL;
    /*其中 malloc的时候是直接malloc(sizeof(CQ_ITEM) * ITEMS_PER_ALLOC) ITEMS_PER_ALLOC个的CQ_ITEM 减少了每个item之间的碎片的产生.*/

            /*
             * Link together all the new items except the first one
             * (which we'll return to the caller) for placement on
             * the freelist.
             */
            for (i = 2; i < ITEMS_PER_ALLOC; i++)
                item[i - 1].next = &item;[i];

            pthread_mutex_lock(&cqi;_freelist_lock);
            item[ITEMS_PER_ALLOC - 1].next = cqi_freelist;
            cqi_freelist = &item;[1];
            pthread_mutex_unlock(&cqi;_freelist_lock);
        }

        return item;
    }

这是new 一个cq_item的操作, 其中 malloc的时候是直接malloc(sizeof(CQ_ITEM) * ITEMS_PER_ALLOC) ITEMS_PER_ALLOC个的CQ_ITEM 减少了每个item之间的碎片的产生.然后是将malloc出来的这么多的cq_item链接起来.然后再将其加入到 cqi_freelist中.

    /*
     * Frees a connection queue item (adds it to the freelist.)
     */
    static void cqi_free(CQ_ITEM *item) {
        pthread_mutex_lock(&cqi;_freelist_lock);
        item->next = cqi_freelist;
        cqi_freelist = item;
        pthread_mutex_unlock(&cqi;_freelist_lock);
    }

Free 一个cq_item 的时候是将其直接放入到cqi_freelist里面去.

每一个work_thread在初始化的时候都有一个cq

    typedef struct conn conn;struct conn {
        int    sfd;
        sasl_conn_t *sasl_conn;
        enum conn_states  state;
        enum bin_substates substate;
        struct event event;
        short  ev_flags;
        short  which;   /** which events were just triggered */

        char   *rbuf;   /** buffer to read commands into */
        char   *rcurr;  /** but if we parsed some already, this is where we stopped */
        int    rsize;   /** total allocated size of rbuf */
        int    rbytes;  /** how much data, starting from rcur, do we have unparsed */

        char   *wbuf;
        char   *wcurr;    int    wsize;
        int    wbytes;
        /** which state to go into after finishing current write */
        enum conn_states  write_and_go;
        void   *write_and_free; /** free this memory after finishing writing */

        char   *ritem;  /** when we read in an item's value, it goes here */
        int    rlbytes;

        /* data for the nread state */

        /**
         * item is used to hold an item structure created after reading the command
         * line of set/add/replace commands, but before we finished reading the actual
         * data. The data is read into ITEM_data(item) to avoid extra copying.
         */

        void   *item;     /* for commands set/add/replace  */

        /* data for the swallow state */
        int    sbytes;    /* how many bytes to swallow */

        /* data for the mwrite state */
        struct iovec *iov;
        int    iovsize;   /* number of elements allocated in iov[] */
        int    iovused;   /* number of elements used in iov[] */

        struct msghdr *msglist;
        int    msgsize;   /* number of elements allocated in msglist[] */
        int    msgused;   /* number of elements used in msglist[] */
        int    msgcurr;   /* element in msglist[] being transmitted now */
        int    msgbytes;  /* number of bytes in current msg */

        item   **ilist;   /* list of items to write out */
        int    isize;
        item   **icurr;
        int    ileft;

        char   **suffixlist;
        int    suffixsize;
        char   **suffixcurr;
        int    suffixleft;

        enum protocol protocol;   /* which protocol this connection speaks */
        enum network_transport transport; /* what transport is used by this connection */

        /* data for UDP clients */
        int    request_id; /* Incoming UDP request ID, if this is a UDP "connection" */
        struct sockaddr request_addr; /* Who sent the most recent request */
        socklen_t request_addr_size;
        unsigned char *hdrbuf; /* udp packet headers */
        int    hdrsize;   /* number of headers' worth of space is allocated */

        bool   noreply;   /* True if the reply should not be sent. */
        /* current stats command */
        struct {
            char *buffer;
            size_t size;
            size_t offset;

        } stats;
        /* Binary protocol stuff */
        /* This is where the binary header goes */
        protocol_binary_request_header binary_header;
        uint64_t cas; /* the cas to return */
        short cmd; /* current command being processed */
        int opaque;
        int keylen;
        conn   *next;     /* Used for generating a list of conn structures */
        LIBEVENT_THREAD *thread; /* Pointer to the thread object serving this connection */
    };

memcached 的conn 代表一个到memcached的链接.
里面的item是连接成功后,读入 set/add/replace 生成的cq_item.
conn->thread 是指向要处理的线程对象.然后将item加入到LIBEVENT_THREAD 对象的 struct conn_queue new_conn_queue中
同样也是有一个free list 叫 freeconns

    static conn **freeconns;
    static int freetotal; //总的freeconns的大小
    static int freecurr; //目前的空闲的 freeconn 的大小

    /*
     * Adds a connection to the freelist. 0 = success.
     */
    bool conn_add_to_freelist(conn *c) {
        bool ret = true;
        pthread_mutex_lock(&conn;_lock);
        if (freecurr < freetotal) {
            freeconns[freecurr++] = c;
            ret = false;
        } else {
            /* try to enlarge free connections array */
            size_t newsize = freetotal * 2;
            conn **new_freeconns = realloc(freeconns, sizeof(conn *) * newsize);
            if (new_freeconns) {
                freetotal = newsize;
                freeconns = new_freeconns;
                freeconns[freecurr++] = c;
                ret = false;
            }
        }
        pthread_mutex_unlock(&conn;_lock);
        return ret;
    }

添加一个 connection 到 freelist, 如果超过了freetotal的大小,那么就将freetotal*2 然后realloc一块新的是原来2倍内存的大小.然后把这个connection添加进去,发现好多地方都是这么做的

memcached的多线程主要是通过实例化多个libevent实现的,分别是一个主线程和n个worker线程.无论是主线程还是worker线程全部通过libevent管理网络事件,实际上每个线程都是一个单独的libevent实例.
主线程负责监听客户端的建立连接请求,以及建立连接后将连接好后生成的connection发送给work_thread去负责处理

[![](http://175.41.172.193/wp-content/uploads/2012/02/thread2-300x234.jpg)](http://175.41.172.193/wp-content/uploads/2012/02/thread2.jpg)

dispatcher_thread 和 worker_thread 的定义

    typedef struct {
        pthread_t thread_id;        /* unique ID of this thread */
        struct event_base *base;    /* libevent handle this thread uses */
        struct event notify_event;  /* listen event for notify pipe */
        int notify_receive_fd;      /* receiving end of notify pipe */
        int notify_send_fd;         /* sending end of notify pipe */
        struct thread_stats stats;  /* Stats generated by this thread */
        struct conn_queue *new_conn_queue; /* queue of new connections to handle */
        cache_t *suffix_cache;      /* suffix cache */
    } LIBEVENT_THREAD;

    typedef struct {
        pthread_t thread_id;        /* unique ID of this thread */
        struct event_base *base;    /* libevent handle this thread uses */
    } LIBEVENT_DISPATCHER_THREAD;

    thread_init是启动所有的worker线程的核心方法.
    void thread_init(int nthreads, struct event_base *main_base) {
         ......//加锁等操作
        for (i = 0; i < item_lock_count; i++) {
            pthread_mutex_init(&item;_locks[i], NULL);
        }

        threads = calloc(nthreads, sizeof(LIBEVENT_THREAD));
        if (! threads) {
            perror("Can't allocate thread descriptors");
            exit(1);
        }

        dispatcher_thread.base = main_base; //dispatcher_thread是静态的全局变量.dispatcher_thread 注册的事件是main_base时间,也就是负责监听socket请求的事件
        dispatcher_thread.thread_id = pthread_self(); 

        for (i = 0; i < nthreads; i++) { //这里是为每一个线程创建一个pipe,这个pipe被用来作为dispatch通知worker线程有新的连接到达
            int fds[2];
            if (pipe(fds)) {
                perror("Can't create notify pipe");
                exit(1);
            }

            threads[i].notify_receive_fd = fds[0];
            threads[i].notify_send_fd = fds[1];

            setup_thread(&threads;[i]);
            /* Reserve three fds for the libevent base, and two for the pipe */
            stats.reserved_fds += 5;
        }

        /* Create threads after we've done all the libevent setup. */
        for (i = 0; i < nthreads; i++) {
            create_worker(worker_libevent, &threads;[i]);
        }

然后是setup_thread 方法,setup_thread 方法主要是创建所有worker线程的libevent实例(主线程的libevent实例在main函数里面创建)
注册所有worker线程的管道读端的libevent的读事件,等待主线程的通知.然后初始化所有worker的CQ.

    static void setup_thread(LIBEVENT_THREAD *me) {
        me->base = event_init();
        if (! me->base) {
            fprintf(stderr, "Can't allocate event base\n");
            exit(1);
        }

        /* Listen for notifications from other threads */
        event_set(&me-;>notify_event, me->notify_receive_fd,
                  EV_READ | EV_PERSIST, thread_libevent_process, me);
        event_base_set(me->base, &me-;>notify_event);

        if (event_add(&me-;>notify_event, 0) == -1) {
            fprintf(stderr, "Can't monitor libevent notify pipe\n");
            exit(1);
        }

        me->new_conn_queue = malloc(sizeof(struct conn_queue));
        if (me->new_conn_queue == NULL) {
            perror("Failed to allocate memory for connection queue");
            exit(EXIT_FAILURE);
        }
        cq_init(me->new_conn_queue);

        if (pthread_mutex_init(&me-;>stats.mutex, NULL) != 0) {
            perror("Failed to initialize mutex");
            exit(EXIT_FAILURE);
        }

        me->suffix_cache = cache_create("suffix", SUFFIX_SIZE, sizeof(char*),
                                        NULL, NULL);
        if (me->suffix_cache == NULL) {
            fprintf(stderr, "Failed to create suffix cache\n");
            exit(EXIT_FAILURE);
        }
    }

然后 create_worker启动了所有线程,pthread_create调用worker_libevent方法,这个方法又调用event_base_loop() 启动该线程的libevent.

在server_socket函数中,主要就是建立一个socket并且绑定到一个port上.然后调用conn_new(这里传入的事件是main_base)注册事件
event_set(&c->event, sfd, event_flags, event_handler, (void *)c);
事件为持久可读,所以dispatch_thread在当前listen的socket可读时,就会调用event_handler,进而调用driver_machine(c) 进入状态机.而在driver_machin中,如果是主线程(dispatch_thread)则会在accept socket 后调用dispatch_new_conn函数来给各个work_thread派发connection

    static int server_socket(const char *interface,
                             int port,
                             enum network_transport transport,
                             FILE *portnumber_file) {
         ....
                if (!(listen_conn_add = conn_new(sfd, conn_listening,
                                                 EV_READ | EV_PERSIST, 1,
                                                 transport, main_base))) { 


至此 dispatch_thread 和 worker_threads的libevent都已开启

thread_libevent_process是worker_thread的管道读端有事件的时候调用的方法.参数fd是这个worker_thread的管道读端的描述符.
首先将管道的1个字节读出,这一个字节是dispatch_thread写入的.用来通知表示有数据写入.然后从自己的CQ里面pop出一个item进行处理,这个item是被dispatch_thread丢到这个cq队列中的.
item->sfd是已建立的socket连接的描述符,通过conn_new函数为该描述符注册libevent的读事件,me->base 是 struct event_base 代表自己的一个线程结构体,就是说对该描述符的事件处理交给当前这个worker_thread处理.

    /*
     * Processes an incoming "handle a new connection" item. This is called when
     * input arrives on the libevent wakeup pipe.
     */
    static void thread_libevent_process(int fd, short which, void *arg) {
        LIBEVENT_THREAD *me = arg;
        CQ_ITEM *item;
        char buf[1];

        if (read(fd, buf, 1) != 1)
            if (settings.verbose > 0)
                fprintf(stderr, "Can't read from libevent pipe\n");

        item = cq_pop(me->new_conn_queue);

        if (NULL != item) {
            conn *c = conn_new(item->sfd, item->init_state, item->event_flags,
                               item->read_buffer_size, item->transport, me->base);

接下来是conn_new函数,前面是一系列的判断,从conn_from_freelist()取得连接.
这里注册了事件,由当前线程处理,(因为这里的event_base是改work_thread自己的)
当该连接有可读时会回调event_handler函数,event_handler调用memcached最核心的方法drive_machine.


    conn *conn_new(const int sfd, enum conn_states init_state,
                    const int event_flags,
                    const int read_buffer_size, enum network_transport transport,
                    struct event_base *base) {
         ......
        event_set(&c-;>event, sfd, event_flags, event_handler, (void *)c);
        event_base_set(base, &c-;>event);
        c->ev_flags = event_flags;

        if (event_add(&c-;>event, 0) == -1) {
            if (conn_add_to_freelist(c)) {
                conn_free(c);
            }
            perror("event_add");
            return NULL;
        }

        STATS_LOCK();
        stats.curr_conns++;
        stats.total_conns++;
        STATS_UNLOCK();

        MEMCACHED_CONN_ALLOCATE(c->sfd);

        return c;

上面将dispatch_thread 会向work_thread写入一字节的数据.dispatch_thread注册的是监听socket可读的事件,然后当有建立连接请求时,dispatch_thread会处理,回调函数也是event_handler(因为dispatch_thread也是通过conn_new初始化监听socket的libevent可读事件)

driven_machine 网络事件处理最核心函数 是所有线程在connection来到时都要调用的函数.
driven_machine 主要就是通过当前连接的conn的state来判断进行何种处理,因为libevent注册了读写事件回调的都是这个函数,所以实际上我们在注册libevent相应事件时,会同时把事件的状态写入到conn结构体里,libevent进行回调时会把该conn结构作为参数传过来

    static void drive_machine(conn *c) {
         ...
        while (!stop) {
         ...
            switch(c->state) {

            case conn_listening:// 该状态是conn_listening状态,只有dispatch_thread才会进入
              ....
              dispatch_conn_new(sfd, conn_new_cmd,EV_READ|EV_PERSIST,
                                         DATA_BUFFER_SIZE, tcp_transport);
              //这里就是dispatch_thread 通知 work_thread 的地方了.

memcached.h里面conn的stat的声明

    /*
     * NOTE: If you modify this table you _MUST_ update the function state_text
     */
    /**
     * Possible states of a connection.
     */
    enum conn_states {
        conn_listening,  /**< the socket which listens for connections */
        conn_new_cmd,    /**< Prepare connection for next command */
        conn_waiting,    /**< waiting for a readable socket */
        conn_read,       /**< reading in a command line */
        conn_parse_cmd,  /**< try to parse a command from the input buffer */
        conn_write,      /**< writing out a simple response */
        conn_nread,      /**< reading in a fixed number of bytes */
        conn_swallow,    /**< swallowing unnecessary bytes w/o storing */
        conn_closing,    /**< closing this connection */
        conn_mwrite,     /**< writing out many items sequentially */
        conn_max_state   /**< Max state value (used for assertion) */
    };

    dispatch_conn_new 将一个新的connection给另外一个thread.这个函数只有dispatch_thread才会调用.
    /* Which thread we assigned a connection to most recently. */
    static int last_thread = -1;
    /* 这里是静态变量 last_thread 记录的是上一次调用的thread.所以这里memcached并没有用高深的方法记录将connection 分发给哪一个thread.只是用轮询的方法实现
    这里dispatch_thread 创建了一个ca_item,并插入到一个thread的cq里面.然后往对应的work_thread写入1字节的数据来通知他.这个时候work_thread立即回调了thread_libevent_process的方法来对数据进行读取. 然后work_thread线程取出这个item(item 里面包含了这次connection 的连接sfd),注册读时间,当该条连接上有数据时,最终也会回调drive_machine方法,也就是driven_machine 的 conn_read. 其他的conn 的状态全部由work_thread去处理,dispatch_thread 只负责将item 发到对应的work_thread中去.
    */

    void dispatch_conn_new(int sfd, enum conn_states init_state, int event_flags,
                           int read_buffer_size, enum network_transport transport) {
        CQ_ITEM *item = cqi_new();
        int tid = (last_thread + 1) % settings.num_threads;
    //这里是通过轮询找到目前要分配给的thread

        LIBEVENT_THREAD *thread = threads + tid;

        last_thread = tid;

        item->sfd = sfd;
        item->init_state = init_state;
        item->event_flags = event_flags;
        item->read_buffer_size = read_buffer_size;
        item->transport = transport;

        cq_push(thread->new_conn_queue, item);

        MEMCACHED_CONN_DISPATCH(sfd, thread->thread_id);
        if (write(thread->notify_send_fd, "", 1) != 1) { //这里就是往work_thread的notify_fd 写入1字节的数据.来
            perror("Writing to thread notify pipe");
        }
    }

