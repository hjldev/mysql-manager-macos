import MySQLKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ObjectTreeView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 290, max: 520)
        } detail: {
            WorkspaceView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.sheet = .connection(ConnectionEditorRequest(config: nil))
                } label: {
                    Label("新建连接", systemImage: "plus")
                }
                .help("新建连接 (⌘N)")
                Button {
                    model.newQuery()
                } label: {
                    Label("新建查询", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("新建查询 (⌘T)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleTheme()
                } label: {
                    Label("切换主题", systemImage: model.isDark ? "sun.max" : "moon")
                }
                .help("切换主题")
            }
        }
        .overlay(alignment: .top) { ToastStack() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case let .connection(r): ConnectionDialog(request: r)
            case let .prompt(r): PromptSheet(request: r)
            case let .export(t): ExportDialog(target: t)
            case let .dump(t): DumpDialog(target: t)
            case let .importCSV(t): ImportDialog(target: t)
            case let .runSQL(t): RunSQLFileDialog(target: t)
            }
        }
    }
}

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.tabs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("双击左侧的表打开数据，或右键新建查询")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                TabStrip()
                Divider()
                // every tab stays alive (scroll position, selection, editor undo);
                // only the active one is visible
                ZStack {
                    ForEach(model.tabs) { tab in
                        let active = tab.id == model.activeTabID
                        TabBody(tab: tab)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                            .zIndex(active ? 1 : 0)
                    }
                }
            }
        }
    }
}

private struct TabBody: View {
    let tab: WorkTab

    var body: some View {
        switch tab {
        case let .query(m): QueryTabView(model: m)
        case let .data(m): TableDataView(model: m)
        case let .design(m): TableDesignView(model: m)
        }
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs) { tab in
                        TabButton(tab: tab, selected: tab.id == model.activeTabID)
                            .id(tab.id)
                        Divider()
                    }
                }
            }
            .onChange(of: model.activeTabID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .frame(height: 30)
        .background(.bar)
    }
}

private struct TabButton: View {
    @Environment(AppModel.self) private var model
    let tab: WorkTab
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let content = tab.content
        HStack(spacing: 6) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(content.title + (content.dirty ? "*" : ""))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220)
            Button {
                Task { await model.requestCloseTab(tab.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(selected || hover ? 1 : 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
        .overlay(alignment: .top) {
            if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.activeTabID = tab.id }
        .onHover { hover = $0 }
        .help(content.title)
    }
}
