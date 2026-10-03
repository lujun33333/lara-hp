import UIKit

// QXA121, LuaJIT prototypes 133/137/138 in Core-SET 1.6.
// Actions are injected by the host; this view never authorizes a device or
// changes the game target. Unbound actions must be reported by the host.
final class CoreSetHomeView: UIView {
    enum Action { case announcements, feedbackSubmit, feedbackQuery, game, update, activation, hud, music, tutorial, expiry }
    var onAction: ((Action) -> Void)?
    private let backgroundGradient = CAGradientLayer()
    private let banner = UIImageView(image: UIImage(named: "hf"))
    private let expiryButton = UIButton(type: .custom)
    private let authorizationPill = CoreSetAuthorizationPill()
    private let hudButton = UIButton(type: .custom)
    private let musicButton = UIButton(type: .custom)
    private let tutorialButton = UIButton(type: .custom)
    private let tutorialTitle = UILabel()
    private let tutorialIcon = UIView()
    private let assistCard = UIView()
    private let rhythmView = UIView()
    private let replyBadge = UILabel()
    private var buttons: [UIButton] = []
    private var gradients: [CAGradientLayer] = []
    private var hitTargets: [UIButton] = []
    private var connectorLayers: [CAShapeLayer] = []
    private var hudGradient = CAGradientLayer()
    private var musicGradient = CAGradientLayer()
    private let musicDisc = UIView()
    private let musicIcon = UIImageView(image: UIImage(systemName: "music.note"))
    private let breathingRing = UIView()
    private let assistGradient = CAGradientLayer()
    private let assistInner = UIView()
    private let assistInnerGradient = CAGradientLayer()
    private let assistClose = UIButton(type:.custom)
    private var assistRows: [UIView] = []
    private var tutorialShown = false
    private let tutorialBookGradient = CAGradientLayer()
    private let tutorialBookMask = CALayer()
    private let tutorialPageGradient = CAGradientLayer()
    private let tutorialPageMask = CAShapeLayer()
    private let rhythmSurface = CAGradientLayer()
    private let rhythmBaseline = CALayer()
    private var rhythmBars: [CAGradientLayer] = []

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
        UIColor(red:r/255,green:g/255,blue:b/255,alpha:a)
    }

    override init(frame: CGRect) {
        super.init(frame:frame)
        backgroundColor = Self.rgb(11,16,32)
        backgroundGradient.colors = [Self.rgb(20,27,51).cgColor,Self.rgb(8,11,22).cgColor]
        backgroundGradient.startPoint = CGPoint(x:0.5,y:0)
        backgroundGradient.endPoint = CGPoint(x:0.5,y:1)
        layer.insertSublayer(backgroundGradient,at:0)
        banner.contentMode = .scaleAspectFit
        banner.clipsToBounds = true
        addSubview(banner)
        addSubview(authorizationPill)
        expiryButton.addAction(UIAction { [weak self] _ in self?.onAction?(.expiry) },for:.touchUpInside)
        addSubview(expiryButton)
        // Ordering matches the arrays consumed by prototype 138.
        let titles = ["查看公告","提交工单","工单进度","启动游戏","检查更新","激活续时"]
        let actions: [Action] = [.announcements,.feedbackSubmit,.feedbackQuery,.game,.update,.activation]
        // Prototype 137 passes c1/c2 to the diagonal gradient and c3 to shadow.
        let palette: [[UIColor]] = [
            [Self.rgb(139,92,246),Self.rgb(109,40,217),Self.rgb(124,58,237)],
            [Self.rgb(59,130,246),Self.rgb(29,78,216),Self.rgb(37,99,235)],
            [Self.rgb(251,146,60),Self.rgb(234,88,12),Self.rgb(249,115,22)],
            [Self.rgb(244,114,182),Self.rgb(219,39,119),Self.rgb(236,72,153)],
            [Self.rgb(56,189,248),Self.rgb(14,116,184),Self.rgb(14,165,233)],
            [Self.rgb(250,204,21),Self.rgb(217,119,6),Self.rgb(245,158,11)]
        ]
        for (index,title) in titles.enumerated() {
            let button = UIButton(type:.custom)
            button.setTitle(title,for:.normal)
            button.setTitleColor(.white,for:.normal)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.72
            let gradient = CAGradientLayer()
            gradient.startPoint = CGPoint(x:0,y:0)
            gradient.endPoint = CGPoint(x:1,y:1)
            gradient.masksToBounds = true
            gradient.colors = [palette[index][0].cgColor,palette[index][1].cgColor]
            button.layer.shadowColor = palette[index][2].cgColor
            button.layer.shadowOpacity = 0.6
            button.layer.shadowRadius = 14
            button.layer.shadowOffset = CGSize(width:0,height:5)
            button.layer.insertSublayer(gradient,at:0)
            let action = actions[index]
            button.addAction(UIAction { [weak self] _ in self?.onAction?(action) },for:.touchUpInside)
            let hit = UIButton(type:.custom)
            hit.addAction(UIAction { [weak self] _ in self?.onAction?(action) },for:.touchUpInside)
            buttons.append(button);gradients.append(gradient);hitTargets.append(hit)
            addSubview(button);addSubview(hit)
            let connector = CAShapeLayer()
            connector.fillColor = UIColor.clear.cgColor
            connectorLayers.append(connector)
            connector.strokeColor = palette[index][0].cgColor
            connector.lineWidth = 2.2
            connector.lineCap = .round;connector.lineJoin = .round
            layer.insertSublayer(connector,above:backgroundGradient)
        }
        hudButton.setTitle("打开菜单",for:.normal)
        hudButton.setTitleColor(.white,for:.normal)
        hudButton.layer.insertSublayer(hudGradient,at:0)
        hudGradient.colors = [Self.rgb(74,222,128).cgColor,Self.rgb(22,163,74).cgColor]
        hudGradient.startPoint = .zero;hudGradient.endPoint = CGPoint(x:1,y:1)
        hudGradient.masksToBounds = true
        hudButton.layer.shadowColor = Self.rgb(34,197,94).cgColor
        hudButton.layer.shadowOpacity = 0.6
        hudButton.layer.shadowRadius = 14
        hudButton.layer.shadowOffset = CGSize(width:0,height:5)
        breathingRing.isUserInteractionEnabled = false
        breathingRing.backgroundColor = Self.rgb(34,197,94,0.1)
        breathingRing.layer.borderWidth = 2
        breathingRing.layer.borderColor = Self.rgb(74,222,128,0.75).cgColor
        breathingRing.layer.shadowColor = Self.rgb(34,197,94).cgColor
        breathingRing.layer.shadowOpacity = 0.85
        breathingRing.layer.shadowRadius = 18
        breathingRing.layer.shadowOffset = .zero
        addSubview(breathingRing)
        hudButton.addAction(UIAction { [weak self] _ in self?.onAction?(.hud) },for:.touchUpInside)
        addSubview(hudButton)
        musicDisc.layer.insertSublayer(musicGradient,at:0)
        musicDisc.isUserInteractionEnabled = false
        musicDisc.backgroundColor = Self.rgb(24,18,48,0.94)
        musicDisc.layer.borderWidth = 1.5
        musicDisc.layer.borderColor = Self.rgb(192,132,252,0.95).cgColor
        musicDisc.layer.shadowColor = Self.rgb(168,85,247).cgColor
        musicDisc.layer.shadowOpacity = 0.8
        musicDisc.layer.shadowRadius = 9
        musicDisc.layer.shadowOffset = .zero
        musicGradient.colors = [Self.rgb(236,72,153,0.72).cgColor,Self.rgb(99,102,241,0.72).cgColor,Self.rgb(34,211,238,0.62).cgColor]
        musicGradient.startPoint = .zero;musicGradient.endPoint = CGPoint(x:1,y:1)
        musicButton.addSubview(musicDisc)
        musicIcon.contentMode = .scaleAspectFit
        musicIcon.tintColor = Self.rgb(240,232,255)
        musicButton.addSubview(musicIcon)
        musicButton.addAction(UIAction { [weak self] _ in self?.onAction?(.music) },for:.touchUpInside)
        addSubview(musicButton)
        tutorialTitle.text = "教程"
        tutorialTitle.textAlignment = .center
        tutorialTitle.textColor = Self.rgb(216,180,254)
        tutorialTitle.font = .boldSystemFont(ofSize:13)
        tutorialBookGradient.colors = [Self.rgb(236,72,153).cgColor,Self.rgb(99,102,241).cgColor,Self.rgb(34,211,238).cgColor]
        tutorialBookGradient.startPoint = CGPoint(x:0,y:0.15);tutorialBookGradient.endPoint = CGPoint(x:1,y:0.85)
        tutorialBookGradient.mask = tutorialBookMask
        tutorialBookGradient.shadowColor = Self.rgb(168,85,247).cgColor
        tutorialBookGradient.shadowOpacity = 0.58;tutorialBookGradient.shadowRadius = 6;tutorialBookGradient.shadowOffset = .zero
        tutorialIcon.layer.addSublayer(tutorialBookGradient)
        tutorialPageGradient.colors = [Self.rgb(250,207,250).cgColor,Self.rgb(129,140,248).cgColor,Self.rgb(103,232,249).cgColor]
        tutorialPageGradient.startPoint = .zero;tutorialPageGradient.endPoint = CGPoint(x:1,y:1)
        tutorialPageGradient.mask = tutorialPageMask
        tutorialPageGradient.anchorPoint = CGPoint(x:0,y:0.5)
        tutorialPageGradient.shadowColor = UIColor.white.cgColor
        tutorialPageGradient.shadowOpacity = 0.42;tutorialPageGradient.shadowRadius = 2;tutorialPageGradient.shadowOffset = .zero
        tutorialPageMask.fillColor = UIColor.white.cgColor
        let page = UIBezierPath();page.move(to:CGPoint(x:0,y:1))
        page.addQuadCurve(to:CGPoint(x:13.5,y:3),controlPoint:CGPoint(x:7.5,y:0))
        page.addLine(to:CGPoint(x:13.5,y:19))
        page.addQuadCurve(to:CGPoint(x:0,y:20),controlPoint:CGPoint(x:7,y:17.5));page.close()
        tutorialPageMask.path = page.cgPath
        tutorialIcon.layer.addSublayer(tutorialPageGradient)
        var perspective = CATransform3DIdentity;perspective.m34 = -1/180
        tutorialIcon.layer.sublayerTransform = perspective
        tutorialButton.addSubview(tutorialIcon)
        tutorialButton.addSubview(tutorialTitle)
        tutorialButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.tutorialShown.toggle()
            self.assistCard.isHidden = !self.tutorialShown
            self.rhythmView.isHidden = self.tutorialShown
            self.onAction?(.tutorial)
        },for:.touchUpInside)
        addSubview(tutorialButton)
        addSubview(rhythmView)
        rhythmSurface.colors = [Self.rgb(30,22,61,0.72).cgColor,Self.rgb(13,25,48,0.82).cgColor]
        rhythmSurface.startPoint = CGPoint(x:0,y:0.5);rhythmSurface.endPoint = CGPoint(x:1,y:0.5)
        rhythmSurface.borderWidth = 1;rhythmSurface.borderColor = Self.rgb(139,92,246,0.26).cgColor
        rhythmSurface.shadowColor = Self.rgb(99,102,241).cgColor;rhythmSurface.shadowOpacity = 0.22;rhythmSurface.shadowRadius = 12;rhythmSurface.shadowOffset = .zero
        rhythmView.layer.addSublayer(rhythmSurface)
        rhythmBaseline.backgroundColor = Self.rgb(129,140,248,0.28).cgColor
        rhythmView.layer.addSublayer(rhythmBaseline)
        assistCard.isHidden = true
        configureAssistCard()
        addSubview(assistCard)
        replyBadge.text = "!"
        replyBadge.textAlignment = .center
        replyBadge.isHidden = true
        addSubview(replyBadge)
    }

    private func configureAssistCard() {
        assistCard.layer.cornerRadius = 18
        assistCard.layer.shadowColor = Self.rgb(88,70,180).cgColor
        assistCard.layer.shadowOpacity = 0.2
        assistCard.layer.shadowRadius = 10
        assistCard.layer.shadowOffset = CGSize(width:0,height:5)
        assistGradient.colors = [Self.rgb(236,72,153,0.82).cgColor,Self.rgb(139,92,246,0.9).cgColor,Self.rgb(34,211,238,0.78).cgColor]
        assistGradient.startPoint = .zero;assistGradient.endPoint = CGPoint(x:1,y:1)
        assistGradient.cornerRadius = 18
        assistCard.layer.insertSublayer(assistGradient,at:0)
        assistInner.backgroundColor = Self.rgb(18,23,48,0.96)
        assistInner.layer.cornerRadius = 16.8
        assistInner.clipsToBounds = true
        assistInnerGradient.colors = [Self.rgb(30,24,62,0.78).cgColor,Self.rgb(15,28,54,0.9).cgColor,Self.rgb(12,20,40,0.96).cgColor]
        assistInnerGradient.startPoint = .zero;assistInnerGradient.endPoint = CGPoint(x:1,y:1)
        assistInner.layer.insertSublayer(assistInnerGradient,at:0)
        assistCard.addSubview(assistInner)
        let icon = UIImageView(image:UIImage(systemName:"list.number"))
        icon.tintColor = Self.rgb(236,72,153)
        icon.frame = CGRect(x:11,y:12,width:18,height:18)
        assistCard.addSubview(icon)
        assistClose.setTitle("关闭",for:.normal)
        assistClose.setTitleColor(Self.rgb(254,205,211),for:.normal)
        assistClose.titleLabel?.font = .boldSystemFont(ofSize:10.5)
        assistClose.backgroundColor = Self.rgb(88,28,55,0.86)
        assistClose.layer.cornerRadius = 10
        assistClose.layer.borderWidth = 1
        assistClose.layer.borderColor = Self.rgb(244,114,182,0.72).cgColor
        assistClose.clipsToBounds = true
        assistClose.addAction(UIAction { [weak self] _ in
            self?.tutorialShown = false;self?.assistCard.isHidden = true;self?.rhythmView.isHidden = false
        },for:.touchUpInside)
        assistCard.addSubview(assistClose)
        let content = [("准备环境","打开菜单，等待环境就绪后点击“内核利用”"),
                       ("启动游戏","初始化成功后启动和平精英，再点击“获取信息”"),
                       ("开始使用","信息获取成功后即可开启功能进入对局"),
                       ("问题反馈","出现异常时可通过“提交工单”进行反馈")]
        let colors = [(Self.rgb(139,92,246),Self.rgb(99,102,241)),
                      (Self.rgb(244,114,182),Self.rgb(219,39,119)),
                      (Self.rgb(34,211,238),Self.rgb(59,130,246)),
                      (Self.rgb(251,146,60),Self.rgb(244,114,182))]
        for (i,text) in content.enumerated() {
            let row = UIView();row.backgroundColor = UIColor.white.withAlphaComponent(0.025);row.layer.cornerRadius = 10
            let number = UILabel(frame:CGRect(x:5,y:4,width:23,height:23))
            let gradient = CAGradientLayer();gradient.frame = number.bounds;gradient.cornerRadius = 11.5
            gradient.colors = [colors[i].0.cgColor,colors[i].1.cgColor]
            gradient.startPoint = .zero;gradient.endPoint = CGPoint(x:1,y:1)
            number.layer.insertSublayer(gradient,at:0)
            number.text = String(i+1);number.textColor = .white;number.font = .boldSystemFont(ofSize:11.5);number.textAlignment = .center
            row.addSubview(number)
            let title = UILabel();title.text = text.0;title.textColor = colors[i].0;title.font = .boldSystemFont(ofSize:12);title.tag = 1
            let detail = UILabel();detail.text = text.1;detail.textColor = Self.rgb(205,215,238);detail.font = .systemFont(ofSize:11);detail.tag = 2
            detail.numberOfLines = 1;detail.adjustsFontSizeToFitWidth = true;detail.minimumScaleFactor = 0.82
            row.addSubview(title);row.addSubview(detail);assistRows.append(row);assistCard.addSubview(row)
        }
    }

    @available(*,unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateStatus(deviceName:String,systemVersion:String,expiry:String?,menuOpen:Bool) {
        authorizationPill.deviceText = "\(deviceName) · iOS \(systemVersion)"
        authorizationPill.expiryText = expiry?.isEmpty == false ? expiry! : "获取失败"
        hudButton.setTitle(menuOpen ? "关闭菜单" : "打开菜单",for:.normal)
        let colors = menuOpen ? [Self.rgb(255,92,110),Self.rgb(220,38,74),Self.rgb(244,63,94)]
                              : [Self.rgb(74,222,128),Self.rgb(22,163,74),Self.rgb(34,197,94)]
        hudGradient.colors = [colors[0].cgColor,colors[1].cgColor]
        hudButton.layer.shadowColor = colors[2].cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let p = CoreSetHomeLayout(bounds:bounds,safeArea:safeAreaInsets)
        CATransaction.begin();CATransaction.setDisableActions(true)
        backgroundGradient.frame = bounds
        banner.frame = p.banner
        authorizationPill.frame = p.expiry
        expiryButton.frame = CGRect(x:p.expiry.minX,y:p.expiry.minY-5,width:p.expiry.width,height:44)
        for i in buttons.indices {
            buttons[i].frame = p.sideButtons[i]
            buttons[i].layer.cornerRadius = p.sideButtons[i].height/2
            buttons[i].titleLabel?.font = .boldSystemFont(ofSize:p.isPad ? 16 : p.isCompact ? 13.5 : 15)
            gradients[i].frame = buttons[i].bounds
            gradients[i].cornerRadius = buttons[i].bounds.height/2
            hitTargets[i].frame = p.sideHitTargets[i]
            let path = UIBezierPath()
            for (j,point) in p.connectors[i].enumerated() {
                if j == 0 { path.move(to:point) } else { path.addLine(to:point) }
            }
            connectorLayers[i].frame = bounds
            connectorLayers[i].path = path.cgPath
        }
        hudButton.frame = p.hud
        hudButton.layer.cornerRadius = p.hud.height/2
        hudButton.titleLabel?.font = .boldSystemFont(ofSize:p.isPad ? 17 : 15)
        hudGradient.frame = hudButton.bounds;hudGradient.cornerRadius = p.hud.height/2
        breathingRing.bounds = CGRect(x:0,y:0,width:p.hud.width+10,height:p.hud.height+10)
        breathingRing.center = CGPoint(x:p.hud.midX,y:p.hud.midY)
        breathingRing.layer.cornerRadius = (p.hud.height+10)/2
        musicButton.frame = p.music
        musicDisc.frame = CGRect(x:3,y:3,width:p.music.width-6,height:p.music.height-6)
        musicDisc.layer.cornerRadius = musicDisc.bounds.width/2
        musicGradient.frame = musicDisc.bounds;musicGradient.cornerRadius = musicDisc.bounds.width/2
        musicIcon.bounds = CGRect(x:0,y:0,width:p.music.width-24,height:p.music.height-24)
        musicIcon.center = CGPoint(x:p.music.width/2,y:p.music.height/2)
        tutorialButton.frame = p.tutorial
        tutorialIcon.frame = CGRect(x:(p.tutorial.width-34)/2,y:0,width:34,height:32)
        tutorialBookGradient.frame = tutorialIcon.bounds
        tutorialBookMask.frame = tutorialIcon.bounds
        let symbol = UIImage(systemName:"book.fill",withConfiguration:UIImage.SymbolConfiguration(pointSize:29,weight:.semibold))?.withTintColor(.black,renderingMode:.alwaysOriginal)
        if let symbol {
            let target = tutorialIcon.bounds
            let scale = min(target.width/symbol.size.width,target.height/symbol.size.height)
            let size = CGSize(width:symbol.size.width*scale,height:symbol.size.height*scale)
            let renderer = UIGraphicsImageRenderer(size:target.size)
            tutorialBookMask.contents = renderer.image { _ in
                symbol.draw(in:CGRect(x:(target.width-size.width)/2,y:(target.height-size.height)/2,width:size.width,height:size.height))
            }.cgImage
        }
        tutorialPageGradient.bounds = CGRect(x:0,y:0,width:14,height:21)
        tutorialPageGradient.position = CGPoint(x:tutorialIcon.bounds.midX,y:tutorialIcon.bounds.midY+0.5)
        tutorialPageMask.frame = tutorialPageGradient.bounds
        tutorialTitle.frame = CGRect(x:0,y:35,width:p.tutorial.width,height:18)
        assistCard.frame = p.card;rhythmView.frame = p.card
        let rhythmWidth = p.card.width, rhythmHeight = p.card.height
        let surfaceHeight = min(76,max(58,rhythmHeight*0.44))
        rhythmSurface.frame = CGRect(x:7,y:(rhythmHeight-surfaceHeight)/2,width:rhythmWidth-14,height:surfaceHeight)
        rhythmSurface.cornerRadius = surfaceHeight/2
        let count = rhythmWidth >= 500 ? 64 : 42
        if rhythmBars.count != count {
            rhythmBars.forEach { $0.removeFromSuperlayer() }
            rhythmBars = (0..<count).map { index in
                let bar = CAGradientLayer()
                let position = CGFloat(index)/CGFloat(count-1)
                let colors = position < 0.34 ? [Self.rgb(244,114,182),Self.rgb(168,85,247,0.88)]
                           : position < 0.68 ? [Self.rgb(192,132,252),Self.rgb(99,102,241,0.88)]
                                            : [Self.rgb(103,232,249),Self.rgb(59,130,246,0.88)]
                bar.colors = colors.map(\.cgColor)
                bar.startPoint = CGPoint(x:0.5,y:0);bar.endPoint = CGPoint(x:0.5,y:1)
                bar.anchorPoint = CGPoint(x:0.5,y:1)
                rhythmView.layer.addSublayer(bar)
                return bar
            }
        }
        let barWidth = min(6,max(3,(rhythmWidth-50-CGFloat(count-1)*2.1)/CGFloat(count)))
        let total = CGFloat(count)*barWidth+CGFloat(count-1)*2.1
        let xStart = (rhythmWidth-total)/2
        let barHeight = surfaceHeight-22
        for (index,bar) in rhythmBars.enumerated() {
            bar.bounds = CGRect(x:0,y:0,width:barWidth,height:barHeight)
            bar.position = CGPoint(x:xStart+barWidth/2+CGFloat(index)*(barWidth+2.1),y:rhythmHeight/2+barHeight/2)
            bar.cornerRadius = barWidth/2
            bar.setAffineTransform(CGAffineTransform(scaleX:1,y:0.18+CGFloat(index%5)*0.035))
        }
        rhythmBaseline.frame = CGRect(x:xStart-4,y:rhythmHeight/2+barHeight/2+1.5,width:total+8,height:1)
        assistGradient.frame = assistCard.bounds
        assistInner.frame = assistCard.bounds.insetBy(dx:1.2,dy:1.2)
        assistInnerGradient.frame = assistInner.bounds
        assistClose.frame = CGRect(x:p.card.width-68,y:12,width:57,height:20)
        for (i,row) in assistRows.enumerated() {
            row.frame = CGRect(x:6,y:38+35*CGFloat(i),width:p.card.width-12,height:31)
            row.viewWithTag(1)?.frame = CGRect(x:39,y:1,width:p.card.width-56,height:14)
            row.viewWithTag(2)?.frame = CGRect(x:39,y:15,width:p.card.width-56,height:15)
        }
        replyBadge.frame = p.replyBadge
        CATransaction.commit()
    }
}
