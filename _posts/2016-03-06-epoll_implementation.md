---
layout: post
title: "epoll implementation"
description: "epoll implementation"
tags: [kernel]
---
### epoll Implementation

epoll 在kernel 的具体实现主要在 fs/eventpoll.c include/linux/eventpoll.h 里面


#### 主要的数据结构

eventpoll 是这里面最重要的结构, 在epoll_create 的时候就会生成这个eventpoll 结构, 后续对这个fd 的操作都是在这个eventpoll 这个结构下面的, 这个eventpoll 结构会被保存在file struct 的 private_data 这个结构体里面

```c
struct eventpoll {
	/* Protect the this structure access */
	spinlock_t lock;

	/*
	 * This mutex is used to ensure that files are not removed
	 * while epoll is using them. This is held during the event
	 * collection loop, the file cleanup path, the epoll file exit
	 * code and the ctl operations.
	 */
	struct mutex mtx;

	/* Wait queue used by sys_epoll_wait() */
  /*
   * 这个wq 这个等待队列是在sys_epoll_wait 里面使用的,
   * 里面放入的进程应该只有执行epoll_wait 这个进程
   */
	wait_queue_head_t wq;

	/* Wait queue used by file->poll() */
  /*
   * 因为eventpoll 本身也是一个file, 所以也会有poll 操作, 有poll
   * 操作肯定就会有一个对应的wait_queue_head_t 队列用来唤醒上面的进程或者函数
   * 就跟pipe_inode_info 里面会有  wait_queue_head_t wait; 一样
   *
   * 不过我们很少看到把一个epoll 的fd 再挂载到另外一个fd 下面
   *
   */
	wait_queue_head_t poll_wait;

	/* List of ready file descriptors */
  /*
   * 在epoll_wait 阶段, 如果有哪些fd 就绪, 会把就绪的fd 放在这个rdllist 里面
   * 这个rdllist 里面放的是epitem 这个结构
   */
	struct list_head rdllist;

	/* RB tree root used to store monitored fd structs */
	struct rb_root rbr;

	/*
	 * This is a single linked list that chains all the "struct epitem" that
	 * happened while transfering ready events to userspace w/out
	 * holding ->lock.
	 */
	struct epitem *ovflist;

	/* The user that created the eventpoll descriptor */
	struct user_struct *user;
};

```

epitem 这个表示的是每一个加入到eventpoll 的结构里面的fd 的时候, 都会有一个epitem 这个结构体, 这个结构体是是连成一个红黑树挂载eventpoll 下面的, 后续查找某一个fd 是否有事件等等都是在这个epitem 上面进行操作

```c
/*
 * Each file descriptor added to the eventpoll interface will
 * have an entry of this type linked to the "rbr" RB tree.
 */
struct epitem {
	/* RB tree node used to link this structure to the eventpoll RB tree */
  /*
   * 这是这个fd 挂载的红黑树的节点
   */
	struct rb_node rbn;

	/* List header used to link this structure to the eventpoll ready list */
  /*
   * 这个是将这个epitem 连接到eventpoll 里面的rdllist 的时候list指针
   */
	struct list_head rdllink;

	/*
	 * Works together "struct eventpoll"->ovflist in keeping the
	 * single linked chain of items.
	 */
	struct epitem *next;

	/* The file descriptor information this item refers to */
  /*
   * epoll 监听的fd
   */
	struct epoll_filefd ffd;

	/* Number of active wait queue attached to poll operations */
  /*
   * 因为一个epitem 可能会被多个eventpoll 监听, 那么就会对应生成多个eppoll_entry
   * 这里nwait 就是记录这个数目
   */
	int nwait;

	/* List containing poll wait queues */
	struct list_head pwqlist;

	/* The "container" of this item */
  /*
   * 当前这个epitem 所属于的eventpoll
   */
	struct eventpoll *ep;

	/* List header used to link this item to the "struct file" items list */
	struct list_head fllink;

	/* The structure that describe the interested events and the source fd */
	struct epoll_event event;
};
```


eppoll_entry 
一个epitem 关联到一个eventpoll, 就会有一个对应的eppoll_entry

```c
/* Wait structure used by the poll hooks */
struct eppoll_entry {
	/* List header used to link this structure to the "struct epitem" */
  /*
   * 因为一个epitem 可以会被多个eventpoll 监听, 因为每一个进程打开的这个文件的fd
   * 和epitem 是一一对应的, 因此这里epitem 对应的是多个eppoll_entry,
   * 所以这个llink 会被连接到pwqlist 里面
   */
	struct list_head llink;

	/* The "base" pointer is set to the container "struct epitem" */
  /*
   * 对应的epitem
   */
	struct epitem *base;

	/*
	 * Wait queue item that will be linked to the target file wait
	 * queue head.
   * wait_queue_t 里面存的就是wait_queue_head_t 下面具体的内容
	 */
  /*
 struct __wait_queue {
     unsigned int flags;
  #define WQ_FLAG_EXCLUSIVE	0x01
  // 这里的这个private 一般指向某一个进程task_struct
  void *private;
  wait_queue_func_t func;
  struct list_head task_list;
  };
  */
	wait_queue_t wait;

	/* The wait queue head that linked the "wait" wait queue item */
	wait_queue_head_t *whead;
};
```

#### epoll_create 的过程

```c
/*
 * Open an eventpoll file descriptor.
 */
SYSCALL_DEFINE1(epoll_create1, int, flags)
{
	int error;
	struct eventpoll *ep = NULL;

	/* Check the EPOLL_* constant for consistency.  */
	BUILD_BUG_ON(EPOLL_CLOEXEC != O_CLOEXEC);

	if (flags & ~EPOLL_CLOEXEC)
		return -EINVAL;
	/*
	 * Create the internal data structure ("struct eventpoll").
   * 初始化建立这个主题的 eventpoll 这个结构
	 */
	error = ep_alloc(&ep);
	if (error < 0)
		return error;
	/*
	 * Creates all the items needed to setup an eventpoll file. That is,
	 * a file structure and a free file descriptor.
   *
   * 这个也是一个重要的过程, 将eventpoll 生成的fd绑定到匿名file上, 
   * 因为我们可以看到epoll_create 出来的也是一个文件fd. 那么这个fd
   * 绑定到一个file 以后, 那么这个epoll具体的内容就在这个struct file 上面的
   * private_data 上面
   *
   * 这里这个error 写的比较坑, 如果正常其实这里返回的就是epoll_create
   * 生成的fd
	 */

  // 这里这个ep 就是一直要传下去的epollevent, 最后这个ep 会被赋值到struct
  // file->private_data 里面去
  // 可以看到这里代表着另外一种文件类型, 匿名文件类型需要建立一个fd的过程
  // 这里其实如果是socket 的话, 那么不一样的地方就是这里传入的不是ep,
  // 而是一个socket
  // 这也是linux 所有数据都是文件的一个体现
	error = anon_inode_getfd("[eventpoll]", &eventpoll_fops, ep,
				 flags & O_CLOEXEC);
	if (error < 0)
		ep_free(ep);

	return error;
}
```

#### epoll_ctl

epoll_ctl 做的主要事情就是把某一个fd 要监听的事件过载到eventpoll 里面

```c

SYSCALL_DEFINE4(epoll_ctl, int, epfd, int, op, int, fd,
		struct epoll_event __user *, event)
{
	int error;
	struct file *file, *tfile;
	struct eventpoll *ep;
	struct epitem *epi;
	struct epoll_event epds;

	error = -EFAULT;
  /*
   * 这里检查这次操作是否有这个操作, 并将用户空间传进来的epoll_event 拷贝到内核空间
   */
	if (ep_op_has_event(op) &&
	    copy_from_user(&epds, event, sizeof(struct epoll_event)))
		goto error_return;

	/* Get the "struct file *" for the eventpoll file */
	error = -EBADF;
  /*
   * 这里就是使用文件的好处了, 根据这个fd, fget 就可以获得当前这个进程fd
   * 号码是pdfd 的file, 然后就操作file 里面的内容, 虽然这里的file 不是正在的file
   * 而是一个匿名文件, 这样操作起来非常的方便
   */
	file = fget(epfd);
	if (!file)
		goto error_return;

	/* Get the "struct file *" for the target file */
  /*
   * 这里的epoll_ctl 要关注的那个文件的fd, 也一样根据这个fd 找到这个文件
   */
	tfile = fget(fd);
	if (!tfile)
		goto error_fput;

  // TODO 这里descriptoer support poll 是什么意思, 是不是有实现poll 函数就行
	/* The target file descriptor must support poll */
	error = -EPERM;
	if (!tfile->f_op || !tfile->f_op->poll)
		goto error_tgt_fput;

	/*
	 * We have to check that the file structure underneath the file descriptor
	 * the user passed to us _is_ an eventpoll file. And also we do not permit
	 * adding an epoll file descriptor inside itself.
     * 这里可以看到如果把自己的epoll 的fd 添加到 epoll_ctl 里面的fd 是有问题的
	 */
	error = -EINVAL;
	if (file == tfile || !is_file_epoll(file))
		goto error_tgt_fput;

	/*
	 * At this point it is safe to assume that the "private_data" contains
	 * our own data structure.
	 */
	ep = file->private_data;

	mutex_lock(&ep->mtx);

	/*
	 * Try to lookup the file inside our RB tree, Since we grabbed "mtx"
	 * above, we can be sure to be able to use the item looked up by
	 * ep_find() till we release the mutex.
     * 根据这个fd 找出对应的epitem, 这里把所有的epitem 根据fd号挂载到红黑树上
	 */
	epi = ep_find(ep, tfile, fd);

	error = -EINVAL;
	switch (op) {
	case EPOLL_CTL_ADD:
		if (!epi) {
			epds.events |= POLLERR | POLLHUP;
			error = ep_insert(ep, &epds, tfile, fd);
		} else
			error = -EEXIST;
```
那么接下来主要看ep_insert 的过程

```c

/*
 * Must be called with "mtx" held.
 * 这里可以看到往这个队列里面加入一个epoll_event 的过程
 */
static int ep_insert(struct eventpoll *ep, struct epoll_event *event,
		     struct file *tfile, int fd)
{
	int error, revents, pwake = 0;
	unsigned long flags;
	struct epitem *epi;
	struct ep_pqueue epq;

	if (unlikely(atomic_read(&ep->user->epoll_watches) >=
		     max_user_watches))
		return -ENOSPC;
	if (!(epi = kmem_cache_alloc(epi_cache, GFP_KERNEL)))
		return -ENOMEM;

	/* Item initialization follow here ... */
	INIT_LIST_HEAD(&epi->rdllink);
	INIT_LIST_HEAD(&epi->fllink);
	INIT_LIST_HEAD(&epi->pwqlist);
  /*
   * 这里会反向标记这个epitem 属于的eventpoll
   */
	epi->ep = ep;
  /*
   * 这里就是去设定 epitem 里面的ffd 字段, 标记里面的ffd 字段
   * 就是初始化好file, fd 字段
   */
	ep_set_ffd(&epi->ffd, tfile, fd);
	epi->event = *event;
	epi->nwait = 0;
	epi->next = EP_UNACTIVE_PTR;

	/* Initialize the poll table using the queue callback */
	epq.epi = epi;
  /*
   * 这里是注册poll 里面有事件到达的时候的处理函数
   * 在ep_ptable_queue_proc 里面去添加事件到达的时候处理函数
   * init_waitqueue_func_entry(&pwq->wait, ep_poll_callback);
   */
	init_poll_funcptr(&epq.pt, ep_ptable_queue_proc);

	/*
	 * Attach the item to the poll hooks and get current event bits.
	 * We can safely use the file* here because its usage count has
	 * been increased by the caller of this function. Note that after
	 * this operation completes, the poll callback can start hitting
	 * the new item.
	 */

  /* 
   *
   * 这里调用对应的fd 的poll 操作, 看是否有事件到达.
   * 并且注册事件到达的时候poll_table
   * 这里是调用用户关注的fd 的.poll()函数, 不是eventpoll 里面的
   * ep_eventpoll_poll
   */  
	revents = tfile->f_op->poll(tfile, &epq.pt);

	/*
	 * We have to check if something went wrong during the poll wait queue
	 * install process. Namely an allocation for a wait queue failed due
	 * high memory pressure.
	 */
	error = -ENOMEM;
	if (epi->nwait < 0)
		goto error_unregister;

	/* Add the current item to the list of active epoll hook for this file */
	spin_lock(&tfile->f_lock);
	list_add_tail(&epi->fllink, &tfile->f_ep_links);
	spin_unlock(&tfile->f_lock);

	/*
	 * Add the current item to the RB tree. All RB tree operations are
	 * protected by "mtx", and ep_insert() is called with "mtx" held. 
	 * 这里是具体把这个epitem 加入到这个eventpoll 的 rb tree 的过程
	 */
	ep_rbtree_insert(ep, epi);

	/* We have to drop the new item inside our item list to keep track of it */
	spin_lock_irqsave(&ep->lock, flags);

	/* If the file is already "ready" we drop it inside the ready list */
	if ((revents & event->events) && !ep_is_linked(&epi->rdllink)) {
		list_add_tail(&epi->rdllink, &ep->rdllist);

		/* Notify waiting tasks that events are available */
		if (waitqueue_active(&ep->wq))
			wake_up_locked(&ep->wq);
		if (waitqueue_active(&ep->poll_wait))
			pwake++;
	}
```

那么到这里已经将这个fd 注册到对应的eventpoll上, 那么我们看一下这里注册的函数, 函数是

init_poll_funcptr(&epq.pt, ep_ptable_queue_proc);
这个函数ep_ptable_queue_proc 里面又会包含对应的当有事件发生的时候的回调函数 ep_poll_callback

那么接下来就是 ep_table_queue_proc 的实现

在ep_table_queue_proc 里面将当前这个进程注册到了想要监听的fd 的唤醒队列里面, 这个唤醒的行数是 ep_poll_callback, 

其实唤醒的时候主要分两种类似
1. 唤醒注册时候的进程, 让注册的进程重新执行. 比如在epoll_wait 的时候对应的唤醒函数就是唤醒这个执行 epoll_wait 的这个进程
2. 唤醒的时候执行注册的某一个函数

这里因为epoll 注册的是唤醒的时候执行注册的某一个函数, 这个函数就是ep_poll_callback

```c

/*
 * This is the callback that is used to add our wait queue to the
 * target file wakeup lists.
 */
static void ep_ptable_queue_proc(struct file *file, wait_queue_head_t *whead,
				 poll_table *pt)
{
  /*
   * 从知道poll_table 的地址去获得这个对应的epitem的地址, 跟kernel 里面list的做法类似
   */
	struct epitem *epi = ep_item_from_epqueue(pt);


  /*
   * 这里eppoll_entry 是对应于每一个epitem 注册挂载到某一个eventpoll 都会有一个eppoll_entry
   */
	struct eppoll_entry *pwq;

	if (epi->nwait >= 0 && (pwq = kmem_cache_alloc(pwq_cache, GFP_KERNEL))) {
    /*
     * 这里就是把pwq->wait 这个元素的callback 设置成 ep_poll_callback 这个函数
     * 然后初始化的时候一般把这个private 设置NULL 的原因是
     * 这里当要等待的这个队列被唤醒的时候, 并不在于哪一个进程,
     * 只要唤醒的时候执行指定的函数就可以了
     * 需要看一下唤醒的时候具体是怎么执行的,
     * 是不是唤醒的时候如果注册的是函数就执行指定的函数,
     * 如果是进程就执行指定的进程
     */
		init_waitqueue_func_entry(&pwq->wait, ep_poll_callback);
		pwq->whead = whead;
		pwq->base = epi;
    // 这里就是将这个要等待的fd 添加到等待队列里面去了,
    // 这里如果这个要等待的fd是pipe, 那么这里这个whead就是pipe->wait了
    // 这里要等待的fd 只有  wait_queue_head_t wait; 这个wait_queue_head,
    // 然后就是将这里epoll_entry 里面的wait_queue_t wait 连在一起,
    // 实际他们组合成了一个等待的队列, 然后想取得这个队列里面的元素, 跟kernel
    // list 一样, 需要根据struct 里面某一个元素的地址, 然后去获得这个元素
    // 比如这里想反向获得这个 epoll_entry 里面的epitem 就是
    //   struct epitem *epi = ep_item_from_wait(wait);
		add_wait_queue(whead, &pwq->wait);
		list_add_tail(&pwq->llink, &epi->pwqlist);
		epi->nwait++;
	} else {
		/* We have to signal that an error occurred */
		epi->nwait = -1;
	}
}
```

ep_poll_callback

```c
/*
 * This is the callback that is passed to the wait queue wakeup
 * machanism. It is called by the stored file descriptors when they
 * have events to report.
 * 这里就是被static void __wake_up_common 这个函数下面进行循环调用的
 *
 * 也就是某一个fd 的等待队列里面注册的这个函数的callback,
 * 然后这个fd有事件发生了, 就会执行这个ep_poll_callback 函数了
 *
 * 这个key 参数是从 wake_up_interruptible_poll() 函数里面一直传进来的, 
 * 这里这个key 在这里表示的就是要监听的这个fd 有什么事件 
 *
 * 其实这里epitem 里面已经包含了发生的事件, 和这里的key 参数其实是一样了,
 * 因为并不是所有的device 都会把发生的事件都放在key 这个参数里面的
 *
 * 这个函数主要就是由监听的fd发生事件了, 然后触发这个回调函数, 
 * 然后这里会把触发的fd 添加到eventpoll 中的 rdllist
 *
 */
static int ep_poll_callback(wait_queue_t *wait, unsigned mode, int sync, void *key)
{
	int pwake = 0;
	unsigned long flags;
  /*
   * 因为之前王wait_queue_t 里面放的是epoll_entry 这个struct 里面的wait 元素,
   * 这里加入的地方是在eventpoll.c:ep_ptable_queue_proc
   * 这个函数里面的
   * add_wait_queue(whead, &pwq->wait);
   * 在这个函数里面有详细的注释
   * 这样要做的事情就是根据struct 里面的某一个元素wait, 去获得这个struct
   * epoll_entry 里面的epitem
   * 到这里的时候, 我们已经知道是这个epitem 里面指定的fd 有时间发生,
   * 那么这个时候就去检查这个fd 里面发生了什么事件
   */
	struct epitem *epi = ep_item_from_wait(wait);


  /*
   * 这里由于需要记录这个epitem 是属于哪一个eventpoll, 因此epitem
   * 会保留这个反向的指向eventpoll 的指针
   */
	struct eventpoll *ep = epi->ep;

	spin_lock_irqsave(&ep->lock, flags);

	/*
	 * If the event mask does not contain any poll(2) event, we consider the
	 * descriptor to be disabled. This condition is likely the effect of the
	 * EPOLLONESHOT bit that disables the descriptor when an event is received,
	 * until the next EPOLL_CTL_MOD will be issued.
	 */
	if (!(epi->event.events & ~EP_PRIVATE_BITS))
		goto out_unlock;

	/*
	 * Check the events coming with the callback. At this stage, not
	 * every device reports the events in the "key" parameter of the
	 * callback. We need to be able to handle both cases here, hence the
	 * test for "key" != NULL before the event match test.
     * 这里其实key 有可能记录了当前这个fd的事件, 如果记录了,
     * 就判断key里面返回的事件和这个fd关注的事件是否有重合
	 */
	if (key && !((unsigned long) key & epi->event.events))
		goto out_unlock;

	/*
	 * If we are trasfering events to userspace, we can hold no locks
	 * (because we're accessing user memory, and because of linux f_op->poll()
	 * semantics). All the events that happens during that period of time are
	 * chained in ep->ovflist and requeued later on.
	 */
  /*
   * 这里把这个epi 添加到ovflist
   */
	if (unlikely(ep->ovflist != EP_UNACTIVE_PTR)) {
		if (epi->next == EP_UNACTIVE_PTR) {
			epi->next = ep->ovflist;
			ep->ovflist = epi;
		}
		goto out_unlock;
	}

	/* If this file is already in the ready list we exit soon */
  // 这个epitem 已经在rdllist 里面就不再添加
  // 这里只要判断这个epitem->rdllink 是否有连接上, 也就是next
  // 指针是否为空就可以知道这个epitem 有没有被连接成一个List
	if (!ep_is_linked(&epi->rdllink))
		list_add_tail(&epi->rdllink, &ep->rdllist);

	/*
	 * Wake up ( if active ) both the eventpoll wait list and the ->poll()
	 * wait list.
	 */
	if (waitqueue_active(&ep->wq))
		wake_up_locked(&ep->wq); // 这里的wake_up ep->wq 就把等待在epoll_wait 里面的直接schedule_timeout()的那个函数给唤醒
  // 那么这个时候如果进程等待在epoll_wait 上面, 进程就会重新执行
	if (waitqueue_active(&ep->poll_wait)) // 这里这个默认的pwake 初始化是0, 表示当前这个ep->poll_wait 所等待的fd 里面有多少个已经wakeup了
    // 为什么这里需要把加这个pwake, 因为如果不加这个pwake, 那么每一个ep
    // 所等待的fd 醒来都去wakeup 一下这个ep这个线程,
    // 那么ep这个线程其实就被wakeup 了很多次
		pwake++;

out_unlock:
	spin_unlock_irqrestore(&ep->lock, flags);

	/* We have to call this outside the lock */
	if (pwake)
		ep_poll_safewake(&ep->poll_wait);

	return 1;
}
```

#### epoll_wait

```c

/*
 * Implement the event wait interface for the eventpoll file. It is the kernel
 * part of the user space epoll_wait(2).
 */
SYSCALL_DEFINE4(epoll_wait, int, epfd, struct epoll_event __user *, events,
		int, maxevents, int, timeout)
{
	int error;
	...
	error = ep_poll(ep, events, maxevents, timeout);

```

主要的执行逻辑在 ep_poll() 上

ep_poll()

```c
static int ep_poll(struct eventpoll *ep, struct epoll_event __user *events,
		   int maxevents, long timeout)
{
	int res, eavail;
	unsigned long flags;
	long jtimeout;
	wait_queue_t wait;

	/*
	 * Calculate the timeout by checking for the "infinite" value (-1)
	 * and the overflow condition. The passed timeout is in milliseconds,
	 * that why (t * HZ) / 1000.
	 */
	jtimeout = (timeout < 0 || timeout >= EP_MAX_MSTIMEO) ?
		MAX_SCHEDULE_TIMEOUT : (timeout * HZ + 999) / 1000;

retry:
	spin_lock_irqsave(&ep->lock, flags);

	res = 0;
	if (list_empty(&ep->rdllist)) {
		/*
		 * We don't have any available event to return to the caller.
		 * We need to sleep here, and we will be wake up by
		 * ep_poll_callback() when events will become available.
     *
     * 由于ep_poll 是被epoll_wait 的时候被调用, 因此这里这个current
     * 进程就是调用epoll_wait 的那个进程
     *
     * 将这个触发当前进程执行的wait_queue_t wait 加入到ep->wq wait_queue_head_t
     * 里面去, 那么下次这个wait_queue 有事件到达的时候, 就会触发当前这个wait
     * 里面的内容
		 */
		init_waitqueue_entry(&wait, current);
		wait.flags |= WQ_FLAG_EXCLUSIVE;
		__add_wait_queue(&ep->wq, &wait);

    /*
     * 这里这个死循环的做法是将current 进程的状态改成TASK_INTERRUPTIBLE,
     * 然后最后重新陷入到执行schedule(),
     * 这里因为当前的进程的状态已经改成TASK_INTERRUPTIBLE了,
     * 因此肯定会切换到其他进程去执行
     */
		for (;;) {
			/*
			 * We don't want to sleep if the ep_poll_callback() sends us
			 * a wakeup in between. That's why we set the task state
			 * to TASK_INTERRUPTIBLE before doing the checks.
			 */
			set_current_state(TASK_INTERRUPTIBLE);
      /*
       * 这里可以看到如果有ep rdllist 里面有元素, 那么说明有时间已经出发了,
       * 那么就退出这个for 循环
       */
			if (!list_empty(&ep->rdllist) || !jtimeout)
				break;
			if (signal_pending(current)) {
				res = -EINTR;
				break;
			}

			spin_unlock_irqrestore(&ep->lock, flags);
      /*
       * 当前这个进程把CPU 交给其他的进程执行, 当切换回来的时候肯定eventpoll
       * 里面的内容应该会被修改了, 比如某一个事件触发的时候, 会往rdllist
       * 里面写入数据内容
       *
       * 这里就开始等待之前在epoll_insert
       * 注册的ep_poll_callback这个函数来把当前这个进程给唤醒,
       * 否则是sleep一段时间以后就返回了
       */
			jtimeout = schedule_timeout(jtimeout);
			spin_lock_irqsave(&ep->lock, flags);
		}
    /*
     * 当前这个进程已经被唤醒, 那么就从eventpoll 里面把这个进程删除掉
     */
		__remove_wait_queue(&ep->wq, &wait);

    /*
     * 设置当前的进程的状态, 到这里我觉得进程已经正常运行了
     */
		set_current_state(TASK_RUNNING);
	}
	/* Is it worth to try to dig for events ? */
	eavail = !list_empty(&ep->rdllist) || ep->ovflist != EP_UNACTIVE_PTR;

	spin_unlock_irqrestore(&ep->lock, flags);

	/*
	 * Try to transfer events to user space. In case we get 0 events and
	 * there's still timeout left over, we go trying again in search of
	 * more luck.
   * 到这里肯定从schedule_timeout 里面退出, 已经有事件发生并且传送过来了,
   * 这个就是就把这些事件传给用户进程
	 */
	if (!res && eavail &&
	    !(res = ep_send_events(ep, events, maxevents)) && jtimeout)
		goto retry;

	return res;
}
```

最后就是将发生的events 传递给用户空间

ep_send_events->ep_scan_ready_list->ep_send_events_proc

```c
/**
 * ep_scan_ready_list - Scans the ready list in a way that makes possible for
 *                      the scan code, to call f_op->poll(). Also allows for
 *                      O(NumReady) performance.
 *
 * @ep: Pointer to the epoll private data structure.
 * @sproc: Pointer to the scan callback.
 * @priv: Private opaque data passed to the @sproc callback.
 *
 * Returns: The same integer error code returned by the @sproc callback.
 */
static int ep_scan_ready_list(struct eventpoll *ep,
			      int (*sproc)(struct eventpoll *,
					   struct list_head *, void *),
			      void *priv)
{
	int error, pwake = 0;
	unsigned long flags;
	struct epitem *epi, *nepi;
	LIST_HEAD(txlist);

	/*
	 * We need to lock this because we could be hit by
	 * eventpoll_release_file() and epoll_ctl().
	 */
	mutex_lock(&ep->mtx);

	/*
	 * Steal the ready list, and re-init the original one to the
	 * empty list. Also, set ep->ovflist to NULL so that events
	 * happening while looping w/out locks, are not lost. We cannot
	 * have the poll callback to queue directly on ep->rdllist,
	 * because we want the "sproc" callback to be able to do it
	 * in a lockless way.
	 */
	spin_lock_irqsave(&ep->lock, flags);

  // 这里将txlist 指向eventpoll 里面的rdllist, 那么接下来就会将txlist
  // 里面的内容也就是rdllist里面的内容拷贝给用户空间
  // 这个rdllist 是在ep_poll_callback 的时候添加进去的内容的
  // 这里执行完这个list_splice_init 以后, ep->rdllist 就变成空的了
  // 那么接下来可以同时处理txllist 里面的内容, 也就是原先rdllist 里面的内容.
  // 也可以同时让新的元素往这个队里里面添加新的内容
  //
  // 这是一个很好的减少锁范围的例子
  // 相当于先生成一个队列, 然后后续要处理这个队列里面内容,
  // 同时又添加和删除操作的时候, 可以把这个添加操作放到一个新的队列上,
  // 那么这个时候就可以同时的添加和删除操作, 不用去竞争一个锁
  // NICE
	list_splice_init(&ep->rdllist, &txlist);
	ep->ovflist = NULL;
	spin_unlock_irqrestore(&ep->lock, flags);

	/*
	 * Now call the callback function.
	 * 这里的sproc 就是 ep_send_events_proc
	 */
	error = (*sproc)(ep, &txlist, priv);

	spin_lock_irqsave(&ep->lock, flags);
	/*
	 * During the time we spent inside the "sproc" callback, some
	 * other events might have been queued by the poll callback.
	 * We re-insert them inside the main ready-list here.
	 */
	for (nepi = ep->ovflist; (epi = nepi) != NULL;
	     nepi = epi->next, epi->next = EP_UNACTIVE_PTR) {
		/*
		 * We need to check if the item is already in the list.
		 * During the "sproc" callback execution time, items are
		 * queued into ->ovflist but the "txlist" might already
		 * contain them, and the list_splice() below takes care of them.
		 */
		if (!ep_is_linked(&epi->rdllink))
			list_add_tail(&epi->rdllink, &ep->rdllist);
	}
	/*
	 * We need to set back ep->ovflist to EP_UNACTIVE_PTR, so that after
	 * releasing the lock, events will be queued in the normal way inside
	 * ep->rdllist.
	 */
	ep->ovflist = EP_UNACTIVE_PTR;
```

ep_send_events_proc 函数

```c
// 这里priv 就是用户传进来的events 的包装 ep_send_events_data
// 这里就是具体的把已经就绪的list copy 给用户空间
static int ep_send_events_proc(struct eventpoll *ep, struct list_head *head, void *priv)
{
  /*
   * 这里esed 里面的内容就是 ep->rdllist 里面的内容
   */
	struct ep_send_events_data *esed = priv;
	int eventcnt;
	unsigned int revents;
	struct epitem *epi;
	struct epoll_event __user *uevent;

	/*
	 * We can loop without lock because we are passed a task private list.
	 * Items cannot vanish during the loop because ep_scan_ready_list() is
	 * holding "mtx" during this call.
	 */
	for (eventcnt = 0, uevent = esed->events;
	     !list_empty(head) && eventcnt < esed->maxevents;) {
		epi = list_first_entry(head, struct epitem, rdllink);

    /*
     * 这里就是默认将这个有时间到达的epi从这个rdllist 里面删除掉了,
     * 下面可以看到如果是epoll LT 模式的话, 这个epi->rdllink
     * 会重新被加入到这个rdllist 里面
     */
		list_del_init(&epi->rdllink);

    /*
     * 返回当前这个监听的fd的事件 & 这个fd 我们关注的事件
     */
		revents = epi->ffd.file->f_op->poll(epi->ffd.file, NULL) &
			epi->event.events;

		/*
		 * If the event mask intersect the caller-requested one,
		 * deliver the event to userspace. Again, ep_scan_ready_list()
		 * is holding "mtx", so no operations coming from userspace
		 * can change the item.
		 */
    /*
     * 如果这个fd发生的事件有我们关注的事件,
     * 那么我们就把这个事件返回到用户空间去
     */
		if (revents) {
			if (__put_user(revents, &uevent->events) ||
			    __put_user(epi->event.data, &uevent->data)) {
        /*
         * 这里是向用户空间拷贝函数失败的分支
         * 这里是如果失败, 那么直接返回当前有多少个事件
         * 如果一个事件也没用, 那么直接返回EFAULT
         */
				list_add(&epi->rdllink, head);
				return eventcnt ? eventcnt : -EFAULT;
			}
			eventcnt++;
			uevent++;
      // 这里上面这个分支就是EPOLLET 的情况
			if (epi->event.events & EPOLLONESHOT)
				epi->event.events &= EP_PRIVATE_BITS;
			else if (!(epi->event.events & EPOLLET)) {
        /*
         * 这里是EPOLLLT 的情况, EPOLLLT 是默认情况, 从这里看出, LT
         * 模式会将这个fd重新加入到这个rdllist 里面, 那么下次会再通知这个fd
         * 里面的事件. 那么问题来了, 什么时候才会从这个rdllist 里面删除呢?
         * 
         * 这个删除操作是默认都做的, 就在上面
         * list_del_init(&epi->rdllink);
         *
         * 比如说pipe 写进来了5个byte 的内容, 第一次读取了2个字节, 然后就返回了,
         * 在下一次执行epoll_wai()的时候, 因为LT 模式默认又加入了rdllist里面,
         * 所有会再一次检查这个fd 里面的状态, 这个时候发现里面还是有数据,
         * 就再一次返回给用户这个状态是
         *
         * 如果是ET模式, 这里可以看到不会添加回去这个rdllist,
         * 那么只有等到这个pipe里面再写入数据的时候才会触发ep_poll_callback把这个fd添加到rdllist里面,
         *
         * 从这里可以看出EPOLL_LT模式是多做了一次的检查,
         * 因为每次完成以后又会加入到这个rdllist里面, 因此性能肯定不如ET模式,
         * 但是ET模式存在说如果一次读取fd没有都读完,
         * 那么必须等到这个fd再有事件过来, 才会通知这个fd
         *
         * 另外一个问题: 这里直接往rdllist 里面添加元素, 这里遍历这个txlist
         * 不会直接把这个元素给遍历到么? 因为这里正好添加到了这个list的尾部.
         * 注释里面为什么写着是下一次的 epoll_wait 在进行一次判断呢?
         *
         * 答: 这里是epoll 实现的时候对锁粒度的一个优化, 每一次有时间的epitem
         * 是存入到idllist 这个队列里面, 然后在进行要传给用户空间操作的时候
         * ep_send_events_proc, 在上面讲这个idllist 的指针传递给了txlist指针,
         * 那么接下来就可以同时往idllist 里面添加元素,
         * 又可以处理txlist(也就是原先的rdllist)上面的内容, 这里就不需要加锁了
         */
				/*
				 * If this file has been added with Level
				 * Trigger mode, we need to insert back inside
				 * the ready list, so that the next call to
				 * epoll_wait() will check again the events
				 * availability. At this point, noone can insert
				 * into ep->rdllist besides us. The epoll_ctl()
				 * callers are locked out by
				 * ep_scan_ready_list() holding "mtx" and the
				 * poll callback will queue them in ep->ovflist.
				 */
				list_add_tail(&epi->rdllink, &ep->rdllist);
			}
		}
	}

	return eventcnt;
}
```

### Tips:

##### 如何唤醒监听的fd

这里加入我们有队列注册在某一个fd 上面, 那么当这个fd 有时间到达的时候, 是如何唤醒这个队列里面所有的进程呢

比如具体的 socket 类型的文件, 那么当这个文件有事件到达的时候, 如何进行唤醒的呢?
这里比如tcp 调用的就是  tcp_prequeue 方法, 然后里面有 wake_up_interruptible_poll
这里wake_up_interruptible_poll 就是去调用一个唤醒队列的方法了
最后都会调用到kernel/sched.c:__wake_up_common 方法
这里就跟进程的调度模块比较相关了

##### 对了file_operations 里面的poll 操作的解释

poll(file, poll_table)
Checks whether there is activity on a file and goes to sleep until something happens on it.
可以看上一个blog 

##### 当一个fd上面有事件发生的时候, 是会唤醒监听这个文件上等待的进程的. 这个是怎么做到的?

每一个设备在linux 看来都是一个文件, 那么对于文件操作来说, 每一个都需要实现file_operations 里面的poll 这个操作, 这个操作的意思是检查这个fd是否活动, 可以看上一篇blog 对应的pollc操作

比如以 pipe 的实现举例子的话

```c
struct pipe_inode_info {
  wait_queue_head_t wait;
  unsigned int nrbufs, curbuf;
  struct page *tmp_page;
  unsigned int readers;

// 这里有一个pipe_inode_info, 如果当这个pipe 有数据写入的时候
static ssize_t
pipe_read(struct kiocb *iocb, const struct iovec *_iov,
     unsigned long nr_segs, loff_t pos)
{
    ...
    // 所有的read 操作执行完以后, 判断时候需要做wakeup 操作
    // 需要做wakeup操作的话, 则把之前注册在这个pipe_inode_info 里面的函数或者
    // 进程唤醒, 这里是函数还是由进程注册的时候的决定

    if (do_wakeup) {
      wake_up_interruptible_sync(&pipe->wait);
      kill_fasync(&pipe->fasync_writers, SIGIO, POLL_OUT);
    }
}

最后的wake_up 函数其实最后会调用到
static void __wake_up_common(wait_queue_head_t *q, unsigned int mode,
      int nr_exclusive, int wake_flags, void *key)

这个函数里面去了, 然后最后的调用是
    /*
     * 这里的func 默认会调用到default_wake_function, 因为在wait_queue_t
     * 初始化的时候回设置func = default_wake_function
     * 如果有注册函数就执行对应的注册函数
     */
    if (curr->func(curr, mode, wake_flags, key) &&
        (flags & WQ_FLAG_EXCLUSIVE) && !--nr_exclusive)
      break;
  }
就是执行注册的函数
```


最后就会调用wake_up_interruptible_sync, 这个就把pipe_inode_info 上面的wait_queue_head_t 上面的等待进程队列唤醒, 那么这里pipe->wait 上面的这个等待队列是什么时候加上去的呢?

说明每一个文件都有这个文件的唤醒队列, 当这个文件有操作的时候, 会通过wake_up 操作来将这个唤醒队列的进程给唤醒,

#### 那么一般是怎么加入到这个唤醒队列里面的呢?

首先是注册到这个fd 的wait_queue_t 里面

过程是在epoll_insert 的时候会调用一下这个pipe fd的poll() 函数
这里在epoll 里面会调用

revents = tfile->f_op->poll(tfile, &epq.pt);

这个操作就是将当前的进程加入到tfile 这个fd 的唤醒队列里面去.

对应于在pipe 里面的调用就是

pipe_poll(struct file *filp, poll_table *wait)

然后在pipe_poll 里面调到的最重要的是

poll_wait(filp, &pipe->wait, wait);

poll_wait 本质到最后调用的是ep_ptable_queue_proc函数, 因为在epoll 调用tfile->f_op->poll 的时候已经注册了这个回调函数

这里是通过 

init_poll_funcptr 这个函数来注册对应的poll_queue_proc的

static void ep_ptable_queue_proc(struct file *file, wait_queue_head_t *whead, poll_table *pt)
{


#### 为什么说 poll/select 的性能比较低

1. 在poll/select 的实现里面, 如果监听多个fd, 只要其中有一个fd 有事件达到, 那么久遍历一个list 去检查到底是哪一个事件到达, 并没有像epoll 一样将这些fd 放在一个红黑树上

```c

  /*
   * 程序在这里面schedule_timeout 中sleep, 如果有事件到达,
   * 从schedule_timeout中唤醒, 然后重新执行逻辑
   */
	for (;;) {
		unsigned long *rinp, *routp, *rexp, *inp, *outp, *exp;

		inp = fds->in; outp = fds->out; exp = fds->ex;
		rinp = fds->res_in; routp = fds->res_out; rexp = fds->res_ex;

    /*
     * 这里检查监听的所有的fd 的状态, 如果这个fd 有事件, 就把对应的rinp, routp,
     * rexp 进行修改
     * 这里可以看到, 即使只有一个fd有事件到达, 这里也要把所有的fd 都遍历一遍,
     * 这就是性能很低的原因了
     */
		for (i = 0; i < n; ++rinp, ++routp, ++rexp) {

```

2. 在进行select 的过程中, 是先将要监听的fd 从用户空间拷贝到内核空间, 然后在内核空间里面进行修改以后, 在拷贝回去给用户空间. 这里就设计到内核空间申请内存, 释放内存等等过程

```c
int core_sys_select(int n, fd_set __user *inp, fd_set __user *outp,
			   fd_set __user *exp, struct timespec *end_time)
{
	fd_set_bits fds;
	void *bits;
	int ret, max_fds;
	unsigned int size;
	struct fdtable *fdt;
  // 可以看到select 是先尝试分配空间在栈上, 下面代码可以看出加入这个需要监听的fd
  // 比较多, 那么就会去申请堆空间里面的内容
  // 这里SELECT_STACK_ALLOC 默认是 256, 那么也就是这个当监听的fd
  // 的个数小于256个的时候, 这里的空间实在栈上,
  // 如果大于256其实空间实在堆上面申请的
	/* Allocate small arguments on the stack to save memory and be faster */

	long stack_fds[SELECT_STACK_ALLOC/sizeof(long)];

	ret = -EINVAL;
	if (n < 0)
		goto out_nofds;

	/* max_fds can increase, so grab it once to avoid race */
	rcu_read_lock();
	fdt = files_fdtable(current->files);
	max_fds = fdt->max_fds;
	rcu_read_unlock();
	if (n > max_fds)
		n = max_fds;

	/*
	 * We need 6 bitmaps (in/out/ex for both incoming and outgoing),
	 * since we used fdset we need to allocate memory in units of
	 * long-words. 
	 */
	size = FDS_BYTES(n);
	bits = stack_fds;
	if (size > sizeof(stack_fds) / 6) {
		/* Not enough space in on-stack array; must use kmalloc */
		ret = -ENOMEM;
		bits = kmalloc(6 * size, GFP_KERNEL);
		if (!bits)
			goto out_nofds;
	}
  /*
   * 这里分别为in, out, ex, res_in, res_out, res_ex 初始化指针到对应的空间里面
   *
   * 我们经常说的select 需要拷贝这个fd 值得就是这里,
   * 就是将用户空间注册的要监听的fd inp, outp, exp 拷贝到fds.in, fds.out,
   * fds.ex. 然后这些fd 的事件的结果我们保存在 fds.res_in, fds.res_out,
   * fds.res_ex. 然后再将这里面的内容拷贝回去到用户空间 inp, outp, exp
   */
	fds.in      = bits;
	fds.out     = bits +   size;
	fds.ex      = bits + 2*size;
	fds.res_in  = bits + 3*size;
	fds.res_out = bits + 4*size;
	fds.res_ex  = bits + 5*size;

  /*
   * 这里就是我们经常说的select需要去用户空间拷贝内容的代码
   * 这里就是把存在inp 里面注册的内容拷贝到 fds.in 里面
   */
	if ((ret = get_fd_set(n, inp, fds.in)) ||
	    (ret = get_fd_set(n, outp, fds.out)) ||
	    (ret = get_fd_set(n, exp, fds.ex)))
		goto out;
	zero_fd_set(n, fds.res_in);
	zero_fd_set(n, fds.res_out);
	zero_fd_set(n, fds.res_ex);

  /*
   * 这里是最主要的select 的过程了
   * ret 返回的是当前有事件的fd 的个数
   */
	ret = do_select(n, &fds, end_time);

	if (ret < 0)
		goto out;
	if (!ret) {
		ret = -ERESTARTNOHAND;
		if (signal_pending(current))
			goto out;
		ret = 0;
	}

  /*
   * 这里就是讲内核空间fds.res_in, out, ex里面的内容拷贝回去到inp, outp, exp
   * 的过程
   */
	if (set_fd_set(n, inp, fds.res_in) ||
	    set_fd_set(n, outp, fds.res_out) ||
	    set_fd_set(n, exp, fds.res_ex))
		ret = -EFAULT;

out:
	if (bits != stack_fds)
		kfree(bits);
out_nofds:
	return ret;
}

```

