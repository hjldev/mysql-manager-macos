import AppKit
import MySQLKit
import SwiftUI

/// Run blocking database work on a GCD thread (not the main thread, and not
/// the Swift concurrency pool, which must not be blocked).
nonisolated func onBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            cont.resume(with: Result(catching: work))
        }
    }
}

/// The user dismissed a prompt; not reported.
struct Cancelled: Error {}

/// Hand freed malloc pages back to the OS. Big short-lived allocations (result
/// sets) otherwise stay in the app's footprint until memory runs low.
func trimMemory(after delay: Duration = .seconds(1)) {
    Task {
        try? await Task.sleep(for: delay)
        malloc_zone_pressure_relief(nil, 0)
    }
}

// MARK: - Toasts

struct Toast: Identifiable, Equatable {
    enum Kind { case success, info, warning, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

struct ToastStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { t in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(t.kind))
                        .foregroundStyle(color(t.kind))
                    Text(t.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420, alignment: .leading)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .onTapGesture { model.dismissToast(t) }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 10)
        .animation(.easeOut(duration: 0.18), value: model.toasts)
    }

    private func icon(_ k: Toast.Kind) -> String {
        switch k {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ k: Toast.Kind) -> Color {
        switch k {
        case .success: .green
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

// MARK: - Combo box

/// Editable text field with a dropdown list (NSComboBox): pick a value or type one.
struct ComboField: NSViewRepresentable {
    @Binding var text: String
    var items: [String]
    var placeholder = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = false
        box.completes = true
        box.numberOfVisibleItems = 14
        box.controlSize = .small
        box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        box.delegate = context.coordinator
        box.placeholderString = placeholder
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.items != items {
            context.coordinator.items = items
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if box.stringValue != text && box.currentEditor() == nil {
            box.stringValue = text
        }
        box.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ComboField
        var items: [String] = []

        init(_ parent: ComboField) {
            self.parent = parent
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  box.indexOfSelectedItem < items.count else { return }
            parent.text = items[box.indexOfSelectedItem]
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.text = box.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.text = box.stringValue
        }
    }
}

// MARK: - Colors and fonts

extension Color {
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    static let mmGreen = Color(red: 0x18 / 255, green: 0xA0 / 255, blue: 0x58 / 255)
    static let mmOrange = Color(red: 0xF0 / 255, green: 0xA0 / 255, blue: 0x20 / 255)
    static let mmBlue = Color(red: 0x20 / 255, green: 0x80 / 255, blue: 0xF0 / 255)
    static let mmPurple = Color(red: 0x8A / 255, green: 0x5C / 255, blue: 0xF5 / 255)
}

extension Font {
    static let mono = Font.system(size: 12, design: .monospaced)
}

/// Monospaced, selectable SQL text block.
struct SQLText: View {
    let sql: String

    var body: some View {
        Text(sql)
            .font(.mono)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
    }
}

/// Small toolbar button with an icon and optional title.
struct ToolButton: View {
    let title: String
    let systemImage: String
    var showsTitle = true
    let action: () -> Void

    init(_ title: String, systemImage: String, showsTitle: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.showsTitle = showsTitle
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if showsTitle {
                Label(title, systemImage: systemImage)
            } else {
                Label(title, systemImage: systemImage).labelStyle(.iconOnly)
            }
        }
        .help(title)
    }
}

// MARK: - File panels

@MainActor
enum FilePanels {
    static func save(defaultName: String, extensions: [String]) -> String? {
        let p = NSSavePanel()
        p.nameFieldStringValue = defaultName
        p.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) }
        p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url?.path : nil
    }

    static func open(extensions: [String]) -> String? {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) }
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

// MARK: - Constants shared with the Tauri UI

enum MySQLTypes {
    static let all = [
        "tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "float", "double", "bit",
        "char", "varchar", "tinytext", "text", "mediumtext", "longtext",
        "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob",
        "date", "datetime", "timestamp", "time", "year",
        "enum", "set", "json", "boolean",
        "geometry", "point", "linestring", "polygon",
    ]
    static let engines = ["InnoDB", "MyISAM", "MEMORY", "CSV", "ARCHIVE"]
    static let fkRules = ["RESTRICT", "CASCADE", "SET NULL", "NO ACTION"]
    static let indexKinds = ["PRIMARY", "UNIQUE", "INDEX", "FULLTEXT", "SPATIAL"]
}
