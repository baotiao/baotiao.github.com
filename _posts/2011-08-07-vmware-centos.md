---
author: admin
comments: true
date: 2011-08-07 14:29:07+00:00
layout: post
slug: vmware-centos-%e5%ae%89%e8%a3%85
title: vmware centos 安装
wordpress_id: 35
categories:
- life
tags:
- centos
- vmware
---

分享一下今天在vmware 下 centos 的安装过程遇到的问题.
centos 在vmware 里面安装的时候 不要选择简单安装.然后就会进入到centos标准安装界面.
swap 就是linux下的虚拟内存分区,它的作用是在物理内存使用完之后,将磁盘空间(也就是SWAP分区)虚拟成内存来使用.
需要注意的是他的速度比物理内存慢多了,因为他是从磁盘中读取的.如果想更快速度,swap是没用的然后看鸟哥的centos安装教程 在centos 里面安装好以后要 提示插入第二个盘 那么 选择 CD&DVD 然后 勾上 Connected . 然后在Use disc image 选上那个镜像就可以了.

在centos 里面 安装 VMTool 在 菜单栏 里面有 virtual Machine 然后 里面 [slot machines online](http://hollandslotscasino.nl/) install VMTool . 进去以后把 /media 下面的 VMTools 复制出来再安装

在centos 里面可能无法上网, 首先得先装好 VMTool ,然后 在 系统->管理->网络->双击eth0 里面配置设置成自动获取就可以了.然后保存 /etc/init.d/network restart 就可以了.
