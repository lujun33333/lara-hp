//
//  CreditsView.swift
//  lara
//
//  Created by lunginspector on 5/9/26.
//

import SwiftUI

struct CreditsView: View {
    var body: some View {
        NavigationStack {
            List {
                LinkCreditCell(name: "roooot", description: "主要开发者", url: "https://github.com/rooootdev") {
                    LinkCreditIcon(url: "https://github.com/rooootdev.png")
                }
                LinkCreditCell(name: "wh1te4ever", description: "制作了 darksword-kexploit-fun", url: "https://github.com/wh1te4ever") {
                    LinkCreditIcon(url: "https://github.com/wh1te4ever.png")
                }
                LinkCreditCell(name: "Duy Tran", description: "各种 remotecall 相关改进和功能", url: "https://github.com/khanhduytran0") {
                    LinkCreditIcon(url: "https://github.com/khanhduytran0.png")
                }
                LinkCreditCell(name: "AppInstalleriOS", description: "帮助我处理偏移量和其他许多工作", url: "https://github.com/AppInstalleriOSGH") {
                    LinkCreditIcon(url: "https://github.com/AppInstalleriOSGH.png")
                }
                LinkCreditCell(name: "jailbreak.party", description: "dirtyZero 修改", url: "https://github.com/jailbreakdotparty") {
                    LinkCreditIcon(url: "https://github.com/jailbreakdotparty.png")
                }
                LinkCreditCell(name: "lunginspector", description: "前端重构", url: "https://github.com/lunginspector") {
                    LinkCreditIcon(url: "https://github.com/lunginspector.png")
                }
                LinkCreditCell(name: "Jurre", description: "EditorView、PocketPoster 助手、各种改进", url: "https://github.com/jurre111") {
                    LinkCreditIcon(url: "https://github.com/jurre111.png")
                }
                LinkCreditCell(name: "neon", description: "Respring 脚本、zipmgr、修复密码主题以及添加应用解密", url: "https://github.com/neonmodder123") {
                    LinkCreditIcon(url: "https://github.com/neonmodder123.png")
                }
                LinkCreditCell(name: "Skadz", description: "Respring 方法", url: "https://github.com/skadz108") {
                    LinkCreditIcon(url: "https://github.com/skadz108.png")
                }
                LinkCreditCell(name: "hxhlb", description: "各种错误修复", url: "https://github.com/hxhlb") {
                    LinkCreditIcon(url: "https://github.com/hxhlb.png")
                }
                LinkCreditCell(name: "leminlimez", description: "各种 Cowabunga 修改", url: "https://github.com/leminlimez") {
                    LinkCreditIcon(url: "https://github.com/leminlimez.png")
                }
            }
            .navigationTitle("致谢")
        }
    }
}
