import Foundation
import HerdCore
import Observation

struct TreeNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case connection
        case database
        case schema
        case tablesFolder
        case viewsFolder
        case table
        case view
        case column
        case error
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String?
    let connectionID: UUID
    var database: String?
    var schema: String?
    var table: String?
    var column: ColumnInfo?

    var isExpandable: Bool {
        switch kind {
        case .connection, .database, .schema, .tablesFolder, .viewsFolder, .table, .view:
            true
        case .column, .error:
            false
        }
    }

    var isSelectable: Bool { kind != .error }

    var symbolName: SolarSymbol {
        switch kind {
        case .connection: .database
        case .database: .database
        case .schema: .folder
        case .tablesFolder, .table: .table
        case .viewsFolder, .view: .eye
        case .column:
            if column?.isPrimaryKey == true { .key }
            else if column?.references != nil { .link }
            else { .dot }
        case .error: .warning
        }
    }
}

struct TreeRow: Identifiable {
    let node: TreeNode
    let depth: Int
    let isExpanded: Bool
    let isLoading: Bool

    var id: String { node.id }
}

@MainActor
@Observable
final class ObjectTreeModel {
    private let app: AppModel

    private(set) var roots: [TreeNode] = []
    var expanded: Set<String> = []
    private(set) var children: [String: [TreeNode]] = [:]
    private(set) var loading: Set<String> = []
    var filter = ""
    var selection: String?

    private var knownConfigs: [UUID: ConnectionConfig] = [:]
    private var didAutoExpand = false

    init(app: AppModel) {
        self.app = app
        syncConnections()
    }

    // MARK: - Connections

    func syncConnections() {
        let configs = app.connections.connections
        let previous = knownConfigs

        roots = configs.map(makeConnectionNode)
        knownConfigs = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })

        for config in configs where previous[config.id] != nil && previous[config.id] != config {
            clearSubtree("c/\(config.id.uuidString)")
            if expanded.contains(connectionID(config.id)) {
                Task { await loadNode(withID: connectionID(config.id)) }
            }
        }

        // Drop state for removed connections.
        let livePrefixes = configs.map { "c/\($0.id.uuidString)" }
        children = children.filter { key, _ in livePrefixes.contains { key.hasPrefix($0) } }
        expanded = expanded.filter { key in livePrefixes.contains { key.hasPrefix($0) } }

        if !didAutoExpand, roots.count == 1, let root = roots.first {
            didAutoExpand = true
            toggle(root)
        }
    }

    private func connectionID(_ id: UUID) -> String { "c/\(id.uuidString)" }

    private func makeConnectionNode(_ config: ConnectionConfig) -> TreeNode {
        TreeNode(
            id: connectionID(config.id),
            kind: .connection,
            title: config.name,
            detail: nil,
            connectionID: config.id
        )
    }

    // MARK: - Expansion

    func toggle(_ node: TreeNode) {
        guard node.isExpandable else { return }
        if expanded.contains(node.id) {
            expanded.remove(node.id)
            return
        }
        expanded.insert(node.id)
        if children[node.id] == nil {
            Task { await loadNode(node) }
        }
    }

    func expand(_ node: TreeNode) {
        guard node.isExpandable, !expanded.contains(node.id) else { return }
        toggle(node)
    }

    func select(_ node: TreeNode) {
        guard node.isSelectable else { return }
        selection = node.id
    }

    func reload(_ node: TreeNode) {
        clearSubtree(node.id)
        if node.isExpandable, expanded.contains(node.id) {
            Task { await loadNode(node) }
        }
    }

    func reloadAll() {
        children.removeAll()
        loading.removeAll()
        selection = nil
        for root in roots where expanded.contains(root.id) {
            Task { await loadNode(root) }
        }
    }

    func retry(afterErrorNode node: TreeNode) {
        guard node.kind == .error, node.id.hasSuffix("\u{1F}error") else { return }
        let parentID = String(node.id.dropLast("\u{1F}error".count))
        guard let parent = self.node(withID: parentID) else { return }
        reload(parent)
    }

    private func clearSubtree(_ id: String) {
        children[id] = nil
        let prefix = id + "\u{1F}"
        children = children.filter { !$0.key.hasPrefix(prefix) }
    }

    func node(withID id: String) -> TreeNode? {
        find(id, in: roots)
    }

    private func find(_ id: String, in nodes: [TreeNode]) -> TreeNode? {
        for node in nodes {
            if node.id == id { return node }
            if let kids = children[node.id], let found = find(id, in: kids) { return found }
        }
        return nil
    }

    // MARK: - Loading

    private func loadNode(withID id: String) async {
        guard let node = node(withID: id) else { return }
        await loadNode(node)
    }

    private func loadNode(_ node: TreeNode) async {
        guard node.isExpandable, children[node.id] == nil, !loading.contains(node.id) else { return }
        guard let config = app.connections.connection(id: node.connectionID) else {
            children[node.id] = [errorNode(for: node, message: "Conexão removida.")]
            return
        }

        loading.insert(node.id)
        defer { loading.remove(node.id) }

        let driver = app.drivers.driver(for: config)
        do {
            let kids = try await loadChildren(of: node, config: config, driver: driver)
            children[node.id] = kids
            for kid in kids where expanded.contains(kid.id) && children[kid.id] == nil {
                Task { await loadNode(kid) }
            }
        } catch is CancellationError {
            return
        } catch {
            children[node.id] = [errorNode(for: node, message: error.localizedDescription)]
        }
    }

    private func loadChildren(
        of node: TreeNode,
        config: ConnectionConfig,
        driver: any DatabaseDriver
    ) async throws -> [TreeNode] {
        switch node.kind {
        case .connection:
            let databases = try await driver.listDatabases()
            return databases.map { makeDatabaseNode($0, parent: node) }

        case .database:
            let schemas = try await driver.listSchemas(database: node.database ?? node.title)
            return schemas.map { makeSchemaNode($0, parent: node) }

        case .schema:
            return [makeFolderNode(.tablesFolder, parent: node), makeFolderNode(.viewsFolder, parent: node)]

        case .tablesFolder, .viewsFolder:
            guard let database = node.database, let schema = node.schema else { return [] }
            let tables = try await driver.listTables(database: database, schema: schema)
            let wantViews = node.kind == .viewsFolder
            return tables
                .filter { ($0.kind == .view) == wantViews }
                .map { makeTableNode($0, parent: node) }

        case .table, .view:
            guard
                let database = node.database,
                let schema = node.schema,
                let table = node.table
            else { return [] }
            let columns = try await driver.listColumns(database: database, schema: schema, table: table)
            return columns.map { makeColumnNode($0, parent: node) }

        case .column, .error:
            return []
        }
    }

    // MARK: - Node factories

    private func makeDatabaseNode(_ database: DatabaseInfo, parent: TreeNode) -> TreeNode {
        TreeNode(
            id: parent.id + "\u{1F}d\u{1F}\(database.name)",
            kind: .database,
            title: database.name,
            detail: nil,
            connectionID: parent.connectionID,
            database: database.name
        )
    }

    private func makeSchemaNode(_ schema: SchemaInfo, parent: TreeNode) -> TreeNode {
        TreeNode(
            id: parent.id + "\u{1F}s\u{1F}\(schema.name)",
            kind: .schema,
            title: schema.name,
            detail: nil,
            connectionID: parent.connectionID,
            database: parent.database,
            schema: schema.name
        )
    }

    private func makeFolderNode(_ kind: TreeNode.Kind, parent: TreeNode) -> TreeNode {
        let isViews = kind == .viewsFolder
        return TreeNode(
            id: parent.id + (isViews ? "\u{1F}views" : "\u{1F}tables"),
            kind: kind,
            title: isViews ? "Views" : "Tabelas",
            detail: nil,
            connectionID: parent.connectionID,
            database: parent.database,
            schema: parent.schema
        )
    }

    private func makeTableNode(_ table: TableInfo, parent: TreeNode) -> TreeNode {
        TreeNode(
            id: parent.id + "\u{1F}t\u{1F}\(table.name)",
            kind: table.kind == .view ? .view : .table,
            title: table.name,
            detail: nil,
            connectionID: parent.connectionID,
            database: parent.database,
            schema: table.schema,
            table: table.name
        )
    }

    private func makeColumnNode(_ column: ColumnInfo, parent: TreeNode) -> TreeNode {
        TreeNode(
            id: parent.id + "\u{1F}c\u{1F}\(column.name)",
            kind: .column,
            title: column.name,
            detail: column.dataType,
            connectionID: parent.connectionID,
            database: parent.database,
            schema: parent.schema,
            table: parent.table,
            column: column
        )
    }

    private func errorNode(for node: TreeNode, message: String) -> TreeNode {
        TreeNode(
            id: node.id + "\u{1F}error",
            kind: .error,
            title: message,
            detail: nil,
            connectionID: node.connectionID,
            database: node.database,
            schema: node.schema
        )
    }

    // MARK: - Visible rows

    var rows: [TreeRow] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [TreeRow] = []

        func append(_ node: TreeNode, depth: Int) {
            result.append(
                TreeRow(
                    node: node,
                    depth: depth,
                    isExpanded: expanded.contains(node.id),
                    isLoading: loading.contains(node.id)
                )
            )
            guard expanded.contains(node.id), let kids = children[node.id] else { return }
            for kid in kids {
                append(kid, depth: depth + 1)
            }
        }

        func search(_ node: TreeNode, depth: Int) {
            if node.kind != .error, node.title.localizedCaseInsensitiveContains(query) {
                result.append(
                    TreeRow(
                        node: node,
                        depth: depth,
                        isExpanded: expanded.contains(node.id),
                        isLoading: loading.contains(node.id)
                    )
                )
            }
            if let kids = children[node.id] {
                for kid in kids {
                    search(kid, depth: depth + 1)
                }
            }
        }

        if query.isEmpty {
            for root in roots { append(root, depth: 0) }
        } else {
            for root in roots { search(root, depth: 0) }
        }
        return result
    }
}
