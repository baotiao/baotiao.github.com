# How to Create presentation with HTML5



!SLIDE middle

# How to Create presentation with HTML5

---

<img src="images/headache.jpg" width=350 />

##[Mingxing Lai](http://mingxinglai.com)

Dept. Of Computer Science XiaMen University, China

Nov 15, 2012



!SLIDE  bulleted

#Tips

* `<F11>` full screen
* `<ctrl>` + '+' zoom in
* `<ctrl>` + '-' zoom out

<img src="images/notice.jpg" align="center" />



!SLIDE bulleted

#Outline

* Introduction
* Install tools
* Writing markdown document
* Make
* Play
* Related articles



!SLIDE middle dark

# Why we create presentation with HTML5 ?

}}}images/welcome.jpg



!SLIDE middle dark

#Because you're not this guy

}}}images/steve-jobs.jpg



!SLIDE middle 

#You are this guy

<img src="images/github-logo.png" />



!SLIDE dark middle

# Let's go

Nothing here; move on!

}}} images/scattered-leaves.jpg



!SLIDE

#What's tool  we use ?

##Makrdown

Markdown is a text-to-HTML conversion tool for web writers. Markdown allows you to write using an easy-to-read, easy-to-write plain text format, then convert it to structurally valid XHTML (or HTML).

##Keydown = Markdown + deck.js

A single-page HTML presentation maker



!SLIDE

#Step 1 install keydown

---

##ruby 

```bash
    #fedora
    sudo yum install ruby-devel.i686
    #ubuntu
    sudo apt-get install ruby
```

##keydown

```bash
    sudo gem install keydown
    gem list --local
```



!SLIDE

#Step 2 generate files

---

```bash
    keydown generate my_presentation
```

<img src="images/generate.png" width=880 height=480 />



!SLIDE

#Step 3 write your presentation in markdown

---

```bash
    cd my_presentation
    vim slides.md
```

##Do you know markdown ?

There is some materials, you can master it in five minutes

* [markdown](http://wowubuntu.com/markdown/)



!SLIDE

#Step 4 Customize with CSS

---

Nothing here; move on!

<img src="images/skiing.jpg" width=880 height=480 />



!SLIDE

#Step 5 keydown slides

---

let's witness the miracle of the moment

```bash
    keydown slides slides.md
```

The command will generate some files include slides.html



!SLIDE

#Congratutations

```bash
    firefox slides.html
```

<img src="images/coffee.jpg"  width=880 height=480 />



!SLIDE middle dark

#very funny ?

}}} images/happy.jpg



!SLIDE  middle

#Video embeds

<embed src="http://player.youku.com/player.php/sid/XODkxNDY0ODQ=/v.swf" allowFullScreen="true" quality="high" width="720" height="600" align="middle" allowScriptAccess="always" type="application/x-shockwave-flash"></embed>



!SLIDE middle dark

#Present anywhere

##...you can launch a browser

}}} images/class-room.jpg



!SLIDE middle dark

#Present anywhere

##...you can launch a browser

}}} images/skiing2.jpg



!SLIDE middle dark

#Present anywhere

##...you can launch a browser

}}} images/desert.jpg



!SLIDE

# Thanks!

- <https://github.com/lalor>

}}} images/constructocat.jpg
