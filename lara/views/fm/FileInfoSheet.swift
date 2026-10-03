//
//  FileInfoSheet.swift
//  lara
//
//  Created by lunginspector on 5/22/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct FileInfoProperties {
    var id = UUID()
    var fileExists: Bool
    var kind: String
    var uttype: String
    var size: Int
    var created: String
    var modified: String
    var isSymlink: Bool
    var posixPerms: String
    var owner: String
    var group: String
    var readable: Bool
    var writable: Bool
    var executable: Bool
}

struct infosheetcontent: View {
    let entry: santanderitem
    @State private var fileInfo: FileInfoProperties?
    
    var body: some View {
        Group {
            if let info = fileInfo {
                santanderinfosheet(name: entry.name, file: info)
            } else {
                ProgressView()
                    .onAppear {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let info = santanderfs.fileDetails(path: entry.path)
                            DispatchQueue.main.async {
                                fileInfo = info
                            }
                        }
                    }
            }
        }
    }
}

struct santanderinfosheet: View {
    @Environment(\.dismiss) var dismiss
    
    var name: String
    var file: FileInfoProperties
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: file.kind == "directory" ? "folder" : "doc")
                        VStack(alignment: .leading) {
                            Text(name)
                            if file.kind == "file" {
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                Section(header: HeaderLabel(text: "文件信息", icon: "info.circle")) {
                    LabeledContent("UTType") {
                        Text(file.uttype)
                    }
                    LabeledContent("创建日期") {
                        Text(file.created)
                    }
                    LabeledContent("最后修改时间") {
                        Text(file.modified)
                    }
                    LabeledContent("符号链接") {
                        Image(systemName: file.isSymlink ? "checkmark" : "xmark")
                    }
                }
                
                Section(header: HeaderLabel(text: "权限", icon: "shield")) {
                    LabeledContent("POSIX 权限") {
                        Text(file.posixPerms)
                    }
                    LabeledContent("所有者") {
                        Text(file.owner)
                    }
                    LabeledContent("所属组") {
                        Text(file.group)
                    }
                    LabeledContent("可读") {
                        Image(systemName: file.readable ? "checkmark" : "xmark")
                    }
                    LabeledContent("可写") {
                        Image(systemName: file.writable ? "checkmark" : "xmark")
                    }
                    LabeledContent("可执行") {
                        Image(systemName: file.executable ? "checkmark" : "xmark")
                    }
                }
            }
            .navigationTitle("文件信息")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
}

struct santandernamesheet: View {
    let title: String
    let itemname: String
    let placeholder: String
    let actiontitle: String
    let apply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(itemname) {
                    TextField(placeholder, text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if name.isEmpty {
                    name = placeholder
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(actiontitle) {
                        apply(name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct santandernewfilesheet: View {
    let itemname: String
    let apply: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = "untitled.txt"
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(itemname) {
                    TextField("文件名", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("内容") {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle("创建文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") {
                        apply(name, text)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct santanderchmodsheet: View {
    let item: santanderitem
    let apply: (UInt16) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(item.name) {
                    TextField("例如 755", text: $text)
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle("Chmod")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用") {
                        guard let mode = UInt16(text, radix: 8) else { return }
                        apply(mode)
                        dismiss()
                    }
                    .disabled(UInt16(text, radix: 8) == nil)
                }
            }
        }
    }
}

struct santanderchownsheet: View {
    let item: santanderitem
    let apply: (UInt32, UInt32) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var uid = ""
    @State private var gid = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(item.name) {
                    TextField("UID（例如 501）", text: $uid)
                        .keyboardType(.numberPad)
                    TextField("GID（例如 501）", text: $gid)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Chown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用") {
                        guard let uid = UInt32(uid), let gid = UInt32(gid) else { return }
                        apply(uid, gid)
                        dismiss()
                    }
                    .disabled(UInt32(uid) == nil || UInt32(gid) == nil)
                }
            }
        }
    }
}

struct santanderfiledoc: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let data = configuration.file.regularFileContents ?? Data()
        try data.write(to: tmp)
        self.url = tmp
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: url, options: .immediate)
    }
}
