---
layout: post
title: MySQL client Tips
summary: MySQL client 命令 pager/edit/tee 介绍
---

1. **pager**

   pager + 任何命令

   常用的比如:

    pager grep 'Pending normal aio reads'

   就可以执行show engine innodb status 以后只看grep 的内容

   ```shell
   mysql> pager grep 'Pending normal aio reads'
   PAGER set to 'grep 'Pending normal aio reads''
   mysql> show engine innodb status\G
   Pending normal aio reads: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] , aio writes: [256, 256, 256, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] ,
   1 row in set (0.00 sec)
   ```

   pager less

   那么执行show engine innodb status 以后直接less 查看结果

   pager vim -

   然后执行show engine innodb status 就可以直接进入到vim 里面编辑执行结果

   

   关闭pager 就是执行 nopager 或者 \n 就可以

   \P 又重新恢复上一个pager 的设置

   还有一些骚操作 比如:

   * 如果我只想要看执行的时间, 不想要看具体的结果, 这么多次执行可以在同一个屏幕里面显示, 那么可以执行

   ```mysql
   mysql> pager cat > /dev/null
   PAGER set to 'cat > /dev/null'
    
   # Trying an execution plan
   mysql> SELECT ...
   1000 rows in set (0.91 sec)
    
   # Another execution plan
   mysql> SELECT ...
   1000 rows in set (1.63 sec)
   ```

   * 比如我要对比两次查询的结果是否一致, 那么可以通过md5 命令来进行对比

     ```mysql
     mysql> pager md5sum
     PAGER set to 'md5sum'
     
     # Original query
     mysql> SELECT ...
     32a1894d773c9b85172969c659175d2d  -
     1 row in set (0.40 sec)
     
     # Rewritten query - wrong
     mysql> SELECT ...
     fdb94521558684afedc8148ca724f578  -
     1 row in set (0.16 sec)
     ```

   比如最常用的show processlist 里面, 也可以使用pager 去查有多少个sleep 的线程

   ```mysql
   mysql> pager grep Sleep | wc -l
   PAGER set to 'grep Sleep | wc -l'
   mysql> show processlist;
   337
   346 rows in set (0.00 sec)
   
   # 或者可以写的更复杂一些, 统计所有的.
   mysql> pager awk -F '|' '{print $6}' | sort | uniq -c | sort -r
   PAGER set to 'awk -F '|' '{print $6}' | sort | uniq -c | sort -r'
   mysql> show processlist;
       309  Sleep       
         3 
         2  Query       
         2  Binlog Dump 
         1  Command
   ```

   pager 后面也可以用写一个脚本来承接, 更骚
   
   ```shell
   #!/bin/sh
   
   grep -A 1 'TRX HAS BEEN WAITING'
   ```
   
   把这个脚本保存在 /tmp/lock_waits 上, 那么就可以过滤show engine innodb status 里面 trx wait 的
   
   ```mysql
   mysql> pager /tmp/lock_waits
   PAGER set to '/tmp/lock_waits'
   mysql> show innodb status\G
   ------- TRX HAS BEEN WAITING 50 SEC FOR THIS LOCK TO BE GRANTED:
   RECORD LOCKS space id 0 page no 52 n bits 72 index `GEN_CLUST_INDEX` of table `test/t` trx id 0 14615 lock_mode X waiting
   1 row in set, 1 warning (0.00 sec)
   ```
   
   当然还有更复杂的, 把explain 的结果进行更详细的展示的



2. **edit**

   edit  命令能够把你上一句命令放在vim 编辑器里面进行编辑, 然后再执行

   ```mysql
   mysql> select count(*) from film left join film_category using(film_id) left join category using(category_id) where name='Music';
   ```

   然后执行 edit 命令, 就进入到vim 终端编辑了

3. **tee**

   把执行的结果输出到另外一个文件里面

   ```mysql
   mysql> tee queries.log
   Logging to file 'queries.log'
   mysql> use sakila
   Reading table information for completion of table and column names
   You can turn off this feature to get a quicker startup with -A
   
   Database changed
   mysql> select count(*) from sakila;
   ERROR 1146 (42S02): Table 'sakila.sakila' doesn't exist
   mysql> select count(*) from film;
   +----------+
   | count(*) |
   +----------+
   |     1000 |
   +----------+
   1 row in set (0.00 sec)
   
   mysql> exit
   ```

   
