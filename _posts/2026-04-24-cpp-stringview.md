---

layout: post
title: C++ StringView 优化字符串比较
summary: 参考 DuckDB string_t 的 StringView 设计, 在 columnar scan 随机访问场景下减少指针解引用

---

### C++ StringView 优化字符串比较

DuckDB / Velox / Umbra 里面常见的字符串表示方式. 和传统的 SimpleStr `(ptr, len)` 相比, 都是 16 字节, 但是 layout 不同.

```
SimpleStr:  [ ptr (8B) ][ len (4B) ][ pad (4B) ]

StringView:
  短字符串 (len ≤ 12): [ len (4B) ][ inline_data (12B)        ]
  长字符串 (len  > 12): [ len (4B) ][ prefix (4B) ][ ptr (8B) ]
```

两个优化点:

* 短字符串直接 inline 存在 struct 里, 比较的时候完全不需要 deref ptr.
* 长字符串把前 4 个字节的 prefix 存在 struct 里, 大部分不匹配的情况在 prefix check 阶段就拒掉了, 不需要访问 heap.

**随机访问场景下的优势**

在 column storage 里面, 字符串数据通常散布在 heap file 的各处. 字符串数据散布在 256MB buffer 里 (远超 L3 cache), 每次 deref 都是 DRAM miss (~100ns). 这个时候 inline 和 prefix 的价值就出来了.

N=1M 条字符串, 数据随机散布在 256MB buffer 里:

```
                     SimpleStr       StringView    Speedup
短字符串 (len=8)     14.74 ns/row    2.75 ns/row   5.36x
长字符串 (len=25)    15.88 ns/row    2.47 ns/row   6.42x
```

SimpleStr 散乱场景下每行 ~15ns 基本就是一次 DRAM round-trip. StringView 短字符串不访问 heap, 长字符串只有 ~5% 的行需要 deref (prefix 通过以后才去访问), 所以平均下来接近顺序访问的速度.

**C++ union 实现**

两个 member 都把 length 放在 offset 0, 所以读 `non_inline.length` 对两条路径都有效.

```cpp
struct StringView {
    union {
        struct { uint32_t length; char prefix[4]; const char* ptr; } non_inline;
        struct { uint32_t length; char data[12];                  } inlined;
    };
};

inline StringView make_view(const char* data, uint32_t len) {
    StringView v;
    if (len <= 12) {
        v.inlined.length = len;
        std::memset(v.inlined.data, 0, 12);
        std::memcpy(v.inlined.data, data, len);
    } else {
        v.non_inline.length = len;
        std::memcpy(v.non_inline.prefix, data, 4);
        v.non_inline.ptr = data;
    }
    return v;
}
```

Equality scan kernel:

```cpp
if (strs[i].non_inline.length != tlen) continue;
if (tlen <= 12) {
    if (memcmp(strs[i].inlined.data, target.inlined.data, tlen) == 0) matches++;
} else {
    uint32_t a, b;
    memcpy(&a, strs[i].non_inline.prefix, 4);
    memcpy(&b, target.non_inline.prefix,  4);
    if (a != b) continue;
    if (memcmp(strs[i].non_inline.ptr, target.non_inline.ptr, tlen) == 0) matches++;
}
```

**顺序访问场景下不一定有优势**

heap 是连续分配的时候, hardware prefetcher 能预测下一次 deref 的目标, 把 cache miss 的代价掩盖掉了. 顺序场景下 SimpleStr 反而比 StringView 略快一点.

N=10M 条字符串, 数据连续分配:

```
                     SimpleStr       StringView    Speedup
短字符串 (len=8)      3.51 ns/row     4.08 ns/row   0.86x
长字符串 (len=25)     3.14 ns/row     3.39 ns/row   0.93x
混合 50/50            5.56 ns/row     4.84 ns/row   1.22x
```

但在大多数 column storage 里面, string column 的数据散布在 heap file 里, 还是以随机分布的 column scan 居多, 所以 StringView 的优势是实际成立的.

**一个反直觉的现象**

仔细看两组数字会发现一件奇怪的事: StringView 在随机访问场景下 (2.75 ns/row) 比顺序场景下 (4.08 ns/row) 还要快. 照理说随机访问应该更慢才对.

原因是这两组 benchmark 用的 N 不同. 顺序测试用了 N=10M, struct 数组本身就有 10M × 16B = 160MB, 超过 L3 cache, 必须从 DRAM streaming 读. 随机测试为了让运行时间合理, 用的是 N=1M, struct 数组只有 16MB, warmup 跑完之后就常驻 L3 了.

对短字符串来说, StringView 完全不碰 heap, 所以"散乱"这件事对它毫无影响. 随机测试里 StringView 实际上在做的是: 顺序扫描一个 16MB 的热 L3 数组, 每行 in-struct 比较即结束. 这比顺序测试里 streaming 160MB DRAM 要快.

**编译**

```
g++ -O3 -std=c++17 -march=native t.cc -o demo
```

`-march=native` 让编译器为当前 CPU 启用全部指令集扩展 (AVX2, SSE4.2 等). memcmp 会被向量化. 生成的二进制不可移植.

完整代码见 [Gist](https://gist.github.com/baotiao/76c63ff8cc68ea6881ec423617cfdce0).
