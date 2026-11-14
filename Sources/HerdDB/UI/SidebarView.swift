import AppKit
import SwiftUI
import HerdCore

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Bindable var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 0) {
            topActions
            filterField
            header

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
            iconButton(.refresh, help: "Atualizar árvore (⌘R)") { workspace.tree.reloadAll() }
            iconButton(.newQuery, help: "Novo script (⌘T)") { workspace.newQueryTab() }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private func iconButton(_ symbol: IconSymbol, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol, size: 16)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var filterField: some View {
        @Bindable var tree = workspace.tree

        return HStack(spacing: 7) {
            Icon(.search, size: 15)
                .foregroundStyle(.secondary)
            TextField("Filtrar objetos", text: $tree.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Conexões")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                workspace.presentNewConnection()
            } label: {
                Icon(.newConnection, size: 16)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Nova conexão (⇧⌘N)")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
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
                .fill(app.connections.connections.isEmpty ? Color.secondary.opacity(0.4) : Color.green)
                .frame(width: 6, height: 6)
            Text(connectionCountText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
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
        node.isSelectable && tree.selection == node.id
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
        .onTapGesture { tree.select(node) }
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
        // Paleta enxuta: azul só no que é aberto/navegável (conexão, tabela, view),
        // âmbar nas chaves, o resto neutro.
        switch node.kind {
        case .connection, .table, .view:
            return .accentColor
        case .database, .schema, .tablesFolder, .viewsFolder:
            return .secondary
        case .column:
            if node.column?.isPrimaryKey == true { return .orange }
            return Color.secondary.opacity(0.8)
        case .error:
            return .red
        }
    }

    private func handleDoubleClick() {
        tree.select(node)
        switch node.kind {
        case .table, .view:
            workspace.openTable(node)
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
                Button("Editar conexão…") { workspace.presentEditConnection(config) }
                Divider()
                Button("Atualizar") { tree.reload(node) }
                Divider()
                Button("Remover conexão…", role: .destructive) { confirmRemoval = true }
            }

        case .table, .view:
            Button("Abrir dados") { workspace.openTable(node) }
            Button("Novo script") { workspace.newQueryTab(for: node) }
            Divider()
            Button("Copiar nome") { copy(node.title) }
            Button("Atualizar") { tree.reload(node) }

        case .database, .schema, .tablesFolder, .viewsFolder:
            Button("Novo script") { workspace.newQueryTab(for: node) }
            Divider()
            Button("Copiar nome") { copy(node.title) }
            Button("Atualizar") { tree.reload(node) }

        case .column:
            Button("Copiar nome") { copy(node.title) }

        case .error:
            Button("Tentar novamente") { tree.retry(afterErrorNode: node) }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
