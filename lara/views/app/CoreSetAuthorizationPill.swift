import UIKit

// Pure presentation from OKDHomeMusicController 0x10017EDE4 / 0x10017F42C.
// There is deliberately no authorization transport or identity persistence here.
final class CoreSetAuthorizationPill: UIView {
    var deviceText = "" { didSet { setNeedsLayout() } }
    var expiryText = "获取失败" { didSet { setNeedsLayout() } }
    private let background = CAGradientLayer()
    private let border = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    private let deviceGradient = CAGradientLayer()
    private let expiryGradient = CAGradientLayer()
    private let deviceMask = CATextLayer()
    private let expiryMask = CATextLayer()
    private let indicator = CAGradientLayer()
    private let indicatorMask = CAShapeLayer()
    private static let colors = [UIColor(red:236/255,green:72/255,blue:153/255,alpha:1).cgColor,
                                 UIColor(red:139/255,green:92/255,blue:246/255,alpha:1).cgColor,
                                 UIColor(red:34/255,green:211/255,blue:238/255,alpha:1).cgColor]
    override init(frame:CGRect) {
        super.init(frame:frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 12
        layer.shadowColor = UIColor(red:139/255,green:92/255,blue:246/255,alpha:1).cgColor
        layer.shadowOpacity = 0.24;layer.shadowRadius = 9;layer.shadowOffset = CGSize(width:0,height:4)
        background.colors = [UIColor(red:20/255,green:25/255,blue:51/255,alpha:0.96).cgColor,
                             UIColor(red:29/255,green:19/255,blue:56/255,alpha:0.94).cgColor]
        background.startPoint = CGPoint(x:0,y:0.5);background.endPoint = CGPoint(x:1,y:0.5);background.cornerRadius = 12
        layer.addSublayer(background)
        border.colors = Self.colors;border.startPoint = .zero;border.endPoint = CGPoint(x:1,y:1)
        borderMask.fillColor = UIColor.clear.cgColor;borderMask.strokeColor = UIColor.white.cgColor;borderMask.lineWidth = 1.5
        border.mask = borderMask;layer.addSublayer(border)
        for (gradient,mask) in [(deviceGradient,deviceMask),(expiryGradient,expiryMask)] {
            gradient.colors = Self.colors;gradient.startPoint = CGPoint(x:0,y:0.5);gradient.endPoint = CGPoint(x:1,y:0.5)
            mask.foregroundColor = UIColor.white.cgColor;mask.truncationMode = .end
            gradient.mask = mask;layer.addSublayer(gradient)
        }
        deviceMask.alignmentMode = .left;expiryMask.alignmentMode = .right
        indicator.type = .conic;indicator.colors = Self.colors
        indicator.startPoint = CGPoint(x:0.5,y:0.5);indicator.endPoint = CGPoint(x:0.5,y:0)
        indicatorMask.fillColor = UIColor.white.cgColor;indicatorMask.lineWidth = 0
        indicator.mask = indicatorMask;layer.addSublayer(indicator)
    }
    @available(*,unavailable)
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin();CATransaction.setDisableActions(true)
        background.frame = bounds;border.frame = bounds;borderMask.frame = bounds
        borderMask.path = UIBezierPath(roundedRect:bounds.insetBy(dx:0.75,dy:0.75),cornerRadius:11.25).cgPath
        let mid = bounds.width/2
        indicator.frame = CGRect(x:mid-4.5,y:bounds.height/2-4.5,width:9,height:9)
        indicatorMask.frame = indicator.bounds
        indicatorMask.path = UIBezierPath(ovalIn:indicator.bounds.insetBy(dx:0.75,dy:0.75)).cgPath
        let widths = [max(mid-25,40),max(bounds.width-mid-24,40)]
        for (index,pair) in [(deviceGradient,deviceMask),(expiryGradient,expiryMask)].enumerated() {
            let text = index == 0 ? deviceText : "授权至：\(expiryText)"
            var size:CGFloat = bounds.width >= 500 ? 12.5 : 11.25
            while size > 9 && (text as NSString).size(withAttributes:[.font:UIFont.boldSystemFont(ofSize:size)]).width > widths[index] { size -= 0.25 }
            let font = UIFont.boldSystemFont(ofSize:size)
            pair.0.frame = CGRect(x:index == 0 ? 13 : mid+12,y:(bounds.height-font.lineHeight)/2-1,width:widths[index],height:font.lineHeight+2)
            pair.1.frame = pair.0.bounds
            pair.1.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            pair.1.string = NSAttributedString(string:text,attributes:[.font:font,.foregroundColor:UIColor.white])
        }
        CATransaction.commit()
    }
}
