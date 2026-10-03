# AX Pro 字符串去混淆（已破解）

## 结论

`其他作者/AX自签v1.2.8.ipa` 里的字符串**不是 AES，也不是真加密**。
它们以「**逐字节内联仿射变换**」的形式被直接编译进 `__text`：
每个明文字节对应一条 `ldrb` + 若干变换 + `strb`，在**使用点当场解码**。

因此早先"AX 二进制里搜不到某字符串 ⇒ AX 不用这个机制"的推断是**无效的**。
（这条错误推断曾经导致把 lara 的 SpringBoard 双窗口托管路径删掉，属于重大回归，已回滚。）

## 解码器形态（示例，0x100006038）

源缓冲 `0x100cb2c00` → 目标缓冲 `0x100cb2c30`：

```
adrp x10, #0x100cb2000 ; add x10, x10, #0xc00      ; src
adrp x11, #0x100cb2000 ; add x11, x11, #0xc30      ; dst

ldrb w11, [x10]        ; b = src[0]
mov  w12, #0xf6
eor  w12, w11, w12     ; b ^ 0xf6
strb w12, [x11]        ; dst[0]

ldrb w12, [x10, #1]
mov  w13, #0x2d
and  w13, w12, w13
sub  w12, w12, w13, lsl #1
add  w12, w12, #0x2d   ; b - 2*(b & 0x2d) + 0x2d
strb w12, [x11, #1]
...
```

单字节可用的变换族：`eor K` / `and K` + `sub ..., lsl #1` + `add K` /
`bic K, b` + `and b, K` + `orr` / `mvn` 位选择。

**坑**：部分字节会用到**读前未写**的寄存器（如 `bic w9, w9, w12`），
其值是**函数序言遗留**的（此例序言 `0x100005f1c mov w9, #0xc2`）。
这类字节必须用「输出必须是可打印 ASCII」作判据穷举入口值，否则会错 1 个字节。

## 已验证的明文（AX Pro v1.2.8）

| 地址 | 明文 |
|---|---|
| `0x100cb2c30` | `SBSAccessibilityWindowHostingController` |
| `0x100cb2c90` | `registerWindowWithContextID:atLevel:` |
| `0x100cb2d10` | `com.axpro.hud.request-termination` |
| `0x100cb2eaf` | `AXHUDKeepAlive`（观测 `A?HUDKeEpAlive`） |
| `0x100eefe60` | `AX.HUD.PhysicalTouchS…` |
| `0x100eeb414` | `setWindowLevel:` |
| `0x100f3bf00` | `com.axpro.autokill.reader` |
| `0x100dafdd0` | `darksword.symbol_offsets_build` |
| `0x100db2b20` | `darksword.kernelcache…` |
| `0x100d70f20` | `thread_set exception_ports` |
| `0x100d713f0` | `RemoteCall cleanup pending: original thread` |
| `0x100d71620` | `LiveContainer can run Khe exploit, but this …` |

即：**AX 与 lara 用的是同一套机制**
（Darksword 内核利用 + RemoteCall 木马 + `SBSAccessibilityWindowHostingController`
+ `registerWindowWithContextID:atLevel:` 注册窗口 + `setWindowLevel:`）。

AX 额外具备 lara 没有的部分：
`AXHUDKeepAlive`（保活）、`com.axpro.hud.request-termination`（请求宿主终止）、
`com.axpro.autokill.reader`（自动 kill）、`AX.HUD.PhysicalTouchS…`。

## 工具

- `extract_strings.py` — 全 `__text` 扫描 + 线性仿真 + 入口值穷举，批量还原
  （当前覆盖 1126 / 7522 个候选块；提高覆盖需处理 ≥3 个未知寄存器的块）
- `emulate_decoder.py` — 单块精仿（用于逐个核对某条字符串）
- `ax_strings2.txt` — 已还原的 1126 条字符串

`extract_strings.py` 需要先把 IPA 里的 AX Pro 主二进制拷到**纯 ASCII 路径**
（LIEF 打不开含中文的路径），并改脚本顶部的 `BIN` 常量。
