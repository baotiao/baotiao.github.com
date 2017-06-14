---
layout: post
title: systemtap tips and examples
summary: systemtap tips and examples

---

### systemtap tips and example

man stapprobes 可以看到大部分的文档信息

#### stap 常用参数:

-c: 通过指定 -c 参数可以在运行stap 程序的时候通过target() 获得当前的pid() 写起来很方便

stap m.stp -c ./a.out  

那么程序里面就可以这么写

`if` (target()== pid()) {

-x: 和 -c 一样可以再 target() 里面获得pid

-d: 增加某一个库的或者二进制文件

sudo stap tm.stp  -d /lib64/libc-2.12.so -d /usr/local/pika22/bin/pika



可以通过stap -l 看到不管是用户空间还是内核里面的某一个函数所在的路径. 换成 -L 可以看到具体可以看的变量 

```shell
[xusiliang@redis220 ~]$ stap -l 'process("/usr/local/pika22/bin/pika").function("AutoPurge")'
process("/usr/local/pika22/bin/pika").function("AutoPurge@src/pika_server.cc:1164")

[xusiliang@redis220 ~]$ stap -L 'process("/usr/local/pika22/bin/pika").function("AutoPurge")'
process("/usr/local/pika22/bin/pika").function("AutoPurge@src/pika_server.cc:1164") $this:class PikaServer* const

# 还可以使用正则, 看到所有的函数
[xusiliang@redis220 ~]$ stap -L 'process("/usr/local/pika22/bin/pika").function("Auto*")'
process("/usr/local/pika22/bin/pika").function("AutoCompactRange@src/pika_server.cc:1114") $this:class PikaServer* const
process("/usr/local/pika22/bin/pika").function("AutoPurge@src/pika_server.cc:1164") $this:class PikaServer* const
process("/usr/local/pika22/bin/pika").function("AutoRollLogger@./db/auto_roll_logger.h:24")
process("/usr/local/pika22/bin/pika").function("AutoThreadOperationStageUpdater@util/thread_status_util.cc:161") $this:class AutoThreadOperationStageUpdater* const $stage:enum OperationStage

# 想使用statement probe 的时候, 很多时候某些行是有问题的, 这个时候只能通过 -L 可以看出到底哪些行可以probe, 这里就是在fork.c 里面这个copy_process 可以加statement 的地方
└─[$] sudo stap -L 'kernel.statement("copy_process@fork.c:*")'
kernel.statement("copy_process@kernel/fork.c:1148") $clone_flags:long unsigned int $stack_start:long unsigned int $stack_size:long unsigned int $child_tidptr:int* $pid:struct pid* $trace:int
kernel.statement("copy_process@kernel/fork.c:1158") $trace:int $pid:struct pid* $child_tidptr:int* $stack_size:long unsigned int $stack_start:long unsigned int $clone_flags:long unsigned int
kernel.statement("copy_process@kernel/fork.c:1161") $trace:int $pid:struct pid* $child_tidptr:int* $stack_size:long unsigned int $stack_start:long unsigned int $clone_flags:long unsigned int
kernel.statement("copy_process@kernel/fork.c:1168") $trace:int $pid:struct pid* $child_tidptr:int* $stack_size:long unsigned int $stack_start:long unsigned int $clone_flags:long unsigned int
kernel.statement("copy_process@kernel/fork.c:1176") $trace:int $pid:struct pid* $child_tidptr:int* $stack_size:long unsigned int $stack_start:long unsigned int $clone_flags:long unsigned int

# 这里是找出sys_madvise 可以加statement 的行数有哪些, 并且可以看打印哪些变量
└─[$] sudo stap -L 'kernel.statement("sys_madvise@madvise.c:*")'
kernel.statement("SyS_madvise@mm/madvise.c:460") $start:long int $len_in:long int $behavior:long int
kernel.statement("SyS_madvise@mm/madvise.c:464") $start:long int $len_in:long int $behavior:long int
kernel.statement("SyS_madvise@mm/madvise.c:471") $start:long int $len_in:long int $behavior:long int
kernel.statement("SyS_madvise@mm/madvise.c:472") $start:long int $len_in:long int $behavior:long int
kernel.statement("SyS_madvise@mm/madvise.c:475") $start:long int $len_in:long int $behavior:long int
kernel.statement("SyS_madvise@mm/madvise.c:477") $start:long int $len_in:long int $behavior:long int
```



#### systemtap 常用函数

tid() 获得当前执行线程的thread id

经常可以写这样的小Probe 来验证这句话对不对

sudo stap -e 'probe begin { printf("%d\n", gettimeofday_s()) }'

#### 2.0.0.8 内核线上systemtap 安装

wget http://xxxxxxxxxxxxxxxxxxxxxxxxxx/kernel/rs-2.0.0.8.tar.gz

这个是线上centos 6.2 的内核需要的包. 主要包含以下内容

```shell
└─[$] tar -zxvf rs-2.0.0.8.tar.gz
rs-2.0.0.8/
rs-2.0.0.8/perf-2.6.32-220.7.1.el6.2.0.0.8.x86_64.rpm
rs-2.0.0.8/kernel-2.6.32-220.7.1.el6.2.0.0.8.x86_64.rpm
rs-2.0.0.8/kernel-debuginfo-2.6.32-220.7.1.el6.2.0.0.8.x86_64.rpm
rs-2.0.0.8/kernel-devel-2.6.32-220.7.1.el6.2.0.0.8.x86_64.rpm
rs-2.0.0.8/perf-debuginfo-2.6.32-220.7.1.el6.2.0.0.8.x86_64.rpm
rs-2.0.0.8/kernel-firmware-2.6.32-220.7.1.el6.2.0.0.8.x86_64.rpm
rs-2.0.0.8/kernel-headers-2.6.32-220.7.1.el6.2.0.0.8.x86_64.rpm
rs-2.0.0.8/python-perf-2.6.32-220.7.1.el6.2.0.0.8.x86_64.rpm
rs-2.0.0.8/kernel-debuginfo-common-x86_64-2.6.32-220.7.1.el6.2.0.0.8.x86_64.rpm
```

找到跟 uname -rn 对应版本的 /lib/modules/`uname -rn`/build  指向 /usr/src/kernel/uname -rn

尽可能把名字都改成和uname -rn 一样的.

```shell
 /lib/modules/2.6.32-220.7.1.el6.2.0.0.8.x86_64/build -> ../../../usr/src/kernels/2.6.32-220.7.1.el6.2.0.0.8.x86_64
```

 如果还有问题, 比如没有对应kernel 版本对应的代码等等, 为了能够让systemtap 跑起来, 比如可以跑 nd_syscall 这些命令也是很有用, 不需要符号表, 那么直接将

/usr/src/kernels/2.6.32-220.7.1.el6.2.0.0.8.x86_64/include/linux/utsrelease.h 里面的内核版本改成uname -rn 里面显示的版本就行

#### systemtap 配套工具

addr2line -e ./a.out 0x4004a6  

通过 print_ubacktrace() 可以详细的看到函数的调用栈, 这个时候再用addr2line 去获得对应地址的代码

```shell
brkcall 0x80fee4000
 0x34794e0a4a : brk+0xa/0x70 [/lib64/libc-2.12.so]
 0x34794e0af5 : __sbrk+0x45/0xa0 [/lib64/libc-2.12.so]
 0x7f33e850c160 : sbrk+0x40/0xe0 [/usr/local/pika22/lib/libtcmalloc.so.4]
 0x7f33e84f55c3 : _ZN16SbrkSysAllocator5AllocEmPmm+0x53/0xd0 [/usr/local/pika22/lib/libtcmalloc.so.4]
 0x7f33e84f5546 : _ZN19DefaultSysAllocator5AllocEmPmm+0x36/0x60 [/usr/local/pika22/lib/libtcmalloc.so.4]
 0x7f33e84f5a0c : _Z20TCMalloc_SystemAllocmPmm+0x6c/0xd0 [/usr/local/pika22/lib/libtcmalloc.so.4]
 0x7f33e84f7905 : _ZN8tcmalloc8PageHeap8GrowHeapEm+0x65/0x360 [/usr/local/pika22/lib/libtcmalloc.so.4]
 0x7f33e84f7c2b : _ZN8tcmalloc8PageHeap3NewEm+0x2b/0x40 [/usr/local/pika22/lib/libtcmalloc.so.4]
 0x7f33e8506c4a : tc_malloc+0x5aa/0x800 [/usr/local/pika22/lib/libtcmalloc.so.4]
 0x711d7d : _ZN4pink9RedisConnC2EiRKSs+0x8d/0xa0 [/usr/local/pika22/bin/pika]
 0x4f29d1 : _ZN14PikaClientConnC1EiSsPN4pink6ThreadE+0x11/0x80 [/usr/local/pika22/bin/pika]
 0x55480c : _ZN4pink12WorkerThreadI14PikaClientConnE10ThreadMainEv+0x33c/0x7a0 [/usr/local/pika22/bin/pika]
 0x70fbfd : _ZN4pink6Thread9RunThreadEPv+0x9d/0x180 [/usr/local/pika22/bin/pika]
 0x3479807aa1 : start_thread+0xd1/0x3d4 [/lib64/libpthread-2.12.so]
 0x34794e8bcd : __clone+0x6d/0x90 [/lib64/libc-2.12.so]
```

那么这里你就可以使用

addr2line -e /usr/local/pika22/bin/pika 0x711d7d 看到对应的申请的代码了

```
[xusiliang@redis220 ~]$ addr2line -e /usr/local/pika22/bin/pika 0x711d7d
/data1/songzhao/Develop/pika/third/pink/src/redis_conn.cc:139
```

#### systemtap example

写的example, 通过example 可以很快的了解常用的语法

```shell
#!/usr/bin/stap

probe begin
{
  log("begin to probe\n")
}

/*
 * 这里是probe 系统调用的写法
 */
probe syscall.madvise
{
  if (execname() == "a.out") {
    /*
     * 这里通过stap -L syscall.madvise 可以获得可以 probe 的几个变量的值
     * 那么这里就可以把这些变量都打印出来
     */
    printf("%d %d %d\n", $start, $len_in, $behavior);

    printf("write %s\n", name);
    printf("thread_indent\n%s\n", thread_indent(1));

    /*
     * vars 是打印出所有的参数, vars 是打印所有函数里面的本地局部变量
     * parms 是包含上面的两个
     */
    printf("vars %s\n", $$vars$)
    printf("locals %s\n", $$locals)
    printf("parms %s\n", $$parms)
  }
}
probe syscall.madvise.return
{
  if (execname() == "a.out") {
    if ($return < 0) {
      print_regs()
      print_backtrace()
    }
    printf("%d %d %d\n", $start, $len_in, $behavior);

    printf("write %s\n", name);
    printf("thread_indent\n%s\n", thread_indent(-1));
  }
}

/*
 * 具体probe 函数里面的某一行
 */
probe kernel.function("*@mm/madvise.c:488")
{
  printf("current end %d\n", $end)
}

/*
 * 当需要probe 两个函数, 但是都是一样处理结果的时候 用逗号(,) 分开
 */
probe kernel.function("tlb_finish_mmu"), kernel.function("madvise_hwpoison")
{
  if (execname() == "a.out") {
    printf("vars %s\n", $$vars$)
    printf("thread_indent\n%s\n", thread_indent(-1));
    print_backtrace()
    print_ubacktrace()
  }
}

probe kernel.function("free_pages")
{
  if (execname() == "a.out") {
    printf("vars %s\n", $$vars$)
    printf("thread_indent\n%s\n", thread_indent(-1));
    print_backtrace()
    print_ubacktrace()
  }
}


probe kernel.function("madvise_behavior_valid")
{
  if (execname() == "a.out") {
    print_backtrace()
  }
}

```

```shell
probe syscall.brk
{
  if (execname() == "a.out") {

    printf("brkcall %s\n", argstr)
    /* printf("%d %d %d\n", $start, $len_in, $behavior); */
    printf("vars %s\n", $$vars)
    /* 经常发现print_backtrace() 和 print_ubacktrace() 一起用的时候, 打印出来的信息会少很多 */
    /* print_backtrace() */
    /* 用来打印出调用brk 系统调用的时候的函数调用栈, 这个时候需要将其他的动态库都传入到stap 的参数列表里面 */
    /* !sudo stap -d /usr/lib64/libc-2.17.so -d /data5/tmp/a.out -d /usr/lib64/ld-2.17.so -d /usr/lib64/libtcmalloc.so.4.2.6 */
    printf("user space backtrace\n")
    print_ubacktrace()
  }
}

很多时候如果执行的有问题, 遇到符号表信息不对 等等情况, 可以直接把 syscall 改成nd_syscall 就行, 这样就不需要符号表了
```

```shell
#!/usr/bin/stap

probe begin
{
  /*
   * 一般开头加上这个, 用于指导Probe 已经开始了, 因为经常probe 要准备一会
   */
  log("begin to probe\n")
}


/*
 * 这里是probe kernel 里面的某一个函数的写法
 */
probe kernel.function("page_remove_rmap")
{
  if (execname() == "a.out") {

    printf("%d %s \n", pid(), execname())
    print_backtrace()
    print_ubacktrace()
  }
}

/*
 * 这个是去 probe 系统调用返回的时候的写法
 */
probe syscall.madvise.return
{
  /*
   * 判断如果是 a.out 才打印出相关的信息, 不然信息太多
   */
  if (execname() == "a.out") {
    printf("madvise %d %s (%s)\n", pid(), execname(), argstr)
    /*
     * 经常用, 分别打印出kernel 内部的堆栈和用户空间的堆栈
     */
    print_backtrace()
    print_ubacktrace()
  }
}

/*
 * 这里也是probe kernel 里面的某一个函数的写法
 */
probe kernel.function("__free_pages")
{
  if (execname() == "a.out") {

    printf("%d %s \n", pid(), execname())
    print_backtrace()
    print_ubacktrace()
  }
}

probe kernel.function("do_munmap")
{
  if (execname() == "a.out") {

    printf("%d %s \n", pid(), execname())
    print_backtrace()
    print_ubacktrace()
  }
}

probe kernel.function("free_pages")
{
  if (execname() == "a.out") {

    printf("%d %s \n", pid(), execname())
    print_backtrace()
    print_ubacktrace()
  }
}
```


```c
# 统计malloc 和 free 分别调用了多少次, 并且看到调用的位置
#!/usr/bin/stap

probe begin
{
  log("begin to probe\n")
}

global nmalloc, nfree
// 这里因为使用的是tcmalloc, 如果使用默认的ptmalloc, 那么这里就是probe process("/lib64/libc.so.6").function("malloc") {

probe process("/usr/local/pika22/lib/libtcmalloc.so.4").function("malloc"), process("/usr/local/pika22/lib/libtcmalloc.so.4").function("realloc") {
        if (execname()== "pika") {
                nmalloc++
                printf("malloc %s \n", argstr)
                print_ubacktrace()
                printf("\n\n")
        }
}

probe process("/usr/local/pika22/lib/libtcmalloc.so.4").function("free") {
        if (execname()== "pika") {
                nfree++
                printf("free %s \n", argstr)
                print_ubacktrace()
                printf("\n\n")
        }
}

probe timer.s(1) {
        printf("malloc %d free %d\n", nmalloc, nfree)
}
```

```
#!/usr/bin/stap

probe begin
{
  log("begin to probe")
}

probe syscall.brk 
{
  if (execname() == "a.out") {
    printf("brkcall %d %s (%s)\n", pid(), execname(), argstr)
  }
}

probe syscall.mmap2
{
  if (execname() == "a.out") {
    printf("mmap %d %s (%s)\n", pid(), execname(), argstr)
  }
}

probe syscall.madvise
{
  if (execname() == "a.out") {
    printf("madvise %d %s (%s)\n", pid(), execname(), argstr)
  }
}

/* probe syscall.open  */
/* { */
/*   printf("%d %s (%s)\n", pid(), execname(), argstr) */
/* } */

probe timer.ms(10000)
{
  exit()
}

```

用来查看内存泄露的一个工具, 比valgrind 方便的地方在于不用线上跑valgrind, 而且可以精确到线程级别

```shell
# 执行方法 sudo stap tm.stp  -d /lib64/libc-2.12.so -d /usr/local/pika22/bin/pika -d /usr/local/pika22/lib/libtcmalloc.so.4 -d /lib64/libpthread-2.12.so

#!/usr/bin/stap

probe begin
{
  log("begin to probe\n")
}

# 对某一个地址调用的malloc, free的次数. 
# 如果 = 0, 说明正常free掉, 
# 如果 = 1, 说明malloc, 但是还没被free
# 如果 > 1, 说明这个地址被多次给malloc返回给用户, 肯定不正常
# 如果 < 1, 说明这个地址被多次free 也就是我们常说的double free 问题
global g_cnt
# 用来记录前一次调用的时候的 ubacktrace 信息
global g_stack
# 用来记录上次操作的时间
global g_time

probe process("/usr/local/pika22/lib/libtcmalloc.so.4").function("__libc_malloc").return, process("/usr/local/pika22/lib/libtcmalloc.so.4").function("__libc_calloc").return

{
	if (tid() == 11808) {
			g_cnt[$return]++
			g_stack[$return] = sprint_ubacktrace()
			g_time[$return] = gettimeofday_s()
	}
}

probe process("/usr/local/pika22/lib/libtcmalloc.so.4").function("__libc_free") {
	if (tid() == 11808 && g_time[$ptr] != 0) {
    # 这里对于之前没有进行过处理的节点忽略
    g_cnt[$ptr]--
    # 正常的malloc free 分支
		if (g_cnt[$ptr] == 0) {
			if ($ptr != 0) {
				printf("A normal malloc and free\n")
				g_stack[$ptr] = sprint_ubacktrace()
			}
      # 可能出现的double free 分支
		} else if (g_cnt[$ptr] < 0 && $ptr != 0) {
				printf("double free problem address %d cnt %d\n", $ptr, g_cnt[$ptr])
				printf("%s\n", g_stack[$ptr])
				printf("the destructure \n")
				print_ubacktrace() 
      # 多次malloc 返回同一个地址的分支, 这种情况很少见
		} else if (g_cnt[$ptr] > 1 && $ptr != 0) {
			printf("malloc large than 0\n")
			print_ubacktrace()
		}
	}
}

probe timer.s(5) {
	foreach (mem in g_cnt) {
    # 这里可以根据定义来调整这个10 的大小, 也就是说这里想打印出 10s 之前申请过内存
    # 但是 10s 之内没有被free 的情况, 这里因为 pika 在短连接的时候都是10之内申请 然后就释放
    # 如果10s 之内没有释放, 那肯定就是内存出现了问题
		if (g_cnt[mem] > 0 && gettimeofday_s() - g_time[mem] > 10) {
			printf("\n\n%s\n\n", g_stack[mem])
		}
	}
}


```

