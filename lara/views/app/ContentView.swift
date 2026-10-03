import Combine
import AVFoundation
import UIKit

enum CoreSetAuthorizationState: Equatable {
    case unverified
    case verifying
    case activated(expiryText: String)
    case expired(expiryText: String?)
    case failed(message: String)
    #if AX_LOCAL_TEST_AUTH_BYPASS
    case localTesting
    #endif

    static var initialForCurrentBuild: Self {
        applyingBuildPolicy(to: .unverified)
    }

    static func applyingBuildPolicy(to state: Self) -> Self {
        #if AX_LOCAL_TEST_AUTH_BYPASS
        precondition(ax_launcher_local_test_authorization_bypass_enabled())
        return .localTesting
        #else
        return state
        #endif
    }

    var showsActivationForm: Bool {
        switch self {
        case .activated:
            return false
        #if AX_LOCAL_TEST_AUTH_BYPASS
        case .localTesting:
            return false
        #endif
        default:
            return true
        }
    }

    var canLaunch: Bool {
        switch self {
        case .activated:
            return true
        #if AX_LOCAL_TEST_AUTH_BYPASS
        case .localTesting:
            return true
        #endif
        default:
            return false
        }
    }

    var isActivated: Bool { canLaunch }

    var normalizedExpiryText: String? {
        let raw: String?
        switch self {
        case let .activated(expiryText): raw = expiryText
        case let .expired(expiryText): raw = expiryText
        default: return nil
        }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    var statusText: String {
        switch self {
        case .unverified:
            return "未激活"
        case .verifying:
            return "正在验证卡密…"
        case .activated:
            guard let expiryText = normalizedExpiryText else { return "获取失败" }
            return "到期时间：\(expiryText)"
        case .expired:
            guard let expiryText = normalizedExpiryText else { return "授权已过期" }
            return "授权已过期：\(expiryText)"
        case let .failed(message):
            return message
        #if AX_LOCAL_TEST_AUTH_BYPASS
        case .localTesting:
            return "LOCAL TEST AUTH BYPASS · 已跳过卡密验证"
        #endif
        }
    }
}


private func coreColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
    UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Core-SET prototypes 134/148. Background clips independently of the shadow.
private final class CoreSetNeonButton: UIButton {
    let gradient = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.insertSublayer(gradient, at: 0)
        gradient.startPoint = .zero
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.masksToBounds = true
        clipsToBounds = false
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 5)
        titleLabel?.font = .boldSystemFont(ofSize: 15)
        titleLabel?.numberOfLines = 2
        titleLabel?.textAlignment = .center
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.72
        setTitleColor(.white, for: .normal)
        setTitleColor(.white, for: .disabled)
        addTarget(self, action: #selector(pressDown), for: .touchDown)
        addTarget(self, action: #selector(pressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        gradient.cornerRadius = bounds.height / 2
        layer.cornerRadius = bounds.height / 2
    }
    func colors(_ a: UIColor, _ b: UIColor, shadow: UIColor) {
        gradient.colors = [a.cgColor, b.cgColor]
        layer.shadowColor = shadow.cgColor
    }
    @objc private func pressDown() {
        UIView.animate(withDuration: 0.12) { self.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
    }
    @objc private func pressUp() {
        UIView.animate(withDuration: 0.28) { self.transform = .identity }
    }
}

@objc(CoreSetLauncherViewController)
final class CoreSetLauncherViewController: UIViewController, AVAudioPlayerDelegate {
    private let background = CAGradientLayer()
    private let particleEmitter = CAEmitterLayer()
    private let leftMist = CAGradientLayer()
    private let rightMist = CAGradientLayer()
    private let banner = UIImageView()
    private let expiryLabel = UIView()
    private let deviceGradient = CAGradientLayer()
    private let authorizationGradient = CAGradientLayer()
    private let deviceMask = CATextLayer()
    private let authorizationMask = CATextLayer()
    private let pillBackground = CAGradientLayer()
    private let pillBorder = CAGradientLayer()
    private let pillBorderMask = CAShapeLayer()
    private let pillIndicator = CAGradientLayer()
    private let pillIndicatorMask = CAShapeLayer()
    private var authorizationValue = "未激活"
    private let assistCard = UIView()
    private let rhythmView = UIView()
    private let rhythmSurface = CAGradientLayer()
    private let rhythmBaseline = CAShapeLayer()
    private var rhythmBars: [CAGradientLayer] = []
    private let cardGradient = CAGradientLayer()
    private let cardInner = UIView()
    private let cardInnerGradient = CAGradientLayer()
    private let cardTitleGradient = CAGradientLayer()
    private let cardTitleMask = CATextLayer()
    private let cardIcon = UIImageView(image: UIImage(systemName: "list.number"))
    private let cardClose = UIButton(type: .custom)
    private let hudButton = CoreSetNeonButton(frame: .zero)
    private let breathingRing = UIView()
    private var ringActive = false
    private let energyBackdrop = CAGradientLayer()
    private let energyCore = CAGradientLayer()
    private let energyWave = CAShapeLayer()
    private let energyPrimary = CAShapeLayer()
    private let energySecondary = CAShapeLayer()
    private var energyActive: Bool?
    private let musicButton = UIButton(type: .custom)
    private let musicGradient = CAGradientLayer()
    private let musicDisc = UIView()
    private let musicIcon = UIImageView(image: UIImage(systemName: "music.note"))
    private var homeMusicPlayer: AVAudioPlayer?
    private var homeMusicObservers: [NSObjectProtocol] = []
    private var homeMusicStarted = false
    private var homeMusicUserPaused = false
    private var homeMusicInterrupted = false
    private let tutorialButton = UIButton(type: .custom)
    private let tutorialLabel = UILabel()
    private let tutorialIcon = UIView()
    private let tutorialBookGradient = CAGradientLayer()
    private let tutorialBookMask = CALayer()
    private let tutorialPageGradient = CAGradientLayer()
    private let tutorialPageMask = CAShapeLayer()
    private var tutorialFlipAnimation: CAAnimationGroup?
    private let loadingView = UIView()
    private let loadingLogo = UIImageView(image: UIImage(named: "CoreSetLoading"))
    private let loadingTitle = UILabel()
    private let loadingSubtitle = UILabel()
    private let loadingDots = UILabel()
    private var loadingDotsTimer: Timer?
    private var sideButtons: [CoreSetNeonButton] = []
    private var sideHitTargets: [UIButton] = []
    private var connectorLayers: [CAShapeLayer] = []
    private var assistRows: [UIView] = []
    private var authorizationState: CoreSetAuthorizationState
    private var presentationObservers: [AnyCancellable] = []
    private var menuRequestedVisible = false
    private var pendingNotices: [String] = []
    weak var coreSetRuntime: CoreSetRuntimeCoordinator?
    private let runtimeStatusLabel = UILabel()
    private var runtimeStatus = "本应用悬浮未就绪 · 跨应用 unavailable"
    init(authorizationState: CoreSetAuthorizationState) {
        self.authorizationState = .applyingBuildPolicy(to: authorizationState)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var shouldAutorotate: Bool { false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }


    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        configureCoreHome()
        runtimeStatusLabel.text = runtimeStatus
        runtimeStatusLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        runtimeStatusLabel.font = .systemFont(ofSize: 9)
        runtimeStatusLabel.textAlignment = .center
        runtimeStatusLabel.adjustsFontSizeToFitWidth = true
        runtimeStatusLabel.minimumScaleFactor = 0.5
        view.addSubview(runtimeStatusLabel)
        observeHomeMusic()
        updatePresentation()
        configureLoadingPresentation()
        presentationObservers = [UIApplication.didBecomeActiveNotification,
                                 UIApplication.willResignActiveNotification,
                                 UIAccessibility.reduceMotionStatusDidChangeNotification].map { name in
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateParticlePresentation()
                    self?.updatePresentation()
                    self?.updateTutorialMotion()
                    self?.presentPendingNotices()
                }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reconcileHomeMusic()
        presentPendingNotices()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // UIKit may detach the home during full-screen presentation. Unlike
        // the original overlay, attachment is consumed through view.window.
        reconcileHomeMusic()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        runtimeStatusLabel.frame = CGRect(x: 12, y: view.bounds.height - max(view.safeAreaInsets.bottom, 16),
                                          width: max(0, view.bounds.width - 24), height: 14)
        // v1.7 prototype 148 matches the recovered v1.6 geometry prototype 133.
        let layout = CoreSetHomeLayout(bounds: view.bounds, safeArea: view.safeAreaInsets,
                                       cardHeight: 185)
        background.frame = view.bounds
        particleEmitter.frame = view.bounds
        particleEmitter.emitterPosition = CGPoint(x: view.bounds.midX, y: view.bounds.midY + 35)
        particleEmitter.emitterSize = CGSize(width: view.bounds.width * 0.92, height: view.bounds.height * 0.72)
        leftMist.frame = CGRect(x: -90, y: view.bounds.height - 310, width: 300, height: 300)
        rightMist.frame = CGRect(x: view.bounds.width - 205, y: view.bounds.height - 390, width: 285, height: 285)
        updateParticlePresentation()
        banner.frame = layout.banner
        expiryLabel.frame = layout.expiry
        layoutAuthorizationPill()
        assistCard.frame = layout.card
        rhythmView.frame = layout.card
        layoutRhythm()
        cardGradient.frame = assistCard.bounds
        cardInner.frame = assistCard.bounds.insetBy(dx: 1.2, dy: 1.2)
        cardInnerGradient.frame = cardInner.bounds
        cardIcon.frame = CGRect(x: 11, y: 12, width: 18, height: 18)
        cardTitleGradient.frame = CGRect(x: 36, y: 11, width: 150, height: 20)
        cardTitleMask.frame = cardTitleGradient.bounds
        cardClose.frame = CGRect(x: layout.card.width - 68, y: 12, width: 57, height: 20)
        for (index, button) in sideButtons.enumerated() {
            button.frame = layout.sideButtons[index]
            button.titleLabel?.font = .boldSystemFont(ofSize: layout.isPad ? 16 : layout.isCompact ? 13.5 : 15)
            sideHitTargets[index].frame = layout.sideHitTargets[index]
        }
        hudButton.frame = layout.hud
        layoutEnergy()
        breathingRing.bounds = CGRect(x: 0, y: 0, width: layout.hud.width + 10, height: layout.hud.height + 10)
        breathingRing.center = CGPoint(x: layout.hud.midX, y: layout.hud.midY)
        breathingRing.layer.cornerRadius = breathingRing.bounds.height / 2
        hudButton.titleLabel?.font = .boldSystemFont(ofSize: layout.isPad ? 17 : 15)
        musicButton.frame = layout.music
        musicDisc.frame = musicButton.bounds.insetBy(dx: 3, dy: 3)
        musicGradient.frame = musicDisc.bounds
        musicGradient.cornerRadius = musicGradient.bounds.height / 2
        musicDisc.layer.cornerRadius = musicDisc.bounds.height / 2
        musicIcon.frame = CGRect(x: 12, y: 12, width: layout.music.width - 24, height: layout.music.height - 24)
        tutorialButton.frame = layout.tutorial
        tutorialLabel.frame = CGRect(x: 0, y: 35, width: layout.tutorial.width, height: 18)
        tutorialIcon.frame = CGRect(x: (layout.tutorial.width - 34) / 2, y: 0, width: 34, height: 32)
        tutorialBookGradient.frame = tutorialIcon.bounds
        tutorialBookMask.frame = tutorialBookGradient.bounds
        let symbol = UIImage(systemName: "book.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 29, weight: UIImage.SymbolWeight(rawValue: 5) ?? .regular))?.withTintColor(.black, renderingMode: .alwaysOriginal)
        if let symbol {
            let scale = min(34 / symbol.size.width, 32 / symbol.size.height)
            let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            tutorialBookMask.contents = UIGraphicsImageRenderer(size: CGSize(width: 34, height: 32)).image { _ in
                symbol.draw(in: CGRect(x: (34 - size.width) / 2, y: (32 - size.height) / 2, width: size.width, height: size.height))
            }.cgImage
        }
        tutorialPageGradient.bounds = CGRect(x: 0, y: 0, width: 14, height: 21)
        tutorialPageGradient.position = CGPoint(x: tutorialIcon.bounds.midX, y: tutorialIcon.bounds.midY + 0.5)
        tutorialPageMask.frame = tutorialPageGradient.bounds
        for (index, layer) in connectorLayers.enumerated() {
            let path = UIBezierPath()
            let points = layout.connectors[index]
            path.move(to: points[0])
            path.addLine(to: points[1])
            path.addLine(to: points[2])
            layer.path = path.cgPath
        }
        for (index, row) in assistRows.enumerated() {
            row.frame = CGRect(x: 6, y: CGFloat(38 + index * 35), width: layout.card.width - 12, height: 31)
            row.viewWithTag(1)?.frame = CGRect(x: 39, y: 1, width: layout.card.width - 56, height: 14)
            row.viewWithTag(2)?.frame = CGRect(x: 39, y: 15, width: layout.card.width - 56, height: 15)
        }
        loadingView.frame = view.bounds
        loadingLogo.frame = CGRect(x: (view.bounds.width - 72) / 2, y: (view.bounds.height - 72) / 2 - 90, width: 72, height: 72)
        loadingTitle.frame = CGRect(x: (view.bounds.width - 220) / 2, y: (view.bounds.height - 30) / 2 + 2, width: 220, height: 30)
        loadingSubtitle.frame = CGRect(x: (view.bounds.width - 260) / 2, y: (view.bounds.height - 22) / 2 + 34, width: 260, height: 22)
        loadingDots.frame = CGRect(x: (view.bounds.width - 120) / 2, y: (view.bounds.height - 24) / 2 + 58, width: 120, height: 24)
    }

    func updateAuthorizationState(_ state: CoreSetAuthorizationState) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateAuthorizationState(state)
            }
            return
        }
        authorizationState = .applyingBuildPolicy(to: state)
        if isViewLoaded {
            updatePresentation()
        }
    }

    private func configureCoreHome() {
        view.backgroundColor = coreColor(11, 16, 32)
        background.colors = [coreColor(20, 27, 51).cgColor, coreColor(8, 11, 22).cgColor]
        background.startPoint = CGPoint(x: 0.5, y: 0)
        background.endPoint = CGPoint(x: 0.5, y: 1)
        view.layer.insertSublayer(background, at: 0)
        configureParticles()
        // Xcode's synchronized group copies these resources into the bundle.
        let bannerURL = Bundle.main.url(forResource: "hf", withExtension: "png")
            ?? Bundle.main.url(forResource: "hf", withExtension: "png", subdirectory: "CoreSetAssets")
        if let bannerURL { banner.image = UIImage(contentsOfFile: bannerURL.path) }
        banner.contentMode = .scaleAspectFit
        banner.layer.cornerRadius = 16
        banner.clipsToBounds = true
        view.addSubview(banner)
        let pillColors = [coreColor(236,72,153).cgColor, coreColor(139,92,246).cgColor, coreColor(34,211,238).cgColor]
        pillBackground.colors = [coreColor(20,25,51,0.96).cgColor, coreColor(29,19,56,0.94).cgColor]
        pillBackground.startPoint = CGPoint(x: 0, y: 0.5)
        pillBackground.endPoint = CGPoint(x: 1, y: 0.5)
        pillBackground.cornerRadius = 12
        expiryLabel.layer.addSublayer(pillBackground)
        pillBorder.colors = pillColors
        pillBorder.startPoint = .zero
        pillBorder.endPoint = CGPoint(x: 1, y: 1)
        pillBorderMask.fillColor = UIColor.clear.cgColor
        pillBorderMask.strokeColor = UIColor.white.cgColor
        pillBorderMask.lineWidth = 1.5
        pillBorder.mask = pillBorderMask
        expiryLabel.layer.addSublayer(pillBorder)
        expiryLabel.layer.shadowColor = coreColor(139,92,246).cgColor
        expiryLabel.layer.shadowOpacity = 0.24
        expiryLabel.layer.shadowRadius = 9
        expiryLabel.layer.shadowOffset = CGSize(width: 0, height: 4)
        pillIndicator.colors = pillColors
        pillIndicator.type = .conic
        pillIndicator.startPoint = CGPoint(x: 0.5, y: 0.5)
        pillIndicator.endPoint = CGPoint(x: 0.5, y: 0)
        pillIndicatorMask.strokeColor = UIColor.white.cgColor
        pillIndicator.mask = pillIndicatorMask
        expiryLabel.layer.addSublayer(pillIndicator)
        for (gradient, mask) in [(deviceGradient, deviceMask), (authorizationGradient, authorizationMask)] {
            gradient.colors = [coreColor(236,72,153).cgColor, coreColor(139,92,246).cgColor, coreColor(34,211,238).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.mask = mask
            mask.truncationMode = .end
            mask.contentsScale = UIScreen.main.scale
            expiryLabel.layer.addSublayer(gradient)
        }
        deviceMask.alignmentMode = .left
        authorizationMask.alignmentMode = .right
        view.addSubview(expiryLabel)

        let titles = ["查看公告", "提交工单", "工单进度", "启动游戏", "检查更新", "激活续时"]
        let palettes: [[CGFloat]] = [
            [139,92,246,109,40,217,124,58,237],
            [59,130,246,29,78,216,37,99,235],
            [251,146,60,234,88,12,249,115,22],
            [244,114,182,219,39,119,236,72,153],
            [56,189,248,14,116,184,14,165,233],
            [250,204,21,217,119,6,245,158,11],
        ]
        for (index, title) in titles.enumerated() {
            let button = CoreSetNeonButton(frame: .zero)
            let c = palettes[index]
            button.colors(coreColor(c[0],c[1],c[2]), coreColor(c[3],c[4],c[5]),
                          shadow: coreColor(c[6],c[7],c[8]))
            button.setTitle(title, for: .normal)
            button.tag = index
            if index == 3 {
                button.addTarget(self, action: #selector(launchApplication), for: .touchUpInside)
            } else {
                button.addTarget(self, action: #selector(homeServiceUnavailable(_:)), for: .touchUpInside)
            }
            sideButtons.append(button)
            view.addSubview(button)
            let hit = UIButton(type: .custom)
            hit.backgroundColor = .clear
            hit.tag = index
            hit.isAccessibilityElement = false
            hit.addTarget(self, action: index == 3 ? #selector(launchApplication) : #selector(homeServiceUnavailable(_:)), for: .touchUpInside)
            sideHitTargets.append(hit)
            view.addSubview(hit)
            view.bringSubviewToFront(button)
            let connector = CAShapeLayer()
            connector.fillColor = UIColor.clear.cgColor
            connector.strokeColor = coreColor(c[0],c[1],c[2]).cgColor
            connector.lineWidth = 2.2
            connector.lineCap = .round
            connector.lineJoin = .round
            let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
            draw.values = [0, 1, 1]
            draw.keyTimes = [0, 0.375, 1]
            draw.duration = 3.2
            draw.repeatCount = .greatestFiniteMagnitude
            draw.calculationMode = .linear
            connector.add(draw, forKey: "homeConnectorDraw")
            connectorLayers.append(connector)
            view.layer.addSublayer(connector)
        }
        hudButton.addTarget(self, action: #selector(toggleMenu), for: .touchUpInside)
        breathingRing.isUserInteractionEnabled = false
        breathingRing.backgroundColor = coreColor(34,197,94,0.1)
        breathingRing.layer.borderWidth = 2
        breathingRing.layer.borderColor = coreColor(74,222,128,0.75).cgColor
        breathingRing.layer.shadowColor = coreColor(34,197,94).cgColor
        breathingRing.layer.shadowOpacity = 0.85
        breathingRing.layer.shadowRadius = 18
        breathingRing.layer.shadowOffset = .zero
        view.addSubview(breathingRing)
        view.addSubview(hudButton)
        energyBackdrop.type = .radial
        energyBackdrop.startPoint = CGPoint(x: 0.5, y: 0.45)
        energyBackdrop.endPoint = CGPoint(x: 1, y: 1)
        energyBackdrop.opacity = 0.94
        energyCore.type = .radial
        energyCore.startPoint = CGPoint(x: 0.5, y: 0.5)
        energyCore.endPoint = CGPoint(x: 1, y: 1)
        for layer in [energyWave, energyPrimary, energySecondary] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            layer.shadowOffset = .zero
        }
        energyWave.lineWidth = 2.2
        energyWave.opacity = 0
        energyWave.shadowOpacity = 0.68
        energyWave.shadowRadius = 5
        energyPrimary.lineWidth = 3.2
        energyPrimary.shadowOpacity = 0.92
        energyPrimary.shadowRadius = 5.5
        energySecondary.lineWidth = 2.5
        energySecondary.shadowOpacity = 0.78
        energySecondary.shadowRadius = 4
        energyCore.shadowOpacity = 0.72
        energyCore.shadowOffset = .zero
        for layer in [energyBackdrop, energyWave, energyPrimary, energySecondary, energyCore] as [CALayer] {
            hudButton.layer.insertSublayer(layer, below: hudButton.titleLabel?.layer)
        }
        musicButton.addTarget(self, action: #selector(toggleHomeMusic), for: .touchUpInside)
        musicButton.accessibilityLabel = "背景音乐"
        musicDisc.isUserInteractionEnabled = false
        musicDisc.backgroundColor = coreColor(24,18,48,0.94)
        musicDisc.layer.borderWidth = 1.5
        musicDisc.layer.borderColor = coreColor(192,132,252,0.95).cgColor
        musicDisc.layer.shadowColor = coreColor(168,85,247).cgColor
        musicDisc.layer.shadowOpacity = 0.8
        musicDisc.layer.shadowRadius = 9
        musicDisc.layer.shadowOffset = .zero
        musicGradient.colors = [coreColor(236,72,153,0.72).cgColor,
                                coreColor(99,102,241,0.72).cgColor,
                                coreColor(34,211,238,0.62).cgColor]
        musicGradient.startPoint = .zero
        musicGradient.endPoint = CGPoint(x: 1, y: 1)
        musicDisc.layer.insertSublayer(musicGradient, at: 0)
        musicButton.insertSubview(musicDisc, at: 0)
        musicIcon.tag = 47017
        musicIcon.tintColor = coreColor(240,232,255)
        musicIcon.contentMode = .scaleAspectFit
        musicIcon.isUserInteractionEnabled = false
        musicButton.addSubview(musicIcon)
        view.addSubview(musicButton)
        tutorialLabel.text = "教程"
        tutorialLabel.textColor = coreColor(216,180,254)
        tutorialLabel.font = .boldSystemFont(ofSize: 13)
        tutorialLabel.textAlignment = .center
        tutorialButton.addSubview(tutorialLabel)
        let tutorialColors = [coreColor(236,72,153).cgColor, coreColor(99,102,241).cgColor, coreColor(34,211,238).cgColor]
        tutorialBookGradient.colors = tutorialColors
        tutorialBookGradient.startPoint = CGPoint(x: 0, y: 0.15)
        tutorialBookGradient.endPoint = CGPoint(x: 1, y: 0.85)
        tutorialBookGradient.mask = tutorialBookMask
        tutorialBookGradient.shadowColor = coreColor(168,85,247).cgColor
        tutorialBookGradient.shadowOpacity = 0.58
        tutorialBookGradient.shadowRadius = 6
        tutorialBookGradient.shadowOffset = .zero
        tutorialIcon.isUserInteractionEnabled = false
        tutorialIcon.layer.addSublayer(tutorialBookGradient)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 180
        tutorialIcon.layer.sublayerTransform = perspective
        tutorialButton.addSubview(tutorialIcon)
        tutorialPageGradient.colors = [coreColor(250,207,250).cgColor, coreColor(129,140,248).cgColor, coreColor(103,232,249).cgColor]
        tutorialPageGradient.startPoint = .zero
        tutorialPageGradient.endPoint = CGPoint(x: 1, y: 1)
        tutorialPageGradient.anchorPoint = CGPoint(x: 0, y: 0.5)
        tutorialPageGradient.mask = tutorialPageMask
        let pagePath = UIBezierPath()
        pagePath.move(to: CGPoint(x: 0, y: 1))
        pagePath.addQuadCurve(to: CGPoint(x: 13.5, y: 3), controlPoint: CGPoint(x: 7.5, y: 0))
        pagePath.addLine(to: CGPoint(x: 13.5, y: 19))
        pagePath.addQuadCurve(to: CGPoint(x: 0, y: 20), controlPoint: CGPoint(x: 7, y: 17.5))
        pagePath.close()
        tutorialPageMask.path = pagePath.cgPath
        tutorialPageMask.fillColor = UIColor.white.cgColor
        tutorialPageGradient.shadowColor = UIColor.white.cgColor
        tutorialPageGradient.shadowOpacity = 0.42
        tutorialPageGradient.shadowRadius = 2
        tutorialPageGradient.shadowOffset = .zero
        tutorialIcon.layer.addSublayer(tutorialPageGradient)
        let flip = CAKeyframeAnimation(keyPath: "transform.rotation.y")
        flip.values = [0, -Double.pi / 2, -3.061592653589793]
        flip.keyTimes = [0, 0.48, 0.88]
        flip.calculationMode = .cubic
        flip.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        flip.duration = 1.45
        let pageOpacity = CAKeyframeAnimation(keyPath: "opacity")
        pageOpacity.values = [1, 1, 0, 0]
        pageOpacity.keyTimes = [0, 0.76, 0.9, 1]
        pageOpacity.duration = 1.45
        let pageAnimation = CAAnimationGroup()
        pageAnimation.animations = [flip, pageOpacity]
        pageAnimation.duration = 1.45
        pageAnimation.repeatCount = .infinity
        tutorialFlipAnimation = pageAnimation
        tutorialButton.addTarget(self, action: #selector(showTutorial), for: .touchUpInside)
        view.addSubview(tutorialButton)
        configureAssistCard()
        rhythmView.isUserInteractionEnabled = false
        rhythmSurface.colors = [coreColor(30,22,61,0.72).cgColor, coreColor(13,25,48,0.82).cgColor]
        rhythmSurface.startPoint = CGPoint(x: 0, y: 0.5)
        rhythmSurface.endPoint = CGPoint(x: 1, y: 0.5)
        rhythmSurface.borderWidth = 1
        rhythmSurface.borderColor = coreColor(139,92,246,0.26).cgColor
        rhythmSurface.shadowColor = coreColor(99,102,241).cgColor
        rhythmSurface.shadowOpacity = 0.22
        rhythmSurface.shadowRadius = 12
        rhythmSurface.shadowOffset = .zero
        rhythmView.layer.addSublayer(rhythmSurface)
        rhythmBaseline.strokeColor = coreColor(129,140,248,0.28).cgColor
        rhythmBaseline.lineWidth = 1
        rhythmBaseline.fillColor = UIColor.clear.cgColor
        rhythmView.layer.addSublayer(rhythmBaseline)
        // A fresh original controller starts with tutorialOpened == false.
        // Preserve later toggles across layout updates.
        assistCard.isHidden = true
        rhythmView.isHidden = false
        view.insertSubview(rhythmView, belowSubview: assistCard)
        updateTutorialMotion()
    }

    private func layoutRhythm() {
        let width = rhythmView.bounds.width
        let height = min(76, max(58, rhythmView.bounds.height * 0.44))
        rhythmSurface.frame = CGRect(x: 7, y: rhythmView.bounds.midY - height / 2, width: width - 14, height: height)
        rhythmSurface.cornerRadius = height / 2
        let count = width >= 500 ? 64 : 42
        if rhythmBars.count != count {
            rhythmBars.forEach { $0.removeFromSuperlayer() }
            rhythmBars = (0..<count).map { index in
                let bar = CAGradientLayer()
                let ratio = CGFloat(index) / CGFloat(count - 1)
                bar.colors = ratio < 0.34
                    ? [coreColor(244,114,182).cgColor, coreColor(168,85,247,0.88).cgColor]
                    : ratio < 0.68
                        ? [coreColor(192,132,252).cgColor, coreColor(99,102,241,0.88).cgColor]
                        : [coreColor(103,232,249).cgColor, coreColor(59,130,246,0.88).cgColor]
                bar.anchorPoint = CGPoint(x: 0.5, y: 1)
                bar.setAffineTransform(CGAffineTransform(scaleX: 1, y: 0.18 + 0.035 * CGFloat(index % 5)))
                rhythmView.layer.addSublayer(bar)
                return bar
            }
        }
        let barWidth = min(6, max(3, ((rhythmSurface.bounds.width - 36) - 2.1 * CGFloat(count - 1)) / CGFloat(count)))
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * 2.1
        let firstX = (width - totalWidth) / 2
        let baselineY = rhythmSurface.frame.midY + (height - 22) / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: firstX - 4, y: baselineY + 1.5))
        path.addLine(to: CGPoint(x: firstX + totalWidth + 4, y: baselineY + 1.5))
        rhythmBaseline.frame = rhythmView.bounds
        rhythmBaseline.path = path.cgPath
        for (index, bar) in rhythmBars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: height - 22)
            bar.position = CGPoint(x: (width - totalWidth) / 2 + barWidth / 2 + CGFloat(index) * (barWidth + 2.1), y: rhythmSurface.frame.midY + (height - 22) / 2)
            bar.cornerRadius = barWidth / 2
        }
        updateRhythmPresentation()
    }

    private func updateRhythmPresentation() {
        let animate = homeMusicPlayer?.isPlaying == true && assistCard.isHidden && !rhythmView.isHidden
            && UIApplication.shared.applicationState == .active && !UIAccessibility.isReduceMotionEnabled
        let groups: [[NSNumber]] = [
            [0.18,0.72,0.34,0.92,0.26,0.64,0.18],
            [0.24,0.48,0.88,0.38,0.76,0.3,0.24],
            [0.16,0.62,0.28,0.82,0.44,0.96,0.16],
            [0.3,0.84,0.42,0.58,0.94,0.36,0.3]
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in rhythmBars.enumerated() {
            if !animate {
                bar.removeAnimation(forKey: "q47.rhythm.pulse")
                bar.setAffineTransform(CGAffineTransform(scaleX: 1, y: 0.15 + 0.035 * CGFloat(index % 5)))
            } else if bar.animation(forKey: "q47.rhythm.pulse") == nil {
                // The reference uses preset keyframes rather than audio FFT.
                let pulse = CAKeyframeAnimation(keyPath: "transform.scale.y")
                pulse.values = groups[index % 4]
                pulse.duration = 0.74 + 0.055 * Double(index % 6)
                pulse.beginTime = CACurrentMediaTime() + 0.016 * Double(index)
                pulse.calculationMode = .cubic
                pulse.repeatCount = .infinity
                bar.add(pulse, forKey: "q47.rhythm.pulse")
            }
        }
        CATransaction.commit()
    }

    private func configureParticles() {
        for mist in [leftMist, rightMist] {
            mist.type = .radial
            mist.startPoint = CGPoint(x: 0.5, y: 0.5)
            mist.endPoint = CGPoint(x: 1, y: 1)
            view.layer.addSublayer(mist)
        }
        leftMist.colors = [coreColor(168,85,247,0.14).cgColor, coreColor(99,102,241,0.055).cgColor, UIColor.clear.cgColor]
        rightMist.colors = [coreColor(34,211,238,0.11).cgColor, coreColor(59,130,246,0.045).cgColor, UIColor.clear.cgColor]
        let dot = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 6)).image { context in
            context.cgContext.setShadow(offset: .zero, blur: 6 * 0.24, color: UIColor.white.withAlphaComponent(0.42).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0.72, y: 0.72, width: 4.56, height: 4.56)).fill()
        }.cgImage
        let palettes = [coreColor(244,114,182,0.345), coreColor(167,139,250,0.368), coreColor(103,232,249,0.3105)]
        let scales: [CGFloat] = [0.28, 0.34, 0.25]
        let rates: [Float] = [1.23, 1.38, 1.08]
        particleEmitter.emitterCells = palettes.indices.map { index in
            let cell = CAEmitterCell()
            cell.contents = dot
            cell.color = palettes[index].cgColor
            cell.scale = scales[index]
            cell.scaleRange = scales[index] * 0.55
            cell.birthRate = rates[index]
            cell.lifetime = 15
            cell.lifetimeRange = 5
            cell.velocity = 13
            cell.velocityRange = 7
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = 0.42
            cell.alphaRange = 0.12
            cell.alphaSpeed = -0.014
            cell.spinRange = 0.3
            return cell
        }
        particleEmitter.emitterShape = .rectangle
        particleEmitter.emitterMode = .volume
        particleEmitter.renderMode = .additive
        particleEmitter.preservesDepth = false
        view.layer.addSublayer(particleEmitter)
    }

    private func configureLoadingPresentation() {
        loadingView.backgroundColor = .white
        loadingLogo.contentMode = .scaleAspectFit
        loadingTitle.text = "Core引擎启动中"
        loadingTitle.font = .boldSystemFont(ofSize: 24)
        loadingTitle.textColor = .darkGray
        loadingSubtitle.text = "Preparing Load Core Graphics"
        loadingSubtitle.font = .systemFont(ofSize: 14)
        loadingSubtitle.textColor = .gray
        loadingDots.text = "·"
        loadingDots.font = .systemFont(ofSize: 22)
        loadingDots.textColor = .lightGray
        [loadingTitle, loadingSubtitle, loadingDots].forEach { $0.textAlignment = .center }
        [loadingLogo, loadingTitle, loadingSubtitle, loadingDots].forEach(loadingView.addSubview)
        view.addSubview(loadingView)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.5
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        loadingLogo.layer.add(pulse, forKey: "core.loading.pulse")
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        loadingLogo.layer.add(spin, forKey: "core.loading.spin")
        var dots = 1
        loadingDotsTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            dots = dots % 3 + 1
            self?.loadingDots.text = String(repeating: "·", count: dots)
        }
        // Presentation timing is never used as backend or authorization readiness.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self else { return }
            self.banner.alpha = 0
            self.banner.transform = CGAffineTransform(translationX: 0, y: -14)
            self.expiryLabel.alpha = 0
            self.expiryLabel.transform = CGAffineTransform(translationX: 0, y: -8)
            // Original prototype 137 homeActionButtons order, including the
            // visually inactive music control and stopped rhythm surface.
            let actions: [UIView] = [self.sideButtons[0], self.musicButton,
                self.sideButtons[1], self.sideButtons[2], self.hudButton,
                self.sideButtons[3], self.sideButtons[4], self.sideButtons[5],
                self.tutorialButton, self.rhythmView]
            for action in actions {
                action.alpha = 0
                action.transform = CGAffineTransform(translationX: 0, y: 18)
            }
            UIView.animate(withDuration: 0.25, animations: {
                self.loadingView.alpha = 0
            }, completion: { [weak self] _ in
                guard let self else { return }
                self.loadingDotsTimer?.invalidate()
                self.loadingDotsTimer = nil
                self.loadingLogo.layer.removeAllAnimations()
                self.loadingView.removeFromSuperview()
                UIView.animate(withDuration: 0.5) {
                    self.banner.alpha = 1
                    self.banner.transform = .identity
                }
                UIView.animate(withDuration: 0.4, delay: 0.05, options: [], animations: {
                    self.expiryLabel.alpha = 1
                    self.expiryLabel.transform = .identity
                })
                for (index, action) in actions.enumerated() {
                    UIView.animate(withDuration: 0.34, delay: 0.03 + 0.035 * Double(index), options: [], animations: {
                        action.alpha = 1
                        action.transform = .identity
                    })
                }
            })
        }
    }

    deinit {
        loadingDotsTimer?.invalidate()
        homeMusicPlayer?.stop()
        homeMusicObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func configureAssistCard() {
        assistCard.layer.cornerRadius = 18
        assistCard.layer.shadowColor = coreColor(88,70,180).cgColor
        assistCard.layer.shadowOpacity = 0.2
        assistCard.layer.shadowRadius = 10
        assistCard.layer.shadowOffset = CGSize(width: 0, height: 5)
        cardGradient.colors = [coreColor(236,72,153,0.82).cgColor,
                               coreColor(139,92,246,0.9).cgColor,
                               coreColor(34,211,238,0.78).cgColor]
        cardGradient.startPoint = .zero
        cardGradient.endPoint = CGPoint(x: 1, y: 1)
        cardGradient.cornerRadius = 18
        assistCard.layer.addSublayer(cardGradient)
        cardInner.backgroundColor = coreColor(18,23,48,0.96)
        cardInner.layer.cornerRadius = 16.8
        cardInner.clipsToBounds = true
        cardInnerGradient.colors = [coreColor(30,24,62,0.78).cgColor,
                                    coreColor(15,28,54,0.9).cgColor,
                                    coreColor(12,20,40,0.96).cgColor]
        cardInnerGradient.startPoint = .zero
        cardInnerGradient.endPoint = CGPoint(x: 1, y: 1)
        cardInner.layer.addSublayer(cardInnerGradient)
        assistCard.addSubview(cardInner)
        cardIcon.contentMode = .scaleAspectFit
        cardIcon.tintColor = coreColor(236,72,153)
        assistCard.addSubview(cardIcon)
        cardTitleGradient.colors = [coreColor(236,72,153).cgColor, coreColor(99,102,241).cgColor, coreColor(34,211,238).cgColor]
        cardTitleGradient.startPoint = CGPoint(x: 0, y: 0.5)
        cardTitleGradient.endPoint = CGPoint(x: 1, y: 0.5)
        cardTitleMask.contentsScale = UIScreen.main.scale
        cardTitleMask.alignmentMode = .left
        cardTitleMask.truncationMode = .end
        cardTitleMask.string = NSAttributedString(string: "快速使用指南", attributes: [.font: UIFont.boldSystemFont(ofSize: 14.5), .foregroundColor: UIColor.white])
        cardTitleGradient.mask = cardTitleMask
        assistCard.layer.addSublayer(cardTitleGradient)
        cardClose.setTitle("关闭", for: .normal)
        cardClose.titleLabel?.font = .boldSystemFont(ofSize: 10.5)
        cardClose.layer.cornerRadius = 10
        cardClose.clipsToBounds = true
        cardClose.backgroundColor = coreColor(88,28,55,0.86)
        cardClose.setTitleColor(coreColor(254,205,211), for: .normal)
        cardClose.layer.borderWidth = 1
        cardClose.layer.borderColor = coreColor(244,114,182,0.72).cgColor
        cardClose.addTarget(self, action: #selector(hideTutorial), for: .touchUpInside)
        assistCard.addSubview(cardClose)
        let rows = [
            ("准备环境", "打开菜单，等待环境就绪后点击“内核利用”"),
            ("启动游戏", "初始化成功后启动和平精英，再点击“获取信息”"),
            ("开始使用", "信息获取成功后即可开启功能进入对局"),
            ("问题反馈", "出现异常时可通过“提交工单”进行反馈"),
        ]
        let rowColors = [coreColor(139,92,246), coreColor(244,114,182),
                         coreColor(34,211,238), coreColor(251,146,60)]
        let rowEnds = [coreColor(99,102,241), coreColor(219,39,119),
                       coreColor(59,130,246), coreColor(244,114,182)]
        for (index, content) in rows.enumerated() {
            let row = UIView()
            row.backgroundColor = UIColor.white.withAlphaComponent(0.025)
            row.layer.cornerRadius = 10
            let number = UILabel(frame: CGRect(x: 5, y: 4, width: 23, height: 23))
            number.text = String(index + 1)
            number.textColor = .white
            number.font = .boldSystemFont(ofSize: 11.5)
            number.textAlignment = .center
            let circle = CAGradientLayer()
            circle.frame = number.frame
            circle.cornerRadius = 11.5
            circle.colors = [rowColors[index].cgColor, rowEnds[index].cgColor]
            circle.startPoint = .zero
            circle.endPoint = CGPoint(x: 1, y: 1)
            row.layer.addSublayer(circle)
            row.addSubview(number)
            let title = UILabel()
            title.tag = 1
            title.text = content.0
            title.textColor = rowColors[index]
            title.font = .boldSystemFont(ofSize: 12)
            row.addSubview(title)
            let detail = UILabel()
            detail.tag = 2
            detail.text = content.1
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = coreColor(205,215,238)
            detail.adjustsFontSizeToFitWidth = true
            detail.minimumScaleFactor = 0.82
            row.addSubview(detail)
            assistCard.addSubview(row)
            assistRows.append(row)
        }
        view.addSubview(assistCard)
    }

    private func updatePresentation() {
        guard isViewLoaded else { return }
        updateHomeMusicPresentation()
        hudButton.isEnabled = true
        hudButton.setTitle(menuRequestedVisible ? "关闭菜单" : "打开菜单", for: .normal)
        hudButton.colors(menuRequestedVisible ? coreColor(255,92,110) : coreColor(74,222,128),
                         menuRequestedVisible ? coreColor(220,38,74) : coreColor(22,163,74),
                         shadow: menuRequestedVisible ? coreColor(244,63,94) : coreColor(34,197,94))
        updateEnergy(active: menuRequestedVisible)
        if menuRequestedVisible || UIApplication.shared.applicationState != .active || UIAccessibility.isReduceMotionEnabled {
            breathingRing.layer.removeAllAnimations()
            breathingRing.isHidden = true
            ringActive = false
        } else if !ringActive {
            ringActive = true
            breathingRing.isHidden = false
            breathingRing.alpha = 0.22
            breathingRing.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            UIView.animate(withDuration: 1.35, delay: 0, options: UIView.AnimationOptions(rawValue: 30), animations: {
                self.breathingRing.alpha = 0.82
                self.breathingRing.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            })
        }
        switch authorizationState {
        case .activated:
            authorizationValue = authorizationState.normalizedExpiryText ?? "获取失败"
        case .expired:
            authorizationValue = authorizationState.normalizedExpiryText ?? "已过期"
        case .verifying: authorizationValue = "查询中…"
        case .failed: authorizationValue = "获取失败"
        case .unverified: authorizationValue = "未激活"
        #if AX_LOCAL_TEST_AUTH_BYPASS
        case .localTesting: authorizationValue = "本地测试"
        #endif
        }
        expiryLabel.accessibilityLabel = authorizationState.statusText
        expiryLabel.accessibilityValue = menuRequestedVisible ? "本地菜单已打开" : "本地菜单已关闭"
        layoutAuthorizationPill()
    }

    private func layoutEnergy() {
        let bounds = hudButton.bounds
        let size = min(bounds.width, bounds.height)
        func centered(_ fraction: CGFloat) -> CGRect {
            let diameter = size * fraction
            return CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        }
        energyBackdrop.frame = bounds.insetBy(dx: size * 0.06, dy: size * 0.06)
        energyBackdrop.cornerRadius = energyBackdrop.bounds.width / 2
        energyWave.frame = centered(0.7)
        energyWave.path = UIBezierPath(ovalIn: energyWave.bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath
        energyPrimary.frame = centered(0.78)
        energySecondary.frame = centered(0.62)
        for (layer, start, end) in [(energyPrimary, -1.0053096491487339, 1.5079644737231006), (energySecondary, 2.324778563656447, 4.775220833456485)] {
            layer.path = UIBezierPath(arcCenter: CGPoint(x: layer.bounds.midX, y: layer.bounds.midY), radius: max(0, layer.bounds.width / 2 - 2), startAngle: CGFloat(start), endAngle: CGFloat(end), clockwise: true).cgPath
        }
        energyCore.frame = centered(0.45)
        energyCore.cornerRadius = energyCore.bounds.width / 2
        energyCore.shadowRadius = size * 0.1
    }

    private func updateEnergy(active: Bool) {
        let changed = energyActive != active
        let wasConfigured = energyActive != nil
        energyActive = active
        let a = active ? coreColor(255,92,110) : coreColor(74,222,128)
        let b = active ? coreColor(190,24,72) : coreColor(22,163,74)
        CATransaction.begin()
        CATransaction.setAnimationDuration(changed && wasConfigured ? 0.34 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        energyBackdrop.colors = [a.withAlphaComponent(0.42).cgColor, b.withAlphaComponent(0.18).cgColor, UIColor.clear.cgColor]
        energyCore.colors = [UIColor.white.withAlphaComponent(0.22).cgColor, a.withAlphaComponent(0.9).cgColor, b.withAlphaComponent(0.2).cgColor]
        energyPrimary.strokeColor = a.cgColor
        energySecondary.strokeColor = a.withAlphaComponent(0.46).cgColor
        energyWave.strokeColor = a.withAlphaComponent(0.58).cgColor
        for layer in [energyCore, energyPrimary, energySecondary, energyWave] as [CALayer] { layer.shadowColor = a.cgColor }
        CATransaction.commit()
        guard UIApplication.shared.applicationState == .active, !UIAccessibility.isReduceMotionEnabled else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (layer, key) in [(energyCore as CALayer, "q47.hud.core"),
                                 (energyPrimary, "q47.hud.orbit"), (energySecondary, "q47.hud.orbit"),
                                 (energyWave, "q47.hud.wave")] {
                layer.removeAnimation(forKey: key)
                layer.transform = CATransform3DIdentity
            }
            energyWave.opacity = 0
            CATransaction.commit()
            return
        }
        guard changed || energyCore.animation(forKey: "q47.hud.core") == nil else { return }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = active ? [0.94,1.07,0.98,1.045,0.94] : [0.94,1.055,0.94]
        pulse.keyTimes = active ? [0,0.22,0.42,0.62,1] : [0,0.5,1]
        pulse.duration = active ? 1.22 : 1.72
        pulse.calculationMode = .cubic
        pulse.repeatCount = .infinity
        energyCore.add(pulse, forKey: "q47.hud.core")
        for (index, layer) in [energyPrimary, energySecondary].enumerated() {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            let current = layer.presentation() ?? layer
            let angle = atan2(Double(current.transform.m12), Double(current.transform.m11))
            spin.fromValue = angle
            let direction: Double = (active == (index == 0)) ? -1 : 1
            spin.toValue = angle + direction * Double.pi * 2
            spin.duration = index == 0 ? (active ? 4.8 : 6.2) : (active ? 7 : 8.4)
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            spin.repeatCount = .infinity
            layer.add(spin, forKey: "q47.hud.orbit")
        }
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.68,1,1.12]; scale.keyTimes = [0,0.58,1]
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0,0.42,0]; opacity.keyTimes = [0,0.26,1]
        let wave = CAAnimationGroup()
        wave.duration = active ? 1.55 : 2.25
        scale.duration = wave.duration; opacity.duration = wave.duration
        wave.animations = [scale, opacity]; wave.repeatCount = .infinity
        energyWave.add(wave, forKey: "q47.hud.wave")
    }

    private func layoutAuthorizationPill() {
        let width = expiryLabel.bounds.width
        guard width > 0 else { return }
        let middle = width / 2
        let widths = [max(40, middle - 25), max(40, width - (middle + 12) - 12)]
        let name = axDeviceSupportStatus().marketingName
        let texts = ["\(name.isEmpty ? "iPhone" : name) · iOS \(UIDevice.current.systemVersion)", "授权至：\(authorizationValue)"]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillBackground.frame = expiryLabel.bounds
        pillBorder.frame = expiryLabel.bounds
        pillBorderMask.frame = expiryLabel.bounds
        pillBorderMask.path = UIBezierPath(roundedRect: expiryLabel.bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 11.25).cgPath
        pillIndicator.frame = CGRect(x: middle - 4.5, y: expiryLabel.bounds.height / 2 - 4.5, width: 9, height: 9)
        pillIndicatorMask.frame = pillIndicator.bounds
        pillIndicatorMask.path = UIBezierPath(ovalIn: pillIndicator.bounds.insetBy(dx: 0.75, dy: 0.75)).cgPath
        let querying = authorizationValue.contains("查询中")
        pillIndicatorMask.fillColor = (querying ? UIColor.clear : UIColor.white).cgColor
        pillIndicatorMask.lineWidth = querying ? 2 : 0
        pillIndicatorMask.strokeStart = querying ? 0.1 : 0
        pillIndicatorMask.strokeEnd = querying ? 0.78 : 1
        pillIndicator.removeAnimation(forKey: "q47.authorization.spin")
        if querying && UIApplication.shared.applicationState == .active && !UIAccessibility.isReduceMotionEnabled {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = 0.9
            spin.repeatCount = .infinity
            pillIndicator.add(spin, forKey: "q47.authorization.spin")
        }
        for (index, pair) in [(deviceGradient, deviceMask), (authorizationGradient, authorizationMask)].enumerated() {
            var size: CGFloat = width >= 500 ? 12.5 : 11.25
            while size > 9 && (texts[index] as NSString).size(withAttributes: [.font: UIFont.boldSystemFont(ofSize: size)]).width > widths[index] {
                size -= 0.25
            }
            let font = UIFont.boldSystemFont(ofSize: size)
            pair.0.frame = CGRect(x: index == 0 ? 13 : middle + 12, y: (expiryLabel.bounds.height - font.lineHeight) / 2 - 1, width: widths[index], height: font.lineHeight + 2)
            pair.1.frame = pair.0.bounds
            pair.1.string = NSAttributedString(string: texts[index], attributes: [.font: font, .foregroundColor: UIColor.white])
        }
        CATransaction.commit()
    }

    @objc private func toggleMenu() {
        guard presentedViewController == nil else { return }
        guard let coreSetRuntime else { presentNotice("本应用悬浮宿主未接入；跨应用 unavailable"); return }
        coreSetRuntime.toggleMenu()
    }

    func updateRuntimePresentation(menuVisible: Bool, status: String) {
        precondition(Thread.isMainThread)
        menuRequestedVisible = menuVisible
        runtimeStatus = status
        guard isViewLoaded else { return }
        runtimeStatusLabel.text = status
        updatePresentation()
        if !menuVisible { presentPendingNotices() }
    }
    @objc private func showTutorial() {
        if !assistCard.isHidden { hideTutorial(); return }
        assistCard.isHidden = false
        rhythmView.isHidden = true
        updateRhythmPresentation()
        updateParticlePresentation(animated: true)
        animateParticleTutorialResponse(opening: true)
        updateTutorialMotion()
    }
    @objc private func hideTutorial() {
        assistCard.isHidden = true
        rhythmView.isHidden = false
        updateRhythmPresentation()
        updateParticlePresentation(animated: true)
        animateParticleTutorialResponse(opening: false)
        updateTutorialMotion()
    }

    private func updateTutorialMotion() {
        tutorialButton.accessibilityValue = assistCard.isHidden ? "已收起" : "已展开"
        tutorialPageGradient.isHidden = !assistCard.isHidden
        let animate = assistCard.isHidden && UIApplication.shared.applicationState == .active && !UIAccessibility.isReduceMotionEnabled
        if animate, let animation = tutorialFlipAnimation {
            if tutorialPageGradient.animation(forKey: "q47.tutorial.flip") == nil {
                tutorialPageGradient.add(animation, forKey: "q47.tutorial.flip")
            }
        } else { tutorialPageGradient.removeAnimation(forKey: "q47.tutorial.flip") }
    }

    private func updateParticlePresentation(animated: Bool = false) {
        let active = UIApplication.shared.applicationState == .active && !UIAccessibility.isReduceMotionEnabled
        particleEmitter.birthRate = active ? 1 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        particleEmitter.opacity = assistCard.isHidden ? 1 : 0.42
        leftMist.opacity = assistCard.isHidden ? 1 : 0.46
        rightMist.opacity = leftMist.opacity
        CATransaction.commit()
        particleEmitter.removeAnimation(forKey: "q47.background.music")
        if !active {
            leftMist.removeAllAnimations()
            rightMist.removeAllAnimations()
            particleEmitter.removeAnimation(forKey: "q47.background.response")
            return
        }
        if homeMusicPlayer?.isPlaying == true {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = assistCard.isHidden ? 0.82 : 0.42
            pulse.toValue = assistCard.isHidden ? 1 : 0.52
            pulse.duration = 1.15
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            particleEmitter.add(pulse, forKey: "q47.background.music")
        }
        for (index, mist) in [leftMist, rightMist].enumerated() where mist.animation(forKey: "q47.background.fog") == nil {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: mist.position)
            move.toValue = NSValue(cgPoint: CGPoint(x: mist.position.x + (index == 0 ? 16 : -14), y: mist.position.y + (index == 0 ? -9 : 11)))
            move.duration = 9
            move.autoreverses = true
            move.repeatCount = .infinity
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mist.add(move, forKey: "q47.background.fog")
        }
    }

    private func animateParticleTutorialResponse(opening: Bool) {
        guard UIApplication.shared.applicationState == .active, !UIAccessibility.isReduceMotionEnabled else { return }
        let response = CAKeyframeAnimation(keyPath: "transform.scale")
        response.values = opening ? [1,1.045,1] : [1,0.965,1]
        response.keyTimes = [0,0.48,1]
        response.duration = 0.48
        particleEmitter.add(response, forKey: "q47.background.response")
    }
    @objc private func launchApplication() {
        CoreSetGameTarget.openApplication { [weak self] result in
            switch result {
            case .opened: break
            case .unavailable: self?.presentNotice("未检测到可打开的和平精英")
            case .failed: self?.presentNotice("系统未能打开和平精英")
            }
        }
    }

    @objc private func homeServiceUnavailable(_ sender: UIButton) {
        let messages = [0: "公告服务尚未接入", 1: "工单提交服务尚未接入", 2: "工单查询服务尚未接入",
                        4: "更新服务尚未接入", 5: "激活续时服务尚未接入"]
        guard let message = messages[sender.tag] else { return }
        presentNotice(message)
    }

    private func observeHomeMusic() {
        guard homeMusicObservers.isEmpty else { return }
        let center = NotificationCenter.default
        homeMusicObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                      object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber else { return }
            // v1.7 audioSessionInterrupted: records both begin and end, then
            // reconciles without changing the user's explicit pause choice.
            self.homeMusicInterrupted = type.uintValue == AVAudioSession.InterruptionType.began.rawValue
            self.reconcileHomeMusic()
        })
        homeMusicObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            self?.homeMusicPlayer?.stop()
            self?.homeMusicPlayer = nil
            self?.reconcileHomeMusic()
        })
        homeMusicObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            self?.reconcileHomeMusic()
        })
        homeMusicObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            self?.homeMusicPlayer?.pause()
            self?.updateHomeMusicPresentation()
        })
    }

    @objc private func toggleHomeMusic() {
        if homeMusicPlayer?.isPlaying == true {
            homeMusicUserPaused = true
            homeMusicPlayer?.pause()
            updateHomeMusicPresentation()
            return
        }
        homeMusicUserPaused = false
        homeMusicInterrupted = false
        // The original native start trigger's home-loading timing is not yet
        // established; begin this local lifecycle on an explicit play request.
        homeMusicStarted = true
        reconcileHomeMusic()
    }

    private func reconcileHomeMusic() {
        // v1.7 reconcilePlayback: only a started, attached, active home may
        // play; interruption/background must not erase a manual pause.
        guard homeMusicStarted, isViewLoaded, view.window != nil,
              UIApplication.shared.applicationState == .active,
              !homeMusicUserPaused, !homeMusicInterrupted else {
            homeMusicPlayer?.pause()
            updateHomeMusicPresentation()
            return
        }
        guard homeMusicPlayer?.isPlaying != true else {
            updateHomeMusicPresentation()
            return
        }
        var failureNotice = "音频会话初始化失败"
        do {
            if homeMusicPlayer == nil {
                guard let url = Bundle.main.url(forResource: "bj", withExtension: "mp3")
                    ?? Bundle.main.url(forResource: "bj", withExtension: "mp3", subdirectory: "CoreSetAssets") else {
                    presentNotice("背景音乐资源 bj.mp3 缺失")
                    return
                }
                try activateHomeMusicSession()
                failureNotice = "背景音乐无法解码"
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
                player.numberOfLoops = -1
                player.volume = 0.62
                guard player.prepareToPlay() else {
                    presentNotice("背景音乐准备失败")
                    return
                }
                homeMusicPlayer = player
            } else {
                try activateHomeMusicSession()
            }
            guard homeMusicPlayer?.play() == true else {
                homeMusicPlayer?.stop()
                homeMusicPlayer = nil
                updateHomeMusicPresentation()
                presentNotice("背景音乐播放失败")
                return
            }
            updateHomeMusicPresentation()
        } catch {
            homeMusicPlayer?.stop()
            homeMusicPlayer = nil
            updateHomeMusicPresentation()
            presentNotice(failureNotice)
        }
    }

    private func activateHomeMusicSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: AVAudioSession.CategoryOptions(rawValue: 1))
        try session.setActive(true)
    }

    private func updateHomeMusicPresentation() {
        let playing = homeMusicPlayer?.isPlaying == true
        musicButton.isSelected = playing
        musicIcon.image = UIImage(systemName: "music.note")
        musicIcon.isHidden = false
        musicIcon.alpha = 1
        musicButton.transform = .identity
        musicDisc.alpha = playing ? 1 : 0.72
        updateMusicIconRotation(playing: playing)
        musicButton.accessibilityValue = playing ? "播放中" : "已暂停"
        musicButton.accessibilityHint = playing ? "轻点暂停背景音乐" : "轻点播放本地背景音乐"
        updateRhythmPresentation()
        updateParticlePresentation()
    }

    private func updateMusicIconRotation(playing: Bool) {
        let layer = musicIcon.layer
        let current = layer.presentation() ?? layer
        let angle = atan2(Double(current.transform.m12), Double(current.transform.m11))
        let animate = playing && UIApplication.shared.applicationState == .active && !UIAccessibility.isReduceMotionEnabled
        if animate {
            guard layer.animation(forKey: "q47.music.rotation") == nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeRotation(CGFloat(angle), 0, 0, 1)
            CATransaction.commit()
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = angle
            rotation.toValue = angle + Double.pi * 2
            rotation.duration = 4.8
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(rotation, forKey: "q47.music.rotation")
        } else {
            layer.removeAnimation(forKey: "q47.music.rotation")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeRotation(CGFloat(angle), 0, 0, 1)
            CATransaction.commit()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.homeMusicPlayer === player else { return }
            self.updateHomeMusicPresentation()
            if !flag { self.presentNotice("背景音乐播放失败") }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.homeMusicPlayer === player else { return }
            self.homeMusicPlayer?.stop()
            self.homeMusicPlayer = nil
            self.updateHomeMusicPresentation()
            self.presentNotice("背景音乐无法解码")
        }
    }
    private func presentNotice(_ message: String) {
        if let alert = presentedViewController as? UIAlertController {
            var messages = (alert.message ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
            if !messages.contains(message) {
                messages.append(message)
                alert.message = messages.joined(separator: "\n")
            }
            return
        }
        if !pendingNotices.contains(message) { pendingNotices.append(message) }
        presentPendingNotices()
    }

    private func presentPendingNotices() {
        guard isViewLoaded, view.window != nil,
              UIApplication.shared.applicationState == .active,
              presentedViewController == nil, !menuRequestedVisible, !pendingNotices.isEmpty else { return }
        let message = pendingNotices.joined(separator: "\n")
        pendingNotices.removeAll()
        let alert = UIAlertController(title: "Core-SET", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .cancel))
        present(alert, animated: true)
    }
}
