//
//  RemoteView.swift
//  lara
//
//  Created by ruter on 17.04.26.
//

import SwiftUI
import Darwin

struct RemoteView: View {
    @ObservedObject var mgr: laramgr
    @State private var statusBarTimeFormat: String = "HH:mm"
    @State private var running: Bool = false
    @State private var columns: Int = 5
    @State private var performanceHUD: Int = -1
    @AppStorage("rcdockunlimited") private var rcdockunlimited: Bool = false
    @State private var customProcessName: String = "SpringBoard"
    @State private var customFunctionName: String = "getpid"
    @State private var customArgsText: String = ""
    @State private var customTimeoutMs: Int = 100
    @State private var customMigBypass: Bool = false
    @State private var customLastResult: String = ""
    @State private var hsRows: Int = 6
    @State private var hsColumns: Int = 4
    @State private var freakyrunning: Bool = false
    @State private var freakyseq: Int = 0

    private var dockMaxColumns: Int { rcdockunlimited ? 50 : 10 }

    var body: some View {
        List {
            Section {
                TextField("日期格式（例如 HH:mm）", text: $statusBarTimeFormat)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    run("状态栏时间格式") {
                        status_bar_time_format(mgr.sbProc, statusBarTimeFormat)
                        return "status_bar_time_format() 完成"
                    }
                } label: {
                    Text("应用")
                }
            } header: {
                Text("状态栏时间格式")
            } footer: {
                Text("文本每分钟自动更新")
            }

            Section {
                Button {
                    run("隐藏图标标签") {
                        let hidden = hide_icon_labels(mgr.sbProc)
                        return "hide_icon_labels() -> \(hidden)"
                    }
                } label: {
                    Text("隐藏图标标签")
                }
            } header: {
                Text("SpringBoard")
            }

            Section {
                Stepper(value: $hsColumns, in: 1...10) {
                    HStack {
                        Text("主屏幕列数")
                        Spacer()
                        Text("\(hsColumns)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                
                Stepper(value: $hsRows, in: 1...10) {
                    HStack {
                        Text("主屏幕行数")
                        Spacer()
                        Text("\(hsRows)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }

                Button {
                    run("修改主屏幕网格 \(hsColumns)x\(hsRows)") {
                        return patch_homescreen_grid(mgr.sbProc, Int32(hsColumns), Int32(hsRows))
                            ? "patch_homescreen_grid(\(hsColumns), \(hsRows)) -> ok"
                            : "patch_homescreen_grid(\(hsColumns), \(hsRows)) -> failed"
                    }
                } label: {
                    Text("应用主屏幕网格")
                }
            }

            Section {
                Stepper(value: $columns, in: 1...dockMaxColumns) {
                    HStack {
                        Text("Dock 列数")
                        Spacer()
                        Text("\(columns)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                .onChange(of: rcdockunlimited) { _ in
                    if !rcdockunlimited, columns > 10 {
                        columns = 10
                    }
                }

                Button {
                    run("应用 Dock 列数=\(columns)") {
                        let result = set_dock_icon_count(mgr.sbProc, Int32(columns))
                        return result == 0
                            ? "set_dock_icon_count(\(columns)) -> ok"
                            : "set_dock_icon_count(\(columns)) -> failed (\(result))"
                    }
                } label: {
                    Text("应用 Dock 列数")
                }
            }

            Section {
                Button {
                    run("启用上下颠倒") {
                        let result = enable_upside_down(mgr.sbProc)
                        return result == 0
                            ? "enable_upside_down() -> ok"
                            : "enable_upside_down() -> failed (\(result))"
                    }
                } label: {
                    Text("启用上下颠倒")
                }
            }

            Section {
                Button {
                    run("启用浮动 Dock") {
                        let result = enable_floating_dock(mgr.sbProc)
                        return result == 0
                            ? "enable_floating_dock() -> ok"
                            : "enable_floating_dock() -> failed (\(result))"
                    }
                } label: {
                    Text("启用浮动 Dock")
                }
                
                Button {
                    run("启用网格 App 切换器") {
                        let result = enable_grid_app_switcher(mgr.sbProc)
                        return result == 0
                            ? "enable_grid_app_switcher() -> ok"
                            : "enable_grid_app_switcher() -> failed (\(result))"
                    }
                } label: {
                    Text("启用网格 App 切换器（动画异常）")
                }
                
                Button {
                    run("启用 UIKit 调试叠加层") {
                        let result = enable_debug_overlay(mgr.sbProc)
                        return result == 0
                            ? "enable_debug_overlay() -> ok"
                            : "enable_debug_overlay() -> failed (\(result))"
                    }
                } label: {
                    Text("启用 UIKit 调试叠加层")
                }

                /*
                Button {
                    togglefreakydog()
                } label: {
                    Text(freakyrunning ? "Stop Freaky Dog Overlay" : "Start Freaky Dog Overlay")
                }
                */
            } footer: {
                Text("要使用 UIKit 调试叠加层，请双击状态栏。")
            }
            
            Section {
                Picker("性能 HUD", selection: $performanceHUD) {
                    Text("关闭").tag(-1)
                    Text("基础").tag(0)
                    Text("背景层").tag(1)
                    Text("粒子").tag(2)
                    Text("完整").tag(3)
                    Text("功耗").tag(5)
                    Text("EDR").tag(7)
                    Text("故障").tag(8)
                    Text("GPU 时间").tag(9)
                    Text("内存带宽").tag(10)
                }
                .onChange(of: performanceHUD) { newValue in
                    set_performance_hud(mgr.sbProc, Int32(newValue))
                }
                .onAppear {
                    if mgr.rcrunning {
                        performanceHUD = Int(get_performance_hud(mgr.sbProc))
                    }
                }
            } footer: {
                Text("这些操作通过 RemoteCall 调用 SpringBoard。运行期间请保持 RemoteCall 已初始化。")
                
                if !mgr.rcready {
                    Text("RemoteCall 尚未初始化。你是怎么来到这里的？")
                }
            }
            .disabled(!mgr.rcready || running)
            
            if #available(iOS 17.4, *) {
                Section {
                    Button {
                        mgr.rcinitDaemon(serviceName: "com.apple.xpc.amsaccountsd", process: "amsaccountsd", migbypass: false) { proc in
                            guard let proc else {
                                mgr.logmsg("远程调用初始化失败")
                                return
                            }
                            mgr.logmsg("远程调用初始化成功！")
                            mgr.eligibilitystate = euenabler_overwrite_eligibility(proc) == 0
                            mgr.logmsg("overwrite_eligibility() 返回：\(mgr.eligibilitystate! ? "成功" : "失败")")
                            proc.destroy()
                        }
                    } label: {
                        HStack {
                            Text("覆盖资格（一次性设置）")
                            if let state = mgr.eligibilitystate {
                                Spacer()
                                if state {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundColor(.green)
                                } else {
                                    Image(systemName: "xmark.circle")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .disabled(mgr.eligibilitystate ?? false)
                    
                    Button {
                        mgr.eu1progress = 0.0
                        mgr.eu2progress = 0.0
                        mgr.eu1running = true
                        mgr.eu2running = true
                        mgr.rcinitDaemon(serviceName: "com.apple.managedappdistributiond.xpc", process: "managedappdistributiond", migbypass: false) { proc in
                            guard let proc else {
                                mgr.logmsg("远程调用初始化失败")
                                mgr.eu1running = false
                                return
                            }
                            mgr.logmsg("远程调用初始化成功！")
                            euenabler_override_country_code(proc) { progress in
                                DispatchQueue.main.async {
                                    self.mgr.eu1progress = progress
                                }
                            }
                            proc.destroy()
                            DispatchQueue.main.async {
                                mgr.eu1running = false
                            }
                        }
                        // fix unable to load app info
                        mgr.rcinitDaemon(serviceName: "com.apple.appstorecomponentsd.xpc", process: "appstorecomponentsd", migbypass: false) { proc in
                            guard let proc else {
                                mgr.logmsg("远程调用初始化失败")
                                mgr.eu2running = false
                                return
                            }
                            mgr.logmsg("远程调用初始化成功！")
                            euenabler_override_country_code(proc) { progress in
                                DispatchQueue.main.async {
                                    self.mgr.eu2progress = progress
                                }
                            }
                            proc.destroy()
                            DispatchQueue.main.async {
                                mgr.eu2running = false
                            }
                        }
                    } label: {
                        HStack {
                            if mgr.eu1running || mgr.eu2running {
                                ProgressView(value: (mgr.eu1progress + mgr.eu2progress)/2)
                                    .progressViewStyle(.circular)
                                    .frame(width: 18, height: 18)
                                Text("正在运行…")
                                Spacer()
                                Text("\(Int((mgr.eu1progress + mgr.eu2progress)/2 * 100))%")
                            } else {
                                Text("启用伪装欧盟地区")
                                Spacer()
                                if mgr.eu1progress + mgr.eu2progress == 2 {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundColor(.green)
                                } else if mgr.dsattempted && mgr.dsfailed {
                                    Image(systemName: "xmark.circle")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .disabled(mgr.eu1running || mgr.eu2running || mgr.eu1progress+mgr.eu2progress == 2)
                } footer: {
                    Text("允许安装欧盟/日本市场的应用。")
                }
                .disabled(isdebugged() || mgr.rcrunning || !mgr.rcready)
            }
            
            Section {
                Button {
                    youtube_tweak(mgr.ytProc)
                } label: {
                    Text("通用 Youtube 调整")
                }
            }
            
            Section {
                Button {
                    _ = mgr.rccall(name: "exit", args: [0], timeout: 100)
                } label: {
                    Text("注销重启")
                }
            } header: {
                Text("工具")
            }
            
            Section {
                TextField("进程名称", text: $customProcessName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    TextField("函数（符号或 0x 地址）", text: $customFunctionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1)
                    
                    TextEditor(text: $customArgsText)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Stepper(value: $customTimeoutMs, in: 10...5000, step: 10) {
                    HStack {
                        Text("超时")
                        Spacer()
                        Text("\(customTimeoutMs) 毫秒")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }

                Toggle("MIG 过滤器绕过", isOn: $customMigBypass)

                Button {
                    run("自定义 RemoteCall \(customProcessName):\(customFunctionName)") {
                        let process = customProcessName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let function = customFunctionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !process.isEmpty else { return "自定义：缺少进程名称" }
                        guard !function.isEmpty else { return "自定义：缺少函数名称" }

                        let (args, parseError) = parseRemoteCallArgs(customArgsText)
                        if let parseError {
                            return "自定义：参数解析错误：\(parseError)"
                        }

                        let ptr: UnsafeMutableRawPointer?
                        if let addr = parseAddress(function) {
                            ptr = UnsafeMutableRawPointer(bitPattern: UInt(addr))
                        } else {
                            let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
                            ptr = function.withCString { dlsym(RTLD_DEFAULT, $0) }
                        }

                        guard let ptr else {
                            return "custom: failed to resolve \(function)"
                        }

                        guard let proc = RemoteCall(process: process, useMigFilterBypass: customMigBypass) else {
                            return "自定义：\(process) 的 RemoteCall 初始化失败"
                        }
                        defer { proc.destroy() }

                        var argsCopy = args
                        let ret = function.withCString { (cName: UnsafePointer<CChar>) -> UInt64 in
                            UInt64(argsCopy.withUnsafeMutableBufferPointer { buffer in
                                proc.doStable(
                                    withTimeout: Int32(customTimeoutMs),
                                    functionName: UnsafeMutablePointer(mutating: cName),
                                    functionPointer: ptr,
                                    args: buffer.baseAddress,
                                    argCount: UInt(args.count)
                                )
                            })
                        }

                        let err = proc.lastError ?? ""
                        let suffix = err.isEmpty ? "" : " (err: \(err))"
                        return "custom: \(process) \(function)(\(args.count) args) -> 0x\(String(ret, radix: 16)) / \(ret)\(suffix)"
                    } onComplete: { msg in
                        self.customLastResult = msg
                    }
                } label: {
                    Text("调用")
                }

                if !customLastResult.isEmpty {
                    Text(customLastResult)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("自定义 RemoteCall")
            } footer: {
                Text("调用符号（通过 dlsym）或绝对地址。数字参数依次传入 x0-x7，之后通过栈传递。")
            }
            .disabled(!mgr.rcready || running)

            

            Section {
                HStack(alignment: .top) {
                    AsyncImage(url: URL(string: "https://github.com/khanhduytran0.png")) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    
                    VStack(alignment: .leading) {
                        Text("Duy Tran")
                            .font(.headline)
                        
                        Text("负责 RemoteCall 相关的大部分工作。")
                            .font(.subheadline)
                            .foregroundColor(Color.secondary)
                    }
                    
                    Spacer()
                }
                .onTapGesture {
                    if let url = URL(string: "https://github.com/khanhduytran0"),
                       UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    }
                }
                
                HStack(alignment: .top) {
                    AsyncImage(url: URL(string: "https://github.com/zeroxjf.png")) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    
                    VStack(alignment: .leading) {
                        Text("0xjf")
                            .font(.headline)
                        
                        Text("Powercuff and SBCustomizer")
                            .font(.subheadline)
                            .foregroundColor(Color.secondary)
                    }
                    
                    Spacer()
                }
                .onTapGesture {
                    if let url = URL(string: "https://github.com/zeroxjf"),
                       UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    }
                }
                
                HStack(alignment: .top) {
                    AsyncImage(url: URL(string: "https://github.com/Scr-eam.png")) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    
                    VStack(alignment: .leading) {
                        Text("Scream")
                            .font(.headline)
                        
                        Text("修复了隐藏图标标签")
                            .font(.subheadline)
                            .foregroundColor(Color.secondary)
                    }
                    
                    Spacer()
                }
                .onTapGesture {
                    if let url = URL(string: "https://github.com/Scr-eam"),
                       UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("致谢")
            }
        }
        .navigationTitle(Text("调整"))
        .onDisappear {
            if freakyrunning, let proc = mgr.sbProc {
                stopfreakydog(proc)
            }
        }
    }

    private func run(_ name: String, _ work: @escaping () -> String, onComplete: ((String) -> Void)? = nil) {
        guard mgr.rcready, !running else { return }
        running = true
        mgr.logmsg("(rc) \(name)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.mgr.logmsg("(rc) \(result)")
                onComplete?(result)
                if self.isRemoteCallFailure(result) {
                    Alertinator.shared.alert(title: "\(name) 失败", body: result)
                }
                self.running = false
            }
        }
    }

    private func isRemoteCallFailure(_ result: String) -> Bool {
        let lowercased = result.lowercased()
        return lowercased.contains("-> -1") ||
            lowercased.contains("-> failed") ||
            lowercased.contains(": failed") ||
            lowercased.contains("failed to")
    }

    private func togglefreakydog() {
        guard mgr.rcready, let proc = mgr.sbProc else { return }

        if freakyrunning {
            stopfreakydog(proc)
            return
        }

        let view = enable_freaky_dog_overlay(proc)
        guard view != 0 else {
            mgr.logmsg("(rc) enable_freaky_dog_overlay() 失败")
            return
        }

        let seq = freakyseq + 1
        freakyseq = seq
        freakyrunning = true
        mgr.logmsg("(rc) enable_freaky_dog_overlay() -> 0x\(String(view, radix: 16))")

        let screen = UIScreen.main.bounds
        let maxw = max(Int(screen.width), 200)
        let maxh = max(Int(screen.height), 300)

        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let shouldcontinue = DispatchQueue.main.sync { () -> Bool in
                    self.freakyrunning && self.freakyseq == seq && self.mgr.rcready && self.mgr.sbProc != nil
                }
                if !shouldcontinue {
                    break
                }

                let size = Int.random(in: 110...220)
                let x = Int.random(in: 0...max(maxw - size, 0))
                let y = Int.random(in: 40...max(maxh - size, 40))
                let result = move_freaky_dog_overlay(proc, view, Int32(x), Int32(y), Int32(size), Int32(size))
                if result != 0 {
                    DispatchQueue.main.async {
                        self.mgr.logmsg("(rc) move_freaky_dog_overlay() 失败：\(result)")
                        self.stopfreakydog(proc)
                    }
                    break
                }

                usleep(UInt32.random(in: 25000...90000))
            }
        }
    }

    private func stopfreakydog(_ proc: RemoteCall) {
        freakyrunning = false
        freakyseq += 1
        let result = disable_freaky_dog_overlay(proc)
        mgr.logmsg("(rc) disable_freaky_dog_overlay() -> \(result)")
    }

    private func parseRemoteCallArgs(_ text: String) -> (args: [UInt64], error: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], nil) }

        let separators = CharacterSet(charactersIn: ", \t\r\n")
        let tokens = trimmed
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [UInt64] = []
        out.reserveCapacity(tokens.count)

        for token in tokens {
            if let value = parseUInt64OrInt64BitPattern(token) {
                out.append(value)
            } else {
                return ([], "无效的令牌 '\(token)'")
            }
        }

        return (out, nil)
    }

    private func parseUInt64OrInt64BitPattern(_ token: String) -> UInt64? {
        if token.hasPrefix("-") {
            let rest = String(token.dropFirst())
            if rest.lowercased().hasPrefix("0x") {
                let hex = String(rest.dropFirst(2))
                guard let magnitude = UInt64(hex, radix: 16) else { return nil }
                let signed = -Int64(bitPattern: magnitude)
                return UInt64(bitPattern: signed)
            } else {
                guard let signed = Int64(rest) else { return nil }
                return UInt64(bitPattern: -signed)
            }
        }

        if token.lowercased().hasPrefix("0x") {
            return UInt64(token.dropFirst(2), radix: 16)
        }

        return UInt64(token)
    }

    private func parseAddress(_ functionField: String) -> UInt64? {
        let s = functionField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("0x") else { return nil }
        guard let value = UInt64(s.dropFirst(2), radix: 16) else { return nil }
        guard value <= UInt64(UInt.max) else { return nil }
        return value
    }
}
