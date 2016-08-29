---
layout: post
title: talk about kernel process descriptor
summary: some problem of kernel process descriptor

---

### task_struct, thread_struct, tss_struct, thread_info 他们之间的关系是什么

* task_struct 

  就是一个process descriptor

```c++
struct task_struct {
	volatile long state;	/* -1 unrunnable, 0 runnable, >0 stopped */
  /*
   * 这个stack 里面存的内容就是内核空间的栈的内容
   * 内核空间的栈的内容包含两个部分
   * 1. thread_info
   * 2. kernel 里面的内核栈空间的内容
   *
   * 这个stack 的初始化是在fork.c:dup_task_struct:alloc_thread_info() 里面的
   * struct thread_info *ti;
   * tsk->stack = ti;
   * 可以看出这个stack 指向的是一个thread_info 结构体
   *
   *  struct thread_info {
   *   struct task_struct	*task;		
   *   ...
   *   }
   *
   * task_thread_info(p)->task = p;
   * 从这里又可以看出 这个thread_info->task 又指向了这个task_struct
   * 也就是这两个结构体task_struct, thread_info是互相指向的
   * 为什么要这样做呢?
   * 因为cpu 里面的esp寄存器指向的就是kernel stack里面的内容, 然后通过kernel
   * stack 就可以获得thread_info 这个结构体(因为kernel stack 和 thread_info
   * 是保存在连续的8k 的空间上的),
   * 然后根据thread_info->task就可以找到当前正在运行task_struct 了.
   */
	void *stack;

  ...
  /* CPU-specific state of this task */
  /*
   * thread_struct 里面保留了大部分的cpu 寄存器的信息
   * 那么在context switch 的时候这个process 的cpu register
   * 等信息会被保存在这个thread_struct 里面
   */
	struct thread_struct thread;
```


* tss_struct 

  是定义的Task State Segment, 也就是 TSS 段, 这个段的主要用在就是存 process context switch 上下文切换的时候的hardware context. 这个 tss_struct 保存在GDT(global descriptor table) 里面. 这个结构并不在task_struct 里面. 

```c++
struct tss_struct *tss = &per_cpu(init_tss, cpu);
```
  从上面可以看出tss_struct 是每一个cpu 有一个这样的结构体

* thread_struct 

  这个是 process context switch 的时候, 将 hardware context 主要保留在的地方, 每一个线程都包含一份 thread_struct. 当然还有一部分包含在 kernel mode stack 里面, 比如(eax, ebx 等等)

  这里tss_struct 和 thread_struct 的关系是task_struct->thread_struct 主要保留的是 context switch 后, 不在cpu中间运行的process的内容, 然后tss_struct 里面的内容是不是就是直接从task_struct->thread_struct 里面的内容加载进来的呢? 确实是这样的

  这里也可以看出在做process switch 的时候, 是先获得了要运行的下一个process 的task_struct, 然后从task_struct 里面的thread_struct 加载到GDT里面, 

* thread_info

  thread_info 用来保存一些需要知道的固定变量, 类似写程序里面的全局变量

* kernel mode stack

  kernel mode stack 就是跟我们写程序的user mode stack 一样, 存的是一些临时变量, 和thread_info 相比, thread_info 更类似存全局变量



### kernel 如何获得当前运行process 的 task_struct 的

这个就主要通过当前运行的process task_struct 里面的stack 来获得.

在stack 里面是这样的一个结构

![Imgur](http://i.imgur.com/1fAYzia.jpg)

可以看出这个stack 底下是一个thread_info 的结构体, 然后stack 的底部是在最上面, 这一部分就是kernel stack 的内容, esp 指针指向着当前的kernel stack 的头部. 那么这个时候想要获得当前运行process 的task_struct 就比较方便. 因为

The close association between the thread_info structure and the Kernel Mode stack just described offers a key benefit in terms of efficiency: the kernel can easily obtain the address of the thread_info structure of the process currently running on a CPU from the value of the esp register. 

就是说可以通过esp 很容易获得thread_info 这个结构体的位置, 然后thread_info->task 里面又保留了这个process descriptor 的指针就可以获得对应的task_struct 的位置了

### 为什么要把stack 和 thread_info 放在一个page 里面

Another advantage of storing the process descriptor with the stack emerges on multi-processor systems: the correct current process for each hardware processor can be derived just by checking the stack, as shown previously.

Earlier versions of Linux did not store the kernel stack and the process descriptor together.

因为kernel stack 上面永远放着esp指针, 那么因为esp 肯定在这个page里面, 通过取模很容易就可以获得当前这个thread_info 所在的地址, 通过thread_info 就可以很容易获得task_struct 的地址了

