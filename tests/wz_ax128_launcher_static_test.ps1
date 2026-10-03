$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $root 'lara/views/app/ContentView.swift') -Raw -Encoding UTF8
$deviceNames = Get-Content -LiteralPath (Join-Path $root 'lara/funcs/DeviceMarketingName.swift') -Raw -Encoding UTF8
$appSource = Get-Content -LiteralPath (Join-Path $root 'lara/lara.swift') -Raw -Encoding UTF8
$info = Get-Content -LiteralPath (Join-Path $root 'lara/Info.plist') -Raw -Encoding UTF8
$project = Get-Content -LiteralPath (Join-Path $root 'lara.xcodeproj/project.pbxproj') -Raw -Encoding UTF8

# AX 1.2.8 original executable SHA256:
# cc947605b97b90d898e784bf73dcab120c44c9281299fe840285dd67dfec1fb4
# UIKit/CALayer reference entry points:
# viewDidLoad 0x10004ed48; viewDidLayoutSubviews 0x10004f020;
# jZtCjHXgjK 0x10004f964; Wu5ojXWpGE 0x100051600;
# F8At8nNO57 0x1000556b8; JxL6SFWVmy:symbol:style: 0x1000565c8;
# qN92rVfL6x 0x100058038; KOijh8hGA 0x10005974c;
# aJ3wS7dK5c 0x10005a19c; qkn9X7uTCw 0x10006e3bc.
function Require-Literal([string]$token, [string]$message) {
    if ($source -notmatch [regex]::Escape($token)) { throw "FAIL: $message ($token)" }
}

function Reject-Pattern([string]$pattern, [string]$message) {
    if ($source -match $pattern) { throw "FAIL: $message" }
}

Require-Literal '@objc(BYG6trFgTr5X)' 'launcher ObjC runtime class is not the AX class'
Require-Literal 'final class AXLauncherViewController: UIViewController {' 'native launcher controller is absent'
foreach ($token in @(
    '@objc(AXGradientButton)', 'final class AXLauncherGradientButton: UIButton',
    '@objc(AXGradientTintView)', 'final class AXLauncherGradientTintView: UIView',
    'override class var layerClass: AnyClass { CAGradientLayer.self }',
    'AXLauncherGradientButton(type: .system)',
    'private let cardHighlightView = AXLauncherGradientTintView()',
    'private let ruleView = AXLauncherGradientTintView()'
)) { Require-Literal $token 'AX gradient runtime hierarchy is incomplete' }
Reject-Pattern 'UIViewControllerRepresentable|UIHostingController|struct ContentView|#Preview|GeometryReader|ZStack|Canvas\s*\{|TimelineView|SecureField|AXAuroraBackground|AXStarfield' 'SwiftUI root or approximation remains in the launcher'
Reject-Pattern 'override func viewDidAppear' 'launcher adds a lifecycle entry absent from BYG6trFgTr5X'
Require-Literal 'private var managerObservation: AnyCancellable?' 'native launcher does not retain its manager observation'
Require-Literal 'mgr.objectWillChange.sink { [weak self] _ in' 'native launcher does not observe laramgr changes'
Require-Literal 'DispatchQueue.main.async { [weak self] in' 'laramgr updates are not marshalled to the UIKit main thread'
Require-Literal 'private func bootstrapEnvironmentIfNeeded()' 'former SwiftUI onAppear bootstrap was not moved into the UIKit controller'
$viewDidLoad = [regex]::Match($source, 'override func viewDidLoad\(\)\s*\{(?<body>[\s\S]*?)\n\s*\}\n\n\s*override func viewDidLayoutSubviews')
if (-not $viewDidLoad.Success -or
    $viewDidLoad.Groups['body'].Value -notmatch 'updatePresentation\(\)[\s\S]{0,80}bootstrapEnvironmentIfNeeded\(\)') {
    throw 'FAIL: AX viewDidLoad no longer owns the single environment bootstrap point'
}
if ([regex]::Matches($source, '(?m)^\s{8}bootstrapEnvironmentIfNeeded\(\)\s*$').Count -ne 1) {
    throw 'FAIL: launcher environment bootstrap call is duplicated'
}

$body = $source.Substring($source.IndexOf('let arrangedSubviews: [UIView] = ['))
$body = $body.Substring(0, $body.IndexOf('arrangedSubviews.forEach'))
$previous = -1
foreach ($token in @('titleLabel', 'versionLabel', 'separatorView', 'supportCard',
                    'activationField', 'activationButton', 'statusCard', 'spacerView',
                    'launchButton', 'progressContainer')) {
    $position = $body.IndexOf($token, [StringComparison]::Ordinal)
    if ($position -lt 0 -or $position -le $previous) {
        throw "FAIL: AX UIKit arranged subview absent or out of order: $token"
    }
    $previous = $position
}
if ($source -match 'core-mountain|radialMenu|menuExpanded|三指|Text\("Core"\)|\.alert\("Core"') {
    throw 'FAIL: Core launcher or unsupported three-finger tutorial remains'
}
if ($source -notmatch 'title:\s*"启动应用"[\s\S]{0,160}action:\s*#selector\(launchApplication\)') {
    throw 'FAIL: AX launch button is disconnected from the launcher gate'
}
if ($source -notmatch 'guard authorizationState\.canLaunch else[\s\S]{0,400}?mgr\.launchWZGame\(\)') {
    throw 'FAIL: AX launch flow does not enforce the authorization state'
}
if ($source -match 'authorizationState\s*=\s*\.activated') {
    throw 'FAIL: launcher fabricates an activated state without a verification service'
}
foreach ($token in @('case unverified', 'case verifying', 'case activated(expiryText: String)',
                    'case expired(expiryText: String?)', 'showsActivationForm',
                    'return "到期时间：\(expiryText)"')) {
    if ($source -notmatch [regex]::Escape($token)) {
        throw "FAIL: AX authorization presentation state is incomplete: $token"
    }
}
foreach ($token in @(
    'private let baseGradientLayer = CAGradientLayer()',
    'private let auroraTopLayer = CAGradientLayer()',
    'private let auroraBottomLayer = CAGradientLayer()',
    'private let starLayer = CALayer()',
    'auroraTopLayer.compositingFilter = "screen"',
    'auroraBottomLayer.compositingFilter = "screen"',
    'axColor(0.016, 0.018, 0.042)',
    'axColor(0.058, 0.052, 0.125)',
    'axColor(0.020, 0.020, 0.048)',
    'x: -0.25 * bounds.width', 'y: -0.30 * bounds.height',
    'width: 1.50 * bounds.width', 'height: 0.85 * bounds.height',
    'x: -0.35 * bounds.width', 'y: 0.62 * bounds.height',
    'width: 1.70 * bounds.width', 'height: 0.75 * bounds.height',
    'let height = UInt32(max(1, Int(bounds.height * 0.72)))',
    'for index in 0..<34', 'CGFloat(arc4random_uniform(16)) / 10 + 1',
    'Float(arc4random_uniform(18)) / 100 + 0.10',
    'Double(arc4random_uniform(8)) / 100 + 0.08',
    'Double(arc4random_uniform(12)) / 100 + 0.22',
    'Double(arc4random_uniform(260)) / 100 + 2.4',
    'Double(arc4random_uniform(200)) / 100',
    'index % 4 == 0', 'axColor(0.76, 0.70, 1)',
    'UIColor(white: 1, alpha: 0.96)',
    'CABasicAnimation(keyPath: "opacity")',
    'twinkle.autoreverses = true', 'twinkle.repeatCount = .infinity',
    'star.add(twinkle, forKey: "twinkle")'
)) { Require-Literal $token 'AX background/star constant is missing' }

foreach ($token in @(
    'cardView.layer.cornerRadius = 22',
    'cardView.layer.borderColor = axColor(0.62, 0.58, 1.00, 0.22).cgColor',
    'cardView.layer.shadowOffset = CGSize(width: 0, height: 20)',
    'cardView.layer.shadowRadius = 34', 'cardView.layer.shadowOpacity = 0.42',
    'width: cardView.bounds.width, height: 44',
    'stackView.spacing = 12',
    'cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22)',
    'cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12)',
    'stackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20)',
    'activationField.heightAnchor.constraint(equalToConstant: 48)',
    'activationButton.heightAnchor.constraint(equalToConstant: 52)',
    'launchButton.heightAnchor.constraint(equalToConstant: 52)',
    'progressContainer.heightAnchor.constraint(equalToConstant: 34)'
)) { Require-Literal $token 'AX card/layout constant is missing' }

foreach ($token in @(
    'private let activationField = UITextField()',
    'font: .systemFont(ofSize: 44, weight: .black)',
    'font: .systemFont(ofSize: 13, weight: .semibold)',
    'font: .systemFont(ofSize: 15, weight: .semibold)',
    'font: .systemFont(ofSize: 12, weight: .bold)',
    'activationField.font = .systemFont(ofSize: 16, weight: .semibold)',
    'activationField.placeholder = "请输入卡密"',
    'activationField.textColor = axColor(0.93, 0.93, 0.99)',
    'activationField.tintColor = axColor(0.66, 0.58, 1)',
    'activationField.autocorrectionType = .no',
    'activationField.autocapitalizationType = .none',
    'activationField.clearButtonMode = .whileEditing',
    'activationField.returnKeyType = .done',
    'activationField.backgroundColor = axColor(0.04, 0.042, 0.088)',
    'activationField.layer.cornerRadius = 14',
    'activationField.layer.borderColor = axColor(0.55, 0.50, 1, 0.32).cgColor',
    'font: .monospacedDigitSystemFont(ofSize: 13, weight: .bold)',
    'activationField.tag = 0xc739', 'activationButton.tag = 0xc73a', 'expiryLabel.tag = 0xc73b',
    'button.backgroundColor = axColor(0.10, 0.105, 0.20)',
    'button.layer.shadowOpacity = 0.26',
    'button.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)',
    'button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)',
    'button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -8, bottom: 0, right: 8)',
    'button.setTitleColor(button.tintColor, for: .normal)',
    'button.setTitleColor(button.tintColor.withAlphaComponent(0.48), for: .disabled)',
    'button.setImage(UIImage(systemName: symbol), for: .normal)',
    'progressContainer.isHidden = true',
    'progressView.progress = 0',
    'progressView.trackTintColor = axColor(0.10, 0.10, 0.20)',
    'progressView.progressTintColor = axColor(0.58, 0.50, 1)',
    'progressView.setProgress(progress, animated: false)',
    'String(format: "VERSION %@", "1.2.8")',
    '正在检查当前环境…',
    'axDeviceSupportStatus()', 'deviceSupport.marketingName', '✓ 当前环境支持',
    '! 当前环境待测试', '✕ 当前环境不受支持',
    '当前系统尚未完成实机验证，请谨慎继续', '验证与启动功能已停用'
)) { Require-Literal $token 'AX control/support contract is missing' }
foreach ($token in @('@objc(ZeqcgKhNvh)', 'final class LaraSceneDelegate: UIResponder, UIWindowSceneDelegate')) {
    if ($appSource -notmatch [regex]::Escape($token)) { throw "FAIL: AX scene runtime class missing: $token" }
}
if ($info -notmatch '<key>UISceneDelegateClassName</key>\s*<string>ZeqcgKhNvh</string>') {
    throw 'FAIL: Info.plist Scene delegate does not use the AX runtime class name'
}

Reject-Pattern 'screenBlendMode|UITextFieldDelegate|activationField\.delegate|textFieldShouldReturn|isSecureTextEntry\s*=\s*true|keyboardType\s*=' 'launcher adds a visual or text-field behavior absent from the AX IMPs'

if ($source -match 'URLSession\.|SecItem(Add|Update|CopyMatching|Delete)\s*\(|UserDefaults\.') {
    throw 'FAIL: excluded authorization transport or persistence was added to the launcher'
}
$supportSource = Get-Content -LiteralPath (Join-Path $root 'lara/funcs/isunsupported.swift') -Raw -Encoding UTF8
foreach ($token in @('machine.hasPrefix("iPhone18,")', 'machine.hasPrefix("iPad17,")',
                    'v.majorVersion == 18', 'v.patchVersion >= 2',
                    'v.majorVersion == 26', 'v.patchVersion > 1')) {
    if ($supportSource -notmatch [regex]::Escape($token)) {
        throw "FAIL: AX support gate is missing: $token"
    }
}
if ($source -notmatch 'let deviceSupport = axDeviceSupportStatus\(\)[\s\S]{0,320}if !deviceSupport\.isSupported') {
    throw 'FAIL: launcher support presentation does not use the shared support gate'
}
$managerSource = Get-Content -LiteralPath (Join-Path $root 'lara/classes/laramgr.swift') -Raw -Encoding UTF8
if ($managerSource -notmatch 'func launchWZGame\(\)[\s\S]{0,260}axDeviceSupportStatus\(\)[\s\S]{0,220}guard support\.isSupported') {
    throw 'FAIL: game launch bypasses the shared AX support gate'
}
foreach ($mapping in @(
    '"iPhone15,2": "iPhone 14 Pro"',
    '"iPhone16,1": "iPhone 15 Pro"',
    '"iPhone17,1": "iPhone 16 Pro"',
    '"iPhone17,2": "iPhone 16 Pro Max"',
    '"iPhone17,3": "iPhone 16"',
    '"iPhone17,4": "iPhone 16 Plus"',
    '"iPhone17,5": "iPhone 16e"',
    '"iPhone18,1": "iPhone 17 Pro"',
    '"iPhone18,2": "iPhone 17 Pro Max"',
    '"iPhone18,3": "iPhone 17"',
    '"iPhone18,4": "iPhone Air"'
)) {
    if ($deviceNames -notmatch [regex]::Escape($mapping)) {
        throw "FAIL: AX marketing-name mapping is missing: $mapping"
    }
}
foreach ($pattern in @('<string>AX Pro</string>', 'UIInterfaceOrientationLandscapeLeft',
                       'UIInterfaceOrientationLandscapeRight', 'UIInterfaceOrientationPortraitUpsideDown')) {
    if ($info -notmatch [regex]::Escape($pattern)) { throw "FAIL: AX Info.plist contract missing: $pattern" }
}
if ($project -notmatch 'MARKETING_VERSION = 1\.2\.8;' -or
    $project -notmatch 'CURRENT_PROJECT_VERSION = 1;') {
    throw 'FAIL: AX launcher bundle version is not 1.2.8 (build 1)'
}
if ($project -match 'INFOPLIST_KEY_UISupportedInterfaceOrientations_i(Phone|Pad) = UIInterfaceOrientationPortrait;') {
    throw 'FAIL: build settings override the AX four-orientation Info.plist contract'
}
$icons = @{
    'lara/AppIcon60x60@2x.png' = 'B5B43BE770B6514384393DEE2D0CECA9AAC9476FB32283D8D719F18525FDF2D0'
    'lara/AppIcon76x76@2x~ipad.png' = '67D418DE12C8C9521A80C6BAB887AE56E9E00DF757F2C0D4BEFB5B5D23832792'
}
foreach ($entry in $icons.GetEnumerator()) {
    $path = Join-Path $root $entry.Key
    if (-not (Test-Path -LiteralPath $path) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Value) {
        throw "FAIL: AX application icon is absent or changed: $($entry.Key)"
    }
}
if (Test-Path -LiteralPath (Join-Path $root 'lara/other/media.xcassets/AppIcon.appiconset')) {
    throw 'FAIL: obsolete Lara AppIcon asset catalog remains in the product'
}
Write-Output 'PASS: AX 1.2.8 launcher states, device names, aurora effects, and launch gate'
