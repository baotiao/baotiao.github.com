---
author: admin
comments: true
date: 2011-08-10 02:34:58+00:00
layout: post
slug: iconv-%e8%84%9a%e6%9c%ac-%e8%bd%ac%e6%8d%a2%e5%ad%97%e7%ac%a6%e7%bc%96%e7%a0%81%e8%84%9a%e6%9c%ac
title: iconv 脚本 转换字符编码脚本
wordpress_id: 39
categories:
- script
tags:
- iconv
- mac
---

这个脚本碰到有些别字的中文的时候会报错,直接去文件里面该就可以了.iconv: 北京.csv:31:12: cannot convert

iconv: 总部.csv:315:12: cannot convert

iconv: 福州.csv:3:12: cannot convert
比如这样  就是  在 北京.csv 31 行 有错 改下就可以了.
`
#!/bin/sh
MYPATH=`pwd`;
files=`ls`;
for filename in $files
do
iconv -f UTF-8 -t GBK $filename > gbk.$filename;
done
`
