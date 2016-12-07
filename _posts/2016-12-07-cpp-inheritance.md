---
layout: post
title: cpp inheritance summary
summary: cpp inheritance 和 composition 一些总结
---


#### 关于inheritance 和 composition 对比

public inheritance 表示的是 is-a 的关系

所有能够用在base class 上面的东西应该都可以使用到 derive class上, 	因为所有的derive class 都是base class的一种

composition 有两个含义

1. 表示的是has-a 的关系
2. 表示由什么东西来实现

这里检查是否能够使用inheritance 的方法是. 是否所有客户端对base class 的操作都能够用到这个derive class 上, 并且不需要知道这个derive class 的具体实现细节. 

My suggestion is to enhance your "is a / has a" heuristic with the [Liskov Substitution Principle](http://www.objectmentor.com/resources/articles/lsp.pdf).
To check whether an inheritence relationship complies with the Liskov Substitution Principle, ask whether clients of a base class can operate on the sub class without knowing that it is operating on a sub class. Of course, all the properties of the sub class must be preserved.

有一个观点看来,  composition 的封装粒度要比 inheritance 来的更高,  因为 inheritance 需要知道更多基类的细节. 所以要判断需要使用composition 还是 inheritance 的时候, 先判断是否能够使用inheritance, 然后偏向于使用composition

#### 在类里面通常有3个类型的函数

1. pure virtual function
2. non-pure virtual function
3. non-virtual function

pure virtual function 表示的是只继承这个接口, 并没有提供默认的实现

常见的一个问题是有时候我们看到代码里面会有pure virtual function, 但是这个pure virtual function 又会有一个默认的实现, 为什么要这样写?

比如rocksdb DB::Put 是pure virtual, 在DBImpl 里面有DB::Put的实现逻辑, 然后DBImpl::Put 只是去调用了一下这个DB::Put 方法. 这样方便如果又有DBImpl2 继承自 DBImpl, 需要写Put 的时候, 直接调用DB类提供的默认方法就可以了

这里是希望的derive class 需要明确的去实现这个function, 而不是使用virtual function 那样有默认的实现方法. 但是又希望base class 给function 提供默认的实现的方法

non-pure virtual function 表示的是继承这个接口并且给出了默认的实现

non-virtual function 表示的是继承了这个接口并且强制了这个实现, 所以我们不应该在派生类里面去重新实现一个non-virtual function.

#### 其他

* 在继承的时候, 只要继承virtual 和 pure-virtual 函数, 如果你要继承 non-virtual 函数, 这说明你的设计有问题了
* 在继承一个参数有默认值的函数的时候, 不要去修改这个函数的默认值, 因为这个默认值的绑定是随着这个类, 而这个函数的绑定是随着这个对象的
