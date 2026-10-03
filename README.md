# Core-SET 和平界面对齐

当前参照样本是 `自签Core-SET和平-v1.7.ipa`。工程的应用 ID 已对齐 `qingxiugai.qingxiugai.qinxiugai`，版本为 1.7/build 1，最低系统为 iOS 17.0；这些是源码与构建合同，尚未生成新包验证。王者专用链已移除，普通启动目标改为和平精英：`ShadowTrackerExtra` / `com.tencent.tmgp.pubgmhd`。首页按钮使用游戏包已登记的 URL scheme 通过公开 UIKit API 打开应用；这不等于接入游戏数据或绘制功能。

当前逐控件差异、交互和验证边界见 [UI 功能点对点清单](artifacts/core-set-v1.7/UI功能点对点对齐.md)，七页可审查排版见 [源码交互预览](artifacts/core-set-v1.7/preview/index.html)。样本身份及版本差分见 [包体身份](artifacts/core-set-v1.7/package-identity.json)。旧逐项台账、清理说明和检查记录是对应阶段的快照。本轮没有生成新 IPA，也没有进行 iOS 原生构建或真机验证，不能声称像素一模一样。

## 当前界面能力

- 首页恢复原版六按钮／教程文案、透明命中范围、频谱／粒子／能量／音乐图标动画及已证音频参数；图片和字体保留原版资源。
- 应用内七页菜单：主页、玩家、物资、调整、雷达、自瞄、压枪；导航、暗黑／纯白主题、主题颜色编辑、七种主题预设、关闭菜单是本地交互。
- 游戏相关控件仍禁用；公告、工单、更新和授权服务未接入。
- 菜单恢复标题与正文分层、物资 3×2 复选框、横排选项按钮、分类标签与滑条；物资和自瞄的同名距离参数已分别处理。部分 UIKit 控件度量、原版样例图形和运行物资网格仍未闭合。
- 通用 Lara 工具代码保留，首页不再自动初始化游戏环境，也不依赖跨应用托管。

## 验证

源码与资源门禁：

```powershell
./tests/core_set_launcher_static_test.ps1
./tests/core_set_ui_static_test.ps1
python -B ./tests/core_set_wz_removal_test.py
python -B ./tests/core_set_package_resource_gate_test.py
```

构建入口为 `scripts/build_ipa_pe.sh`，CI 和测试引用已同步；产物清单使用和平目标，并拒绝旧王者对象、符号和资源。旧目标文档、AX 专用工具／二进制测试和无消费方的 Metal 工程引用已清理，指定原始文件均已备份；历史 Core-SET 证据和仍被当前构建消费的通用依赖保留。

## 来源与许可

本项目基于 [lara](https://github.com/rooootdev/lara) 的本地分支继续开发，原项目版权及许可见 [LICENSE](LICENSE)。
