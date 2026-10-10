import UIKit
import Darwin

struct CoreSetMenuHostSettings: Equatable {
    var menuVisible = false
    var floatingPalette: CoreSetFloatingPalette?
}

// MARK: - Core v1.7 ImGui model

extension CoreSetMenuViewController: CoreSetImGuiMenuModel {
    var imguiMenuModelRevision: UInt64 { hostedMenuRevision }

    private func imguiItem(_ type: String, _ title: String, _ action: String = "",
                           value: Any? = nil, minimum: Double? = nil, maximum: Double? = nil,
                           options: [String]? = nil, enabled: Bool = true) -> [String: Any] {
        var result: [String: Any] = ["type": type, "title": title, "action": action,
                                     "enabled": enabled]
        if let value { result["value"] = value }
        if let minimum { result["minimum"] = minimum }
        if let maximum { result["maximum"] = maximum }
        if let options { result["options"] = options }
        if type == "choice" {
            let color = featureState.home.desired.accent ?? CoreSetReferenceMenuAppearance.preset(6)
            result["accent"] = [color.red, color.green, color.blue, color.alpha]
        }
        return result
    }

    private func imguiSection(_ title: String, _ items: [[String: Any]]) -> [String: Any] {
        ["title": title, "items": items]
    }

    private func imguiChannelReady<Value: Equatable>(_ channel: CoreSetFeatureChannel<Value>) -> Bool {
        canStage(channel) && channel.pendingApply == nil && channel.pendingStop == nil
    }

    private func imguiStatus(_ title: String, _ text: String?) -> [String: Any] {
        ["type": "status", "title": title, "text": textValue(text), "action": "", "enabled": true]
    }

    private func imguiPresetIndex(_ color: CoreSetRGBA?) -> Int {
        guard let color else { return 6 }
        return (0..<7).first { CoreSetReferenceMenuAppearance.preset($0) == color.referenceOpaque } ?? 6
    }

    func imguiMenuSnapshot() -> [String: Any] {
        precondition(Thread.isMainThread)
        updateConsumerAvailability()
        let home = featureState.home.desired
        let accentValue = home.accent ?? CoreSetReferenceMenuAppearance.preset(6)
        let accent = [accentValue.red, accentValue.green, accentValue.blue, accentValue.alpha]
        let homeSnapshot = featureState.homeSnapshot
        let runValues: [CoreSetRunMode] = [.safe, .efficiency]
        let coverValues: [CoreSetCoverMode] = [.global, .inGame, .off]
        let homeItems: [[String: Any]] = [
            imguiItem("choice", "运行模式", "home.run", value: runValues.firstIndex(of: home.runMode ?? .safe) ?? 0,
                      options: ["安全", "效率"]),
            imguiItem("choice", "掩体判断", "home.cover", value: coverValues.firstIndex(of: home.coverMode ?? .off) ?? 2,
                      options: ["全局", "局内", "关闭"]),
            imguiItem("choice", "界面主题", "home.theme", value: home.theme == .light ? 1 : 0,
                      options: ["暗黑", "纯白"]),
            imguiItem("slider", "FPS 调节", "home.fps", value: featureState.frameRate.desired.framesPerSecond.value ?? 60,
                      minimum: 30, maximum: 144, enabled: imguiChannelReady(featureState.frameRate)),
            imguiItem("button", "内核利用", "home.kernel", enabled: !homeActionsInFlight.contains(.kernelAction)),
            imguiItem("button", "获取信息", "home.information", enabled: !homeActionsInFlight.contains(.informationAction))
        ]
        var statusItems: [[String: Any]] = []
        for item in [("内核状态", homeSnapshot?.kernel), ("运行环境", homeSnapshot?.environment),
                     ("获取信息状态", homeSnapshot?.information), ("当前阶段", homeSnapshot?.stage),
                     ("悬浮菜单", homeSnapshot?.floating)] {
            statusItems.append(imguiStatus(item.0, item.1))
        }

        let player = featureState.player.desired
        func actorItems(_ scope: CoreSetActorScope, _ state: CoreSetActorDisplay) -> [[String: Any]] {
            let prefix = scope == .player ? "player.player" : "player.bot"
            return [
                imguiItem("choice", "显示手持", "\(prefix).weapon", value: state.weapon.mode?.rawValue ?? 0,
                          options: ["图片", "文字"]),
                imguiItem("choice", "玩家数量", "\(prefix).count", value: state.count.mode == .detailed ? 0 : 1,
                          options: ["详细", "简洁"]),
                imguiItem("choice", "显示信息", "\(prefix).information", value: state.information.mode?.rawValue ?? 0,
                          options: ["现代", "精简"]),
                imguiItem("toggle", "显示射线", "\(prefix).ray", value: state.ray == true),
                imguiItem("toggle", "显示方框", "\(prefix).box", value: state.box == true),
                imguiItem("toggle", "显示距离", "\(prefix).distance", value: state.distance == true),
                imguiItem("toggle", "显示骨骼", "\(prefix).bones", value: state.bones == true)
            ]
        }
        let playerAdvanced: [[String: Any]] = [
            imguiItem("toggle", "隐藏人机", "player.hideBots", value: player.hideBots == true),
            imguiItem("toggle", "手雷预警", "player.grenade", value: player.grenadeWarning == true),
            imguiItem("choice", "背敌指示", "player.back", value: player.backIndicator?.rawValue ?? 2,
                      options: ["指示+距离", "指示", "关闭"]),
            imguiItem("slider", "绘制显示距离", "player.drawDistance", value: player.drawingDistance.value ?? 1,
                      minimum: 1, maximum: 1000),
            imguiItem("slider", "骨骼显示距离", "player.boneDistance", value: player.boneDistance.value ?? 1,
                      minimum: 1, maximum: 500),
            imguiItem("slider", "背敌指示大小", "player.backSize", value: player.backSize.value ?? 40,
                      minimum: 40, maximum: 160)
        ]

        let material = featureState.materials.desired
        let category = CoreSetMaterialCategory(rawValue: previewMaterialCategory) ?? .vehicles
        let materialState = material.categories[category.rawValue]
        var materialGroups = materialState.groups.enumerated().map { index, group in
            imguiItem("toggle", group.displayName, "material.group.\(index)", value: group.selection == .all)
        }
        materialGroups.insert(imguiItem("button", "本类全开", "material.allOn"), at: 0)
        materialGroups.insert(imguiItem("button", "本类全关", "material.allOff"), at: 1)
        let materialGeneral: [[String: Any]] = [
            imguiItem("toggle", "显示物资", "material.enabled", value: material.enabled == true),
            imguiItem("toggle", "持枪屏蔽物资", "material.hideArmed", value: material.hideWhileArmed == true),
            imguiItem("toggle", "地铁头甲", "material.metro", value: material.metroArmor == true),
            imguiItem("toggle", "隐藏已开启地铁箱子", "material.hideOpened", value: material.hideOpenedCrates == true),
            imguiItem("toggle", "显示地铁箱子等级", "material.crateLevel", value: material.showCrateLevel == true),
            imguiItem("toggle", "显示载具油量血量", "material.vehicle", value: material.vehicleStatus == true),
            imguiItem("choice", "物资分类", "material.category", value: category.rawValue,
                      options: CoreSetMaterialCategory.allCases.map(\.displayName)),
            imguiItem("slider", "最小距离", "material.minimum", value: materialState.distance.minimum ?? 0,
                      minimum: 0, maximum: 2000),
            imguiItem("slider", "最大距离", "material.maximum", value: materialState.distance.maximum ?? 2000,
                      minimum: 0, maximum: 2000),
            imguiItem("choice", "分类颜色", "material.color", value: imguiPresetIndex(materialState.color),
                      options: ["1", "2", "3", "4", "5", "6", "7"])
        ]

        let adjustment = featureState.adjustments.desired
        func colorItems(_ scope: CoreSetActorScope) -> [[String: Any]] {
            let prefix = scope == .player ? "adjust.player" : "adjust.bot"
            let colors = scope == .player ? adjustment.player : adjustment.bot
            let values = [colors.name, colors.ray, colors.distance, colors.bone, colors.team]
            return ["name", "ray", "distance", "bone", "team"].enumerated().map { index, field in
                imguiItem("choice", ["名称颜色", "射线颜色", "距离颜色", "骨骼颜色", "队伍颜色"][index],
                          "\(prefix).\(field)", value: imguiPresetIndex(values[index]),
                          options: ["1", "2", "3", "4", "5", "6", "7"])
            }
        }
        let adjustmentSizes: [[String: Any]] = [
            imguiItem("slider", "射线粗细", "adjust.rayThickness", value: adjustment.rayThickness.value ?? 1, minimum: 1, maximum: 10),
            imguiItem("slider", "骨骼粗细", "adjust.boneThickness", value: adjustment.boneThickness.value ?? 1, minimum: 1, maximum: 10),
            imguiItem("slider", "物资字体", "adjust.materialFont", value: adjustment.materialFontSize.value ?? 5, minimum: 5, maximum: 30)
        ]

        let radar = featureState.radar.desired
        let radarItems: [[String: Any]] = [
            imguiItem("toggle", "雷达", "radar.enabled", value: radar.enabled == true),
            imguiItem("toggle", "显示距离米数", "radar.distance", value: radar.showDistance == true),
            imguiItem("slider", "探测距离", "radar.detect", value: radar.detectionDistance.value ?? 100, minimum: 100, maximum: 1000),
            imguiItem("slider", "雷达半径", "radar.radius", value: radar.placement.radius ?? 80, minimum: 50, maximum: 300),
            imguiItem("slider", "雷达 X", "radar.x", value: radar.placement.x ?? 100, minimum: 0, maximum: Double(radar.placement.canvas?.width ?? 390)),
            imguiItem("slider", "雷达 Y", "radar.y", value: radar.placement.y ?? 100, minimum: 0, maximum: Double(radar.placement.canvas?.height ?? 844)),
            imguiItem("toggle", "被瞄预警", "radar.warning", value: radar.warningEnabled == true),
            imguiItem("toggle", "忽略人机", "radar.ignoreBots", value: radar.ignoreBots == true),
            imguiItem("slider", "被瞄预警范围", "radar.warningRange", value: radar.warningRange.value ?? 20, minimum: 20, maximum: 300),
            imguiItem("slider", "预警文字调节", "radar.warningText", value: radar.warningTextSize.value ?? 10, minimum: 10, maximum: 200)
        ]

        let aim = featureState.aim.desired
        let aimEditable = featureState.aim.phase != .applying && featureState.aim.phase != .active
        let aimMain: [[String: Any]] = [
            imguiItem("toggle", "自瞄总开关", "aim.enabled", value: aim.enabled == true, enabled: featureState.aim.restoration != .pending),
            imguiItem("toggle", "预瞄标记圈", "aim.preaim", value: aim.preaimCircle == true, enabled: aimEditable),
            imguiItem("toggle", "动态自瞄圈", "aim.dynamic", value: aim.dynamicCircle.enabled == true, enabled: aimEditable),
            imguiItem("toggle", "显示自瞄圈", "aim.circle", value: aim.showCircle == true, enabled: aimEditable),
            imguiItem("toggle", "自瞄连接线", "aim.line", value: aim.connectionLine == true, enabled: aimEditable),
            imguiItem("choice", "瞄准部位", "aim.point", value: aim.point?.rawValue ?? 0, options: ["头部", "胸部", "屁股"], enabled: aimEditable),
            imguiItem("choice", "触发模式", "aim.trigger", value: [CoreSetAimTrigger.scopeOnly, .fireOnly, .either, .both].firstIndex(of: aim.trigger ?? .either) ?? 2,
                      options: ["仅开镜", "仅开火", "开镜或开火", "开镜且开火"], enabled: aimEditable),
            imguiItem("slider", "自瞄圈大小", "aim.circleSize", value: aim.circleSize.value ?? 30, minimum: 30, maximum: 525, enabled: aimEditable),
            imguiItem("toggle", "倒地不瞄", "aim.knocked", value: aim.excludeKnocked == true, enabled: aimEditable),
            imguiItem("toggle", "瞄准人机", "aim.bots", value: aim.includeBots == true, enabled: aimEditable),
            imguiItem("toggle", "锁定同目标", "aim.lock", value: aim.lockSameTarget == true, enabled: aimEditable),
            imguiItem("choice", "场景", "aim.scene", value: [CoreSetAimScene.far, .general, .close, .custom].firstIndex(of: aim.scene ?? .far) ?? 0,
                      options: ["远距离", "通用", "近距离", "自定义"], enabled: aimEditable)
        ]
        var aimTuning: [[String: Any]] = []
        if aim.scene == .custom {
            aimTuning = [
                imguiItem("slider", "最大距离", "aim.maximum", value: aim.custom.maximumDistance.value ?? 10, minimum: 10, maximum: 500, enabled: aimEditable),
                imguiItem("slider", "自瞄强度", "aim.strength", value: aim.custom.strength.value ?? 5, minimum: 5, maximum: 100, enabled: aimEditable),
                imguiItem("slider", "转动平滑", "aim.smoothing", value: aim.custom.smoothing.value ?? 1, minimum: 1, maximum: 10, enabled: aimEditable),
                imguiItem("slider", "水平速度", "aim.horizontal", value: aim.custom.horizontalSpeed.value ?? 30, minimum: 30, maximum: 720, enabled: aimEditable),
                imguiItem("slider", "垂直速度", "aim.vertical", value: aim.custom.verticalSpeed.value ?? 30, minimum: 30, maximum: 720, enabled: aimEditable),
                imguiItem("slider", "预判提前", "aim.prediction", value: aim.custom.predictionMilliseconds.value ?? 0, minimum: 0, maximum: 300, enabled: aimEditable),
                imguiItem("slider", "锁定门槛", "aim.threshold", value: aim.custom.lockThreshold.value ?? 5, minimum: 5, maximum: 500, enabled: aimEditable),
                imguiItem("slider", "接管确认帧数", "aim.confirmation", value: aim.custom.confirmationFrames.value ?? 1, minimum: 1, maximum: 6, enabled: aimEditable),
                imguiItem("slider", "接管暂停", "aim.pause", value: aim.custom.takeoverPauseMilliseconds.value ?? 50, minimum: 50, maximum: 1000, enabled: aimEditable)
            ]
        } else {
            aimTuning = [imguiItem("choice", "锁定强度", "aim.lockStrength",
                value: [CoreSetLockStrength.strong, .medium, .light].firstIndex(of: aim.lockStrength ?? .light) ?? 2,
                options: ["强锁定", "中锁定", "轻锁定"], enabled: aimEditable)]
        }

        let recoil = featureState.recoil.desired
        let recoilItems: [[String: Any]] = [
            imguiItem("toggle", "启用压枪", "recoil.enabled", value: recoil.enabled == true),
            imguiItem("toggle", "停火不压", "recoil.stop", value: recoil.stopWhenNotFiring.enabled == true),
            imguiItem("toggle", "垂直补偿", "recoil.vertical", value: recoil.verticalEnabled == true),
            imguiItem("slider", "垂直补偿强度", "recoil.verticalStrength", value: recoil.verticalStrength.value ?? 0, minimum: 0, maximum: 100),
            imguiItem("toggle", "水平补偿", "recoil.horizontal", value: recoil.horizontalEnabled == true),
            imguiItem("slider", "水平补偿强度", "recoil.horizontalStrength", value: recoil.horizontalStrength.value ?? 0, minimum: 0, maximum: 100),
            imguiStatus("说明", "压枪并非无后坐力，是纯模拟压枪，远距离效果请实测")
        ]

        let pages: [[String: Any]] = [
            ["title": "主页", "sections": [imguiSection("内核管理", homeItems), imguiSection("状态", statusItems)]],
            ["title": "玩家", "sections": [imguiSection("玩家绘制", actorItems(.player, player.player)), imguiSection("人机绘制", actorItems(.bot, player.bot)), imguiSection("进阶设置", playerAdvanced)]],
            ["title": "物资", "sections": [imguiSection("物资管理", materialGeneral), imguiSection("物资筛选", materialGroups)]],
            ["title": "调整", "sections": [imguiSection("玩家颜色", colorItems(.player)), imguiSection("人机颜色", colorItems(.bot)), imguiSection("粗细调节", adjustmentSizes)]],
            ["title": "雷达", "sections": [imguiSection("雷达与预警", radarItems)]],
            ["title": "自瞄", "sections": [imguiSection("Core 稳定自瞄", aimMain), imguiSection("场景参数", aimTuning)]],
            ["title": "压枪", "sections": [imguiSection("Core 智能压枪【非无后坐力】", recoilItems)]]
        ]
        return ["selectedPage": selectedPage, "theme": home.theme?.rawValue ?? "dark",
                "accent": accent, "pages": pages]
    }

    private func textValue(_ value: String?) -> String { value ?? "unavailable" }

    private func performHomeActionFromImGui(_ point: CoreSetHomeProbePoint) -> Bool {
        guard !homeActionsInFlight.contains(point), let onHomeAction else { return false }
        homeActionsInFlight.insert(point); hostedMenuRevision &+= 1
        onHomeAction(point) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.homeActionsInFlight.remove(point)
                self.showConfigurationFeedback(error ?? "动作生产者已返回")
                self.rebuildMenu()
            }
        }
        return true
    }

    private func setActorField(_ scope: CoreSetActorScope, field: String, value: Double) {
        editGame(\.player) { state in
            func edit(_ actor: inout CoreSetActorDisplay) {
                switch field {
                case "weapon": if let mode = CoreSetWeaponMode(rawValue: Int(value)) { actor.weapon.select(mode) }
                case "count": actor.count.select(Int(value) == 0 ? .detailed : .compact)
                case "information": if let mode = CoreSetInformationMode(rawValue: Int(value)) { actor.information.select(mode) }
                case "ray": actor.ray = value != 0
                case "box": actor.box = value != 0
                case "distance": actor.distance = value != 0
                case "bones": actor.bones = value != 0
                default: break
                }
            }
            if scope == .player { edit(&state.player) } else { edit(&state.bot) }
        }
    }

    private func stopAimFromImGui() -> Bool {
        if featureState.aim.restoration.stopComplete {
            featureState.aim.updateDesired { $0.enabled = false }
            stagedConfigurationPaths.insert(\CoreSetFeatureState.aim)
            rebuildMenu()
            return true
        }
        guard let consumer = gameConsumers[\CoreSetFeatureState.aim] as? CoreSetMenuConsumer<CoreSetAimSettings>,
              let token = featureState.aim.prepareStop() else { return false }
        let source = interactionControlIdentifier
        consumer.stop(token) { [weak self] token, outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                let received = self.featureState.aim.receiveStop(token, outcome: outcome)
                if received && self.featureState.aim.restoration.stopComplete {
                    self.featureState.aim.updateDesired { $0.enabled = false }
                }
                NSLog("Core-SET: ImGui action stage=actual control=%@ capability=aimStop confirmed=%d",
                      source, received && self.featureState.aim.restoration.stopComplete ? 1 : 0)
                self.rebuildMenu()
            }
        }
        return true
    }

    func performImGuiMenuAction(_ action: String, value: Double) -> Bool {
        precondition(Thread.isMainThread)
        guard value.isFinite else { return false }
        interactionControlIdentifier = "ImGui.\(action)"
        if action == "page" {
            let page = Int(value.rounded())
            guard pageTitles.indices.contains(page) else { return false }
            selectedPage = page; rebuildMenu(); return true
        }
        if action == "close" {
            requestMenuVisibility(false) { [weak self] confirmed in
                if confirmed { self?.onClose?() }
            }
            return true
        }
        if action == "exit" { onExitHUD?(); return true }
        switch action {
        case "home.run":
            let values: [CoreSetRunMode] = [.safe, .efficiency]; guard values.indices.contains(Int(value)) else { return false }
            featureState.home.updateDesired { $0.runMode = values[Int(value)] }
        case "home.cover":
            let values: [CoreSetCoverMode] = [.global, .inGame, .off]; guard values.indices.contains(Int(value)) else { return false }
            featureState.home.updateDesired { $0.selectCoverMode(values[Int(value)]) }; onHomeProbeRefusal?(.coverMode, Int(value))
        case "home.theme":
            featureState.home.updateDesired { $0.theme = Int(value) == 1 ? .light : .dark }; applyLocalAppearance()
        case "home.fps": editGame(\.frameRate) { $0.framesPerSecond.set(Int(value.rounded())) }
        case "home.kernel": return performHomeActionFromImGui(.kernelAction)
        case "home.information": return performHomeActionFromImGui(.informationAction)
        case let key where key.hasPrefix("player.player."):
            setActorField(.player, field: String(key.dropFirst("player.player.".count)), value: value)
        case let key where key.hasPrefix("player.bot."):
            setActorField(.bot, field: String(key.dropFirst("player.bot.".count)), value: value)
        case "player.hideBots": editGame(\.player) { $0.hideBots = value != 0 }
        case "player.grenade": editGame(\.player) { $0.grenadeWarning = value != 0 }
        case "player.back": editGame(\.player) { $0.backIndicator = CoreSetBackIndicator(rawValue: Int(value)) }
        case "player.drawDistance": editGame(\.player) { $0.drawingDistance.set(Int(value.rounded())) }
        case "player.boneDistance": editGame(\.player) { $0.boneDistance.set(Int(value.rounded())) }
        case "player.backSize": editGame(\.player) { $0.backSize.set(Int(value.rounded())) }
        case "material.enabled": editGame(\.materials) { $0.enabled = value != 0 }
        case "material.hideArmed": editGame(\.materials) { $0.hideWhileArmed = value != 0 }
        case "material.metro": editGame(\.materials) { $0.metroArmor = value != 0 }
        case "material.hideOpened": editGame(\.materials) { $0.hideOpenedCrates = value != 0 }
        case "material.crateLevel": editGame(\.materials) { $0.showCrateLevel = value != 0 }
        case "material.vehicle": editGame(\.materials) { $0.vehicleStatus = value != 0 }
        case "material.category":
            guard CoreSetMaterialCategory(rawValue: Int(value)) != nil else { return false }
            previewMaterialCategory = Int(value); rebuildMenu()
        case "material.minimum": editGame(\.materials) { $0.editCategory(CoreSetMaterialCategory(rawValue: previewMaterialCategory) ?? .vehicles) { $0.distance.setMinimum(Int(value.rounded())) } }
        case "material.maximum": editGame(\.materials) { $0.editCategory(CoreSetMaterialCategory(rawValue: previewMaterialCategory) ?? .vehicles) { $0.distance.setMaximum(Int(value.rounded())) } }
        case "material.color": editGame(\.materials) { $0.editCategory(CoreSetMaterialCategory(rawValue: previewMaterialCategory) ?? .vehicles) { $0.color = CoreSetReferenceMenuAppearance.preset(max(0, min(6, Int(value)))) } }
        case "material.allOn", "material.allOff": editGame(\.materials) { $0.editCategory(CoreSetMaterialCategory(rawValue: previewMaterialCategory) ?? .vehicles) { $0.setAll(action == "material.allOn") } }
        case let key where key.hasPrefix("material.group."):
            guard let index = Int(key.dropFirst("material.group.".count)) else { return false }
            editGame(\.materials) { $0.editCategory(CoreSetMaterialCategory(rawValue: previewMaterialCategory) ?? .vehicles) { _ = $0.editGroup(at: index) { $0.toggle() } } }
        case "adjust.rayThickness": editGame(\.adjustments) { $0.rayThickness.set(Int(value.rounded())) }
        case "adjust.boneThickness": editGame(\.adjustments) { $0.boneThickness.set(Int(value.rounded())) }
        case "adjust.materialFont": editGame(\.adjustments) { $0.materialFontSize.set(Int(value.rounded())) }
        case let key where key.hasPrefix("adjust."):
            let parts = key.split(separator: "."); guard parts.count == 3 else { return false }
            let color = CoreSetReferenceMenuAppearance.preset(max(0, min(6, Int(value))))
            editGame(\.adjustments) { state in
                func set(_ target: inout CoreSetActorColors) {
                    switch parts[2] { case "name": target.name = color; case "ray": target.ray = color
                    case "distance": target.distance = color; case "bone": target.bone = color
                    case "team": target.team = color; default: break }
                }
                if parts[1] == "player" { set(&state.player) } else { set(&state.bot) }
            }
        case "radar.enabled": editGame(\.radar) { $0.enabled = value != 0 }
        case "radar.distance": editGame(\.radar) { $0.showDistance = value != 0 }
        case "radar.detect": editGame(\.radar) { $0.detectionDistance.set(Int(value.rounded())) }
        case "radar.warning": editGame(\.radar) { $0.warningEnabled = value != 0 }
        case "radar.ignoreBots": editGame(\.radar) { $0.ignoreBots = value != 0 }
        case "radar.warningRange": editGame(\.radar) { $0.warningRange.set(Int(value.rounded())) }
        case "radar.warningText": editGame(\.radar) { $0.warningTextSize.set(Int(value.rounded())) }
        case "radar.radius", "radar.x", "radar.y":
            editGame(\.radar) { state in
                if state.placement.canvas == nil { state.placement.refreshCanvas(CoreSetRadarCanvas(nativeWidth: 390, nativeHeight: 844, displayWidth: 390, displayHeight: 844)) }
                if action == "radar.radius" { state.placement.setRadius(Int(value.rounded())) }
                else if action == "radar.x" { state.placement.setX(Int(value.rounded())) }
                else { state.placement.setY(Int(value.rounded())) }
            }
        case "aim.enabled":
            if featureState.aim.desired.enabled == true { return stopAimFromImGui() }
            else { editGame(\.aim) { $0.enabled = true } }
        case "aim.preaim": featureState.aim.updateDesired { $0.preaimCircle = value != 0 }
        case "aim.dynamic": featureState.aim.updateDesired { $0.dynamicCircle.enabled = value != 0 }
        case "aim.circle": featureState.aim.updateDesired { $0.showCircle = value != 0 }
        case "aim.line": featureState.aim.updateDesired { $0.connectionLine = value != 0 }
        case "aim.point": featureState.aim.updateDesired { $0.point = CoreSetAimPoint(rawValue: Int(value)) }
        case "aim.trigger":
            let values: [CoreSetAimTrigger] = [.scopeOnly, .fireOnly, .either, .both]; guard values.indices.contains(Int(value)) else { return false }
            featureState.aim.updateDesired { $0.trigger = values[Int(value)] }
        case "aim.circleSize": featureState.aim.updateDesired { $0.circleSize.set(Int(value.rounded())) }
        case "aim.knocked": featureState.aim.updateDesired { $0.excludeKnocked = value != 0 }
        case "aim.bots": featureState.aim.updateDesired { $0.includeBots = value != 0 }
        case "aim.lock": featureState.aim.updateDesired { $0.lockSameTarget = value != 0 }
        case "aim.scene":
            let values: [CoreSetAimScene] = [.far, .general, .close, .custom]; guard values.indices.contains(Int(value)) else { return false }
            featureState.aim.updateDesired { $0.scene = values[Int(value)] }
        case "aim.lockStrength":
            let values: [CoreSetLockStrength] = [.strong, .medium, .light]; guard values.indices.contains(Int(value)) else { return false }
            featureState.aim.updateDesired { $0.lockStrength = values[Int(value)] }
        case "aim.maximum": featureState.aim.updateDesired { $0.custom.maximumDistance.set(Int(value.rounded())) }
        case "aim.strength": featureState.aim.updateDesired { $0.custom.strength.set(Int(value.rounded())) }
        case "aim.smoothing": featureState.aim.updateDesired { $0.custom.smoothing.set(Int(value.rounded())) }
        case "aim.horizontal": featureState.aim.updateDesired { $0.custom.horizontalSpeed.set(Int(value.rounded())) }
        case "aim.vertical": featureState.aim.updateDesired { $0.custom.verticalSpeed.set(Int(value.rounded())) }
        case "aim.prediction": featureState.aim.updateDesired { $0.custom.predictionMilliseconds.set(Int(value.rounded())) }
        case "aim.threshold": featureState.aim.updateDesired { $0.custom.lockThreshold.set(Int(value.rounded())) }
        case "aim.confirmation": featureState.aim.updateDesired { $0.custom.confirmationFrames.set(Int(value.rounded())) }
        case "aim.pause": featureState.aim.updateDesired { $0.custom.takeoverPauseMilliseconds.set(Int(value.rounded())) }
        case "recoil.enabled": editGame(\.recoil) { $0.enabled = value != 0 }
        case "recoil.stop": editGame(\.recoil) { $0.stopWhenNotFiring.enabled = value != 0 }
        case "recoil.vertical": editGame(\.recoil) { $0.verticalEnabled = value != 0 }
        case "recoil.verticalStrength": editGame(\.recoil) { $0.verticalStrength.set(Int(value.rounded())) }
        case "recoil.horizontal": editGame(\.recoil) { $0.horizontalEnabled = value != 0 }
        case "recoil.horizontalStrength": editGame(\.recoil) { $0.horizontalStrength.set(Int(value.rounded())) }
        default: return false
        }
        if action.hasPrefix("aim.") && action != "aim.enabled" {
            stagedConfigurationPaths.insert(\CoreSetFeatureState.aim)
            configurationSources[\CoreSetFeatureState.aim] = interactionControlIdentifier
        }
        rebuildMenu()
        return true
    }
}

private struct CoreSetMenuAppearance: Equatable {
    var theme: CoreSetTheme
    var accent: CoreSetRGBA
    var floatingPalette: CoreSetFloatingPalette
}

private struct CoreSetDirectoryPresentation: Equatable {
    var category: CoreSetMaterialCategory
    var selections: [CoreSetGroupSelection]
    var tint: CoreSetRGBA
}

// Retains the actual consumer. FeatureChannel itself deliberately uses weak ownership.
private final class CoreSetMenuConsumer<Value: Equatable>: CoreSetFeatureConsumer {
    // Swift 6.3's EarlyPerfInliner crashes in this generic isolated destructor.
    // Keep actor isolation and normal stored-property cleanup; skip only its SIL optimization.
    @_optimize(none)
    deinit {}

    typealias State = Value
    let capability: CoreSetCapability
    private let readiness: () -> CoreSetAvailability
    private let fields: () -> Set<CoreSetField>
    private let configurationFields: () -> Set<CoreSetField>
    private let applyBody: (CoreSetApplyRequest<Value>, @escaping (CoreSetRequestToken, CoreSetApplyOutcome<Value>) -> Void) -> Void
    private let stopBody: (CoreSetRequestToken, @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) -> Void
    var availability: CoreSetAvailability { readiness() }
    var supportedFields: Set<CoreSetField> { fields() }
    var configurableFields: Set<CoreSetField> { configurationFields() }
    init<C: CoreSetFeatureConsumer>(_ consumer: C) where C.State == Value {
        capability = consumer.capability
        readiness = { consumer.availability }
        fields = { consumer.supportedFields }
        configurationFields = { consumer.configurableFields }
        applyBody = { consumer.apply($0, completion: $1) }
        stopBody = { consumer.stop($0, completion: $1) }
    }
    init(capability: CoreSetCapability, readiness: @escaping () -> CoreSetAvailability,
         apply: @escaping (CoreSetApplyRequest<Value>, @escaping (CoreSetRequestToken, CoreSetApplyOutcome<Value>) -> Void) -> Void,
         stop: @escaping (CoreSetRequestToken, @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) -> Void) {
        self.capability = capability; self.readiness = readiness; fields = { [] }; configurationFields = { [] }
        applyBody = apply; stopBody = stop
    }
    func apply(_ request: CoreSetApplyRequest<Value>, completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<Value>) -> Void) {
        applyBody(request, completion)
    }
    func stop(_ token: CoreSetRequestToken, completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        stopBody(token, completion)
    }
}

// Local presentation only. Reference geometry does not establish device pixel parity.
final class CoreSetMenuViewController: UIViewController, CoreSetHostedMenuTapConsumer, UIGestureRecognizerDelegate {
    // The production menu surface is a dedicated ImGui/Metal controller. This
    // object remains the typed feature-state owner only; when enabled it never
    // constructs or hit-tests the legacy UIKit menu tree.
    private var imguiRuntimeEnabled = false
    func enableImGuiRuntime() {
        precondition(Thread.isMainThread)
        imguiRuntimeEnabled = true
        hostedMenuRevision &+= 1
    }
    private weak var basicAimStatusLabel: UILabel?
    private var basicAimStatus = "基础模式待启动"
    func updateBasicAimStatus(_ status: String) {
        basicAimStatus = status
        if case .unavailable(let reason) = featureState.aim.availability {
            basicAimStatusLabel?.text = reason
        } else { basicAimStatusLabel?.text = status }
    }
    var onClose: (() -> Void)?
    var onExitHUD: (() -> Void)?
    var onHomeProbeRefusal: ((CoreSetHomeProbePoint, Int?) -> Void)?
    var onHomeAction: ((CoreSetHomeProbePoint, @escaping (String?) -> Void) -> Void)?
    private var homeActionsInFlight: Set<CoreSetHomeProbePoint> = []
    private var hostedExitAvailable = false
    func setHostedExitAvailable(_ available: Bool) {
        if hostedExitAvailable != available { panelLayoutViewport = .null }
        hostedExitAvailable = available
        if isViewLoaded {
            exitHUDButton.isHidden = !available
            view.setNeedsLayout()
        }
    }
    private(set) var featureState = CoreSetFeatureState()
    private var gameConsumers: [AnyKeyPath: AnyObject] = [:]
    private var stagedConfigurationPaths: Set<AnyKeyPath> = []
    private var stagedConfigurationReadiness: [AnyKeyPath: Bool] = [:]
    private var configurationSources: [AnyKeyPath: String] = [:]
    private var interactionControlIdentifier = "UIKit"
    private var controlProofCache: [String: String] = [:]
    private let configurationFeedbackLabel = UILabel()
    private var configurationFeedback = "配置选择须等待消费者回执后才生效"
    private var hostConsumer: CoreSetMenuConsumer<CoreSetMenuHostSettings>?
    private var hostChannel = CoreSetFeatureChannel(capability: .hostWindow, desired: CoreSetMenuHostSettings())
    private var lastHostAppliedToken: CoreSetRequestToken?
    private var appearanceConsumer: CoreSetMenuConsumer<CoreSetMenuAppearance>?
    private var directoryConsumer: CoreSetMenuConsumer<CoreSetDirectoryPresentation>?
    private var appearanceChannel: CoreSetFeatureChannel<CoreSetMenuAppearance>?
    private var directoryChannel: CoreSetFeatureChannel<CoreSetDirectoryPresentation>?

    private let themeKey = CoreSetReferenceMenuAppearance.themeKey
    private let legacyThemeKey = "core-set.menu.light"
    private let referenceSize = CGSize(width: 838, height: 535)
    // v1.7 custom child: visual top extends 23; requested child height trims 7.
    private let cardBodyOffset: CGFloat = 23
    private let cardBodyTrim: CGFloat = 7
    private var defaultAccent: UIColor { uiColor(CoreSetReferenceMenuAppearance.preset(6)) }
    private var accent: UIColor { featureState.home.desired.accent.map(uiColor) ?? defaultAccent }
    private let accentKey = CoreSetReferenceMenuAppearance.accentKey
    private let legacyAccentKey = "core-set.menu.accent-rgba"
    private func storedTheme() -> CoreSetTheme {
        if let number = UserDefaults.standard.object(forKey: themeKey) as? NSNumber {
            let value = number.intValue // Native NSNumber integerValue, then accepts only 0/1.
            return value == 1 ? .light : .dark
        }
        if UserDefaults.standard.object(forKey: themeKey) != nil { return .dark }
        return UserDefaults.standard.bool(forKey: legacyThemeKey) ? .light : .dark
    }
    private func storedPackedAccent() -> UInt32? {
        guard let number = UserDefaults.standard.object(forKey: accentKey) as? NSNumber else { return nil }
        guard number.doubleValue.isFinite else { return nil }
        return number.uint32Value // Native unsignedIntValue width/truncation; no Swift overflow cast.
    }
    private enum ColorRole: String, CaseIterable, Hashable {
        case name = "名称颜色", ray = "射线颜色", distance = "距离颜色", bone = "骨骼颜色", team = "队伍颜色"
    }
    private enum ColorScope { case player, bot }
    private enum ColorTarget: Hashable {
        case theme, player(ColorRole), bot(ColorRole), material(Int)
    }
    private final class ColorButton: UIButton { var colorTarget: ColorTarget? }
    private final class MaterialGroupButton: UIButton { var observedSelection = CoreSetGroupSelection.unknown }
    private final class UnavailableInfoButton: UIButton { weak var explainedView: UIView? }
    private let floatingThemeKey = "DSESPThemeColorV1"
    private let floatingThemeValues = [6, 4, 1, 0, 2, 3, 5]
    private var floatingThemeValue: Int {
        featureState.home.desired.floatingPalette?.rawValue ?? 5
    }
    private func storedFloatingThemeValue() -> Int {
        guard let number = UserDefaults.standard.object(forKey: floatingThemeKey) as? NSNumber else { return 5 }
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value, (0...6).contains(value) else { return 5 }
        return Int(value)
    }
    private let radarRangeRows = UIView()
    private var radarRangeCanvas: CoreSetRadarCanvas?
    private var performanceValueLabels: [UILabel] = []
    private weak var presentationRateLabel: UILabel?
    private var presentationProofSignature: String?
    private var performanceLogSignatures: [Int: String] = [:]
    private var homeStatusValueLabels: [String: UILabel] = [:]
    private var homeStatusProgressViews: [String: UIProgressView] = [:]
    private var homeStatusStructureSignature: String?
    private var pageContentOffsets: [Int: CGPoint] = [:]
    private var hostedPointerID: String?
    private var homeStatusNeedsRebuild = false
    private var homeFieldStateLogSignatures: [Int: String] = [:]
    private var hostedPaletteLogSignatures: [Int: String] = [:]
    private var homeStatusSnapshot: CoreSetHomeSnapshot? { featureState.homeSnapshot }
    func updateRuntimeObservations(_ observation: CoreSetHomeObservation, expectedHostGeneration: UInt64) {
        precondition(Thread.isMainThread)
        if let identity = observation.identity {
            let age = Date().timeIntervalSince(identity.observedAt)
            let old = featureState.homeObservationIdentity
            guard identity.hostGeneration == expectedHostGeneration, identity.sequence > 0, age >= 0, age <= 5,
                  old?.observerEpoch != identity.observerEpoch || identity.sequence > (old?.sequence ?? 0) else {
                NSLog("Core-SET: home-observation stage=rejected confirmed=0 reason=epoch/sequence/host-generation/freshness-mismatch"); return
            }
        }
        let changed = featureState.homeSnapshot != observation.snapshot ||
            featureState.homeObservationSupportedFields != observation.supportedFields ||
            featureState.homeObservationUnavailableReasons != observation.unavailableReasons ||
            featureState.homeObservationFieldIdentities.mapValues({ $0.observerEpoch }) != observation.fieldIdentities.mapValues({ $0.observerEpoch }) ||
            featureState.homeObservationIdentity?.hostGeneration != observation.identity?.hostGeneration
        featureState.homeSnapshot = observation.snapshot
        featureState.homeObservationIdentity = observation.identity
        featureState.homeObservationUnavailableReasons = observation.unavailableReasons
        featureState.homeObservationFieldIdentities = observation.fieldIdentities
        featureState.homeObservationSupportedFields = observation.supportedFields
        if changed {
            let fields: [(Int, CoreSetHomeObservationField)] = [(4, .kernel), (5, .environment), (6, .information), (7, .floating), (8, .stage), (9, .pageProgress), (10, .firmwareProgress)]
            for (point, field) in fields {
                let fieldIdentity = observation.fieldIdentities[field]
                let observed = observation.supportedFields.contains(field)
                let reason = observation.unavailableReasons[field] ?? (observed ? "matched-live-producer" : "field-producer-unconfirmed")
                let logSignature = "\(observed ? 1 : 0)|\(fieldIdentity?.observerEpoch.uuidString ?? "unavailable")|\(fieldIdentity?.hostGeneration ?? expectedHostGeneration)|\(reason)"
                if homeFieldStateLogSignatures[point] != logSignature {
                    homeFieldStateLogSignatures[point] = logSignature
                    NSLog("Core-SET: home-observation stage=field-state point=v17-%03d observed=%d observerEpoch=%@ sequence=%llu hostGeneration=%llu reason=%@ scope=typed-read-only-producer original-runtime-receipt=0 device-effect-verified=0",
                          point, observed ? 1 : 0,
                          fieldIdentity?.observerEpoch.uuidString ?? "unavailable", fieldIdentity?.sequence ?? 0,
                          fieldIdentity?.hostGeneration ?? expectedHostGeneration, reason)
                }
            }
        }
        guard changed else { return }
        if isViewLoaded && selectedPage == 0 {
            if hostedPointerID == nil {
                if !refreshHomeStatusLabels() { rebuildMenu() }
            }
            else { homeStatusNeedsRebuild = true }
        }
    }

    func updatePerformanceObservation(_ sample: CoreSetPerformanceSample?) {
        precondition(Thread.isMainThread)
        if let sample, sample.processID == getpid() {
            featureState.performanceSnapshot = CoreSetPerformanceSnapshot(
                processID: sample.processID, observedAt: sample.observedAt as Date,
                cpuPercent: sample.cpuValid ? sample.cpuPercent : nil,
                footprintMiB: sample.footprintValid ? sample.footprintMiB : nil,
                peakFootprintMiB: sample.peakValid ? sample.peakFootprintMiB : nil)
        } else { featureState.performanceSnapshot = nil }
        if isViewLoaded && selectedPage == 0 { refreshPerformanceLabels() }
    }
    func updatePresentedFrameObservation(_ observation: CoreSetPresentedFrameObservation?) {
        precondition(Thread.isMainThread)
        featureState.presentedFrameSnapshot = observation
        let signature = observation.map { "\($0.hostGeneration)/\($0.renderGeneration)/\($0.adapterEpoch)/\($0.sampleCount)/\($0.lastPresentedTime)" } ?? "unavailable"
        if signature != presentationProofSignature {
            presentationProofSignature = signature
            NSLog("Core-SET: presentation-cadence point=v17-029 observed=%d sample=%@ scope=actual-drawable-present-time-window requested-fps-input=0 original-runtime-receipt=0 device-effect-verified=0",
                  observation == nil ? 0 : 1, signature)
        }
        presentationRateLabel?.text = observation.map { String(format: "实测呈现 %.1f FPS · %llu 帧", $0.framesPerSecond, $0.sampleCount) } ?? "实测呈现 unavailable · 无新鲜 present 时间窗口"
    }
    // v1.7 palette bytes at file 0xac813c; swatch spacing is 7, not the selection helper's 6.
    private let presetRGB: [[CGFloat]] = [
        [174, 139, 148], [180, 85, 94], [68, 119, 168], [58, 133, 120],
        [126, 98, 171], [181, 86, 137], [56, 139, 155]
    ]
    private let panel = UIView()
    private let content = UIScrollView()
    private let closeButton = UIButton(type: .system)
    private let exitHUDButton = UIButton(type: .system)
    private var panelPlacementInitialized = false
    private var panelLayoutViewport = CGRect.null
    private var panelScale: CGFloat = 1
    private enum HostedAction: String {
        case close, exitHUD, page, theme, homeRunMode, homeCoverMode, homeKernelAction, homeInformationAction
        case boundRange, adjustmentRange, localAimCircleSize
        case localAimPreviewDistance, frameRate, warningRange, radarPlacement
        case backIndicator, playerWeaponMode, playerCountMode, playerInformationMode
        case playerField, localAimCircle, localAimPreviewField, materialEnabled
        case hideWhileArmed, metroArmor, hideOpenedCrates, crateLevel, vehicleStatus
        case radarField, warningField, presetColor, floatingColor, materialCategory
        case backStyle, previewScene, materialGroup, allMaterialGroups
        case aimTrigger, aimPoint, aimRange, aimBots, aimLock, aimLockStrength
        case aimStart, aimStop, aimChoice, aimConfigurationField, recoilField, recoilStrength, contentScroll, materialScroll
        case colorEditor, colorRed, colorGreen, colorBlue, colorAlpha, colorApply, colorCancel, unavailableInfo
        var allowsDrag: Bool { self == .contentScroll || self == .materialScroll || isSlider }
        var isSlider: Bool {
            switch self {
            case .boundRange, .adjustmentRange, .localAimCircleSize,
                 .localAimPreviewDistance, .frameRate, .warningRange,
                 .radarPlacement, .aimRange, .recoilStrength, .colorRed, .colorGreen,
                 .colorBlue, .colorAlpha: return true
            default: return false
            }
        }
        var isSegmented: Bool {
            switch self {
            case .aimTrigger, .aimPoint, .aimBots, .aimLock, .aimLockStrength: return true
            default: return false
            }
        }
    }
    private final class HostedEntry {
        weak var view: UIView?
        let identifier: String
        let action: HostedAction
        init(view: UIView, identifier: String, action: HostedAction) {
            self.view = view; self.identifier = identifier; self.action = action
        }
    }
    private var hostedEntries: [HostedEntry] = []
    private(set) var hostedMenuRevision: UInt64 = 0
    private var hostedScrollID: String?
    private var hostedScrollStart = CGPoint.zero
    private var hostedScrollOffset = CGPoint.zero
    private var hostedDispatchControlID: String?
    private var hostedSliderID: String?
    private weak var trackingUIKitSlider: UISlider?
    private var hostedSliderOriginalValue: Float = 0
    private var hostedColorOverlay: UIView?
    private var hostedColorCard: UIView?
    private var hostedColorPreview: UIView?
    private var hostedColorSliders: [UISlider] = []
    private var hostedColorApplyButton: UIButton?
    private var hostedColorCancelButton: UIButton?
    private var hostedColorTarget: ColorTarget?
    private func registerHosted(_ view: UIView, _ action: HostedAction,
                                field: CoreSetField? = nil, capability: CoreSetCapability? = nil) {
        // UIKit sliders also commit on release; rebuilding on each valueChanged
        // would destroy the control while the finger is still tracking it.
        if let slider = view as? UISlider,
           ![.colorRed, .colorGreen, .colorBlue, .colorAlpha].contains(action) {
            slider.isContinuous = false
            slider.addTarget(self, action: #selector(beginUIKitSliderTracking(_:)), for: .touchDown)
            slider.addTarget(self, action: #selector(endUIKitSliderTracking(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        let id = "p\(selectedPage).\(action.rawValue).\(view.tag).\(hostedEntries.count)"
        if view.accessibilityIdentifier == nil {
            if let field, let capability {
                let category = capability == .materialFiltering ? ".category\(previewMaterialCategory)" : ""
                view.accessibilityIdentifier = "core-set.\(selectedPage).\(capability.rawValue).\(field.diagnosticID).\(view.tag)\(category)"
            } else { view.accessibilityIdentifier = "core-set.\(selectedPage).\(action.rawValue).\(view.tag)" }
        }
        hostedEntries.append(HostedEntry(view: view, identifier: id, action: action))
        if let field, let capability { updateControlProof(view, field: field, capability: capability) }
    }

    private func updateControlProof(_ control: UIView, field: CoreSetField, capability: CoreSetCapability) {
        let value = control.accessibilityValue
        let unknown = value.map { text in ["未选择", "未知", "未验证"].contains { text.contains($0) } } ?? true
        let explicit: Bool
        if let segmented = control as? UISegmentedControl {
            explicit = segmented.selectedSegmentIndex != UISegmentedControl.noSegment
        } else {
            explicit = control.accessibilityTraits.contains(.selected) || (control as? UIButton)?.isSelected == true || !unknown
        }
        func proof<Value: Equatable>(_ channel: CoreSetFeatureChannel<Value>) -> (Bool, String) {
            guard explicit else { return (false, "该控件尚未明确选择参数；不能把其他字段回执归给此点") }
            if channel.isFieldDesiredConfirmed(field) { return (true, "消费者声明字段回执匹配") }
            if let reason = channel.observationInvalidationReason { return (false, "旧显示回执已撤销：\(reason)") }
            if case .unavailable(let reason) = channel.fieldAvailability(field) { return (false, reason) }
            return (false, "等待该字段实际回执")
        }
        let evidence: (Bool, String)
        switch capability {
        case .playerRendering: evidence = proof(featureState.player)
        case .materialFiltering: evidence = proof(featureState.materials)
        case .drawingAppearance: evidence = proof(featureState.adjustments)
        case .radarRendering: evidence = proof(featureState.radar)
        case .frameScheduling: evidence = proof(featureState.frameRate)
        case .aimControl: evidence = proof(featureState.aim)
        case .recoilControl: evidence = proof(featureState.recoil)
        case .localAimDisplay: evidence = proof(featureState.aimDisplay)
        default: evidence = (false, "未提供该能力的字段回执消费者")
        }
        let scope = capability == .localAimDisplay ? "替代预览，不算v1.7原效果" :
            (capability == .frameScheduling ? "Metal调度器参数回读；非实测呈现FPS" : "声明字段，本次未验证v1.7设备效果")
        let text = "配置：\(control.accessibilityValue ?? "未选择")；\(evidence.0 ? "回执匹配" : "效果未确认")；\(scope)"
        control.accessibilityValue = text
        let identifier = control.accessibilityIdentifier ?? "unknown"
        let status = "\(evidence.0):\(evidence.1)"
        if controlProofCache[identifier] != status {
            controlProofCache[identifier] = status
            NSLog("Core-SET: menu stage=field-state control=%@ capability=%@ field=%@ confirmed=%d scope=%@ reason=%@",
                  identifier, capability.rawValue, field.diagnosticID, evidence.0 ? 1 : 0, scope, evidence.1)
        }
    }
    // Read-only live views: the host converts hit coordinates through their
    // current transforms. No second copy of the reference geometry is exported.
    var localHostHitRegions: [UIView] { [panel, closeButton] }
    private let pageTitles = ["主页", "玩家", "物资", "调整", "雷达", "自瞄", "压枪"]
    private var pageViews: [UIView] = []
    private var pageButtons: [UIButton] = []
    private var fontCache: [CGFloat: UIFont] = [:]
    private var selectedPage = 0
    private var isLight: Bool { featureState.home.desired.theme == .light }
    private var isClosing = false
    // These selections belong only to this menu instance. They are neither
    // reference defaults nor game configuration and are never persisted.
    private var previewBackStyle: Int? { featureState.player.desired.backStyle?.rawValue }
    private var previewSceneValue: Int? { featureState.aim.desired.scene?.rawValue }
    private let scenarioValues = [0, 2, 1, 3]
    private let scenarioWidths: [CGFloat] = [60, 60, 60, 52]
    private var previewMaterialCategory = 0
    private let materialGrid = UIScrollView()
    private let materialGridItems = UIView()
    private let materialCategoryTitles = CoreSetMaterialCategory.allCases.map(\.displayName)
    // v1.7 static candidate display groups, not the runtime-filtered item list.
    private let materialCatalog = CoreSetMaterialCatalog.names
    // Native only draws these when the scene index is 3. Its current value is
    // unknown, so this UI inventory is not presented as a selected scene/default.
    private let conditionalScenarioRanges: [String: (Float, Float)] = [
        "水平速度": (30, 720), "垂直速度": (30, 720), "预判提前": (0, 300),
        "锁定门槛": (5, 500), "接管暂停": (50, 1000)
    ]

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .fullScreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let storedAccent = storedColor(forKey: accentKey).flatMap(rgba)
        let storedPalette = CoreSetFloatingPalette(rawValue: storedFloatingThemeValue())
        featureState.home.updateDesired {
            if $0.theme == nil { $0.theme = storedTheme() }
            if $0.accent == nil { $0.setAccent(storedAccent ?? rgba(defaultAccent)) }
            if $0.floatingPalette == nil { $0.floatingPalette = storedPalette }
        }
        view.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        panel.bounds = CGRect(origin: .zero, size: referenceSize)
        panel.layer.cornerRadius = 20
        panel.layer.borderWidth = 1
        panel.clipsToBounds = true
        view.addSubview(panel)
        let panelPan = UIPanGestureRecognizer(target: self, action: #selector(moveReferencePanel(_:)))
        panelPan.cancelsTouchesInView = false
        panelPan.delegate = self
        panel.addGestureRecognizer(panelPan)
        closeButton.setTitle("×", for: .normal)
        closeButton.titleLabel?.font = font(28)
        closeButton.accessibilityLabel = "关闭菜单"
        closeButton.addTarget(self, action: #selector(closeMenu), for: .touchUpInside)
        view.addSubview(closeButton)
        exitHUDButton.setTitle("退出 HUD", for: .normal)
        exitHUDButton.accessibilityLabel = "退出 HUD 并注销悬浮窗口"
        exitHUDButton.titleLabel?.font = font(15)
        exitHUDButton.layer.cornerRadius = 6
        exitHUDButton.addTarget(self, action: #selector(exitHUDTapped), for: .touchUpInside)
        exitHUDButton.isHidden = !hostedExitAvailable
        rebuildMenu()
        configureLocalConsumers()
        CoreSetWeaponImageCatalog.prepare { [weak self] _ in
            guard let self, self.isViewLoaded else { return }
            self.rebuildMenu()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        CoreSetWeaponImageCatalog.prepare { [weak self] _ in
            guard let self, self.isViewLoaded else { return }
            self.rebuildMenu()
        }
        appearanceChannel?.refreshAvailability()
        directoryChannel?.refreshAvailability()
        rebuildMenu()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Core draws the 838x535 reference window from the hosted surface's
        // display bounds.  A controller first lays out in the launcher's
        // portrait scene, then receives the game's landscape bounds.  Keeping
        // that old absolute centre clamps the window against the landscape
        // left edge.  Re-seed the centre whenever the source viewport changes;
        // dragging remains stable while the viewport itself is unchanged.
        let viewport = hostedExitAvailable ? view.bounds : view.bounds.inset(by: view.safeAreaInsets)
        let scale = min(1, min(max(1, viewport.width - 16) / referenceSize.width,
                               max(1, viewport.height - 16) / referenceSize.height))
        panelScale = scale
        panel.bounds = CGRect(origin: .zero, size: referenceSize)
        panel.transform = CGAffineTransform(scaleX: scale, y: scale)
        let viewportChanged = panelLayoutViewport != viewport
        if !panelPlacementInitialized || viewportChanged {
            panel.center = CGPoint(x: viewport.midX, y: viewport.midY)
            panelPlacementInitialized = true
            panelLayoutViewport = viewport
        }
        panel.center = clampedPanelCenter(panel.center, in: viewport, scale: scale)
        // Keep the ordinary modal close target usable when the reference panel scales down.
        closeButton.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        let closeCenter = CGPoint(x: panel.center.x + (818 - referenceSize.width / 2) * scale,
                                  y: panel.center.y + (20 - referenceSize.height / 2) * scale)
        closeButton.center = CGPoint(x: min(viewport.maxX - 22, max(viewport.minX + 22, closeCenter.x)),
                                     y: min(viewport.maxY - 22, max(viewport.minY + 22, closeCenter.y)))
        hostedColorOverlay?.frame = view.bounds
        hostedColorCard?.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if selectedPage == 4 { refreshRadarRangeRows() }
    }

    private func clampedPanelCenter(_ proposed: CGPoint, in safe: CGRect, scale: CGFloat) -> CGPoint {
        let halfWidth = referenceSize.width * scale / 2
        let halfHeight = referenceSize.height * scale / 2
        let x = safe.width < halfWidth * 2 ? safe.midX : min(safe.maxX - halfWidth, max(safe.minX + halfWidth, proposed.x))
        let y = safe.height < halfHeight * 2 ? safe.midY : min(safe.maxY - halfHeight, max(safe.minY + halfHeight, proposed.y))
        return CGPoint(x: x, y: y)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let point = pan.location(in: panel)
        // Core's ImGui window is movable; reserve the title/brand area so page
        // controls keep their original hit behavior.
        return point.x >= 0 && point.x <= 160 && point.y >= 0 && point.y <= 104
    }

    @objc private func moveReferencePanel(_ sender: UIPanGestureRecognizer) {
        guard sender.state == .began || sender.state == .changed else { return }
        let translation = sender.translation(in: view)
        let viewport = hostedExitAvailable ? view.bounds : view.bounds.inset(by: view.safeAreaInsets)
        panel.center = clampedPanelCenter(
            CGPoint(x: panel.center.x + translation.x, y: panel.center.y + translation.y),
            in: viewport, scale: panelScale)
        sender.setTranslation(.zero, in: view)
        view.setNeedsLayout()
    }

    private func font(_ size: CGFloat) -> UIFont {
        if let cached = fontCache[size] { return cached }
        let value = UIFont(name: "OPPOSans-H", size: size) ?? .systemFont(ofSize: size)
        fontCache[size] = value
        return value
    }

    private func gray(_ dark: CGFloat, _ light: CGFloat) -> UIColor {
        UIColor(white: (isLight ? light : dark) / 255, alpha: 1)
    }

    private func label(_ text: String, size: CGFloat, frame: CGRect,
                       secondary: Bool = false) -> UILabel {
        let result = UILabel(frame: frame)
        result.text = text
        result.font = font(size)
        result.textColor = secondary ? gray(105, 160) : gray(255, 80)
        return result
    }

    private func rebuildMenu(preservingCurrentOffset: Bool = true) {
        if imguiRuntimeEnabled {
            hostedMenuRevision &+= 1
            homeStatusNeedsRebuild = false
            return
        }
        if hostedPointerID != nil || hostedDispatchControlID != nil || trackingUIKitSlider != nil {
            homeStatusNeedsRebuild = true
            return
        }
        if preservingCurrentOffset { pageContentOffsets[selectedPage] = content.contentOffset }
        hostedPointerID = nil
        homeStatusNeedsRebuild = false
        hostedMenuRevision &+= 1
        hostedEntries.removeAll()
        hostedScrollID = nil
        hostedSliderID = nil
        performanceValueLabels.removeAll()
        homeStatusValueLabels.removeAll()
        homeStatusProgressViews.removeAll()
        homeStatusStructureSignature = nil
        radarRangeCanvas = nil
        registerHosted(closeButton, .close)
        updateConsumerAvailability()
        panel.subviews.forEach { $0.removeFromSuperview() }
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews.removeAll()
        pageButtons.removeAll()
        panel.backgroundColor = gray(26, 250)
        panel.layer.borderColor = gray(50, 215).cgColor
        closeButton.setTitleColor(gray(255, 80), for: .normal)
        let sidebar = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 535))
        sidebar.backgroundColor = gray(32, 240)
        panel.addSubview(sidebar)
        let divider = UIView(frame: CGRect(x: 160, y: 0, width: 1, height: 535))
        divider.backgroundColor = gray(50, 215)
        panel.addSubview(divider)
        addReferenceBrand(to: sidebar)

        let groupY: [CGFloat] = [104, 183, 376]
        for (index, title) in ["初始化", "视觉", "战斗"].enumerated() {
            sidebar.addSubview(label(title, size: 17,
                                     frame: CGRect(x: 13, y: groupY[index], width: 134, height: 24),
                                     secondary: true))
        }
        let navY: [CGFloat] = [132, 211, 249, 287, 325, 404, 442]
        for (index, title) in pageTitles.enumerated() {
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 13, y: navY[index], width: 135, height: 35)
            button.tag = index
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = font(19)
            button.layer.cornerRadius = 5
            button.backgroundColor = selectedPage == index ? accent : .clear
            button.setTitleColor(selectedPage == index ? .white : gray(255, 80), for: .normal)
            button.accessibilityTraits = selectedPage == index ? [.button, .selected] : .button
            button.addTarget(self, action: #selector(selectPage(_:)), for: .touchUpInside)
            sidebar.addSubview(button)
            pageButtons.append(button)
            registerHosted(button, .page)
        }
        content.frame = CGRect(x: 170, y: 38, width: 658, height: 492)
        content.contentSize = CGSize(width: 658, height: 492)
        content.contentOffset = .zero
        content.backgroundColor = .clear
        content.showsHorizontalScrollIndicator = false
        content.showsVerticalScrollIndicator = true
        content.clipsToBounds = false
        panel.addSubview(content)
        registerHosted(content, .contentScroll)
        rebuildPage()
        content.layoutIfNeeded()
        let offset = pageContentOffsets[selectedPage] ?? .zero
        content.contentOffset = CGPoint(
            x: min(max(0, offset.x), max(0, content.contentSize.width - content.bounds.width)),
            y: min(max(0, offset.y), max(0, content.contentSize.height - content.bounds.height)))
        registerHostedColorEditor()
        installUnavailableFeedback(in: panel)
    }

    private func addReferenceBrand(to sidebar: UIView) {
        let large = font(36)
        let small = font(11)
        let cWidth = ceil(("C" as NSString).size(withAttributes: [.font: large]).width)
        let oreWidth = ceil(("ORE" as NSString).size(withAttributes: [.font: large]).width)
        let setWidth = ceil(("SET" as NSString).size(withAttributes: [.font: small]).width)
        let largeGap: CGFloat = 6
        let smallGap: CGFloat = 3.5
        let total = cWidth + oreWidth + largeGap + smallGap * 2 + setWidth
        var x = (160 - total) / 2
        let c = label("C", size: 36, frame: CGRect(x: x, y: 35, width: cWidth, height: 48))
        c.textColor = accent
        sidebar.addSubview(c)
        x += cWidth + smallGap
        let ore = label("ORE", size: 36, frame: CGRect(x: x, y: 35, width: oreWidth, height: 48))
        ore.textColor = accent
        sidebar.addSubview(ore)
        x += oreWidth + largeGap + smallGap
        let set = label("SET", size: 11, frame: CGRect(x: x, y: 55, width: setWidth, height: 16))
        set.textColor = accent
        sidebar.addSubview(set)
    }

    private func rebuildCurrentPage() {
        if imguiRuntimeEnabled {
            hostedMenuRevision &+= 1
            homeStatusNeedsRebuild = false
            return
        }
        guard hostedPointerID == nil, hostedDispatchControlID == nil,
              trackingUIKitSlider == nil else {
            homeStatusNeedsRebuild = true
            return
        }
        hostedMenuRevision &+= 1
        homeStatusNeedsRebuild = false
        performanceValueLabels.removeAll()
        homeStatusValueLabels.removeAll()
        homeStatusProgressViews.removeAll()
        homeStatusStructureSignature = nil
        radarRangeCanvas = nil
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews.removeAll()
        hostedEntries = hostedEntries.filter { entry in
            guard let view = entry.view else { return false }
            return view === closeButton || view === exitHUDButton || view === content ||
                pageButtons.contains(where: { $0 === view })
        }
        for (index, button) in pageButtons.enumerated() {
            let selected = index == selectedPage
            button.backgroundColor = selected ? accent : .clear
            button.setTitleColor(selected ? .white : gray(255, 80), for: .normal)
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
        updateConsumerAvailability()
        content.contentOffset = .zero
        content.contentSize = CGSize(width: 658, height: 492)
        rebuildPage()
        content.layoutIfNeeded()
        let offset = pageContentOffsets[selectedPage] ?? .zero
        content.contentOffset = CGPoint(
            x: min(max(0, offset.x), max(0, content.contentSize.width - content.bounds.width)),
            y: min(max(0, offset.y), max(0, content.contentSize.height - content.bounds.height)))
        registerHostedColorEditor()
        installUnavailableFeedback(in: panel)
    }

    @objc private func selectPage(_ sender: UIButton) {
        guard pageTitles.indices.contains(sender.tag) else { return }
        if hostedColorOverlay != nil { dismissHostedColorEditor() }
        pageContentOffsets[selectedPage] = content.contentOffset
        selectedPage = sender.tag
        rebuildCurrentPage()
        NSLog("Core-SET: hosted input stage=actual capability=menuPage page=%ld confirmed=%d",
              selectedPage, pageViews.isEmpty ? 0 : 1)
    }

    @objc private func selectTheme(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard localAppearanceReady, (0...1).contains(sender.tag) else { return }
        featureState.home.updateDesired { $0.theme = sender.tag == 1 ? .light : .dark }
        applyLocalAppearance()
    }

    func hostedControlID(at point: CGPoint) -> String? {
        precondition(Thread.isMainThread)
        guard presentedViewController == nil, isViewLoaded, view.window != nil,
              let hit = view.hitTest(point, with: nil) else { return nil }
        var candidate: UIView? = hit
        while let current = candidate {
            if let entry = hostedEntries.last(where: { $0.view === current }),
               hostedEligible(entry),
               hostedColorOverlay.map({ entry.view?.isDescendant(of: $0) == true }) ?? true {
                return entry.identifier
            }
            if current === view { break }
            candidate = current.superview
        }
        return nil
    }

    private func hostedEligible(_ entry: HostedEntry) -> Bool {
        guard let target = entry.view, target.window != nil else { return false }
        var node: UIView? = target
        while let current = node {
            if current.isHidden || current.alpha <= 0.01 || !current.isUserInteractionEnabled { return false }
            if let control = current as? UIControl, !control.isEnabled { return false }
            if current === view { return true }
            node = current.superview
        }
        return false
    }

    func hostedControlAllowsDrag(_ identifier: String) -> Bool {
        hostedEntries.first(where: { $0.identifier == identifier })?.action.allowsDrag ?? false
    }

    private func finishDeferredMenuRefresh() {
        if selectedPage == 0 && refreshHomeStatusLabels() {
            homeStatusNeedsRebuild = false
        } else { rebuildMenu() }
    }

    func handleHostedControl(_ identifier: String, phase: CoreSetHostedPointerPhase,
                             at point: CGPoint) -> Bool {
        precondition(Thread.isMainThread)
        defer {
            if phase == .ended || phase == .cancelled {
                if hostedPointerID == identifier { hostedPointerID = nil }
                if homeStatusNeedsRebuild && hostedPointerID == nil {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.hostedPointerID == nil,
                              self.hostedDispatchControlID == nil,
                              self.trackingUIKitSlider == nil,
                              self.homeStatusNeedsRebuild else { return }
                        self.finishDeferredMenuRefresh()
                    }
                }
            }
        }
        if phase == .cancelled {
            if hostedScrollID == identifier { hostedScrollID = nil }
            if hostedSliderID == identifier {
                if let slider = hostedEntries.first(where: { $0.identifier == identifier })?.view as? UISlider {
                    slider.value = hostedSliderOriginalValue
                    refreshHostedColorPreview()
                }
                hostedSliderID = nil
            }
            return false
        }
        guard let entry = hostedEntries.first(where: { $0.identifier == identifier }),
              hostedEligible(entry), let target = entry.view else { return false }
        if phase == .began { hostedPointerID = identifier }
        if let scroll = target as? UIScrollView, entry.action == .contentScroll || entry.action == .materialScroll {
            if phase == .began {
                hostedScrollID = identifier; hostedScrollStart = point
                hostedScrollOffset = scroll.contentOffset
                return true
            }
            guard hostedScrollID == identifier else { return false }
            if phase == .ended && hypot(point.x - hostedScrollStart.x,
                                        point.y - hostedScrollStart.y) < 3 {
                hostedScrollID = nil
                return false
            }
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            let desired = CGPoint(x: min(maxX, max(0, hostedScrollOffset.x - point.x + hostedScrollStart.x)),
                                  y: min(maxY, max(0, hostedScrollOffset.y - point.y + hostedScrollStart.y)))
            scroll.contentOffset = desired
            if entry.action == .contentScroll { pageContentOffsets[selectedPage] = desired }
            if phase == .ended { hostedScrollID = nil }
            let confirmed = scroll.contentOffset == desired
            if phase == .ended {
                NSLog("Core-SET: hosted input stage=actual capability=scroll confirmed=%d",
                      confirmed ? 1 : 0)
            }
            return confirmed
        }
        if phase == .began {
            if let slider = target as? UISlider, entry.action.isSlider {
                hostedSliderID = identifier
                hostedSliderOriginalValue = slider.value
            }
            return true
        }
        if let slider = target as? UISlider, entry.action.isSlider {
            let local = slider.convert(point, from: view)
            let fraction = min(1, max(0, local.x / max(1, slider.bounds.width)))
            slider.value = slider.minimumValue + Float(fraction) * (slider.maximumValue - slider.minimumValue)
            if phase == .moved {
                if [.colorRed, .colorGreen, .colorBlue, .colorAlpha].contains(entry.action) {
                    refreshHostedColorPreview()
                }
                return true
            }
            guard phase == .ended else { return false }
            hostedSliderID = nil
            hostedDispatchControlID = identifier
            defer { hostedDispatchControlID = nil }
            return dispatchHostedSlider(entry.action, slider)
        }
        guard phase == .ended else { return false }
        if let segment = target as? UISegmentedControl, entry.action.isSegmented {
            let local = segment.convert(point, from: view)
            let index = min(segment.numberOfSegments - 1,
                            max(0, Int(local.x / max(1, segment.bounds.width) * CGFloat(segment.numberOfSegments))))
            guard segment.isEnabledForSegment(at: index) else { return false }
            segment.selectedSegmentIndex = index
            hostedDispatchControlID = identifier
            defer { hostedDispatchControlID = nil }
            return dispatchHostedSegment(entry.action, segment)
        }
        guard let button = target as? UIButton else { return false }
        hostedDispatchControlID = identifier
        defer { hostedDispatchControlID = nil }
        return dispatchHostedButton(entry.action, button)
    }

    private func dispatchHostedSlider(_ action: HostedAction, _ slider: UISlider) -> Bool {
        interactionControlIdentifier = slider.accessibilityIdentifier ?? hostedDispatchControlID ?? "hosted"
        switch action {
        case .boundRange: changeBoundRange(slider)
        case .adjustmentRange: changeAdjustmentRange(slider)
        case .localAimCircleSize: changeLocalAimCircleSize(slider)
        case .localAimPreviewDistance: changeLocalAimPreviewDistance(slider)
        case .frameRate: changeFrameRate(slider)
        case .warningRange: changeWarningRange(slider)
        case .radarPlacement: changeRadarPlacement(slider)
        case .aimRange: configureBasicAimRange(slider)
        case .recoilStrength: configureRecoilStrength(slider)
        case .colorRed, .colorGreen, .colorBlue, .colorAlpha:
            refreshHostedColorPreview()
        default: return false
        }
        return true
    }

    private func dispatchHostedSegment(_ action: HostedAction, _ segment: UISegmentedControl) -> Bool {
        interactionControlIdentifier = segment.accessibilityIdentifier ?? hostedDispatchControlID ?? "hosted"
        switch action {
        case .aimTrigger: configureBasicAimTrigger(segment)
        case .aimPoint: configureBasicAimPoint(segment)
        case .aimBots: configureBasicAimBots(segment)
        case .aimLock: configureBasicAimLock(segment)
        case .aimLockStrength: configureBasicAimLockStrength(segment)
        default: return false
        }
        return true
    }

    private func dispatchHostedButton(_ action: HostedAction, _ button: UIButton) -> Bool {
        interactionControlIdentifier = button.accessibilityIdentifier ?? hostedDispatchControlID ?? "hosted"
        switch action {
        case .close: guard !isClosing else { return false }; closeMenu()
        case .exitHUD:
            guard let onExitHUD else { return false }
            onExitHUD()
        case .page: selectPage(button)
        case .theme: selectTheme(button)
        case .homeRunMode: configureHomeRunMode(button)
        case .homeCoverMode: configureHomeCoverMode(button)
        case .homeKernelAction: startHomeKernelAction(button)
        case .homeInformationAction: startHomeInformationAction(button)
        case .backIndicator: selectBackIndicator(button)
        case .playerWeaponMode: selectPlayerWeaponMode(button)
        case .playerCountMode: selectPlayerCountMode(button)
        case .playerInformationMode: selectPlayerInformationMode(button)
        case .playerField: togglePlayerField(button)
        case .localAimCircle: toggleLocalAimCircle(button)
        case .localAimPreviewField: toggleLocalAimPreviewField(button)
        case .materialEnabled: toggleMaterialEnabled(button)
        case .hideWhileArmed: toggleHideWhileArmed(button)
        case .metroArmor: toggleMetroArmor(button)
        case .hideOpenedCrates: toggleHideOpenedCrates(button)
        case .crateLevel: toggleCrateLevel(button)
        case .vehicleStatus: toggleVehicleStatus(button)
        case .radarField: toggleRadarField(button)
        case .warningField: toggleWarningField(button)
        case .presetColor: selectPresetColor(button)
        case .floatingColor: selectFloatingColor(button)
        case .materialCategory: selectMaterialCategory(button)
        case .backStyle: selectBackStyle(button)
        case .previewScene: selectPreviewScene(button)
        case .materialGroup: toggleMaterialGroup(button)
        case .allMaterialGroups: setAllMaterialGroups(button)
        case .aimStart: startBasicAim()
        case .aimStop: stopBasicAim()
        case .aimChoice: selectAimChoice(button)
        case .aimConfigurationField: toggleAimConfigurationField(button)
        case .recoilField: toggleRecoilField(button)
        case .colorEditor: return showHostedColorEditor(button)
        case .colorApply: return applyHostedColorEditor()
        case .colorCancel: dismissHostedColorEditor(); return true
        case .unavailableInfo: explainUnavailable(button)
        default: return false
        }
        return true // Invocation only. Original FeatureChannel owns the actual receipt.
    }

    private func showConfigurationFeedback(_ message: String) {
        configurationFeedback = message
        configurationFeedbackLabel.text = message
        configurationFeedbackLabel.accessibilityLabel = message
    }

    @objc private func beginUIKitSliderTracking(_ sender: UISlider) { trackingUIKitSlider = sender }
    @objc private func endUIKitSliderTracking(_ sender: UISlider) {
        guard trackingUIKitSlider === sender else { return }
        trackingUIKitSlider = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.trackingUIKitSlider == nil, self.hostedPointerID == nil,
                  self.hostedDispatchControlID == nil, self.homeStatusNeedsRebuild else { return }
            self.finishDeferredMenuRefresh()
        }
    }

    @objc private func explainUnavailable(_ sender: UIButton) {
        interactionControlIdentifier = sender.accessibilityIdentifier ?? "unavailable"
        if selectedPage == 0, let point = CoreSetHomeProbePoint.allCases.first(where: {
            interactionControlIdentifier.contains($0.stableID)
        }) {
            onHomeProbeRefusal?(point, point == .runMode || point == .coverMode ? sender.tag : nil)
        }
        let title = sender.accessibilityLabel ?? sender.currentTitle ?? "该控件"
        let reason = sender.accessibilityHint ?? "功能尚未接入，未执行操作"
        showConfigurationFeedback("\(title)：尚未生效；\(reason)")
        NSLog("Core-SET: hosted input stage=unavailable control=%@ configured=0 confirmed=0 reason=%@",
              interactionControlIdentifier, reason)
    }

    private func unavailableReason(title: String) -> String? {
        let name = title.components(separatedBy: "  ").first ?? title
        if selectedPage == 0 {
            switch name {
            case "运行模式": return nil // Core only normalizes/persists C+0x12c; no separate consumer.
            case "掩体判断": return "home.coverMode：原版只读 lease、A/B 指针/表读取、0xa0 输出布局、callback owner/payload 与三条空间索引 worker 已静态闭合；64d04 row 到 builder 字段的连续身份及真机回执待验证"
            case "内核利用": return "kernelAction：当前场景动作 owner 未绑定或正在执行"
            case "获取信息": return "informationAction：当前场景动作 owner 未绑定或正在执行"
            default: return nil
            }
        }
        if selectedPage == 5 {
            switch name {
            case "倒地不瞄": return "aim.excludeKnocked：按 Core 记录 flag14 筛选"
            case "启用自瞄": return "aim.enabled：当前目标会话或画布未就绪"
            case "关闭自瞄": return "aim.stop：当前没有需要停止的动作会话"
            default: return nil
            }
        }
        if selectedPage == 6 {
            let fields: [String: (String, CoreSetField)] = [
                "启用压枪": ("enabled", .recoilEnabled),
                "停火不压": ("stopWhenNotFiring", .recoilStopWhenNotFiring),
                "垂直补偿": ("verticalEnabled", .recoilVerticalEnabled),
                "垂直补偿强度": ("verticalStrength", .recoilVerticalStrength),
                "水平补偿": ("horizontalEnabled", .recoilHorizontalEnabled),
                "水平补偿强度": ("horizontalStrength", .recoilHorizontalStrength)
            ]
            guard let (path, field) = fields[name],
                  case .unavailable(let reason) = featureState.recoil.fieldAvailability(field) else { return nil }
            return "recoil.\(path)：\(reason)"
        }
        return nil
    }

    private func recordAimConfiguration(_ sender: UIView, path: String) {
        interactionControlIdentifier = sender.accessibilityIdentifier ?? "aim.local-configuration"
        let reason = "\(path)：配置已记录；启用后由基础视角自瞄消费者应用"
        showConfigurationFeedback(reason)
        NSLog("Core-SET: menu stage=desired control=%@ capability=aimControl field=%@ configured=1 confirmed=0 targetEffectsCreated=0 scope=typed-action-configuration reason=%@",
              interactionControlIdentifier, path, reason)
    }

    private func aimConfigurationAvailable(_ field: CoreSetField) -> Bool {
        canStage(featureState.aim) && controlAvailability(field, in: featureState.aim) == .ready
    }

    private func recoilConfigurationAvailable(_ field: CoreSetField) -> Bool {
        canStage(featureState.recoil) && controlAvailability(field, in: featureState.recoil) == .ready
    }

    private var homeConfigurationAvailable: Bool {
        guard !featureState.home.suspended, featureState.home.pendingStop == nil,
              featureState.home.restoration != .pending else { return false }
        if case .failed = featureState.home.restoration { return false }
        return true
    }

    private func recordRecoilConfiguration(_ sender: UIView, path: String) {
        interactionControlIdentifier = sender.accessibilityIdentifier ?? "recoil.local-configuration"
        let reason = "\(path)：已记录参数；参数完整且共享动作 worker 就绪时提交并等待写后回读"
        showConfigurationFeedback(reason)
        NSLog("Core-SET: menu stage=desired control=%@ capability=recoilControl field=%@ configured=1 confirmed=0 targetEffectsCreated=0 scope=typed-action-configuration reason=%@",
              interactionControlIdentifier, path, reason)
    }

    // Keep unsupported actions fail-closed, while both UIKit and hosted input
    // can reach an explanation instead of silently falling through to scrolling.
    private func installUnavailableFeedback(in container: UIView) {
        for child in container.subviews {
            if container.subviews.contains(where: { ($0 as? UnavailableInfoButton)?.explainedView === child }) { continue }
            let disabledControl = (child as? UIControl).map { !$0.isEnabled } ?? false
            let disabledRow = child.isAccessibilityElement && child.accessibilityTraits.contains(.notEnabled)
            if disabledControl || disabledRow {
                let info = UnavailableInfoButton(type: .custom)
                info.explainedView = child
                info.tag = child.tag
                info.frame = child.frame
                info.accessibilityLabel = child.accessibilityLabel ?? (child as? UIButton)?.currentTitle ??
                    container.subviews.compactMap { ($0 as? UILabel)?.text }.first ?? "该控件"
                var reason = unavailableReason(title: info.accessibilityLabel ?? "") ?? child.accessibilityHint ?? "功能尚未接入，原版运行值未验证"
                if selectedPage == 5, case .unavailable(let value) = featureState.aim.availability {
                    reason += "；\(value)"
                } else if selectedPage == 6, case .unavailable(let value) = featureState.recoil.availability {
                    reason += "；\(value)"
                }
                info.accessibilityHint = reason
                info.accessibilityIdentifier = child.accessibilityIdentifier ?? "core-set.\(selectedPage).unavailable.\(info.accessibilityLabel ?? "unknown")"
                info.addTarget(self, action: #selector(explainUnavailable(_:)), for: .touchUpInside)
                child.isAccessibilityElement = false
                container.addSubview(info)
                registerHosted(info, .unavailableInfo)
            } else { installUnavailableFeedback(in: child) }
        }
    }

    private func registerHostedColorEditor() {
        guard hostedColorOverlay != nil, hostedColorSliders.count == 4 else { return }
        for (slider, action) in zip(hostedColorSliders,
                                     [HostedAction.colorRed, .colorGreen, .colorBlue, .colorAlpha]) {
            registerHosted(slider, action)
        }
        if let hostedColorApplyButton { registerHosted(hostedColorApplyButton, .colorApply) }
        if let hostedColorCancelButton { registerHosted(hostedColorCancelButton, .colorCancel) }
    }

    private func refreshHostedColorPreview() {
        guard hostedColorSliders.count == 4 else { return }
        let values = hostedColorSliders.map { CGFloat($0.value) }
        hostedColorPreview?.backgroundColor = UIColor(red: values[0], green: values[1],
                                                     blue: values[2], alpha: values[3])
    }

    private func showHostedColorEditor(_ sender: UIButton) -> Bool {
        guard let target = (sender as? ColorButton)?.colorTarget,
              colorTargetStageReady(target), hostedColorOverlay == nil else { return false }
        let seed = colorValue(target).map(uiColor) ?? defaultAccent
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard seed.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        let overlay = UIView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        let card = UIView(frame: CGRect(x: 0, y: 0, width: 330, height: 320))
        card.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        card.backgroundColor = gray(26, 250)
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1
        card.layer.borderColor = gray(70, 190).cgColor
        let editorTitle: String
        switch target {
        case .theme: editorTitle = "主题颜色"
        case .player(let role), .bot(let role): editorTitle = role.rawValue
        case .material: editorTitle = "分类颜色"
        }
        card.addSubview(label(editorTitle, size: 17,
                              frame: CGRect(x: 20, y: 12, width: 290, height: 28)))
        let preview = UIView(frame: CGRect(x: 20, y: 48, width: 290, height: 24))
        preview.layer.cornerRadius = 4
        card.addSubview(preview)
        hostedColorSliders = []
        for (index, value) in [r, g, b, target == .theme ? CGFloat(1) : a].enumerated() {
            card.addSubview(label(["R", "G", "B", "A"][index], size: 13,
                                  frame: CGRect(x: 20, y: 83 + CGFloat(index) * 44,
                                                width: 22, height: 30)))
            let slider = UISlider(frame: CGRect(x: 50, y: 83 + CGFloat(index) * 44,
                                                width: 260, height: 30))
            slider.minimumValue = 0; slider.maximumValue = 1
            slider.value = Float(value)
            slider.isEnabled = index != 3 || target != .theme
            slider.addTarget(self, action: #selector(hostedColorSliderChanged), for: .valueChanged)
            card.addSubview(slider)
            hostedColorSliders.append(slider)
        }
        let apply = UIButton(type: .system)
        apply.frame = CGRect(x: 145, y: 275, width: 76, height: 32)
        apply.setTitle("应用", for: .normal)
        apply.addTarget(self, action: #selector(hostedColorApplyTapped), for: .touchUpInside)
        card.addSubview(apply)
        let cancel = UIButton(type: .system)
        cancel.frame = CGRect(x: 234, y: 275, width: 76, height: 32)
        cancel.setTitle("取消", for: .normal)
        cancel.addTarget(self, action: #selector(hostedColorCancelTapped), for: .touchUpInside)
        card.addSubview(cancel)
        overlay.addSubview(card)
        view.addSubview(overlay)
        hostedColorOverlay = overlay; hostedColorCard = card; hostedColorPreview = preview
        hostedColorApplyButton = apply; hostedColorCancelButton = cancel; hostedColorTarget = target
        hostedMenuRevision &+= 1
        registerHostedColorEditor()
        refreshHostedColorPreview()
        return true
    }

    private func applyHostedColorEditor() -> Bool {
        guard let target = hostedColorTarget, colorTargetStageReady(target),
              hostedColorSliders.count == 4 else { return false }
        let values = hostedColorSliders.map { CGFloat($0.value) }
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        let color = UIColor(red: values[0], green: values[1], blue: values[2], alpha: values[3])
        dismissHostedColorEditor()
        applyEditedColor(color, target: target)
        return true // The original appearance/material/adjustment channel owns the receipt.
    }

    private func dismissHostedColorEditor() {
        hostedColorOverlay?.removeFromSuperview()
        hostedColorOverlay = nil; hostedColorCard = nil; hostedColorPreview = nil
        hostedColorSliders = []; hostedColorApplyButton = nil; hostedColorCancelButton = nil
        hostedColorTarget = nil
        hostedMenuRevision &+= 1
    }

    @objc private func hostedColorSliderChanged() { refreshHostedColorPreview() }
    @objc private func hostedColorApplyTapped() { _ = applyHostedColorEditor() }
    @objc private func hostedColorCancelTapped() { dismissHostedColorEditor() }

    @objc private func closeMenu() {
        guard !isClosing else { return }
        isClosing = true
        if hostConsumer != nil {
            requestMenuVisibility(false) { [weak self] confirmed in
                guard let self else { return }
                self.isClosing = false
                if confirmed { self.onClose?() }
            }
        } else {
            dismiss(animated: true, completion: onClose)
        }
    }

    @objc private func exitHUDTapped() { onExitHUD?() }

    private func canApply<Value: Equatable>(_ channel: CoreSetFeatureChannel<Value>) -> Bool {
        var current = channel
        current.refreshAvailability()
        guard (current.availability == .ready || current.canApplySupportedSubset),
              !current.suspended, current.pendingApply == nil,
              current.pendingStop == nil, current.restoration != .pending,
              !(current.restoration == .required && current.phase != .active) else { return false }
        if case .failed = current.restoration { return false }
        return true
    }
    private func canStage<Value: Equatable>(_ channel: CoreSetFeatureChannel<Value>) -> Bool {
        channel.canStageDesired
    }
    // Editing permission is a local schema declaration. This does not change
    // fieldAvailability or the live prepareApply/receipt gates.
    private func controlAvailability<Value: Equatable>(_ field: CoreSetField,
        in channel: CoreSetFeatureChannel<Value>) -> CoreSetAvailability {
        channel.fieldConfigurationAvailability(field)
    }
    @discardableResult
    private func updateConsumerAvailability() -> Bool {
        func values() -> [CoreSetAvailability] {
            [featureState.home.availability, featureState.frameRate.availability,
             featureState.player.availability, featureState.materials.availability,
             featureState.adjustments.availability, featureState.radar.availability,
             featureState.aim.availability, featureState.aimDisplay.availability,
             featureState.recoil.availability, appearanceChannel?.availability ?? .unavailable(reason: "No local appearance consumer"),
             directoryChannel?.availability ?? .unavailable(reason: "No local directory consumer"), hostChannel.availability]
        }
        let before = values()
        featureState.home.refreshAvailability(); featureState.frameRate.refreshAvailability()
        featureState.player.refreshAvailability()
        featureState.materials.refreshAvailability(); featureState.adjustments.refreshAvailability()
        featureState.radar.refreshAvailability(); featureState.aim.refreshAvailability()
        featureState.aimDisplay.refreshAvailability(); featureState.recoil.refreshAvailability()
        appearanceChannel?.refreshAvailability(); directoryChannel?.refreshAvailability(); hostChannel.refreshAvailability()
        return before != values()
    }
    private func refreshBeforeInteraction(_ sender: UIView? = nil) {
        if let sender { interactionControlIdentifier = sender.accessibilityIdentifier ?? "UIKit" }
        if updateConsumerAvailability(), isViewLoaded { rebuildMenu() }
    }
    // The owner invokes this immediately on consumer/capability changes; rendering
    // and every edit additionally query the live consumer before accepting input.
    func refreshConsumerAvailability() {
        precondition(Thread.isMainThread)
        if updateConsumerAvailability(), isViewLoaded { rebuildMenu() }
        applyStagedConfigurations()
    }
    func invalidateLocalAimDisplayAfterHostReset() {
        precondition(Thread.isMainThread)
        featureState.aimDisplay.invalidateLocalFrameObservation()
    }

    func invalidateReadFrameObservation(capability: CoreSetCapability, reason: String) {
        precondition(Thread.isMainThread)
        switch capability {
        case .playerRendering: featureState.player.invalidateReadFrameObservation(reason: reason)
        case .materialFiltering: featureState.materials.invalidateReadFrameObservation(reason: reason)
        case .radarRendering: featureState.radar.invalidateReadFrameObservation(reason: reason)
        case .drawingAppearance: featureState.adjustments.invalidateReadFrameObservation(reason: reason)
        case .localAimDisplay: featureState.aimDisplay.invalidateReadFrameObservation(reason: reason)
        default: return
        }
        showConfigurationFeedback("\(capability.rawValue)：旧显示回执已撤销；配置保留，当前效果未确认")
        NSLog("Core-SET: hosted input stage=observation-invalidated capability=%@ confirmed=0 reason=%@",
              capability.rawValue, reason)
        if isViewLoaded { rebuildMenu() }
    }

    func invalidateFrameRateObservation(reason: String) {
        precondition(Thread.isMainThread)
        featureState.frameRate.invalidateSchedulerObservation(reason: reason)
        showConfigurationFeedback("v17-029：Metal调度器旧回读已撤销；配置保留，当前调度效果未确认")
        NSLog("Core-SET: menu stage=observation-invalidated point=v17-029 capability=frameScheduling confirmed=0 reason=%@", reason)
        if isViewLoaded { rebuildMenu() }
    }

    @discardableResult
    func bindGameConsumer<C: CoreSetFeatureConsumer>(_ consumer: C,
        to path: WritableKeyPath<CoreSetFeatureState, CoreSetFeatureChannel<C.State>>) -> Bool {
        precondition(Thread.isMainThread)
        let supported: [AnyKeyPath] = [\CoreSetFeatureState.home, \CoreSetFeatureState.frameRate,
            \CoreSetFeatureState.player,
            \CoreSetFeatureState.materials, \CoreSetFeatureState.adjustments, \CoreSetFeatureState.radar,
            \CoreSetFeatureState.aim, \CoreSetFeatureState.aimDisplay, \CoreSetFeatureState.recoil]
        guard supported.contains(path) else { return false }
        let box = CoreSetMenuConsumer(consumer)
        guard featureState[keyPath: path].bind(box) else { return false }
        gameConsumers[path] = box
        if isViewLoaded { rebuildMenu() }
        return true
    }

    private func editGame<Value: Equatable>(_ path: WritableKeyPath<CoreSetFeatureState, CoreSetFeatureChannel<Value>>,
                                 _ edit: (inout Value) -> Void) {
        updateConsumerAvailability()
        guard canStage(featureState[keyPath: path]), gameConsumers[path] != nil else { rebuildMenu(); return }
        featureState[keyPath: path].updateDesired(edit)
        stagedConfigurationPaths.insert(path)
        configurationSources[path] = interactionControlIdentifier
        showConfigurationFeedback("配置已记录；尚未生效，等待消费者就绪及回执")
        NSLog("Core-SET: hosted input stage=desired control=%@ capability=%@ configured=1 confirmed=0",
              interactionControlIdentifier, featureState[keyPath: path].capability.rawValue)
        if canApply(featureState[keyPath: path]) && featureState[keyPath: path].pendingApply == nil {
            applyGame(path)
        } else { rebuildMenu() }
    }

    private func applyStagedConfigurations() {
        guard hostedPointerID == nil else { return }
        func apply<Value: Equatable>(_ path: WritableKeyPath<CoreSetFeatureState, CoreSetFeatureChannel<Value>>) {
            guard stagedConfigurationPaths.contains(path) else { return }
            let ready = canApply(featureState[keyPath: path])
            let wasReady = stagedConfigurationReadiness[path] ?? false
            stagedConfigurationReadiness[path] = ready
            // Incomplete parameters do not create a repeated submit loop while
            // the runtime remains ready. A new edit or a readiness edge retries.
            guard ready && !wasReady else { return }
            applyGame(path)
        }
        apply(\.frameRate); apply(\.player); apply(\.materials); apply(\.adjustments)
        apply(\.radar); apply(\.aimDisplay); apply(\.aim); apply(\.recoil)
    }

    private func applyGame<Value: Equatable>(_ path: WritableKeyPath<CoreSetFeatureState, CoreSetFeatureChannel<Value>>) {
        guard let consumer = gameConsumers[path] as? CoreSetMenuConsumer<Value>,
              let request = featureState[keyPath: path].prepareApply() else { return }
        stagedConfigurationPaths.remove(path)
        stagedConfigurationReadiness.removeValue(forKey: path)
        let hostedSource = configurationSources[path] ?? interactionControlIdentifier
        showConfigurationFeedback("已提交配置；等待消费者实际回执")
        consumer.apply(request) { [weak self] token, outcome in
            DispatchQueue.main.async {
                guard let self, self.featureState[keyPath: path].receive(token, outcome: outcome) else { return }
                switch outcome {
                case .notApplied, .unavailable:
                    self.stagedConfigurationPaths.insert(path)
                    self.stagedConfigurationReadiness[path] = self.canApply(self.featureState[keyPath: path])
                case .applied, .appliedWithoutRestoration, .failed: break
                }
                let channel = self.featureState[keyPath: path]
                let result: String
                switch outcome {
                case .applied: result = "applied"
                case .appliedWithoutRestoration: result = "applied-without-restoration"
                case .notApplied(let reason): result = "notApplied:\(reason)"
                case .unavailable(let reason): result = "unavailable:\(reason)"
                case .failed(let reason): result = "failed:\(reason)"
                }
                NSLog("Core-SET: hosted input stage=actual control=%@ capability=%@ confirmed=%d result=%@ scope=consumer-declared-fields",
                      hostedSource, channel.capability.rawValue,
                      channel.isSupportedDesiredConfirmed ? 1 : 0, result)
                if channel.isSupportedDesiredConfirmed {
                    if channel.capability == .materialFiltering,
                       let notice = self.materialConfigurationNotice(self.featureState.materials.desired) {
                        self.showConfigurationFeedback(notice)
                    } else {
                        self.showConfigurationFeedback(channel.capability == .localAimDisplay
                            ? "替代预览回执已确认；不算v1.7原效果闭合"
                            : (channel.capability == .frameScheduling ? "Metal调度器参数回读已确认；不是实测呈现FPS"
                                : "消费者声明字段回执已确认；v1.7设备效果仍需验证"))
                    }
                }
                else if case .unavailable(let reason) = channel.availability {
                    self.showConfigurationFeedback("配置已记录；尚未生效：\(reason)")
                } else if case .failed(let reason) = channel.phase {
                    self.showConfigurationFeedback("配置已记录；应用失败：\(reason)")
                } else { self.showConfigurationFeedback("配置已记录；尚未确认生效") }
                self.rebuildCurrentPage()
                if self.featureState[keyPath: path].desired != request.desired,
                   self.canApply(self.featureState[keyPath: path]) { self.applyGame(path) }
            }
        }
    }

    // Session/scene teardown calls this; hiding the panel alone does not stop game effects.
    func suspendGameConsumers(completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        stagedConfigurationPaths.removeAll()
        stagedConfigurationReadiness.removeAll()
        configurationSources.removeAll()
        let group = DispatchGroup()
        func stop<Value: Equatable>(_ path: WritableKeyPath<CoreSetFeatureState, CoreSetFeatureChannel<Value>>) {
            featureState[keyPath: path].suspend()
            guard let token = featureState[keyPath: path].pendingStop,
                  let consumer = gameConsumers[path] as? CoreSetMenuConsumer<Value> else { return }
            group.enter()
            var received = false
            consumer.stop(token) { [weak self] token, outcome in
                DispatchQueue.main.async {
                    guard !received, let self, self.featureState[keyPath: path].receiveStop(token, outcome: outcome) else { return }
                    received = true
                    group.leave()
                }
            }
        }
        stop(\.home); stop(\.frameRate); stop(\.player); stop(\.materials); stop(\.adjustments)
        stop(\.radar); stop(\.aim); stop(\.aimDisplay); stop(\.recoil)
        func stopLocal<Value: Equatable>(
            _ path: ReferenceWritableKeyPath<CoreSetMenuViewController, CoreSetFeatureChannel<Value>?>,
            consumer: CoreSetMenuConsumer<Value>?) {
            self[keyPath: path]?.suspend()
            guard let token = self[keyPath: path]?.pendingStop, let consumer else { return }
            group.enter()
            var received = false
            consumer.stop(token) { [weak self] token, outcome in
                DispatchQueue.main.async {
                    guard !received, let self, self[keyPath: path]?.receiveStop(token, outcome: outcome) == true else { return }
                    received = true; group.leave()
                }
            }
        }
        stopLocal(\.appearanceChannel, consumer: appearanceConsumer)
        stopLocal(\.directoryChannel, consumer: directoryConsumer)
        group.notify(queue: .main) { [weak self] in
            guard let self else { completion(false); return }
            let states = [self.featureState.home.restoration, self.featureState.frameRate.restoration,
                self.featureState.player.restoration,
                self.featureState.materials.restoration, self.featureState.adjustments.restoration,
                self.featureState.radar.restoration, self.featureState.aim.restoration,
                self.featureState.aimDisplay.restoration, self.featureState.recoil.restoration,
                self.appearanceChannel?.restoration ?? .notNeeded, self.directoryChannel?.restoration ?? .notNeeded]
            self.rebuildMenu()
            completion(states.allSatisfy { $0.stopComplete })
        }
    }
    func suspendAimConsumer(completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        featureState.aim.suspend()
        guard let token = featureState.aim.pendingStop else {
            completion(featureState.aim.restoration.stopComplete); return
        }
        guard let consumer = gameConsumers[\CoreSetFeatureState.aim] as? CoreSetMenuConsumer<CoreSetAimSettings> else {
            completion(false); return
        }
        consumer.stop(token) { [weak self] token, outcome in
            DispatchQueue.main.async {
                guard let self, self.featureState.aim.receiveStop(token, outcome: outcome) else { completion(false); return }
                self.rebuildMenu()
                completion(self.featureState.aim.restoration.stopComplete)
            }
        }
    }

    // Aim and recoil share one serialized target-action worker. A host/context
    // transition must stop both logical lanes before either source window is
    // exported, otherwise recoil can remain live after the aim lane is cleared.
    func suspendActionConsumers(completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        let group = DispatchGroup()
        var missingConsumer = false
        func stop<Value: Equatable>(
            _ path: WritableKeyPath<CoreSetFeatureState, CoreSetFeatureChannel<Value>>
        ) {
            featureState[keyPath: path].suspend()
            guard let token = featureState[keyPath: path].pendingStop else {
                return
            }
            guard let consumer = gameConsumers[path] as? CoreSetMenuConsumer<Value> else {
                missingConsumer = true
                return
            }
            group.enter()
            var received = false
            consumer.stop(token) { [weak self] token, outcome in
                DispatchQueue.main.async {
                    guard !received else { return }
                    received = true
                    if let self { _ = self.featureState[keyPath: path].receiveStop(token, outcome: outcome) }
                    group.leave()
                }
            }
        }
        stop(\.aim)
        stop(\.recoil)
        let consumerMissing = missingConsumer
        group.notify(queue: .main) { [weak self] in
            guard let self else { completion(false); return }
            let states = [self.featureState.aim.restoration, self.featureState.recoil.restoration]
            self.rebuildMenu()
            completion(!consumerMissing && states.allSatisfy { $0.stopComplete })
        }
    }

    @discardableResult
    func resumeActionConsumers() -> Bool {
        precondition(Thread.isMainThread)
        let aimResumed = featureState.aim.suspended ? featureState.aim.resume() : true
        let recoilResumed = featureState.recoil.suspended ? featureState.recoil.resume() : true
        refreshConsumerAvailability()
        return aimResumed && recoilResumed
    }
    @discardableResult
    func resumeAimConsumer() -> Bool {
        precondition(Thread.isMainThread)
        let result = featureState.aim.resume(); refreshConsumerAvailability(); return result
    }

    @discardableResult
    func resumeGameConsumers() -> Bool {
        precondition(Thread.isMainThread)
        let appearanceResumed = appearanceChannel?.suspended == true ? (appearanceChannel?.resume() ?? false) : true
        let directoryResumed = directoryChannel?.suspended == true ? (directoryChannel?.resume() ?? false) : true
        let results = [appearanceResumed, directoryResumed, featureState.home.resume(), featureState.frameRate.resume(),
            featureState.player.resume(), featureState.materials.resume(),
            featureState.adjustments.resume(), featureState.radar.resume(),
            featureState.aim.resume(), featureState.aimDisplay.resume(), featureState.recoil.resume()]
        refreshConsumerAvailability()
        return results.allSatisfy { $0 }
    }

    @discardableResult
    func bindMenuHostConsumer<C: CoreSetFeatureConsumer>(_ consumer: C) -> Bool where C.State == CoreSetMenuHostSettings {
        precondition(Thread.isMainThread)
        let box = CoreSetMenuConsumer(consumer)
        guard hostChannel.bind(box) else { return false }
        hostConsumer = box
        return true
    }

    func requestMenuVisibility(_ visible: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        precondition(Thread.isMainThread)
        loadViewIfNeeded()
        let palette = featureState.home.desired.floatingPalette
        hostChannel.updateDesired { $0.menuVisible = visible; $0.floatingPalette = palette }
        applyHostSettings { [weak self] confirmed in
            self?.isClosing = false
            if confirmed && !visible { self?.dismissHostedColorEditor() }
            completion(confirmed)
        }
    }

    func suspendMenuHostConsumer(completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        hostChannel.suspend()
        guard let token = hostChannel.pendingStop else { completion(hostChannel.restoration.stopComplete); return }
        guard let consumer = hostConsumer else { completion(false); return }
        consumer.stop(token) { [weak self] token, outcome in
            DispatchQueue.main.async {
                guard let self, self.hostChannel.receiveStop(token, outcome: outcome) else { completion(false); return }
                if self.hostChannel.restoration.stopComplete { self.lastHostAppliedToken = nil }
                _ = self.featureState.setInfrastructure(.hostWindow, availability: .unavailable(reason: "Host consumer stopped"))
                completion(self.hostChannel.restoration.stopComplete)
            }
        }
    }
    @discardableResult
    func resumeMenuHostConsumer() -> Bool {
        precondition(Thread.isMainThread)
        let result = hostChannel.resume()
        if result { lastHostAppliedToken = nil }
        refreshConsumerAvailability()
        return result
    }

    private func applyHostSettings(completion: @escaping (Bool) -> Void = { _ in }) {
        guard let consumer = hostConsumer, let request = hostChannel.prepareApply() else { completion(false); return }
        let hostedSource = interactionControlIdentifier
        consumer.apply(request) { [weak self] token, outcome in
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                guard self.hostChannel.receive(token, outcome: outcome) else {
                    if token.generation == self.hostChannel.generation, self.hostChannel.pendingStop == nil {
                        self.invalidateMenuHostObservation(reason: "Host apply receipt no longer matches its live producer")
                    }
                    completion(false); return
                }
                if case .applied = outcome { self.lastHostAppliedToken = token }
                _ = self.featureState.setInfrastructure(.hostWindow, availability: self.hostChannel.isDesiredConfirmed
                    ? .ready : .unavailable(reason: "Host request has not been confirmed"))
                NSLog("Core-SET: hosted input stage=actual control=%@ capability=hostWindow confirmed=%d result=%@ scope=actual-host-floating-gradient-property original-runtime-receipt=0 device-effect-verified=0",
                      hostedSource, self.hostChannel.isDesiredConfirmed ? 1 : 0, String(describing: outcome))
                completion(self.hostChannel.isDesiredConfirmed)
                if self.isViewLoaded && self.selectedPage == 0 { self.rebuildMenu() }
            }
        }
    }
    func menuHostRequestIsCurrent(_ token: CoreSetRequestToken) -> Bool {
        lastHostAppliedToken == token && hostChannel.generation == token.generation &&
            hostChannel.pendingApply == nil && hostChannel.pendingStop == nil
    }
    func menuHostObservationMayBeRefreshed(_ token: CoreSetRequestToken) -> Bool {
        hostChannel.pendingApply == nil && hostChannel.pendingStop == nil
    }
    func invalidateMenuHostObservation(reason: String) {
        precondition(Thread.isMainThread)
        hostChannel.invalidateHostPresentationObservation(reason: reason)
        lastHostAppliedToken = nil
        NSLog("Core-SET: hosted-palette stage=invalidated point=v17-014 confirmed=0 scope=actual-host-floating-gradient-property reason=%@", reason)
        if isViewLoaded && selectedPage == 0 { rebuildMenu() }
    }
    private var hostPaletteReceiptReason: String {
        if let reason = hostChannel.observationInvalidationReason { return reason }
        if case .failed(let reason) = hostChannel.phase { return reason }
        if case .unavailable(let reason) = hostChannel.availability { return reason }
        return "awaiting-matched-host-palette-receipt"
    }

    private func uiColor(_ value: CoreSetRGBA) -> UIColor {
        UIColor(red: CGFloat(value.red), green: CGFloat(value.green), blue: CGFloat(value.blue), alpha: CGFloat(value.alpha))
    }
    private func rgba(_ color: UIColor) -> CoreSetRGBA? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return CoreSetRGBA(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }
    private func appearanceDesired() -> CoreSetMenuAppearance {
        CoreSetMenuAppearance(theme: featureState.home.desired.theme ?? .dark,
            accent: featureState.home.desired.accent ?? rgba(defaultAccent)!,
            floatingPalette: featureState.home.desired.floatingPalette ?? .gradient)
    }
    private func directoryDesired() -> CoreSetDirectoryPresentation {
        let category = CoreSetMaterialCategory(rawValue: previewMaterialCategory) ?? .vehicles
        return CoreSetDirectoryPresentation(category: category,
            selections: featureState.materials.desired.categories[category.rawValue].groups.map(\.selection),
            tint: rgba(materialPreviewTint(category: category.rawValue))!)
    }
    private var localAppearanceReady: Bool { appearanceChannel.map(canApply) ?? false }
    private var localDirectoryReady: Bool { directoryChannel.map(canApply) ?? false }

    private func configureLocalConsumers() {
        let readiness: () -> CoreSetAvailability = { [weak self] in
            guard let self, self.isViewLoaded, self.panel.superview === self.view else {
                return .unavailable(reason: "Local view configuration is unavailable")
            }
            return .ready
        }
        let stop: (CoreSetRequestToken, @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) -> Void = { [weak self] token, complete in
            guard let self else { complete(token, .failed(reason: "Local menu released")); return }
            self.dismissHostedColorEditor()
            let observedStop = {
                let cleared = self.hostedColorOverlay == nil
                NSLog("Core-SET: local-menu stage=stop token=%@/%@/%@ confirmed=%d persisted-config-retained=1 scope=local-editor-lifecycle",
                      token.generation.uuidString, token.consumerID.uuidString, token.requestID.uuidString, cleared ? 1 : 0)
                complete(token, cleared ? .restored : .failed(reason: "Local editor dismissal did not match"))
            }
            observedStop()
        }
        appearanceConsumer = CoreSetMenuConsumer(capability: .localRendering, readiness: readiness, apply: { [weak self] request, complete in
            // Hosted dispatch owns the old controls until its End callback returns.
            // Apply and observe together after that ownership has been released.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.viewIfLoaded?.window != nil else { complete(request.token, .notApplied(reason: "Local menu is not attached")); return }
                guard self.appearanceChannel?.pendingApply?.token == request.token,
                      self.appearanceChannel?.suspended == false else {
                    complete(request.token, .notApplied(reason: "Local appearance request is no longer current")); return
                }
                guard self.hostedPointerID == nil, self.hostedDispatchControlID == nil,
                      self.trackingUIKitSlider == nil else {
                    complete(request.token, .notApplied(reason: "Local menu input is still tracking")); return
                }
                let value = request.desired
                UserDefaults.standard.set(value.theme == .light ? 1 : 0, forKey: self.themeKey)
                UserDefaults.standard.set(UInt64(value.accent.referencePackedRGBA), forKey: self.accentKey)
                // Preserve old-build compatibility only on an explicit user edit.
                UserDefaults.standard.set(value.theme == .light, forKey: self.legacyThemeKey)
                UserDefaults.standard.set([value.accent.red, value.accent.green, value.accent.blue, 1], forKey: self.legacyAccentKey)
                UserDefaults.standard.set(value.floatingPalette.rawValue, forKey: self.floatingThemeKey)
                self.rebuildMenu()
                // Observe actual view properties and local preference readback. This
                // receipt belongs only to localRendering, never to homeSettings.
                guard let observed = self.observeAppearance(), observed == value else {
                    complete(request.token, .failed(reason: "Local appearance observation did not match")); return
                }
                complete(request.token, .applied(observed: observed))
            }
        }, stop: stop)
        appearanceChannel = CoreSetFeatureChannel(capability: .localRendering, desired: appearanceDesired())
        if let consumer = appearanceConsumer { _ = appearanceChannel?.bind(consumer) }
        directoryConsumer = CoreSetMenuConsumer(capability: .localRendering, readiness: readiness, apply: { [weak self] request, complete in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedPage == 2, self.viewIfLoaded?.window != nil else {
                    complete(request.token, .notApplied(reason: "Directory preview is not visible")); return
                }
                guard self.directoryChannel?.pendingApply?.token == request.token,
                      self.directoryChannel?.suspended == false else {
                    complete(request.token, .notApplied(reason: "Local directory request is no longer current")); return
                }
                guard self.hostedPointerID == nil, self.hostedDispatchControlID == nil,
                      self.trackingUIKitSlider == nil else {
                    complete(request.token, .notApplied(reason: "Local menu input is still tracking")); return
                }
                self.rebuildCurrentPage()
                guard let observed = self.observeDirectory(), observed == request.desired else {
                    complete(request.token, .failed(reason: "Directory view observation did not match")); return
                }
                complete(request.token, .applied(observed: observed))
            }
        }, stop: stop)
        directoryChannel = CoreSetFeatureChannel(capability: .localRendering, desired: directoryDesired())
        if let consumer = directoryConsumer { _ = directoryChannel?.bind(consumer) }
    }

    private func observeAppearance() -> CoreSetMenuAppearance? {
        guard panel.superview === view,
              let sidebar = panel.subviews.first,
              let brand = sidebar.subviews.compactMap({ $0 as? UILabel }).first(where: { $0.text == "C" }),
              let drawnAccent = brand.textColor,
              let color = rgba(drawnAccent),
              let saved = storedPackedAccent(), saved == color.referencePackedRGBA else { return nil }
        let brandParts = sidebar.subviews.compactMap { $0 as? UILabel }.filter {
            ["C", "ORE", "SET"].contains($0.text ?? "")
        }
        guard brandParts.count == 3,
              brandParts.allSatisfy({ $0.textColor?.isEqual(drawnAccent) == true }) else { return nil }
        let light = storedTheme() == .light
        let background = UIColor(white: (light ? 250.0 : 26.0) / 255.0, alpha: 1)
        guard panel.backgroundColor?.isEqual(background) == true,
              let palette = CoreSetFloatingPalette(rawValue: storedFloatingThemeValue()) else { return nil }
        return CoreSetMenuAppearance(theme: light ? .light : .dark, accent: color, floatingPalette: palette)
    }

    private func observeDirectory() -> CoreSetDirectoryPresentation? {
        guard materialGrid.window != nil,
              let category = CoreSetMaterialCategory(rawValue: previewMaterialCategory) else { return nil }
        let buttons = materialGridItems.subviews.compactMap { $0 as? MaterialGroupButton }.sorted { $0.tag < $1.tag }
        guard buttons.count == featureState.materials.desired.categories[category.rawValue].groups.count else { return nil }
        guard buttons.map({ $0.currentTitle ?? "" }) == materialCatalog[category.rawValue] else { return nil }
        let selections = buttons.map(\.observedSelection)
        guard let selectedTab = pageViews.flatMap({ $0.subviews }).flatMap({ $0.subviews })
            .compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "material.category.\(category.rawValue)" }),
              selectedTab.accessibilityTraits.contains(.selected),
              let drawnColor = selectedTab.backgroundColor.flatMap(rgba) else { return nil }
        return CoreSetDirectoryPresentation(category: category, selections: selections, tint: drawnColor)
    }

    private func applyLocalAppearance() {
        let desired = appearanceDesired()
        appearanceChannel?.updateDesired { $0 = desired }
        guard let consumer = appearanceConsumer, let request = appearanceChannel?.prepareApply() else { rebuildMenu(); return }
        let hostedSource = interactionControlIdentifier
        consumer.apply(request) { [weak self] token, outcome in
            DispatchQueue.main.async {
                guard let self, self.appearanceChannel?.receive(token, outcome: outcome) == true else { return }
                NSLog("Core-SET: hosted input stage=actual control=%@ capability=localRendering confirmed=%d scope=same-meaning-local-theme-and-persistence floating-effect-confirmed=0 device-effect-verified=0",
                      hostedSource, self.appearanceChannel?.isDesiredConfirmed == true ? 1 : 0)
                self.rebuildCurrentPage()
                if self.appearanceChannel?.desired != request.desired,
                   self.appearanceChannel?.phase == .active { self.applyLocalAppearance() }
            }
        }
    }
    private func applyLocalDirectory() {
        let desired = directoryDesired()
        directoryChannel?.updateDesired { $0 = desired }
        guard let consumer = directoryConsumer, let request = directoryChannel?.prepareApply() else { rebuildMenu(); return }
        let hostedSource = interactionControlIdentifier
        consumer.apply(request) { [weak self] token, outcome in
            DispatchQueue.main.async {
                guard let self, self.directoryChannel?.receive(token, outcome: outcome) == true else { return }
                NSLog("Core-SET: hosted input stage=actual control=%@ capability=directoryPreview confirmed=%d scope=same-meaning-local-category-navigation target-material-effect-confirmed=0 device-effect-verified=0",
                      hostedSource, self.directoryChannel?.isDesiredConfirmed == true ? 1 : 0)
                self.rebuildMenu()
                if self.directoryChannel?.desired != request.desired,
                   self.directoryChannel?.phase == .active { self.applyLocalDirectory() }
            }
        }
    }

    private func card(_ title: String, _ frame: CGRect) -> UIView {
        let result = UIView(frame: CGRect(x: frame.minX, y: frame.minY - cardBodyOffset,
                                          width: frame.width, height: frame.height - cardBodyTrim + cardBodyOffset))
        result.backgroundColor = gray(32, 240)
        result.layer.cornerRadius = 5
        result.layer.borderWidth = 1
        result.layer.borderColor = gray(50, 215).cgColor
        result.addSubview(label(title, size: 17,
                                frame: CGRect(x: 10, y: 8, width: frame.width - 20, height: 26)))
        content.addSubview(result)
        pageViews.append(result)
        let body = UIView(frame: CGRect(x: 0, y: cardBodyOffset,
                                       width: frame.width, height: frame.height - cardBodyTrim))
        body.clipsToBounds = true
        result.addSubview(body)
        return body
    }

    private func themeChoice(_ title: String, light: Bool, in card: UIView, x: CGFloat) {
        let button = UIButton(type: .system)
        button.frame = CGRect(x: x, y: 33, width: 100, height: 28)
        button.tag = light ? 1 : 0
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = font(16)
        button.setTitleColor(isLight == light ? .white : gray(255, 80), for: .normal)
        button.backgroundColor = isLight == light ? accent : gray(41, 230)
        button.layer.cornerRadius = 5
        button.accessibilityTraits = isLight == light ? [.button, .selected] : .button
        button.isEnabled = localAppearanceReady
        button.addTarget(self, action: #selector(selectTheme(_:)), for: .touchUpInside)
        card.addSubview(button)
        registerHosted(button, .theme)
    }

    // Selected control types come from static v1.7 menu call sites. Unverified
    // UIKit metrics remain approximations; no runtime values/defaults are supplied.
    private func disabledRows(_ titles: [String], in card: UIView, y: CGFloat, columns: Int = 1,
                              materialFilter: Bool = false, playerScope: CoreSetActorScope? = nil) {
        let count = max(1, columns)
        let materialGrid = count == 3 && titles.count == 6 && titles.first == "显示物资"
        let width = materialGrid ? (card.bounds.width - 40 - 16) / 3 : (card.bounds.width - 24) / CGFloat(count)
        let rows = max(1, Int(ceil(Double(titles.count) / Double(count))))
        let height = min(30, (card.bounds.height - y) / CGFloat(rows))
        var ranges: [String: (Float, Float)] = [
            "FPS 调节": (30, 144), "绘制显示距离": (1, 1000), "骨骼显示距离": (1, 500),
            "背敌指示大小": (40, 160), "射线粗细": (1, 10), "骨骼粗细": (1, 10),
            "物资字体": (5, 30), "最大距离": (10, 500), "自瞄强度": (5, 100),
            "转动平滑": (1, 10), "接管确认帧数": (1, 6), "探测距离": (100, 1000),
            "被瞄预警范围": (20, 300), "预警文字调节": (10, 200), "自瞄圈大小": (30, 525),
            "垂直补偿强度": (0, 100), "水平补偿强度": (0, 100)
        ]
        if materialFilter {
            ranges["最小距离"] = (0, 2000)
            ranges["最大距离"] = (0, 2000)
        }
        ranges.merge(conditionalScenarioRanges) { current, _ in current }
        let checkboxes: Set<String> = [
            "显示射线", "显示方框", "显示距离", "显示骨骼", "隐藏人机", "手雷预警",
            "显示物资", "持枪屏蔽物资", "地铁头甲", "隐藏已开启地铁箱子", "显示地铁箱子等级", "显示载具油量血量",
            "雷达", "显示距离米数", "被瞄预警", "忽略人机",
            "自瞄总开关", "预瞄标记圈", "动态自瞄圈", "显示自瞄圈", "自瞄连接线",
            "倒地不瞄", "瞄准人机", "锁定同目标", "启用压枪", "停火不压", "垂直补偿", "水平补偿"
        ]
        let choices: Set<String> = ["显示手持", "玩家数量", "掩体判断", "人机手持", "人机数量", "显示信息", "背敌指示", "瞄准部位", "触发模式", "场景", "锁定强度"]
        let choiceWidths: [String: [CGFloat]] = [
            "显示手持": [46, 46, 46], "玩家数量": [46, 46, 46], "掩体判断": [46, 46, 46],
            "人机手持": [46, 46, 46], "人机数量": [46, 46, 46], "显示信息": [46, 46, 46],
            "背敌指示": [90, 46, 46], "瞄准部位": [60, 60, 60],
            "触发模式": [60, 60, 84, 84], "场景": [60, 60, 60, 52],
            "锁定强度": [54, 54, 54]
        ]
        for (index, title) in titles.enumerated() {
            let rowX = materialGrid ? 20 + CGFloat(index % count) * (width + 8) : 12 + CGFloat(index % count) * width
            let rowY = materialGrid ? (index < 3 ? y : 35) : y + CGFloat(index / count) * height
            let row = UIView(frame: CGRect(x: rowX, y: rowY,
                                           width: materialGrid ? width : width - 6,
                                           height: materialGrid ? 21 : height - 2))
            let kernelAction = title == "内核利用" || title == "获取信息"
            if kernelAction {
                // Both v1.7 calls use helper 0xca028, vertically separated by Spacing.
                // Height/insets are confirmed; y and the 40-point row step are local
                // UIKit approximations because native content flow/ItemSpacing is unknown.
                row.frame = CGRect(x: 20, y: y + CGFloat(index) * 40,
                                   width: card.bounds.width - 40, height: 30)
            }
            row.isUserInteractionEnabled = false
            row.isAccessibilityElement = true
            row.accessibilityLabel = title
            row.accessibilityHint = "功能尚未接入，原版运行值未验证"
            row.accessibilityTraits = .notEnabled
            let caption = label(title, size: 16,
                                frame: CGRect(x: 0, y: 0, width: row.bounds.width, height: row.bounds.height))
            caption.adjustsFontSizeToFitWidth = true
            caption.minimumScaleFactor = 0.72
            row.addSubview(caption)
            let parts = title.components(separatedBy: "  ")
            if selectedPage == 0 {
                let homePoint: CoreSetHomeProbePoint? = parts[0] == "运行模式" ? .runMode :
                    (parts[0] == "掩体判断" ? .coverMode : (title == "内核利用" ? .kernelAction :
                        (title == "获取信息" ? .informationAction : nil)))
                if let homePoint {
                    row.accessibilityIdentifier = "core-set.0.\(homePoint.stableID).unavailable"
                    if homePoint == .runMode || homePoint == .coverMode {
                        row.isUserInteractionEnabled = true; row.isAccessibilityElement = false
                    }
                }
            }
            if let range = ranges[title] {
                caption.frame = CGRect(x: 0, y: 0, width: width * 0.45, height: height - 2)
                let slider = UISlider(frame: CGRect(x: width * 0.46, y: 0, width: width * 0.50, height: height - 2))
                slider.minimumValue = range.0
                slider.maximumValue = range.1
                slider.isEnabled = false
                // A neutral rail carries no claimed live/default value or thumb position.
                slider.thumbTintColor = .clear
                slider.minimumTrackTintColor = gray(75, 200)
                slider.maximumTrackTintColor = gray(75, 200)
                if selectedPage == 5 {
                    let mapping: [String: (Int, CoreSetField, Int?)] = [
                        "自瞄圈大小": (0, .basicAimCircleSize, featureState.aim.desired.circleSize.value),
                        "最大距离": (1, .basicAimMaximumDistance, featureState.aim.desired.custom.maximumDistance.value),
                        "自瞄强度": (2, .basicAimStrength, featureState.aim.desired.custom.strength.value),
                        "转动平滑": (3, .basicAimSmoothing, featureState.aim.desired.custom.smoothing.value),
                        "水平速度": (4, .basicAimHorizontalSpeed, featureState.aim.desired.custom.horizontalSpeed.value),
                        "垂直速度": (5, .basicAimVerticalSpeed, featureState.aim.desired.custom.verticalSpeed.value),
                        "锁定门槛": (6, .basicAimLockThreshold, featureState.aim.desired.custom.lockThreshold.value),
                        "接管确认帧数": (7, .basicAimConfirmationFrames, featureState.aim.desired.custom.confirmationFrames.value),
                        "接管暂停": (8, .basicAimTakeoverPause, featureState.aim.desired.custom.takeoverPauseMilliseconds.value),
                        "预判提前": (9, .basicAimPredictionMilliseconds, featureState.aim.desired.custom.predictionMilliseconds.value)
                    ]
                    if let item = mapping[title] {
                        slider.tag = item.0
                        slider.value = Float(item.2 ?? Int(range.0))
                        slider.isEnabled = featureState.aim.phase != .applying &&
                            featureState.aim.phase != .active && aimConfigurationAvailable(item.1)
                        slider.thumbTintColor = slider.isEnabled ? accent : .clear
                        slider.accessibilityValue = item.2.map(String.init) ?? "未选择"
                        slider.accessibilityHint = "Core 1.7 同位参数；启用后由共享动作 worker 消费"
                        slider.addTarget(self, action: #selector(configureBasicAimRange(_:)), for: .valueChanged)
                        registerHosted(slider, .aimRange, field: item.1, capability: .aimControl)
                        row.isUserInteractionEnabled = true
                        row.isAccessibilityElement = false
                    }
                } else if title == "绘制显示距离" || title == "骨骼显示距离" ||
                    title == "背敌指示大小" || title == "探测距离" ||
                    (materialFilter && (title == "最小距离" || title == "最大距离")) {
                    let materialRange = materialFilter && (title == "最小距离" || title == "最大距离")
                    let field: CoreSetField = materialRange ? .materialDistance :
                        (title == "绘制显示距离" ? .drawingDistance :
                         title == "骨骼显示距离" ? .boneDistance :
                         (title == "背敌指示大小" ? .backSize : .radarDetectionDistance))
                    let ready = materialRange ? canStage(featureState.materials) &&
                        controlAvailability(field, in: featureState.materials) == .ready :
                        (title == "探测距离" ? canStage(featureState.radar) &&
                         controlAvailability(field, in: featureState.radar) == .ready :
                         canStage(featureState.player) && controlAvailability(field, in: featureState.player) == .ready)
                    let distance = featureState.materials.desired.categories[previewMaterialCategory].distance
                    let current = materialRange ? (title == "最小距离" ? distance.minimum : distance.maximum) :
                        (title == "绘制显示距离" ? featureState.player.desired.drawingDistance.value :
                         title == "骨骼显示距离" ? featureState.player.desired.boneDistance.value :
                         (title == "背敌指示大小" ? featureState.player.desired.backSize.value :
                          featureState.radar.desired.detectionDistance.value))
                    slider.tag = materialRange ? (title == "最小距离" ? 3 : 4) :
                        (title == "绘制显示距离" ? 5 :
                         title == "骨骼显示距离" ? 0 : (title == "背敌指示大小" ? 1 : 2))
                    slider.value = Float(current ?? Int(range.0))
                    slider.isEnabled = ready
                    slider.thumbTintColor = ready ? accent : .clear
                    slider.accessibilityValue = current.map { String($0) } ?? "未选择"
                    slider.addTarget(self, action: #selector(changeBoundRange(_:)), for: .valueChanged)
                    registerHosted(slider, .boundRange, field: field,
                        capability: materialRange ? .materialFiltering : (title == "探测距离" ? .radarRendering : .playerRendering))
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                } else if selectedPage == 6 &&
                            (title == "垂直补偿强度" || title == "水平补偿强度") {
                    let vertical = title == "垂直补偿强度"
                    let field: CoreSetField = vertical ? .recoilVerticalStrength : .recoilHorizontalStrength
                    let current = vertical ? featureState.recoil.desired.verticalStrength.value :
                        featureState.recoil.desired.horizontalStrength.value
                    let ready = recoilConfigurationAvailable(field)
                    slider.tag = vertical ? 0 : 1
                    slider.value = Float(current ?? Int(range.0))
                    slider.isEnabled = ready
                    slider.thumbTintColor = ready ? accent : .clear
                    slider.accessibilityValue = current.map(String.init) ?? "未选择"
                    slider.accessibilityHint = "保存0...100配置并归一化；参数完整后提交共享压枪 worker"
                    slider.addTarget(self, action: #selector(configureRecoilStrength(_:)), for: .valueChanged)
                    registerHosted(slider, .recoilStrength, field: field, capability: .recoilControl)
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                } else if title == "射线粗细" || title == "骨骼粗细" || title == "物资字体" {
                    let field: CoreSetField = title == "射线粗细" ? .rayThickness :
                        (title == "骨骼粗细" ? .boneThickness : .materialFontSize)
                    let ready = canStage(featureState.adjustments) &&
                        controlAvailability(field, in: featureState.adjustments) == .ready
                    let current = title == "射线粗细" ? featureState.adjustments.desired.rayThickness.value :
                        (title == "骨骼粗细" ? featureState.adjustments.desired.boneThickness.value :
                         featureState.adjustments.desired.materialFontSize.value)
                    slider.tag = title == "射线粗细" ? 0 : (title == "骨骼粗细" ? 1 : 2)
                    slider.value = Float(current ?? Int(range.0))
                    slider.isEnabled = ready
                    slider.thumbTintColor = ready ? accent : .clear
                    slider.accessibilityValue = current.map { String($0) } ?? "未选择"
                    slider.addTarget(self, action: #selector(changeAdjustmentRange(_:)), for: .valueChanged)
                    registerHosted(slider, .adjustmentRange, field: field, capability: .drawingAppearance)
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                } else if title == "自瞄圈大小" {
                    let ready = canStage(featureState.aimDisplay) &&
                        controlAvailability(.localAimCircleSize, in: featureState.aimDisplay) == .ready
                    let current = featureState.aimDisplay.desired.circleSize.value
                    slider.value = Float(current ?? Int(range.0))
                    slider.isEnabled = ready
                    slider.thumbTintColor = ready ? accent : .clear
                    slider.accessibilityValue = current.map { String($0) } ?? "未选择"
                    slider.accessibilityHint = "仅本地 HUD 预览圈半径，不是自瞄范围或目标动作"
                    slider.addTarget(self, action: #selector(changeLocalAimCircleSize(_:)), for: .valueChanged)
                    registerHosted(slider, .localAimCircleSize, field: .localAimCircleSize, capability: .localAimDisplay)
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                } else if title == "最大距离" && !materialFilter {
                    let ready = canStage(featureState.aimDisplay) &&
                        controlAvailability(.localAimPreviewDistance, in: featureState.aimDisplay) == .ready
                    let current = featureState.aimDisplay.desired.maximumDistance.value
                    slider.value = Float(current ?? Int(range.0))
                    slider.isEnabled = ready
                    slider.thumbTintColor = ready ? accent : .clear
                    slider.accessibilityValue = current.map { String($0) } ?? "未选择"
                    slider.accessibilityHint = "只限制本地预览候选距离，不改变自瞄控制"
                    slider.addTarget(self, action: #selector(changeLocalAimPreviewDistance(_:)), for: .valueChanged)
                    registerHosted(slider, .localAimPreviewDistance, field: .localAimPreviewDistance, capability: .localAimDisplay)
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                } else if title == "FPS 调节" {
                    let ready = canStage(featureState.frameRate) &&
                        controlAvailability(.framesPerSecond, in: featureState.frameRate) == .ready
                    let current = featureState.frameRate.desired.framesPerSecond.value
                    slider.value = Float(current ?? Int(range.0))
                    slider.isEnabled = ready
                    slider.thumbTintColor = ready ? accent : .clear
                    slider.accessibilityValue = current.map { String($0) } ?? "未选择"
                    slider.accessibilityHint = ready ? "仅可回读的 Metal 调度器；CA 事件驱动不可设置固定 FPS" :
                        "当前渲染后端没有可回读的固定 FPS 调度器"
                    slider.addTarget(self, action: #selector(changeFrameRate(_:)), for: .valueChanged)
                    registerHosted(slider, .frameRate, field: .framesPerSecond, capability: .frameScheduling)
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                } else if title == "被瞄预警范围" || title == "预警文字调节" {
                    let field: CoreSetField = title == "被瞄预警范围" ? .warningRange : .warningTextSize
                    let ready = canStage(featureState.radar) &&
                        controlAvailability(field, in: featureState.radar) == .ready
                    let current = title == "被瞄预警范围" ?
                        featureState.radar.desired.warningRange.value :
                        featureState.radar.desired.warningTextSize.value
                    slider.tag = title == "被瞄预警范围" ? 0 : 1
                    slider.value = Float(current ?? Int(range.0))
                    slider.isEnabled = ready
                    slider.thumbTintColor = ready ? accent : .clear
                    slider.accessibilityValue = current.map { String($0) } ?? "未选择"
                    slider.accessibilityHint = "仅 Core 主分支 ServerControlRotation.Yaw 的只读预警子集"
                    slider.addTarget(self, action: #selector(changeWarningRange(_:)), for: .valueChanged)
                    registerHosted(slider, .warningRange, field: field, capability: .radarRendering)
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                }
                row.addSubview(slider)
            } else if parts.count == 2 && choices.contains(parts[0]), let itemWidths = choiceWidths[parts[0]] {
                caption.text = parts[0]
                let options = parts[1].components(separatedBy: " / ")
                guard options.count == itemWidths.count else { continue }
                let groupWidth = itemWidths.reduce(0, +) + CGFloat(max(0, options.count - 1)) * 6
                let right = count == 1 ? card.bounds.width - 20 - row.frame.minX : row.bounds.width
                let groupX = max(0, right - groupWidth)
                caption.frame.size.width = max(0, groupX - 8)
                var optionX = groupX
                for (optionIndex, option) in options.enumerated() {
                    let selection = UIButton(type: .system)
                    selection.frame = CGRect(x: optionX, y: (row.bounds.height - 22) / 2,
                                             width: itemWidths[optionIndex], height: 22)
                    optionX += itemWidths[optionIndex] + 6
                    selection.layer.cornerRadius = 5
                    selection.backgroundColor = gray(41, 230)
                    selection.setTitle(option, for: .normal)
                    if selectedPage == 0, parts[0] == "掩体判断" {
                        selection.tag = optionIndex
                        selection.accessibilityLabel = "掩体判断  \(option)"
                        selection.accessibilityIdentifier = "core-set.0.v17-001.option\(optionIndex).configured"
                        let values: [CoreSetCoverMode] = [.global, .inGame, .off]
                        selection.isEnabled = values.indices.contains(optionIndex)
                        selection.isSelected = selection.isEnabled &&
                            featureState.home.desired.coverMode == values[optionIndex]
                        selection.backgroundColor = selection.isSelected ? accent : gray(41, 230)
                        selection.accessibilityHint = "已闭合原版0/1/2配置与静态输出 ABI；运行时 row 连续身份及真机遮挡消费者待验证"
                        selection.addTarget(self, action: #selector(configureHomeCoverMode(_:)), for: .touchUpInside)
                        registerHosted(selection, .homeCoverMode)
                        row.isUserInteractionEnabled = true
                        row.isAccessibilityElement = false
                    }
                    selection.titleLabel?.font = font(16)
                    selection.titleLabel?.adjustsFontSizeToFitWidth = true
                    selection.titleLabel?.minimumScaleFactor = 0.72
                    selection.setTitleColor(gray(255, 80), for: .normal)
                    if selectedPage == 5 && ["瞄准部位", "触发模式", "锁定强度"].contains(parts[0]) {
                        let base = parts[0] == "瞄准部位" ? 100 : (parts[0] == "触发模式" ? 200 : 300)
                        let field: CoreSetField = parts[0] == "瞄准部位" ? .basicAimPoint :
                            (parts[0] == "触发模式" ? .basicAimTrigger : .basicAimLockStrength)
                        let selected: Bool
                        if parts[0] == "瞄准部位" {
                            selected = featureState.aim.desired.point?.rawValue == optionIndex
                        } else if parts[0] == "触发模式" {
                            let values: [CoreSetAimTrigger] = [.scopeOnly, .fireOnly, .either, .both]
                            selected = values.indices.contains(optionIndex) &&
                                featureState.aim.desired.trigger == values[optionIndex]
                        } else {
                            let values: [CoreSetLockStrength] = [.strong, .medium, .light]
                            selected = values.indices.contains(optionIndex) &&
                                featureState.aim.desired.lockStrength == values[optionIndex]
                        }
                        selection.tag = base + optionIndex
                        selection.isEnabled = featureState.aim.phase != .applying &&
                            featureState.aim.phase != .active && aimConfigurationAvailable(field)
                        selection.isSelected = selected
                        selection.backgroundColor = selected ? accent : gray(41, 230)
                        selection.addTarget(self, action: #selector(selectAimChoice(_:)), for: .touchUpInside)
                        registerHosted(selection, .aimChoice, field: field, capability: .aimControl)
                        row.isUserInteractionEnabled = true
                        row.isAccessibilityElement = false
                    } else if parts[0] == "背敌指示" {
                        let ready = canStage(featureState.player) &&
                            controlAvailability(.backIndicator, in: featureState.player) == .ready
                        let configured = featureState.player.desired.backStyle != nil &&
                            featureState.player.desired.backSize.value != nil
                        selection.tag = optionIndex
                        selection.isEnabled = ready && (optionIndex == 2 || configured)
                        selection.isSelected = featureState.player.desired.backIndicator?.rawValue == optionIndex
                        selection.backgroundColor = selection.isSelected ? accent : gray(41, 230)
                        selection.addTarget(self, action: #selector(selectBackIndicator(_:)), for: .touchUpInside)
                        registerHosted(selection, .backIndicator, field: .backIndicator, capability: .playerRendering)
                        row.isUserInteractionEnabled = true
                        row.isAccessibilityElement = false
                    } else if parts[0] == "显示手持" || parts[0] == "人机手持" {
                        let scope: CoreSetActorScope = parts[0] == "显示手持" ? .player : .bot
                        let weapon = scope == .player ? featureState.player.desired.player.weapon :
                            featureState.player.desired.bot.weapon
                        let ready = canStage(featureState.player) &&
                            controlAvailability(.actor(scope, .weapon), in: featureState.player) == .ready
                        selection.tag = (scope == .player ? 0 : 3) + optionIndex
                        selection.isEnabled = ready &&
                            (optionIndex != 0 || CoreSetWeaponImageCatalog.isReady())
                        selection.isSelected = optionIndex == 0 ?
                            (weapon.enabled == true && weapon.mode == .image) :
                            (optionIndex == 1 ? (weapon.enabled == true && weapon.mode == .text) :
                             weapon.enabled == false)
                        selection.backgroundColor = selection.isSelected ? accent : gray(41, 230)
                        selection.accessibilityHint = optionIndex == 0 &&
                            !CoreSetWeaponImageCatalog.isReady() ? "武器图片资源加载或校验未完成" : nil
                        selection.addTarget(self, action: #selector(selectPlayerWeaponMode(_:)), for: .touchUpInside)
                        registerHosted(selection, .playerWeaponMode, field: .actor(scope, .weapon), capability: .playerRendering)
                        row.isUserInteractionEnabled = true
                        row.isAccessibilityElement = false
                    } else if parts[0] == "玩家数量" || parts[0] == "人机数量" {
                        let scope: CoreSetActorScope = parts[0] == "玩家数量" ? .player : .bot
                        let count = scope == .player ? featureState.player.desired.player.count :
                            featureState.player.desired.bot.count
                        let ready = canStage(featureState.player) &&
                            controlAvailability(.actor(scope, .count), in: featureState.player) == .ready
                        let selectedMode: CoreSetCountMode = optionIndex == 0 ? .detailed : .compact
                        selection.tag = (scope == .player ? 0 : 3) + optionIndex
                        selection.isEnabled = ready
                        selection.isSelected = optionIndex == 2 ? count.enabled == false :
                            (count.enabled == true && count.mode == selectedMode)
                        selection.backgroundColor = selection.isSelected ? accent : gray(41, 230)
                        selection.addTarget(self, action: #selector(selectPlayerCountMode(_:)), for: .touchUpInside)
                        registerHosted(selection, .playerCountMode, field: .actor(scope, .count), capability: .playerRendering)
                        row.isUserInteractionEnabled = true
                        row.isAccessibilityElement = false
                    } else if parts[0] == "显示信息", let scope = playerScope {
                        let information = scope == .player ? featureState.player.desired.player.information :
                            featureState.player.desired.bot.information
                        let ready = canStage(featureState.player) &&
                            controlAvailability(.actor(scope, .information), in: featureState.player) == .ready
                        let selectedMode: CoreSetInformationMode = optionIndex == 0 ? .modern : .minimal
                        selection.tag = (scope == .player ? 0 : 3) + optionIndex
                        selection.isEnabled = ready
                        selection.isSelected = optionIndex == 2 ? information.enabled == false :
                            (information.enabled == true && information.mode == selectedMode)
                        selection.backgroundColor = selection.isSelected ? accent : gray(41, 230)
                        selection.accessibilityHint = "仅已证名称/队伍/生命/距离/手持字段；文字布局为本地子集"
                        selection.addTarget(self, action: #selector(selectPlayerInformationMode(_:)), for: .touchUpInside)
                        registerHosted(selection, .playerInformationMode, field: .actor(scope, .information), capability: .playerRendering)
                        row.isUserInteractionEnabled = true
                        row.isAccessibilityElement = false
                    } else if !(selectedPage == 0 && parts[0] == "掩体判断") {
                        selection.isEnabled = false
                    }
                    row.addSubview(selection)
                }
            } else if parts.count == 2 && parts[0] == "运行模式" {
                caption.text = parts[0]
                caption.frame = CGRect(x: 0, y: 0, width: 66, height: height - 2)
                for (optionIndex, option) in parts[1].components(separatedBy: " / ").enumerated() {
                    // v1.7 helper 0x1000d1900 uses rounded button-like selection,
                    // not circles. Width/spacing below remain UIKit approximations.
                    let origin = CGFloat(70 + optionIndex * 90)
                    let selection = UIButton(type: .system)
                    selection.frame = CGRect(x: origin, y: 2, width: 84, height: height - 6)
                    selection.layer.cornerRadius = 5
                    selection.backgroundColor = gray(41, 230)
                    selection.setTitle(option, for: .normal)
                    selection.titleLabel?.font = font(16)
                    selection.setTitleColor(gray(255, 80), for: .normal)
                    selection.isEnabled = true
                    selection.tag = optionIndex
                    selection.accessibilityLabel = "运行模式  \(option)"
                    selection.accessibilityIdentifier = "core-set.0.v17-000.option\(optionIndex).configured"
                    let values: [CoreSetRunMode] = [.safe, .efficiency]
                    selection.isSelected = values.indices.contains(optionIndex) &&
                        featureState.home.desired.runMode == values[optionIndex]
                    selection.backgroundColor = selection.isSelected ? accent : gray(41, 230)
                    selection.accessibilityHint = "同步原版0/1归一化配置；Core镜像中没有独立运行消费者"
                    selection.addTarget(self, action: #selector(configureHomeRunMode(_:)), for: .touchUpInside)
                    registerHosted(selection, .homeRunMode)
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(selection)
                }
            } else if title == "全开" || title == "全关" || kernelAction {
                caption.isHidden = true
                let action = UIButton(type: .system)
                action.frame = row.bounds
                action.setTitle(title, for: .normal)
                action.titleLabel?.font = font(16)
                action.setTitleColor(gray(255, 80), for: .normal)
                action.backgroundColor = gray(41, 230)
                action.layer.cornerRadius = kernelAction ? 6 : 5
                action.layer.borderWidth = kernelAction ? 1 : 0
                action.layer.borderColor = gray(50, 215).cgColor
                action.isEnabled = false
                if kernelAction {
                    let point: CoreSetHomeProbePoint = title == "内核利用" ? .kernelAction : .informationAction
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    action.isEnabled = onHomeAction != nil && !homeActionsInFlight.contains(point)
                    action.accessibilityValue = homeActionsInFlight.contains(point) ? "执行中" : "可执行"
                    action.accessibilityHint = title == "内核利用" ?
                        "启动本应用 DarkSword 初始化并由主页状态生产者回读" :
                        "读取 kernelcache、解析当前设备偏移并由主页状态生产者回读"
                    if point == .kernelAction {
                        action.addTarget(self, action: #selector(startHomeKernelAction(_:)), for: .touchUpInside)
                        registerHosted(action, .homeKernelAction)
                    } else {
                        action.addTarget(self, action: #selector(startHomeInformationAction(_:)), for: .touchUpInside)
                        registerHosted(action, .homeInformationAction)
                    }
                } else if materialFilter && (title == "全开" || title == "全关") {
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    action.isEnabled = materialGroupEditingReady
                    action.tag = title == "全开" ? 1 : 0
                    action.accessibilityHint = "更新当前分类的名称模式选择；生效需物资 lane 精确回执"
                    action.addTarget(self, action: #selector(setAllMaterialGroups(_:)), for: .touchUpInside)
                    registerHosted(action, .allMaterialGroups, field: .materialGroupSelection, capability: .materialFiltering)
                }
                row.addSubview(action)
            } else if materialFilter && title == "分类颜色" {
                caption.isHidden = true
                row.isUserInteractionEnabled = true
                row.isAccessibilityElement = false
                colorEditRow(title, target: .material(previewMaterialCategory), in: row, frame: row.bounds, labelInset: 0)
            } else if checkboxes.contains(title) {
                // Checkbox geometry: v1.7 helper 0x1000c8928, side 21/right inset 20.
                let right = columns == 1 ? card.bounds.width - 20 - row.frame.minX : row.bounds.width
                let box = UIView(frame: CGRect(x: right - 21, y: (row.bounds.height - 21) / 2, width: 21, height: 21))
                box.layer.cornerRadius = 3
                box.layer.borderWidth = 1.5
                box.layer.borderColor = gray(75, 200).cgColor
                row.addSubview(box)
                caption.frame.size.width = max(0, box.frame.minX - 8)
                if selectedPage == 5 && ["自瞄总开关", "倒地不瞄", "瞄准人机", "锁定同目标"].contains(title) {
                    let mapping: [String: (Int, CoreSetField, Bool?)] = [
                        "自瞄总开关": (0, .basicAimEnabled, featureState.aim.desired.enabled),
                        "倒地不瞄": (5, .basicAimExcludeKnocked, featureState.aim.desired.excludeKnocked),
                        "瞄准人机": (6, .basicAimIncludeBots, featureState.aim.desired.includeBots),
                        "锁定同目标": (7, .basicAimLockSameTarget, featureState.aim.desired.lockSameTarget)
                    ]
                    guard let item = mapping[title] else { continue }
                    let stopping = title == "自瞄总开关" &&
                        (featureState.aim.restoration == .required || featureState.aim.restoration == .pending ||
                         featureState.aim.phase == .active || featureState.aim.desired.enabled == true)
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.tag = item.0
                    button.isEnabled = featureState.aim.restoration != .pending &&
                        (stopping || (featureState.aim.phase != .applying && featureState.aim.phase != .active &&
                         aimConfigurationAvailable(item.1)))
                    button.isSelected = item.2 == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = item.2.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = "Core 1.7 同位字段；动作结果以 aimControl 回执为准"
                    if title == "自瞄总开关" {
                        button.addTarget(self, action: stopping ? #selector(stopBasicAim) : #selector(startBasicAim),
                                         for: .touchUpInside)
                        registerHosted(button, stopping ? .aimStop : .aimStart,
                                       field: .basicAimEnabled, capability: .aimControl)
                    } else {
                        button.addTarget(self, action: #selector(toggleAimConfigurationField(_:)), for: .touchUpInside)
                        registerHosted(button, .aimConfigurationField, field: item.1, capability: .aimControl)
                    }
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if selectedPage == 6 &&
                            ["启用压枪", "停火不压", "垂直补偿", "水平补偿"].contains(title) {
                    let mapping: [String: (Int, CoreSetField, Bool?)] = [
                        "启用压枪": (0, .recoilEnabled, featureState.recoil.desired.enabled),
                        "停火不压": (1, .recoilStopWhenNotFiring, featureState.recoil.desired.stopWhenNotFiring.enabled),
                        "垂直补偿": (2, .recoilVerticalEnabled, featureState.recoil.desired.verticalEnabled),
                        "水平补偿": (3, .recoilHorizontalEnabled, featureState.recoil.desired.horizontalEnabled)
                    ]
                    guard let item = mapping[title] else { continue }
                    let ready = recoilConfigurationAvailable(item.1)
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.tag = item.0
                    button.isEnabled = ready
                    button.isSelected = item.2 == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = item.2.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = "保存压枪配置；参数完整后提交共享压枪 worker并等待回读"
                    button.addTarget(self, action: #selector(toggleRecoilField(_:)), for: .touchUpInside)
                    registerHosted(button, .recoilField, field: item.1, capability: .recoilControl)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if let scope = playerScope,
                   let toggle = playerToggle(title: title, scope: scope) {
                    let ready = canStage(featureState.player) &&
                        controlAvailability(toggle.field, in: featureState.player) == .ready
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.tag = toggle.tag
                    button.isEnabled = ready
                    button.isSelected = toggle.value == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = toggle.value.map { $0 ? "开启" : "关闭" } ?? "未知"
                    button.accessibilityHint = ready ? "请求目标只读玩家消费者；须等本地帧精确回执" : "目标身份会话未就绪或字段未支持"
                    button.accessibilityTraits = button.isSelected ? [.button, .selected] : .button
                    button.addTarget(self, action: #selector(togglePlayerField(_:)), for: .touchUpInside)
                    registerHosted(button, .playerField, field: toggle.field, capability: .playerRendering)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.addSubview(button)
                } else if title == "显示自瞄圈" {
                    let previewReady = canStage(featureState.aimDisplay) &&
                        controlAvailability(.localAimCircle, in: featureState.aimDisplay) == .ready
                    let actionReady = aimConfigurationAvailable(.basicAimShowCircle)
                    let value = featureState.aim.desired.showCircle ??
                        featureState.aimDisplay.desired.circleVisible
                    let observed = featureState.aimDisplay.actual?.circleVisible == true &&
                        featureState.aimDisplay.phase == .active
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.isEnabled = actionReady || (previewReady && (observed ||
                        featureState.aimDisplay.desired.circleSize.value != nil))
                    button.isSelected = observed
                    button.accessibilityLabel = "显示自瞄圈（仅本地预览）"
                    button.accessibilityValue = observed ? "本地已显示" :
                        (value == true ? "待重新应用" : (value == false ? "关闭" : "未选择"))
                    button.accessibilityHint = "保存原版显示圈配置；本地 HUD 可用时另等独立帧回执，不启动目标动作"
                    button.addTarget(self, action: #selector(toggleLocalAimCircle(_:)), for: .touchUpInside)
                    registerHosted(button, .localAimCircle, field: .localAimCircle, capability: .localAimDisplay)
                    box.backgroundColor = observed ? accent : (value == true ? accent.withAlphaComponent(0.35) : .clear)
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if title == "自瞄连接线" || title == "预瞄标记圈" ||
                    title == "动态自瞄圈" || title == "瞄准人机" {
                    let field: CoreSetField = title == "自瞄连接线" ? .localAimPreviewLine :
                        (title == "预瞄标记圈" ? .localAimPreviewMarker :
                         (title == "动态自瞄圈" ? .localAimDynamicCircle : .localAimPreviewBots))
                    let previewReady = canStage(featureState.aimDisplay) &&
                        controlAvailability(field, in: featureState.aimDisplay) == .ready
                    let state = featureState.aimDisplay.desired
                    let actionState = featureState.aim.desired
                    let actionField: CoreSetField = title == "自瞄连接线" ? .basicAimConnectionLine :
                        (title == "预瞄标记圈" ? .basicAimPreaimCircle :
                         (title == "动态自瞄圈" ? .basicAimDynamicCircle : .basicAimIncludeBots))
                    let actionReady = aimConfigurationAvailable(actionField)
                    let value = title == "自瞄连接线" ? (actionState.connectionLine ?? state.connectionLine) :
                        (title == "预瞄标记圈" ? (actionState.preaimCircle ?? state.preaimMarker) :
                         (title == "动态自瞄圈" ? (actionState.dynamicCircle.enabled ?? state.dynamicCircle) :
                          (actionState.includeBots ?? state.includeBots)))
                    let selected = title == "自瞄连接线" ? featureState.aimDisplay.actual?.connectionLine :
                        (title == "预瞄标记圈" ? featureState.aimDisplay.actual?.preaimMarker :
                         (title == "动态自瞄圈" ? featureState.aimDisplay.actual?.dynamicCircle :
                          featureState.aimDisplay.actual?.includeBots))
                    let configured = state.circleSize.value != nil &&
                        state.maximumDistance.value != nil &&
                        (title != "动态自瞄圈" || state.circleVisible == true)
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.tag = title == "自瞄连接线" ? 0 :
                        (title == "预瞄标记圈" ? 1 : (title == "动态自瞄圈" ? 2 : 3))
                    button.isEnabled = actionReady || (previewReady &&
                        (button.tag == 3 || configured || value == true))
                    button.isSelected = selected == true && featureState.aimDisplay.phase == .active
                    button.accessibilityLabel = "\(title)（仅本地预览）"
                    button.accessibilityValue = button.isSelected ? "本地已显示" :
                        (value == true ? "待重新应用" : (value == false ? "关闭" : "未选择"))
                    button.accessibilityHint = "保存原版配置；只读预选 HUD 可用时另等独立帧回执，不启动目标动作"
                    if !button.isEnabled {
                        button.accessibilityHint = "先设置本地圈大小和预览距离；动态圈还需开启本地圈，且尚未生效"
                    }
                    button.addTarget(self, action: #selector(toggleLocalAimPreviewField(_:)), for: .touchUpInside)
                    registerHosted(button, .localAimPreviewField, field: field, capability: .localAimDisplay)
                    box.backgroundColor = button.isSelected ? accent : (value == true ? accent.withAlphaComponent(0.35) : .clear)
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if materialGrid && title == "显示物资" {
                    let ready = canStage(featureState.materials) &&
                        controlAvailability(.materialEnabled, in: featureState.materials) == .ready
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    // Core's C+0x2a total checkbox is independent from every
                    // category range/color record. Keep it clickable and let
                    // the consumer return the exact missing configuration.
                    button.isEnabled = ready
                    button.isSelected = featureState.materials.desired.enabled == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = featureState.materials.desired.enabled.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = button.isEnabled ? "请求独立物资 lane；缺少距离或颜色时会明确提示" :
                        "目标只读会话未就绪"
                    button.addTarget(self, action: #selector(toggleMaterialEnabled(_:)), for: .touchUpInside)
                    registerHosted(button, .materialEnabled, field: .materialEnabled, capability: .materialFiltering)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if materialGrid && title == "持枪屏蔽物资" {
                    let ready = canStage(featureState.materials) &&
                        controlAvailability(.hideWhileArmed, in: featureState.materials) == .ready
                    let value = featureState.materials.desired.hideWhileArmed
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.isEnabled = ready
                    button.isSelected = value == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = value.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = ready ? "本地武器 ID 非零时仅清物资 lane；须等精确帧回执" :
                        "目标只读会话未就绪或字段未支持"
                    button.addTarget(self, action: #selector(toggleHideWhileArmed(_:)), for: .touchUpInside)
                    registerHosted(button, .hideWhileArmed, field: .hideWhileArmed, capability: .materialFiltering)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if materialGrid && title == "地铁头甲" {
                    let ready = canStage(featureState.materials) &&
                        controlAvailability(.metroArmor, in: featureState.materials) == .ready
                    let value = featureState.materials.desired.metroArmor
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.isEnabled = ready
                    button.isSelected = value == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = value.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = ready ? "只显示目标角色第 9/10 装备槽已知 ID 的头甲标签" :
                        "目标只读会话未就绪或字段未支持"
                    button.addTarget(self, action: #selector(toggleMetroArmor(_:)), for: .touchUpInside)
                    registerHosted(button, .metroArmor, field: .metroArmor, capability: .materialFiltering)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if materialGrid && title == "隐藏已开启地铁箱子" {
                    let ready = canStage(featureState.materials) &&
                        controlAvailability(.hideOpenedCrates, in: featureState.materials) == .ready
                    let value = featureState.materials.desired.hideOpenedCrates
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.isEnabled = ready
                    button.isSelected = value == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = value.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = ready ? "仅按 Core 规则隐藏 Children.Num 为 1 的 EscapeBox" :
                        "目标只读会话未就绪或字段未支持"
                    button.addTarget(self, action: #selector(toggleHideOpenedCrates(_:)), for: .touchUpInside)
                    registerHosted(button, .hideOpenedCrates, field: .hideOpenedCrates, capability: .materialFiltering)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if materialGrid && title == "显示地铁箱子等级" {
                    let ready = canStage(featureState.materials) &&
                        controlAvailability(.showCrateLevel, in: featureState.materials) == .ready
                    let value = featureState.materials.desired.showCrateLevel
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.isEnabled = ready
                    button.isSelected = value == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = value.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = ready ? "只显示 EscapeBox 名称中明确的 Lv 等级；不推断开启状态" :
                        "目标只读会话未就绪或字段未支持"
                    button.addTarget(self, action: #selector(toggleCrateLevel(_:)), for: .touchUpInside)
                    registerHosted(button, .crateLevel, field: .showCrateLevel, capability: .materialFiltering)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if materialGrid && title == "显示载具油量血量" {
                    let ready = canStage(featureState.materials) &&
                        controlAvailability(.vehicleStatus, in: featureState.materials) == .ready
                    let value = featureState.materials.desired.vehicleStatus
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.isEnabled = ready
                    button.isSelected = value == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = value.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = ready ? "仅对目标车辆类显示已验证的血量和油量百分比" :
                        "目标只读会话未就绪或字段未支持"
                    button.addTarget(self, action: #selector(toggleVehicleStatus(_:)), for: .touchUpInside)
                    registerHosted(button, .vehicleStatus, field: .vehicleStatus, capability: .materialFiltering)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if title == "雷达" || title == "显示距离米数" {
                    let field: CoreSetField = title == "雷达" ? .radarEnabled : .radarShowDistance
                    let ready = canStage(featureState.radar) &&
                        controlAvailability(field, in: featureState.radar) == .ready
                    let value = title == "雷达" ? featureState.radar.desired.enabled :
                        featureState.radar.desired.showDistance
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.tag = title == "雷达" ? 0 : 1
                    button.isEnabled = ready
                    button.isSelected = value == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = value.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = button.isEnabled ? "请求独立雷达 lane；生效需精确回执" :
                        "雷达字段配置会话尚未就绪"
                    button.addTarget(self, action: #selector(toggleRadarField(_:)), for: .touchUpInside)
                    registerHosted(button, .radarField, field: field, capability: .radarRendering)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                } else if title == "被瞄预警" || title == "忽略人机" {
                    let field: CoreSetField = title == "被瞄预警" ? .warningEnabled : .warningIgnoreBots
                    let ready = canStage(featureState.radar) &&
                        controlAvailability(field, in: featureState.radar) == .ready
                    let value = title == "被瞄预警" ? featureState.radar.desired.warningEnabled :
                        featureState.radar.desired.ignoreBots
                    let button = UIButton(type: .custom)
                    button.frame = row.bounds
                    button.tag = title == "被瞄预警" ? 0 : 1
                    button.isEnabled = ready
                    button.isSelected = value == true
                    button.accessibilityLabel = title
                    button.accessibilityValue = value.map { $0 ? "开启" : "关闭" } ?? "未选择"
                    button.accessibilityHint = button.isEnabled ? "独立 warning lane；生效须双 lane 精确回执" :
                        "预警字段配置会话尚未就绪"
                    button.addTarget(self, action: #selector(toggleWarningField(_:)), for: .touchUpInside)
                    registerHosted(button, .warningField, field: field, capability: .radarRendering)
                    box.backgroundColor = button.isSelected ? accent : .clear
                    row.isUserInteractionEnabled = true
                    row.isAccessibilityElement = false
                    row.addSubview(button)
                }
            }
            // Unclassified status/action/category rows retain text only. No generic
            // checkbox is substituted for an unverified native widget type.
            if ranges[title] == nil && parts.count != 2 && !checkboxes.contains(title) {
                caption.adjustsFontSizeToFitWidth = true
                caption.minimumScaleFactor = 0.72
            }
            card.addSubview(row)
        }
    }

    private func playerToggle(title: String, scope: CoreSetActorScope)
        -> (field: CoreSetField, tag: Int, value: Bool?)? {
        if title == "隐藏人机" { return (.hideBots, 6, featureState.player.desired.hideBots) }
        if title == "手雷预警" { return (.grenadeWarning, 9, featureState.player.desired.grenadeWarning) }
        if title == "显示骨骼" {
            let value = scope == .player ? featureState.player.desired.player.bones : featureState.player.desired.bot.bones
            return (.actor(scope, .bones), scope == .player ? 7 : 8, value)
        }
        let base = scope == .player ? 0 : 3
        let display = scope == .player ? featureState.player.desired.player : featureState.player.desired.bot
        switch title {
        case "显示射线": return (.actor(scope, .ray), base, display.ray)
        case "显示方框": return (.actor(scope, .box), base + 1, display.box)
        case "显示距离": return (.actor(scope, .distance), base + 2, display.distance)
        default: return nil
        }
    }

    @objc private func togglePlayerField(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard (0...9).contains(sender.tag) else { return }
        let scope: CoreSetActorScope = sender.tag < 3 || sender.tag == 6 || sender.tag == 7 ? .player : .bot
        let title = sender.tag == 9 ? "手雷预警" :
            (sender.tag >= 7 ? "显示骨骼" : ["显示射线", "显示方框", "显示距离"][sender.tag % 3])
        guard let toggle = playerToggle(title: sender.tag == 6 ? "隐藏人机" : title, scope: scope),
              canStage(featureState.player),
              controlAvailability(toggle.field, in: featureState.player) == .ready else { return }
        editGame(\.player) { state in
            if sender.tag == 6 { state.hideBots = !(state.hideBots ?? false); return }
            if sender.tag == 9 { state.grenadeWarning = !(state.grenadeWarning ?? false); return }
            let enabled = !(toggle.value ?? false)
            if scope == .player {
                switch sender.tag { case 0: state.player.ray = enabled
                case 1: state.player.box = enabled
                case 7: state.player.bones = enabled
                default: state.player.distance = enabled }
            } else {
                switch sender.tag { case 3: state.bot.ray = enabled
                case 4: state.bot.box = enabled
                case 8: state.bot.bones = enabled
                default: state.bot.distance = enabled }
            }
        }
    }

    @objc private func changeBoundRange(_ sender: UISlider) {
        refreshBeforeInteraction(sender)
        let value = Int(sender.value.rounded())
        switch sender.tag {
        case 0:
            guard canStage(featureState.player),
                  controlAvailability(.boneDistance, in: featureState.player) == .ready else { return }
            editGame(\.player) { $0.boneDistance.set(value) }
        case 5:
            guard canStage(featureState.player),
                  controlAvailability(.drawingDistance, in: featureState.player) == .ready else { return }
            editGame(\.player) { $0.drawingDistance.set(value) }
        case 1:
            guard canStage(featureState.player),
                  controlAvailability(.backSize, in: featureState.player) == .ready else { return }
            editGame(\.player) { $0.backSize.set(value) }
        case 2:
            guard canStage(featureState.radar),
                  controlAvailability(.radarDetectionDistance, in: featureState.radar) == .ready else { return }
            editGame(\.radar) { $0.detectionDistance.set(value) }
        case 3, 4:
            guard canStage(featureState.materials),
                  controlAvailability(.materialDistance, in: featureState.materials) == .ready,
                  let category = CoreSetMaterialCategory(rawValue: previewMaterialCategory) else { return }
            editMaterials { state in state.editCategory(category) { item in
                if sender.tag == 3 { item.distance.setMinimum(value) }
                else { item.distance.setMaximum(value) }
            } }
        default: break
        }
    }

    @objc private func changeLocalAimCircleSize(_ sender: UISlider) {
        refreshBeforeInteraction(sender)
        guard canStage(featureState.aimDisplay),
              controlAvailability(.localAimCircleSize, in: featureState.aimDisplay) == .ready else { return }
        let value = Int(sender.value.rounded())
        if aimConfigurationAvailable(.basicAimCircleSize) {
            featureState.aim.updateDesired { $0.circleSize.set(value) }
            recordAimConfiguration(sender, path: "aim.circleSize")
        }
        editGame(\.aimDisplay) { $0.circleSize.set(value) }
    }

    @objc private func toggleLocalAimCircle(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        let actionReady = aimConfigurationAvailable(.basicAimShowCircle)
        let previewReady = canStage(featureState.aimDisplay) &&
            controlAvailability(.localAimCircle, in: featureState.aimDisplay) == .ready
        guard actionReady || previewReady else { return }
        let current = featureState.aim.desired.showCircle ??
            featureState.aimDisplay.desired.circleVisible ?? false
        let next = !current
        if actionReady {
            featureState.aim.updateDesired { $0.showCircle = next }
            recordAimConfiguration(sender, path: "aim.showCircle")
        }
        if previewReady && (!next || featureState.aimDisplay.desired.circleSize.value != nil) {
            editGame(\.aimDisplay) { $0.circleVisible = next }
        } else { rebuildMenu() }
    }

    @objc private func changeLocalAimPreviewDistance(_ sender: UISlider) {
        refreshBeforeInteraction(sender)
        guard canStage(featureState.aimDisplay),
              controlAvailability(.localAimPreviewDistance, in: featureState.aimDisplay) == .ready else { return }
        let value = Int(sender.value.rounded())
        if aimConfigurationAvailable(.basicAimMaximumDistance) {
            featureState.aim.updateDesired { $0.custom.maximumDistance.set(value) }
            recordAimConfiguration(sender, path: "aim.custom.maximumDistance")
        }
        editGame(\.aimDisplay) { $0.maximumDistance.set(value) }
    }

    @objc private func toggleLocalAimPreviewField(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard (0...3).contains(sender.tag) else { return }
        let field: CoreSetField = sender.tag == 0 ? .localAimPreviewLine :
            (sender.tag == 1 ? .localAimPreviewMarker :
             (sender.tag == 2 ? .localAimDynamicCircle : .localAimPreviewBots))
        let actionField: CoreSetField = sender.tag == 0 ? .basicAimConnectionLine :
            (sender.tag == 1 ? .basicAimPreaimCircle :
             (sender.tag == 2 ? .basicAimDynamicCircle : .basicAimIncludeBots))
        let actionReady = aimConfigurationAvailable(actionField)
        let previewReady = canStage(featureState.aimDisplay) &&
            controlAvailability(field, in: featureState.aimDisplay) == .ready
        guard actionReady || previewReady else { return }
        let action = featureState.aim.desired
        let current = sender.tag == 0 ? action.connectionLine :
            (sender.tag == 1 ? action.preaimCircle :
             (sender.tag == 2 ? action.dynamicCircle.enabled : action.includeBots))
        let next = !(current ?? false)
        if actionReady {
            featureState.aim.updateDesired { state in
                switch sender.tag {
                case 0: state.connectionLine = next
                case 1: state.preaimCircle = next
                case 2: state.dynamicCircle.enabled = next
                default: state.includeBots = next
                }
            }
            let path = ["connectionLine", "preaimCircle", "dynamicCircle", "includeBots"][sender.tag]
            recordAimConfiguration(sender, path: "aim.\(path)")
        }
        if previewReady {
            editGame(\.aimDisplay) { state in
                switch sender.tag {
                case 0: state.connectionLine = next
                case 1: state.preaimMarker = next
                case 2: state.dynamicCircle = next
                default: state.includeBots = next
                }
            }
        } else { rebuildMenu() }
    }

    @objc private func changeAdjustmentRange(_ sender: UISlider) {
        refreshBeforeInteraction(sender)
        guard (0...2).contains(sender.tag), canStage(featureState.adjustments) else { return }
        let field: CoreSetField = sender.tag == 0 ? .rayThickness :
            (sender.tag == 1 ? .boneThickness : .materialFontSize)
        guard controlAvailability(field, in: featureState.adjustments) == .ready else { return }
        let value = Int(sender.value.rounded())
        editGame(\.adjustments) { state in
            switch sender.tag {
            case 0: state.rayThickness.set(value)
            case 1: state.boneThickness.set(value)
            default: state.materialFontSize.set(value)
            }
        }
    }

    @objc private func changeFrameRate(_ sender: UISlider) {
        refreshBeforeInteraction(sender)
        guard canStage(featureState.frameRate),
              controlAvailability(.framesPerSecond, in: featureState.frameRate) == .ready else { return }
        editGame(\.frameRate) { $0.framesPerSecond.set(Int(sender.value.rounded())) }
    }

    @objc private func toggleMaterialEnabled(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard canStage(featureState.materials),
              controlAvailability(.materialEnabled, in: featureState.materials) == .ready else { return }
        editMaterials { $0.enabled = $0.enabled != true }
    }

    @objc private func toggleHideWhileArmed(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard canStage(featureState.materials),
              controlAvailability(.hideWhileArmed, in: featureState.materials) == .ready else { return }
        editMaterials { $0.hideWhileArmed = $0.hideWhileArmed != true }
    }

    @objc private func toggleCrateLevel(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard canStage(featureState.materials),
              controlAvailability(.showCrateLevel, in: featureState.materials) == .ready else { return }
        editMaterials { $0.showCrateLevel = $0.showCrateLevel != true }
    }

    @objc private func toggleVehicleStatus(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard canStage(featureState.materials),
              controlAvailability(.vehicleStatus, in: featureState.materials) == .ready else { return }
        editMaterials { $0.vehicleStatus = $0.vehicleStatus != true }
    }

    @objc private func toggleMetroArmor(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard canStage(featureState.materials),
              controlAvailability(.metroArmor, in: featureState.materials) == .ready else { return }
        editMaterials { $0.metroArmor = $0.metroArmor != true }
    }

    @objc private func toggleHideOpenedCrates(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard canStage(featureState.materials),
              controlAvailability(.hideOpenedCrates, in: featureState.materials) == .ready else { return }
        editMaterials { $0.hideOpenedCrates = $0.hideOpenedCrates != true }
    }

    @objc private func selectBackIndicator(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard let value = CoreSetBackIndicator(rawValue: sender.tag), canStage(featureState.player),
              controlAvailability(.backIndicator, in: featureState.player) == .ready else { return }
        if value != .off {
            guard featureState.player.desired.backStyle != nil,
                  featureState.player.desired.backSize.value != nil else { return }
        }
        editGame(\.player) { $0.backIndicator = value }
    }

    @objc private func selectPlayerWeaponMode(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard (0...5).contains(sender.tag),
              canStage(featureState.player) else { return }
        if sender.tag % 3 == 0 && !CoreSetWeaponImageCatalog.isReady() { return }
        let scope: CoreSetActorScope = sender.tag < 3 ? .player : .bot
        guard controlAvailability(.actor(scope, .weapon), in: featureState.player) == .ready else { return }
        editGame(\.player) { state in
            if scope == .player {
                switch sender.tag % 3 {
                case 0: state.player.weapon.select(.image)
                case 1: state.player.weapon.select(.text)
                default: state.player.weapon.disable()
                }
            } else {
                switch sender.tag % 3 {
                case 0: state.bot.weapon.select(.image)
                case 1: state.bot.weapon.select(.text)
                default: state.bot.weapon.disable()
                }
            }
        }
    }

    @objc private func selectPlayerCountMode(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard (0...5).contains(sender.tag), canStage(featureState.player) else { return }
        let scope: CoreSetActorScope = sender.tag < 3 ? .player : .bot
        guard controlAvailability(.actor(scope, .count), in: featureState.player) == .ready else { return }
        editGame(\.player) { state in
            if scope == .player {
                switch sender.tag % 3 {
                case 0: state.player.count.select(.detailed)
                case 1: state.player.count.select(.compact)
                default: state.player.count.disable()
                }
            } else {
                switch sender.tag % 3 {
                case 0: state.bot.count.select(.detailed)
                case 1: state.bot.count.select(.compact)
                default: state.bot.count.disable()
                }
            }
        }
    }

    @objc private func selectPlayerInformationMode(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard (0...5).contains(sender.tag), canStage(featureState.player) else { return }
        let scope: CoreSetActorScope = sender.tag < 3 ? .player : .bot
        guard controlAvailability(.actor(scope, .information), in: featureState.player) == .ready else { return }
        editGame(\.player) { state in
            if scope == .player {
                switch sender.tag % 3 {
                case 0: state.player.information.select(.modern)
                case 1: state.player.information.select(.minimal)
                default: state.player.information.disable()
                }
            } else {
                switch sender.tag % 3 {
                case 0: state.bot.information.select(.modern)
                case 1: state.bot.information.select(.minimal)
                default: state.bot.information.disable()
                }
            }
        }
    }

    @objc private func toggleRadarField(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard sender.tag == 0 || sender.tag == 1, canStage(featureState.radar) else { return }
        let field: CoreSetField = sender.tag == 0 ? .radarEnabled : .radarShowDistance
        guard controlAvailability(field, in: featureState.radar) == .ready else { return }
        if sender.tag == 0 {
            let enabling = featureState.radar.desired.enabled != true
            editGame(\.radar) { $0.enabled = enabling }
        } else {
            editGame(\.radar) { $0.showDistance = !($0.showDistance ?? false) }
        }
    }

    @objc private func toggleWarningField(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard sender.tag == 0 || sender.tag == 1, canStage(featureState.radar) else { return }
        let field: CoreSetField = sender.tag == 0 ? .warningEnabled : .warningIgnoreBots
        guard controlAvailability(field, in: featureState.radar) == .ready else { return }
        if sender.tag == 0 {
            let enabling = featureState.radar.desired.warningEnabled != true
            editGame(\.radar) { $0.warningEnabled = enabling }
        } else {
            editGame(\.radar) { $0.ignoreBots = !($0.ignoreBots ?? false) }
        }
    }

    @objc private func changeWarningRange(_ sender: UISlider) {
        refreshBeforeInteraction(sender)
        guard sender.tag == 0 || sender.tag == 1, canStage(featureState.radar) else { return }
        let field: CoreSetField = sender.tag == 0 ? .warningRange : .warningTextSize
        guard controlAvailability(field, in: featureState.radar) == .ready else { return }
        let value = Int(sender.value.rounded())
        editGame(\.radar) { state in
            if sender.tag == 0 { state.warningRange.set(value) }
            else { state.warningTextSize.set(value) }
        }
    }

    @objc private func changeRadarPlacement(_ sender: UISlider) {
        refreshBeforeInteraction(sender)
        guard (0...2).contains(sender.tag), canStage(featureState.radar) else { return }
        let field: CoreSetField = sender.tag == 0 ? .radarRadius :
            (sender.tag == 1 ? .radarX : .radarY)
        guard controlAvailability(field, in: featureState.radar) == .ready else { return }
        let value = Int(sender.value.rounded())
        editGame(\.radar) { state in
            switch sender.tag {
            case 0: state.placement.setRadius(value)
            case 1: state.placement.setX(value)
            default: state.placement.setY(value)
            }
        }
    }

    private func storedColor(forKey key: String) -> UIColor? {
        guard key == accentKey else { return nil }
        if let packed = storedPackedAccent() { return uiColor(CoreSetRGBA.referenceOpaque(packed: packed)) }
        if UserDefaults.standard.object(forKey: accentKey) != nil { return nil }
        guard let values = UserDefaults.standard.array(forKey: legacyAccentKey) as? [Double],
              values.count == 4, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return UIColor(red: CGFloat(values[0]), green: CGFloat(values[1]),
                       blue: CGFloat(values[2]), alpha: 1)
    }

    private func saveColor(_ color: UIColor, forKey key: String) {
        guard key == accentKey, appearanceChannel.map(canStage) == true, let value = rgba(color) else { return }
        featureState.home.updateDesired { $0.setAccent(value) }
        applyLocalAppearance()
    }

    private func localColorRows(in card: UIView) {
        colorEditRow("主题颜色", target: .theme, in: card,
                     frame: CGRect(x: 0, y: 66, width: card.bounds.width, height: 24))
        card.addSubview(label("预设颜色", size: 16, frame: CGRect(x: 12, y: 96, width: 96, height: 24)))
        for index in presetRGB.indices {
            let swatch = UIButton(type: .system)
            swatch.frame = CGRect(x: 90 + CGFloat(index) * 31, y: 96, width: 24, height: 24)
            swatch.backgroundColor = uiColor(CoreSetReferenceMenuAppearance.preset(index))
            swatch.layer.cornerRadius = 5
            swatch.tag = index
            swatch.accessibilityLabel = "预设颜色 \(index + 1)"
            let selected = matchesPreset(CoreSetReferenceMenuAppearance.preset(index))
            swatch.isSelected = selected
            swatch.isEnabled = localAppearanceReady
            swatch.accessibilityTraits = selected ? [.button, .selected] : .button
            if selected {
                // Matching/outline geometry is confirmed. The reference style-table
                // outline color is unresolved, so use the local theme text color.
                let outline = CAShapeLayer()
                outline.frame = swatch.bounds
                outline.path = UIBezierPath(roundedRect: swatch.bounds.insetBy(dx: -2, dy: -2),
                                            cornerRadius: 6).cgPath
                outline.fillColor = UIColor.clear.cgColor
                outline.strokeColor = gray(255, 80).cgColor
                outline.lineWidth = 2
                swatch.clipsToBounds = false
                swatch.layer.addSublayer(outline)
            }
            swatch.addTarget(self, action: #selector(selectPresetColor(_:)), for: .touchUpInside)
            registerHosted(swatch, .presetColor)
            card.addSubview(swatch)
        }
        floatingColorRows(in: card)
    }

    private func matchesPreset(_ preset: CoreSetRGBA) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        let dr = red - CGFloat(preset.red)
        let dg = green - CGFloat(preset.green)
        let db = blue - CGFloat(preset.blue)
        return dr * dr + dg * dg + db * db < 0.0001
    }

    @objc private func selectPresetColor(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard localAppearanceReady, presetRGB.indices.contains(sender.tag) else { return }
        // Integer labels remain display-only; apply original Float32 data.
        saveColor(uiColor(CoreSetReferenceMenuAppearance.preset(sender.tag)), forKey: accentKey)
    }

    @objc private func editLocalColor(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        // Core opens its color editor inside the same ImGui menu/context. Use
        // the same in-menu editor for local and hosted input so no UIKit modal
        // window steals ownership from the mirrored menu surface.
        _ = showHostedColorEditor(sender)
    }

    private func colorEditRow(_ title: String, target: ColorTarget, in card: UIView,
                              frame: CGRect, labelInset: CGFloat = 12) {
        let row = UIView(frame: frame)
        let button = ColorButton(type: .custom)
        button.colorTarget = target
        button.frame = CGRect(x: row.bounds.width - 20 - 32, y: (row.bounds.height - 21) / 2, width: 32, height: 21)
        button.layer.cornerRadius = 3
        let current = colorValue(target).map(uiColor)
        button.backgroundColor = current ?? .clear
        button.layer.borderWidth = current == nil ? 1 : 0
        button.layer.borderColor = gray(75, 200).cgColor
        button.setTitle(current == nil ? "?" : nil, for: .normal)
        button.titleLabel?.font = font(16)
        button.setTitleColor(gray(255, 80), for: .normal)
        button.accessibilityLabel = title
        button.accessibilityValue = current == nil ? "原版颜色未验证" : "本地预览颜色"
        switch target {
        case .theme: button.accessibilityHint = "UIKit近似编辑器；只影响本应用主题"
        case .material: button.accessibilityHint = "本地物资 lane 绘制，须等待精确帧回执"
        case .player, .bot: button.accessibilityHint = "本地玩家 lane 样式，须等待精确帧回执"
        }
        button.isEnabled = colorTargetReady(target)
        if !button.isEnabled { button.accessibilityHint = "对应消费者不可用，颜色功能未接入" }
        button.addTarget(self, action: #selector(editLocalColor(_:)), for: .touchUpInside)
        switch target {
        case .theme: registerHosted(button, .colorEditor)
        case .player(let role): registerHosted(button, .colorEditor, field: .actorColor(.player, colorField(role)), capability: .drawingAppearance)
        case .bot(let role): registerHosted(button, .colorEditor, field: .actorColor(.bot, colorField(role)), capability: .drawingAppearance)
        case .material: registerHosted(button, .colorEditor, field: .materialColor, capability: .materialFiltering)
        }
        row.addSubview(label(title, size: 16,
                             frame: CGRect(x: labelInset, y: 0, width: max(0, button.frame.minX - labelInset - 8), height: row.bounds.height)))
        row.addSubview(button)
        card.addSubview(row)
    }

    private func previewColorRows(_ titles: [String], scope: ColorScope, in card: UIView) {
        for (index, title) in titles.enumerated() {
            guard let role = ColorRole(rawValue: title) else { continue }
            let target: ColorTarget
            switch scope {
            case .player: target = .player(role)
            case .bot: target = .bot(role)
            }
            colorEditRow(title, target: target, in: card,
                         frame: CGRect(x: 0, y: 34 + CGFloat(index) * 30, width: card.bounds.width, height: 28))
        }
    }

    private func applyEditedColor(_ color: UIColor, target: ColorTarget) {
        refreshBeforeInteraction()
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        guard colorTargetStageReady(target), let value = rgba(color) else { return }
        if target == .theme {
            saveColor(color, forKey: accentKey)
        } else if case let .material(index) = target {
            guard let category = CoreSetMaterialCategory(rawValue: index) else { return }
            editMaterials { $0.editCategory(category) { $0.color = value } }
        } else {
            editGame(\.adjustments) { state in
                switch target {
                case .player(let role): self.setActorColor(&state.player, role: role, value: value)
                case .bot(let role): self.setActorColor(&state.bot, role: role, value: value)
                default: break
                }
            }
        }
    }

    private func actorColor(_ colors: CoreSetActorColors, role: ColorRole) -> CoreSetRGBA? {
        switch role { case .name: return colors.name; case .ray: return colors.ray
        case .distance: return colors.distance; case .bone: return colors.bone; case .team: return colors.team }
    }
    private func setActorColor(_ colors: inout CoreSetActorColors, role: ColorRole, value: CoreSetRGBA) {
        switch role { case .name: colors.name = value; case .ray: colors.ray = value
        case .distance: colors.distance = value; case .bone: colors.bone = value; case .team: colors.team = value }
    }
    private func colorValue(_ target: ColorTarget) -> CoreSetRGBA? {
        switch target {
        case .theme: return featureState.home.desired.accent
        case .player(let role): return actorColor(featureState.adjustments.desired.player, role: role)
        case .bot(let role): return actorColor(featureState.adjustments.desired.bot, role: role)
        case .material(let index):
            guard featureState.materials.desired.categories.indices.contains(index) else { return nil }
            return featureState.materials.desired.categories[index].color
        }
    }
    private func colorTargetReady(_ target: ColorTarget) -> Bool {
        if case .player(let role) = target,
           controlAvailability(.actorColor(.player, colorField(role)), in: featureState.adjustments) != .ready { return false }
        if case .bot(let role) = target,
           controlAvailability(.actorColor(.bot, colorField(role)), in: featureState.adjustments) != .ready { return false }
        switch target { case .theme: return localAppearanceReady
        case .material: return materialEditingReady &&
            (gameConsumers[\CoreSetFeatureState.materials] == nil ||
             controlAvailability(.materialColor, in: featureState.materials) == .ready)
        case .player, .bot: return canStage(featureState.adjustments) }
    }
    private func colorField(_ role: ColorRole) -> CoreSetColorField {
        switch role { case .name: return .name; case .ray: return .ray
        case .distance: return .distance; case .bone: return .bone; case .team: return .team }
    }
    private func colorTargetStageReady(_ target: ColorTarget) -> Bool {
        if case .player(let role) = target,
           controlAvailability(.actorColor(.player, colorField(role)), in: featureState.adjustments) != .ready { return false }
        if case .bot(let role) = target,
           controlAvailability(.actorColor(.bot, colorField(role)), in: featureState.adjustments) != .ready { return false }
        switch target { case .theme: return appearanceChannel.map(canStage) ?? false
        case .material:
            return gameConsumers[\CoreSetFeatureState.materials] != nil ?
                (canStage(featureState.materials) &&
                 controlAvailability(.materialColor, in: featureState.materials) == .ready) :
                (directoryChannel.map(canStage) ?? false)
        case .player, .bot: return canStage(featureState.adjustments) }
    }
    private var materialEditingReady: Bool {
        if gameConsumers[\CoreSetFeatureState.materials] != nil { return canStage(featureState.materials) }
        return localDirectoryReady
    }
    private var materialGroupEditingReady: Bool {
        guard materialEditingReady else { return false }
        if gameConsumers[\CoreSetFeatureState.materials] == nil { return true }
        // Core's group buttons write their own bool-pointer set independently
        // of the total-visibility byte, range and packed colour.  Keeping group
        // editing available also lets the user clear an incomplete selection.
        return controlAvailability(.materialGroupSelection, in: featureState.materials) == .ready
    }
    private func materialConfigurationNotice(_ state: CoreSetMaterialSettings) -> String? {
        let selected = state.categories.filter { category in
            category.groups.contains { $0.members.contains(true) }
        }
        guard !selected.isEmpty else {
            return state.enabled == true ? "显示物资已开启，但尚未选择任何物资；当前绘制命令为 0" : nil
        }
        if state.enabled != true {
            return "物资筛选已保存，但“显示物资”总开关仍关闭；当前绘制命令为 0"
        }
        let incomplete = selected.compactMap { category -> String? in
            var missing: [String] = []
            if category.distance.minimum == nil || category.distance.maximum == nil { missing.append("距离") }
            if category.color == nil { missing.append("颜色") }
            guard !missing.isEmpty else { return nil }
            return "\(category.category.displayName)(\(missing.joined(separator: "/")))"
        }
        guard !incomplete.isEmpty else { return nil }
        return "显示物资尚未生效；请先补全：\(incomplete.joined(separator: "、"))"
    }
    private func editMaterials(_ edit: (inout CoreSetMaterialSettings) -> Void) {
        // Each material control already checks its own field contract before
        // reaching this shared editor.  Requiring materialColor here coupled
        // the total switch, distance and group controls to an unrelated field
        // and made otherwise configurable controls appear unresponsive.
        guard materialEditingReady else { return }
        if gameConsumers[\CoreSetFeatureState.materials] != nil { editGame(\.materials, edit) }
        else { featureState.materials.updateDesired(edit); applyLocalDirectory() }
    }

    private func materialPreviewTint(category: Int) -> UIColor {
        colorValue(.material(category)).map(uiColor) ?? accent
    }

    private func floatingColorRows(in card: UIView) {
        card.addSubview(label("悬浮颜色", size: 16, frame: CGRect(x: 12, y: 126, width: 96, height: 24)))
        for index in presetRGB.indices {
            let swatch = UIButton(type: .custom)
            swatch.frame = CGRect(x: 90 + CGFloat(index) * 31, y: 126, width: 24, height: 24)
            swatch.tag = index
            swatch.backgroundColor = uiColor(CoreSetReferenceMenuAppearance.preset(index))
            swatch.layer.cornerRadius = 5
            if index == 6 {
                let gradient = CAGradientLayer()
                gradient.frame = swatch.bounds
                gradient.cornerRadius = 5
                gradient.startPoint = CGPoint(x: 0, y: 0.5)
                gradient.endPoint = CGPoint(x: 1, y: 0.5)
                gradient.colors = [0, 2].map { uiColor(CoreSetReferenceMenuAppearance.preset($0)).cgColor }
                swatch.layer.addSublayer(gradient)
            }
            let selected = floatingThemeValue == floatingThemeValues[index]
            swatch.isSelected = selected
            swatch.isEnabled = localAppearanceReady
            swatch.accessibilityLabel = "悬浮颜色 \(index + 1)"
            let confirmed = selected && hostChannel.isDesiredConfirmed && hostChannel.actual?.floatingPalette == CoreSetFloatingPalette(rawValue: floatingThemeValues[index])
            swatch.accessibilityValue = confirmed ? "宿主浮球颜色属性已回读" : "颜色已配置，等待宿主浮球回执"
            swatch.accessibilityHint = "实际 Host 浮球 gradient 属性/代次回读；不代表原包设备像素或跨应用呈现验收"
            let point = 22 + index
            let reason = confirmed ? "matched-host-palette-token" : hostPaletteReceiptReason
            let logSignature = "\(selected ? 1 : 0)|\(confirmed ? 1 : 0)|\(reason)"
            if hostedPaletteLogSignatures[point] != logSignature {
                hostedPaletteLogSignatures[point] = logSignature
                NSLog("Core-SET: hosted-palette stage=field-state point=v17-%03d field=floatingPalette configured=%d confirmed=%d scope=actual-host-floating-gradient-property original-runtime-receipt=0 device-effect-verified=0 reason=%@",
                      point, selected ? 1 : 0, confirmed ? 1 : 0, reason)
            }
            swatch.accessibilityTraits = selected ? [.button, .selected] : .button
            if selected {
                let outline = CAShapeLayer()
                outline.frame = swatch.bounds
                outline.path = UIBezierPath(roundedRect: swatch.bounds.insetBy(dx: -2, dy: -2), cornerRadius: 6).cgPath
                outline.fillColor = UIColor.clear.cgColor
                outline.strokeColor = gray(255, 80).cgColor
                outline.lineWidth = 2
                swatch.layer.addSublayer(outline)
            }
            swatch.addTarget(self, action: #selector(selectFloatingColor(_:)), for: .touchUpInside)
            registerHosted(swatch, .floatingColor)
            card.addSubview(swatch)
        }
    }

    @objc private func selectFloatingColor(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard localAppearanceReady, floatingThemeValues.indices.contains(sender.tag),
              let palette = CoreSetFloatingPalette(rawValue: floatingThemeValues[sender.tag]) else { return }
        featureState.home.updateDesired { $0.floatingPalette = palette }
        applyLocalAppearance()
        hostChannel.updateDesired { $0.floatingPalette = palette }
        if hostConsumer != nil { applyHostSettings() }
    }

    private func categoryTabs(_ titles: [String], in card: UIView, y: CGFloat, startIndex: Int = 0) {
        var x: CGFloat = 20
        for (offset, title) in titles.enumerated() {
            // Native category tab width is measured text + 24; UIKit font metrics remain approximate.
            let width = (title as NSString).size(withAttributes: [.font: font(16)]).width + 24
            let button = UIButton(type: .system)
            button.frame = CGRect(x: x, y: y, width: width, height: 28)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = font(16)
            let index = startIndex + offset
            button.tag = index
            button.accessibilityIdentifier = "material.category.\(index)"
            let selected = index == previewMaterialCategory
            button.setTitleColor(selected ? UIColor.white.withAlphaComponent(240.0 / 255.0) : gray(255, 80), for: .normal)
            button.backgroundColor = selected ? materialPreviewTint(category: index) : gray(41, 230)
            button.layer.cornerRadius = 14
            button.accessibilityTraits = selected ? [.button, .selected] : .button
            button.accessibilityHint = "v1.7同义本地分类切换；目标物资效果和设备呈现仍未验证"
            // Core changes only its local selected-category index here.
            button.isEnabled = true
            button.addTarget(self, action: #selector(selectMaterialCategory(_:)), for: .touchUpInside)
            registerHosted(button, .materialCategory)
            card.addSubview(button)
            x += width + 6
        }
    }

    private func backStylePreview(in card: UIView) {
        card.addSubview(label("背敌样式", size: 16,
                              frame: CGRect(x: 20, y: 124, width: card.bounds.width - 40, height: 20)))
        let width = (card.bounds.width - 40 - 16) / 3
        for index in 0..<6 {
            let button = UIButton(type: .custom)
            button.frame = CGRect(x: 20 + CGFloat(index % 3) * (width + 8),
                                  y: 148 + CGFloat(index / 3) * 40, width: width, height: 34)
            button.tag = index
            let selected = previewBackStyle == index
            button.backgroundColor = selected ? accent.withAlphaComponent(0.16) : gray(41, 230)
            button.layer.cornerRadius = 5
            button.layer.borderWidth = selected ? 1.5 : 1
            button.layer.borderColor = (selected ? accent : gray(50, 215)).cgColor
            button.accessibilityLabel = "背敌样式 \(index + 1)"
            button.isEnabled = canStage(featureState.player) &&
                controlAvailability(.backStyle, in: featureState.player) == .ready
            button.accessibilityHint = button.isEnabled ? "请求玩家绘制消费者，生效需实际回执" : "玩家绘制消费者未接入，样式不可应用"
            button.accessibilityTraits = selected ? [.button, .selected] : .button
            drawBackGlyph(index, in: button, color: selected ? accent : gray(255, 80))
            button.addTarget(self, action: #selector(selectBackStyle(_:)), for: .touchUpInside)
            registerHosted(button, .backStyle, field: .backStyle, capability: .playerRendering)
            card.addSubview(button)
        }
    }

    @objc private func selectBackStyle(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard let style = CoreSetBackStyle(rawValue: sender.tag) else { return }
        editGame(\.player) { $0.backStyle = style }
    }

    private func drawBackGlyph(_ index: Int, in button: UIButton, color: UIColor) {
        let width: CGFloat = 40
        let height: CGFloat = 15
        let origin = CGPoint(x: button.bounds.midX - width / 2, y: button.bounds.midY)
        let outline = max(1, width / 80 * 1.35)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * width, y: origin.y + y * height)
        }
        func add(_ path: UIBezierPath, fill: UIColor?, stroke: UIColor?, thickness: CGFloat = 0) {
            let layer = CAShapeLayer()
            layer.frame = button.bounds
            layer.path = path.cgPath
            layer.fillColor = (fill ?? .clear).cgColor
            layer.strokeColor = stroke?.cgColor
            layer.lineWidth = thickness
            layer.lineJoin = .round
            layer.lineCap = .round
            button.layer.addSublayer(layer)
        }
        func polygon(_ vertices: [(CGFloat, CGFloat)], fill: UIColor, bordered: Bool = true) {
            guard let first = vertices.first else { return }
            let path = UIBezierPath()
            path.move(to: point(first.0, first.1))
            for vertex in vertices.dropFirst() { path.addLine(to: point(vertex.0, vertex.1)) }
            path.close()
            add(path, fill: fill, stroke: bordered ? .black : nil, thickness: outline)
        }
        func arc(_ centerX: CGFloat, radius: CGFloat, from start: CGFloat, to end: CGFloat, points: Int) {
            let path = UIBezierPath()
            let center = point(centerX, 0)
            for step in 0..<points {
                let angle = start + (end - start) * CGFloat(step) / CGFloat(points - 1)
                let next = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if step == 0 { path.move(to: next) } else { path.addLine(to: next) }
            }
            add(path, fill: nil, stroke: .black, thickness: max(0.18 * height, 2.4))
            add(path, fill: nil, stroke: color, thickness: max(0.095 * height, 1.3))
        }
        func dot(_ centerX: CGFloat, radius: CGFloat, alpha: CGFloat, borderFactor: CGFloat) {
            let center = point(centerX, 0)
            let outer = radius + outline * borderFactor
            add(UIBezierPath(ovalIn: CGRect(x: center.x - outer, y: center.y - outer,
                                           width: outer * 2, height: outer * 2)), fill: .black, stroke: nil)
            add(UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2)),
                fill: color.withAlphaComponent(alpha), stroke: nil)
        }
        switch index {
        case 0:
            polygon([(0, 0), (0.42, -0.5), (0.42, -0.19), (1, -0.19),
                     (1, 0.19), (0.42, 0.19), (0.42, 0.5)], fill: color)
        case 1:
            polygon([(0, 0), (0.38, -0.5), (0.34, -0.26), (1, -0.26),
                     (0.76, 0), (1, 0.26), (0.34, 0.26), (0.38, 0.5)], fill: color)
        case 2:
            polygon([(0, 0), (0.48, -0.5), (0.48, 0.5)], fill: color, bordered: false)
            polygon([(0.48, -0.5), (1, 0), (0.48, 0.5)], fill: color.withAlphaComponent(0.46), bordered: false)
            polygon([(0, 0), (0.48, -0.5), (1, 0), (0.48, 0.5)], fill: .clear)
        case 3:
            arc(0.67, radius: 0.43 * height, from: -2.5215926, to: 2.5215926, points: 21)
            polygon([(0, 0), (0.52, -0.26), (0.52, 0.26)], fill: color)
        case 4:
            dot(0.48, radius: max(0.15 * height, 1.1), alpha: 0.90, borderFactor: 0.72)
            dot(0.67, radius: max(0.11 * height, 1.1), alpha: 0.65, borderFactor: 0.72)
            dot(0.83, radius: max(0.075 * height, 1.1), alpha: 0.40, borderFactor: 0.72)
            polygon([(0, 0), (0.30, -0.46), (0.30, 0.46)], fill: color)
        default:
            arc(0.65, radius: 0.46 * height, from: -2.4215927, to: -0.18, points: 13)
            arc(0.65, radius: 0.46 * height, from: 0.18, to: 2.4215927, points: 13)
            dot(0.65, radius: max(0.075 * height, 1), alpha: 1, borderFactor: 0.65)
            polygon([(0, 0), (0.53, -0.18), (0.53, 0.18)], fill: color)
        }
    }

    private func scenePreview(in card: UIView) {
        let titles = ["远距", "近战", "通用", "自定义"]
        let groupWidth = scenarioWidths.reduce(0, +) + 18
        var x = card.bounds.width - 20 - groupWidth
        card.addSubview(label("场景", size: 16, frame: CGRect(x: 12, y: 34, width: max(0, x - 20), height: 22)))
        for (index, title) in titles.enumerated() {
            let button = UIButton(type: .system)
            button.frame = CGRect(x: x, y: 34, width: scenarioWidths[index], height: 22)
            button.tag = index
            let selected = previewSceneValue == scenarioValues[index]
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = font(16)
            button.setTitleColor(selected ? .white : gray(255, 80), for: .normal)
            button.backgroundColor = selected ? accent : gray(41, 230)
            button.layer.cornerRadius = 5
            button.accessibilityHint = "仅切换本地场景参数预览，不影响游戏"
            button.isEnabled = featureState.aim.phase != .applying && featureState.aim.phase != .active &&
                aimConfigurationAvailable(.basicAimScene)
            button.accessibilityHint = "选择基础视角自瞄场景参数"
            button.accessibilityTraits = selected ? [.button, .selected] : .button
            button.addTarget(self, action: #selector(selectPreviewScene(_:)), for: .touchUpInside)
            registerHosted(button, .previewScene, field: .basicAimScene, capability: .aimControl)
            card.addSubview(button)
            x += scenarioWidths[index] + 6
        }
    }

    @objc private func selectPreviewScene(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard featureState.aim.phase != .applying && featureState.aim.phase != .active,
              scenarioValues.indices.contains(sender.tag),
              let scene = CoreSetAimScene(rawValue: scenarioValues[sender.tag]),
              aimConfigurationAvailable(.basicAimScene) else { return }
        featureState.aim.updateDesired { $0.scene = scene }
        recordAimConfiguration(sender, path: "aim.scene")
        rebuildMenu()
    }

    private func materialGroupValues(category: Int, item: Int) -> [Bool?] {
        guard featureState.materials.desired.categories.indices.contains(category),
              featureState.materials.desired.categories[category].groups.indices.contains(item) else { return [] }
        return featureState.materials.desired.categories[category].groups[item].members
    }

    private func materialGroupSelection(_ values: [Bool?]) -> (all: Bool, any: Bool, unknown: Bool) {
        let unknown = values.isEmpty || values.contains(nil)
        return (!unknown && values.allSatisfy { $0 == true }, !unknown && values.contains(true), unknown)
    }

    @objc private func selectMaterialCategory(_ sender: UIButton) {
        guard materialCatalog.indices.contains(sender.tag), sender.tag != previewMaterialCategory else { return }
        let category = sender.tag
        previewMaterialCategory = category
        // Native category switching resets only scrolling, not the selections.
        materialGrid.contentOffset = .zero
        NSLog("Core-SET: hosted input stage=desired control=material.category.%ld configured=1 confirmed=0 scope=local-category-index", category)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectedPage == 2, self.previewMaterialCategory == category else { return }
            self.rebuildCurrentPage()
        }
    }

    @objc private func toggleMaterialGroup(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard let category = CoreSetMaterialCategory(rawValue: previewMaterialCategory),
              materialCatalog[previewMaterialCategory].indices.contains(sender.tag),
              materialGroupEditingReady,
              (gameConsumers[\CoreSetFeatureState.materials] == nil ||
               controlAvailability(.materialGroupSelection, in: featureState.materials) == .ready) else { return }
        editMaterials { $0.editCategory(category) { _ = $0.editGroup(at: sender.tag) { $0.toggle() } } }
    }

    @objc private func setAllMaterialGroups(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard let category = CoreSetMaterialCategory(rawValue: previewMaterialCategory), (0...1).contains(sender.tag),
              materialGroupEditingReady,
              (gameConsumers[\CoreSetFeatureState.materials] == nil ||
               controlAvailability(.materialGroupSelection, in: featureState.materials) == .ready) else { return }
        editMaterials { $0.editCategory(category) { $0.setAll(sender.tag == 1) } }
    }

    private func materialPreview(in card: UIView) {
        guard materialCatalog.indices.contains(previewMaterialCategory) else { return }
        let items = materialCatalog[previewMaterialCategory]
        let complete = items.indices.filter {
            materialGroupSelection(materialGroupValues(category: previewMaterialCategory, item: $0)).all
        }.count
        let heading = "\(materialCategoryTitles[previewMaterialCategory])   \(complete) / \(items.count)"
        card.addSubview(label(heading, size: 16, frame: CGRect(x: 20, y: 180, width: card.bounds.width - 130, height: 22)))
        let oldOffset = materialGrid.contentOffset
        materialGridItems.subviews.forEach { $0.removeFromSuperview() }
        materialGrid.frame = CGRect(x: 16, y: 208, width: card.bounds.width - 32,
                                    height: max(48, card.bounds.height - 220))
        materialGrid.showsVerticalScrollIndicator = true
        materialGrid.accessibilityLabel = "物资目录预览"
        materialGrid.accessibilityHint = "Core 名称候选目录；选中项经目标只读采集和本地物资 lane 绘制，不写游戏"
        card.addSubview(materialGrid)
        registerHosted(materialGrid, .materialScroll)
        materialGrid.addSubview(materialGridItems)
        var x: CGFloat = 4
        var y: CGFloat = 4
        for (index, title) in items.enumerated() {
            let measured = (title as NSString).size(withAttributes: [.font: font(16)]).width + 24
            let width = min(measured, materialGrid.bounds.width - 22)
            if x > 4 && x + width > materialGrid.bounds.width - 18 { x = 4; y += 32 }
            let button = MaterialGroupButton(type: .system)
            button.frame = CGRect(x: x, y: y, width: width, height: 26)
            button.tag = index
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = font(16)
            let selected = materialGroupSelection(materialGroupValues(category: previewMaterialCategory, item: index))
            button.observedSelection = selected.unknown ? .unknown : (selected.all ? .all : (selected.any ? .partial : .none))
            button.setTitleColor(selected.all ? UIColor.white.withAlphaComponent(240.0 / 255.0) : gray(255, 80), for: .normal)
            // Unknown reference colors fall back only to the local preview theme.
            let tint = materialPreviewTint(category: previewMaterialCategory)
            button.backgroundColor = selected.all ? tint : (selected.any ? tint.withAlphaComponent(105.0 / 255.0) : gray(41, 230))
            button.layer.cornerRadius = 13
            button.layer.borderWidth = 1
            button.layer.borderColor = (selected.any ? tint : gray(50, 215)).cgColor
            button.accessibilityValue = selected.unknown ? "本地状态未知" : (selected.all ? "本地全选" : (selected.any ? "本地部分选择" : "本地未选"))
            button.accessibilityHint = "仅更改本地目录预览，不影响游戏；点击部分选择将全选"
            button.accessibilityTraits = selected.all ? [.button, .selected] : .button
            button.isEnabled = materialGroupEditingReady
            button.addTarget(self, action: #selector(toggleMaterialGroup(_:)), for: .touchUpInside)
            registerHosted(button, .materialGroup, field: .materialGroupSelection, capability: .materialFiltering)
            materialGridItems.addSubview(button)
            x += width + 6
        }
        materialGrid.contentSize = CGSize(width: materialGrid.bounds.width, height: y + 30)
        materialGridItems.frame = CGRect(origin: .zero, size: materialGrid.contentSize)
        materialGrid.contentOffset = CGPoint(x: 0, y: min(max(0, oldOffset.y), max(0, materialGrid.contentSize.height - materialGrid.bounds.height)))
    }

    func syncRadarCanvas(_ size: CGSize) {
        precondition(Thread.isMainThread)
        guard size.width > 0, size.height > 0 else { return }
        let canvas = CoreSetRadarCanvas(nativeWidth: nil, nativeHeight: nil,
                                         displayWidth: Double(size.width), displayHeight: Double(size.height))
        guard featureState.radar.desired.placement.canvas != canvas else { return }
        let oldPlacement = featureState.radar.desired.placement
        featureState.radar.updateDesired { $0.placement.refreshCanvas(canvas) }
        let changed = oldPlacement != featureState.radar.desired.placement
        if selectedPage == 4 { refreshRadarRangeRows() }
        guard changed, featureState.radar.phase == .active else { return }
        // Layout/host callbacks can occur while a frame is being consumed.
        // Reapply through the existing channel after this stack unwinds; only
        // CoreSetRadarConsumer's frame receipt can confirm the new placement.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.featureState.radar.desired.placement.canvas == canvas,
                  self.featureState.radar.phase == .active,
                  self.featureState.radar.pendingApply == nil,
                  self.featureState.radar.actual != self.featureState.radar.desired else { return }
            self.applyGame(\.radar)
        }
    }

    private func refreshRadarRangeRows() {
        guard selectedPage == 4, radarRangeRows.bounds.width > 0 else { return }
        if hostedPointerID != nil || hostedDispatchControlID != nil || trackingUIKitSlider != nil {
            homeStatusNeedsRebuild = true; return
        }
        guard let canvas = featureState.radar.desired.placement.canvas else { return }
        guard radarRangeCanvas != canvas || radarRangeRows.subviews.isEmpty else { return }
        if radarRangeCanvas != nil {
            hostedMenuRevision &+= 1
            hostedSliderID = nil
            hostedEntries.removeAll { $0.action == .radarPlacement }
        }
        radarRangeCanvas = canvas
        let placement = featureState.radar.desired.placement
        radarRangeRows.subviews.forEach { $0.removeFromSuperview() }
        let values: [(String, ClosedRange<Int>?)] = [
            ("雷达大小", placement.canvas?.radiusBounds), ("雷达X位置", placement.xBounds), ("雷达Y位置", placement.yBounds)
        ]
        for (index, entry) in values.enumerated() {
            let row = UIView(frame: CGRect(x: 0, y: CGFloat(index) * 30, width: radarRangeRows.bounds.width, height: 28))
            row.isUserInteractionEnabled = false
            row.isAccessibilityElement = true
            row.accessibilityLabel = entry.0
            row.accessibilityTraits = .notEnabled
            row.accessibilityHint = "本地雷达 lane 坐标；须目标只读会话和精确帧回执"
            row.addSubview(label(entry.0, size: 16, frame: CGRect(x: 0, y: 0, width: row.bounds.width * 0.45, height: 28)))
            if let range = entry.1 {
                let slider = UISlider(frame: CGRect(x: row.bounds.width * 0.46, y: 0, width: row.bounds.width * 0.50, height: 28))
                slider.minimumValue = Float(range.lowerBound)
                slider.maximumValue = Float(range.upperBound)
                let field: CoreSetField = index == 0 ? .radarRadius : (index == 1 ? .radarX : .radarY)
                let ready = canStage(featureState.radar) &&
                    controlAvailability(field, in: featureState.radar) == .ready
                let current = index == 0 ? placement.radius : (index == 1 ? placement.x : placement.y)
                slider.value = Float(current ?? range.lowerBound)
                slider.tag = index
                slider.isEnabled = ready
                slider.thumbTintColor = ready ? accent : .clear
                slider.minimumTrackTintColor = gray(75, 200)
                slider.maximumTrackTintColor = gray(75, 200)
                slider.addTarget(self, action: #selector(changeRadarPlacement(_:)), for: .valueChanged)
                registerHosted(slider, .radarPlacement, field: field, capability: .radarRendering)
                row.addSubview(slider)
                row.isUserInteractionEnabled = true
                row.isAccessibilityElement = false
                slider.accessibilityValue = current.map { String($0) } ?? "未选择"
            } else {
                // A plain rail has no fictitious UISlider 0...1 range or value.
                let rail = UIView(frame: CGRect(x: row.bounds.width * 0.46, y: 13, width: row.bounds.width * 0.50, height: 2))
                rail.backgroundColor = gray(75, 200)
                rail.layer.cornerRadius = 1
                row.addSubview(rail)
                row.accessibilityValue = "先选择雷达半径以确定范围"
            }
            radarRangeRows.addSubview(row)
        }
        installUnavailableFeedback(in: radarRangeRows)
    }

    private func statusText(_ value: String?) -> String {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap { $0.isEmpty ? nil : $0 } ?? "未接入 / 未验证"
    }
    @discardableResult
    private func statusRow(_ title: String, value: String?, in card: UIView, y: CGFloat) -> UILabel {
        let display = statusText(value)
        card.addSubview(label(title, size: 16, frame: CGRect(x: 20, y: y, width: 100, height: 26)))
        let detail = label(display, size: 16, frame: CGRect(x: 122, y: y, width: card.bounds.width - 142, height: 26), secondary: true)
        detail.textAlignment = .right
        detail.adjustsFontSizeToFitWidth = true
        detail.minimumScaleFactor = 0.72
        detail.accessibilityLabel = "\(title)：\(display)"
        card.addSubview(detail)
        return detail
    }
    private func homeFirmwareProgress(_ snapshot: CoreSetHomeSnapshot?) -> (title: String, value: String, fraction: Float)? {
        guard let firmware = snapshot?.firmwareState, firmware.totalBytes > 0,
              firmware.downloadedBytes <= firmware.totalBytes,
              firmware.stage == "ota-download" ||
                (firmware.localEquivalent && firmware.stage == "local-kernelcache-copy") else { return nil }
        let title = firmware.localEquivalent
            ? "本机 kernelcache 复制进度（Core 同位本地等价）" : "固件下载进度"
        let fraction = Float(min(1, Double(firmware.downloadedBytes) / Double(firmware.totalBytes)))
        return (title, "\(firmware.downloadedBytes)/\(firmware.totalBytes) B", fraction)
    }
    private func homeStatusStructure(_ snapshot: CoreSetHomeSnapshot?) -> String {
        let active = snapshot?.executing == true || snapshot?.status == 3
        let kernelProgress = snapshot?.kernelProgressFraction.map {
            $0.isFinite && (0...1).contains($0) && snapshot?.executing == true
        } ?? false
        let pageProgress = active && (snapshot?.totalPages ?? 0) > 0 && snapshot?.completedPages != nil
        let firmware = homeFirmwareProgress(snapshot)?.title ?? "none"
        return "active=\(active)|kernel=\(kernelProgress)|page=\(pageProgress)|firmware=\(firmware)"
    }
    @discardableResult
    private func refreshHomeStatusLabels() -> Bool {
        guard selectedPage == 0,
              homeStatusStructureSignature == homeStatusStructure(homeStatusSnapshot) else { return false }
        let snapshot = homeStatusSnapshot
        let values: [(String, String, String?)] = [
            ("kernel", "内核状态", snapshot?.kernel),
            ("stage", "当前阶段", snapshot?.stage),
            ("environment", "运行环境", snapshot?.environment),
            ("information", "获取信息状态", snapshot?.information),
            ("floating", "悬浮菜单", snapshot?.floating),
            ("page", "页面进度", snapshot.flatMap { state in
                guard let total = state.totalPages, total > 0, let completed = state.completedPages else { return nil }
                return "\(completed)/\(total)"
            })
        ]
        for (key, title, value) in values where homeStatusValueLabels[key] != nil {
            let display = statusText(value)
            homeStatusValueLabels[key]?.text = display
            homeStatusValueLabels[key]?.accessibilityLabel = "\(title)：\(display)"
        }
        if let fraction = snapshot?.kernelProgressFraction,
           fraction.isFinite, (0...1).contains(fraction), snapshot?.executing == true {
            let display = "\(Int((fraction * 100).rounded()))%"
            homeStatusValueLabels["kernelProgress"]?.text = display
            homeStatusValueLabels["kernelProgress"]?.accessibilityLabel = "本应用内核进度：\(display)"
            homeStatusProgressViews["kernel"]?.progress = Float(fraction)
        }
        if let firmware = homeFirmwareProgress(snapshot) {
            homeStatusValueLabels["firmware"]?.text = firmware.value
            homeStatusValueLabels["firmware"]?.accessibilityLabel = "\(firmware.title)：\(firmware.value)"
            homeStatusProgressViews["firmware"]?.progress = firmware.fraction
        }
        view.setNeedsLayout()
        return true
    }
    private func performanceValues() -> [String?] {
        let sample = featureState.performanceSnapshot
        let age = sample.map { Date().timeIntervalSince($0.observedAt) }
        let fresh = sample?.processID == getpid() && age.map { $0 >= 0 && $0 <= 5 } == true
        guard fresh, let sample else { return [nil, nil, nil] }
        return [sample.cpuPercent.map { String(format: "本应用 %.1f %%", $0) },
                sample.footprintMiB.map { String(format: "本应用 %.1f MiB", $0) },
                sample.peakFootprintMiB.map { String(format: "本应用 %.1f MiB", $0) }]
    }
    private func refreshPerformanceLabels() {
        let values = performanceValues()
        let titles = ["CPU 占用", "内存占用", "内存峰值"]
        guard performanceValueLabels.count == values.count else { return }
        for index in values.indices {
            let display = statusText(values[index])
            performanceValueLabels[index].text = display
            performanceValueLabels[index].accessibilityLabel = "\(titles[index])：\(display)"
            let sources = ["nonidle-thread-basic-info", "TASK_VM_INFO.phys_footprint", "process-lifetime-footprint-CAS-max"]
            let observed = values[index] != nil && performanceValueLabels[index].window != nil &&
                performanceValueLabels[index].text == display
            let reason = values[index] == nil ? "identity/freshness/independent-field-valid-unconfirmed" :
                (observed ? "matched-local-label-property" : "local-label-not-attached")
            performanceValueLabels[index].accessibilityHint = "本应用 \(sources[index])；本地数值/属性回读，不代表目标游戏或设备效果验收"
            let point = 30 + index
            let logSignature = "\(observed ? 1 : 0)|\(reason)"
            if performanceLogSignatures[point] != logSignature {
                performanceLogSignatures[point] = logSignature
                NSLog("Core-SET: performance point=v17-%03d stage=observation source=%@ observed=%d reason=%@ scope=own-process-local-label-property original-runtime-receipt=0 device-effect-verified=0",
                      point, sources[index], observed ? 1 : 0, reason)
            }
        }
    }

    private func homeStatusRows(in card: UIView) {
        let snapshot = homeStatusSnapshot
        let active = snapshot?.executing == true || snapshot?.status == 3
        homeStatusStructureSignature = homeStatusStructure(snapshot)
        var y: CGFloat = 134
        func add(_ key: String, _ title: String, _ value: String?) {
            homeStatusValueLabels[key] = statusRow(title, value: value, in: card, y: y)
            y += 30
        }
        add("kernel", "内核状态", snapshot?.kernel)
        if active { add("stage", "当前阶段", snapshot?.stage) }
        add("environment", "运行环境", snapshot?.environment)
        add("information", "获取信息状态", snapshot?.information)
        add("floating", "悬浮菜单", snapshot?.floating)
        if let fraction = snapshot?.kernelProgressFraction, fraction.isFinite,
           (0...1).contains(fraction), snapshot?.executing == true {
            add("kernelProgress", "本应用内核进度", "\(Int((fraction * 100).rounded()))%")
            let progress = UIProgressView(progressViewStyle: .default)
            progress.frame = CGRect(x: 20, y: y - 3, width: card.bounds.width - 40, height: 2)
            progress.progress = Float(fraction)
            progress.accessibilityLabel = "本应用 DarkSword 初始化进度"
            card.addSubview(progress)
            homeStatusProgressViews["kernel"] = progress
        }
        if active, let total = snapshot?.totalPages, total > 0, let completed = snapshot?.completedPages {
            add("page", "页面进度", "\(completed)/\(total)")
        }
        if let firmware = homeFirmwareProgress(snapshot) {
            add("firmware", firmware.title, firmware.value)
            let progress = UIProgressView(progressViewStyle: .default)
            progress.frame = CGRect(x: 20, y: y - 3, width: card.bounds.width - 40, height: 2)
            progress.progress = firmware.fraction
            progress.accessibilityLabel = firmware.title
            card.addSubview(progress)
            homeStatusProgressViews["firmware"] = progress
        }
    }

    @objc private func configureHomeRunMode(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        let values: [CoreSetRunMode] = [.safe, .efficiency]
        guard homeConfigurationAvailable, values.indices.contains(sender.tag) else { return }
        featureState.home.updateDesired { $0.runMode = values[sender.tag] }
        showConfigurationFeedback("home.runMode：已同步原版0/1归一化配置（原版无独立运行消费者）")
        NSLog("Core-SET: menu stage=desired point=v17-000 option=%d configured=1 confirmed=1 targetEffectsCreated=0 scope=reference-config-only-no-native-consumer",
              sender.tag)
        rebuildMenu()
    }

    @objc private func configureHomeCoverMode(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        let values: [CoreSetCoverMode] = [.global, .inGame, .off]
        guard homeConfigurationAvailable, values.indices.contains(sender.tag) else { return }
        featureState.home.updateDesired { $0.selectCoverMode(values[sender.tag]) }
        onHomeProbeRefusal?(.coverMode, sender.tag)
        showConfigurationFeedback("home.coverMode：配置已记录；关闭时保留上次非关闭模式，动作消费者未绑定")
        NSLog("Core-SET: menu stage=desired point=v17-001 option=%d configured=1 confirmed=0 targetEffectsCreated=0 scope=typed-home-configuration",
              sender.tag)
        rebuildMenu()
    }

    private func startHomeAction(_ point: CoreSetHomeProbePoint, sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard !homeActionsInFlight.contains(point), let onHomeAction else { return }
        homeActionsInFlight.insert(point)
        interactionControlIdentifier = sender.accessibilityIdentifier ?? point.stableID
        showConfigurationFeedback(point == .kernelAction ?
            "正在执行内核利用；主页状态会显示实际阶段和结果" :
            "正在获取 kernelcache 并验证当前设备偏移")
        rebuildMenu()
        onHomeAction(point) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.homeActionsInFlight.remove(point)
                self.showConfigurationFeedback(error ?? (point == .kernelAction ?
                    "内核利用已完成并由状态生产者确认" : "当前设备信息与偏移已完成验证"))
                self.rebuildMenu()
            }
        }
    }

    @objc private func startHomeKernelAction(_ sender: UIButton) {
        startHomeAction(.kernelAction, sender: sender)
    }

    @objc private func startHomeInformationAction(_ sender: UIButton) {
        startHomeAction(.informationAction, sender: sender)
    }

    @objc private func toggleAimConfigurationField(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        let fields: [CoreSetField] = [.basicAimEnabled, .basicAimPreaimCircle,
            .basicAimDynamicCircle, .basicAimShowCircle, .basicAimConnectionLine,
            .basicAimExcludeKnocked, .basicAimIncludeBots, .basicAimLockSameTarget]
        guard fields.indices.contains(sender.tag), sender.tag != 0,
              featureState.aim.phase != .applying && featureState.aim.phase != .active,
              aimConfigurationAvailable(fields[sender.tag]) else { return }
        featureState.aim.updateDesired { state in
            switch sender.tag {
            case 1: state.preaimCircle = state.preaimCircle != true
            case 2: state.dynamicCircle.enabled = state.dynamicCircle.enabled != true
            case 3: state.showCircle = state.showCircle != true
            case 4: state.connectionLine = state.connectionLine != true
            case 5: state.excludeKnocked = state.excludeKnocked != true
            case 6: state.includeBots = state.includeBots != true
            case 7: state.lockSameTarget = state.lockSameTarget != true
            default: break
            }
        }
        let paths = ["enabled", "preaimCircle", "dynamicCircle", "showCircle",
                     "connectionLine", "excludeKnocked", "includeBots", "lockSameTarget"]
        recordAimConfiguration(sender, path: "aim.\(paths[sender.tag])")
        rebuildMenu()
    }

    @objc private func selectAimChoice(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        guard featureState.aim.phase != .applying && featureState.aim.phase != .active else { return }
        switch sender.tag {
        case 100..<103:
            guard aimConfigurationAvailable(.basicAimPoint),
                  let point = CoreSetAimPoint(rawValue: sender.tag - 100) else { return }
            featureState.aim.updateDesired { $0.point = point }
            recordAimConfiguration(sender, path: "aim.point")
        case 200..<204:
            let values: [CoreSetAimTrigger] = [.scopeOnly, .fireOnly, .either, .both]
            let index = sender.tag - 200
            guard values.indices.contains(index), aimConfigurationAvailable(.basicAimTrigger) else { return }
            featureState.aim.updateDesired { $0.trigger = values[index] }
            recordAimConfiguration(sender, path: "aim.trigger")
        case 300..<303:
            let values: [CoreSetLockStrength] = [.strong, .medium, .light]
            let index = sender.tag - 300
            guard values.indices.contains(index), aimConfigurationAvailable(.basicAimLockStrength) else { return }
            featureState.aim.updateDesired { $0.lockStrength = values[index] }
            recordAimConfiguration(sender, path: "aim.lockStrength")
        default: return
        }
        rebuildMenu()
    }

    @objc private func toggleRecoilField(_ sender: UIButton) {
        refreshBeforeInteraction(sender)
        let fields: [CoreSetField] = [.recoilEnabled, .recoilStopWhenNotFiring,
            .recoilVerticalEnabled, .recoilHorizontalEnabled]
        guard fields.indices.contains(sender.tag), recoilConfigurationAvailable(fields[sender.tag]) else { return }
        editGame(\.recoil) { state in
            switch sender.tag {
            case 0: state.enabled = state.enabled != true
            case 1: state.stopWhenNotFiring.enabled = state.stopWhenNotFiring.enabled != true
            case 2: state.verticalEnabled = state.verticalEnabled != true
            default: state.horizontalEnabled = state.horizontalEnabled != true
            }
        }
        let paths = ["enabled", "stopWhenNotFiring", "verticalEnabled", "horizontalEnabled"]
        recordRecoilConfiguration(sender, path: "recoil.\(paths[sender.tag])")
        rebuildMenu()
    }

    @objc private func configureRecoilStrength(_ sender: UISlider) {
        refreshBeforeInteraction(sender)
        let fields: [CoreSetField] = [.recoilVerticalStrength, .recoilHorizontalStrength]
        guard fields.indices.contains(sender.tag), recoilConfigurationAvailable(fields[sender.tag]) else { return }
        let value = Int(sender.value.rounded())
        editGame(\.recoil) { state in
            if sender.tag == 0 { state.verticalStrength.set(value) }
            else { state.horizontalStrength.set(value) }
        }
        recordRecoilConfiguration(sender, path: sender.tag == 0 ?
            "recoil.verticalStrength" : "recoil.horizontalStrength")
        rebuildMenu()
    }

    @objc private func configureBasicAimTrigger(_ sender: UISegmentedControl) {
        guard featureState.aim.phase != .applying && featureState.aim.phase != .active,
              aimConfigurationAvailable(.basicAimTrigger) else { return }
        guard (0...3).contains(sender.selectedSegmentIndex) else { return }
        let modes: [CoreSetAimTrigger] = [.scopeOnly, .fireOnly, .either, .both]
        featureState.aim.updateDesired { $0.trigger = modes[sender.selectedSegmentIndex] }
        recordAimConfiguration(sender, path: "aim.trigger")
        rebuildMenu()
    }
    @objc private func configureBasicAimRange(_ sender: UISlider) {
        let fields: [CoreSetField] = [.basicAimCircleSize, .basicAimMaximumDistance,
            .basicAimStrength, .basicAimSmoothing, .basicAimHorizontalSpeed,
            .basicAimVerticalSpeed, .basicAimLockThreshold, .basicAimConfirmationFrames,
            .basicAimTakeoverPause, .basicAimPredictionMilliseconds]
        guard featureState.aim.phase != .applying && featureState.aim.phase != .active,
              fields.indices.contains(sender.tag), aimConfigurationAvailable(fields[sender.tag]) else { return }
        featureState.aim.updateDesired {
            switch sender.tag {
            case 0: $0.circleSize.set(Int(sender.value.rounded()))
            case 1: $0.custom.maximumDistance.set(Int(sender.value.rounded()))
            case 2: $0.custom.strength.set(Int(sender.value.rounded()))
            case 3: $0.custom.smoothing.set(Int(sender.value.rounded()))
            case 4: $0.custom.horizontalSpeed.set(Int(sender.value.rounded()))
            case 5: $0.custom.verticalSpeed.set(Int(sender.value.rounded()))
            case 6: $0.custom.lockThreshold.set(Int(sender.value.rounded()))
            case 7: $0.custom.confirmationFrames.set(Int(sender.value.rounded()))
            case 8: $0.custom.takeoverPauseMilliseconds.set(Int(sender.value.rounded()))
            case 9: $0.custom.predictionMilliseconds.set(Int(sender.value.rounded()))
            default: break
            }
        }
        let paths = ["circleSize", "custom.maximumDistance", "custom.strength", "custom.smoothing",
                      "custom.horizontalSpeed", "custom.verticalSpeed", "custom.lockThreshold",
                      "custom.confirmationFrames", "custom.takeoverPauseMilliseconds", "custom.predictionMilliseconds"]
        recordAimConfiguration(sender, path: "aim.\(paths[sender.tag])")
        // The same explicit size/distance selection also configures the
        // independent local HUD preview; aimControl is never applied here.
        if sender.tag == 0,
           controlAvailability(.localAimCircleSize, in: featureState.aimDisplay) == .ready {
            editGame(\.aimDisplay) { $0.circleSize.set(Int(sender.value.rounded())) }
        } else if sender.tag == 1,
                  controlAvailability(.localAimPreviewDistance, in: featureState.aimDisplay) == .ready {
            editGame(\.aimDisplay) { $0.maximumDistance.set(Int(sender.value.rounded())) }
        } else {
            showConfigurationFeedback("参数配置已记录；启用后由基础视角自瞄消费者应用")
        }
        rebuildMenu()
    }
    @objc private func configureBasicAimBots(_ sender: UISegmentedControl) {
        guard featureState.aim.phase != .applying && featureState.aim.phase != .active,
              aimConfigurationAvailable(.basicAimIncludeBots) else { return }
        guard sender.selectedSegmentIndex >= 0 else { return }
        featureState.aim.updateDesired { $0.includeBots = sender.selectedSegmentIndex == 1 }
        recordAimConfiguration(sender, path: "aim.includeBots")
        if controlAvailability(.localAimPreviewBots, in: featureState.aimDisplay) == .ready {
            editGame(\.aimDisplay) { $0.includeBots = sender.selectedSegmentIndex == 1 }
        }
        rebuildMenu()
    }
    @objc private func configureBasicAimLock(_ sender: UISegmentedControl) {
        guard featureState.aim.phase != .applying && featureState.aim.phase != .active,
              sender.selectedSegmentIndex >= 0,
              aimConfigurationAvailable(.basicAimLockSameTarget) else { return }
        featureState.aim.updateDesired { $0.lockSameTarget = sender.selectedSegmentIndex == 1 }
        recordAimConfiguration(sender, path: "aim.lockSameTarget")
        rebuildMenu()
    }
    @objc private func configureBasicAimPoint(_ sender: UISegmentedControl) {
        let values: [CoreSetAimPoint] = [.head, .chest, .hips]
        guard featureState.aim.phase != .applying && featureState.aim.phase != .active,
              values.indices.contains(sender.selectedSegmentIndex),
              aimConfigurationAvailable(.basicAimPoint) else { return }
        let point = values[sender.selectedSegmentIndex]
        featureState.aim.updateDesired { $0.point = point }
        recordAimConfiguration(sender, path: "aim.point")
        rebuildMenu()
    }
    @objc private func configureBasicAimLockStrength(_ sender: UISegmentedControl) {
        guard featureState.aim.phase != .applying && featureState.aim.phase != .active,
              aimConfigurationAvailable(.basicAimLockStrength) else { return }
        let values: [CoreSetLockStrength] = [.strong, .medium, .light]
        guard values.indices.contains(sender.selectedSegmentIndex) else { return }
        featureState.aim.updateDesired { $0.lockStrength = values[sender.selectedSegmentIndex] }
        recordAimConfiguration(sender, path: "aim.lockStrength")
        rebuildMenu()
    }
    @objc private func startBasicAim() {
        guard aimConfigurationAvailable(.basicAimEnabled) else { return }
        recordAimConfiguration(view, path: "aim.enabled")
        editGame(\.aim) { $0.enabled = true }
    }
    @objc private func stopBasicAim() {
        if featureState.aim.restoration.stopComplete {
            guard aimConfigurationAvailable(.basicAimEnabled) else { return }
            featureState.aim.updateDesired { $0.enabled = false }
            recordAimConfiguration(view, path: "aim.enabled=false")
            rebuildMenu()
            return
        }
        guard let consumer = gameConsumers[\CoreSetFeatureState.aim] as? CoreSetMenuConsumer<CoreSetAimSettings>,
              let token = featureState.aim.prepareStop() else {
            let reason = unavailableReason(title: "关闭自瞄") ?? "aim.stop：没有可停止的已确认动作会话"
            showConfigurationFeedback(reason)
            NSLog("Core-SET: menu stage=unavailable control=core-set.5.aimStop.0 configured=0 confirmed=0 reason=%@", reason)
            return
        }
        let hostedSource = interactionControlIdentifier
        consumer.stop(token) { [weak self] token, outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                let received = self.featureState.aim.receiveStop(token, outcome: outcome)
                if received && self.featureState.aim.restoration.stopComplete {
                    self.featureState.aim.updateDesired { $0.enabled = false }
                }
                NSLog("Core-SET: hosted input stage=actual control=%@ capability=aimStop confirmed=%d",
                      hostedSource, received && self.featureState.aim.restoration.stopComplete ? 1 : 0)
                self.rebuildMenu()
            }
        }
    }
    private func aimControls(in aim: UIView, filter: UIView, scenario: UIView) {
        let state = featureState.aim.desired
        let editable = featureState.aim.phase != .applying && featureState.aim.phase != .active
        let custom = state.scene == .custom
        let modes: [CoreSetAimTrigger] = [.scopeOnly, .fireOnly, .either, .both]
        let trigger = UISegmentedControl(items: ["仅开镜", "仅开火", "开镜或开火", "开镜且开火"])
        trigger.frame = CGRect(x: 335, y: 34, width: 303, height: 40)
        trigger.selectedSegmentIndex = state.trigger.flatMap { modes.firstIndex(of: $0) } ?? UISegmentedControl.noSegment
        trigger.isEnabled = editable && aimConfigurationAvailable(.basicAimTrigger)
        trigger.addTarget(self, action: #selector(configureBasicAimTrigger(_:)), for: .valueChanged)
        registerHosted(trigger, .aimTrigger)
        aim.addSubview(trigger)
        let point = UISegmentedControl(items: ["头部", "胸部", "屁股"])
        point.frame = CGRect(x: 20, y: 34, width: 300, height: 40)
        point.selectedSegmentIndex = state.point?.rawValue ?? UISegmentedControl.noSegment
        point.isEnabled = editable && aimConfigurationAvailable(.basicAimPoint)
        point.accessibilityHint = "选择基础视角自瞄目标高度"
        point.addTarget(self, action: #selector(configureBasicAimPoint(_:)), for: .valueChanged)
        registerHosted(point, .aimPoint)
        aim.addSubview(point)
        let circle = UISlider(frame: CGRect(x: 145, y: 82, width: 493, height: 36))
        circle.tag = 0; circle.minimumValue = 30; circle.maximumValue = 525
        circle.value = Float(state.circleSize.value ?? 30)
        circle.isEnabled = editable && aimConfigurationAvailable(.basicAimCircleSize)
        circle.accessibilityValue = state.circleSize.value.map(String.init) ?? "未选择"
        circle.addTarget(self, action: #selector(configureBasicAimRange(_:)), for: .valueChanged)
        registerHosted(circle, .aimRange, field: .localAimCircleSize, capability: .localAimDisplay)
        aim.addSubview(label("自瞄圈大小 \(state.circleSize.value.map(String.init) ?? "未选择")", size: 16,
                             frame: CGRect(x: 20, y: 82, width: 120, height: 36)))
        aim.addSubview(circle)
        let bots = UISegmentedControl(items: ["不含人机", "含人机"])
        bots.frame = CGRect(x: 20, y: 34, width: 135, height: 40)
        bots.selectedSegmentIndex = state.includeBots.map { $0 ? 1 : 0 } ?? UISegmentedControl.noSegment
        bots.isEnabled = editable && aimConfigurationAvailable(.basicAimIncludeBots)
        bots.accessibilityLabel = "瞄准人机（本地配置／替代预览）"
        bots.addTarget(self, action: #selector(configureBasicAimBots(_:)), for: .valueChanged)
        registerHosted(bots, .aimBots, field: .localAimPreviewBots, capability: .localAimDisplay)
        filter.addSubview(bots)
        let lock = UISegmentedControl(items: ["最近目标", "锁定同目标"])
        lock.frame = CGRect(x: 165, y: 34, width: 138, height: 40)
        lock.selectedSegmentIndex = state.lockSameTarget.map { $0 ? 1 : 0 } ?? UISegmentedControl.noSegment
        lock.isEnabled = editable && aimConfigurationAvailable(.basicAimLockSameTarget)
        lock.addTarget(self, action: #selector(configureBasicAimLock(_:)), for: .valueChanged)
        registerHosted(lock, .aimLock)
        filter.addSubview(lock)
        var rows: [(String, Int?, Float, Float, Int)] = []
        if custom {
            rows = [("最大距离", state.custom.maximumDistance.value, 10, 500, 1),
                     ("自瞄强度", state.custom.strength.value, 5, 100, 2),
                     ("转动平滑", state.custom.smoothing.value, 1, 10, 3),
                     ("接管确认帧数", state.custom.confirmationFrames.value, 1, 6, 7)]
        }
        for (index, row) in rows.enumerated() {
            let y = 82 + CGFloat(index) * 38
            filter.addSubview(label(row.0 + " " + (row.1.map(String.init) ?? "未选择"),
                size: 10, frame: CGRect(x: 12, y: y, width: 88, height: 34)))
            let slider = UISlider(frame: CGRect(x: 102, y: y, width: 201, height: 34))
            slider.tag = row.4; slider.minimumValue = row.2; slider.maximumValue = row.3
            slider.value = Float(row.1 ?? Int(slider.minimumValue)); slider.isContinuous = false
            slider.accessibilityLabel = row.0
            slider.accessibilityValue = row.1.map(String.init) ?? "未选择"
            let field: CoreSetField = row.4 == 1 ? .basicAimMaximumDistance :
                (row.4 == 2 ? .basicAimStrength :
                 (row.4 == 3 ? .basicAimSmoothing : .basicAimConfirmationFrames))
            slider.isEnabled = editable && aimConfigurationAvailable(field)
            slider.addTarget(self, action: #selector(configureBasicAimRange(_:)), for: .valueChanged)
            if row.4 == 1 {
                registerHosted(slider, .aimRange, field: .localAimPreviewDistance, capability: .localAimDisplay)
            } else { registerHosted(slider, .aimRange) }
            filter.addSubview(slider)
        }
        if custom {
            let scenarioRows: [(String, Int?, Float, Float, Int)] = [
                ("水平速度", state.custom.horizontalSpeed.value, 30, 720, 4),
                ("垂直速度", state.custom.verticalSpeed.value, 30, 720, 5),
                ("预判提前", state.custom.predictionMilliseconds.value, 0, 300, 9),
                ("锁定门槛", state.custom.lockThreshold.value, 5, 500, 6),
                ("接管暂停", state.custom.takeoverPauseMilliseconds.value, 50, 1000, 8)
            ]
            for (index, row) in scenarioRows.enumerated() {
                let y = 82 + CGFloat(index) * 32
                let title = label(row.0 + " " + (row.1.map(String.init) ?? "未选择"),
                                  size: 10, frame: CGRect(x: 12, y: y, width: 88, height: 30))
                title.adjustsFontSizeToFitWidth = true
                scenario.addSubview(title)
                let slider = UISlider(frame: CGRect(x: 102, y: y, width: 201, height: 30))
                slider.tag = row.4; slider.minimumValue = row.2; slider.maximumValue = row.3
                slider.value = Float(row.1 ?? Int(row.2))
                let field: CoreSetField = row.4 == 4 ? .basicAimHorizontalSpeed :
                    (row.4 == 5 ? .basicAimVerticalSpeed :
                     (row.4 == 9 ? .basicAimPredictionMilliseconds :
                      (row.4 == 6 ? .basicAimLockThreshold : .basicAimTakeoverPause)))
                slider.isEnabled = editable && aimConfigurationAvailable(field)
                slider.accessibilityLabel = row.0
                slider.accessibilityValue = row.1.map(String.init) ?? "未选择"
                slider.accessibilityHint = "基础视角自瞄运行参数"
                slider.addTarget(self, action: #selector(configureBasicAimRange(_:)), for: .valueChanged)
                registerHosted(slider, .aimRange)
                scenario.addSubview(slider)
            }
        } else if state.scene != nil {
            let strength = UISegmentedControl(items: ["强锁定", "中锁定", "轻锁定"])
            strength.frame = CGRect(x: 12, y: 82, width: 299, height: 40)
            let strengths: [CoreSetLockStrength] = [.strong, .medium, .light]
            strength.selectedSegmentIndex = state.lockStrength.flatMap { strengths.firstIndex(of: $0) } ?? UISegmentedControl.noSegment
            strength.isEnabled = editable && aimConfigurationAvailable(.basicAimLockStrength)
            strength.addTarget(self, action: #selector(configureBasicAimLockStrength(_:)), for: .valueChanged)
            registerHosted(strength, .aimLockStrength)
            scenario.addSubview(strength)
        }
        let configured = state.scene != nil && (state.scene != .custom ||
            (state.custom.maximumDistance.value != nil && state.custom.strength.value != nil &&
             state.custom.smoothing.value != nil && state.custom.horizontalSpeed.value != nil &&
             state.custom.verticalSpeed.value != nil && state.custom.lockThreshold.value != nil &&
             state.custom.confirmationFrames.value != nil && state.custom.predictionMilliseconds.value != nil &&
             state.custom.takeoverPauseMilliseconds.value != nil)) &&
             (state.scene == .custom || state.lockStrength != nil)
        let totalSwitch = UIButton(type: .system)
        totalSwitch.frame = CGRect(x: 20, y: 126, width: 245, height: 40)
        totalSwitch.setTitle("自瞄总开关", for: .normal)
        let restorationNeedsStop: Bool
        switch featureState.aim.restoration {
        case .required, .pending, .failed: restorationNeedsStop = true
        case .notNeeded, .confirmed, .abandoned: restorationNeedsStop = false
        }
        let turningOff = state.enabled == true || restorationNeedsStop
        let readyToConfigureOn = editable && aimConfigurationAvailable(.basicAimEnabled) && configured &&
            state.trigger != nil && state.includeBots != nil && state.lockSameTarget != nil &&
            state.point != nil && state.circleSize.value != nil
        totalSwitch.isEnabled = featureState.aim.restoration != .pending &&
            (turningOff ? (restorationNeedsStop || aimConfigurationAvailable(.basicAimEnabled)) : readyToConfigureOn)
        totalSwitch.isSelected = state.enabled == true
        totalSwitch.accessibilityValue = featureState.aim.restoration == .pending ? "停止清理中" :
            (featureState.aim.phase == .active ? "运行中" : (state.enabled == true ? "已配置" : "关闭"))
        if turningOff {
            totalSwitch.accessibilityHint = "停止后续写入并清理目标会话"
            totalSwitch.addTarget(self, action: #selector(stopBasicAim), for: .touchUpInside)
            registerHosted(totalSwitch, .aimStop)
        } else {
            totalSwitch.accessibilityHint = "启动基础视角自瞄并等待目标写入回读"
            totalSwitch.addTarget(self, action: #selector(startBasicAim), for: .touchUpInside)
            registerHosted(totalSwitch, .aimStart)
        }
        aim.addSubview(totalSwitch)
        let text: String
        if case .unavailable(let reason) = featureState.aim.availability { text = reason }
        else { text = basicAimStatus }
        let status = label(text, size: 10, frame: CGRect(x: 280, y: 122, width: 358, height: 54), secondary: true)
        status.numberOfLines = 3; aim.addSubview(status); basicAimStatusLabel = status
        content.contentSize.height = 735
    }
    private func rebuildPage() {
        switch selectedPage {
        case 0:
            let kernel = card("内核管理", CGRect(x: 0, y: 0, width: 323, height: 466))
            kernel.addSubview(label("DarkSword", size: 16,
                                    frame: CGRect(x: 12, y: 34, width: 299, height: 32), secondary: true))
            disabledRows(["运行模式  安全 / 效率", "掩体判断  全局 / 局内 / 关闭"], in: kernel, y: 70)
            homeStatusRows(in: kernel)
            disabledRows(["内核利用", "获取信息"], in: kernel, y: 380)
            let settings = card("界面设置", CGRect(x: 335, y: 0, width: 323, height: 175))
            themeChoice("暗黑", light: false, in: settings, x: 12)
            themeChoice("纯白", light: true, in: settings, x: 122)
            localColorRows(in: settings)
            let fps = card("局内绘制帧率", CGRect(x: 335, y: 203, width: 323, height: 90))
            disabledRows(["FPS 调节"], in: fps, y: 38)
            let performance = card("性能监测", CGRect(x: 335, y: 321, width: 323, height: 145))
            let values = performanceValues()
            for (index, title) in ["CPU 占用", "内存占用", "内存峰值"].enumerated() {
                performanceValueLabels.append(statusRow(title, value: values[index],
                    in: performance, y: 34 + CGFloat(index) * 30))
            }
        case 1:
            let players = card("玩家显示", CGRect(x: 0, y: 0, width: 323, height: 225))
            disabledRows(["显示手持  贴图 / 文字 / 关闭", "玩家数量  详细 / 精简 / 关闭",
                          "显示信息  现代 / 简约 / 关闭", "显示射线", "显示方框", "显示距离", "显示骨骼"], in: players, y: 34, playerScope: .player)
            let bots = card("人机显示", CGRect(x: 335, y: 0, width: 323, height: 225))
            disabledRows(["人机手持  贴图 / 文字 / 关闭", "人机数量  详细 / 精简 / 关闭",
                          "显示信息  现代 / 简约 / 关闭", "显示射线", "显示方框", "显示距离", "显示骨骼"], in: bots, y: 34, playerScope: .bot)
            let advanced = card("进阶设置", CGRect(x: 0, y: 253, width: 323, height: 239))
            disabledRows(["隐藏人机", "手雷预警", "背敌指示  指示+距离 / 指示 / 关闭"], in: advanced, y: 34, playerScope: .player)
            backStylePreview(in: advanced)
            let tuning = card("绘制调节", CGRect(x: 335, y: 253, width: 323, height: 239))
            disabledRows(["绘制显示距离", "骨骼显示距离", "背敌指示大小"], in: tuning, y: 34)
        case 2:
            let materials = card("物资管理", CGRect(x: 0, y: 0, width: 658, height: 75))
            disabledRows(["显示物资", "持枪屏蔽物资", "地铁头甲", "隐藏已开启地铁箱子",
                          "显示地铁箱子等级", "显示载具油量血量"], in: materials, y: 4, columns: 3)
            let filter = card("物资筛选", CGRect(x: 0, y: 103, width: 658, height: 389))
            categoryTabs(["载具车辆", "游戏道具", "物资箱子", "治疗药品", "三级防具", "配件弹药"], in: filter, y: 34)
            categoryTabs(["突击步枪", "冲锋枪", "霰弹枪", "栓动狙击", "射手步枪", "轻机枪", "其他武器"], in: filter, y: 68, startIndex: 6)
            disabledRows(["最小距离", "最大距离"], in: filter, y: 110, columns: 2, materialFilter: true)
            disabledRows(["分类颜色", "全开", "全关"], in: filter, y: 145, columns: 3, materialFilter: true)
            materialPreview(in: filter)
        case 3:
            let players = card("玩家颜色", CGRect(x: 0, y: 0, width: 323, height: 225))
            let bots = card("人机颜色", CGRect(x: 335, y: 0, width: 323, height: 225))
            let colors = ["名称颜色", "射线颜色", "距离颜色", "骨骼颜色", "队伍颜色"]
            previewColorRows(colors, scope: .player, in: players)
            previewColorRows(colors, scope: .bot, in: bots)
            let weight = card("粗细调节", CGRect(x: 0, y: 252, width: 658, height: 232))
            disabledRows(["射线粗细", "骨骼粗细", "物资字体"], in: weight, y: 34)
        case 4:
            if featureState.radar.desired.placement.canvas == nil {
                let screen = view.window?.screen ?? UIScreen.main
                let canvas = CoreSetRadarCanvas(nativeWidth: Double(screen.nativeBounds.width),
                    nativeHeight: Double(screen.nativeBounds.height), displayWidth: Double(view.bounds.width),
                    displayHeight: Double(view.bounds.height))
                featureState.radar.updateDesired { $0.placement.refreshCanvas(canvas) }
            }
            let radar = card("雷达设置", CGRect(x: 0, y: 0, width: 323, height: 360))
            disabledRows(["雷达", "显示距离米数", "探测距离"], in: radar, y: 34)
            radarRangeRows.frame = CGRect(x: 12, y: 124, width: radar.bounds.width - 24, height: 90)
            radar.addSubview(radarRangeRows)
            refreshRadarRangeRows()
            let warning = card("预警设置", CGRect(x: 335, y: 0, width: 323, height: 360))
            disabledRows(["被瞄预警", "忽略人机", "被瞄预警范围", "预警文字调节"], in: warning, y: 34)
        case 5:
            // Core v1.7 0x1000cef88: 658x160. The first child is 230x145;
            // the remaining width is the second child. The lower cards start
            // at y=188 and are 323x220, or 323x315 for the custom scene.
            let aim = card("Core稳定自瞄", CGRect(x: 0, y: 0, width: 658, height: 160))
            let left = UIView(frame: CGRect(x: 0, y: 0, width: 230, height: 145))
            let right = UIView(frame: CGRect(x: 250, y: 0, width: 400, height: 145))
            aim.addSubview(left); aim.addSubview(right)
            disabledRows(["自瞄总开关", "预瞄标记圈", "动态自瞄圈", "自瞄连接线"],
                         in: left, y: 0)
            disabledRows(["瞄准部位  头部 / 胸部 / 屁股",
                          "触发模式  仅开镜 / 仅开火 / 开镜或开火 / 开镜且开火",
                          "显示自瞄圈", "自瞄圈大小"], in: right, y: 0)
            let custom = featureState.aim.desired.scene == .custom
            let lowerHeight: CGFloat = custom ? 315 : 220
            let filter = card("目标筛选", CGRect(x: 0, y: 188, width: 323, height: lowerHeight))
            var filterRows = ["倒地不瞄", "瞄准人机", "锁定同目标"]
            if custom { filterRows += ["最大距离", "自瞄强度", "转动平滑", "接管确认帧数"] }
            disabledRows(filterRows, in: filter, y: 34)
            let scenario = card("场景预设", CGRect(x: 335, y: 188, width: 323, height: lowerHeight))
            scenePreview(in: scenario)
            if custom {
                disabledRows(["水平速度", "垂直速度", "预判提前", "锁定门槛", "接管暂停"],
                             in: scenario, y: 86)
            } else if featureState.aim.desired.scene != nil {
                disabledRows(["锁定强度  强锁定 / 中锁定 / 轻锁定"], in: scenario, y: 86)
            }
            content.contentSize.height = 188 + lowerHeight
        default:
            let recoil = card("Core智能压枪【非无后坐力】", CGRect(x: 0, y: 0, width: 658, height: 474))
            disabledRows(["启用压枪", "停火不压", "垂直补偿", "垂直补偿强度", "水平补偿", "水平补偿强度"], in: recoil, y: 34)
            let note = label("压枪并非无后坐力是纯模拟压枪，远距离压不住，效果请自测！", size: 16,
                             frame: .zero, secondary: true)
            note.numberOfLines = 0
            let noteSize = note.sizeThatFits(CGSize(width: recoil.bounds.width - 40, height: 64))
            note.frame = CGRect(x: 20, y: recoil.bounds.height - noteSize.height - 12,
                                width: recoil.bounds.width - 40, height: noteSize.height)
            note.accessibilityHint = "原版说明文案；压枪由共享动作 worker 应用并等待写后回读"
            recoil.addSubview(note)
        }
    }
}
