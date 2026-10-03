$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

function Require-Text([string]$Path, [string]$Pattern, [string]$Message) {
    $content = Get-Content -LiteralPath (Join-Path $root $Path) -Raw -Encoding UTF8
    if ($content -notmatch $Pattern) { throw "FAIL: $Message ($Path)" }
}

function Reject-Text([string]$Path, [string]$Pattern, [string]$Message) {
    $content = Get-Content -LiteralPath (Join-Path $root $Path) -Raw -Encoding UTF8
    if ($content -match $Pattern) { throw "FAIL: $Message ($Path)" }
}

function Require-Count([string]$Path, [string]$Pattern, [int]$Count, [string]$Message) {
    $content = Get-Content -LiteralPath (Join-Path $root $Path) -Raw -Encoding UTF8
    $actual = [regex]::Matches($content, $Pattern).Count
    if ($actual -ne $Count) {
        throw "FAIL: $Message expected=$Count actual=$actual ($Path)"
    }
}

# Read-only transport and current-game profile contracts.
Require-Text 'lara/kexploit/wzmem.h' 'WZ_CAP_READ' '缺少统一读取 capability'
Require-Text 'lara/kexploit/wzmem.h' 'WZ_CAP_WRITE' '缺少统一写入 capability'
Require-Text 'lara/kexploit/wzmem.m' 'task_read_for_pid' '缺少只读 task port 获取回退'
Require-Text 'lara/kexploit/wzmem.m' 'processor_set_tasks' '缺少 processor-set task port 回退'
Require-Text 'lara/kexploit/wzmem.m' 'mach_port_deallocate\(mach_task_self\(\), machTask\)' '断开未释放 task port'
Require-Text 'lara/kexploit/wzmem.m' 'writing \? WZ_CAP_WRITE : WZ_CAP_READ' '读写未按 capability 门禁'
Require-Text 'lara/kexploit/wzmem.m' 'wzmem_read_chunks' 'Mach 读取未使用部分完成契约'
Require-Text 'lara/kexploit/wzmem.m' 'wz_mcache_open\(256\)' '外读采集仍使用单页缓存'
Require-Text 'lara/classes/laramgr.swift' 'let canWrite = false' 'WZ 未保持版本级写权限 fail-closed'
Require-Text 'lara/classes/laramgr.swift' 'wzesp_tick' '王者只读采集未接入 worker'
Require-Text 'lara/classes/laramgr.swift' 'wz_find_image_base' '未按 UUID 定位 UnityFramework'
Require-Text 'lara/kexploit/wz/YuanbaoCollector.mm' 'header\.camp != host\.camp' '英雄敌我分类未接 camp'
Require-Text 'lara/kexploit/wzesp.h' 'WZESP_SHOW_MAP_ADJUSTMENT' '缺少地图调节开关'
Require-Text 'lara/kexploit/wzesp.h' 'WZESP_SHOW_SKILL' '缺少技能读取开关'

# AX architecture: two local source windows plus two SpringBoard CALayerHost
# mirrors. Local SBS registrations are independent best-effort operations.
Require-Text 'lara/kexploit/WZHUDBridge.mm' '@interface WZHUDDrawWindow : UIWindow' '缺少 AX 绘制窗口'
Require-Text 'lara/kexploit/WZHUDBridge.mm' '@interface WZHUDMenuWindow : UIWindow' '缺少 AX 菜单窗口'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_windowContextIDs\[2\]' 'AX context 数量不是两个'
# Local readiness is reserved for successful local hosting-controller
# registration.  Bare source windows/context IDs remain available for the
# active SpringBoard fallback, but are not themselves a cross-app ready state.
Require-Text 'lara/kexploit/WZHUDBridge.h' 'bool wzhud_local_hosting_ready\(void\)' '桥接头未暴露本地托管 readiness'
Require-Text 'lara/kexploit/WZHUDBridge.h' 'unsigned int wzhud_draw_context_id\(void\)' '桥接头未暴露绘制 context id'
Require-Text 'lara/kexploit/WZHUDBridge.h' 'unsigned int wzhud_menu_context_id\(void\)' '桥接头未暴露菜单 context id'
Require-Text 'lara/kexploit/WZHUDBridge.mm' "bool wzhud_local_hosting_ready\(void\)[\s\S]{0,260}g_localHostingReady\.load\(\)[\s\S]{0,100}g_systemWindowMode\.load\(\)[\s\S]{0,220}g_windowContextIDs\[0\] != 0" '本地托管 readiness 未绑定真实注册、双窗口与 contextId'
Require-Text 'lara/kexploit/WZHUDBridge.mm' "BOOL menuReady = register_local_hosting_side_main\(1\);[\s\S]{0,120}BOOL drawReady = register_local_hosting_side_main\(0\);[\s\S]{0,160}wzhud_hosting_outcome\(menuReady, drawReady\)" '本地托管未保留菜单、绘制两侧的独立注册结果'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'wz_probe_hosting_classes_once' '缺少真机托管类只读探测'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'bool wzhud_springboard_hosting_ready\(void\)' '跨进程托管 readiness 缺失'
Require-Text 'lara/kexploit/WZHUDBridge.h' 'wzhud_springboard_hosting_ready' '桥接头缺跨进程托管 readiness'
Require-Text 'lara/kexploit/WZHUDBridge.mm' "bool wzhud_is_enabled\(void\)[\s\S]{0,220}g_localHostingReady\.load\(\)[\s\S]{0,100}wzhud_springboard_hosting_ready\(\)[\s\S]{0,250}g_active\.load\(\)[\s\S]{0,250}g_windowContextIDs\[0\]" 'HUD enabled 未绑定本地或 SpringBoard 真实托管'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' "posix_spawn|--wzhud-host|WZHUDFloatWindow|g_windowContextIDs\[3\]" '仍混入 helper 或 Core 三窗口结构'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' "wzhud_(create|remove|poll)_direct_springboard|wzhud_(start|stop)_context_host_helper" '仍暴露旧远端/helper 实现'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' "static void handle_scene_activity_main\(BOOL active\)[\s\S]{0,900}if \(!active\)[\s\S]{0,450}(destroy_hud_main|unregister_local_hosting_main|g_(window|menuWindow)\.hidden = YES)" '切到游戏后仍销毁、注销或隐藏 AX 双窗口'
Require-Text 'lara/kexploit/WZHUDBridge.mm' "void wzhud_update_wz_snapshot\([\s\S]{0,1200}!g_sceneActive\.load\(\)[\s\S]{0,300}g_backgroundSnapshotApplyPending\.compare_exchange_strong[\s\S]{0,700}dispatch_async\(dispatch_get_main_queue\(\)[\s\S]{0,700}render_frame_main\(CACurrentMediaTime\(\)\)" '后台快照发布未驱动合并后的主线程应用'
Require-Text 'lara/kexploit/WZHUDBridge.mm' "static void render_frame_main\([\s\S]{0,2200}ax_build_render_commands\(latest, latestCount, current_wz_config\(\)[\s\S]{0,1000}useLayerRenderer[\s\S]{0,500}present_layer_frame_main\(frame\)[\s\S]{0,120}\[CATransaction flush\]" '后台或远程托管帧未从共享不可变命令提交 CA'
Require-Text 'lara/kexploit/WZHUDBridge.mm' "else \{[\s\S]{0,500}submitCommands:&frame\.commands[\s\S]{0,180}bounds:frame\.bounds scale:frame\.scale" '前台帧未消费同一命令集到 ImDrawList'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'UIApplicationDidEnterBackgroundNotification[\s\S]{0,500}UIApplicationDidBecomeActiveNotification' '未按 AX gdr2sae1a 安装 UIApplication 生命周期观察者'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' 'static BOOL present_layer_frame_main\([\s\S]{0,5000}(g_canvas\.subviews|CGPathCreateCopyByTransformingPath)' '后台 CA 仍遍历 UIKit staging 或复制 CGPath'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'ax_enable_hosted_layer\(CALayer \*layer\)[\s\S]{0,350}setDisableUpdateMask:[\s\S]{0,200}0x12' '缺少 AX 已证实的后台图层掩码'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'wz_probe_hosting_classes_once[\s\S]{0,1400}objc_copyClassList\(&count\)' '托管类探测未按只读枚举实现'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'kWZHUDWindowLevel = 10000009\.0' 'HUD 层级未对齐 AX 的 10000009/10000010'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'BOOL menuPublished = present_menu_window_main\(\);[\s\S]{0,180}register_local_hosting_side_main\(1\)[\s\S]{0,260}g_window = hudScene[\s\S]{0,700}register_local_hosting_side_main\(0\)' 'HUD 未按菜单发布/注册后再创建/注册绘制窗口'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'AX hosting-order menu-publish/register=%d/%d[\s\S]{0,100}draw-create/register=1/%d' '缺少窗口创建与注册顺序诊断'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' 'previousKeyWindow|\[.* makeKeyWindow\]' 'HUD 仍恢复旧 key window'
Require-Text 'lara/kexploit/WZHUDBridge.mm' '\[g_menuWindow makeKeyAndVisible\]' 'AX 菜单未 makeKeyAndVisible'
foreach ($window in @('WZHUDDrawWindow', 'WZHUDMenuWindow')) {
    Require-Text 'lara/kexploit/WZHUDBridge.mm' ("@implementation $window" + '[\s\S]{0,100}\+ \(BOOL\)_isSystemWindow \{ return YES; \}[\s\S]{0,100}_isSecure \{ return NO; \}[\s\S]{0,100}_canBecomeKeyWindow \{ return YES; \}[\s\S]{0,100}_isApplicationKeyWindow \{ return NO; \}[\s\S]{0,100}_isWindowServerHostingManaged \{ return NO; \}') 'AX 私有窗口身份不一致'
}
Require-Text 'lara/kexploit/WZHUDBridge.mm' '@implementation WZHUDDrawWindow[\s\S]{0,500}_ignoresHitTest \{ return YES; \}' '绘制窗口未透传'
Require-Text 'lara/kexploit/WZHUDBridge.mm' '@implementation WZHUDMenuWindow[\s\S]{0,500}_ignoresHitTest \{ return NO; \}' '菜单窗口错误透传'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'for \(NSUInteger index : \{ 1u, 0u \}\)' 'context 未按菜单、绘制顺序获取'
# Source windows remain alive while the active SpringBoard fallback mirrors
# their contexts. Backgrounding must not destroy those source surfaces.
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'if \(!active\)[\s\S]{0,500}configure_layer_renderer_main\(\)' '后台未配置 AX 托管图层'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'local-hosting draw/menu' '缺少本地 system-window 托管就绪日志'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'bool wzhud_register_springboard_hosts\(RemoteCall \*remoteCall\)' 'SpringBoard 跨进程托管回落未启用'
Require-Text 'lara/kexploit/WZHUDBridge.mm' '_shouldCreateContextAsSecure \{ return NO; \}' 'Core system-window fallback 仍错误创建 secure context'

# AX failure callbacks report the error; only host success opens the game.
Require-Text 'lara/classes/laramgr.swift' 'func launchWZGame\(\)[\s\S]*setGameHUD\(true\)[\s\S]*prepareWZSpringBoardHosting \{[\s\S]{0,450}guard success else[\s\S]{0,500}wzhud_set_panel_visible\(true\)[\s\S]{0,100}openWZGame\(epoch: launchEpoch\)' '游戏启动未在托管成功后展示 HUD 并启动游戏'
Require-Text 'lara/classes/laramgr.swift' 'wzLaunchPending = true[\s\S]{0,180}initializeWZEnvironment\(\)' '首次启动未保留环境初始化后的续接请求'
Require-Text 'lara/classes/laramgr.swift' 'if self\.wzLaunchPending \{[\s\S]{0,100}self\.launchWZGame\(\)' '偏移初始化成功后未自动续接游戏启动'
Require-Text 'lara/classes/laramgr.swift' 'if wzhud_local_hosting_ready\(\) \{' 'HUD 启动未以本地托管 readiness 为第一级'
Require-Text 'lara/classes/laramgr.swift' 'wzhud_register_springboard_hosts\(remoteProcess\)' 'Swift 未走跨进程托管兜底'
Reject-Text 'lara/classes/laramgr.swift' 'prepareWZLocalHUDAndOpen|attempt < 30|正在注册 AX 本地双窗口' '游戏启动仍保留 HUD 等待门禁'
Require-Text 'lara/classes/laramgr.swift' 'local hosting ready \(AX 双系统窗口模式\)' 'HUD 启动未走本地双窗口就绪分支'
# A failed local registration may keep source windows for fallback, but it must
# clear every local-ready/validated marker and must never log itself as ready.
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_systemWindowMode\.store\(axHosted\)[\s\S]{0,160}g_contextsStable\.store\(axHosted\)[\s\S]{0,160}g_validatedContextMask\.store\(axHosted \? kWZHUDFullContextMask : 0\)' '本地注册失败仍伪造 system-window/context 就绪态'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'hosting=pending mode=unhosted-source[\s\S]{0,180}awaiting SpringBoard fallback' '本地注册失败未明确进入 SpringBoard 回落等待态'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' 'hosting=ready mode=system-window' '未托管的 Lara scene 窗口仍被宣称为跨 App 就绪'
Require-Text 'lara/classes/laramgr.swift' 'opening com.tencent.smoba[\s\S]*wzhud_open_smoba_application\(\)[\s\S]*open callback opened=' 'bundle ID 启动缺少结果诊断'
Reject-Text 'lara/classes/laramgr.swift' 'private func openWZGame\(epoch: UInt64\)[\s\S]{0,240}DispatchQueue\.main\.async' 'LS 启动成功块被额外投递了一次主队列'
Reject-Text 'lara/classes/laramgr.swift' 'smoba1104466820|openWZGameURL' '仍保留非 AX URL 启动'
Require-Text 'lara/classes/laramgr.swift' 'func setGameHUD\(_ enabled: Bool\)[\s\S]{0,1500}let requested = wzhud_set_enabled\(true\)' 'HUD 创建未收敛到 wzhud_set_enabled'
Require-Count 'lara/classes/laramgr.swift' 'wzhud_set_enabled\(true\)' 1 'HUD 创建入口不唯一'
Reject-Text 'lara/classes/laramgr.swift' 'wzGameHUD(Position|LargeFont|SingleLine|Inverted)|showWZControlPanel|cycleWZColor|resetWZFeatureState|wzhud_set_wz_config' 'Swift 仍保留 CORE 面板状态或覆盖 AX 配置'
Require-Text 'lara/classes/laramgr.swift' 'wzhud_copy_wz_config\(&config\)' '采集未直接读取 AX 菜单配置'
Require-Text 'lara/kexploit/wzesp.h' 'float skillSize;' '配置缺少独立 AX 技能大小字段'
Require-Text 'lara/classes/laramgr.swift' 'private func hideGameHUD\([\s\S]{0,400}rcdestroy' 'HUD 停止未统一走 mode0/RC/context 清理'
Reject-Text 'lara/classes/laramgr.swift' 'wzhud_(start|stop)_context_host_helper|wzhud_prepare_game_launch' 'Swift 启动链仍调用旧 helper/Core 门禁'
Reject-Text 'lara/lara.swift' 'handleLaraBackgroundTransition\([\s\S]{0,1000}wzhud_set_enabled\(false\)' 'App 退后台仍销毁 AX HUD'
Reject-Text 'lara/lara.swift' 'handleLaraBackgroundTransition|RemoteCallCleanup' '普通前后台仍销毁 RemoteCall'
Require-Text 'lara/lara.swift' 'didFinishLaunchingWithOptions[\s\S]{0,150}startBackgroundAudio\(\)' '启动音频晚于窗口生命周期'
Require-Text 'lara/classes/laramgr.swift' 'numberOfLoops = -1[\s\S]{0,80}volume = 0\.08' 'AX 音频循环/音量不一致'
Require-Text 'lara/classes/laramgr.swift' 'beginBackgroundTask\(withName: "AXHUDKeepAlive"' '缺少 AX background task'
Require-Text 'lara/classes/laramgr.swift' 'guard audioObservers\.isEmpty[\s\S]{0,250}AVAudioSession\.interruptionNotification' '音频观察者重复或遗漏中断通知'
Require-Text 'lara/classes/laramgr.swift' 'AVAudioSession\.mediaServicesWereResetNotification[\s\S]{0,250}audioPlayer = nil[\s\S]{0,80}recoverBackgroundAudio' '媒体服务重置未重建播放器'
Require-Text 'lara/classes/laramgr.swift' 'reason == 1 \|\| reason == 2 \|\| reason == 4' 'route change 原因未按 AX 筛选'
Require-Text 'lara/classes/laramgr.swift' 'for delay in \[0\.0, 0\.2, 0\.5, 1\.0, 2\.0, 4\.0, 8\.0, 16\.0\]' 'AX 音频恢复时序不一致'
Require-Text 'lara/classes/laramgr.swift' 'audioRecoveryEpoch == epoch[\s\S]{0,200}endAudioBackgroundTask\(\)' '恢复成功未取消旧代恢复并结束后台任务'
Require-Text 'lara/classes/laramgr.swift' 'func stopBackgroundAudio[\s\S]{0,400}removeObserver[\s\S]{0,200}audioWatchdog\?\.cancel' '音频终止未注销通知和watchdog'
Require-Text 'lara/kexploit/TaskRop/RemoteCall.m' 'return version\.majorVersion == 16;' 'AX exact iOS16 分支未同步'
Reject-Text 'lara/kexploit/TaskRop/RemoteCall.m' 'return version\.majorVersion >= 16;' 'iOS17/26 仍误走 iOS16 分支'
Require-Text 'lara/classes/laramgr.swift' 'func rcdestroy[\s\S]{0,1000}cleanupRemoteCallsOnWorker\(remoteProcess\)' 'rcdestroy 未进入带 pending retry 的串行销毁路径'
Reject-Text 'lara/classes/laramgr.swift' 'retained local contexts|RemoteCall and contexts retained|远程调用会话已保留' '仍残留非 AX 失败保留策略'
Reject-Text 'lara/classes/laramgr.swift' 'Date\(timeIntervalSinceNow: 2\)|deadline: \.now\(\) \+ 0\.5|termination cleanup did not finish before callback deadline' '仍残留无 AX 依据的终止期限/host 轮询'
Require-Text 'lara/classes/laramgr.swift' 'prepareWZSpringBoardHosting[\s\S]{0,600}wzhud_local_hosting_ready' '准备函数未以本地托管为判据'
Require-Text 'lara/classes/laramgr.swift' 'private func performWZCleanupSync[\s\S]{0,240}DispatchQueue\.getSpecific\(key: wzWorkerKey\) == 1[\s\S]{0,180}wzWorker\.sync\(execute: body\)' '远端清理 helper 未保持同队列直接、异队列同步'
Require-Text 'lara/classes/laramgr.swift' 'private func drainWZRemoteTeardown\(\)[\s\S]{0,2200}while !finished[\s\S]{0,80}CFRunLoopRun\(\)' '远端队列缺少同步排空'
Require-Text 'lara/classes/laramgr.swift' 'private func drainWZReaderTeardown\(\)[\s\S]{0,900}while !finished[\s\S]{0,60}CFRunLoopRun\(\)' '独立 reader 队列缺少同步排空'
Require-Text 'lara/classes/laramgr.swift' 'func terminateWZSession[\s\S]{0,700}drainWZRemoteTeardown\(\)[\s\S]{0,120}wzhud_request_termination_sync\(\)[\s\S]{0,120}drainWZReaderTeardown\(\)[\s\S]{0,120}stopBackgroundAudio\(\)' '终止顺序不是远端→本地 HUD→reader→音频'

# AX pages and the retained collector draw-item interface.
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'item\.primitive == WZESP_PRIMITIVE_MONSTER_POINT' '野怪点位绘制断开'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'item\.primitive == WZESP_PRIMITIVE_SOLDIER_POINT' '兵线点位绘制断开'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'item\.recallActive[\s\S]{0,900}1\.0995573997497559f' '回城动态绘制断开'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'item\.auxiliaryCooldownSeconds' '辅助技能冷却未进入绘制层'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'heroimg/%d/%d\.jpg' 'AX 英雄头像加载链未接入'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'summonero/%d\.png' '元宝召唤师图标加载链未接入'
Require-Text 'lara/kexploit/WZHUDBridge.mm' '@"大图头像"' '元宝大图头像功能缺失'
Require-Text 'lara/kexploit/WZHUDBridge.mm' '@"野怪刷新"' '元宝野怪刷新功能缺失'
Require-Text 'lara/kexploit/WZHUDBridge.mm' '@"英雄技能"' '元宝英雄技能功能缺失'
Require-Text 'lara/kexploit/WZHUDBridge.mm' '@"地图 X"[\s\S]{0,100}@"地图 Y"' '元宝地图位置功能缺失'
Require-Text 'lara/kexploit/wzesp.mm' 'if \(entity\.isDead != 0\) \{[\s\S]{0,80}continue;' '发布端未在技能 HUD 前过滤死亡实体'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' '@"CORE\.|S M O B A|wzCore|rebuild_core_page|update_fallback_snapshot|present_snapshot_metal|wzhud_set_presentation' '仍残留 CORE UI 或截图渲染实现'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' '描边增强（写入）|目标追踪（写入）|自动瞄准（写入）' '菜单仍混入写入功能'

# One executable, no helper source and no spawn/direct-remote path.
$helper = Join-Path $root 'scripts/WZHUDHostHelper.m'
if (Test-Path -LiteralPath $helper) { throw 'FAIL: 已删除的 WZHUDHostHelper.m 仍存在' }
Reject-Text 'lara.xcodeproj/project.pbxproj' 'WZHUDHostHelper' 'Xcode 工程仍引用旧 helper'
Reject-Text 'scripts/build_ipa_wz.sh' 'WZHUDHostHelper\.m|WZHUDHostHelper\.o|posix_spawn\s*\(' '构建脚本仍编译 helper 或调用 spawn'
Require-Text 'scripts/build_ipa_wz.sh' 'WZHUDDrawWindow[\s\S]*WZHUDMenuWindow[\s\S]*IOHIDEventSystemClientDispatchEvent[\s\S]*local-hosting draw/menu' '构建未验证进程内托管契约'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'create_local_hosting_controller' '本地 SBS 托管控制器路径被删除'
Require-Text 'lara/kexploit/WZHUDBridge.h' 'wzhud_register_springboard_hosts' '桥接头未暴露跨进程托管入口'
Require-Text 'lara/classes/laramgr.swift' 'installWZSpringBoardHosting' 'Swift 侧跨进程托管兜底被删除'
Require-Text 'scripts/build_ipa_wz.sh' 'PlistBuddy.*LARABuildSourceCommit' '构建产物未写入源码提交标识'
Require-Text 'Config/lara.entitlements' 'com\.apple\.QuartzCore\.displayable-context' '最终签名缺少可显示 context 权限'
Require-Text 'Config/lara.entitlements' 'com\.apple\.springboard\.accessibility-window-hosting' '最终签名缺少 AX 托管权限'

# Explicit single-scene UIKit host and background audio contract.
Require-Text 'lara/lara.swift' '@main[\s\S]*final class LaraAppDelegate: UIResponder, UIApplicationDelegate' '缺少 UIKit AppDelegate 入口'
Require-Text 'lara/lara.swift' '@objc\(ZeqcgKhNvh\)[\s\S]*UIWindowSceneDelegate' 'SceneDelegate 运行时类名未对齐 AX'
Require-Text 'lara/lara.swift' 'UIWindow\(windowScene: windowScene\)' 'SceneDelegate 未创建主窗口'
Require-Text 'lara/lara.swift' 'self\.window = window[\s\S]{0,160}window\.backgroundColor = \.black[\s\S]{0,240}window\.rootViewController = AXLauncherViewController[\s\S]{0,240}window\.makeKeyAndVisible\(\)' 'AX UIKit 根控制器建立顺序不一致'
Reject-Text 'lara/lara.swift' 'UIHostingController|LaraRootView' '启动路径仍保留 SwiftUI 根壳'
foreach ($callback in @('sceneDidBecomeActive', 'sceneWillEnterForeground', 'sceneWillResignActive', 'sceneDidEnterBackground', 'sceneDidDisconnect')) {
    Require-Text 'lara/lara.swift' ("func $callback\(_ scene: UIScene\)\s*\{\s*\}") "AX Scene 空回调被加入额外副作用：$callback"
}
Require-Text 'lara/Info.plist' '<string>audio</string>' '应用未保留后台音频模式'
Require-Text 'lara/Info.plist' '<key>UIApplicationSupportsMultipleScenes</key>[\s\S]*<false/>' '应用未保持单场景模式'
Require-Text 'lara/views/app/ContentView.swift' 'mgr\.launchWZGame\(\)' '启动入口未接王者启动链'
Reject-Text 'lara/views/app/ContentView.swift' 'WZControlPanelView\(' '应用仍叠加 SwiftUI 控制台副本'

Require-Text 'lara/kexploit/WZHUDBridge.mm' 'game\.gtimg\.cn/images/yxzj/img201606/heroimg/%d/%d\.jpg' 'AX 英雄头像地址未接入'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'game\.gtimg\.cn/images/yxzj/img201606/summonero/%d\.png' '元宝召唤师技能头像地址未接入'
if (Test-Path -LiteralPath (Join-Path $root 'lara/heroatlas.bin')) {
    throw 'FAIL: 已删除的旧英雄图集仍在产品资源中'
}

# ── AX 交互模型（对齐 AX Pro v1.2.8 的 mjh763hgxc）──────────────────────
# 几何过渡按 token 记账而不是计数器；指针按 id 记账；两态几何各有显式入口。
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_hudActivePointerIDs\s*=\s*\[NSMutableIndexSet' '缺少 AX 活动指针集合'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_hudActiveGeometryTransitionIDs\s*=\s*\[NSMutableIndexSet' '缺少 AX 几何过渡 token 集合'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_hudGeometryTransitionGeneration\.fetch_add\(1\)' '缺少 AX 几何过渡 generation'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'static uint64_t hud_begin_geometry_transition\(void\)[\s\S]{0,300}addIndex:' '几何过渡未按 token 记账'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'static void hud_end_geometry_transition_for_token\(uint64_t token\)[\s\S]{0,180}removeIndex:' '几何过渡 token 未被回收'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'hud_begin_synthetic_interaction_for_pointer\(int64_t pointerID\)[\s\S]{0,200}addIndex:' '缺少 AX 按 pointerID 的合成交互入口'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'hud_end_synthetic_interaction_for_pointer\(int64_t pointerID\)[\s\S]{0,200}removeIndex:' '缺少 AX 按 pointerID 的合成交互回收'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'hud_apply_compact_geometry\(void\)' '缺少 AX 紧凑几何入口'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'hud_apply_full_screen_geometry\(void\)' '缺少 AX 全屏几何入口'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'hud_reconcile_interaction_geometry\(void\)' '缺少 AX 几何和解入口'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'hud_refresh_interaction_geometry\(void\)' '缺少 AX 几何刷新入口'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'hud_resolved_full_screen_bounds\(void\)' '缺少 AX 全屏边界求解'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_hudSurfaceBounds' '缺少 AX hudSurfaceBounds 状态'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_hudPortraitSurfaceBounds' '缺少 AX hudPortraitSurfaceBounds 状态'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_hudContentRequiresFullScreen' '缺少 AX hudContentRequiresFullScreen 状态'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_hudInteractionGeometryConfigured' '缺少 AX hudInteractionGeometryConfigured 状态'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'g_hudCompactGeometryApplied' '缺少 AX hudCompactGeometryApplied 状态'
Require-Count 'lara/kexploit/WZHUDBridge.mm' 'hud_refresh_interaction_geometry\(\)' 3 '几何刷新调用点数量异常'
Require-Count 'lara/kexploit/WZHUDBridge.mm' 'hud_apply_full_screen_geometry\(\)' 2 '全屏几何未在面板展示和 SpringBoard 托管前同步'
Require-Count 'lara/kexploit/WZHUDBridge.mm' 'hud_apply_compact_geometry\(\)' 1 '紧凑几何未被调用'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' 'g_geometryTransitions' '仍保留 AX 没有的过渡计数器'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'remote_host_context\([\s\S]{0,360}CGRect surfaceFrame' 'SpringBoard 托管没有接收完整物理 surface'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'window, runtime->selSetFrame,[\s\S]{0,100}&surfaceFrame' '远程 UIWindow 仍未设置完整 surface frame'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'hostLayer, runtime->selSetFrame,[\s\S]{0,100}&surfaceFrame' '远程 CALayerHost 仍未设置完整 surface frame'
Require-Text 'lara/kexploit/WZHUDBridge.mm' 'clsTransaction[\s\S]{0,1800}selFlush' 'SpringBoard 托管完成后未 flush CATransaction'
Reject-Text 'lara/kexploit/WZHUDBridge.mm' 'remote_host_context[\s\S]{0,2600}zeroFrame' '远程托管仍使用零尺寸 frame'
Require-Text 'lara/kexploit/wzesp.mm' 'publishedHeroIdentities[\s\S]{0,900}entity\.smoothingKey[\s\S]{0,180}insert\(entity\.smoothingKey\)\.second' '发布端未按 stable entity identity 去重'
Require-Text 'lara/kexploit/wzesp.mm' 'entity\.onScreen && entity\.valid1000' '直读坐标无效的英雄仍可发布屏幕绘制'

# ── 底层：allproc 是唯一必要符号，其余 base 项保持可选兼容 ──────────────
Reject-Text 'lara/kexploit/offsets.m' 'if \(\s*!kernproc\s*\|\|\s*!rootvnode\s*\)' 'resolvekernoffsets 仍硬要求 kernproc/rootvnode'
Reject-Text 'lara/kexploit/offsets.m' 'if \(\s*kernproc < gXPF\.kernelBase\s*\|\|\s*rootvnode < gXPF\.kernelBase\s*\)' '可选符号仍被当成无效即失败的门槛'
Require-Text 'lara/kexploit/offsets.m' 'if \(gXPF\.kernelBase == 0 \|\| allproc <= gXPF\.kernelBase\)[\s\S]{0,700}xpf_stop\(\);[\s\S]{0,80}return false;' 'allproc 缺失或非法时未停止 XPF 并失败返回'
Require-Text 'lara/kexploit/offsets.m' 'kernproc != 0 && kernproc >= gXPF\.kernelBase\)[\s\r\n]*\? kernproc - gXPF\.kernelBase : 0;' 'kernproc 偏移计算缺少防零值/下溢保护'
Require-Text 'lara/kexploit/offsets.m' 'rootvnode != 0 && rootvnode >= gXPF\.kernelBase\)[\s\r\n]*\? rootvnode - gXPF\.kernelBase : 0;' 'rootvnode 偏移计算缺少防零值/下溢保护'
Require-Text 'lara/kexploit/offsets.m' 'if \(kernprocoff != 0\)[\s\S]{0,180}setObject:@\(kernprocoff\)[\s\S]{0,180}else[\s\S]{0,120}removeObjectForKey:kkernprockey' 'kernproc 缺失时未清理陈旧 defaults'
Require-Text 'lara/kexploit/offsets.m' 'if \(rootvnodeoff != 0\)[\s\S]{0,180}setObject:@\(rootvnodeoff\)[\s\S]{0,180}else[\s\S]{0,120}removeObjectForKey:krootvnodekey' 'rootvnode 缺失时未清理陈旧 defaults'
Require-Text 'lara/kexploit/offsets.m' 'if \(procsize != 0\)[\s\S]{0,180}setObject:@\(procsize\)[\s\S]{0,180}else[\s\S]{0,120}removeObjectForKey:kkernprocsize' 'procsize 缺失时未清理陈旧 defaults'

# ── 底层：T1SZ_BOOT 首选 XPF，取不到交给实测校准（不得硬失败）──────────
Require-Text 'lara/kexploit/offsets.m' 'if \(resolvedt1szboot != 0\)[\s\S]{0,320}refreshpacmask\(\);' 'T1SZ_BOOT 未从 XPF 采纳'
Require-Text 'lara/kexploit/utils.m' 'void init_offsets\(void\)[\s\S]{0,1800}fixed structure offsets only' 'init_offsets 缺少单一 XPF 生命周期说明'
$utilsSource = Get-Content -Raw 'lara/kexploit/utils.m'
$initOffsetsMatch = [regex]::Match(
    $utilsSource,
    'void init_offsets\(void\)\s*\{(?<body>[\s\S]*?)\n\}',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
if (-not $initOffsetsMatch.Success) {
    throw '无法提取 init_offsets 函数体'
}
if ($initOffsetsMatch.Groups['body'].Value -match 'xpf_start_with_kernel_path\s*\(') {
    throw 'init_offsets 不得启动 XPF；resolvekernoffsets 必须独占 XPF 生命周期'
}
Require-Text 'lara/kexploit/offsets.m' '交由 wz_calibrate_smr_boot\(\) 实测确定' 'XPF 取不到时未交给实测校准'
Reject-Text 'lara/kexploit/offsets.m' '\n\s*t1sz_boot = 0x1[19];' '仍保留按 CPU 家族猜的 t1sz_boot 静态兜底（真赋值，非注释）'
Reject-Text 'lara/kexploit/offsets.m' '拒绝以静态兜底值继续' 'offsets 仍在硬失败，会让 App 卡在偏移重试'
Require-Text 'lara/kexploit/offsets.m' '\(void\)isA16Above;' 'CPU 家族分类结果未明确标注为诊断用途'

# ── 底层：XPF 解析策略对齐 AX（正规字典入口优先，逐项仅作兜底）───────────
# AX 1.2.8 的公开入口和实现都是单参数；三参数新版会把 Lara 未初始化的
# x1/x2 当成 SPTM/TXM 路径并在启动时解引用。
Require-Text 'lara/headers/xpf.h' 'int xpf_start_with_kernel_path\(const char \*kernelPath\);' 'Lara 侧 XPF 声明不是 AX 单参数 ABI'
Require-Text 'vendor/XPF/src/xpf.h' 'int xpf_start_with_kernel_path\(const char \*kernelPath\);' 'vendor XPF 声明不是 AX 单参数 ABI'
Require-Text 'vendor/XPF/src/xpf.c' 'int xpf_start_with_kernel_path\(const char \*kernelPath\)[\s\r\n]*\{' 'vendor XPF 实现不是 AX 单参数 ABI'
foreach ($xpfSource in @(
    'lara/headers/xpf.h',
    'lara/kexploit/offsets.m',
    'lara/kexploit/utils.m',
    'vendor/XPF/src/xpf.h',
    'vendor/XPF/src/xpf.c',
    'vendor/XPF/src/cli/main.c'
)) {
    Reject-Text $xpfSource 'xpf_start_with_kernel_path\s*\([^\)\r\n]*,' '仍存在多参数 XPF 声明、实现或调用'
}
Require-Text 'scripts/build_ipa_wz.sh' '拒绝构建 ABI 混用产物' '出货构建未阻止 XPF 单/三参数 ABI 混用'
# App 直接读取导出的 gXPF。AX 1.2.8 是单 kernelcache 布局，firstItem/ignoreBaseSet
# 必须固定在 0x110/0x118，不能重新混入 SPTM/TXM 或其额外 section 字段。
foreach ($xpfHeader in @('lara/headers/xpf.h', 'vendor/XPF/src/xpf.h')) {
    Require-Text $xpfHeader 'kernelBootdataInit;[\s\S]{0,160}kernelAMFITextSection;[\s\S]{0,160}kernelAMFIStringSection;[\s\S]{0,160}kernelSandboxTextSection;[\s\S]{0,160}kernelSandboxStringSection;[\s\S]{0,160}kernelInfoPlistSection;[\s\S]{0,100}XPFItem \*firstItem;[\s\S]{0,100}bool ignoreBaseSet;' 'XPF 旧字段顺序与 AX 1.2.8 不一致'
    Reject-Text $xpfHeader 'kernelBootcodeSection|kernelSandboxAuthStubSection|kernelIOSurface(Text|String|OsLog)Section|decompressedSptm|decompressedTxm|sptm(Container|Base|TextSection|StringSection)|txm(Container|Base|TextSection|StringSection)' 'XPF 头仍含不属于 AX 1.2.8 ABI 的新版字段'
    Require-Text $xpfHeader 'offsetof\(XPF, firstItem\) == 0x110' '缺少 firstItem 0x110 编译期门禁'
    Require-Text $xpfHeader 'offsetof\(XPF, ignoreBaseSet\) == 0x118' '缺少 ignoreBaseSet 0x118 编译期门禁'
    Require-Text $xpfHeader 'sizeof\(XPF\) == 0x120' '缺少 XPF 0x120 编译期门禁'
}
foreach ($xpfProductionSource in @(
    'vendor/XPF/src/xpf.c',
    'vendor/XPF/src/common.c',
    'vendor/XPF/src/ppl.c',
    'vendor/XPF/Makefile'
)) {
    Reject-Text $xpfProductionSource 'xpf_sptm_txm_init|decompressedSptm|decompressedTxm|kernelBootcodeSection|kernelSandboxAuthStubSection|kernelIOSurface(Text|String|OsLog)Section' 'XPF 生产链仍含新版 SPTM/TXM 初始化或 section'
}
Require-Text 'vendor/XPF/src/common.c' 'pmap_asid_plru[\s\S]{0,500}if \(!stringInFuncAddr\)[\s\S]{0,260}arm_maxoffset' 'pmap_bootstrap 未保留 arm_maxoffset 兼容 fallback'
Require-Text 'vendor/XPF/src/xpf.c' 'void xpf_set_ignore_base_set\(bool val\)[\s\S]{0,100}gXPF\.ignoreBaseSet = val' 'ignoreBaseSet 写入未保留在旧 ABI 的 0x118 字段'
Require-Text 'tests/xpf_ax128_layout_test.c' 'offsetof\(XPF, firstItem\) == 0x110[\s\S]{0,160}offsetof\(XPF, ignoreBaseSet\) == 0x118[\s\S]{0,160}sizeof\(XPF\) == 0x120' '缺少独立 XPF ABI 编译测试'
Require-Text 'scripts/build_ipa_wz.sh' 'Lara 与 vendor/XPF 的 gXPF 结构布局不一致' '出货构建未阻止 gXPF 结构布局漂移'
Require-Text 'scripts/build_ipa_wz.sh' 'AX 1\.2\.8 firstItem ABI' '出货构建未编译 XPF ABI 门禁'
Require-Text 'scripts/build_ipa_wz.sh' 'required_offsets = \{[\s\S]{0,120}"_xpf_item_register": "0x110",[\s\S]{0,120}"_xpf_item_resolve": "0x110",[\s\S]{0,120}"_xpf_set_ignore_base_set": "0x118"' '出货构建未反汇编验证 gXPF 最终字段偏移'
Require-Text 'scripts/build_ipa_wz.sh' 'verify_xpf_binary_layout "\$XPF_DIR/output/ios/libxpf\.dylib"' '源码构建的 libxpf 未执行最终字段偏移验证'
Reject-Text 'scripts/build_ipa_wz.sh' 'XPF_EMBEDDED=|verify_xpf_binary_layout\s+"\$(BIN|XPF_EMBEDDED)"' '最终主 Mach-O 仍重复套用独立 dylib 的指令形态门禁'
Require-Text 'scripts/build_ipa_wz.sh' 'grep -a -q -- "arm_maxoffset" "\$BIN"[\s\S]{0,220}MAIN_SYMBOLS="\$\(xcrun nm -g "\$BIN"\)"[\s\S]{0,220}_xpf_start_with_kernel_path' '最终主 Mach-O 缺少 XPF marker 与静态链接符号门禁'
Require-Text 'lara/kexploit/xpfitems.m' 'static const char \*kAXSets\[\] = \{ "base", "translation", "physmap", NULL \}' '缺少 AX 的三组字典集合'
Require-Text 'lara/kexploit/xpfitems.m' 'xpf_construct_offset_dictionary\(kAXSets\)' '未走 XPF 正规字典入口'
Require-Text 'lara/kexploit/xpfitems.m' 'xpc_dictionary_get_uint64\(dict, "kernelConstant.T1SZ_BOOT"\)' '未从字典取 T1SZ_BOOT'
Require-Text 'lara/kexploit/xpfitems.m' '字典入口失败[\s\S]{0,220}回落到逐项解析' '字典失败后缺少明确的回落路径'
Require-Text 'lara/kexploit/xpfitems.m' 'xpfresetitems\(\);[\s\S]{0,400}xpf_item_resolve' '兜底逐项解析前未清缓存'
Reject-Text 'lara/kexploit/xpfitems.m' '\n\s*xpf_set_error\(""\);' '仍写入空错误串，会抹掉 finder 的真实原因（真调用，非注释）'
Require-Text 'lara/kexploit/xpfitems.m' '原因: %s' '缺少的 item 未带出 XPF 记录的原因'
# ── 底层：kernelcache 走 Partial 分段获取（对齐 AX），整包下载降为兜底 ─────
Require-Text 'lara/kexploit/Partial.h' '@interface Partial : NSObject' 'Partial 类未声明'
Require-Text 'lara/kexploit/Partial.h' '\+ \(instancetype\)partialZipWithURL:\(NSURL \*\)url error:\(NSError \*\*\)error' '缺少 Partial 构造入口'
Require-Text 'lara/kexploit/Partial.h' '- \(NSData \*\)getFileForPath:\(NSString \*\)path error:\(NSError \*\*\)error' '缺少 Partial 单成员取用入口'
Require-Text 'lara/kexploit/Partial.h' 'bool kc_resolve_firmware_url\(NSString \*\*urlOut\)' '缺少固件包 URL 解析入口'
Require-Text 'lara/kexploit/Partial.h' 'bool kc_fetch_kernelcache_by_range\(NSString \*outpath\)' '缺少分段获取入口'
Require-Text 'lara/kexploit/Partial.m' 'api\.appledb\.dev/ios/%@;%@\.json' '未使用 AppleDB 按 build 精确查询端点'
Require-Text 'lara/kexploit/Partial.m' 'sysctlbyname\("kern\.osversion"' '未取 kern.osversion 作为 build'
Require-Text 'lara/kexploit/Partial.m' 'kc_first_ipsw_url_in_object' '缺少 ipsw 链接提取'
Require-Text 'lara/kexploit/Partial.m' 'kc_pick_kernelcache_entry' '缺少 kernelcache 成员选择'
Require-Text 'lara/kexploit/Partial.m' 'bytes\[0\] != 0x30 \|\| bytes\[1\] != 0x84' '分段结果未按 im4p 校验'
Require-Text 'lara/kexploit/offsets.m' '#import "Partial\.h"' 'offsets.m 未引入 Partial'
Require-Text 'lara/kexploit/offsets.m' 'kc_fetch_kernelcache_by_range\(outpath\)[\s\S]{0,400}grab_kernelcache\(outpath\)' '整包下载未降级为分段失败后的兜底'
Write-Output 'PASS: WZ AX two-window static contracts present; build and device behavior remain unverified'
