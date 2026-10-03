import UIKit

// Core-SET v1.7 homepage geometry for the local UIKit presentation.
// This layout does not read game or backend state.
struct CoreSetHomeLayout {
    let width: CGFloat
    let height: CGFloat
    let isPad: Bool
    let isCompact: Bool
    let topSafe: CGFloat
    let bottomSafe: CGFloat
    let banner: CGRect
    let expiry: CGRect
    let card: CGRect
    let sideButtons: [CGRect]
    let sideHitTargets: [CGRect]
    let hud: CGRect
    let music: CGRect
    let tutorial: CGRect
    let connectors: [[CGPoint]]
    let replyBadge: CGRect

    init(bounds: CGRect, safeArea: UIEdgeInsets, cardHeight: CGFloat = 185) {
        let w = bounds.width, h = bounds.height
        width = w; height = h
        let pad = w >= 700
        let compact = !pad && h <= 700
        isPad = pad; isCompact = compact
        var top = safeArea.top
        if top < 1 { top = pad ? 24 : (h >= 800 ? 47 : 20) }
        top += compact ? 6 : 12
        topSafe = top
        var bottom = safeArea.bottom
        if bottom < 1 { bottom = pad ? 20 : (compact ? 8 : 12) }
        if pad { bottom += 8 }
        bottomSafe = bottom
        let imageWidth = min(w - (pad ? 48 : compact ? 32 : 20),
                             pad ? 680 : w - (compact ? 32 : 20))
        let imageHeight = imageWidth * 887 / 1920
        banner = CGRect(x: (w-imageWidth)/2, y: top, width: imageWidth, height: imageHeight)
        let cardWidth = min(w-(pad ? 64 : 24), pad ? 680 : w-24)
        let cardX = (w-cardWidth)/2
        let cardY = h-bottom-cardHeight
        card = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
        let expiryY = top+imageHeight+4
        expiry = CGRect(x: cardX, y: expiryY, width: cardWidth, height: 34)
        let controlWidth = min(w-(pad ? 64 : compact ? 28 : 24), pad ? 760 : w)
        let controlX = (w-controlWidth)/2
        let gap: CGFloat = pad ? 20 : compact ? 7 : 9
        let centerWidth = min(pad ? 152 : compact ? 108 : 122, controlWidth * 0.34)
        let sideWidth = (controlWidth-centerWidth-gap*2)/2
        let buttonWidth = sideWidth*2/3
        let buttonHeight: CGFloat = pad ? 36 : compact ? 27 : 29.333333333333332
        let leftX = controlX
        let centerX = controlX+sideWidth+gap
        let rightX = centerX+centerWidth+gap+sideWidth-buttonWidth
        let start = expiryY+42
        let end = cardY-(compact ? 6 : 10)
        let available = max(180,end-start)
        let regionHeight = min(available,pad ? 500 : available)
        let regionTop = start+max(0,(available-regionHeight)/2)
        let factor: CGFloat = compact ? 0.16 : 0.18
        let rows = [regionTop+regionHeight*factor-buttonHeight/2,
                    regionTop+(regionHeight-buttonHeight)/2,
                    regionTop+regionHeight*(1-factor)-buttonHeight/2]
        sideButtons = [leftX,rightX].flatMap { x in
            rows.map { CGRect(x:x,y:$0,width:buttonWidth,height:buttonHeight) }
        }
        sideHitTargets = sideButtons.map {
            CGRect(x:$0.minX-5,y:$0.midY-22,width:$0.width+10,height:44)
        }
        let mainY = regionTop+(regionHeight-centerWidth)/2
        hud = CGRect(x:centerX,y:mainY,width:centerWidth,height:centerWidth)
        let musicSize: CGFloat = pad ? 48 : 44
        music = CGRect(x:(w-musicSize)/2,y:rows[0]+(buttonHeight-musicSize)/2,
                       width:musicSize,height:musicSize)
        let tutorialSize: CGFloat = pad ? 64 : 58
        tutorial = CGRect(x:(w-tutorialSize)/2,y:rows[2]+buttonHeight/2-tutorialSize/2,
                          width:tutorialSize,height:tutorialSize)
        let margin = max(22,gap*2.5)
        let leftStart = leftX+buttonWidth, rightStart = rightX
        let leftStop = centerX-margin, rightStop = centerX+centerWidth+margin
        let leftBend = leftStart+(leftStop-leftStart)*0.58
        let rightBend = rightStart-(rightStart-rightStop)*0.58
        let rise = min(22,centerWidth*0.18)
        connectors = [(leftStart,leftBend,leftStop),(rightStart,rightBend,rightStop)].flatMap { x in
            rows.enumerated().map { index,y in
                let center = y+buttonHeight/2
                return [CGPoint(x:x.0,y:center),
                        CGPoint(x:index == 1 ? x.2 : x.1,y:center),
                        CGPoint(x:x.2,y:center+(index == 0 ? rise : index == 2 ? -rise : 0))]
            }
        }
        replyBadge = CGRect(x:leftStop-8,y:rows[2]+buttonHeight/2-rise-8,width:16,height:16)
    }
}
