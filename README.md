# MySQL Manager — native macOS app

A native SwiftUI + AppKit port of the Tauri MySQL Manager in the parent
directory. It talks to MySQL through its own Swift implementation of the
client/server protocol, with no third-party dependencies, and was built to
see how much memory a native app saves compared to the Tauri build (see
[Results](#results-2026-10-13-macos-27-release-builds)).

Connections are stored in the same
`~/Library/Application Support/com.sting.mysqlmanager/connections.json` as
the Tauri app, so both apps see the same saved connections.

## Features

- **Connections**: create / edit / copy / delete, test connection, optional
  SSL (certificate not verified), optional saved password (file mode 0600),
  color tag. Supports `mysql_native_password`, `caching_sha2_password` and
  `sha256_password`.
- **Object tree**: connection → database → tables / views, search, context
  menus: create / drop database, create / rename / copy (structure, or
  structure + data) / truncate / drop table, view DDL, copy name.
- **SQL editor**: syntax highlighting, line numbers, table / column
  completion; run the selection or the whole script (⌘↩), the current
  statement (⇧⌘↩), stop (⌘.). Multiple statements and result sets,
  `DELIMITER`, `USE db`; each tab keeps its own session. Results are not
  capped by the client: the statement's own `LIMIT` decides how many rows
  come back. Export results as CSV / JSON / SQL.
- **Table data**: paging (100 rows per page by default), WHERE / ORDER BY;
  edit cells inline, add / delete rows, preview the generated SQL and commit
  it in one transaction (tables without a primary key are matched on all
  columns with `LIMIT 1`).
- **Table design**: columns / indexes / foreign keys / table options, SQL
  preview (CREATE, or an ALTER diff of the changes), DDL view.
- **Import / export**: export a table to CSV / JSON / SQL INSERT (optional
  WHERE), dump a database or table to SQL (structure, or structure + data),
  import CSV with column mapping in one transaction, run SQL files with
  progress.
- Light and dark themes (⇧⌘D).

## Layout

- `Sources/MySQLKit/` — everything that talks to the server: the wire
  protocol (`Wire/`: TCP + TLS transport, packets, auth plugins), connection
  pool, query sessions, metadata, row edits, table DDL, import / export,
  the connection store.
- `Sources/App/` — the app: SwiftUI shell, object tree (`Sidebar/`),
  `NSTableView` data grid (`Grid/`), `NSTextView` SQL editor (`Editor/`),
  query / data / design tabs (`Tabs/`), dialogs.
- `Tests/MySQLKitTests/` — unit tests, plus live tests against a real server.

## Build

Requires Xcode 26+ (Swift 6.2). Runs on macOS 14+.

```bash
./build.sh
```

Produces `build/MySQL Manager Native.app`. `swift build` or opening
`Package.swift` in Xcode also works for development.

### Tests

```bash
swift test
```

The live tests use the first saved connection and work in a scratch database
`mm_native_test`, dropped at the end:

```bash
MM_LIVE=1 swift test --filter LiveTests
```

## Results (2026-10-13, macOS 27, release builds)

Same steps in both apps: connect to localhost, expand `hrshare` (64 tables),
open `work_task_instance_subtask` (500 rows × 20 columns per page), open a
query tab and run `SELECT * FROM hrshare.work_task_instance LIMIT 1000`
(1000 × 22). Footprint 30 s after each step:

| Step | Tauri (app + WebKit processes) | Native |
|---|---|---|
| Idle | 105–110 MB | 31–50 MB |
| Table open | 190 MB | 81 MB |
| Table + query | 288 MB (app 35, WebContent 154, GPU 92, Networking 7) | 97 MB |

About 18 MB of the native numbers is freed malloc memory left by a system
image decode 5–15 s after launch; the OS reclaims it under memory pressure,
but Activity Monitor counts it.

## Measuring memory

```bash
./measure.sh "build/MySQL Manager Native.app"
./measure.sh "../src-tauri/target/release/bundle/macos/MySQL Manager.app" --enter
```

`measure.sh` adds up the app's footprint and the WebKit helper processes it
starts. `--enter` waits for Enter so you can click through the app first.
The native app also opens tabs by itself on the first saved connection:

```bash
./measure.sh "build/MySQL Manager Native.app" --wait 30 -- \
  -mmAutoTable hrshare.work_task_instance_subtask \
  -mmAutoSQL "SELECT * FROM hrshare.work_task_instance LIMIT 1000"
```
