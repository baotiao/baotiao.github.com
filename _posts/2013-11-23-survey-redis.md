---
layout: post
title: "How redis implement data structure"
description: "about redis"
category: tech
tags: [survey]
---

1. redis implement the append command by realloc the space need by the function.

When we append the value. Redis first Makeroom for the result.  Redis control the memory by double the memory. The copy the chars to new space by memcpy.  
2. use copy-on-write technology to make as less copy as possible.  
3. **how redis implement list?**

redid really implement two kind of list. 

the first is the zip list, it is also the default list.  every time we have the value the size, we will transfer the zip list the the second link list. 

Why redis implement this way. Because We know link list is the as fast as zip list. At the beginning of time, we just need small space. So we can first encode the chars and store the value. Then if we need the value, what we need to do is just to decode the memory. So It is very quickly. As the data grow, the space is not big enough, and every time the decoding is also waste of time . 

So we need to modify the way we save data, we just put the data in link list, and we travel the list by the point.

