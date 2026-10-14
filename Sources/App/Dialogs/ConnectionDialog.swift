import MySQLKit
import SwiftUI

struct ConnectionDialog: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    private let isEdit: Bool
    @State private var form: ConnectionConfig
    @State private var password = ""
    @State private var testing = false
    @State private var saving = false
    @State private var error = ""

    private static let swatches = ["#18a058", "#2080f0", "#f0a020", "#d03050", "#8a5cf5"]

    init(request: ConnectionEditorRequest) {
        isEdit = !(request.config?.id ?? "").isEmpty
        _form = State(initialValue: request.config ?? ConnectionConfig())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEdit ? "编辑连接" : "新建连接 - MySQL").font(.headline)
            Form {
                TextField("连接名", text: $form.name, prompt: Text("例如 本地 MySQL"))
                TextField("主机", text: $form.host)
                TextField("端口", value: $form.port, format: .number.grouping(.never))
                    .frame(width: 220)
                TextField("用户名", text: $form.user)
                SecureField("密码", text: $password, prompt: Text(isEdit ? "留空表示不修改" : ""))
                Toggle("保存密码", isOn: $form.savePassword)
                TextField("默认数据库", text: Binding(get: { form.database ?? "" }, set: { form.database = $0 }),
                          prompt: Text("可选"))
                Toggle("使用 SSL（不校验证书）", isOn: $form.ssl)
                LabeledContent("颜色") {
                    HStack(spacing: 6) {
                        ForEach(Self.swatches, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex)!)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.primary.opacity(form.color == hex ? 0.8 : 0), lineWidth: 2))
                                .onTapGesture { form.color = hex }
                        }
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: form.color) ?? .mmGreen },
                            set: { form.color = $0.hexString }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        Button("清除") { form.color = nil }
                            .buttonStyle(.borderless)
                            .disabled(form.color == nil)
                    }
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button {
                    Task { await test() }
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("测试连接") }
                }
                .disabled(testing)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("保存") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func payload() -> ConnectionConfig {
        var f = form
        if f.name.trimmingCharacters(in: .whitespaces).isEmpty { f.name = "\(f.host):\(f.port)" }
        // for edits, an empty password means "keep the stored one"
        f.password = isEdit && password.isEmpty ? nil : password
        if f.database?.isEmpty == true { f.database = nil }
        return f
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let db = app.db, cfg = payload()
        do {
            let version = try await onBackground { try db.testConnection(cfg) }
            app.toast(.success, "连接成功，MySQL \(version)")
        } catch {
            app.report(error)
        }
    }

    private func save() async {
        let cfg = payload()
        if cfg.host.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "请输入主机"
            return
        }
        if cfg.user.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "请输入用户名"
            return
        }
        saving = true
        defer { saving = false }
        do {
            let saved = try await app.saveConnection(cfg)
            if isEdit && app.isOpen(saved.id) {
                // reconnect with the new settings on next expand
                app.closeTabs { $0.connID == saved.id }
                await app.closeConnection(saved.id)
            }
            dismiss()
            app.toast(.success, "已保存")
        } catch {
            app.report(error)
        }
    }
}

struct PromptSheet: View {
    @Environment(AppModel.self) private var app
    let request: PromptRequest
    @State private var value: String
    @FocusState private var focused: Bool

    init(request: PromptRequest) {
        self.request = request
        _value = State(initialValue: request.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.headline)
            if !request.label.isEmpty {
                Text(request.label).foregroundStyle(.secondary)
            }
            Group {
                if request.password {
                    SecureField("", text: $value)
                } else {
                    TextField("", text: $value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { finish(value) }
            HStack {
                Spacer()
                Button("取消") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("确定") { finish(value) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
        .onDisappear { request.resolve(nil) }
    }

    private func finish(_ v: String?) {
        request.resolve(v)
        app.sheet = nil
    }
}
