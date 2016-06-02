---
date: 2011-08-17 02:05:32+00:00
layout: post
title: grep in awk
---

```shell
awk 'BEGIN {while (( getline < "f2" > 0 )) { f2[lc] = $0 ;lc++;}} { for (i=1; i<lc; i++) { if (match (f2[i], $1)) print f2[i];}}' f1

awk 'BEGIN {while (( getline < "f2" > 0 )) { f2[lc] = $0 ;lc++;}} { for (i=1; i<lc; i++) { if (f2[i] ~ $1) print f2[i];}}' f1
```


其中 match 函数 match(s,r)              测试s是否包含匹配r的字符串
有两个文件 f1 包含

```shell
czz 234
xyy 2ee
ghy 2g3
```

f2包含

```shell
au=xyygxh
ssssssssssssss
au=xyy;xyygxhgxh
au=czz;andxyy
au=czz;andguanxiaohong
```

现在 要把 f2 搜索一次 如果有包含 czz 就列出来, 然后 再把f2搜索一次 有xyy就列出来 
所以答案应该是 

```shell
au=czz;andxyy
au=czz;andguanxiaohong
au=xyy;xyygxhgxh
au=czz;andxyy
au=xyy;xyygxhgxh
```

刚开始想到的是 先 awk 然后 里面再用 grep 来做,不过后来试验了无数次 grep 总是报错, 不过也知道了 grep 里面包含awk的方法.
就是 grep "$(awk '{printf("%s"), $1;}' f1)" f2 这样就是把  f2 中 包含 czz 或者 xyy 或者 ghy 的找出来.
后来grep 放弃了, 后来看到有这个 match 函数 试了一下,马上就可以了.

```shell
awk 'BEGIN {while (( getline < "f2" > 0 )) { f2[lc] = $0 ;lc++;}} { for (i=1; i<lc; i++) { if (match (f2[i], $1)) print f2[i];}}' f1
```

这里 在 BEGIN 的时候 吧 f2的文件都读进来,然后 存在f2数组里面,然后 接下来对每一个f1文件里面的每一行 都 与f2数组做比较.
match(s,r) 的意思是测试s是否包含匹配r 的字符串. 所以f2[i] 包含 $1 就会输出 f2[i].

还有一种做法 

```shell
awk 'BEGIN {while (( getline < "f2" > 0 )) { f2[lc] = $0 ;lc++;}} { for (i=1; i<lc; i++) { if (f2[i] ~ $1) print f2[i];}}' f1
```

这里 匹配的时候要注意两点  if (f2[i] ~ $1) 就是 f2[i] 中 包含 $1 这个正则表达式 
还有 就是 是否要用着 /""/ 这个问题, 如果是变量就不要用,不是变量就必须用. 
这样这里就不用grep  实际上也是实现了 grep 的功能.
线上实际用到这个命令的地方.

```shell
awk 'BEGIN { while (( getline < "/var/sankuai/wwwlogs/www.meituan.com-110816-access_log" > 0))  { f2[lc] = $0; lc++;}} -F "," { name = "au="$2"[;|\"]"; for (i = 1; i < lc; i++) {if (f2[i] ~ name) print f2[i];} printf("\n\n");}' zhuagui.ouput > zhuagui50
```
