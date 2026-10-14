import AppKit
import MySQLKit
import SwiftUI

@main
struct MySQLManagerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MySQL Manager", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    delegate.model = model
                    model.runBenchmarkHooks()
                }
        }
        .defaultSize(width: 1360, height: 860)
        .commands { AppCommands(model: model) }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建连接") { model.sheet = .connection(ConnectionEditorRequest(config: nil)) }
                .keyboardShortcut("n")
            Button("新建查询") { model.newQuery() }
                .keyboardShortcut("t")
        }
        CommandMenu("查询") {
            Button("运行") { model.runActiveQuery(currentStatement: false) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("运行当前语句") { model.runActiveQuery(currentStatement: true) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("停止") { model.stopActiveQuery() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("运行 / 刷新数据") { model.runOrRefresh() }
                .keyboardShortcut("r")
        }
        CommandGroup(after: .toolbar) {
            Button("切换主题") { model.toggleTheme() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
        }
    }
}

extension AppModel {
    func runActiveQuery(currentStatement: Bool) {
        guard case let .query(m) = activeTab else { return }
        Task { await m.run(currentStatement ? m.editor.currentStatement() : nil) }
    }

    func stopActiveQuery() {
        if case let .query(m) = activeTab { m.stop() }
    }

    /// ⌘R: run in a query tab, reload in a table tab.
    func runOrRefresh() {
        switch activeTab {
        case let .query(m): Task { await m.run() }
        case let .data(m): Task { await m.reload() }
        case let .design(m): Task { await m.load() }
        case nil: break
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` (no .app bundle) starts as a background process
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        // ⌘W closes the current tab while there are tabs, then the window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  e.charactersIgnoringModifiers == "w",
                  let model = self?.model, let id = model.activeTabID,
                  e.window?.isSheet == false, e.window?.attachedSheet == nil
            else { return e }
            Task { await model.requestCloseTab(id) }
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
