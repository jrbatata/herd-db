import AppKit
import Foundation
import HerdCore
import UniformTypeIdentifiers

struct ConnectionEditorState: Identifiable {
    let id = UUID()
    var config: ConnectionConfig
    var password: String
    var isNew: Bool
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum NewDBObject: String, CaseIterable {
    case database = "Banco de dados…"
    case table = "Tabela…"
    case schema = "Schema…"
    case column = "Coluna…"
    case index = "Índice…"
    case rule = "Regra…"
    case trigger = "Trigger…"
    case policy = "Política RLS…"
}

@MainActor
@Observable
final class WorkspaceState {
    let app: AppModel
    let tree: ObjectTreeModel
    let processes = DatabaseProcesses()
    let processesTabID = UUID()

    var tabs: [QueryTab] = []
    var activeTabID: UUID?
    var sidebarVisible = true
    var inspectorVisible = false
    var resultsVisible = true
    var connectionEditor: ConnectionEditorState?
    var tableWizard: TableWizardState?
    var schemaWizard: SchemaWizardState?
    var databaseWizard: DatabaseWizardState?
    var tableStructure: TableStructureState?
    var dropWizard: DropWizardState?
    var backupWizard: BackupWizardState?
    var restoreWizard: RestoreWizardState?
    var tableSubObjectWizard: TableSubObjectWizardState?
    var alert: AlertMessage?
    var focusFilterToken = 0
    @ObservationIgnored weak var editor: SQLTextView?
    @ObservationIgnored var editorTabID: UUID?

    private var queryCounter = 0

    init(app: AppModel) {
        self.app = app
        self.tree = ObjectTreeModel(app: app)
    }

    var activeTab: QueryTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var selectedNode: TreeNode? {
        tree.selection.flatMap { tree.node(withID: $0) }
    }

    var hasFocusedEditor: Bool {
        activeTab != nil && activeTab?.id == editorTabID && editor != nil
    }

    func performEditor(_ action: SQLTextView.Action) {
        if action == .find, !hasFocusedEditor {
            focusSidebarFilter()
            return
        }
        guard hasFocusedEditor, let editor else { return }
        if NSApp.keyWindow?.firstResponder !== editor {
            NSApp.keyWindow?.makeFirstResponder(editor)
        }
        editor.perform(action)
    }

    func focusSidebarFilter() {
        if !sidebarVisible {
            sidebarVisible = true
        }
        focusFilterToken += 1
    }

    var windowTitle: String {
        activeTabID == processesTabID && processes.visible ? "Processos" : (activeTab?.title ?? "herd")
    }

    func openProcesses() {
        processes.visible = true
        activeTabID = processesTabID
    }

    func closeProcesses() {
        processes.visible = false
        activeTabID = tabs.last?.id
    }

    // MARK: - Tabs

    @discardableResult
    func newQueryTab(context: QueryContext? = nil, sql: String = "", title: String? = nil) -> QueryTab? {
        guard let context = context ?? defaultContext() else {
            alert = AlertMessage(
                title: "Nenhuma conexão",
                message: "Crie uma conexão antes de abrir um script."
            )
            return nil
        }

        queryCounter += 1
        let tab = QueryTab(
            title: title ?? "Query \(queryCounter)",
            sql: sql,
            context: context
        )
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    func openTable(_ node: TreeNode) {
        guard node.kind == .table || node.kind == .view else { return }
        guard let config = app.connections.connection(id: node.connectionID) else { return }
        guard let table = node.table, let database = node.database else { return }

        let dialect = engineDialect(config.engine)
        let sql = dialect.limitedSelect(schema: node.schema, table: table, limit: 500)
        let context = QueryContext(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            schema: node.schema
        )
        let tab = newQueryTab(context: context, sql: sql, title: node.title)
        if node.kind == .table {
            tab?.sourceTable = table
            tab?.browseSQL = sql
        }
    }

    /// Opens a new script tab prefilled with a ready-made query for the table/view.
    func openReadyQuery(_ query: SQLReadyQuery, for node: TreeNode) {
        guard node.kind == .table || node.kind == .view else { return }
        guard let config = app.connections.connection(id: node.connectionID) else { return }
        guard let table = node.table, let database = node.database else { return }

        let dialect = engineDialect(config.engine)
        let sql = dialect.readyQuery(query, schema: node.schema, table: table)
        let context = QueryContext(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            schema: node.schema
        )
        let tab = newQueryTab(context: context, sql: sql, title: "\(query.title) · \(node.title)")
        if node.kind == .table { tab?.sourceTable = table }
    }

    func openReferencedRow(connectionID: UUID, database: String, reference: String, value: String) {
        let parts = reference.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let config = app.connections.connection(id: connectionID) else { return }
        let refSchema = parts[0]
        let refTable = parts[1]
        let refColumn = parts[2]
        let dialect = engineDialect(config.engine)
        let target = dialect.qualify(schema: refSchema, table: refTable)
        let quotedCol = dialect.quote(refColumn)
        let escapedVal = value.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT *\nFROM \(target)\nWHERE \(quotedCol) = '\(escapedVal)'\nLIMIT 500;"
        let context = QueryContext(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            schema: refSchema
        )
        if let tab = newQueryTab(context: context, sql: sql, title: "\(refTable) · \(value)") {
            tab.sourceTable = refTable
            tab.tableFilter = value
            tab.browseTable(app: app, page: 0)
        }
    }

    func openInsertScript(for tab: QueryTab) {
        guard let table = tab.sourceTable,
              let config = app.connections.connection(id: tab.connectionID) else { return }
        let context = QueryContext(connectionID: tab.connectionID,
                                   connectionName: tab.connectionName,
                                   database: tab.database, schema: tab.schema)
        let sql = engineDialect(config.engine).readyQuery(.insert, schema: tab.schema, table: table)
        newQueryTab(context: context, sql: sql, title: "Nova linha · \(table)")
    }

    func newQueryTab(for node: TreeNode) {
        guard let config = app.connections.connection(id: node.connectionID) else { return }
        let database = node.database ?? config.maintenanceDatabase
        let context = QueryContext(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            schema: node.schema
        )
        newQueryTab(context: context)
    }

    func openDDL(_ sql: String, for node: TreeNode, title: String) {
        guard let config = app.connections.connection(id: node.connectionID) else { return }
        let database = node.kind == .database && sql.hasPrefix("DROP DATABASE")
            ? "postgres" : (node.database ?? config.maintenanceDatabase)
        let context = QueryContext(connectionID: config.id, connectionName: config.name,
                                   database: database,
                                   schema: node.schema)
        newQueryTab(context: context, sql: sql, title: title)
    }

    func canCreate(_ object: NewDBObject) -> Bool {
        guard let node = selectedNode,
              app.connections.connection(id: node.connectionID)?.engine == .postgres else { return false }
        switch object {
        case .database:
            return true
        case .table, .schema:
            return node.kind == .database || node.kind == .schema || node.kind == .tablesFolder || node.kind == .table || node.kind == .view
        case .column, .index, .rule, .trigger, .policy:
            return node.kind == .table
        }
    }

    func create(_ object: NewDBObject, for targetNode: TreeNode? = nil) {
        guard let node = targetNode ?? selectedNode,
              let config = app.connections.connection(id: node.connectionID) else { return }
        switch object {
        case .database:
            presentCreateDatabase(for: config)
        case .table:
            presentCreateTable(for: node)
        case .schema:
            presentCreateSchema(for: node)
        case .column, .index, .rule, .trigger, .policy:
            let subKind: TableSubObjectWizardState.SubObjectKind = switch object {
            case .column: .column
            case .index: .index
            case .rule: .rule
            case .trigger: .trigger
            case .policy: .policy
            case .database, .table, .schema: .column
            }
            tableSubObjectWizard = TableSubObjectWizardState(
                connectionID: config.id,
                connectionName: config.name,
                database: node.database ?? config.maintenanceDatabase,
                schema: node.schema,
                table: node.table ?? node.title,
                kind: subKind
            )
        }
    }

    func presentCreateDatabase(for config: ConnectionConfig) {
        databaseWizard = DatabaseWizardState(
            connectionID: config.id,
            connectionName: config.name,
            maintenanceDatabase: config.maintenanceDatabase,
            defaultOwner: config.username
        )
    }

    func presentTableStructure(for node: TreeNode? = nil) {
        guard let target = node ?? selectedNode,
              target.kind == .table,
              let config = app.connections.connection(id: target.connectionID),
              let database = target.database,
              let table = target.table else { return }
        tableStructure = TableStructureState(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            schema: target.schema ?? "public",
            table: table
        )
    }

    func openCreateTableScript(for node: TreeNode) {
        guard let config = app.connections.connection(id: node.connectionID),
              let database = node.database,
              let table = node.table else { return }
        let schema = node.schema ?? "public"
        let dialect = engineDialect(config.engine)
        let qualified = dialect.qualify(schema: schema, table: table)
        let driver = app.drivers.driver(for: config)

        Task {
            let cols = (try? await driver.listColumns(database: database, schema: schema, table: table)) ?? []
            var lines = cols.map { col -> String in
                var part = "    \(dialect.quote(col.name)) \(col.dataType)"
                if !col.isNullable { part += " NOT NULL" }
                if col.isPrimaryKey { part += " PRIMARY KEY" }
                return part
            }
            if lines.isEmpty { lines = ["    id bigint PRIMARY KEY"] }
            let sql = "CREATE TABLE \(qualified) (\n\(lines.joined(separator: ",\n"))\n);"
            let context = QueryContext(
                connectionID: config.id,
                connectionName: config.name,
                database: database,
                schema: schema
            )
            newQueryTab(context: context, sql: sql, title: "CREATE · \(table)")
        }
    }

    func presentCreateTable(for node: TreeNode? = nil) {
        guard let target = node ?? selectedNode,
              let config = app.connections.connection(id: target.connectionID) else { return }
        let database = target.database ?? config.maintenanceDatabase
        let defaultSchema = (target.kind == .schema ? target.title : target.schema) ?? "public"
        tableWizard = TableWizardState(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            defaultSchema: defaultSchema,
            defaultOwner: config.username,
            reloadNode: target
        )
    }

    func presentCreateSchema(for node: TreeNode? = nil) {
        guard let target = node ?? selectedNode,
              let config = app.connections.connection(id: target.connectionID) else { return }
        let database = target.database ?? config.maintenanceDatabase
        schemaWizard = SchemaWizardState(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            defaultOwner: config.username,
            reloadNode: target
        )
    }

    func presentBackup(for node: TreeNode) {
        guard node.kind == .database || node.kind == .table,
              let config = app.connections.connection(id: node.connectionID) else { return }
        backupWizard = BackupWizardState(
            node: node,
            connectionName: config.name,
            database: node.database ?? config.maintenanceDatabase,
            target: node.kind == .table
                ? "\(node.schema ?? "public").\(node.table ?? node.title)"
                : (node.database ?? config.maintenanceDatabase)
        )
    }

    func presentRestore(for node: TreeNode) {
        guard node.kind == .database,
              let config = app.connections.connection(id: node.connectionID),
              let database = node.database else { return }
        restoreWizard = RestoreWizardState(
            node: node,
            connectionName: config.name,
            database: database
        )
    }

    func presentDropObject(for node: TreeNode, force: Bool = false) {
        guard let config = app.connections.connection(id: node.connectionID) else { return }
        let database = node.database ?? config.maintenanceDatabase
        let kind: DropWizardState.ObjectKind
        switch node.kind {
        case .table: kind = .table
        case .view: kind = .view
        case .schema: kind = .schema
        case .database: kind = .database
        default: return
        }
        dropWizard = DropWizardState(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            schema: node.schema,
            objectName: node.table ?? node.title,
            kind: kind,
            force: force,
            reloadNode: node
        )
    }

    func reloadAfterDDL(connectionID: UUID, database: String?, schema: String?) {
        let connNodeID = "c/\(connectionID.uuidString)"
        guard let database else {
            if let connNode = tree.node(withID: connNodeID) {
                tree.reload(connNode)
            }
            return
        }
        let dbNodeID = connNodeID + "\u{1F}d\u{1F}\(database)"
        if let schema {
            let schemaNodeID = dbNodeID + "\u{1F}s\u{1F}\(schema)"
            let tablesFolderID = schemaNodeID + "\u{1F}tables"
            if let folderNode = tree.node(withID: tablesFolderID) {
                tree.reload(folderNode)
                return
            }
            if let schemaNode = tree.node(withID: schemaNodeID) {
                tree.reload(schemaNode)
                return
            }
        }
        if let dbNode = tree.node(withID: dbNodeID) {
            tree.reload(dbNode)
        } else if let connNode = tree.node(withID: connNodeID) {
            tree.reload(connNode)
        }
    }

    func newQueryTab(for config: ConnectionConfig) {
        let database = config.maintenanceDatabase
        let context = QueryContext(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            schema: nil
        )
        newQueryTab(context: context)
    }

    @discardableResult
    func closeTab(_ tab: QueryTab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        guard confirmClose(tab) else { return false }
        tab.cancel()
        tabs.remove(at: index)
        if editorTabID == tab.id { editor = nil; editorTabID = nil }
        if activeTabID == tab.id {
            if tabs.indices.contains(index) {
                activeTabID = tabs[index].id
            } else if index > 0, tabs.indices.contains(index - 1) {
                activeTabID = tabs[index - 1].id
            } else {
                activeTabID = tabs.last?.id
            }
        }
        return true
    }

    func closeOthers(except tab: QueryTab) {
        for other in tabs.filter({ $0.id != tab.id }) {
            guard closeTab(other) else { break }
        }
        activeTabID = tab.id
    }

    func closeTabs(after tab: QueryTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        for other in Array(tabs[(index + 1)...]) {
            guard closeTab(other) else { break }
        }
    }

    func closeAllTabs() {
        for tab in Array(tabs) {
            guard closeTab(tab) else { break }
        }
    }

    func closeActiveTab() {
        guard let tab = activeTab else { return }
        closeTab(tab)
    }

    func selectTab(at index: Int) {
        guard !tabs.isEmpty else { return }
        if index == 8, tabs.count >= 9 {
            activeTabID = tabs.last?.id
        } else if tabs.indices.contains(index) {
            activeTabID = tabs[index].id
        }
    }

    // MARK: - SQL files

    func openSQLFile() {
        guard let context = activeTab.map({ QueryContext(connectionID: $0.connectionID,
                                                       connectionName: $0.connectionName,
                                                       database: $0.database, schema: $0.schema) }) ?? defaultContext() else {
            alert = AlertMessage(title: "Nenhuma conexão", message: "Crie uma conexão antes de abrir um arquivo SQL.")
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = [String.Encoding.utf8, .utf16, .isoLatin1]
                .compactMap { encoding -> (String, String.Encoding)? in
                    String(data: data, encoding: encoding).map { ($0, encoding) }
                }.first
            guard let (sql, encoding) = decoded else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let tab = newQueryTab(context: context, sql: sql, title: url.lastPathComponent)
            tab?.fileURL = url
            tab?.fileEncoding = encoding
        } catch {
            alert = AlertMessage(title: "Não foi possível abrir o SQL", message: error.localizedDescription)
        }
    }

    @discardableResult
    func saveActiveTab(as saveAs: Bool = false) -> Bool {
        guard let tab = activeTab else { return false }
        return save(tab, as: saveAs)
    }

    private func save(_ tab: QueryTab, as saveAs: Bool = false) -> Bool {
        var destination = saveAs ? nil : tab.fileURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
            panel.nameFieldStringValue = tab.fileURL?.lastPathComponent ?? "\(tab.title).sql"
            guard panel.runModal() == .OK else { return false }
            destination = panel.url
        }
        guard let destination else { return false }
        do {
            guard let data = tab.sql.data(using: tab.fileEncoding) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            try data.write(to: destination, options: .atomic)
            tab.fileURL = destination
            tab.title = destination.lastPathComponent
            tab.savedSQL = tab.sql
            return true
        } catch {
            alert = AlertMessage(title: "Não foi possível salvar o SQL", message: error.localizedDescription)
            return false
        }
    }

    private func confirmClose(_ tab: QueryTab) -> Bool {
        guard tab.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Salvar alterações em \(tab.title)?"
        alert.informativeText = "As alterações serão perdidas se você fechar sem salvar."
        alert.addButton(withTitle: "Salvar")
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Não salvar")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save(tab)
        case .alertThirdButtonReturn:
            tab.savedSQL = tab.sql
            return true
        default:
            return false
        }
    }

    func confirmCloseWindow() -> Bool {
        for tab in Array(tabs) where tab.hasUnsavedChanges {
            guard confirmClose(tab) else { return false }
        }
        return true
    }

    // MARK: - Query

    func runActiveTab(scope: QueryExecutionScope = .automatic) {
        activeTab?.run(app: app, scope: scope)
    }

    func cancelActiveTab() {
        activeTab?.cancel()
    }

    func defaultContext() -> QueryContext? {
        if let id = tree.selection,
           let node = tree.node(withID: id),
           let config = app.connections.connection(id: node.connectionID) {
            return QueryContext(
                connectionID: config.id,
                connectionName: config.name,
                database: node.database ?? config.maintenanceDatabase,
                schema: node.schema
            )
        }

        guard let config = app.connections.connections.first else { return nil }
        return QueryContext(
            connectionID: config.id,
            connectionName: config.name,
            database: config.maintenanceDatabase,
            schema: nil
        )
    }

    private func engineDialect(_ engine: DatabaseEngine) -> SQLDialect {
        engine == .sqlServer ? .sqlServer : .postgres
    }

    // MARK: - Connections

    func presentNewConnection() {
        connectionEditor = ConnectionEditorState(
            config: ConnectionConfig(username: NSUserName()),
            password: "",
            isNew: true
        )
    }

    func presentEditConnection(_ config: ConnectionConfig) {
        connectionEditor = ConnectionEditorState(
            config: config,
            password: app.connections.password(for: config.id) ?? "",
            isNew: false
        )
    }

    func save(_ editor: ConnectionEditorState, config: ConnectionConfig, password: String) {
        do {
            try app.save(config, password: password)
            tree.syncConnections()
            connectionEditor = nil
        } catch {
            alert = AlertMessage(title: "Não foi possível salvar", message: error.localizedDescription)
        }
    }

    func remove(_ config: ConnectionConfig) {
        do {
            try app.remove(config)
            tree.syncConnections()
        } catch {
            alert = AlertMessage(title: "Não foi possível remover", message: error.localizedDescription)
        }
    }
}
