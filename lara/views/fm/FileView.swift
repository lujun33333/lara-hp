//
//  FileView.swift
//  lara
//
//  Created by lunginspector on 5/22/26.
//

import SwiftUI
import _AVKit_SwiftUI

enum santanderpreview {
    case loading
    case text(String, Bool)
    case image(UIImage)
    case media(URL)
    case error(String)
}

struct santanderfileview: View {
    let item: santanderitem
    let readsbx: Bool
    let writevfs: Bool

    @State private var preview: santanderpreview = .loading
    @State private var editing = false
    @State private var editable = false
    @State private var text = ""
    @State private var original = ""
    @State private var query = ""
    @State private var msg: santandermsg?
    @State private var exporturl: URL?
    @State private var showexport = false

    var body: some View {
        Group {
            switch preview {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case let .text(value, canedit):
                if editing && canedit {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 4)
                } else {
                    ScrollView {
                        Text(highlighted(text: value, query: query))
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                }

            case let .image(img):
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                }

            case let .media(url):
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea(edges: .bottom)

            case let .error(err):
                ScrollView {
                    Text(err)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(item.name)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .onAppear {
            load()
        }
        .onDisappear {
            cleanup()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if caneditfile {
                    Button(editing ? "保存" : "编辑") {
                        if editing {
                            save()
                        } else {
                            startedit()
                        }
                    }
                }

                if exporturl != nil {
                    Button {
                        showexport = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .alert(item: $msg) { msg in
            Alert(title: Text(msg.title), message: Text(msg.text), dismissButton: .default(Text("确定")))
        }
        .fileExporter(
            isPresented: $showexport,
            document: santanderfiledoc(url: exporturl ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("empty")),
            contentType: item.type ?? .data,
            defaultFilename: item.name
        ) { result in
            if case .failure(let err) = result {
                msg = santandermsg(title: "导出失败", text: err.localizedDescription)
            }
        }
    }

    private var caneditfile: Bool {
        switch preview {
        case let .text(_, canedit):
            return canedit && (readsbx || writevfs)
        default:
            return false
        }
    }

    private func load() {
        preview = .loading
        let item = item
        let readsbx = readsbx

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = santanderfs.loadfile(item: item, readsbx: readsbx)
            let outurl = santanderfs.preparetemp(item: item, readsbx: readsbx, maxbytes: 128 * 1024 * 1024)

            DispatchQueue.main.async {
                preview = loaded.preview
                text = loaded.text
                original = loaded.text
                editable = loaded.editable
                exporturl = outurl
            }
        }
    }

    private func startedit() {
        guard editable else {
            msg = santandermsg(title: "编辑不可用", text: "此文件类型无法在查看器中编辑。")
            return
        }
        editing = true
        text = original
    }

    private func save() {
        let data: Data

        if item.path.hasSuffix(".plist") {
            do {
                let obj = try PropertyListSerialization.propertyList(
                    from: Data(text.utf8),
                    options: [],
                    format: nil
                )

                data = try PropertyListSerialization.data(
                    fromPropertyList: obj,
                    format: .binary,
                    options: 0
                )
            } catch {
                msg = santandermsg(
                    title: "保存失败",
                    text: "无效的 plist 格式。"
                )
                return
            }
        } else {
            data = Data(text.utf8)
        }
        
        let ok = santanderfs.writefile(path: item.path, data: data, readsbx: readsbx, writevfs: writevfs)
        if ok {
            editing = false
            original = text
            preview = .text(text, true)
            msg = santandermsg(title: "已保存", text: "文件已更新。")
            if !readsbx {
                exporturl = santanderfs.preparetemp(item: item, readsbx: readsbx, maxbytes: 128 * 1024 * 1024)
            }
        } else {
            msg = santandermsg(title: "保存失败", text: writevfs ? "VFS 覆盖失败。" : "无法写入文件。")
        }
    }

    private func highlighted(text: String, query: String) -> AttributedString {
        var out = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return out }

        var scan = text.startIndex..<text.endIndex
        while let found = text.range(of: q, options: [.caseInsensitive], range: scan, locale: .current) {
            if let lower = AttributedString.Index(found.lowerBound, within: out),
               let upper = AttributedString.Index(found.upperBound, within: out) {
                out[lower..<upper].backgroundColor = .yellow.opacity(0.35)
            }

            if found.upperBound == text.endIndex {
                break
            }
            scan = found.upperBound..<text.endIndex
        }
        return out
    }

    private func cleanup() {
        if case let .media(url) = preview, url.path.hasPrefix(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: url)
        }
        guard let exporturl else { return }
        if exporturl.path.hasPrefix(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: exporturl)
        }
    }
}

struct santanderloadedfile {
    let preview: santanderpreview
    let text: String
    let editable: Bool
}
