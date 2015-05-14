---
layout: post
title: "Mesos libprocess Synchronized Implement"
description: "Mesos Synchronized Implement"
category: tech
tags: [mesos, c++]
---

最近由于项目的需要, 在看Mesos 的代码

觉得libprocess 里面实现的Synchronized 实现的挺有意思就摘取出来了


``` 
#include <pthread.h>
#include <iostream>

class Synchronizable
{
public:
    Synchronizable()
        : initialized(false) {}

    explicit Synchronizable(int _type)
        : type(_type), initialized(false)
    {
        initialize();
    }

    Synchronizable(const Synchronizable &that)
    {
        type = that.type;
        initialize();
    }

    Synchronizable & operator = (const Synchronizable &that)
    {
        type = that.type;
        initialize();
        return *this;
    }

    void acquire()
    {
        if (!initialized) {
        }
        pthread_mutex_lock(&mutex);
    }

    void release()
    {
        if (!initialized) {
        }
        pthread_mutex_unlock(&mutex);
    }

private:
    void initialize()
    {
        if (!initialized) {
            pthread_mutexattr_t attr;
            pthread_mutexattr_init(&attr);
            pthread_mutexattr_settype(&attr, type);
            pthread_mutex_init(&mutex, &attr);
            pthread_mutexattr_destroy(&attr);
            initialized = true;
        } else {
        }
    }

    int type;
    bool initialized;
    pthread_mutex_t mutex;
};


class Synchronized
{
public:
    explicit Synchronized(Synchronizable *_synchronizable)
        : synchronizable(_synchronizable)
    {
        synchronizable->acquire();
    }

    ~Synchronized()
    {
        synchronizable->release();
    }

    operator bool () { return true; }

private:
    Synchronizable *synchronizable;
};


#define synchronized(s)                                                 \
    if (Synchronized __synchronized ## s = Synchronized(&__synchronizable_ ## s))

#define synchronizable(s)                       \
    Synchronizable __synchronizable_ ## s

#define synchronizer(s)                         \
    (__synchronizable_ ## s)


#define SYNCHRONIZED_INITIALIZER                \
    Synchronizable(PTHREAD_MUTEX_NORMAL)

#define SYNCHRONIZED_INITIALIZER_DEBUG          \
    Synchronizable(PTHREAD_MUTEX_ERRORCHECK)

#define SYNCHRONIZED_INITIALIZER_RECURSIVE      \
    Synchronizable(PTHREAD_MUTEX_RECURSIVE)


/*
 * 这里是libprocess 里面锁的实现, 能够保证的力度是一个函数的力度.
 * 只要在这一个函数里面声明了不一样的synchronizable(prefixes), 那么就可以保证在
 * 执行 synchronized (prefixes) 的时候是只有一个线程能够执行到的
 * 可以 gcc -E % 可以看出这里宏到底做了什么
 *
 * string generate(const string& prefix)
 * {
 *     static map<string, int>* prefixes = new map<string, int>();
 *     static Synchronizable __synchronizable_prefixes = Synchronizable(0);
 * 
 *     int id;
 *     这里Synchronized(&__synchronizable_prefixes) 构造函数里面就对这个变量 
 *     pthread_mutex_lock(&mutex);
 *     那么如果有多个线程执行到这里, 其实只有一个线程能够执行的.
 *     那么这里为什么要赋值呢?
 *     因为这里这个变量没有copy assign 构造函数, 那么默认的就是全拷贝.
 *     那么这里这个变量的__synchronizedprefixes 的作用域就是 if()之间的内容
 *     而Synchronized 这个类型默认的析构函数就是释放这个锁,
 *     因此可以做到进入这个if 内容以后, 就把这个锁给释放了
 *     
 *     if (Synchronized __synchronizedprefixes = Synchronized(&__synchronizable_prefixes)) {
 *         int& _id = (*prefixes)[prefix];
 *         _id += 1;
 *         id = _id;
 *     }
 *     printf("%d\n", id);
 *     return prefix + "(" + ")";
 * }
 *
 * 之前有文章介绍leveldb 锁的实现也很好看. 这里与leveldb 对比一下主要区别在于
 * leveldb 需要在类的内部定义mutex的变量. 不能想用的时候就用
 * mesos 这里可以想保证锁的时候就可以保证, 但是因为这个声明的变量是 static,
 * 存在于全局的.data段里面, 因此生命周期是整个进程的生命周期
 */

using namespace std;
#include <map>
#include <string>
string generate(const string& prefix)
{
    static map<string, int>* prefixes = new map<string, int>();
    static synchronizable(prefixes) = SYNCHRONIZED_INITIALIZER;

    int id;
    synchronized (prefixes) {
        int& _id = (*prefixes)[prefix];
        _id += 1;
        id = _id;
    }
    printf("%d\n", id);
    return prefix + "(" + ")";
}


int main()
{
    printf("%s\n", generate("heihei").c_str());
    return 0;
}

```
