# 隔离单次角度探针

这是基础视角自瞄主链复用的单次事务入口，也可由可修改测试宿主直接调用。每个探针实例只允许一次提交，失败消耗机会。主 consumer 每 50 ms 用新捕获的完整快照发起新事务，不重发旧值；采样或事务失败就撤销本轮，需显式停止并重新开始。仅支持 ControlRotation 主槽的 pitch/yaw 小幅增量（各不超过 1 度），不支持任意地址或 RotationInput 槽。

当前仓库没有已审设备 kernel profile，真实写默认仍会拒绝。本入口不会安装 profile、运行利用或解除底层门禁。iPhone 16 Pro Max / iOS 26.0 型号版本不能代替 profile 验证。

## 测试宿主调用合同

1. 测试宿主持有自己的 active request UUID、host generation、config revision，以及独立观测当前 PID/base/read generation/controller 的读取器。建立 `CoreSetIsolatedWriteProbe`，提供 `CoreSetProbeLiveValidator` block。block 必须读取当前状态并验证这些值与捕获快照一致；不能无条件 YES，也不能只回显传入参数。它在探针工作队列同步执行，不能同步等待主线程，不能递归调用 submit/stop。
2. 用已有 `CoreSetPlayerCollector.capture` 的 `includeBattleInputs:YES` 重载取得完整快照；nil 或 battleInputsPresent=false 不提交。只读预览默认 NO，不能拿 HUD 帧代替。捕获到提交及事务验证必须保持在 0.5 秒内。
3. 在测试宿主的后台调用 `submitSnapshot:requestToken:hostGeneration:configRevision:axis:pitchDelta:yawDelta:`。例如 `axis:CoreSetTargetWriteAxisSecond pitchDelta:0 yawDelta:0.25f` 是显式一次 yaw 试验。旧值由快照导出；底层 writer 再独立预读比较并写后独立回读。旧值不同拒绝，不自动刷新并重试。
4. 检查返回 `committed/pending/completedBytes/reason`，然后调用 `stop` 并检查 cleanup.complete。停止会立即撤销 authority，串行等待事务排空并释放资源；新提交拒绝。清理失败时保留探针并重试 stop，不新建探针覆盖 pending 会话。

Objective-C++ 调用形状（`validator`、`snapshot`、`activeToken` 等由测试宿主独立实现和持有）：

```objc
CoreSetIsolatedWriteProbe *probe =
    [[CoreSetIsolatedWriteProbe alloc] initWithLiveValidator:validator];
CoreSetTargetWriteResult *result = [probe submitSnapshot:snapshot
    requestToken:activeToken hostGeneration:hostGeneration
    configRevision:configRevision axis:CoreSetTargetWriteAxisSecond
    pitchDelta:0 yawDelta:0.25f];
// Record result fields without secrets; do not equate committed with hit success.
CoreSetTargetWriteCleanupResult *cleanup = [probe stop];
// Retain probe if cleanup.complete is false, and retry stop before another probe.
```

## 可诊断结果与验收

- `invalid complete battle snapshot...`：缺战斗输入、轴/增量错误或非有限角度。
- `live request/target validation rejected or snapshot expired`：独立 live 验证拒绝、上下文不完整或超过 TTL。
- `target read identity changed`：底层独立读会话与捕获身份不匹配。
- `verified mapped-page kernel profile unavailable or binding stale`：缺已审 profile 或映射不稳定，零提交；当前默认预期会遇到此结果。
- `probe stopped or single attempt already consumed`：本对象不可继续提交。
- `read-compare-mapped-write-independent-readback committed`：仅证明该次字节事务通过独立回读，仍需观测测试宿主效果与停止状态，不证明子弹命中。

`stop` 是停止后续写和资源清理，不会盲目写回旧角度。游戏可能已合法更新角度，旧值不是可直接恢复的恒定配置。测试宿主应自行恢复测试场景；真实目标行为、原生编译、签装、profile、映射安全与设备效果须分别验收。

## 基础自瞄菜单测试

自瞄页下方新增“基础视角自瞄测试 · actor原点”。显式选择触发条件、是否包含人机，并移动范围/距离滑块选择值；只读身份、画布和已审 kernel profile 均就绪时，“开始基础测试”才可提交。状态显示等待触发/无目标/独立回读及失败原因。首次实际 commit 前不会报 applied；停止按钮撤销 authority、排空 worker，清理完成后报告 stopped（动态视角未回写旧值），并允许新 read session 重新启用。

目标点是 actor 世界原点，不是头/胸/臀。控制器视角每步最多改变 1 度，没有导入未知的原版预测、掩体判断、倒地状态、锁定、场景曲线或安全/效率 runMode。这是可测试的基础生产链，未声称完整对齐 v1.7、静默子弹追踪或真机已生效。当前源码没有可信设备 profile 的安装调用，默认明确拒绝真实写；只有另行审定、安装并验证当前系统/内核精确 profile 后才可能开放，不能把新增代码或机型/26.0 当作 profile 已获得。

触发类型 0任一/1开镜/2开火/3同时及触发后的 0.25秒延续按本轮子代理从原Core主程序直接复核的分支接入共用状态机。每次配置提交、停止、失败会重置该状态；时钟非有限或回退拒绝，authority在事务前后再次检查延续期限。采样失效立即撤销，不利用延续继续写旧目标。运行中配置控件锁定，修改须先显式停止。

生产 Swift 实际调用 `CoreSetBasicAimDelta` 的原生桥；桥复用 `CoreSetBasicAimGeometry.h` 的候选、触发与角度函数。Portable C++ 测试执行这些真实共用函数及 SingleAttemptGate，不复制另一份数学实现。但 Swift worker/UI 的运行、Objective-C++ bridge 和签装仍需 Apple SDK/设备测试。

Portable C++ 测试验证请求身份、一次性、失败消耗、时效与撤销。Python 检查仅核对 bridge/同步组注册与复用 writer；二者均不执行 Apple API 或目标写入。`.mm` 在 lara 文件系统同步组内自动编译，bridging header 已导入新头，不另加重复 Sources 条目。
