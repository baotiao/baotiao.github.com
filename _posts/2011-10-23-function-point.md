---
layout: post
title: "函数指针和指针函数"
description: "function point"
category: tech
tags: [c]
---

    函数指针和指针函数区别. 指针函数. 返回值是指针的函数叫指针函数. 函数的返回值可以是int,char,double,struct,也可以是指针,指针函数就是返回值是指针的函数,也就是返回的是一个地址.比如: 

    char *cp(char *s, char *t) 
    { 
        t = s; return t; 
    }
    int main() 
    { 
        char s1[10] = "hello"; 
        char s2[10] = "world"; 
        printf("%s %sn", s1, s2); 
        printf("%sn",cp(s1,s2)); 
        return 0; 
    }

    这里返回值就是一个地址. 这里 char *cp(char *s, char *t)里面的第一个*我们可以看做是跟定义一个指针 char *p,里面的*是一个意思,就是只是表示这是一个指针而已.所以我们调用cp(s1,s2)返回的就是一个地址,printf("%s")的时候,传入的是一个地址或者字符串的名字.如果是一个 int *get(),那么获得返回值就是 printf("%dn",*get())就可以了.

    函数指针 指向函数的指针叫函数指针. 在C语言中，函数也是一种类型，可以定义指向函数的指针。我们知道，指针变量的内存单元存放一个地址值，而函数指针存放的就是函数的入口地址(位于.text段). 下面看一个简单的例子: 例 23.3. 函数指针 

    void say_hello(const char *str) 
    { 
        printf("Hello %sn", str); 
    } 
    int main(void) { 
        void (*f)(const char *) = say_hello; //注意这里*f必须加()否则就和上面说的函数指针混乱了. 
        f("Guys"); 
        return 0; 
    }


    分析一下变量f的类型声明void (*f)(const char *)，f首先跟*号结合在一起，因此是一个指针。(*f)外面是一个函数原型的格式，参数是const char *，返回值是void，所以f是指向这种函数的指针。而say_hello的参数是const char *，返回值是void，正好是这种函数，因此f可以指向say_hello。注意，say_hello是一种函数类型，而函数类型和数组类型类似，做右值使用时自动转换成函数指针类型，所以可以直接赋给f，当然也可以写成void (*f)(const char *) = &say_hello;，把函数say_hello先取地址再赋给f，就不需要自动类型转换了。
    可以直接通过函数指针调用函数，如上面的f("Guys")，也可以先用*f取出它所指的函数类型，再调用函数，即(*f)("Guys")。可以这么理解：函数调用运算符()要求操作数是函数指针，所以f("Guys")是最直接的写法，而say_hello("Guys")或(*f)("Guys")则是把函数类型自动转换成函数指针然后做函数调用。
    就是我们平常调用函数的时候也是先吧函数类型转换程函数指针,然后在做函数调用,有了函数指针直接把指针指向这一个函数在.text段的位置,就直接做函数调用了.函数指针可以指向所有这一类的函数.
