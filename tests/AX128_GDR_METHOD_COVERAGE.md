# AX 1.2.8 gdr2sae1a 源级覆盖总表（不代表真机完全一致）

参考为原始 IPA 的 Payload/AX Pro.app/AX Pro，SHA256 cc947605b97b90d898e784bf73dcab120c44c9281299fe840285dd67dfec1fb4。

状态只表示源码/静态证据，不代表编译、真机或像素验证。equivalent 表示替代实现持有同语义状态，不表示同类名/同机器码。

前台可达性：drawInMTKView 0x1007864d4 → bnd4sfh5。applicationState=0 时 0x100792248 setRenderingWithCoreAnimation:NO → currentRenderPassDescriptor/currentDrawable → 0x10078cc9c presentDrawable → 0x10078c400 commit；applicationState=2 时 0x10078e604 MTK hidden → 0x10078e700 CA mode → 0x1007924c0 beginFrame → 0x10078ff44 endFrame。前台分支不是全局不可达，故不能写 not reachable。

| 地址 | 方法 | 状态 | 当前映射/差异 |
|---|---|---|---|
| 0x10076d234 | configureHostedBackgroundMetalLayer | equivalent | MTKView CAMetalLayer mask18/nextDrawableTimeout:YES |
| 0x1007723f0 | configureHostedBackgroundLayerHierarchy | implemented | ax_enable_hosted_layer；host/ancestor/window/root layer mask18 |
| 0x100774430 | initWithFrame: | equivalent | CA command pool、WZAXMetalRenderer/MTKView/queue、Dear ImGui 1.92.5 WIP context 与官方 Metal backend 初始化；Rajdhani Bold OTF 以 18px+默认 0x20..0xff glyph range 装载；WIP 快照固定为 `59db6ceeb15ea7b685c2564a7bc889fd5ba7eef9` |
| 0x100783c60 | didMoveToWindow | equivalent | 窗口安装路径configure_layer_renderer_main及方向同步；需设备检查 |
| 0x100784384 | mtkView:drawableSizeWillChange: | equivalent | MTK delegate接入；每帧从drawable及逻辑bounds计算NDC |
| 0x1007864d4 | drawInMTKView: | equivalent | WZAXMetalRenderer 固定 DeltaTime 后执行 ImGui NewFrame/Render，并由 ImGui_ImplMetal_RenderDrawData 提交 render encoder/drawable/command buffer |
| 0x100786f3c | renderFrameForBackgroundTick | equivalent | render_frame_main+CADisplayLink更新CA；未做设备调度比对 |
| 0x100788bf8 | bnd4sfh5 | equivalent | active 直接提交固定 snapshot 到 ImDrawList/Metal；inactive 单独走 UIKit/retained CA，不再把 CALayer/CGPath 反向转译到前台 |
| 0x100793890 | bg6dw1sf | equivalent | 前台从 snapshot 直接生成 Rect、Line、Image、Circle、Text、Arc 七类原语；世界框/射线/头像/技能/视野/HP/4组回城弧/固定slot野怪已接入 |
| 0x1007c6624 | QsqnWxfaw4:nhs3shtre: | equivalent | WZAXImageCache异步两类缓存、3次>1000字节、5秒失败退避 |
| 0x1007d1b08 | bny4sq1:nhs3shtre: | equivalent | imageForID:summoner:缓存查询及pending去重 |
| 0x1007d3070 | nhd32dgreq:heroID:nhs3shtre: | equivalent | 纹理按variant/key存储，清pending/retry |
| 0x1007d469c | atg3rh21d: | implemented | RGBA8Unorm/ShaderRead/bitmap16385/replaceRegion/UIImage关联 |
| 0x1007d735c | pv6t4k8x2n | implemented | FBSOrientationObserver/setHandler NSInvocation；main读取update orientation/duration |
| 0x1007dd67c | synchronizeActiveOrientation | equivalent | activeInterfaceOrientation NSInvocation；apply_orientation_main |
| 0x1007e0ca4 | scheduleOrientationSynchronizationAfterAppSwitch | implemented | 0.15/0.65/1.5秒重试 |
| 0x1007e2548 | applicationDidEnterBackgroundForOrientation: | equivalent | 保持context，调度方向重试和后台显示帧 |
| 0x1007e29e8 | applicationDidBecomeActiveForRendering: | equivalent | scene active恢复60Hz统一displayLink；Metal显示、CA隐藏 |
| 0x1007e2fc0 | jq9m5w3h7k:animateWithDuration: | implemented | orientation去重/bounds更新/旋转duration/hidden直到completion |
| 0x1007e5fe4 | kt4p8n2w6x | implemented | observer非空时不重复安装 |
| 0x1007e68c0 | hn7j3m9t5v | implemented | invalidate后置nil |
| 0x1007e6e78 | dealloc | equivalent | displayLink invalidate、observer invalidate、ARC缓存/renderer释放 |
| 0x1007e8dc8 | mtkView | equivalent | WZAXMetalRenderer.view（强引用） |
| 0x1007e965c | setMtkView: | equivalent | WZAXMetalRenderer._view初始化/ARC销毁 |
| 0x1007e9df0 | device | equivalent | WZAXImageCache._device |
| 0x1007ea6b4 | setDevice: | equivalent | WZAXImageCache._device |
| 0x1007ead2c | XTELkrUMOa | equivalent | WZAXMetalRenderer._commandQueue |
| 0x1007eb2d4 | setXTELkrUMOa: | equivalent | newCommandQueue强引用/ARC生命周期 |
| 0x1007eb6a4 | KEZgpJxG2C | equivalent | g_displayLink |
| 0x1007ebf2c | setKEZgpJxG2C: | equivalent | g_displayLink |
| 0x1007ec888 | GZYY14bTff | equivalent | Metal初始化成功状态：g_metalRenderer非nil/pipeline非nil；init在10077b6d4发布 |
| 0x1007ec9cc | setGZYY14bTff: | equivalent | 初始化失败返回nil；成功发布renderer对象，与render-ready门限等价 |
| 0x1007ed270 | backgroundLayerRenderer | equivalent | g_layerRenderer |
| 0x1007ed9f4 | setBackgroundLayerRenderer: | equivalent | g_layerRenderer |
| 0x1007ede20 | renderingWithCoreAnimation | equivalent | g_sceneActive反值；present_layer_frame_main显式切双backend |
| 0x1007ee4a0 | setRenderingWithCoreAnimation: | equivalent | 切换Metal view hidden/CAroot visible，背景不申请drawable |
| 0x1007eed78 | nWcTe1g0B6 | equivalent | g_axOrientationObserver |
| 0x1007ef3fc | setNWcTe1g0B6: | equivalent | g_axOrientationObserver |
| 0x1007efae8 | FoVmbOTwYg | equivalent | g_orientation |
| 0x1007f00d8 | setFoVmbOTwYg: | equivalent | g_orientation |
| 0x1007f0720 | XlmGrRW4tK | equivalent | g_requested/g_active窗口生命周期门限 |
| 0x1007f0fb4 | setXlmGrRW4tK: | equivalent | g_requested/g_active窗口生命周期门限 |
| 0x1007f15a8 | hudPortraitSurfaceBounds | equivalent | hud_surface_bounds |
| 0x1007f1e7c | setHudPortraitSurfaceBounds: | equivalent | hud_surface_bounds |
| 0x1007f2228 | eRdrQswBmO | equivalent | _textures[0] hero |
| 0x1007f2b3c | setERdrQswBmO: | equivalent | _textures[0] hero |
| 0x1007f3144 | FckFwZ2ZVW | equivalent | _textures[1] summoner |
| 0x1007f3794 | setFckFwZ2ZVW: | equivalent | _textures[1] summoner |
| 0x1007f3ae4 | Sc14qyptly | equivalent | _pending[0] hero |
| 0x1007f4150 | setSc14qyptly: | equivalent | _pending[0] hero |
| 0x1007f47ec | KCb83SvbdO | equivalent | _pending[1] summoner |
| 0x1007f4da8 | setKCb83SvbdO: | equivalent | _pending[1] summoner |
| 0x1007f568c | EEGP2tzkDe | equivalent | _retryAfter[0] hero |
| 0x1007f59f0 | setEEGP2tzkDe: | equivalent | _retryAfter[0] hero |
| 0x1007f6108 | EN27oXx1ah | equivalent | _retryAfter[1] summoner |
| 0x1007f69e8 | setEN27oXx1ah: | equivalent | _retryAfter[1] summoner |
| 0x1007f7204 | .cxx_destruct | equivalent | ARC释放CA/Metal/view/queue/cache；MTKdelegate销毁前置nil |
| 0x100773e08 | bgh4fdqt | equivalent | 屏幕bounds创建hosted绘制根；原helper非singleton |

双后端等价边界：前台直接从 `wzesp_item_t` snapshot 生成 Dear ImGui 1.92.5 WIP draw-data，并使用官方 Metal backend（动态 font atlas、ImDrawVert 20 字节、ImDrawIdx 16 位、backend scissor/texture/pipeline/blend）；后台保留独立 UIKit/retained CA 消费。ImGui DeltaTime 固定为 0.01666666753590107，context/动画 Time 从 0 按该步长推进。参考二进制将版本锁到 `1.92.5 WIP`，并将 ABI 锁到 ImGuiIO `0xbd8`、ImGuiStyle `0x4ec`、ImDrawVert `0x14`、ImDrawIdx 2 字节和 ImTextureID 8 字节。当前固定官方提交 `59db6ceeb15ea7b685c2564a7bc889fd5ba7eef9`：它是上游加入会把 ImGuiStyle 增至 `0x508` 的 drag-drop 样式字段之前最后一个提交；vendored 文件均以 SHA256 门禁。仅凭 Mach-O 不能在所有相同 ABI 的早期 WIP 提交中反推出唯一源码提交。未进行 iOS 构建、真机或像素比对，equivalent 不代表像素完全一致。

野怪消费补证：0x1007ab460 对 slot 清低位，0x1007ab464/484/4a0 比较 18/16；19、20 条模拟记录均仅生成前16槽位图元。0/8蓝、4/12红，其余白；特殊点半径 mapsize/51+1，其余 mapsize/51。record+4 非0时改为 snprintf("%d")，0/4/8/12黄字、其余白字（0x1007acab4 固定黄色；0x1007ad314 使用分支颜色参数）。对 1、999、1000、-1 均观察到文字分支，无旧1..999门禁。文字位置为 minimap-(mapsize/52,mapsize/52)，字号 mapsize/26*1.9。实验仅桩化生产端刷新与外部UIKit调用，原绘制消费逻辑在Unicorn执行；不能代替真机绘制验证。
