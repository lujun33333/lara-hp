import Foundation

// v1.7 UI contract only; see artifacts/core-set-v1.7/v1.7-ui-evidence.md, batch 3.
// Nil means unobserved/unselected, not a reference default. No game schema or algorithm.
// Owners must serialize mutations and consumer callbacks on the same executor.
enum CoreSetPage: String, CaseIterable { case home, player, materials, adjustments, radar, aim, recoil }

enum CoreSetCapability: String, CaseIterable {
    case hostWindow, remoteHosting, localRendering, touchTransport, readTransport
    case homeSettings, frameScheduling, playerRendering, materialFiltering, drawingAppearance, radarRendering
    case aimControl, recoilControl, localAimDisplay, kernelAction, informationAction, runtimeTelemetry
    var isInfrastructure: Bool {
        switch self {
        case .hostWindow, .remoteHosting, .localRendering, .touchTransport, .readTransport: return true
        default: return false
        }
    }
}

enum CoreSetAvailability: Equatable {
    case unavailable(reason: String)
    case ready
}

// A consumer declares concrete controls, not a whole page by implication.
// These are local contract IDs; none is a game-memory offset.
enum CoreSetActorScope: Hashable { case player, bot }
enum CoreSetActorField: Hashable { case weapon, count, information, ray, box, distance, bones }
enum CoreSetColorField: Hashable { case name, ray, distance, bone, team }
enum CoreSetField: Hashable {
    case actor(CoreSetActorScope, CoreSetActorField)
    case actorColor(CoreSetActorScope, CoreSetColorField)
    case hideBots, grenadeWarning, backIndicator, backStyle, drawingDistance, boneDistance, backSize
    case materialEnabled, hideWhileArmed, metroArmor, hideOpenedCrates, showCrateLevel, vehicleStatus
    case materialDistance, materialColor, materialGroupSelection
    case rayThickness, boneThickness, materialFontSize, framesPerSecond
    case radarEnabled, radarShowDistance, radarDetectionDistance, radarRadius, radarX, radarY
    case warningEnabled, warningIgnoreBots, warningRange, warningTextSize
    case localAimCircle, localAimCircleSize, localAimPreviewLine, localAimPreviewMarker
    case localAimDynamicCircle, localAimPreviewBots, localAimPreviewDistance
    case basicAimEnabled, basicAimTrigger, basicAimDistance, basicAimRadius, basicAimBots
    case basicAimScene, basicAimStrength, basicAimSmoothing, basicAimHorizontalSpeed
    case basicAimVerticalSpeed, basicAimLockSameTarget, basicAimPoint
    case basicAimLockThreshold, basicAimConfirmationFrames, basicAimTakeoverPause

    static func required(for capability: CoreSetCapability) -> Set<CoreSetField> {
        switch capability {
        case .aimControl: return [.basicAimEnabled, .basicAimTrigger, .basicAimDistance, .basicAimRadius,
                                  .basicAimBots, .basicAimScene, .basicAimStrength, .basicAimSmoothing,
                                  .basicAimHorizontalSpeed, .basicAimVerticalSpeed, .basicAimLockSameTarget,
                                  .basicAimPoint, .basicAimLockThreshold, .basicAimConfirmationFrames,
                                  .basicAimTakeoverPause]
        case .frameScheduling: return [.framesPerSecond]
        case .localAimDisplay: return [.localAimCircle, .localAimCircleSize,
                                       .localAimPreviewLine, .localAimPreviewMarker,
                                       .localAimDynamicCircle, .localAimPreviewBots,
                                       .localAimPreviewDistance]
        case .playerRendering:
            let actors = [CoreSetActorScope.player, .bot].flatMap { scope in
                [CoreSetActorField.weapon, .count, .information, .ray, .box, .distance, .bones]
                    .map { CoreSetField.actor(scope, $0) }
            }
            return Set(actors + [.hideBots, .grenadeWarning, .backIndicator, .backStyle,
                                 .drawingDistance, .boneDistance, .backSize])
        case .materialFiltering:
            return [.materialEnabled, .hideWhileArmed, .metroArmor, .hideOpenedCrates,
                    .showCrateLevel, .vehicleStatus, .materialDistance, .materialColor,
                    .materialGroupSelection]
        case .drawingAppearance:
            let colors = [CoreSetActorScope.player, .bot].flatMap { scope in
                [CoreSetColorField.name, .ray, .distance, .bone, .team]
                    .map { CoreSetField.actorColor(scope, $0) }
            }
            return Set(colors + [.rayThickness, .boneThickness, .materialFontSize])
        case .radarRendering:
            return [.radarEnabled, .radarShowDistance, .radarDetectionDistance, .radarRadius,
                    .radarX, .radarY, .warningEnabled, .warningIgnoreBots, .warningRange,
                    .warningTextSize]
        default: return []
        }
    }
}

enum CoreSetRestoration: Equatable { case notNeeded, required, pending, confirmed, failed(String) }
enum CoreSetActualPhase: Equatable { case unknown, applying, active, stopping, stopped, failed(String) }

struct CoreSetRequestToken: Equatable {
    let generation: UUID
    let consumerID: UUID
    let requestID: UUID
}

struct CoreSetApplyRequest<Value: Equatable> {
    let token: CoreSetRequestToken
    let desired: Value
}

// A receipt is an observation, never merely "request accepted". Consumers must not
// report .applied from a menu callback or from host-window readiness alone.
enum CoreSetApplyOutcome<Value: Equatable> {
    case applied(observed: Value)
    case unavailable(reason: String)
    case failed(reason: String)
}

enum CoreSetStopOutcome { case restored, stopped(reason: String), failed(reason: String) }

protocol CoreSetFeatureConsumer: AnyObject {
    associatedtype State: Equatable
    var capability: CoreSetCapability { get }
    var availability: CoreSetAvailability { get }
    var supportedFields: Set<CoreSetField> { get }
    func apply(_ request: CoreSetApplyRequest<State>, completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void)
    func stop(_ token: CoreSetRequestToken, completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void)
}

extension CoreSetFeatureConsumer {
    var supportedFields: Set<CoreSetField> { [] }
}

private final class CoreSetConsumerBinding<Value: Equatable> {
    let id = UUID()
    weak var owner: AnyObject?
    let currentAvailability: () -> CoreSetAvailability
    let supportedFields: () -> Set<CoreSetField>
    init<Consumer: CoreSetFeatureConsumer>(_ consumer: Consumer) where Consumer.State == Value {
        owner = consumer
        currentAvailability = { [weak consumer] in
            consumer?.availability ?? .unavailable(reason: "Consumer released")
        }
        supportedFields = { [weak consumer] in consumer?.supportedFields ?? [] }
    }
}

struct CoreSetFeatureChannel<Value: Equatable> {
    let capability: CoreSetCapability
    private(set) var desired: Value
    private(set) var actual: Value?
    private(set) var availability: CoreSetAvailability = .unavailable(reason: "No consumer attached")
    private(set) var supportedFields: Set<CoreSetField> = []
    private(set) var phase: CoreSetActualPhase = .unknown
    private(set) var restoration: CoreSetRestoration = .notNeeded
    private(set) var generation = UUID()
    private(set) var pendingApply: CoreSetApplyRequest<Value>?
    private(set) var pendingStop: CoreSetRequestToken?
    private(set) var suspended = false
    // Tracks possible effects even after a failed/lost apply acknowledgement.
    private var mayHaveEffects = false
    private var binding: CoreSetConsumerBinding<Value>?

    init(capability: CoreSetCapability, desired: Value) {
        self.capability = capability
        self.desired = desired
    }

    var isDesiredConfirmed: Bool {
        binding?.owner != nil && binding?.currentAvailability() == .ready && availability == .ready &&
            !suspended && phase == .active && actual == desired && pendingApply == nil
    }
    // Field-level consumers may apply a supported subset while the page-level
    // availability remains unavailable until every required control is backed.
    var canApplySupportedSubset: Bool {
        (capability == .playerRendering || capability == .materialFiltering ||
         capability == .radarRendering || capability == .drawingAppearance ||
         capability == .localAimDisplay) &&
            binding?.owner != nil && binding?.currentAvailability() == .ready &&
            !supportedFields.isEmpty && supportedFields.isSubset(of: CoreSetField.required(for: capability))
    }
    func fieldAvailability(_ field: CoreSetField) -> CoreSetAvailability {
        guard CoreSetField.required(for: capability).contains(field) else {
            return .unavailable(reason: "Field does not belong to this capability")
        }
        guard !suspended, pendingStop == nil, binding?.owner != nil,
              binding?.supportedFields().contains(field) == true else {
            return .unavailable(reason: "Field consumer is unavailable")
        }
        return binding?.currentAvailability() ?? .unavailable(reason: "Consumer released")
    }
    mutating func updateDesired(_ edit: (inout Value) -> Void) { edit(&desired) }

    // Binding requires a live consumer of this state type and exact capability.
    // The owner retains it; this channel never extends a consumer's lifetime.
    @discardableResult
    mutating func bind<Consumer: CoreSetFeatureConsumer>(_ consumer: Consumer) -> Bool where Consumer.State == Value {
        guard consumer.capability == capability, !mayHaveEffects, pendingStop == nil else { return false }
        binding = CoreSetConsumerBinding(consumer)
        generation = UUID(); pendingApply = nil; actual = nil; phase = .unknown
        refreshAvailability()
        return true
    }

    mutating func refreshAvailability() {
        let value = binding?.currentAvailability() ?? .unavailable(reason: "No consumer attached")
        supportedFields = binding?.supportedFields() ?? []
        let missing = CoreSetField.required(for: capability).subtracting(supportedFields)
        availability = value == .ready && !missing.isEmpty
            ? .unavailable(reason: "Only \(supportedFields.count) of \(supportedFields.count + missing.count) controls supported")
            : value
        if case .unavailable(let reason) = value {
            pendingApply = nil
            if pendingStop == nil { phase = .failed(reason) }
        }
    }

    // Call only after Composer has dropped the old host generation's frames.
    // A prior local display receipt cannot remain the current actual value.
    mutating func invalidateLocalFrameObservation() {
        guard capability == .localAimDisplay, pendingStop == nil else { return }
        generation = UUID(); pendingApply = nil; actual = nil; phase = .unknown
        mayHaveEffects = false; restoration = .notNeeded
    }

    mutating func prepareApply() -> CoreSetApplyRequest<Value>? {
        refreshAvailability()
        guard let binding = binding, binding.owner != nil else { return nil }
        guard !suspended, (availability == .ready || canApplySupportedSubset),
              pendingStop == nil, pendingApply == nil,
              restoration != .pending else { return nil }
        if restoration == .required && phase != .active { return nil }
        if case .failed = restoration { return nil }
        let request = CoreSetApplyRequest(token: CoreSetRequestToken(generation: generation, consumerID: binding.id, requestID: UUID()), desired: desired)
        pendingApply = request
        phase = .applying
        mayHaveEffects = true
        restoration = .required
        return request
    }

    @discardableResult
    mutating func receive(_ token: CoreSetRequestToken, outcome: CoreSetApplyOutcome<Value>) -> Bool {
        guard binding?.owner != nil, token.consumerID == binding?.id,
              token.generation == generation, pendingApply?.token == token, !suspended else { return false }
        pendingApply = nil
        switch outcome {
        case .applied(let observed):
            guard binding?.currentAvailability() == .ready else { refreshAvailability(); return false }
            actual = observed; phase = .active
        case .unavailable(let reason): availability = .unavailable(reason: reason); phase = .failed(reason)
        case .failed(let reason): phase = .failed(reason)
        }
        return true
    }

    // Close preserves desired configuration and modes. Caller must deliver pendingStop
    // to the old consumer and wait for a real restore receipt before reactivation.
    mutating func suspend() {
        suspended = true
        pendingApply = nil
        if mayHaveEffects { _ = prepareStop() }
    }

    @discardableResult
    mutating func prepareStop() -> CoreSetRequestToken? {
        guard mayHaveEffects else { return nil }
        if let token = pendingStop { return token }
        pendingApply = nil
        guard let binding = binding else { restoration = .required; return nil }
        let token = CoreSetRequestToken(generation: generation, consumerID: binding.id, requestID: UUID())
        pendingStop = token
        restoration = .pending
        phase = .stopping
        return token
    }

    @discardableResult
    mutating func receiveStop(_ token: CoreSetRequestToken, outcome: CoreSetStopOutcome) -> Bool {
        guard binding?.owner != nil, token.consumerID == binding?.id,
              token.generation == generation, pendingStop == token else { return false }
        pendingStop = nil
        switch outcome {
        case .restored:
            mayHaveEffects = false; restoration = .confirmed; phase = .stopped; actual = nil
        case .stopped:
            // No continued action remains. The dynamic view angle was not rolled
            // back; confirmed here means the stop barrier, not byte restoration.
            mayHaveEffects = false; restoration = .notNeeded; phase = .stopped; actual = nil
        case .failed(let reason): restoration = .failed(reason); phase = .failed(reason)
        }
        return true
    }

    // Reopen creates a new callback generation, but never silently reapplies desired.
    @discardableResult
    mutating func resume() -> Bool {
        guard !mayHaveEffects, pendingStop == nil else { return false }
        generation = UUID(); pendingApply = nil; actual = nil; phase = .unknown; suspended = false
        return true
    }
}

struct CoreSetIntSetting: Equatable {
    let bounds: ClosedRange<Int>
    private(set) var value: Int?
    init(_ bounds: ClosedRange<Int>) { self.bounds = bounds }
    mutating func set(_ value: Int?) { self.value = value.map { min(bounds.upperBound, max(bounds.lowerBound, $0)) } }
}

struct CoreSetToggleMode<Mode: Equatable>: Equatable {
    var enabled: Bool?
    private(set) var mode: Mode?
    mutating func select(_ mode: Mode) { self.mode = mode; enabled = true }
    mutating func disable() { enabled = false } // Deliberately keep mode.
}

struct CoreSetInvertedFlag: Equatable {
    var enabled: Bool?
    var nativeFlag: Bool? {
        get { enabled.map { !$0 } }
        set { enabled = newValue.map { !$0 } }
    }
    var nativeInteger: Int? { nativeFlag.map { $0 ? 1 : 0 } }
}

struct CoreSetRGBA: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    init?(red: Double, green: Double, blue: Double, alpha: Double) {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    var opaque: CoreSetRGBA { CoreSetRGBA(red: red, green: green, blue: blue, alpha: 1)! }
}

enum CoreSetRunMode: String { case safe, efficiency } // Native enum conversion unresolved.
enum CoreSetCoverMode: String { case global, inGame, off } // No guessed backend policy.
enum CoreSetTheme: String { case dark, light }
enum CoreSetFloatingPalette: Int, CaseIterable {
    case first = 6, second = 4, third = 1, fourth = 0, fifth = 2, sixth = 3, gradient = 5
}

struct CoreSetHomeSettings: Equatable {
    var runMode: CoreSetRunMode?
    var coverMode: CoreSetCoverMode?
    var theme: CoreSetTheme?
    private(set) var accent: CoreSetRGBA?
    var floatingPalette: CoreSetFloatingPalette?
    var framesPerSecond = CoreSetIntSetting(30...144) // Reference UI model; runtime uses frameRate channel.
    mutating func setAccent(_ color: CoreSetRGBA?) { accent = color?.opaque }
}

struct CoreSetFrameRateSettings: Equatable {
    var framesPerSecond = CoreSetIntSetting(30...144)
}

// Read-only observations: these are not desired configuration or fabricated status.
struct CoreSetHomeSnapshot: Equatable {
    var kernel: String?
    var stage: String?
    var environment: String?
    var information: String?
    var floating: String?
    var executing: Bool?
    var status: Int?
    var completedPages: UInt64?
    var totalPages: UInt64?
    var environmentStage: String?
    var downloadedBytes: UInt64?
    var totalBytes: UInt64?
    var kernelProgressFraction: Double?
    var showStage: Bool { executing == true || status == 3 }
    var showPageProgress: Bool { showStage && completedPages != nil && (totalPages ?? 0) > 0 }
    var showDownloadProgress: Bool { environmentStage == "ota-download" && downloadedBytes != nil && (totalBytes ?? 0) > 0 }
}

struct CoreSetPerformanceSnapshot: Equatable {
    // Explicit process identity prevents presenting host metrics as game metrics.
    let processID: Int32
    let observedAt: Date
    let cpuPercent: Double?
    let residentMiB: Double?
    let peakResidentMiB: Double?
}

enum CoreSetWeaponMode: Int { case image = 0, text = 1 }
enum CoreSetCountMode: Int { case detailed = 1, compact = 0 }
enum CoreSetInformationMode: Int { case modern = 0, minimal = 1 }
enum CoreSetBackIndicator: Int {
    case withDistance = 0, indicatorOnly = 1, off = 2
    var showDistance: Bool { self == .withDistance }
    var showIndicator: Bool { self != .off }
}
enum CoreSetBackStyle: Int, CaseIterable { case style0, style1, style2, style3, style4, style5 }

struct CoreSetActorDisplay: Equatable {
    var weapon = CoreSetToggleMode<CoreSetWeaponMode>()
    var count = CoreSetToggleMode<CoreSetCountMode>()
    var information = CoreSetToggleMode<CoreSetInformationMode>()
    var ray: Bool?
    var box: Bool?
    var distance: Bool?
    var bones: Bool?
}

struct CoreSetPlayerSettings: Equatable {
    var player = CoreSetActorDisplay()
    var bot = CoreSetActorDisplay()
    var hideBots: Bool?
    var grenadeWarning: Bool?
    var backIndicator: CoreSetBackIndicator?
    var backStyle: CoreSetBackStyle?
    var drawingDistance = CoreSetIntSetting(1...1000)
    var boneDistance = CoreSetIntSetting(1...500)
    var backSize = CoreSetIntSetting(40...160)
}

struct CoreSetActorColors: Equatable {
    var name: CoreSetRGBA?
    var ray: CoreSetRGBA?
    var distance: CoreSetRGBA?
    var bone: CoreSetRGBA?
    var team: CoreSetRGBA?
}

struct CoreSetAdjustmentSettings: Equatable {
    var player = CoreSetActorColors()
    var bot = CoreSetActorColors()
    var rayThickness = CoreSetIntSetting(1...10)
    var boneThickness = CoreSetIntSetting(1...10)
    var materialFontSize = CoreSetIntSetting(5...30)
}

enum CoreSetMaterialCategory: Int, CaseIterable {
    case vehicles, props, crates, medicine, armor, ammunition, assault, submachine
    case shotgun, boltAction, marksman, machineGun, otherWeapons
    var displayName: String {
        ["载具车辆", "游戏道具", "物资箱子", "治疗药品", "三级防具", "配件弹药", "突击步枪", "冲锋枪", "霰弹枪", "栓动狙击", "射手步枪", "轻机枪", "其他武器"][rawValue]
    }
}

// These stable local IDs describe candidate UI records, NOT native game object IDs.
struct CoreSetMaterialGroupID: Hashable { let category: CoreSetMaterialCategory; let index: Int }
enum CoreSetGroupSelection: Equatable { case unknown, none, partial, all }

struct CoreSetMaterialGroup: Equatable {
    let id: CoreSetMaterialGroupID
    let displayName: String
    private(set) var members: [Bool?]
    init(id: CoreSetMaterialGroupID, displayName: String, count: Int) {
        self.id = id; self.displayName = displayName
        members = Array(repeating: nil, count: max(1, count))
    }
    var selection: CoreSetGroupSelection {
        guard members.allSatisfy({ $0 != nil }) else { return .unknown }
        if members.allSatisfy({ $0 == true }) { return .all }
        return members.contains(true) ? .partial : .none
    }
    mutating func setAll(_ value: Bool) { members = members.map { _ in value } }
    mutating func toggle() { setAll(selection != .all) }
    @discardableResult
    mutating func setMember(at index: Int, value: Bool?) -> Bool {
        guard members.indices.contains(index) else { return false }
        members[index] = value; return true
    }
}

struct CoreSetMaterialDistance: Equatable {
    private(set) var minimum: Int?
    private(set) var maximum: Int?
    mutating func setMinimum(_ value: Int?) {
        minimum = value.map { min(maximum ?? 2000, max(0, min(2000, $0))) }
    }
    mutating func setMaximum(_ value: Int?) {
        maximum = value.map { max(minimum ?? 0, max(0, min(2000, $0))) }
    }
}

struct CoreSetMaterialCategoryState: Equatable {
    let category: CoreSetMaterialCategory
    var distance = CoreSetMaterialDistance()
    var color: CoreSetRGBA?
    private(set) var groups: [CoreSetMaterialGroup]
    init(category: CoreSetMaterialCategory) {
        self.category = category
        groups = CoreSetMaterialCatalog.names[category.rawValue].enumerated().map { index, name in
            CoreSetMaterialGroup(id: CoreSetMaterialGroupID(category: category, index: index), displayName: name,
                                 count: CoreSetMaterialCatalog.multiplicity(category: category, name: name))
        }
    }
    mutating func setAll(_ value: Bool) { for index in groups.indices { groups[index].setAll(value) } }
    @discardableResult
    mutating func editGroup(at index: Int, _ edit: (inout CoreSetMaterialGroup) -> Void) -> Bool {
        guard groups.indices.contains(index) else { return false }
        edit(&groups[index]); return true
    }
}

struct CoreSetMaterialSettings: Equatable {
    var enabled: Bool?
    var hideWhileArmed: Bool?
    var metroArmor: Bool?
    var hideOpenedCrates: Bool?
    var showCrateLevel: Bool?
    var vehicleStatus: Bool? // Native UI adapter writes 0/1, reads nonzero.
    private(set) var categories = CoreSetMaterialCategory.allCases.map(CoreSetMaterialCategoryState.init)
    // Selected tab and scroll offset belong to the view, never clear these filters.
    mutating func editCategory(_ category: CoreSetMaterialCategory, _ edit: (inout CoreSetMaterialCategoryState) -> Void) {
        edit(&categories[category.rawValue])
    }
    var candidateRecordCount: Int { categories.reduce(0) { $0 + $1.groups.reduce(0) { $0 + $1.members.count } } }
}

enum CoreSetMaterialCatalog {
    static let names: [[String]] = [
        ["自行车", "小鲨鱼", "雪橇飞车", "飞车刷新", "双人跑车", "沙舟车", "飞马", "小绵羊", "马", "鹿车", "舞龙", "醒狮", "鹿", "装甲车", "摩托车", "雪地摩托", "旅行车", "蹦蹦车", "轿车", "吉普车", "皮卡车", "迷你巴士", "快艇", "摩托艇", "滑翔机", "大脚车", "四轮摩托", "行李车", "越野车", "三轮车", "雪橇车", "船", "跑车", "挖掘机", "风筝", "拉力赛车", "SUV电车", "大巴车", "泥土车", "战斗机", "霹雳车", "溜溜球", "沙漠越野车"],
        ["手雷", "雪人", "密室", "突击兵密钥", "特种兵密钥", "指挥官密钥", "无人机", "旺财", "防雷", "地雷 冰", "地雷 闪", "闪电", "涂鸦", "空袭", "追踪雷", "雷枪", "飞镖", "燃烧", "召回枪", "召回弹", "信号弹", "信号枪", "自救器", "钱", "飞索", "紧急呼救器", "金仓", "金插"],
        ["盒子", "树", "1宝箱", "2宝箱", "篮子", "首饰盒", "3宝箱", "空投", "主题箱子", "扭蛋机", "保险箱1", "保险箱2", "辐射", "物资箱", "超级物资箱", "马车", "棺材"],
        ["饮料", "止痛药", "肾上腺素", "医疗箱"],
        ["三 甲", "三 包", "三 头"],
        ["冲锋消音器", "冲锋快扩", "收束器", "鸭嘴", "散弹快扩", "狙击快扩", "狙击枪托", "狙击消音器", "步枪快扩", "步枪枪托", "轻型握把", "激光瞄准", "直角握把", "步枪消音器", "8倍镜", "6倍镜", "4倍镜", "3倍镜", "5.56MM", "9MM", "45口径", "7.62MM", "12口径", "迫击炮弹", "箭"],
        ["AKM", "ACE32", "蜜獾", "ARX200", "M762", "Groza", "SCAR", "M416", "G36", "Famas"],
        ["UMP45", "JS9", "AKS74U", "Vector"], ["S12K", "DBS", "SPAS", "AA12"],
        ["SVD", "M200", "AMR"], ["SKS", "M417", "M1加兰德", "Mini14"], ["PKM", "MG36"], ["迫击炮", "爆炸弓"]
    ]
    static func multiplicity(category: CoreSetMaterialCategory, name: String) -> Int {
        switch category {
        case .vehicles: return ["飞车刷新": 2, "双人跑车": 2, "舞龙": 2, "鹿": 2, "挖掘机": 2][name] ?? 1
        case .props: return name == "雪人" ? 2 : 1
        case .crates: return ["盒子": 4, "空投": 4, "主题箱子": 2, "辐射": 4, "物资箱": 13][name] ?? 1
        default: return 1
        }
    }
}

struct CoreSetRadarCanvas: Equatable {
    let width: Int
    let height: Int
    init(nativeWidth: Double?, nativeHeight: Double?, displayWidth: Double?, displayHeight: Double?) {
        func dimension(_ native: Double?, _ display: Double?, fallback: Int) -> Int {
            for candidate in [native, display] {
                if let value = candidate, value.isFinite, value > 0, value < Double(Int.max) { return Int(value) }
            }
            return fallback
        }
        width = dimension(nativeWidth, displayWidth, fallback: 390)
        height = dimension(nativeHeight, displayHeight, fallback: 844)
    }
    var radiusBounds: ClosedRange<Int> { 50...max(50, min(300, min(width, height) / 2 - 1)) }
}

struct CoreSetRadarPlacement: Equatable {
    private(set) var canvas: CoreSetRadarCanvas?
    private(set) var radius: Int?
    private(set) var x: Int?
    private(set) var y: Int?
    var xBounds: ClosedRange<Int>? {
        guard let canvas = canvas, let radius = radius else { return nil }
        return radius...max(radius, canvas.width - radius)
    }
    var yBounds: ClosedRange<Int>? {
        guard let canvas = canvas, let radius = radius else { return nil }
        return radius...max(radius, canvas.height - radius)
    }
    mutating func refreshCanvas(_ canvas: CoreSetRadarCanvas) { self.canvas = canvas; setRadius(radius) }
    mutating func setRadius(_ value: Int?) {
        guard let bounds = canvas?.radiusBounds else { return }
        radius = value.map { min(bounds.upperBound, max(bounds.lowerBound, $0)) }
        if radius == nil { x = nil; y = nil; return }
        setX(x); setY(y)
    }
    mutating func setX(_ value: Int?) { if let bounds = xBounds { x = value.map { min(bounds.upperBound, max(bounds.lowerBound, $0)) } } }
    mutating func setY(_ value: Int?) { if let bounds = yBounds { y = value.map { min(bounds.upperBound, max(bounds.lowerBound, $0)) } } }
}

struct CoreSetRadarSettings: Equatable {
    var enabled: Bool?
    var showDistance: Bool?
    var detectionDistance = CoreSetIntSetting(100...1000)
    var placement = CoreSetRadarPlacement()
    var warningEnabled: Bool?
    var ignoreBots: Bool?
    var warningRange = CoreSetIntSetting(20...300)
    var warningTextSize = CoreSetIntSetting(10...200)
}

enum CoreSetAimPoint: Int { case head = 0, chest = 1, hips = 2 }
enum CoreSetAimTrigger: Int { case scopeOnly = 1, fireOnly = 2, either = 0, both = 3 }
enum CoreSetAimScene: Int { case far = 0, close = 2, general = 1, custom = 3 }
enum CoreSetLockStrength: Int { case strong = 4, medium = 3, light = 0 }

struct CoreSetAimCustomSettings: Equatable {
    var maximumDistance = CoreSetIntSetting(10...500)
    var strength = CoreSetIntSetting(5...100)
    var smoothing = CoreSetIntSetting(1...10)
    var confirmationFrames = CoreSetIntSetting(1...6)
    var horizontalSpeed = CoreSetIntSetting(30...720)
    var verticalSpeed = CoreSetIntSetting(30...720)
    var predictionMilliseconds = CoreSetIntSetting(0...300)
    var lockThreshold = CoreSetIntSetting(5...500)
    var takeoverPauseMilliseconds = CoreSetIntSetting(50...1000)
}

struct CoreSetAimSettings: Equatable {
    var enabled: Bool?
    var point: CoreSetAimPoint?
    var preaimCircle: Bool?
    var trigger: CoreSetAimTrigger?
    var dynamicCircle = CoreSetInvertedFlag()
    var showCircle: Bool?
    var connectionLine: Bool?
    var circleSize = CoreSetIntSetting(30...525)
    var excludeKnocked: Bool?
    var includeBots: Bool?
    var lockSameTarget: Bool?
    var scene: CoreSetAimScene?
    var lockStrength: CoreSetLockStrength?
    var custom = CoreSetAimCustomSettings()
    var showCustomControls: Bool { scene == .custom }
    var showLockStrength: Bool { scene != nil && scene != .custom }
    // Switching scenes preserves custom values. Preset rows 0/1/2 are fixed-hash Core v1.7 values.
}

// A local HUD preview only. This state never changes aimControl or target memory.
struct CoreSetAimDisplaySettings: Equatable {
    var circleVisible: Bool?
    var circleSize = CoreSetIntSetting(30...525)
    var connectionLine: Bool?
    var preaimMarker: Bool?
    var dynamicCircle: Bool?
    var includeBots: Bool?
    var maximumDistance = CoreSetIntSetting(10...500)
}

struct CoreSetRecoilSettings: Equatable {
    var enabled: Bool?
    var stopWhenNotFiring = CoreSetInvertedFlag()
    var verticalEnabled: Bool?
    var verticalStrength = CoreSetIntSetting(0...100)
    var horizontalEnabled: Bool?
    var horizontalStrength = CoreSetIntSetting(0...100)
    var verticalDesiredActive: Bool? {
        if enabled == false || verticalEnabled == false { return false }
        return enabled == true && verticalEnabled == true ? true : nil
    }
    var horizontalDesiredActive: Bool? {
        if enabled == false || horizontalEnabled == false { return false }
        return enabled == true && horizontalEnabled == true ? true : nil
    }
}

struct CoreSetFeatureState {
    var home = CoreSetFeatureChannel(capability: .homeSettings, desired: CoreSetHomeSettings())
    var frameRate = CoreSetFeatureChannel(capability: .frameScheduling, desired: CoreSetFrameRateSettings())
    var player = CoreSetFeatureChannel(capability: .playerRendering, desired: CoreSetPlayerSettings())
    var materials = CoreSetFeatureChannel(capability: .materialFiltering, desired: CoreSetMaterialSettings())
    var adjustments = CoreSetFeatureChannel(capability: .drawingAppearance, desired: CoreSetAdjustmentSettings())
    var radar = CoreSetFeatureChannel(capability: .radarRendering, desired: CoreSetRadarSettings())
    var aim = CoreSetFeatureChannel(capability: .aimControl, desired: CoreSetAimSettings())
    var aimDisplay = CoreSetFeatureChannel(capability: .localAimDisplay, desired: CoreSetAimDisplaySettings())
    var recoil = CoreSetFeatureChannel(capability: .recoilControl, desired: CoreSetRecoilSettings())
    var homeSnapshot: CoreSetHomeSnapshot?
    var homeObservationSupportedFields: Set<CoreSetHomeObservationField> = []
    var performanceSnapshot: CoreSetPerformanceSnapshot?
    private(set) var infrastructure: [CoreSetCapability: CoreSetAvailability] = [:]
    func infrastructureAvailability(_ capability: CoreSetCapability) -> CoreSetAvailability {
        infrastructure[capability] ?? .unavailable(reason: "No infrastructure observation")
    }
    @discardableResult
    mutating func setInfrastructure(_ capability: CoreSetCapability, availability: CoreSetAvailability) -> Bool {
        guard capability.isInfrastructure else { return false }
        infrastructure[capability] = availability
        return true // Never promotes any game feature channel.
    }
    mutating func suspendAll() {
        home.suspend(); frameRate.suspend(); player.suspend(); materials.suspend(); adjustments.suspend()
        radar.suspend(); aim.suspend(); aimDisplay.suspend(); recoil.suspend()
    }
}
