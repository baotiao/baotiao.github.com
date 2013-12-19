---
layout: post
title: "Memcache 内存分配"
description: "Memcache slabs"
category: tech
tags: [memcache]
---

内存分配主要在slab.c里面实现.
slabclass 的数据结构

    typedef struct {
        unsigned int size;      /* sizes of items */  每一个chunk的大小
        unsigned int perslab;   /* how many items per slab */ 每一个slab包含的chunk的数目
       
        void **slots;           /* list of item ptrs */ 是当前slab class的空闲的chunk块指针数组    
        unsigned int sl_total;  /* size of previous array */ 已分配的slots数据的大小
        unsigned int sl_curr;   /* first free slot */ 当前可用的slots数组的索引
       
        void *end_page_ptr;         /* pointer to next free item at end of page, or 0 */ //这个指针指向最新的那个page可用的chunk处
        unsigned int end_page_free; /* number of items remaining at end of last alloced page */ //这个是新的那个page里面可用的chunk的个数,如果*end_page_prt != NUll 并且 end_page_free == 0 说明最后一个page也被填满数据了.
       
        unsigned int slabs;     /* how many slabs were allocated for this class */ //这个是当前已使用的slab_list的数量
       
        void **slab_list;       /* array of slab pointers */ //这个是所有的page的list, 每新添加一个page.
        unsigned int list_size; /* size of prev array */ //slab_list指针数组已分配的大小
       
        unsigned int killing;  /* index+1 of dying slab, or zero if none */
        size_t requested; /* The number of requested bytes */
    } slabclass_t;

slabs 模型. (网上找的,我觉得表示最好的一张图,结合图看下面的函数分析)
[![](http://chenzongzhi.info/wp-content/uploads/2012/02/slabs.jpeg)](http://chenzongzhi.info/wp-content/uploads/2012/02/slabs.jpeg)﻿

几个重要变量

    static slabclass_t slabclass[MAX_NUMBER_OF_SLAB_CLASSES];
    static size_t mem_limit = 0; //内存限制的大小
    static size_t mem_malloced = 0;
    static int power_largest;

    static void *mem_base = NULL; //分配的整块大内存的位置
    static void *mem_current = NULL; //目前可用的内存的位置
    static size_t mem_avail = 0; //剩余可用的内存的大小
     
函数介绍:

    /*
         就是根据传进来的size.找到第一个slab class的size比他大的slab class.返回slab class的id.
    */
    unsigned int slabs_clsid(const size_t size) {
        int res = POWER_SMALLEST;

        if (size == 0)
            return 0;
        while (size > slabclass[res].size)
            if (res++ == power_largest)     /* won't fit in the biggest slab */
                return 0;
        return res;
    }

    /*
         slabs初始化函数,初始化了生成一个链表slabclass.
         slabclass 就是size大小不同的,然后size * perslab = 1M的一个链表,然后在这个链表里面每添加一个slab,这个slab也叫page.也就是不断往这个链表后面添加page.然后每个page里面的有perslab 数的chunk,然后真正的数据是叫item,item存在正好比item大一点的chunk上.
         以后每次添加新的page,都是先找到相应大小的那个类型的slab,然后插入在slabclass这个链表的slab_list的后面
    */
         
    void slabs_init(const size_t limit, const double factor, const bool prealloc) {
        int i = POWER_SMALLEST - 1;
        unsigned int size = sizeof(item) + settings.chunk_size; //初始化最小的slabclass里面的size
        mem_limit = limit;

        if (prealloc) { //选择了prealloc就是预先分配一个大内存 然后初始化mem_base,mem_current,mem_avail.
            /* Allocate everything in a big chunk with malloc */
            mem_base = malloc(mem_limit); //分配mem_limit大小的内存
            if (mem_base != NULL) {
                mem_current = mem_base;
                mem_avail = mem_limit;
            } else {
                fprintf(stderr, "Warning: Failed to allocate requested memory in"
                        " one large chunk.\nWill allocate in smaller chunks\n");
            }
        }

        memset(slabclass, 0, sizeof(slabclass));

        /*
            这里是初始化slabclass链表的过程,根据最小的size.然后size*factor 逐渐加上去
            直到size = 1M 为止
        */
        while (++i < POWER_LARGEST && size <= settings.item_size_max / factor) {

        省略..
                 if (pre_alloc == NULL || atoi(pre_alloc) != 0) {
                slabs_preallocate(power_largest);
              //这个函数是给没一个slabclass都预先分配一个slabs,也就是1M的大小.
              //所以每一个slabclass都会有一个1M大小的空间.不过这样有存在内存浪费,因为有可能有些
              //slabs不会被用到
            }
    }

    /*
         预先为所有的slabclass分配空间
    */
    static void slabs_preallocate (const unsigned int maxslabs) {
        int i;
        unsigned int prealloc = 0;

        /* pre-allocate a 1MB slab in every size class so people don't get
           confused by non-intuitive "SERVER_ERROR out of memory"
           messages.  this is the most common question on the mailing
           list.  if you really don't want this, you can rebuild without
           these three lines.  */

        for (i = POWER_SMALLEST; i <= POWER_LARGEST; i++) {
            if (++prealloc > maxslabs)
                return;
            do_slabs_newslab(i);
        }
    }

    /*
        调整slabclass的slab_list指针数组,如果为空,这默认分配16个,如果存在,那么*2的增加slab_list数组*/
    static int grow_slab_list (const unsigned int id) {
        slabclass_t *p = &slabclass;[id];
        if (p->slabs == p->list_size) {  //当slabclass里面的slabs(当前已使用的slab_list的数量)和list_size(已分配的slab_list的数量)相等时,
                                        //表示这个slab_list的已经用完了,需要生成新的slab_list
            size_t new_size =  (p->list_size != 0) ? p->list_size * 2 : 16; //如果list_size是空,自>动生成16个,否则就是*2的增长
            void *new_list = realloc(p->slab_list, new_size * sizeof(void *)); //把这个list realloc到新的空间去
            if (new_list == 0) return 0;
            p->list_size = new_size;
            p->slab_list = new_list;
        }
        return 1;
    }

    /*
        为某一个slabclass分配一个新的slab.真正执行分配一个slab的是memory_allocate函数
        其实memori_alocate函数做的就是从mem_current找到len大小的空间,并返回mem_current的地址
    */
    static int do_slabs_newslab(const unsigned int id) {
        slabclass_t *p = &slabclass;[id];
        int len = p->size * p->perslab;
        char *ptr;

        /*
            这里判断slab_list这个指针数据大小够不够,不够分配新的空间.
            memory_allocate分配新的大小的空间
        */
        if ((mem_limit && mem_malloced + len > mem_limit && p->slabs > 0) ||
            (grow_slab_list(id) == 0) ||
            ((ptr = memory_allocate((size_t)len)) == 0)) { //在这里声明大小为 1M的page.

            MEMCACHED_SLABS_SLABCLASS_ALLOCATE_FAILED(id);
            return 0;
        }     

        memset(ptr, 0, (size_t)len);
        p->end_page_ptr = ptr; //将end_page_ptr 也就是表示最新的可用的chunk的指针指向ptr
        p->end_page_free = p->perslab; //end_page_free 因为这里是一个全新的page 所以 end_page_free = p->perslabs
        p->slab_list[p->slabs++] = ptr; //将ptr 加入道p->slab_list里面去,并且 page 的个数++
        mem_malloced += len;
        MEMCACHED_SLABS_SLABCLASS_ALLOCATE(id);

        return 1;
    }

    /*
        这个是进行给slab分配内存的函数,会判断是否有足够的空间,已经然后将目前的mem_current返回,然后>调整mem_current的值
    */
    static void *memory_allocate(size_t size) {
        void *ret;

        if (mem_base == NULL) {
            /* We are not using a preallocated large memory chunk */
            ret = malloc(size);
        } else {
            ret = mem_current;

            if (size > mem_avail) {
                return NULL;
            }

            /* mem_current pointer _must_ be aligned!!! */
            if (size % CHUNK_ALIGN_BYTES) {
                size += CHUNK_ALIGN_BYTES - (size % CHUNK_ALIGN_BYTES);
            }

            mem_current = ((char*)mem_current) + size;

            if (size < mem_avail) {
                mem_avail -= size;
            } else {
                mem_avail = 0;
            }
        }

        return ret;
    }

到此处理slabs已经初始化结束了.memcached还提供了一个空闲item链表,叫slots.就是当一个slabs里面的item已经过期了,那么这个chunk不是退回给内存池,而是放入到这个空闲链表里面去,同样当申请一个新元素的时候也是先判断这个slots数组是否有空间,没有空间再去slabs里面去获得.

    static void *do_slabs_alloc(const size_t size, unsigned int id) {
         ..省略..
    /*
            这里判断end_page_ptr是否指向可用的chunk, 当前slabclass的slots的空闲chunk个数
            以及是否可以新分配一块slab
            如果可以获得空间的话,先从slabclass的slots里面获得,然后才是从slab里面的end_page_ptr处去>获得
        */
        if (! (p->end_page_ptr != 0 || p->sl_curr != 0 ||
               do_slabs_newslab(id) != 0)) {
            /* We don't have more memory available */
            ret = NULL;
        } else if (p->sl_curr != 0) {
            /* return off our freelist */
            ret = p->slots[--p->sl_curr];
        } else {
            /* if we recently allocated a whole page, return from that */
            assert(p->end_page_ptr != NULL);
            ret = p->end_page_ptr;
            if (--p->end_page_free != 0) {
                p->end_page_ptr = ((caddr_t)p->end_page_ptr) + p->size;
            } else {
                p->end_page_ptr = 0;
            }
        }

        if (ret) {
            p->requested += size;
            MEMCACHED_SLABS_ALLOCATE(size, id, p->size, ret);
        } else {
            MEMCACHED_SLABS_ALLOCATE_FAILED(size, id);
        }

        return ret;
    }

这个函数主要是将slab里面的chunk设置成free. 设置free不是把他归还给内存池
而是把这个item放入到这个slabclass的slots中

    static void do_slabs_free(void *ptr, const size_t size, unsigned int id) {
        slabclass_t *p;

        assert(((item *)ptr)->slabs_clsid == 0);
        assert(id >= POWER_SMALLEST && id <= power_largest);
        if (id < POWER_SMALLEST || id > power_largest)
            return;

        MEMCACHED_SLABS_FREE(size, id, ptr);
        p = &slabclass;[id];

        /*
            刚开始看这里的时候不明白,为什么slots数组需要malloc空间,
            因为slots是指针数组,这里malloc分配的内存空间是给这个指针数组的.
            然后这个数组每一个都指向在slab里面被free的chunk.
        */
        if (p->sl_curr == p->sl_total) { /* need more space on the free list */
            int new_size = (p->sl_total != 0) ? p->sl_total * 2 : 16;  /* 16 is arbitrary */
            void **new_slots = realloc(p->slots, new_size * sizeof(void *));
            //这里是给slots数组malloc了这么多数量的void指针.
            if (new_slots == 0)
                return;
            p->slots = new_slots;
            p->sl_total = new_size;
        }
        p->slots[p->sl_curr++] = ptr; //这里把sl_curr指向了这个ptr,这个ptr就是一个slab里面的一个空>闲的chunk处.所以这里空闲数组又获得了一个空间,这里sl_curr可用的slots数+1.
        p->requested -= size;
        return;
    }
