---
layout: post
title: "kernel file poll operations"
description: "kernel file poll operations"
category: kernel, tech
tags: [kernel]
---

#### 在file_operations 里面, poll 这个操作到底是什么意思

在ulk 里面poll 操作的解释是

Checks whether there is activity on a file and goes to sleep until something happens on it.

然后我看了kernel(2.6.32) 里面的实现, 其实并没有sleep的过程

看不同kernel 里面fd 的poll 实现可以发现其实poll 操作做的事情主要是两个

1. 注册这个唤醒队列的回调函数, 也就是设置当这个fd 有事件到达的时候的执行函数
2. 返回当前这个fd 的事件状态, 比如这里pipe 的状态就是根据 nrbufs 里面的内容的多少来返回这个当前fd的状态, tcp的判断就更加复杂一些

比如这个是pipe 上面的 poll 操作 pipe_poll()

```

/* No kernel lock held - fine */
static unsigned int
pipe_poll(struct file *filp, poll_table *wait)
{
  unsigned int mask;
  struct inode *inode = filp->f_path.dentry->d_inode;
  struct pipe_inode_info *pipe = inode->i_pipe;
  int nrbufs;

  poll_wait(filp, &pipe->wait, wait);

  /* Reading only -- no need for acquiring the semaphore.  */
  nrbufs = pipe->nrbufs;
  mask = 0;
  if (filp->f_mode & FMODE_READ) {
    // 这里nrbufs > 0, 说明这个pipe里面是有内容的, 因此这个fd 有可读事件
    mask = (nrbufs > 0) ? POLLIN | POLLRDNORM : 0;
    if (!pipe->writers && filp->f_version != pipe->w_counter)
      mask |= POLLHUP;
  }

  if (filp->f_mode & FMODE_WRITE) {
    // 只要nrbufs < PIPE_BUFFERS, 说明这个pipe 还没被写满, 那么这个fd 就是可写的
    mask |= (nrbufs < PIPE_BUFFERS) ? POLLOUT | POLLWRNORM : 0;
    /*
     * Most Unices do not set POLLERR for FIFOs but on Linux they
     * behave exactly like pipes for poll().
     */
    if (!pipe->readers)
      mask |= POLLERR;
  }

  return mask;
}
```

对应的tcp 里面是否有时间到达的poll 函数是 tcp_poll()

```
unsigned int tcp_poll(struct file *file, struct socket *sock, poll_table *wait)
{
  unsigned int mask;
  struct sock *sk = sock->sk;
  struct tcp_sock *tp = tcp_sk(sk);
  sock_poll_wait(file, sk->sk_sleep, wait);
  if (sk->sk_state == TCP_LISTEN)
    return inet_csk_listen_poll(sk);

  /* Socket is not locked. We are protected from async events
   * by poll logic and correct handling of state changes
   * made by other threads is impossible in any case.
   */

  mask = 0;
  if (sk->sk_err)
    mask = POLLERR;

...
  if (sk->sk_shutdown == SHUTDOWN_MASK || sk->sk_state == TCP_CLOSE)
    mask |= POLLHUP;
  if (sk->sk_shutdown & RCV_SHUTDOWN)
    mask |= POLLIN | POLLRDNORM | POLLRDHUP;

  /* Connected? */
  if ((1 << sk->sk_state) & ~(TCPF_SYN_SENT | TCPF_SYN_RECV)) {
    int target = sock_rcvlowat(sk, 0, INT_MAX);

    if (tp->urg_seq == tp->copied_seq &&
        !sock_flag(sk, SOCK_URGINLINE) &&
        tp->urg_data)
      target--;

    /* Potential race condition. If read of tp below will
     * escape above sk->sk_state, we can be illegally awaken
     * in SYN_* states. */
    if (tp->rcv_nxt - tp->copied_seq >= target)
      mask |= POLLIN | POLLRDNORM;

    if (!(sk->sk_shutdown & SEND_SHUTDOWN)) {
      if (sk_stream_wspace(sk) >= sk_stream_min_wspace(sk)) {
        mask |= POLLOUT | POLLWRNORM;
      } else {  /* send SIGIO later */
        set_bit(SOCK_ASYNC_NOSPACE,
          &sk->sk_socket->flags);
        set_bit(SOCK_NOSPACE, &sk->sk_socket->flags);
    /* Potential race condition. If read of tp below will
     * escape above sk->sk_state, we can be illegally awaken
     * in SYN_* states. */
    if (tp->rcv_nxt - tp->copied_seq >= target)
      mask |= POLLIN | POLLRDNORM;

    }

    if (tp->urg_data & TCP_URG_VALID)
      mask |= POLLPRI;
  }
  return mask;
}
```

这里可以看到, tcp 的tcp_poll() 里面也是同样调用socket_poll_wait, 然后socket_poll_wait 调用poll_wait来注册当有时间发生的时候的回调函数.

然后这里tcp 这个是否有时间到达需要进行的判断就比pipe 要复杂的多, 比如这里需要判断socket 的是否shut_down, 需要判断tp->rcv_nxt 等等, 最后才能获得这个fd 上面的事件的内容
