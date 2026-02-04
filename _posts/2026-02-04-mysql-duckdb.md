---

layout: post
title: 为什么我认为 MySQL 比 PostgreSQL 集成 DuckDB 更加的优雅?
summary: 为什么我认为 MySQL 比 PostgreSQL 集成 DuckDB 更加的优雅?
---


我们看到目前有 3 个主流 PostgreSQL 集成 DuckDB 的方案在运行 pg_duckdb,pg_mooncake, pg_lake.

pg_duckdb 是官方提供的 DuckDB 插件, 只能提供存量行存表到 DuckDB 的迁移, 无法让增量的数据同步到 DuckDB 表中, 适用场景比较受限.

databricks 收购的 pg_mooncake 可以支持存量和增量的数据同步, 通过额外的 pg_moonlink 进程以逻辑复制的方式把 PostgreSQL 的数据复制过来, 并且以 Iceberg 格式写入, 后续如果有复制查询, 需要走 postgresql => pg_moonlink => s3(Iceberg) 的请求方式.

snowflake 收购的 pg_lake 同样也不支持增量数据同步, 只支持全量的数据导入导出, 感觉更多是一个归档场景的方案.



我们可以看到有几个问题, 一个是 PostgreSQL 逻辑复制能力不够成熟, 远不及其原生的物理复制能力, 无法通过逻辑复制连接PostgreSQL和DuckDB只读实例.
另外一个问题是 PostgreSQL 没有支持很好的可插拔的存储引擎能力, 虽然 PostgreSQL 提供了 table access method 作为存储引擎接口, 但并没有提供主备复制, Crash Recovery等能力, 很多场景下无法保证数据一致性.



**在 MySQL 里面很好的解决了这个问题**

首先 MySQL 天然就是一个可插拔的存储引擎设计, 在早期 MySQL 的默认引擎还是 MyIsam, 后面由于 InnoDB 对行级别 MVCC 的支持, MySQL 才把默认的引擎转换成了 InnoDB 引擎. 在 MySQL 里面原先也有InfoBright 这样的列存方案, 但是没有流行起来. 所以在 MySQL 里面支持列存 DuckDB, 增加一个列存引擎是一个非常顺其自然的事情. 不需要像 PostgreSQL 一样, 需要将写入数据先写入到行存再转换成列存这样的解决方案.

另外是 MySQL 的 binlog 机制, MySQL 的双 log 机制有缺点也有优点, binlog/redo log 的存在肯定会对写入性能造成影响, 但是 binlog 对 MySQL 生态的上下游提供了非常好的支持, binlog 提供了完整的 SQL 语句非常方便复制给下游, 这也是为什么 MySQL 生态的 OLAP 应用这么流行的原因, 像 Clickhouse, starrocks, selectdb 等等.

MySQL 使用 DuckDB 作为存储引擎场景里面, MySQL 的 binlog 生态是完全兼容, 没有被破坏的. 所以它可以作为一个数仓节点, 写入到这个数仓节点的数据依然可以把 binlog 流转出来. 在作为 HTAP 的场景里面, 主节点 MySQL innodb 引擎发送 binlog 到下游的 MySQL DuckDB 引擎, 从而实现完全兼容的流转.



