import AppKit
import Foundation

/// Launch arguments for repeatable memory measurements (see measure.sh):
///   -mmAutoTable db.table   open the table on the first saved connection
///   -mmAutoSQL "<sql>"      open a query tab and run it
///   -mmSnapshot <file.png>  then save an image of the window
extension AppModel {
    func runBenchmarkHooks() {
        let defaults = UserDefaults.standard
        let table = defaults.string(forKey: "mmAutoTable")
        let sql = defaults.string(forKey: "mmAutoSQL")
        let snapshot = defaults.string(forKey: "mmSnapshot")
        guard table != nil || sql != nil || snapshot != nil else { return }
        Task {
            // wait for the saved connections
            for _ in 0..<50 where connections.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if (table != nil || sql != nil), let conn = connections.first, let root = node("conn:\(conn.id)") {
                do {
                    try await load(root)
                    root.isExpanded = true
                    if let table, let dot = table.firstIndex(of: ".") {
                        let db = String(table[..<dot]), name = String(table[table.index(after: dot)...])
                        if let dbNode = node("db:\(conn.id):\(db)") {
                            try await load(dbNode)
                            dbNode.isExpanded = true
                            for c in dbNode.children ?? [] where c.kind == .tables { c.isExpanded = true }
                        }
                        openTableData(connID: conn.id, db: db, table: name, isView: false)
                    }
                    if let sql {
                        await openQuery(connID: conn.id, db: conn.database, sql: sql).run(sql)
                    }
                } catch {
                    report(error)
                }
            }
            if let snapshot {
                try? await Task.sleep(for: .seconds(2))
                saveWindowImage(to: snapshot)
            }
        }
    }

    private func saveWindowImage(to path: String) {
        // the frame view, so the title bar and toolbar are included
        guard let view = NSApp.windows.first(where: \.isVisible)?.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
