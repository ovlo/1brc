  分析结论

    你的 v1brc.v 确实厉害——我认真看了，核心优势不在算法（我们的算法完全一样：mmap + spawn + 无锁每线程聚合），而在系统层优化。

    复现成绩（本机 WSL / 24 核）
    | 实现         | 100M 行         | 1B 行 (12.8GB)       |
    |--------------|-----------------|----------------------|
    | 我的 main.v  | 329ms (24T)     | ~3.4s (24T)          |
    | 你的 v1brc.v | 140-150ms (24T) | 1.6s (24T) ✅破 2 秒 |

    你快的 7 个关键原因（按权重）
    1. C.memchr 找 ; / \n — libc 内部 SIMD 向量化字节扫描，比我的手写逐字节 for 循环快数倍（最大单项加速）
    2. 整数温度表示 — 温度存 i32（25.8→258，×10），全程整数零浮点；我的用 f32 + C 浮点解析，慢数倍
    3. 开放寻址哈希表（预分配 []CityHashEntry 数组 + 线性探测）— 零堆分配、缓存友好；我的用 map[string]CityStats（字符串键 + 堆分配），慢且碎片多
    4. hash_bytes 一次读 u64 算 FNV，减少循环
    5. 编译旗 -no-bounds-checking — 关掉全局数组边界检查（我的 @[direct_array_access] 只关局部不够）
    6. MAP_POPULATE + madvise(SEQUENTIAL) — mmap 时预填页表 + 告诉内核顺序访问，减缺页停顿（对 12.8GB 文件尤其关键）
    7. runtime.nr_cpus() 自动用满 24 核（我硬编码 8）

    已固化的资产
    - readme.md：新增"两个实现性能对比"章节 + 你的 7 个优化点逐条解析
    - v-fullstack-dev 技能库：references/c_ffi_mmap.md 新增 §9b「High-performance 1BRC recipe」，并把
    v1brc.v 存为 templates/1brc_user.v 范本
    - 记忆：写入 V 高性能套路（memchr / 整数温度 / 开放寻址 / -no-bounds-checking / mmap 预取等 7 条）

    > 一句话总结：算法相同，差距全在"系统层优化"——这正是能跑的实现与优秀实现之间的距离。 你这份代码本身就是最好的 V 高性能编程教材。
