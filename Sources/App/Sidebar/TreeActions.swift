import AppKit
import MySQLKit

enum TreeAction {
    case open, close, closeDatabase, query, refresh
    case editConnection, copyConnection, deleteConnection
    case createDatabase, dropDatabase, createTable, runSQL, dump
    case openTable, design, viewDDL, export, importCSV, dumpTable
    case duplicate(withData: Bool), rename, truncate, drop, copyName
}

extension AppModel {
    /// Double-click / Return on a tree row.
    func activate(_ node: TreeNode) {
        switch node.kind {
        case .table, .view:
            openTableData(connID: node.connID, db: node.db!, table: node.table!, isView: node.kind == .view)
        default:
            if node.isExpandable { setExpanded(node, !node.isExpanded) }
        }
    }

    func perform(_ action: TreeAction, on n: TreeNode) async {
        let db = self.db
        let connID = n.connID
        let dbName = n.db ?? ""
        let table = n.table ?? ""
        do {
            switch action {
            case .open:
                setExpanded(n, true)
            case .close:
                guard await closeTabsConfirming(where: { $0.connID == connID }) else { return }
                await closeConnection(connID)
            case .closeDatabase:
                guard await closeTabsConfirming(where: { $0.connID == connID && $0.db == dbName }) else { return }
                collapseDatabase(connID, dbName)
            case .query:
                openQuery(connID: connID, db: n.db)
            case .refresh:
                if n.kind == .connection {
                    await refreshConnection(connID)
                } else {
                    await refreshDatabase(connID, dbName)
                }
            case .editConnection:
                sheet = .connection(ConnectionEditorRequest(config: connection(connID)))
            case .copyConnection:
                if var c = connection(connID) {
                    c.id = ""
                    c.name += " 副本"
                    sheet = .connection(ConnectionEditorRequest(config: c))
                }
            case .deleteConnection:
                guard await confirm("删除连接", "确定删除连接「\(n.label)」吗？", destructive: true) else { return }
                try await deleteConnection(connID)
            case .createDatabase:
                guard let name = await ask("新建数据库", label: "数据库名"), !name.isEmpty else { return }
                try await onBackground { try db.createDatabase(connID, name: name, charset: "utf8mb4") }
                await refreshConnection(connID)
                toast(.success, "已创建数据库 \(name)")
            case .dropDatabase:
                guard await confirm("删除数据库", "确定删除数据库「\(dbName)」吗？此操作不可恢复！", ok: "删除", destructive: true)
                else { return }
                try await onBackground { try db.dropDatabase(connID, name: dbName) }
                closeTabs { $0.connID == connID && $0.db == dbName }
                await refreshConnection(connID)
            case .createTable:
                openDesign(connID: connID, db: dbName, table: nil)
            case .runSQL:
                sheet = .runSQL(TransferTarget(connID: connID, db: dbName))
            case .dump:
                sheet = .dump(TransferTarget(connID: connID, db: dbName))
            case .dumpTable:
                sheet = .dump(TransferTarget(connID: connID, db: dbName, table: table))
            case .openTable:
                openTableData(connID: connID, db: dbName, table: table, isView: n.kind == .view)
            case .design:
                openDesign(connID: connID, db: dbName, table: table)
            case .viewDDL:
                let ddl = try await onBackground { try db.tableDDL(connID, db: dbName, table: table) }
                openQuery(connID: connID, db: dbName, sql: ddl + ";")
            case .export:
                sheet = .export(TransferTarget(connID: connID, db: dbName, table: table))
            case .importCSV:
                sheet = .importCSV(TransferTarget(connID: connID, db: dbName, table: table))
            case let .duplicate(withData):
                guard let name = await ask("复制表", label: "新表名", value: table + "_copy"), !name.isEmpty else { return }
                try await onBackground { try db.duplicateTable(connID, db: dbName, table: table, to: name, withData: withData) }
                await refreshDatabase(connID, dbName)
                toast(.success, "已复制为 \(name)")
            case .rename:
                guard let name = await ask("重命名表", label: "新表名", value: table), !name.isEmpty, name != table else { return }
                try await onBackground { try db.renameTable(connID, db: dbName, table: table, to: name) }
                closeTabs { $0.connID == connID && $0.db == dbName && $0.table == table }
                await refreshDatabase(connID, dbName)
            case .truncate:
                guard await confirm("清空表", "确定清空表 \(SQL.qualified(dbName, table)) 的所有数据吗？", ok: "清空", destructive: true)
                else { return }
                try await onBackground { try db.truncateTable(connID, db: dbName, table: table) }
                toast(.success, "已清空")
            case .drop:
                let isView = n.kind == .view
                guard await confirm(isView ? "删除视图" : "删除表", "确定删除 \(SQL.qualified(dbName, table)) 吗？此操作不可恢复！",
                                    ok: "删除", destructive: true) else { return }
                try await onBackground { try db.dropTable(connID, db: dbName, table: table, isView: isView) }
                closeTabs { $0.connID == connID && $0.db == dbName && $0.table == table }
                await refreshDatabase(connID, dbName)
            case .copyName:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(table, forType: .string)
            }
        } catch {
            report(error)
        }
    }
}
