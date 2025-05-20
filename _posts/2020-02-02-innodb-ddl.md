---
layout: post
title: InnoDB DDL 主要流程介绍
summary: InnoDB DDL 介绍

---



**DDL 主要流程**

1. 在prepare phase 阶段, 需要对要进行DDL 的table 加 X mdl
2. 根据这次要执行的DDL 语句, 创建一个新的schema 的table1, 然后放掉x mdl
3. 然后如果是Copy algorithm那么就每次从老的table 拷贝到新的table1, 如果是inplace algorithm, 那么每次就inplace 的修改每一行数据的内容. 期间如果有DML 操作, 如果是读取, 就正常读取, 如果是写入, 那么就把写入的内容记录到row_log 中
4. 重新获得table mdl, 然后将row_log 中的记录写入到table1 中, 这个过程需要一直拿着table mdl lock 防止有新数据写入, 因此如果这个时候row_log 中的内容比较多, 那么这个操作会持续一段时间
5. 将原来的table drop 掉, 然后将table1 rename 成 table






DDL 过程中常见的参数:

https://dev.mysql.com/doc/refman/8.0/en/innodb-online-ddl-space-requirements.html





**对于 Online DDL 的定义**

从mysql5.6开始，很多DDL操作过程都进行了改进，出现了Online DDL。所谓Online DDL就是指这类DDL操作和DML基本上可以不发生冲突(不是绝对不冲突)，表在执行DDL操作时同样可以执行DML操作。mysql5.6时只是部分DDL操作online化，到现在绝大部分DDL都是Online DDL。

**我们所说的 Online DDL 其实主要指的是在DDL 的过程中依然是可写的, 非Online DDL 在运行过程中, 一般是不可写的.**

**不管是否Online, DDL 的过程中, 数据都是可以访问的.**



在做DDL 的时候 一般分成INPLACE 和 COPY 两种方式, 通过在Alter 语句的时候执行algorithm 来指定

* COPY  需要拷贝原始表, 所以不允许写操作
* Inplace 不需要拷贝原始表, 直接在当前的表上进行, 可以节省大量的IO
  * Online DDL  可以写
  * 非Online DDL  不可写



在DDL 选择inplace 的时候, 才会有选项是否支持Online(代码中实现其实是在Inplace 的时候, 通过row_log 记录DDL 过程中插入的数据, 在DDL 结束以后回放row_log 中的数据来实现).

所以如果选择copy table 的方式进行DDL, 那肯定是无法Online 的, 也就是不可写, 只可读的. 

一般来说inplace 方式DDL 都是Online,  但是有时候虽然是inplace 的方式, 但是还是需要copy table的



对于不同的DDL 类型, 我们主要关注4个维度

1. In-Place  是否是In-Place 操作, 目前大部分DDL 操作已经是In-Place 操作了
2. copy table  是否需要copy-table, 是否需要重建表, 一般in-place 操作都不需要重建表, 但是有些操作, 比如修改列顺序, 删除列, 添加列这些操作虽然是in-place, 但是还是需要重建表.   其实是否需要copy table 主要是因为cluster index 里面的leaf-node 保存的是具体的数据, 所以加了列, 那么肯定需要把cluster index 里面的数据整理.  所以考虑是否需要copy table 的时候, 我们想想cluster index 里面的数据是否要重新整理就知道了
3. Allows Concurrent DML  是否允许写,  inplace DDL 一般都允许写, non-inplace 一般不允许写
4. Allows Concurrent Query  DDL 过程一直都是允许读的



| Operation                        | In-Place? | Copies Table? | Allows Concurrent DML? | Allows Concurrent Query? | Notes                                                        |
| -------------------------------- | --------- | ------------- | ---------------------- | ------------------------ | ------------------------------------------------------------ |
| 添加索引                         | Yes*      | No*           | Yes                    | Yes                      | 对全文索引的一些限制                                         |
| 删除索引                         | Yes       | No            | Yes                    | Yes                      | 仅修改表的元数据                                             |
| OPTIMIZE TABLE                   | Yes       | Yes           | Yes                    | Yes                      | 从 5.6.17开始使用ALGORITHM=INPLACE，当然如果指定了`old_alter_table=1`或mysqld启动带`--skip-new`则将还是COPY模式。如果表上有全文索引只支持COPY |
| 对一列设置默认值                 | Yes       | No            | Yes                    | Yes                      | 仅修改表的元数据                                             |
| 对一列修改auto-increment 的值    | Yes       | No            | Yes                    | Yes                      | 仅修改表的元数据                                             |
| 添加 foreign key constraint      | Yes*      | No*           | Yes                    | Yes                      | 为了避免拷贝表，在约束创建时会禁用foreign_key_checks         |
| 删除 foreign key constraint      | Yes       | No            | Yes                    | Yes                      | foreign_key_checks 不影响                                    |
| 改变列名                         | Yes*      | No*           | Yes*                   | Yes                      | 为了允许DML并发, 如果保持相同数据类型，仅改变列名            |
| 添加列                           | Yes*      | Yes*          | Yes*                   | Yes                      | 尽管允许 ALGORITHM=INPLACE ，但数据大幅重组，所以它仍然是一项昂贵的操作。当添加列是auto-increment，不允许DML并发 |
| 删除列                           | Yes       | Yes*          | Yes                    | Yes                      | 尽管允许 ALGORITHM=INPLACE ，但数据大幅重组，所以它仍然是一项昂贵的操作 |
| 修改列数据类型                   | No        | Yes*          | No                     | Yes                      | 修改类型或添加长度，都会拷贝表，而且不允许更新操作           |
| 更改列顺序                       | Yes       | Yes           | Yes                    | Yes                      | 尽管允许 ALGORITHM=INPLACE ，但数据大幅重组，所以它仍然是一项昂贵的操作 |
| 修改ROW_FORMAT  和KEY_BLOCK_SIZE | Yes       | Yes           | Yes                    | Yes                      | 尽管允许 ALGORITHM=INPLACE ，但数据大幅重组，所以它仍然是一项昂贵的操作 |
| 设置列属性NULL 或NOT NULL        | Yes       | Yes           | Yes                    | Yes                      | 尽管允许 ALGORITHM=INPLACE ，但数据大幅重组，所以它仍然是一项昂贵的操作 |
| 添加主键                         | Yes*      | Yes           | Yes                    | Yes                      | 尽管允许 ALGORITHM=INPLACE ，但数据大幅重组，所以它仍然是一项昂贵的操作。 如果列定义必须转化NOT NULL，则不允许INPLACE |
| 删除并添加主键                   | Yes       | Yes           | Yes                    | Yes                      | 在同一个 ALTER TABLE 语句删除就主键、添加新主键时，才允许inplace；数据大幅重组,所以它仍然是一项昂贵的操作。 |
| 删除主键                         | No        | Yes           | No                     | Yes                      | 不允许并发DML，要拷贝表，而且如果没有在同一 ATLER TABLE 语句里同时添加主键则会收到限制 |
| 变更表字符集                     | No        | Yes           | No                     | Yes                      | 如果新的字符集编码不同，重建表                               |





online DDL 主要包含3个阶段

1. prepare 阶段

   执行函数 ha_prepare_inplace_alter_table 最后执行到 InnoDB 中 ha_innobase::prepare_inplace_alter_table => prepare_inplace_alter_table_impl => prepare_inplace_alter_table_dict

2. ddl 阶段

   执行函数 ha_inplace_alter_table 最后执行到InnoDB 中

   ha_innobase::inplace_alter_table

3. commit 阶段

   执行函数 ha_commit_inplace_alter_table  最后执行到InnoDB 中handler0alter.cc ha_innobase::commit_inplace_alter_table





#### 最常见的场景, 增加一个index 的时候, 代码的执行流程



在create index 的时候, 主要流程

1. row0merge.c::row_merge_create_index();  // 创建新的索引所需要的索引结构信息, 创建内存结构体 dict_index_t

2. row0merge.c::row_merge_build_indexes();  // 读取cluster index, 然后对读取到的文件排序, 最后插入到新的索引结构中

   ​	1. row_merge_read_clustered_index();

   ​	2. row_merge_sort();

   ​	3. row_merge_insert_index_tuples();

   三个步骤对应建立索引的3个阶段

   1. 读取阶段: 读cluster index
   2. 排序阶段: 对索引临时文件进行排序
   3. 建立阶段: 插入记录建索引

3. row0log.cc::row_log_table_apply 在完成这3个步骤以后, 因为Online DDL 的同时是还允许用户写入, 因为在将DDL 开始前的数据都插入到新的索引, 还需要将在DDL期间的数据也要插入到新的索引.

   在Online DDL 实现中, 将DDL 期间新插入的数据写入到 row_log 中, 那么DDL 完成后, 需要将row_log 中的数据进行apply 

   在Online create index 的时候, 增加了row log 相关的操作.



**copy DDL**

copy ddl首尾加mdl x锁，中间执行阶段加的mdl锁不允许写，允许读

而online ddl 首尾加mdl xlock, 中间执行阶段不加mdl 锁. 所以是允许写的




**Aurora fast DDL 的核心思路**

Aurora support fast DDL, 其实我理解fast DDL 类似实现了多版本的 dd 信息.

https://aws.amazon.com/blogs/database/amazon-aurora-under-the-hood-fast-ddl/

Moving them to parallel, background, and asynchronous execution makes a difference.

将DDL 这个同步操作 改成 并行, 并行在后台执行的异步操作来实现 fast DDL

**我理解fast ddl 是目前共享存储架构必须实现的一套方案, 因为ro, rw 共享一套数据了, 那么rw 必然需要和ro 共享一份DD 数据, 因此想做DDL 只能阻止ro 访问了, 这个实现更值得做了**

那么fast DDL是怎么做的呢?



1. 首先在发起 DDL 操作以后, database 只需要更新了 information_schema 里面的表结构信息, 这里是支持多版本的 information_schema, 增加了一个新版本, 然后把这个通知给所有的 replica

   这样前台的同步操作就完成了, 后续都是异步后台的操作了

2. 那么接下来如果有 DML 操作,  会先看要访问的page schema是否有一个还没有执行完成的 DDL 操作.  比较的方法是通过比较这个page 的lsn 和最新的schema 信息比较, 如果比较小, 那么说明这个page 是老大, 需要更新到最新的schema.  这个时候, 可以当独对page apply 最新版本的schema 信息. 返回给DML 操作.

   对于没有被DML 操作访问到的page 则在后台慢慢更新这些page

   这些page 被DML 操作更新以后, 如果发生SMO 操作了, 那该如何处理?

   TODO(baotiao), 必须小心处理

   同样, 对于replica 因为replica 不可能修改数据, 因此默认让replica 都访问最新版本数据, 当DML 操作带上对page 访问的版本号以后, 只要不发生SMO 操作, 都可以根据page 找到老版本的redo log 信息





这里涉及修改的地方比较多得是



1. 每一个record 标记自己属于哪一个版本的 dd

2. InnoDB 的record 是通过undo 来实现, 并不是pg 里面直接拷贝一份数据, 所以一个record 的多版本就需要在Undo 里面去做.

3. 建立二级索引这种需求, 如果一些record 一直没有被访问到, 那么数据一直是老版本的, 这个时候建立index 没有这个字段怎么处理

4. 还有对性能的影响怎么处理? 目前dd 信息都存在内存里面,  直接访问最新的就可以, 如果dd 版本过多, 那么是不是设计到IO 操作了



**server 层代码路径:**

```c++
#0  mysql_alter_table (thd=thd@entry=0x7fd72c000b50, new_db=0x7fd72c2e6380 "test", new_name=0x0, create_info=create_info@entry=0x7fe05afa2580,
    table_list=table_list@entry=0x7fd72c2e5dd8, alter_info=alter_info@entry=0x7fe05afa2680) at /disk1/git/PolarDB_80/sql/sql_table.cc:14187
#1  0x00000000010ba894 in Sql_cmd_alter_table::execute (this=<optimized out>, thd=0x7fd72c000b50) at /disk1/git/PolarDB_80/sql/sql_alter.cc:343
#2  0x0000000000cda7cb in mysql_execute_command (thd=thd@entry=0x7fd72c000b50, first_level=first_level@entry=true)
    at /disk1/git/PolarDB_80/sql/sql_parse.cc:4644
#3  0x0000000000cdca3f in mysql_parse (thd=thd@entry=0x7fd72c000b50, parser_state=parser_state@entry=0x7fe05afa4420,
    force_primary_storage_engine=force_primary_storage_engine@entry=false) at /disk1/git/PolarDB_80/sql/sql_parse.cc:5396
#4  0x0000000000cdfcf3 in dispatch_command (thd=thd@entry=0x7fd72c000b50, com_data=com_data@entry=0x7fe05afa4be0, command=COM_QUERY)
    at /disk1/git/PolarDB_80/sql/sql_parse.cc:1794
#5  0x0000000000ce084d in do_command (thd=thd@entry=0x7fd72c000b50) at /disk1/git/PolarDB_80/sql/sql_parse.cc:1288
#6  0x0000000000df5398 in handle_connection (arg=arg@entry=0x5330050) at /disk1/git/PolarDB_80/sql/conn_handler/connection_handler_per_thread.cc:316
#7  0x000000000213352f in pfs_spawn_thread (arg=0x5330110) at /disk1/git/PolarDB_80/storage/perfschema/pfs.cc:2836
#8  0x00007fe06fb82e25 in start_thread () from /lib64/libpthread.so.0
#9  0x00007fe06e172f1d in clone () from /lib64/libc.so.6
```

常见的sql 解析过程就是do_command=>dispatch_command=>mysql_parse=>mysql_execute_command, 然后这里解析到了 case SQLCOM_ALTER_TABLE:  就执行alter 相关代码, 带了sql_alter.cc 里面.

在 Sql_cmd_alter_table::execute 里面会执行最长的 mysql_alter_table 语句


