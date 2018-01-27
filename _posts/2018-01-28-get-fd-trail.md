---
layout: post
title: linux get fd trail
summary: linux get fd trail

---

我们知道在我们使用open() 系统调用打开一个文件以后, 会返回一个具体的fd, 我们知道0, 1, 2是默认的标准输入, 标准输出以及错误输出的fd, 那么这个fd 号是如何获得, 以及关闭以后如何使用的呢?

**数据结构**

首先进程打开一个文件相关的操作都保存在 files_struct 这个结构体里, 变量名是files, 每一个进程有自己的 files_struct, files_struct 中包含fdtable 结构体

```c
/*
 * Open file table structure
 */
struct files_struct {
  /*
   * read mostly part
   */
	atomic_t count;
	struct fdtable *fdt;
	struct fdtable fdtab;
  /*
   * written part on a separate cache line in SMP
   * 操作 fdt 的时候一般都会锁住 file_lock
   * 比如在 open 需要往fdt 增加fd 的过程, 以及在close 需要往fdt 中减东西的过程
   * 这个就是保证了有多个线程在一个进程中都在申请open, socket() 等等操作的时候fd 
   * 不会冲突的保证
   */
	spinlock_t file_lock ____cacheline_aligned_in_smp;  
	int next_fd;
	struct embedded_fd_set close_on_exec_init;
	struct embedded_fd_set open_fds_init;
	struct file * fd_array[NR_OPEN_DEFAULT];
};

struct fdtable {
	unsigned int max_fds;
  /*
   * 这里这个fd 保存的就是fd 与 vfs 中的file 的对应关系, 
   * 所以知道一个进程打开的fd 以后, 在这里根据fd 的号码对应的数组
   * 的位置就可以获得这个file 结构了
   * 比如: 这里就是fdtable 根据fd 或者对应file* 的操作
   * filp = fdt->fd[fd];
   * 将一个fd 关联到file* 的方法是
	 * fd_install(fd, f);
   */
	struct file ** fd;      /* current fd array */
	fd_set *close_on_exec;
	fd_set *open_fds;
	struct rcu_head rcu;
	struct fdtable *next;
};

// 其中fd_set 的定义是这样
#define __NFDBITS	(8 * sizeof(unsigned long))
#define __FD_SETSIZE	1024
#define __FDSET_LONGS	(__FD_SETSIZE/__NFDBITS)
typedef struct {
	unsigned long fds_bits [__FDSET_LONGS];
} __kernel_fd_set;
typedef __kernel_fd_set		fd_set;


```



所以进程打开的fd 是保存在每一个fd_set *open_fds 中, 每一个打开的进程是一个bit 位



**方法**

申请fd 的过程是

```c
SYSCALL_DEFINE3(open, const char __user *, filename, int, flags, int, mode)
{
	ret = do_sys_open(AT_FDCWD, filename, flags, mode);

 =>
long do_sys_open(int dfd, const char __user *filename, int flags, int mode)
{

    /*
     * 获得当前这个进程里面空闲的fd
     * 注意下面的调用里面会用到current 这个变量, 这个变量指的是当前的进程
     */
		fd = get_unused_fd_flags(flags);
	...
      /*
       * 这里是打开file * 指针的操作
       */
	struct file *f = do_filp_open(dfd, tmp, flags, mode, 0);

	...
		fsnotify_open(f->f_path.dentry);
        /*
         * 将fd 和 file* 关联起来
         * 主要做的事情就是设置这个fdtable 中的fd[fd] = f;
         * 那么下一次就可以根据fd 号获得 file* 这个指针
         */
		fd_install(fd, f);

=>
#define get_unused_fd_flags(flags) alloc_fd(0, (flags))

int alloc_fd(unsigned start, unsigned flags)
{
...
  // 在操作fdt 之前都会加 file_lock 这个锁
	spin_lock(&files->file_lock);
  // 找出在open_fds->fds_bits 中空闲的bit, 如果不够了, 同时扩展这个fds_bits
	if (fd < fdt->max_fds)
		fd = find_next_zero_bit(fdt->open_fds->fds_bits,
					   fdt->max_fds, fd);
  /*
   * 在expand_files 里面, 会进行检查是否达到这个进程的resource limit
   * 以及ulimit -a 中的打开文件句柄数限制
   * 如果fdtable 的空间不够, 就进行翻倍扩展
   */
	error = expand_files(files, fd);


```

tips

从代码的实现里面可以看出, 所有对于fdtable 的操作都会添加file_lock锁, 所以肯定不会出现一个fd 对应多个打开的文件的情况, 之前线上出现一个fd 对应多个打开文件, 我们还怀疑过, 估计当时的现象应该是打开了了一个文件以后, 已经被关闭, 这个时候打开了一个新的文件使用的还是这个fd 号, 因为从下面close 的策略可以看出, 是一旦有fd 释放, 马上就会去使用这个fd 的

close的过程

```c
SYSCALL_DEFINE1(close, unsigned int, fd)
{
	spin_lock(&files->file_lock);
  /*
   * 保存在fdtable 中, 通过fd 就可以直接找到对应的file* 指针
   */
	filp = fdt->fd[fd];

	__put_unused_fd(files, fd);
	spin_unlock(&files->file_lock);

...

static void __put_unused_fd(struct files_struct *files, unsigned int fd)
{
	struct fdtable *fdt = files_fdtable(files);
	__FD_CLR(fd, fdt->open_fds);
  /*
   * 从这个设置next_fd 的操作可以看出
   * 对于fd 的操作是close 一个fd 以后, 下一次的open 操作申请的
   * 就是这个释放的fd
   * 所以这里是循环利用这个fd的
   */
	if (fd < files->next_fd)
		files->next_fd = fd;
}

```



