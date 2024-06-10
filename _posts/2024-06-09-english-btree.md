---

layout: post
title: Evolution of InnoDB B-Tree Latch Optimization
summary: Evolution of InnoDB B-Tree Latch Optimization

---

(In database terms, latch usually refers to a physical lock, while lock refers to a logical transaction lock. They are used interchangeably here.)

In InnoDB, the B-tree has two main types of locks: index lock and page lock.

- **Index lock** refers to the lock on the entire index, specifically `dict_index->lock` in the code.
- **Page lock** is a lock on each page within the B-tree, found in the page's variables.

When we mention B-tree lock, it generally includes both index and page locks.

### B-tree Latch in MySQL 5.6

In version 5.6, the B-tree latch process is straightforward:

1. **For a query request**:
   - The B-tree index is locked with an S LOCK.
   - The leaf node is locked with an S LOCK, and the index lock is released after finding the leaf node.
   
   ![Query Process](https://raw.githubusercontent.com/baotiao/bb/main/uPic/7AouKrR.png)

2. **For a leaf page modification request**:
   - The B-tree index is locked with an S LOCK.
   - After finding the leaf node, it is locked with an X LOCK for modification, and the index lock is released. If the modification triggers a B-tree structure change, a pessimistic insert operation is performed:
     - The entire B-tree index is locked with an X LOCK.
     - The `btr_cur_search_to_nth_level` function is executed to locate the specific page.
     - Since the leaf node modification can affect the entire path up to the root node, an X LOCK is necessary to prevent access by other threads, potentially causing IO operations and significant performance fluctuations.

   ![Modification Process](https://raw.githubusercontent.com/baotiao/bb/main/uPic/MZrRVA6.png)

In 5.6, only the entire B-tree index and the leaf node page have locks, while non-leaf nodes do not. This simple implementation has the downside of causing performance issues during Structure Modification Operations (SMOs), as read operations are blocked, especially when IO operations are involved.

### Improvements in MySQL 8.0

By version 8.0, significant changes were introduced, including:

1. **SX Lock**:
   - SX Lock allows access intent for modification without starting the modification immediately. It does not conflict with S LOCK but does with X LOCK and other SX LOCKs.
   - This lock was introduced via [WL#6363](https://dev.mysql.com/worklog/task/?id=6363).

2. **Non-Leaf Page Lock**:
   - Both leaf and non-leaf pages have page locks.
   - This allows for latch coupling, where child node locks are acquired before releasing parent node locks, minimizing the lock range.

#### Updated Processes in MySQL 8.0

1. **For a query request**:
   - The B-tree index is locked with an S LOCK.
   - All non-leaf node pages along the search path are locked with S LOCK.
   - The leaf node page is locked with an S LOCK, and the index lock is released.

   ![Query Process 8.0](https://raw.githubusercontent.com/baotiao/bb/main/uPic/AGN3ghS.png)

2. **For a leaf page modification request**:
   - The B-tree index is locked with an S LOCK, and non-leaf node pages are locked with S LOCK.
   - After finding the leaf node, it is locked with an X LOCK for modification, and the index lock is released. If modification triggers a structure change:
     - The index lock is changed to SX LOCK.
     - The pages in the search path are saved, and potential structural changes are handled with X LOCKs on affected pages.

   ![Modification Process 8.0](https://i.imgur.com/ye4VVpc.png)

During SMOs, SX LOCK allows for concurrent read operations and optimistic writes. However, only one SMO can occur at a time due to SX LOCK conflicts, leading to potential performance issues under heavy concurrent modifications.

### Optimization Points

1. **Index Lock Refinement**:
   - Consider eliminating the global index lock completely.
   
2. **Holding Index Locks**:
   - Explore reducing the duration of holding SX LOCK during the `btr_page_split_and_insert` process.

3. **Search Path Optimization**:
   - Retain the search path during `btr_cur_search_to_nth_level` to avoid repeated searches.

4. **Optimistic vs. Pessimistic Inserts**:
   - Reevaluate the necessity of both insert methods to reduce traversal overhead.

### Conclusion

In summary, MySQL 8.0 introduces significant improvements over 5.6 by allowing concurrent reads during SMOs and refining the lock mechanisms. However, further optimizations are needed to address the remaining limitations and enhance overall performance.

For more details, refer to:
- [Domas' Blog on InnoDB Index Lock](https://dom.as/2011/07/03/innodb-index-lock/)
- [MySQL Worklog Task WL#6363](https://dev.mysql.com/worklog/task/?id=6326)


