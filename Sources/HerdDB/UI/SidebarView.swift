import AppKit
import SwiftUI
import HerdCore

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Bindable var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 0) {
            topActions
                .zIndex(10)
            filterField

            if app.connections.connections.isEmpty {
                emptyState
            } else if workspace.tree.rows.isEmpty {
                noResultsState
            } else {
                treeList
            }

            footer
        }
    }

    /// Linha na altura dos semáforos: o botão de sidebar fica à esquerda (sobreposto pela janela),
    /// atualizar e nova consulta ficam à direita.
    private var topActions: some View {
        HStack(spacing: 2) {
            Spacer()
            WindowIconButton(symbol: .refresh, selected: false, help: "Atualizar árvore (⌘R)") { workspace.tree.reloadAll() }
            WindowIconButton(symbol: .newConnection, selected: false, help: "Nova conexão (⇧⌘N)") { workspace.presentNewConnection() }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    @FocusState private var filterFocused: Bool

    private var filterField: some View {
        @Bindable var tree = workspace.tree

        return HStack(spacing: 7) {
            Icon(.search, size: 15)
                .foregroundStyle(.secondary)
            TextField("Filtrar objetos", text: $tree.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($filterFocused)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.accentColor.opacity(filterFocused ? 0.85 : 0), lineWidth: 2.5)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.accentColor.opacity(filterFocused ? 0.25 : 0), lineWidth: 5)
                .padding(-2.5)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: filterFocused)
        .onChange(of: workspace.focusFilterToken) { _, _ in
            filterFocused = true
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var treeList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(workspace.tree.rows) { row in
                    TreeRowView(row: row, tree: workspace.tree, workspace: workspace)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Icon(.database, size: 34)
                .foregroundStyle(.tertiary)
            Text("Nenhuma conexão")
                .font(.system(size: 13, weight: .semibold))
            Text("Adicione um servidor PostgreSQL para começar.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Nova conexão…") {
                workspace.presentNewConnection()
            }
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 6) {
            Spacer()
            Icon(.search, size: 26)
                .foregroundStyle(.tertiary)
            Text("Nenhum objeto encontrado")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(footerStatusColor)
                .frame(width: 6, height: 6)
            Text(connectionCountText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    /// Verde apenas quando há alguma sessão aberta; conexões desconectadas ficam neutras.
    private var footerStatusColor: Color {
        workspace.tree.connectedIDs.isEmpty ? Color.secondary.opacity(0.4) : Color.green
    }

    private var connectionCountText: String {
        let count = app.connections.connections.count
        return count == 1 ? "1 conexão" : "\(count) conexões"
    }
}

struct TreeRowView: View {
    let row: TreeRow
    let tree: ObjectTreeModel
    let workspace: WorkspaceState

    @State private var isHovering = false
    @State private var confirmRemoval = false

    private var node: TreeNode { row.node }
    private var isSelected: Bool {
        node.isSelectable && (tree.selectedIDs.contains(node.id) || tree.selection == node.id)
    }
    /// Recursos de DDL, backup e processos ainda são específicos do PostgreSQL.
    private var isPostgres: Bool {
        workspace.app.connections.connection(id: node.connectionID)?.engine == .postgres
    }

    var body: some View {
        HStack(spacing: 5) {
            chevron

            Icon(node.symbolName, size: node.kind == .column ? 12 : 16, solid: isSelected)
                .foregroundStyle(iconColor)
                .frame(width: 17)

            Text(node.title)
                .font(.system(size: 12.5, weight: node.kind == .connection ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(textColor)

            Spacer(minLength: 4)

            if let detail = node.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
            }

            if row.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            } else if node.kind == .connection {
                connectionStatus
            }
        }
        .padding(.leading, CGFloat(row.depth) * 13 + 4)
        .padding(.trailing, 7)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { handleDoubleClick() }
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            tree.select(
                node,
                extendRange: flags.contains(.shift),
                toggleSingle: flags.contains(.command)
            )
        }
        .contextMenu { contextMenu }
        .confirmationDialog(
            "Remover “\(node.title)”?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Remover conexão", role: .destructive) {
                if let config = workspace.app.connections.connection(id: node.connectionID) {
                    workspace.remove(config)
                }
            }
        } message: {
            Text("Os dados da conexão e a senha salva no Chaveiro serão apagados.")
        }
    }

    /// Estado da sessão, alinhado à direita da linha: clique para alternar.
    private var connectionStatus: some View {
        let connected = tree.connectedIDs.contains(node.connectionID)
        return Button {
            if connected {
                tree.disconnect(node)
            } else {
                tree.connect(node)
            }
        } label: {
            Icon(connected ? .check : .alertCircle, size: 14, solid: true)
                .foregroundStyle(connected ? Color.green : Color.red)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(connected ? "Conectado — clique para desconectar" : "Desconectado — clique para conectar")
    }

    private var chevron: some View {
        Group {
            if node.isExpandable {
                Button {
                    tree.toggle(node)
                } label: {
                    Icon(.chevron, size: 12, solid: isSelected)
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 18)
            }
        }
    }

    private var textColor: Color {
        if node.kind == .error { return .red }
        return isSelected ? .white : .primary
    }

    private var backgroundColor: Color {
        if isSelected { return .accentColor }
        if node.kind == .error { return .clear }
        return isHovering ? Color.primary.opacity(0.055) : .clear
    }

    private var iconColor: Color {
        if node.kind == .error { return .red }
        if isSelected { return .white }
        if node.kind == .connection { return .secondary }
        // Paleta enxuta: azul somente no que é aberto/navegável (conexão, tabela, view),
        // âmbar nas chaves, o resto neutro.
        switch node.kind {
        case .table, .view:
            return .accentColor
        case .database, .schema, .tablesFolder, .viewsFolder, .routinesFolder, .routine:
            return .secondary
        case .column:
            if node.column?.isPrimaryKey == true { return .orange }
            return Color.secondary.opacity(0.8)
        case .connection, .error:
            return .secondary
        }
    }

    private func handleDoubleClick() {
        tree.select(node)
        switch node.kind {
        case .table, .view:
            workspace.openTable(node)
        case .routine:
            workspace.openRoutineCall(node)
        case .error:
            tree.retry(afterErrorNode: node)
        default:
            if node.isExpandable { tree.toggle(node) }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        switch node.kind {
        case .connection:
            if let config = workspace.app.connections.connection(id: node.connectionID) {
                Button("Novo script") { workspace.newQueryTab(for: config) }
                    .keyboardShortcut("t", modifiers: .command)
                if isPostgres {
                    Button("Criar banco de dados…") { workspace.presentCreateDatabase(for: config) }
                        .keyboardShortcut("d", modifiers: [.command, .option])
                }
                Button("Editar conexão…") { workspace.presentEditConnection(config) }
                    .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button("Atualizar") { tree.reload(node) }
                    .keyboardShortcut("r", modifiers: .command)
                if tree.connectedIDs.contains(node.connectionID) {
                    Button("Desconectar") { tree.disconnect(node) }
                } else {
                    Button("Conectar") { tree.connect(node) }
                }
                Divider()
                Button("Remover conexão…", role: .destructive) { confirmRemoval = true }
                    .keyboardShortcut(.delete, modifiers: .command)
            }

        case .table, .view:
            Button("Abrir dados") { workspace.openTable(node) }
                .keyboardShortcut(.return, modifiers: [])
            if node.kind == .table, isPostgres {
                Button("Estrutura / DDL…") { workspace.presentTableStructure(for: node) }
                    .keyboardShortcut("i", modifiers: .command)
            }
            Button("Novo script") { workspace.newQueryTab(for: node) }
                .keyboardShortcut("t", modifiers: .command)
            Menu("Scripts SQL") {
                ForEach(SQLReadyQuery.allCases, id: \.self) { query in
                    Button(query.title) {
                        workspace.openReadyQuery(query, for: node)
                    }
                    .keyboardShortcut(query.shortcut, modifiers: [.command, .option, .shift])
                }
                if node.kind == .table {
                    Divider()
                    Button("CREATE (DDL)") {
                        workspace.openCreateTableScript(for: node)
                    }
                    .keyboardShortcut("6", modifiers: [.command, .option, .shift])
                }
            }
            if node.kind == .table, isPostgres {
                Menu("Criar") {
                    Button("Tabela…") { workspace.presentCreateTable(for: node) }
                        .keyboardShortcut("n", modifiers: [.command, .option])
                    Button("Schema…") { workspace.presentCreateSchema(for: node) }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                    Divider()
                    Button("Coluna…") { workspace.create(.column, for: node) }
                        .keyboardShortcut("k", modifiers: [.command, .option])
                    Button("Índice…") { workspace.create(.index, for: node) }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    Button("Regra…") { workspace.create(.rule, for: node) }
                        .keyboardShortcut("u", modifiers: [.command, .option])
                    Button("Trigger…") { workspace.create(.trigger, for: node) }
                        .keyboardShortcut("g", modifiers: [.command, .option])
                    Button("Política RLS…") { workspace.create(.policy, for: node) }
                        .keyboardShortcut("y", modifiers: [.command, .option])
                }
            } else if isPostgres {
                Button("Criar tabela…") { workspace.presentCreateTable(for: node) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            if isPostgres {
                Button("Excluir…", role: .destructive) { workspace.presentDropObject(for: node) }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Excluir em cascata…", role: .destructive) { workspace.presentDropObject(for: node, force: true) }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
            }
            if node.kind == .table {
                Divider()
                Button("Backup…") { workspace.presentBackup(for: node) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            if node.kind == .table, isPostgres {
                Menu("Importar/Exportar CSV") {
                    Button("Importar CSV…") { workspace.processes.transferCSV(node, connections: workspace.app.connections, importing: true) }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                    Button("Exportar CSV…") { workspace.processes.transferCSV(node, connections: workspace.app.connections, importing: false) }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                }
            }
            if isPostgres {
                Button("Ver processos…") { workspace.openProcesses() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
            Divider()
            Button("Copiar nome") { copy(node.title) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Atualizar") { tree.reload(node) }
                .keyboardShortcut("r", modifiers: .command)

        case .database, .schema, .tablesFolder, .viewsFolder, .routinesFolder:
            Button("Novo script") { workspace.newQueryTab(for: node) }
                .keyboardShortcut("t", modifiers: .command)
            if isPostgres, node.kind == .database || node.kind == .schema || node.kind == .tablesFolder {
                Menu("Criar") {
                    if let config = workspace.app.connections.connection(id: node.connectionID) {
                        Button("Banco de dados…") { workspace.presentCreateDatabase(for: config) }
                            .keyboardShortcut("d", modifiers: [.command, .option])
                        Divider()
                    }
                    Button("Tabela…") { workspace.presentCreateTable(for: node) }
                        .keyboardShortcut("n", modifiers: [.command, .option])
                    Button("Schema…") { workspace.presentCreateSchema(for: node) }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                }
            }
            if isPostgres, node.kind == .database || node.kind == .schema {
                Button("Excluir…", role: .destructive) { workspace.presentDropObject(for: node) }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button(node.kind == .database ? "Excluir forçando desconexão…" : "Excluir em cascata…", role: .destructive) {
                    workspace.presentDropObject(for: node, force: true)
                }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
            }
            if node.kind == .database {
                Divider()
                Button("Backup…") { workspace.presentBackup(for: node) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Restore…") { workspace.presentRestore(for: node) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                if isPostgres {
                    Button("Ver processos…") { workspace.openProcesses() }
                        .keyboardShortcut("p", modifiers: [.command, .option])
                }
            }
            Divider()
            Button("Copiar nome") { copy(node.title) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Atualizar") { tree.reload(node) }
                .keyboardShortcut("r", modifiers: .command)

        case .routine:
            Button("Abrir chamada no editor") { workspace.openRoutineCall(node) }
                .keyboardShortcut(.return, modifiers: [])
            Divider()
            Button("Copiar nome") { copy(node.title) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Atualizar") { tree.reload(node) }
                .keyboardShortcut("r", modifiers: .command)

        case .column:
            Button("Copiar nome") { copy(node.title) }
                .keyboardShortcut("c", modifiers: [.command, .option])

        case .error:
            Button("Tentar novamente") { tree.retry(afterErrorNode: node) }
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private extension SQLReadyQuery {
    var shortcut: KeyEquivalent {
        switch self {
        case .select: "1"
        case .selectLimited: "2"
        case .insert: "3"
        case .update: "4"
        case .delete: "5"
        }
    }
}
