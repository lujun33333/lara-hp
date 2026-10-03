# AX Pro 1.2.8 全项目同步进度

更新时间：2026-09-20  
工作分支：`lara-wz-clean`  
当前基线提交：`db3ff41`（后续改动尚未提交、推送或打包）

## 目标

不只复刻启动页 UI，而是按 AX Pro 1.2.8 的真实处理链同步：

- 设备型号与系统支持判定；
- 卡密、授权状态与到期时间；
- 内核环境、XPF 偏移初始化与生命周期；
- 王者启动门禁；
- 双窗口 HUD、跨 App 托管、绘制、触摸和退出清理；
- Scene 断开、前后台切换和重连；
- 构建、包体与真机行为验证。

## 已确认的根因

### 1. 先前的两次闪退

- 第一次：Lara 调用方与 `libxpf.dylib` 的 `xpf_start_with_kernel_path` 参数 ABI 不一致。
- 第二次：Lara 仍按 AX 旧版 `gXPF.firstItem + 0x110` 读取，而新版 XPF 已将该字段移到 `+0x1a8`，最终把 Mach-O 魔数当成链表指针访问。
- 这两项已在提交 `82c4c1f`、`db3ff41` 分阶段处理，但最新完整逆向证明：只修参数或结构偏移仍不够。

### 2. 当前 XPF 是“旧 AX ABI + 新版内部实现”的混搭

原 AX 1.2.8 二进制已确认：

- `xpf_start_with_kernel_path @ 0x100a8ba7c` 只有一个 kernelcache 参数；
- `gXPF.firstItem` 位于 `+0x110`，`ignoreBaseSet` 位于 `+0x118`；
- 原版没有新版 `gXPF.sptm/gXPF.txm` 字段，也没有三镜像 XPF loader；
- `sptm.im4p`、`txm.im4p` 是固件获取器的解包产物，不是该 XPF 入口的参数。

当前项目却使用包含 SPTM/TXM 字段、三镜像 finder 和 `firstItem + 0x1a8` 的新版 XPF，再把入口机械改成单参数。这会让结构、集合支持判断和 finder 彼此不一致，是当前最高优先级问题。

结论：必须整体恢复 AX 对应的旧 XPF 源码与布局，并只回移植 iOS 26 必需的 finder 修复；不能继续给混搭版本补偏移。

### 3. HUD 曾把“窗口已创建”误报为“跨 App 托管成功”

此前 `finish_hud_services_main()` 在本地 hosting controller 注册失败后，仍将 system-window/context 标为 ready，Swift 因而跳过 SpringBoard fallback。切到王者后，Lara 自己 Scene 上的窗口并不等于跨 App 可见。

### 4. 启动页连续启动两次全局 XPF

`init_offsets()` 曾启动 XPF 且不停止，紧接着 `resolvekernoffsets()` 再次覆盖全局 `gXPF`，可能造成 mmap/fd 泄漏、item 缓存污染和重入崩溃。

### 5. 当前工程没有原版授权实现

当前旧启动页的“卡密激活”只弹提示，没有验证、Keychain 状态、到期时间或启动门禁。原 AX 已确认存在：

- `KVVerifyStrictSessionDelegate`；
- Keychain、SecKey、HMAC、PBKDF2、SHA-256；
- `card_code`、`device_fingerprint`、`feature_code`、`kv_state`、`state_secret_v`、`vip_expire_*`；
- `VerifyStateDidChangeNotification`；
- 未激活、验证中、已激活、过期、错误状态及到期时间显示。

服务器 URL、请求头、请求 JSON 和响应 schema 尚未完整恢复，因此当前不能安全声称卡密网络协议已同步，也不能制造假激活结果。

## 已完成的未提交改动

### HUD 托管 P0

涉及：

- `lara/kexploit/WZHUDBridge.mm`
- `tests/wz_hosting_readiness_static_test.ps1`
- `tests/wz_source_static_test.ps1`

已完成：

- 本地 ready 必须依赖两个 hosting controller 的真实注册结果；
- 裸 `UIWindowScene` 窗口和 contextId 不再被当成跨 App ready；
- 本地注册失败时保留 source context，并进入 SpringBoard fallback；
- 半注册会先回滚；
- context 失效或 HUD 销毁时清除 ready、stable 和 validated mask；
- `wzhud_is_enabled()` 只在本地或 SpringBoard 任一真实 host 成功后返回 true。

### XPF 生命周期 P0

涉及：

- `lara/kexploit/utils.m`
- `tests/wz_source_static_test.ps1`

已完成：

- `init_offsets()` 只初始化静态结构偏移，不再启动 XPF；
- XPF session 由 `resolvekernoffsets()` 单点拥有并负责 start/stop；
- 新增静态断言，禁止 `init_offsets()` 再次引入 XPF start。

### 启动页、设备名与视觉

涉及：

- `lara/views/app/ContentView.swift`
- `lara/funcs/DeviceMarketingName.swift`
- `lara/funcs/isunsupported.swift`
- `tests/wz_ax128_launcher_static_test.ps1`

已完成：

- 增加未验证、验证中、已激活、过期、失败的展示状态；
- 已激活态隐藏卡密输入与激活按钮，显示到期时间；
- `iPhone17,2` 显示为 `iPhone 16 Pro Max`，并补齐已确认的 iPhone 映射；
- 增加星点动画、上下 Aurora、卡片顶部高光、边框与外发光；
- 系统支持判断统一为共享结果，覆盖 AX 已确认的 `iPhone18,*`、`iPad17,*`、iOS 18.7.2、26.0.2 和 26.1 门禁；
- UI 和游戏启动入口共用同一支持判断；
- 没有硬编码授权成功、固定到期时间、服务 URL、token 或密钥。

### Scene 生命周期与可重连清理

涉及：

- `lara/lara.swift`
- `lara/classes/laramgr.swift`
- `tests/wz_scene_lifecycle_static_test.ps1`

已完成：

- 补齐 `sceneWillEnterForeground`、`sceneDidDisconnect`；
- 普通 Scene 断开会失效旧 epoch，清理 HUD、RemoteCall、采集、内存连接和音频，但不会永久锁死进程；
- 新 Scene 可重新启动音频并建立新一代会话；
- 旧 Scene 的环境初始化、RemoteCall 和启动回调不能在重连后复活；
- `applicationWillTerminate` 仍使用永久终止路径。

## 已运行检查

当前已实际通过：

- `tests/wz_hosting_readiness_static_test.ps1`
- `tests/wz_scene_lifecycle_static_test.ps1`
- `tests/wz_source_static_test.ps1`
- `tests/wz_ax128_launcher_static_test.ps1`
- `tests/wz_ax128_ui_static_test.ps1`
- `git diff --check`（仅换行符提示）

这些结果属于源码/静态行为门禁，不等于 iOS 编译、真机渲染、卡密联网或王者内运行通过。

## 正在处理

1. 将 `vendor/XPF` 整体恢复到 AX 1.2.8 对应的旧布局和单 kernelcache 实现。
2. 从上游旧版源码回移植 iOS 26 必需的 `arm_maxoffset` finder 修复，不带入新版 SPTM/TXM 结构。
3. 同步 Lara 侧 `xpf.h`、构建门禁和最终 Mach-O 偏移检查，确保 `firstItem` 恢复为 `+0x110`。
4. 继续还原授权服务器 URL、请求字段、响应字段、证书校验和 Keychain 状态格式。
5. 完成代码审计后推送并触发 WZ IPA 构建。

## 尚未完成 / 不能声称已完成

- XPF 整套回退尚未落盘和编译；
- 原版卡密网络协议尚未恢复；
- 当前改动尚未提交、推送；
- 尚未生成包含本轮改动的新 IPA；
- 尚未进行 Xcode 编译、真机启动、真机卡密、王者跨 App HUD 和高光截图验证；
- 因此目前不能称为“全部同步完成”。

## 下一次可验收节点

- 源码层：旧 XPF 布局、单参数入口、finder 和 Lara 头文件一致；
- 构建层：CI 成功，最终 IPA 内 `libxpf.dylib` 的 `firstItem` 访问为 `+0x110`；
- 真机层：不闪退、设备显示为营销名、授权状态正确、启动后 HUD/高光在王者前台可见；
- 若卡密服务协议仍无法从二进制得到完整证据，将单独列为外部阻塞，不以本地假授权替代。
