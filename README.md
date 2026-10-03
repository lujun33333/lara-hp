# Core-SET 和平精英源码

这是 Core-SET v1.7 和平精英目标的 iOS 源码仓库。应用工程在 `lara.xcodeproj`，源码与应用资源在 `lara/`，武器图片在 `CoreSetWeaponIcons/`，权限配置在 `Config/`，构建所需第三方源码在 `vendor/`。

CI 使用 `.github/workflows/build.yml` 调用 `scripts/build_ipa_pe.sh`。该脚本在构建前编译 `scripts/build_support/xpf_layout_check.c`，校验 XPF 与应用头文件的布局。原生构建、包体和设备运行结果应分别以对应 CI 记录、产物及设备日志为准。

旧版 WZ/AX 测试、逆向工具和历史报告不参与当前构建，已从发布源码树移除；需要追溯时可从 Git 历史恢复。项目许可见 [LICENSE](LICENSE)，第三方许可保留在 `lara/licenses/` 和 `vendor/`。
