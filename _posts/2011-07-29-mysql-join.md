---
author: admin
comments: true
date: 2011-07-29 18:13:57+00:00
layout: post
slug: mysql-join-%e5%ad%a6%e4%b9%a0
title: mysql join 学习
wordpress_id: 32
categories:
- mysql
tags:
- Mysql
---

join 的学习: 在SQL标准中规划的（Join）联结大致分为下面四种： 1． 内联结：将两个表中存在联结关系的字段符合联结关系的那些记录形成记录集的联结。 2． 外联结：分为外左联结和外右联结。 左联结A、B表的意思就是将表A中的全部记录和表B中联结的字段与表A的联结字段符合联结条件的那些记录形成的记录集的联结，这里注意的是最后出来的记录集会包括表A的全部记录。 右联结A、B表的结果和左联结B、A的结果是一样的，也就是说： Select A.name B.name From A Left Join B On A.id=B.id 和Select A.name B.name From B Right Join A on B.id=A.id执行后的结果是一样的。 还有其他的联结就不用管了. 这里 就是 内联结是只将符合条件的列出来,而外联接是将全部的都列出来,分左右外联接啦. 这里我有个比较简便的记忆方法，内外联结的区别是内联结将去除所有不符合条件的记录，而外联结则保留其中部分。外左联结与外右联结的区别在于如果用A左联结B则A中所有记录都会保 留在结果中，此时B中只有符合联结条件的记录，而右联结相反，这样也就不会混淆了比如表t1 有 2数据 1,2 表 t2 有一个数据 1. 那么 select t1.s1,t2.s1 from t1 inner join t2 on t1.s1=t2.s1; ------ ------ | s1 | s1 | ------ ------ | 1 | 1 | ------ ------ 这个时候 t1里面的 2 这个数据由于在t2表里面找不到 就会被除去. left join [casino online](http://britishcasino.org.uk/) 的时候 select t1.s1,t2.s1 from t1 left join t2 on t1.s1=t2.s1; ------ ------ | s1 | s1 | ------ ------ | 1 | 1 | | 2 | NULL | 这个时候是 t1为左表都保存下来. ------ ------ 同样 right join 的时候 select t1.s1,t2.s1 from t1 right join t2 on t1.s1=t2.s1; ------ ------ | s1 | s1 | ------ ------ | 1 | 1 |
