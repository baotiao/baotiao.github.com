---
layout: post
title: "network programming echo example"
description: "network programming echo example"
category: tech
tags: [network, c++]
---

socket 描述符就跟 file 描述符一样.

1个字节有8位.也就是1个字节可以表示0~255(2^8). 所以short是2个字节,表示的就是0~(2^16). 因为int 是4字节,所以int表示的就是0~(2^32)
short s = 0x0100 0x是标志是16进制,所以00是第一个字节,01是第二个字节.所以这里表示的值是256
所有的套接字地址结构一般都要包含3个字段 sa_family_t sin_family, struct in_addr sin_addr, in_port_t sin_port. 也就是套接字的address family 地址协议,套接字监听的地址,监听的端口号.

所有客户和服务器都从调用socket开始,它返回一个套接字描述符号.客户随后调用connect,服务器则调用bind,listen和accept.大多数TCP服务器是并发的,所以为每个待处理的客户连接建立一个fork出一个子进程来处理.

socket 指定期望的通信协议类型(使用ipv4的tcp,使用ipv6的udp等)
int socket(int family, int type, int protocol)
其中family参数执行协议组,就是上面讲的address family地址协议,type参数指明套接字的类型.protocol参数为某个协议类型常值.
函数在成功时返回一个小的非负整数值,它与文件描述符类似,我们把它称为套接字描述符,简称sockfd.

在server 与 client 交互过程会产生3个sockfd,client 产生一个fd.然后connect server的addr.
在server端先是产生一个fd,bind()绑定自己的ip地址和端口号. 然后接下来listen.然后accept 阻塞等待client接过来一个请求.等到client正好connect这个server后就生成一个新的connected的fd, 还有就是一个client_addr.这个就是server获得到的两个东西,然后就是写数据或者收数据都是直接对这个sockfd进行的,而不是对这个地址进行的.

    // 这个是srv端程序.
    #include<stdio.h>
    #include<netinet/in.h>
    #include<sys/socket.h>
    #include<string.h>
    void str_echo(int sockfd)
    {
        ssize_t n;
        char buf[1000];
    again:
        while ((n = read(sockfd, buf, 1000)) > 0) { //读已经建立连接的socket的数据.
            fputs("a socket has come\n", stdout);
            write(sockfd, buf, n+3); // 写入数据
        }
        if (n < 0)
            exit(0);
    }
    int main()
    {
        int listenfd, connfd;  //这两个分别是监听时候的链接,和accept建立以后的链接.
        pid_t childpid; //子进程的id.
        socklen_t clilen; 
        struct sockaddr_in cliaddr, servaddr; // 基于ipv4的套接字地址结构
        listenfd = socket(AF_INET, SOCK_STREAM,0); //返回一个socket描述符
        memset(&servaddr, 0, sizeof(servaddr));// 把这个servaddr地址初始化
        servaddr.sin_family = AF_INET; // 设置 adress family
        servaddr.sin_addr.s_addr = htonl(INADDR_ANY); // 设置套接字监听的地址为通配地址
        servaddr.sin_port = htons(9877); // 设置监听的端口号  
        bind(listenfd, (struct sockaddr *) &servaddr, sizeof(servaddr));
         //将这个listenfd socket 描述符绑定到servaddr这个地址
        listen(listenfd, 10); //listenfd 这个socket端口开始监听
        for(; ; ) { // 一个死循环来server
            clilen = sizeof(cliaddr);
            connfd = accept(listenfd, (struct sockaddr *) &cliaddr, &clilen);
            // 这里阻塞accept 等待 cli 连接. cli 连接成功会一个新的connfd,这个connfd就是通向客户端的socket描述符,往这个描述符写东西就可以送到客户端.
            if ((childpid = fork() == 0)) {
                close(listenfd);
                str_echo(connfd);
                exit(0);
            }
            fputs("i am parent\n", stdout);
            close(connfd);
        }
        return 0;
    }

这个是cli端程序

    //cli 端的程序要做的事情也和srv端一样,不过初始化好地址以后,调用connect.试图与srv端连接.链接成功则将一个文件描述符指向srv端,就可以srv端写入或者读出数据了.
    #include<stdio.h>
    #include<netinet/in.h>
    #include<unistd.h>
    #include<sys/socket.h>
    #include<string.h>
    void str_cli(FILE *fp, int sockfd)
    {
        char sendline[1000], recvline[1000];
        while(fgets(sendline, 1000, fp) != NULL) {
            write(sockfd, sendline, strlen(sendline));
            if (read(sockfd, recvline, 100) == 0)
                printf("server terminated\n");
            fputs(recvline, stdout);
        }
    }
    int main(int argc, char *argv[])
    {
        int sockfd;
        struct sockaddr_in servaddr;
        sockfd = socket(AF_INET, SOCK_STREAM, 0);
        memset(&servaddr, 0, sizeof(servaddr));
        servaddr.sin_family = AF_INET;
        servaddr.sin_port = htons(9877);
        inet_pton(AF_INET, argv[1], &servaddr.sin_addr);
        connect(sockfd, (struct sockaddr *) &servaddr, sizeof(servaddr));
        str_cli(stdin, sockfd);
        return 0;
    }

