---
layout: post
title: cpp reference and function
summary: cpp reference and function
---
在cpp 里面 

```c++
int *p;
int &r;
```

这里\*, \& 和实际使用到 \*p, &a 的时候是不一个意思的, 在定义变量类型的时候 \*, & 是没有任何意义的, 表示的只是这个一个指针类型, 和引用类型

函数前面的 \*, & 和变量声明的 \*, & 一个意思, 只是表示这个函数返回值的类型.

**函数的return val; 这里这个val 无论是 *val, &val 都不影响这个函数的声明, 这个是函数的使用者不需要关注的, 也可以理解, 因此这个return val 属于函数的实现里面, 不属于函数的声明**

在这里我们要知道 &(reference) 是cpp 新加入的一种类似, 和指针一样表示的是引用类型而同时& 也是用来做取地址操作, 因此容易混淆.

```c++
int a = 10;
int &r = a; // 这里& 是声明r 是一个引用类型
int *p = &a; // 这里& 是取地址操作
```



##### 传给函数的时候什么时候用 &, 什么时候用 * 呢?

1. 如果这个参数可以是NULL, 那么只能必须用 pointer, 否则就可以用&
2. 为了方便起见传入的参数用&, 可能被修改的用*

**reference 一旦订下来 就不能修改, 比如 int &b = a; 接下来就不能把这个b 又成为别人的引用, 因为引用的意思就是别名(an alternate name), 不能说b 既是a的别名, 也是c 的别名**

所以从这个角度来说 & 和 int* const p 是一样的(注意和const int *p 的区别, const int *p 表示的是这个int 是const, 所以是不能对这个这个int 进行修改, 但是p 可以指向其他地址. 而int * const p 是p 是一个const 指针, 指向一个非const 的int. 可以对这个 *p = new value的, 但是不能让 p = new address, 因为就和引用一样, 是不能又成为一个新的值的引用的.)

#### 常见的函数和reference 几个问题

1. 函数的定义前面加上 &

2. 函数的定义前面加上 *

   * 上面两个其实结果是一样的, 函数前面的 &, * 其实有点类似于变量的声明时候的&, * 的用途, 表示的都是没用任何意义. 只是声明这个函数的返回值是 reference 类型和指针类型. 在函数的返回 return val, 如果变成 return *val, return &val 都是没有任何影响的, 就好像外部对这个val 一无所知, 只有函数前面的 int &, int, int * 来描述这个return val 是什么意思一样. 所以 **重要** **重要** 函数前面的 *, & 和变量声明的 *, & 一个意思, 只是函数返回值的类型. 所以其实函数可以看成

     ```cpp
     int* fun() {
       .... // 中间这里是不用关注的
       return val; // 这里变成return *val, return &val 都没有任何的影响
     }
     这就类似于 int *val;
     
     那么要接这个val 就必须是
     int *p = fun(); // 因为这里 fun() 就是一个val. 而val 就是 int *类型.
     // 或者这里函数的定义 int *fun() 就告诉了这里是int * 类型的意思
     ```

   * 函数的返回结果如果是& 的时候,  接这个函数的返回结果的变量必须定义成reference 类型. 就跟如果函数返回前面 *, 接这个函数的返回结果的变量必须定义成pointer 类型一样.

3. 函数的返回结果是const(其实把函数的声明看成变量的声明就清晰了)

   1. 一般函数的返回是引用或者指针的时候才有必要加上const, 表示的是对这个返回结果的一个保护, 不能修改这个返回结果. 如果直接返回的是值则没有任何意义, 因为返回的是值的时候返回的都是一个拷贝, 因此是可以随意修改的. 其实返回的是值可以看成这种

      ```c++
      const int cb = 10;
      int c = cb;
      c = 20;
      
      // 因为函数的声明可以看出变量的声明, 因此上下两个是等价的, 下面这样也是没问题的
      int a = 10;
      const int fun() {
        return a;
      }
      int c = fun();
      c = 20;
      ```

      ​

   2. 这个结论对在类里面的函数和对类外面的函数都试用

      ```cpp
      #include <iostream>
      #include <stdio.h>
      
      class A {
       public:
        void set_rel(int val) {
          rel_ = val;
        }
      
        /*
         * 这里 relAddr1 和 relAddr 都是类似返回地址
         *
         * 这里 relAddr1 是c 里面的做法, 返回的是一个指针
         * 这个指针指向的是rel_ 的地址
         * 那么使用的时候就是
         * int *p = a->relAddr1();
         * *p = 30;
         * 那么这个时候a 里面的 rel_ 就会被修改
         *
         * relAddr 是c++ 里面的做法, 返回的是一个引用. 同样对返回的引用进行修改以后
         * 类里面的值也同样是有问题的
         *
         * 记住如果函数的返回类型是引用, 那么这个变量也必须是引用类型,
         * 才可以接到这个函数的引用
         * int &b = a->relAddr();
         * b = 30;
         * 那么这个时候a 里面的 rel_ 也同样被修改
         *
         */
      
      
        /*
         * 这里如果写成
         * const int *relAddr1() {
         *
         * 那么下面就不能用 int *p 对这个赋值
         * int *p = a->relAddr1(); // 也就是const 指针赋值给一个非const 指针的错误
         */
        int *relAddr1() {
          return &rel_;
        };
      
        /*
         * const int &relAddr() {
         * 这里如果给这个返回值加上const 以后, 那么下面的
         * int &b = a->relAddr();
         * b = 30; // 这里就是报错, 因为const 的意思是说这个返回值是无法修改的
         * 所以如果确实需要返回一个reference 的话, 也最好是返回一个const reference
         */
        int &relAddr() {
          return rel_;
        }
        const int rel() {
          return rel_;
        }
      
        int rel_;
      };
      
      /*
       * 这里const 对类外面的函数也同样适用, 所以如果需要返回的结果是& 或者* 的时候,
       * 最好对这个变量进行const 修饰, 表示不能给被修改
       */
      int ax = 10;
      const int& fun() {
        return ax;
      }
      
      int main()
      {
        A *a = new A();
      
        a->set_rel(10);
        printf("%d\n", a->rel());
      
        /*
         * 这里如果定义 const int &b, 那么接下来 b = 30 的时候就由于这个reference
         * 类型是const 所以不能赋值
         */
        int &b = a->relAddr();
        b = 30;
        printf("%d %d\n", b, a->rel());
      
        /*
         * 同样这里如果定义的是 const int *p, 那么接下来就不能操作*p = 40. 
         * 因为这个指针是const 类型的
         */
        int *p = a->relAddr1();
      
        *p = 40;
        printf("%d %d %d\n", *p, a->rel(), b);
      
        const int &xx = fun();
        // xx = 50;
      
        printf("%d %d\n", xx, ax);
        
        return 0;
      }
      ```



