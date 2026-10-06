$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $root 'lara/views/app/CoreSetMenuViewController.swift') -Raw -Encoding UTF8
foreach ($token in @('final class CoreSetMenuViewController: UIViewController',
    'var onClose: (() -> Void)?', 'CGSize(width: 838, height: 535)',
    '["主页", "玩家", "物资", "调整", "雷达", "自瞄", "压枪"]',
    'width: 160, height: 535', 'OPPOSans-H',
    'core-set.menu.light', 'UserDefaults.standard.set(value.theme == .light, forKey: self.themeKey)',
    '#selector(selectPage(_:))', '#selector(selectTheme(_:))', '#selector(closeMenu)',
    'dismiss(animated: true, completion: onClose)', 'DarkSword',
    'row.isUserInteractionEnabled = false', 'row.accessibilityTraits = .notEnabled',
    'slider.isEnabled = false', 'selection.isEnabled = false',
    'card.bounds.width - 20 - row.frame.minX', 'width: 21, height: 21',
    'box.layer.cornerRadius = 3', 'box.layer.borderWidth = 1.5',
    'private let defaultAccent = UIColor', 'values.count == 4',
    'values.allSatisfy({ $0.isFinite && (0...1).contains($0) })',
    'guard key == accentKey, appearanceChannel.map(canStage) == true',
    'guard localAppearanceReady, presetRGB.indices.contains(sender.tag) else { return }',
    'picker.supportsAlpha = target != .theme', 'picker.delegate = self',
    'ranges["最小距离"] = (0, 2000)', 'ranges["最大距离"] = (0, 2000)',
    '"最大距离": (10, 500)', 'materialFilter: true',
    '"显示手持": 46, "玩家数量": 46',
    'width: width, height: 28', 'x += width + 6',
    'let kernelAction = title == "内核利用" || title == "获取信息"',
    'width: card.bounds.width - 40, height: 30',
    'action.layer.cornerRadius = kernelAction ? 6 : 5',
    'action.layer.borderWidth = kernelAction ? 1 : 0',
    'disabledRows(["内核利用", "获取信息"], in: kernel, y: 380)',
    'action.isEnabled = false', 'swatch.layer.cornerRadius = 5',
    'CGFloat(index) * 31', 'let selected = matchesPreset(rgb)',
    'swatch.isSelected = selected',
    'swatch.accessibilityTraits = selected ? [.button, .selected] : .button',
    'swatch.bounds.insetBy(dx: -2, dy: -2)', 'outline.lineWidth = 2',
    'return dr * dr + dg * dg + db * db < 0.0001',
    'blue: CGFloat(values[2]), alpha: 1)', 'slider.thumbTintColor = .clear')) {
    if (-not $source.Contains($token)) { throw "FAIL: local menu contract missing: $token" }
}
if ($source -match 'wzhud_|wzesp_|wzmem|UnityFramework|smoba|Yuanbao|RemoteCall|SecItem|URLSession|ds_|init_offsets|offsets_init') {
    throw 'FAIL: local menu contains a retired backend, external service or privileged consumer'
}
if ($source -match '本地菜单|游戏数据功能尚未接入') {
    throw 'FAIL: menu has unreferenced visible labels'
}
$selectors = [regex]::Matches($source, '#selector\((\w+)')
foreach ($selector in $selectors) {
    if ($selector.Groups[1].Value -notin @('selectPage','selectTheme','closeMenu','editLocalColor','selectPresetColor',
        'selectBackStyle','selectPreviewScene','selectMaterialCategory','toggleMaterialGroup','setAllMaterialGroups','selectFloatingColor',
        'togglePlayerField','changeBoundRange','changeAdjustmentRange','changeFrameRate','selectBackIndicator','selectPlayerWeaponMode','selectPlayerCountMode','selectPlayerInformationMode','toggleRadarField','changeRadarPlacement',
        'toggleMaterialEnabled','toggleHideWhileArmed','toggleCrateLevel','toggleVehicleStatus','toggleMetroArmor','toggleHideOpenedCrates',
        'toggleWarningField','changeWarningRange','toggleLocalAimCircle','changeLocalAimCircleSize',
        'configureBasicAimTrigger','configureBasicAimRange','configureBasicAimBots','configureBasicAimLock',
        'configureBasicAimPoint','configureBasicAimLockStrength','startBasicAim','stopBasicAim',
        'toggleLocalAimPreviewField','changeLocalAimPreviewDistance')) {
        throw 'FAIL: unreviewed menu callback; inspect its state consumers before allowing it'
    }
}
if (-not $source.Contains('let trigger = UISegmentedControl(items: ["开镜", "开火", "任一", "同时"])') -or
    -not $source.Contains('let point = UISegmentedControl(items: ["上身 fallback +30", "胯部 fallback +25"])') -or
    -not $source.Contains('let lock = UISegmentedControl(items: ["最近目标", "锁定同目标"])') -or
    -not $source.Contains('controlAvailability(.basicAimScene, in: featureState.aim) == .ready')) {
    throw 'FAIL: reviewed v1.7 Aim controls must stay bound to typed field availability'
}
if (-not $source.Contains('controlAvailability(.localAimCircle, in: featureState.aimDisplay) == .ready') -or
    -not $source.Contains('controlAvailability(.localAimCircleSize, in: featureState.aimDisplay) == .ready') -or
    -not $source.Contains('显示自瞄圈（仅本地预览）')) {
    throw 'FAIL: local aim display selectors must remain separate from aimControl'
}
if (-not $source.Contains('controlAvailability(.localAimPreviewDistance, in: featureState.aimDisplay) == .ready') -or
    -not $source.Contains('controlAvailability(field, in: featureState.aimDisplay) == .ready')) {
    throw 'FAIL: read-only AimPreview controls must use local field availability'
}
Write-Output 'PASS: seven pages, scoped ranges, validated local colors and reviewed local-preview selectors; static source checks only, no pixel/device result'
