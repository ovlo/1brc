# 1BRC 挑战 · Windows 移植与优化记录

本仓库用 V 语言实现 [1 Billion Row Challenge](https://github.com/gunnarmorling/1brc)（1BRC）：
在单进程中解析一个“城市;温度”格式的大文件，对每个城市输出
最小/平均/最大温度。本文件记录三件事：**数据生成**、**Windows 移植的优化过程**、
以及**为什么 Windows 仍比 Linux 慢 2.4 倍的原因分析**。

相关文档：`readme.md`（Linux 版 `v1brc.v` 为何快的 7 点分析）、
`readme-gen.md`（数据生成器详解）。

---

## 1. 数据生成

测试数据为 `1brc.txt`：**约 1.5 GB、1 亿行（100M）**，由生成器 `vgen` 产生。

```bash
v -prod -o vgen.exe vgen.v
vgen.exe 100000000 -i cities.txt -o 1brc.txt -t 0    # -t 0 = 自动按 CPU 核数
```

- 城市名来自 `cities.txt`（每行一个，共 366 行，其中 `Kingston` 重复一次，
  实际 365 个不重复城市）。
- 温度由 `xorshift64` 伪随机 + Box-Muller 正态分布 `N(0, 25)` 采样，裁剪到
  `[-99.9, 99.9]`，保留一位小数（`25.8` 形式）。
- 因城市无气候均值数据，所有城市温度同分布，故每个城市的极值都会触及
  `±99.9`、均值趋近于 0 —— 这也使得输出可用于**正确性自检**（行数应等于总样本数，
  城市数应等于不重复城市数）。

更完整的生成器说明见 `readme-gen.md`。

---

## 2. 构建与运行

### Linux 参考实现 `v1brc.v`（仅参考，不可在 Windows 编译）

```bash
v -prod -cc gcc -skip-unused -no-bounds-checking -cflags "-std=c17 -march=native -mtune=native" .
./v1brc 1brc.txt [-n threads]
```
本机（WSL / 24 核）成绩：**100M 行 140–150 ms（24 线程）**，1B 行 ~1.6 s。

### Windows 移植 `v1brc_win.c.v`（完全重写，单文件）

用 Win32 `CreateFileA` / `CreateFileMappingA` / `MapViewOfFile` 替换 POSIX `mmap`，
用 `QueryPerformanceCounter` 计时，算法与 Linux 版一致。

```bash
v -prod -cc gcc -skip-unused -no-bounds-checking -cflags "-std=gnu17 -march=native -mtune=native" -o v1brc_win.exe v1brc_win.c.v
v1brc_win.exe 1brc.txt [-n threads]
```
> 必须用 `-std=gnu17` 而非 `c17`：AVX2 扫描是以 GCC 语句表达式（`({...})`）
> 宏实现的，属于 GNU 扩展。

本机（Windows / 24 核）成绩：**100M 行热态最佳 ~0.36 s（`-n 13`）**，
默认 `nr_cpus()`（24 线程）~0.40 s。

---

## 3. 算法核心（Linux / Windows 完全一致）

1. **整数温度**：温度存 `i32`（25.8 → 258，×10），全链路整数、零浮点解析。
2. **内存映射 + 多线程**：把文件 `mmap` 后按 `\n` 切成 N 段，每段一个线程
   `spawn` 独立解析，无锁聚合，最后合并。
3. **开放寻址哈希表**：预分配 `[]CityHashEntry`（`hash_cap = 1<<12`）+ 线性探测，
   零堆分配、缓存友好；每线程一张表，结束再合并。
4. **SIMD 扫描**：`avx2_delim_mask` 宏一次 AVX2 扫描整段，位掩码同时定位
   `;`（59）和 `\n`（10），再按位遍历分隔符；分块边界仍用 `avx2_memchr` 找 `\n`。
5. **FNV 哈希**：`hash_bytes` 对长度 ≥8 的城市名一次读 `u64` 计算。
6. **关键编译旗**：`-no-bounds-checking` 关闭数组越界检查、`-march=native` 启用
   AVX2/`POPCNT` 等 —— 二者是最大的性能杠杆，缺一不可。

---

## 4. Windows 移植优化过程

初始移植（纯 Win32 替换，算法照搬）即得到 **~0.42 s（默认 24 线程）**。
随后逐一尝试以下优化，全部以 100M 行热态、`-n 13` 为基准测量：

| # | 尝试 | 结果 | 结论 |
|---|------|------|------|
| 1 | 用内联 AVX2 字节扫描替换 MSVCRT `memchr` | 无变化（~0.43 s → ~0.42 s） | 扫描**不是**瓶颈 |
| 2 | 把每行调用的 `C.memcmp` 换成内联 `u64` 分块比较（存名尾部为 0，可精确比较 `len` 字节） | **~6% 提升**（0.42 → 0.37 s @n12；~0.36 s @n13） | **唯一有效增益** |
| 3 | `hash_bytes` 短城市名改 4 字节分块 | 噪声级 | 无效 |
| 4 | 重写为整段 SIMD 多分隔符扫描（`;`+`\n` 位掩码） | 无变化（~0.365 s），但代码更干净、已被采纳 | 扫描非瓶颈 |
| 5 | 每线程城市名缓存（按前 3 字节直接映射，跳过哈希+探测） | **变慢**（~0.395 s） | 本数据为均匀分布，**无时间局部性**，索引读取反而增加内存流量 |
| 6 | `PrefetchVirtualMemory`（Windows 版 `MAP_POPULATE`） | 变慢（~0.51 s） | 热数据已驻留内存，预填页表纯属浪费 |
| 7 | `-O3 -flto` | 无变化（~0.364 s） | 编译器对该热循环已最优 |

**最终成绩：~0.36 s（`-n 13`），默认 24 线程 ~0.40 s。**
正确性自检验证：总行数 = 100,000,000（精确），不重复城市 = 365（与 `cities.txt`
去重后一致）。

关键经验：**第 2 步的内联比较是唯一的真实增益**；第 1/4/5/6/7 步都“听起来该快”，
实测却无益甚至更慢 —— 因为瓶颈根本不在扫描或内存，而在每行的哈希与比较。

---

## 5. 原因分析：为何 Windows 比 Linux 慢 2.4 倍

同样的算法、同样的编译旗标（`-march=native`、`-no-bounds-checking`）、
同样的 1.5 GB 数据，Windows 为 **~0.36 s**，Linux 为 **~0.15 s**（100M 行），
差距约 **2.4 倍**。逐条排查后结论如下。

### 5.1 瓶颈定位：每行哈希计算，而非 I/O 或扫描

- **扫描不是瓶颈**：把 MSVCRT `memchr` 换成内联 AVX2、再改写成整段多分隔符 SIMD
  扫描，时间几乎不变 → 扫描早已够快。
- **内存不是瓶颈**：1.5 GB / 0.36 s ≈ 4.2 GB/s 聚合带宽，单线程仅 ~230 MB/s，
  远低于内存带宽，说明是**每字节的计算成本**主导，而非访存。
- **线程不是瓶颈**：`-n 1` → 2.54 s，`-n 13` → 0.36 s，近乎线性扩展。
- 因此热点是 `find_or_insert` 里**每行的 `hash_bytes` + 哈希表探测 + 城市名比较**，
  这是算法固有的 per-row 成本，与具体平台无关。

### 5.2 差距来自 OS / 微架构层，而非算法

既然算法与旗标一致，2.4 倍差异只能落在操作系统与微架构上：

- **页表 / TLB**：Linux 用 `mmap` + `MAP_POPULATE`（建映射时即把全部页表项填好）
  + `madvise(MADV_SEQUENTIAL)`（告知内核顺序访问、激进预读）。遍历 1.5 GB / 4 KB
  ≈ 37.5 万页，Linux 在映射期就铺好页表、并借内核预读让消费者不 stall。
  Windows 的 `MapViewOfFile` + `FILE_FLAG_SEQUENTIAL_SCAN` 达不到同等的页表/TLB
  布局与预读强度，1.5 GB 工作集远超 L3 缓存，随机线程访存会引入更多 TLB miss
  与页行走开销。
- **预取 / 调度**：`PrefetchVirtualMemory` 实测反而更慢，说明热数据已驻留，
  真正的代价是“驻留页的页表/TLB 形态”，不是“是否读进内存”。

### 5.3 线程数为何 13 优于 24

在 1 亿行这个规模下，更多线程不会加快单段解析（已是计算瓶颈），
反而增加合并阶段与调度开销；`n=13` 时总开销最小。`runtime.nr_cpus()`（24）
并非最优。

---

## 6. 结论与未尝试的杠杆

- **已收敛**：当前 Windows 实现 ~0.36 s，相对初始移植 ~0.42 s 提升约 14%，
  其中几乎全部来自“内联城市名比较”这一处。
- **剩余差距是 OS 级**，便携代码难以消除：Linux 的 `MAP_POPULATE`+`madvise`
  在 1.5 GB 上给出了 Windows `MapViewOfFile` 没有的页表/TLB/预读优势。
- **最后一招（未做）**：Windows **大页（2 MB）** 映射 —— 在 `CreateFileMappingA`
  加 `SEC_LARGE_PAGES`、进程需 `SeLockMemoryPrivilege` 特权。2 MB 大页把 1.5 GB
  的页表项从 37.5 万降到 ~750，可大幅削减 TLB miss，是最有可能进一步逼近
  Linux 150 ms 的杠杆。
