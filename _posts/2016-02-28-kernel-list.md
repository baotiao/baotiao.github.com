---
layout: post
title: "kernel list"
description: "kernel list"
category: kernel, tech
tags: [kernel]
---

### 困惑点
之前看kernel list 的时候困惑的地方在于这个list里面居然没有指针指向这个list
对应的struct, 而是直接指向struct 里面的list 元素,
比如这样

```
struct my_cool_list{
  struct list_head list; /* kernel's list structure */
  int my_cool_data;
  void* my_cool_void;
};

```


那么怎么返回这个实际包含这个list 里面的元素的struct 的结构体呢?

答案: 其实最重要的一点就是有list_entry(ptr, type, member) 这个宏定义,
这个宏实现可以从一个struct 里面的一个元素, 然后返回这个struct 的地址,
这个是怎么做的呢?

其实也很好实现, 就是把struct 里面的偏移量拿来加减就可以了, 比如
struct node {
  int a;
  int b;
}

知道这个node.b 的地址, 那么很容易根据偏移量减去这个地址就可以了. 所以

```
#define list_entry(ptr, type, member) \
        ((type *)((char *)(ptr)-(unsigned long)(&((type *)0)->member)))
```
这里ptr 就是这个b 的地址, 然后type 就是这个node 这个结构体, member 就是这个b.

那么这里我们是怎么知道b 这个元素在这个结构体里面的偏移量呢?

Now the question is how can we compute the offset of an element in a structure? Suppose you have a data structure struct foo_bar and you want to find the offset of element boo in it, this is how you do it:
(unsigned long)(&((struct foo_bar *)0)->boo)

这样就可以了
这里的做法就是用foo_bar 结构体指针指向这个0这个地址, -> boo的操作其实就是增加这个偏移量, 然后获得这个元素的地址了

其他的地方就是普通的list 结构, 然后封装好了比较方便的操作了
![Imgur](http://i.imgur.com/513DxAK.jpg)

### kernel list 好在哪里呢?

我们平常自己实现的list 一般是这么实现的

```

struct my_list{
  void *myitem;
  struct my_list *next;
  struct my_list *prev;
};

```

这里我们想要获得下一个list元素, 一般有一个对应struct 类型的指针 *next;  
然后这个next 指针一般指向下一个my_list;

然而kernel 里面的list 是这么实现

```
struct my_cool_list{
  struct list_head list; /* kernel's list structure */
  int my_cool_data;
  void* my_cool_void;
};

```

这里可以看到相比较于我们自己实现的list, kernel list 的优点有

1. 直接把这个list_head 结构体放在一个struct 内部, 就可以让这个struct 实现一个list 结构, 不需要知道这个struct 的类型, 实现的非常的通用, 这里也可以在这个 把这个list 连接的不是这个my_cool_list 类型, 连接其他类型也是完全可以
2. 可以放多个list_head 结构, 这样这个结构体就可以连成多个list, 虽然原生的方法也可以, 不过这样看上去非常的简洁


这个是list 的具体使用方法,

```

#include <stdio.h>
#include <stdlib.h>

#include "list.h"

struct kool_list{
  int to;
  struct list_head list;
  int from;
};

int main(int argc, char **argv){

  struct kool_list *tmp;
  struct list_head *pos, *q;
  unsigned int i;

  struct kool_list mylist;
  INIT_LIST_HEAD(&mylist.list);
  /* or you could have declared this with the following macro
  * LIST_HEAD(mylist); which declares and initializes the list
   */

  /* adding elements to mylist */
  for(i=5; i!=0; --i){
    tmp= (struct kool_list *)malloc(sizeof(struct kool_list));

    /* INIT_LIST_HEAD(&tmp->list);
    *
    * this initializes a dynamically allocated list_head. we
    * you can omit this if subsequent call is add_list() or
    * anything along that line because the next, prev
    * fields get initialized in those functions.
     */
    printf("enter to and from:");
    scanf("%d %d", &tmp->to, &tmp->from);

    /* add the new item 'tmp' to the list of items in mylist */
    list_add(&(tmp->list), &(mylist.list));
    /* you can also use list_add_tail() which adds new items to
    * the tail end of the list
     */
  }
  printf("\n");

  /* now you have a circularly linked list of items of type struct kool_list.
  * now let us go through the items and print them out
   */

  /* list_for_each() is a macro for a for loop.
  * first parameter is used as the counter in for loop. in other words, inside the
  * loop it points to the current item's list_head.
  * second parameter is the pointer to the list. it is not manipulated by the macro.
   */
  printf("traversing the list using list_for_each()\n");
  list_for_each(pos, &mylist.list){

    /* at this point: pos->next points to the next item's 'list' variable and
    * pos->prev points to the previous item's 'list' variable. Here item is
    * of type struct kool_list. But we need to access the item itself not the
    * variable 'list' in the item! macro list_entry() does just that. See "How
    * does this work?" below for an explanation of how this is done.
     */
    tmp= list_entry(pos, struct kool_list, list);

    /* given a pointer to struct list_head, type of data structure it is part of,
    * and it's name (struct list_head's name in the data structure) it returns a
    * pointer to the data structure in which the pointer is part of.
    * For example, in the above line list_entry() will return a pointer to the
    * struct kool_list item it is embedded in!
     */

    printf("to= %d from= %d\n", tmp->to, tmp->from);

  }
  printf("\n");
  /* since this is a circularly linked list. you can traverse the list in reverse order
  * as well. all you need to do is replace 'list_for_each' with 'list_for_each_prev'
  * everything else remain the same!
  *
  * Also you can traverse the list using list_for_each_entry() to iterate over a given
  * type of entries. For example:
   */
  printf("traversing the list using list_for_each_entry()\n");
  list_for_each_entry(tmp, &mylist.list, list)
    printf("to= %d from= %d\n", tmp->to, tmp->from);
  printf("\n");

  /* now let's be good and free the kool_list items. since we will be removing items
  * off the list using list_del() we need to use a safer version of the list_for_each()
  * macro aptly named list_for_each_safe(). Note that you MUST use this macro if the loop
  * involves deletions of items (or moving items from one list to another).
   */
  printf("deleting the list using list_for_each_safe()\n");
  list_for_each_safe(pos, q, &mylist.list){
    tmp= list_entry(pos, struct kool_list, list);
    printf("freeing item to= %d from= %d\n", tmp->to, tmp->from);
    list_del(pos);
    free(tmp);
  }

  return 0;
}

```

