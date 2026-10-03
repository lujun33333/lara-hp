//
//  isunsupported.swift
//  lara
//
//  Created by ruter on 30.03.26.
//

import UIKit
import Darwin

struct AXDeviceSupportStatus {
    let identifier: String
    let marketingName: String
    let systemVersion: OperatingSystemVersion
    let isSupported: Bool
    let reason: String?
}

func devicemachine() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)

    let mirror = Mirror(reflecting: sysinfo.machine)
    return mirror.children.reduce("") { identifier, element in
        guard let value = element.value as? Int8, value != 0 else { return identifier }
        return identifier + String(UnicodeScalar(UInt8(value)))
    }
}

func hasmie() -> Bool {
    let machine = devicemachine()

    // AX 1.2.8 pC9jR4xT7k rejects the A19/M5 generations by their confirmed
    // hardware-family prefixes.  Keep the same rule in every consumer.
    return machine.hasPrefix("iPhone18,") || machine.hasPrefix("iPad17,")
}

func axDeviceSupportStatus() -> AXDeviceSupportStatus {
    let identifier = devicemachine()
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let name = DeviceMarketingName.name(for: identifier)

    if v.majorVersion < 16 {
        return AXDeviceSupportStatus(identifier: identifier, marketingName: name,
                                     systemVersion: v, isSupported: false,
                                     reason: "系统版本低于 iOS 16.0")
    }

    // AX 1.2.8 has two supported system families: 16.0...18.7.1 and
    // 26.0...26.0.1.  18.7.2, 26.0.2 and 26.1 are explicit binary gates.
    if v.majorVersion >= 19 && v.majorVersion <= 25 {
        return AXDeviceSupportStatus(identifier: identifier, marketingName: name,
                                     systemVersion: v, isSupported: false,
                                     reason: "系统版本不在 AX 1.2.8 支持范围")
    }
    if v.majorVersion > 26 {
        return AXDeviceSupportStatus(identifier: identifier, marketingName: name,
                                     systemVersion: v, isSupported: false,
                                     reason: "系统版本高于 iOS 26.0.1")
    }
    if v.majorVersion == 18 &&
        (v.minorVersion > 7 || (v.minorVersion == 7 && v.patchVersion >= 2)) {
        return AXDeviceSupportStatus(identifier: identifier, marketingName: name,
                                     systemVersion: v, isSupported: false,
                                     reason: "AX 1.2.8 仅支持到 iOS 18.7.1")
    }
    if v.majorVersion == 26 {
        if v.minorVersion > 0 || (v.minorVersion == 0 && v.patchVersion > 1) {
            return AXDeviceSupportStatus(identifier: identifier, marketingName: name,
                                         systemVersion: v, isSupported: false,
                                         reason: "AX 1.2.8 仅支持到 iOS 26.0.1")
        }
    }

    if hasmie() {
        return AXDeviceSupportStatus(identifier: identifier, marketingName: name,
                                     systemVersion: v, isSupported: false,
                                     reason: "A19/M5 及更新设备启用了不受支持的 MIE")
    }

    if isdebugged() {
        return AXDeviceSupportStatus(identifier: identifier, marketingName: name,
                                     systemVersion: v, isSupported: false,
                                     reason: "检测到调试器")
    }

    return AXDeviceSupportStatus(identifier: identifier, marketingName: name,
                                 systemVersion: v, isSupported: true, reason: nil)
}

func isunsupported() -> Bool {
    !axDeviceSupportStatus().isSupported
}
