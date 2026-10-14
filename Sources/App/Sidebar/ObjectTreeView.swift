import MySQLKit
import SwiftUI

struct ObjectTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)

            if model.roots.isEmpty {
                VStack(spacing: 10) {
                    Text("还没有连接").foregroundStyle(.secondary)
                    Button("新建连接") { model.sheet = .connection(ConnectionEditorRequest(config: nil)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedNodeID) {
                    ForEach(TreeFilter(model.search).visible(model.roots)) { TreeRow(node: $0) }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let n = model.node(id) {
                        TreeMenu(node: n)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let n = model.node(id) { model.activate(n) }
                }
            }
        }
    }
}

/// Search: show nodes whose label matches, with their ancestors.
struct TreeFilter {
    let pattern: String

    init(_ pattern: String) {
        self.pattern = pattern.trimmingCharacters(in: .whitespaces)
    }

    var isActive: Bool { !pattern.isEmpty }

    func matches(_ n: TreeNode) -> Bool {
        n.label.localizedCaseInsensitiveContains(pattern) || (n.children ?? []).contains(where: matches)
    }

    func visible(_ list: [TreeNode]) -> [TreeNode] {
        isActive ? list.filter(matches) : list
    }
}

private struct TreeRow: View {
    @Environment(AppModel.self) private var model
    let node: TreeNode

    var body: some View {
        let filter = TreeFilter(model.search)
        if node.isExpandable {
            DisclosureGroup(isExpanded: expanded(filter)) {
                ForEach(filter.visible(node.children ?? [])) { TreeRow(node: $0) }
            } label: {
                NodeLabel(node: node)
            }
            .tag(node.id)
        } else {
            NodeLabel(node: node).tag(node.id)
        }
    }

    private func expanded(_ filter: TreeFilter) -> Binding<Bool> {
        Binding {
            filter.isActive && (node.children ?? []).contains(where: filter.matches) ? true : node.isExpanded
        } set: { open in
            model.setExpanded(node, open)
        }
    }
}

private struct NodeLabel: View {
    @Environment(AppModel.self) private var model
    let node: TreeNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(node.label)
                .lineLimit(1)
                .truncationMode(.middle)
            if node.isLoading {
                Spacer()
                ProgressView().controlSize(.mini)
            }
        }
        .help(tooltip)
    }

    private var icon: String {
        switch node.kind {
        case .connection: "server.rack"
        case .database: "cylinder.split.1x2"
        case .tables, .views: "folder"
        case .table: "tablecells"
        case .view: "eye"
        }
    }

    private var color: Color {
        switch node.kind {
        case .connection:
            model.isOpen(node.connID) ? (Color(hex: model.connection(node.connID)?.color) ?? .mmGreen) : .secondary
        case .database: .mmOrange
        case .tables, .views: .secondary
        case .table: .mmBlue
        case .view: .mmPurple
        }
    }

    private var tooltip: String {
        switch node.kind {
        case .connection:
            if let v = model.opened[node.connID] { return "MySQL \(v)" }
            guard let c = model.connection(node.connID) else { return "" }
            return "\(c.user)@\(c.host):\(c.port)"
        case .table, .view:
            return node.info?.comment.flatMap { $0.isEmpty ? nil : $0 } ?? node.label
        default:
            return node.label
        }
    }
}

private struct TreeMenu: View {
    @Environment(AppModel.self) private var model
    let node: TreeNode

    var body: some View {
        switch node.kind {
        case .connection:
            let open = model.isOpen(node.connID)
            item(open ? "关闭连接" : "打开连接", open ? .close : .open)
            item("新建查询", .query)
            Divider()
            item("新建数据库", .createDatabase).disabled(!open)
            item("运行 SQL 文件", .runSQL).disabled(!open)
            item("刷新", .refresh).disabled(!open)
            Divider()
            item("编辑连接", .editConnection)
            item("复制连接", .copyConnection)
            item("删除连接", .deleteConnection)
        case .database:
            item("关闭数据库", .closeDatabase).disabled(node.children == nil)
            item("新建查询", .query)
            item("新建表", .createTable)
            Divider()
            item("运行 SQL 文件", .runSQL)
            item("转储 SQL 文件", .dump)
            Divider()
            item("刷新", .refresh)
            item("删除数据库", .dropDatabase)
        case .tables:
            item("新建表", .createTable)
            item("刷新", .refresh)
        case .views:
            item("刷新", .refresh)
        case .table:
            item("打开表", .openTable)
            item("设计表", .design)
            item("新建查询", .query)
            Divider()
            item("导出数据", .export)
            item("导入 CSV", .importCSV)
            item("转储 SQL 文件", .dumpTable)
            Divider()
            item("复制表（结构）", .duplicate(withData: false))
            item("复制表（结构和数据）", .duplicate(withData: true))
            item("重命名", .rename)
            item("清空表", .truncate)
            item("删除表", .drop)
            Divider()
            item("复制表名", .copyName)
            item("刷新", .refresh)
        case .view:
            item("打开视图", .openTable)
            item("查看定义", .viewDDL)
            item("导出数据", .export)
            Divider()
            item("删除视图", .drop)
        }
    }

    private func item(_ title: String, _ action: TreeAction) -> some View {
        Button(title) {
            Task { await model.perform(action, on: node) }
        }
    }
}
