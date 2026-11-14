import Foundation
import HerdCore

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

@MainActor
@Observable
final class WorkspaceState {
    let app: AppModel
    let tree: ObjectTreeModel

    var tabs: [QueryTab] = []
    var activeTabID: UUID?
    var sidebarVisible = true
    var connectionEditor: ConnectionEditorState?
    var alert: AlertMessage?

    private var queryCounter = 0

    init(app: AppModel) {
        self.app = app
        self.tree = ObjectTreeModel(app: app)
    }

    var activeTab: QueryTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var windowTitle: String { activeTab?.title ?? "herd" }

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
        let sql = dialect.limitedSelect(schema: node.schema, table: table, limit: 100)
        let context = QueryContext(
            connectionID: config.id,
            connectionName: config.name,
            database: database,
            schema: node.schema
        )
        newQueryTab(context: context, sql: sql, title: node.title)
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

    func closeTab(_ tab: QueryTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.cancel()
        tabs.remove(at: index)
        if activeTabID == tab.id {
            if tabs.indices.contains(index) {
                activeTabID = tabs[index].id
            } else if index > 0, tabs.indices.contains(index - 1) {
                activeTabID = tabs[index - 1].id
            } else {
                activeTabID = tabs.last?.id
            }
        }
    }

    func closeActiveTab() {
        guard let tab = activeTab else { return }
        closeTab(tab)
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
