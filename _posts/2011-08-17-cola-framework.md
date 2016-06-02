---
date: 2011-08-17 07:10:42+00:00
layout: post
title: Cola.php的默认配置以及url分发
---

cola.php 是一个叫付超群写得框架,可能对比较大型的框架理解不清楚,可以先看这个比较小型的.
0.1版就包含了框架里面最主要的几个文件,那些扩张功能还不包括在里面,非常适合让我们理解如何实现一个mvc框架的过程.

这里是对 0.1版代码的阅读记录.

1. 在demo下面的index.php 是所有动态请求的入口,也是框架的入口.
2. 在index.php里面require了Cola.php 和 config.inc.php.
其中Cola.php是最主要的函数,在Cola.php里面的__construct函数里面定义的根目录,用spl_autoload_register 实现框架加载任意的类.
3. 其中具体的加载方法是在Cola.php下面的loadClass方法里面.
首先,有三个默认加载的方法
如果是Cola_Router 那么 就加载Cola 下的Router.php.
如果是Cola_View 那么就加载Cola 下的View.php.
如果是Cola_Controller 那么就加载Cola 下的Controller.php
如果不是上面上中情况,那么在建立一个新的类的时候,就是getInstance()的时候必须指定类名,以及目录.
那么loadClass也会找到相应的文件并包含他.
4.config.inc.php 就是包含的默认的配置文件.
$urls 是用于url 分发的时候,定义的规则,与$urls匹配以后再找到相应的文件来加载.
$dbConfig 包含的是db的一些信息.
index.php 会调用cola 的config 函数把规则保存在$_config 变量里面.
5. index.php 会调用dispatch() 函数,就是实现url 分发的主要方法.
首先.dispatch 函数会默认去获得DispatchInfo()的信息,如果没有那么就去setDispatchInfo().
然后,在setDispatchInfo()里面就会先获得Router的信息.那么Router会把config.inc.php里面包含的$urls的匹配信息保存进去.
然后.在setDispatchInfo()里面会调用setPathInfo函数,函数根据$_SERVER['PATH_INFO']来获得pathInfo.
之后会调用Router里面的match方法.改方法将config.inc.php里面定义的匹配规则一一与获得的pathInfo匹配,如果匹配成功就return出来.
其中如果$url里面包含里maps这个变量,那么就可以变量赋值,并且,如果maps里面包含的某些变量没有进行赋值,那么default则会给赋默认值.
当匹配成功后会得到file,class,action,以后如果有默认参数会有args 也就是变量的信息.
6.接下来在dispatch()函数里面回去找文件,并且包含他.接下来就是调用找到的class里面的action 并且调用call_user_func_array 来执行
这个方法.然后就跳到执行相应方法的controller里面了.

后面就是demo 下面的controller方法都是继承自Cola_Controller, model 都是继承自Cola_Model.

有新的再及时更新.
在google 的code 里面有最新更新  http://code.google.com/p/colaphp/ 还有代码获取 [Men's Health](http://cheaponlinegenericdrugs.com/products/provigrax.htm)
