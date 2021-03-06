---
layout: post
title: Ternary Search Trees 三分树
---

经常碰到要存一堆的string, 这个时候可以用hash tables, 虽然hash tables 查找很快,但是hash tables不能表现出字符串之间的联系.可以用binary search tree, 但是查询速度不是很理想. 可以用trie, 不过trie会浪费很多空间(当然你也可以用二个数组实现也比较省空间). 所以这里Ternary Search trees 有trie的查询速度快的优点,以及binary search tree省空间的优点.

实现一个12个单词的查找




![](data:image/png;base64,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)

这个是用二分查找树实现,n是单词个数,len是长度,复杂度是O(logn * n),空间是n*len




![](data:image/png;base64,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)




这个是用trie实现,复杂度O(n), 空间是 这里是18 * 26(假设只有26个小写字符),随着单词长度的增长等,需要的空间就更多




![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAATsAAAC/CAYAAACBinu9AAAKMWlDQ1BJQ0MgUHJvZmlsZQAASImdlndUU9kWh8+9N71QkhCKlNBraFICSA29SJEuKjEJEErAkAAiNkRUcERRkaYIMijggKNDkbEiioUBUbHrBBlE1HFwFBuWSWStGd+8ee/Nm98f935rn73P3Wfvfda6AJD8gwXCTFgJgAyhWBTh58WIjYtnYAcBDPAAA2wA4HCzs0IW+EYCmQJ82IxsmRP4F726DiD5+yrTP4zBAP+flLlZIjEAUJiM5/L42VwZF8k4PVecJbdPyZi2NE3OMErOIlmCMlaTc/IsW3z2mWUPOfMyhDwZy3PO4mXw5Nwn4405Er6MkWAZF+cI+LkyviZjg3RJhkDGb+SxGXxONgAoktwu5nNTZGwtY5IoMoIt43kA4EjJX/DSL1jMzxPLD8XOzFouEiSniBkmXFOGjZMTi+HPz03ni8XMMA43jSPiMdiZGVkc4XIAZs/8WRR5bRmyIjvYODk4MG0tbb4o1H9d/JuS93aWXoR/7hlEH/jD9ld+mQ0AsKZltdn6h21pFQBd6wFQu/2HzWAvAIqyvnUOfXEeunxeUsTiLGcrq9zcXEsBn2spL+jv+p8Of0NffM9Svt3v5WF485M4knQxQ143bmZ6pkTEyM7icPkM5p+H+B8H/nUeFhH8JL6IL5RFRMumTCBMlrVbyBOIBZlChkD4n5r4D8P+pNm5lona+BHQllgCpSEaQH4eACgqESAJe2Qr0O99C8ZHA/nNi9GZmJ37z4L+fVe4TP7IFiR/jmNHRDK4ElHO7Jr8WgI0IABFQAPqQBvoAxPABLbAEbgAD+ADAkEoiARxYDHgghSQAUQgFxSAtaAYlIKtYCeoBnWgETSDNnAYdIFj4DQ4By6By2AE3AFSMA6egCnwCsxAEISFyBAVUod0IEPIHLKFWJAb5AMFQxFQHJQIJUNCSAIVQOugUqgcqobqoWboW+godBq6AA1Dt6BRaBL6FXoHIzAJpsFasBFsBbNgTzgIjoQXwcnwMjgfLoK3wJVwA3wQ7oRPw5fgEVgKP4GnEYAQETqiizARFsJGQpF4JAkRIauQEqQCaUDakB6kH7mKSJGnyFsUBkVFMVBMlAvKHxWF4qKWoVahNqOqUQdQnag+1FXUKGoK9RFNRmuizdHO6AB0LDoZnYsuRlegm9Ad6LPoEfQ4+hUGg6FjjDGOGH9MHCYVswKzGbMb0445hRnGjGGmsVisOtYc64oNxXKwYmwxtgp7EHsSewU7jn2DI+J0cLY4X1w8TogrxFXgWnAncFdwE7gZvBLeEO+MD8Xz8MvxZfhGfA9+CD+OnyEoE4wJroRIQiphLaGS0EY4S7hLeEEkEvWITsRwooC4hlhJPEQ8TxwlviVRSGYkNimBJCFtIe0nnSLdIr0gk8lGZA9yPFlM3kJuJp8h3ye/UaAqWCoEKPAUVivUKHQqXFF4pohXNFT0VFysmK9YoXhEcUjxqRJeyUiJrcRRWqVUo3RU6YbStDJV2UY5VDlDebNyi/IF5UcULMWI4kPhUYoo+yhnKGNUhKpPZVO51HXURupZ6jgNQzOmBdBSaaW0b2iDtCkVioqdSrRKnkqNynEVKR2hG9ED6On0Mvph+nX6O1UtVU9Vvuom1TbVK6qv1eaoeajx1UrU2tVG1N6pM9R91NPUt6l3qd/TQGmYaYRr5Grs0Tir8XQObY7LHO6ckjmH59zWhDXNNCM0V2ju0xzQnNbS1vLTytKq0jqj9VSbru2hnaq9Q/uE9qQOVcdNR6CzQ+ekzmOGCsOTkc6oZPQxpnQ1df11Jbr1uoO6M3rGelF6hXrtevf0Cfos/ST9Hfq9+lMGOgYhBgUGrQa3DfGGLMMUw12G/YavjYyNYow2GHUZPTJWMw4wzjduNb5rQjZxN1lm0mByzRRjyjJNM91tetkMNrM3SzGrMRsyh80dzAXmu82HLdAWThZCiwaLG0wS05OZw2xljlrSLYMtCy27LJ9ZGVjFW22z6rf6aG1vnW7daH3HhmITaFNo02Pzq62ZLde2xvbaXPJc37mr53bPfW5nbse322N3055qH2K/wb7X/oODo4PIoc1h0tHAMdGx1vEGi8YKY21mnXdCO3k5rXY65vTW2cFZ7HzY+RcXpkuaS4vLo3nG8/jzGueNueq5clzrXaVuDLdEt71uUnddd457g/sDD30PnkeTx4SnqWeq50HPZ17WXiKvDq/XbGf2SvYpb8Tbz7vEe9CH4hPlU+1z31fPN9m31XfKz95vhd8pf7R/kP82/xsBWgHcgOaAqUDHwJWBfUGkoAVB1UEPgs2CRcE9IXBIYMj2kLvzDecL53eFgtCA0O2h98KMw5aFfR+OCQ8Lrwl/GGETURDRv4C6YMmClgWvIr0iyyLvRJlESaJ6oxWjE6Kbo1/HeMeUx0hjrWJXxl6K04gTxHXHY+Oj45vipxf6LNy5cDzBPqE44foi40V5iy4s1licvvj4EsUlnCVHEtGJMYktie85oZwGzvTSgKW1S6e4bO4u7hOeB28Hb5Lvyi/nTyS5JpUnPUp2Td6ePJninlKR8lTAFlQLnqf6p9alvk4LTduf9ik9Jr09A5eRmHFUSBGmCfsytTPzMoezzLOKs6TLnJftXDYlChI1ZUPZi7K7xTTZz9SAxESyXjKa45ZTk/MmNzr3SJ5ynjBvYLnZ8k3LJ/J9879egVrBXdFboFuwtmB0pefK+lXQqqWrelfrry5aPb7Gb82BtYS1aWt/KLQuLC98uS5mXU+RVtGaorH1futbixWKRcU3NrhsqNuI2ijYOLhp7qaqTR9LeCUXS61LK0rfb+ZuvviVzVeVX33akrRlsMyhbM9WzFbh1uvb3LcdKFcuzy8f2x6yvXMHY0fJjpc7l+y8UGFXUbeLsEuyS1oZXNldZVC1tep9dUr1SI1XTXutZu2m2te7ebuv7PHY01anVVda926vYO/Ner/6zgajhop9mH05+x42Rjf2f836urlJo6m06cN+4X7pgYgDfc2Ozc0tmi1lrXCrpHXyYMLBy994f9Pdxmyrb6e3lx4ChySHHn+b+O31w0GHe4+wjrR9Z/hdbQe1o6QT6lzeOdWV0iXtjusePhp4tLfHpafje8vv9x/TPVZzXOV42QnCiaITn07mn5w+lXXq6enk02O9S3rvnIk9c60vvG/wbNDZ8+d8z53p9+w/ed71/LELzheOXmRd7LrkcKlzwH6g4wf7HzoGHQY7hxyHui87Xe4Znjd84or7ldNXva+euxZw7dLI/JHh61HXb95IuCG9ybv56Fb6ree3c27P3FlzF3235J7SvYr7mvcbfjT9sV3qID0+6j068GDBgztj3LEnP2X/9H686CH5YcWEzkTzI9tHxyZ9Jy8/Xvh4/EnWk5mnxT8r/1z7zOTZd794/DIwFTs1/lz0/NOvm1+ov9j/0u5l73TY9P1XGa9mXpe8UX9z4C3rbf+7mHcTM7nvse8rP5h+6PkY9PHup4xPn34D94Tz++xtAWsAAAlUSURBVHic7d3bcqS4EgVQPDH//8t1HvoQzWDKhkKJUsq1njo6bChEstEFyl+v1+u1AEzun94fAOAJwg4oQdgBJQg7oARhB5Qg7IAShB1QgrADShB2QAnCjuF9fX31/ggMQNgxPG88coawA0oQdgzPMJYzhB1QgrADShB2QAnCDihB2AElCDugBGEHlCDsmJbn79j6t/cHgN/sQ2v/ethPr4t9fX15nYxlWYQdCf0Wbmetv7duT+jVJuxIYRtwrUNJ6LEswo5OWvXerhB6tQk7HhPZe7tC6NUk7AjTo/d2hdCrRdjRVK/e251VV6FXg7Djluy9tyuE3tyEHZdlmXuLIvTmJOz41Uy9tyuE3lyEHYdm771dIfTmIOxYlqVu7+0KoTc2YVeY3ttnhN6Yvl7OVBl6bzGE3hj07Can9xZPT28Mwm4yem/9CL3chN3ghNsfmb63TujlJOwGZGg6BqGXi7AbgN7b2IReDsIuKb23+Qi9voRdEnpvdQi9PoRdR3pvtQm9Z3mo+EF6b/xE6MXSswum98ZZenqxhF0gRcsnhF4Mw9gTMj2wSj1Cr41/en8A4Gev1+tbb4/rhB0MRO/uc+bsLrDYkJNV7u/U6nfC7qT9vJ15vByOzkP1c6NWjxnGnrQvltfrZf6EdI6CTa3+IewY2tGFrBfDEcNYhrcPPGHHET07prB9PAOOCDuGdjSENT/FEWF30v4CssJFRkdhr1b/MGd34Oj1nJ/mhRRTPxYovjOHecy7sRufvoPo3UXIzzD2/9be2SeBtf6euSJGUbFWyw9jW/bKtoGnlwe5lB7GRs61Cb142/Onva+r1mYlw+7Jk2zxIoZ3Ytup0m7l5uzuzM2tv3/FOrStOEcS5d3Fad70ryvtUKVGy4TdejJ73MEsYLTz2znUzp+pUKPTh9025Hp31avcQaOcvVnNftFGmrntpg67LCG3VeEOGuFqr1wbf27Wm/KUYddzyHrWrAUV4dNzKfA+N+NNebrn7LKH3JbHJn5393yuF6y2/cxMz45O8+jJDCfERflfLdtD2943ehtOEXajn4StGUK7hYhzOlOd9DJyGw4ddjMHw8hFdVf0my1V27WVUa+7IcOuZ2M/ebGMWlR3PNG+FQJPO3433GpsxsdJosy4IvaTpy6eSm0aabQnCoYJuxEeJ4kyWlF94ulzK/DaGOmGPETYVerNvbMtqhEK64qer/HN1pa9jNCWqcOucm/unZHupGf0Pr8ztWVv2W/GaR8q7n0RZDfDw55ZzrEHj9vJ/KB8utXYjI2U3YgXasbPnPEz0U6asBNy94zUfplDJfNn454UYafA2sneltk/37KM8Rm5rusChQWI9jJPEmf8TEcsWsypa89O0MUaaWgL0VIMYwGipX7OjhiGaFQk7OAEN4h7MrSfsANKCHuDYp/kM0wNbo9ptuNZlrhjWheiRq2J9XOPsKCWsa2ztF/IAsXRQfU+0Lv2n3/k43m3Sht1TE/vL8IonzVrW/fe/7IYxp5ydKJGfxbr6cLrXeiVaOtjIWF3dFcB6OmRObvRe0HLIrBhdCFhl2F83tpsxwPVmLO7QW8PxvFI2I0eCkfD8Bl7rzCzkGHsPhy23146akDMMO/I53yb8T0Z2s8XAQAlmLMDShB2QAnC7ibzeDCG8LATBnk5N3N5dz4znOcMn0HP7iartGTQe6VzBMKuAYFHT78Fnfr8Q9g1oqDo4WyPTn0Ku6YUFE+6OnStXp/CrrHqBcUzPp2jq1yf3qAIYsKYKC1qq2J96tkFqXwHJU6rkKpYn8IuUMWCIk7r3li1+vRQcbDMBZX1c/Fd1LDzqfrMUGt6dg/IHHjkFz2/VqU+hd1DqhQUbT21kFChPoXdgyoUFO08vWI6e30Ku4fNXlC00evRkJnrU9h1MHNBcV/vZ+BmrU9h18msBcU9vYNuNWN9eoOisyzFTX8ZayHjZ/qUnl1nM95BuS5rqMxUn8IugZkKiuuyBt1qlvoUdkmsBTVDUXFe9qBbzRB4wi6R1+s1ROFzTea/DXHF6DdkCxQQaJSeWwV6dkAJ/0ZufN/ddYd7b22rfRu9+/+W+4zafnVr+87Su1uP42pNZqmzsLA7OsGznPQIP00ARwXddrvOTXvrOZ2pXa8eT6Y6M4wt6KjgZlhtI96doFt/v1edhYXd0UHNdIeLsG+z2XoF0FPonN3+4nXh5qEXRzWhYbcsfwPOxZWLGw/VhA1jj4awAu932wc3nw4k54eZWaAo6OjGY36Q1rLVWdgw1gLFPdFtpafNEzLN23tdLCG9LGjPMBYoIXw19kjkK1Aj0y4Qp9sw1oUNPKnbMHb97jaT5MATus/Zjf6FgMAYuszZ7e3fsjC0BVrr3rPbMrQFoqQKu5WhLdBayrBblv/28j4JPUEJbKUNu5WhLdBC+rBbXenlbb/7H2BZBn039syqrfdLga1henZbhrbAVUOG3cqqLXBWioeK7zBUBc4YumcHcJawA0oQdkAJ04ad1Vpga9qwWxaLF8BfU4cdwErYASUIO6AEYQeUIOyAEoQdUIKwA0oQdkAJwg4oQdgBJQi7A0++U/vEvkY/nlG2mWFfvFci7BTbcyLeR35im1E1Uv1voWS69kqEHUDY17LvE/3o7nbmZ+7uZ/tnFa9uf7vtd7975mc+3de7v6J25q+r/baPd79/93i27bz+++55Pjp3LbcZVSN3tntm2y3a9up+rmz/3fG3umauCgm7d8W5P+DffqbFftYTdfcC+/SY7uzrp+/kaxUYP33+FkOwFuc5eptRNfLpds9s+8r/ReznjKPjj6ixswxj39ifgH3wHJ2kT78wtNV2ruxjr+XxXNnvqKLa68q2I25EEfu5ur8oIWF3ZvK3RaM+Ncnc05mQrSbygmRej8zZvUvv/f+3mG/wSMHnRjqeFrVDLY/N2b2znySO2k+E2S6w0Y7nTu1QT7c5u6NhyAxFG3EMa9v0CPeM52TW2iHWI2H3VCG23M9+W+9W2n76mVb7ekLL46kgsr2eOhdPn/PeNRYyjH03n7I9sFYLFL/tZ/tzV7Z/Zk6oVY/i7PxTdFGM0kOKWKCIqpG7nydi20/uZ9+uPedav15u3UPQy4J7PGcHlBD26AltfPKaDvCdsEtOyEEbhrFACcIOKEHYASUIO6AEYQeUIOyAEoQdUIKwA0oQdkAJwg4oQdgBJfwPfj0ubXXvGykAAAAASUVORK5CYII=)




这个是Ternary search tree, 可以看出空间复杂度和binary search tree 一样, 复杂度近似O(n),常数上会比trie差点.







# 介绍


Ternary search tree 有binary search tree 省空间和trie 查询快的优点.
Ternary search tree 有三个只节点,在查找的时候,比较当前字符,如果查找的字符比较小,那么就跳到左节点.如果查找的字符比较大,那么就跳转到友节点.如果这个字符正好相等,那么就走向中间节点.这个时候比较下一个字符.
比如上面的例子,要查找"ax", 先比较"a" 和 "i", "a" < "i",跳转到"i"的左节点, 比较 "a" < "b", 跳转到"b"的左节点, "a" = "a", 跳转到 "a"的中间节点,并且比较下一个字符"x". "x" > "s" , 跳转到"s" 的右节点, 比较 "x" > "t" 发现"t" 没有右节点了.找出结果,不存在"ax"这个字符


# 构造方法


这里用c语言来实现
节点定义:

```c
typedef struct tnode *Tptr;
typedef struct tnode {
  char s;
  Tptr lokid, eqkid, hikid;
} Tnode;
```

先介绍查找的方法:

```c
int search(char *s) // s是想要查找的字符串
{
    Tptr p;
    p = t; //t 是已经构造好的Ternary search tree 的root 节点.
    while (p) {
        if (*s < p->s) { // 如果*s 比 p->s 小, 那么节点跳到p->lokid
            p = p->lokid;
        } else if (*s > p->s) {
            p = p->hikid;
        } else {
            if (*(s) == '\0') { //当*s 是'\0'时候,则查找成功
                return 1;
            } //如果*s == p->s,走向中间节点,并且s++
            s++;
            p = p->eqkid;
        }
    }
    return 0;
}
```

插入某一个字符串:

```c
Tptr insert(Tptr p, char *s)
{
  if (p == NULL) {
    p = (Tptr)malloc(sizeof(Tnode));
    p->s = *s;
    p->lokid = p->eqkid = p->hikid = NULL;
  }
  if (*s < p->s) {
    p->lokid = insert(p->lokid, s);
  } else if (*s > p->s) {
    p->hikid = insert(p->hikid, s);
  } else {
    if (*s != '\0') {
      p->eqkid = insert(p->eqkid, ++s);
    } else {
      p->eqkid = (Tptr) insertstr; //insertstr 是要插入的字符串,方便遍历所有字符串等操作
    }
  }
  return p;
}
```

同binary search tree 一样,插入的顺序也是讲究的,binary search tree 在最坏情况下顺序插入字符串会退化成一个链表.不过Ternary search Tree 最坏情况会比 binary search tree 好很多.

肯定得有一个遍历某一个树的操作

```c
//这里以字典序输出所有的字符串
void traverse(Tptr p) //这里遍历某一个节点以下的所有节点,如果是非根节点,则是有同一个前缀的字符串
{ 
  if (!p) return; 
  traverse(p->lokid); 
  if (p->s != '\0') { 
    traverse(p->eqkid); 
  } else { 
    printf("%s\n", (char *)p->eqkid); 
  } 
  traverse(p->hikid); 
}  
```

#应用 


这里先介绍两个应用,一个是模糊查询,一个是找出包含公共前缀的字符串, 一个是相邻查询(哈密顿距离小于某个范围)
模糊查询
psearch("root", ".a.a.a") 应该能匹配出baxaca, cadakd 等字符串

```c
void psearch1(Tptr p, char *s)
{
  if (p == NULL) {
    return ;
  }
  if (*s == '.' || *s < p->s) { //如果*s 是'.' 或者 *s < p->s 就查找左子树
    psearch1(p->lokid, s); 
  }
  if (*s == '.' || *s > p->s) { //同上
    psearch1(p->hikid, s); 
  }
  if (*s == '.' || *s == p->s) { // *s = '.' 或者 *s == p->s 则去查找下一个字符
    if (*s && p->s && p->eqkid != NULL) { 
      psearch1(p->eqkid, s + 1);
    }
  }
  if (*s == '\0' && p->s == '\0') {
    printf("%s\n", (char *) p->eqkid);
  }
}
```

解决在哈密顿距离内的匹配问题,比如hobby和dobbd,hocbe的哈密顿距离都是2

```c
void nearsearch(Tptr p, char *s, int d) //s 是要查找的字符串, d是哈密顿距离
{
  if (p == NULL || d < 0)
    return ;
  if (d > 0 || *s < p->s) {
    nearsearch(p->lokid, s, d);
  }
  if (d > 0 || *s > p->s) {
    nearsearch(p->hikid, s, d);
  }
  if (p->s == '\0') {
    if ((int)strlen(s) <= d) {
      printf("%s\n", (char *) p->eqkid);
    }
  } else {
    nearsearch(p->eqkid, *s ? s + 1 : s, (*s == p->s) ? d : d - 1);
  }   
}
```

搜索引擎输入bin, 然后相应的找出所有以bin开头的前缀匹配这样类似的结果.比如bing,binha,binb 就是找出所有前缀匹配的结果.

```
void presearch(Tptr p, char *s) //s 是想要找的前缀
{
  if (p == NULL)
    return;
  if (*s < p->s) {
    presearch(p->lokid, s);
  } else if (*s > p->s) {
    presearch(p->hikid, s);
  } else {
    if (*(s + 1) == '\0') {
      traverse(p->eqkid); // 遍历这个节点,也就是找出包含这个节点的所有字符
      return ;
    } else {
      presearch(p->eqkid, s + 1);
    }
  }
}
```

# 总结


1. Ternary search tree 效率高而且容易实现
2. Ternary search tree 大体上效率比hash来的快,因为当数据量大的时候hash出现碰撞的几率也会大,而Ternary search tree 是指数增长
3. Ternary search tree 增长和收缩很方便,而 hash改变大小的话则需要拷贝内存重新hash等操作
4. Ternary search tree 支持模糊匹配,哈密顿距离查找,前缀查找等操作
5. Ternary search tree 支持许多其他操作,比如字典序输出所有字符串等,trie也能做,不过很费时.

**参考**:http://drdobbs.com/database/184410528?pgno=1
