import AppKit
import HerdCore
import Observation
import SwiftUI

/// Escopo da paleta. `⌘P` busca tudo, `⌘K` somente bancos e `⇧⌘K` somente conexões.
enum CommandPaletteScope: Equatable {
    case all
    case databases
    case connections

    var label: String {
        switch self {
        case .all: "Tudo"
        case .databases: "Bancos"
        case .connections: "Conexões"
        }
    }

    var placeholder: String {
        switch self {
        case .all: "Buscar bancos, tabelas, funções, ações…"
        case .databases: "Buscar banco de dados…"
        case .connections: "Buscar conexão…"
        }
    }
}

struct PaletteItem: Identifiable {
    enum Kind {
        case action
        case connection
        case database
        case schema
        case table
        case view
        case routine
        case recentQuery
    }

    let id: String
    let title: String
    let subtitle: String?
    let icon: IconSymbol
    let shortcut: String?
    let kind: Kind
    let action: PaletteAction
    /// Texto usado pelo matcher: inclui nome, schema, banco e conexão.
    let searchText: String
}

enum PaletteAction {
    case newQueryTab
    case newQuery(connectionID: UUID, database: String?, schema: String?)
    case openTable(connectionID: UUID, database: String, schema: String, table: String, isTable: Bool)
    case openDatabase(connectionID: UUID, database: String)
    case selectConnection(UUID)
    case openRoutine(connectionID: UUID, database: String, schema: String, name: String, isProcedure: Bool)
    case openRecent(connectionID: UUID, database: String, sql: String)
    case backup
    case restore
    case cancelQueries
    case openSettings
    case refreshTree
    case toggleSidebar
    case toggleConsole
    case openDatabases
    case openConnections
    case newConnection
}

/// Estado da paleta "Abrir Qualquer Coisa".
@MainActor
@Observable
final class CommandPaletteModel {
    private(set) var isPresented = false
    private(set) var scope: CommandPaletteScope = .all
    private(set) var allItems: [PaletteItem] = []
    private(set) var isLoading = false
    var query = "" {
        didSet { selectedIndex = 0 }
    }
    var selectedIndex = 0

    @ObservationIgnored private weak var workspace: WorkspaceState?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Descarta resultados de cargas antigas quando a paleta muda de escopo.
    @ObservationIgnored private var generation = 0

    var items: [PaletteItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return allItems }

        return allItems
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = FuzzyMatcher.score(term, in: item.searchText) else { return nil }
                return (item, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    // MARK: - Lifecycle

    func present(scope: CommandPaletteScope, workspace: WorkspaceState) {
        self.workspace = workspace
        self.scope = scope
        query = ""
        selectedIndex = 0
        isPresented = true
        allItems = baseItems(workspace: workspace, scope: scope)

        loadTask?.cancel()
        generation += 1
        let current = generation
        loadTask = Task { [weak self] in
            await self?.loadRemote(workspace: workspace, scope: scope, generation: current)
        }
    }

    func dismiss() {
        loadTask?.cancel()
        loadTask = nil
        generation += 1
        isPresented = false
        isLoading = false
        query = ""
        allItems = []
    }

    // MARK: - Keyboard

    func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    func select(_ index: Int) {
        selectedIndex = max(0, index)
    }

    /// Tab: completa a busca com o título do item destacado.
    func complete() {
        guard items.indices.contains(selectedIndex) else { return }
        query = items[selectedIndex].title
    }

    /// Esc: limpa a busca; com a busca vazia, fecha a paleta.
    func escape() {
        if query.isEmpty {
            dismiss()
        } else {
            query = ""
        }
    }

    func submit(newTab: Bool = false) {
        guard items.indices.contains(selectedIndex) else { return }
        perform(items[selectedIndex], newTab: newTab)
    }

    // MARK: - Actions

    private func perform(_ item: PaletteItem, newTab: Bool) {
        guard let workspace else { return }
        dismiss()

        switch item.action {
        case .newQueryTab:
            workspace.newQueryTab()

        case .newQuery(let connectionID, let database, let schema):
            guard let config = workspace.app.connections.connection(id: connectionID) else { return }
            workspace.newQueryTab(context: QueryContext(
                connectionID: connectionID,
                connectionName: config.name,
                database: database ?? config.maintenanceDatabase,
                schema: schema
            ))

        case .openTable(let connectionID, let database, let schema, let table, let isTable):
            workspace.openPaletteTable(
                connectionID: connectionID,
                database: database,
                schema: schema,
                table: table,
                isTable: isTable,
                newTab: newTab
            )

        case .openDatabase(let connectionID, let database):
            guard let config = workspace.app.connections.connection(id: connectionID) else { return }
            workspace.newQueryTab(context: QueryContext(
                connectionID: connectionID,
                connectionName: config.name,
                database: database,
                schema: nil
            ))

        case .selectConnection(let id):
            workspace.revealConnection(id)

        case .openRoutine(let connectionID, let database, let schema, let name, let isProcedure):
            workspace.openRoutineCall(
                connectionID: connectionID,
                database: database,
                schema: schema,
                name: name,
                isProcedure: isProcedure
            )

        case .openRecent(let connectionID, let database, let sql):
            guard let config = workspace.app.connections.connection(id: connectionID) else { return }
            workspace.newQueryTab(
                context: QueryContext(
                    connectionID: connectionID,
                    connectionName: config.name,
                    database: database,
                    schema: nil
                ),
                sql: sql,
                title: "Consulta recente"
            )

        case .backup:
            workspace.presentBackupForSelection()

        case .restore:
            workspace.presentRestoreForSelection()

        case .cancelQueries:
            workspace.cancelActiveTab()

        case .openSettings:
            SettingsOpener.open()

        case .refreshTree:
            workspace.tree.reloadAll()

        case .toggleSidebar:
            withAnimation(.snappy(duration: 0.25)) { workspace.sidebarVisible.toggle() }

        case .toggleConsole:
            workspace.toggleConsole()

        case .openDatabases:
            present(scope: .databases, workspace: workspace)

        case .openConnections:
            present(scope: .connections, workspace: workspace)

        case .newConnection:
            workspace.presentNewConnection()
        }
    }

    // MARK: - Static items

    private func baseItems(workspace: WorkspaceState, scope: CommandPaletteScope) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if scope == .all {
            items.append(contentsOf: actionItems())
            items.append(contentsOf: recentItems(workspace: workspace))
        }
        if scope != .databases {
            items.append(contentsOf: connectionItems(workspace: workspace))
        }
        return items
    }

    private func actionItems() -> [PaletteItem] {
        [
            action("new-query", "Nova consulta", "Abrir um script em branco", .newQuery, "⌘T", .action,
                   .newQueryTab),
            action("open-databases", "Abrir banco…", "Ir para um banco de dados", .database, "⌘K", .action,
                   .openDatabases),
            action("open-connections", "Abrir conexão…", "Ir para uma conexão", .database, "⇧⌘K", .action,
                   .openConnections),
            action("new-connection", "Nova conexão…", "Cadastrar um servidor", .newConnection, "⇧⌘N", .action,
                   .newConnection),
            action("backup", "Backup…", "Exportar banco ou tabela", .download, "⇧⌘B", .action, .backup),
            action("restore", "Restore…", "Restaurar um dump no banco", .download, "⇧⌘R", .action, .restore),
            action("cancel", "Cancelar consultas", "Interromper a execução atual", .stop, "⌘.", .action,
                   .cancelQueries),
            action("settings", "Configurações…", "Preferências do herd", .info, "⌘,", .action, .openSettings),
            action("refresh", "Atualizar árvore", "Recarregar a barra lateral", .refresh, "⌘R", .action,
                   .refreshTree),
            action("sidebar", "Alternar barra lateral", "Mostrar ou ocultar a sidebar", .sidebar, "⌘B", .action,
                   .toggleSidebar),
            action("console", "Alternar console", "Ver as consultas enviadas ao servidor", .clock, "⌃⌘C", .action,
                   .toggleConsole)
        ]
    }

    private func action(
        _ key: String,
        _ title: String,
        _ subtitle: String,
        _ icon: IconSymbol,
        _ shortcut: String?,
        _ kind: PaletteItem.Kind,
        _ action: PaletteAction
    ) -> PaletteItem {
        PaletteItem(
            id: "action/\(key)",
            title: title,
            subtitle: subtitle,
            icon: icon,
            shortcut: shortcut,
            kind: kind,
            action: action,
            searchText: "\(title) \(subtitle)"
        )
    }

    private func connectionItems(workspace: WorkspaceState) -> [PaletteItem] {
        workspace.app.connections.connections.map { config in
            PaletteItem(
                id: "conn/\(config.id.uuidString)",
                title: config.name,
                subtitle: "\(config.engine.displayName) · \(config.host):\(config.port)",
                icon: config.engine.iconSymbol,
                shortcut: nil,
                kind: .connection,
                action: .selectConnection(config.id),
                searchText: "\(config.name) \(config.host) \(config.username) \(config.engine.displayName)"
            )
        }
    }

    private func recentItems(workspace: WorkspaceState) -> [PaletteItem] {
        let connections = workspace.app.connections
        return workspace.app.history.entries.prefix(15).compactMap { entry in
            guard let config = connections.connection(id: entry.connectionID) else { return nil }
            let title = String(entry.summary.prefix(90))
            return PaletteItem(
                id: "recent/\(entry.id.uuidString)",
                title: title,
                subtitle: "Recente · \(config.name) · \(entry.database)",
                icon: .clock,
                shortcut: nil,
                kind: .recentQuery,
                action: .openRecent(
                    connectionID: entry.connectionID,
                    database: entry.database,
                    sql: entry.sql
                ),
                searchText: "\(entry.sql) \(entry.database) \(config.name)"
            )
        }
    }

    // MARK: - Remote items

    private func loadRemote(
        workspace: WorkspaceState,
        scope: CommandPaletteScope,
        generation: Int
    ) async {
        guard generation == self.generation else { return }
        isLoading = true
        defer { isLoading = false }

        let app = workspace.app
        let connections = app.connections.connections

        if scope != .connections {
            let drivers = connections.map { ($0, app.drivers.driver(for: $0)) }
            await withTaskGroup(of: (UUID, [DatabaseInfo]).self) { group in
                for (config, driver) in drivers {
                    group.addTask {
                        let databases = (try? await driver.listDatabases()) ?? []
                        return (config.id, databases)
                    }
                }
                for await (id, databases) in group {
                    guard generation == self.generation, isPresented else { return }
                    guard let config = connections.first(where: { $0.id == id }) else { continue }
                    append(databases.map { database in
                        PaletteItem(
                            id: "db/\(id.uuidString)/\(database.name)",
                            title: database.name,
                            subtitle: config.name,
                            icon: .database,
                            shortcut: nil,
                            kind: .database,
                            action: .openDatabase(connectionID: id, database: database.name),
                            searchText: "\(database.name) \(config.name) \(config.host)"
                        )
                    }, generation: generation)
                }
            }
        }

        guard generation == self.generation, scope == .all, !Task.isCancelled, isPresented else { return }
        guard let target = objectTarget(workspace: workspace) else { return }

        let driver = app.drivers.driver(for: target.config)
        async let schemasTask = driver.listSchemas(database: target.database)
        async let objectsTask = driver.listObjects(database: target.database)

        let schemas = (try? await schemasTask) ?? []
        let objects = (try? await objectsTask) ?? []
        guard generation == self.generation, !Task.isCancelled, isPresented else { return }

        var items: [PaletteItem] = schemas.map { schema in
            PaletteItem(
                id: "schema/\(target.config.id.uuidString)/\(target.database)/\(schema.name)",
                title: schema.name,
                subtitle: "\(target.config.name) · \(target.database)",
                icon: .folder,
                shortcut: nil,
                kind: .schema,
                action: .newQuery(
                    connectionID: target.config.id,
                    database: target.database,
                    schema: schema.name
                ),
                searchText: "\(schema.name) \(target.database) \(target.config.name)"
            )
        }

        items.append(contentsOf: objects.map { object in
            let subtitle = "\(object.kind.displayName) · \(object.schema) · \(target.config.name)"
            let action: PaletteAction
            let kind: PaletteItem.Kind
            let icon: IconSymbol
            switch object.kind {
            case .table:
                kind = .table
                icon = .table
                action = .openTable(
                    connectionID: target.config.id,
                    database: target.database,
                    schema: object.schema,
                    table: object.name,
                    isTable: true
                )
            case .view, .materializedView:
                kind = .view
                icon = .view
                action = .openTable(
                    connectionID: target.config.id,
                    database: target.database,
                    schema: object.schema,
                    table: object.name,
                    isTable: false
                )
            case .function, .procedure:
                kind = .routine
                icon = .newQuery
                action = .openRoutine(
                    connectionID: target.config.id,
                    database: target.database,
                    schema: object.schema,
                    name: object.name,
                    isProcedure: object.kind == .procedure
                )
            }
            return PaletteItem(
                id: "obj/\(target.config.id.uuidString)/\(target.database)/\(object.id)",
                title: object.name,
                subtitle: subtitle,
                icon: icon,
                shortcut: nil,
                kind: kind,
                action: action,
                searchText: "\(object.name) \(object.schema) \(object.kind.displayName) \(target.database) \(target.config.name)"
            )
        })

        append(items, generation: generation)
    }

    private func objectTarget(workspace: WorkspaceState) -> (config: ConnectionConfig, database: String)? {
        if let tab = workspace.activeTab,
           let config = workspace.app.connections.connection(id: tab.connectionID) {
            return (config, tab.database)
        }
        guard let config = workspace.app.connections.connections.first else { return nil }
        return (config, config.maintenanceDatabase)
    }

    private func append(_ newItems: [PaletteItem], generation: Int) {
        guard isPresented, generation == self.generation else { return }
        let existing = Set(allItems.map(\.id))
        allItems.append(contentsOf: newItems.filter { !existing.contains($0.id) })
    }
}

/// Abre a cena de Configurações a partir de uma ação da paleta.
enum SettingsOpener {
    @MainActor
    static func open() {
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

// MARK: - Overlay

struct CommandPaletteOverlay: View {
    @Bindable var palette: CommandPaletteModel
    @State private var keyMonitor: Any?

    private var visibleItems: [PaletteItem] { Array(palette.items.prefix(80)) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { palette.dismiss() }

            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                footer
            }
            .frame(width: 660)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
            .padding(.top, 84)
        }
        .onAppear {
            // ⌘↵ costuma ser capturado pelo menu "Executar"; aqui ele abre em nova aba.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let isReturn = event.keyCode == 36 || event.keyCode == 76
                guard isReturn, event.modifierFlags.contains(.command) else { return event }
                MainActor.assumeIsolated { palette.submit(newTab: true) }
                return nil
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Icon(.search, size: 17)
                .foregroundStyle(.secondary)

            PaletteSearchField(
                text: $palette.query,
                placeholder: palette.scope.placeholder,
                onMove: { palette.move($0) },
                onSubmit: { palette.submit(newTab: $0) },
                onComplete: { palette.complete() },
                onEscape: { palette.escape() }
            )
            .frame(height: 26)

            if palette.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }

            Text(palette.scope.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    @ViewBuilder
    private var content: some View {
        if visibleItems.isEmpty {
            VStack(spacing: 8) {
                if palette.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Carregando objetos…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Icon(.search, size: 24)
                        .foregroundStyle(.tertiary)
                    Text("Nenhum resultado")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, isSelected: index == palette.selectedIndex)
                                .id(item.id)
                                .onTapGesture {
                                    palette.select(index)
                                    palette.submit()
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
                .onChange(of: palette.selectedIndex) { _, index in
                    guard visibleItems.indices.contains(index) else { return }
                    withAnimation(.snappy(duration: 0.12)) {
                        proxy.scrollTo(visibleItems[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↑↓", "navegar")
            hint("↵", "abrir")
            hint("⌘↵", "nova aba")
            hint("Tab", "completar")
            hint("Esc", "limpar/fechar")
            Spacer()
            Text("⌘P")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Icon(item.icon, size: 15)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                }
            }

            Spacer(minLength: 8)

            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        (isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .contentShape(Rectangle())
    }
}

// MARK: - Search field

/// Campo AppKit para capturar Return, Tab, Esc, ↑↓ e ⌃P/⌃N com confiabilidade.
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMove: (Int) -> Void
    var onSubmit: (Bool) -> Void
    var onComplete: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = PaletteTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField

        init(_ parent: PaletteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                parent.onSubmit(command)
                return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onComplete()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

/// Foca o campo assim que ele entra na janela, sem precisar de dispatch assíncrono.
final class PaletteTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if window.firstResponder !== currentEditor() {
            window.makeFirstResponder(self)
        }
    }
}
