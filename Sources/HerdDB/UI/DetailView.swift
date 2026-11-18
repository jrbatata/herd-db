import AppKit
import SwiftUI
import HerdCore

struct DetailView: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        Group {
            if workspace.processes.visible && workspace.activeTabID == workspace.processesTabID {
                DatabaseProcessesView(processes: workspace.processes)
            } else if let tab = workspace.activeTab {
                QueryTabView(tab: tab, workspace: workspace)
                    .id(tab.id)
            } else {
                EmptyWorkspaceView(workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 1)
    }
}

/// Barra superior (na altura dos semáforos) com as abas abertas.
struct TopBarView: View {
    @Bindable var workspace: WorkspaceState
    let leadingInset: CGFloat
    @State private var hoveredTab: UUID?

    var body: some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                // Poucas abas: tudo cabe e o botão de novo script fica colado na última.
                HStack(spacing: 4) {
                    tabsRow
                    newScriptButton
                    Spacer(minLength: 0)
                }

                // Muitas abas: a faixa de abas rola e o botão fica fixo à direita.
                HStack(spacing: 4) {
                    ScrollViewReader { reader in
                        ScrollView(.horizontal, showsIndicators: false) {
                            tabsRow
                        }
                        .onChange(of: workspace.activeTabID) { _, id in
                            guard let id else { return }
                            withAnimation(.snappy(duration: 0.2)) { reader.scrollTo(id, anchor: .center) }
                        }
                        .onChange(of: workspace.tabs.count) { _, _ in
                            guard let id = workspace.activeTabID else { return }
                            withAnimation(.snappy(duration: 0.2)) { reader.scrollTo(id, anchor: .trailing) }
                        }
                    }
                    newScriptButton
                }
            }
            HStack(spacing: 0) {
                WindowIconButton(symbol: .sidebarLeft, selected: workspace.sidebarVisible,
                                 help: "Alternar barra lateral (⌘B)") {
                    workspace.sidebarVisible.toggle()
                }
                WindowIconButton(symbol: .panelBottom, selected: workspace.resultsVisible,
                                 help: "Alternar resultados (⌘J)") {
                    workspace.resultsVisible.toggle()
                }
                WindowIconButton(symbol: .sidebar, selected: workspace.inspectorVisible,
                                 help: "Alternar inspetor (⌥⌘B)") {
                    workspace.inspectorVisible.toggle()
                }
                WindowIconButton(symbol: .processes, selected: workspace.processes.visible,
                                 help: "Ver processos de backup, restore e CSV (⌥⌘P)") {
                    workspace.openProcesses()
                }
                WindowIconButton(symbol: .clock, selected: workspace.consoleVisible,
                                 help: "Alternar console de log (⌃⌘C)") {
                    workspace.toggleConsole()
                }
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(height: 36)
        .zIndex(10)
    }

    private var tabsRow: some View {
        HStack(spacing: 4) {
            ForEach(workspace.tabs) { tab in
                tabItem(tab)
                    .id(tab.id)
            }
            if workspace.processes.visible {
                processesTab
                    .id(workspace.processesTabID)
            }
        }
    }

    private var processesTab: some View {
        let active = workspace.activeTabID == workspace.processesTabID
        return HStack(spacing: 7) {
            Icon(.processes, size: 14)
            Text("Processos")
                .font(.system(size: 12, weight: active ? .medium : .regular))
            Button { workspace.closeProcesses() } label: { Icon(.close, size: 11) }
                .buttonStyle(.plain)
                .help("Fechar aba Processos")
        }
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .padding(.horizontal, 10)
        .frame(height: 27)
        .background(active ? Color(nsColor: .windowBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { workspace.openProcesses() }
    }

    @ViewBuilder
    private var newScriptButton: some View {
        if !workspace.tabs.isEmpty {
            WindowIconButton(symbol: .plus, selected: false, help: "Novo script (⌘T)") {
                workspace.newQueryTab()
            }
        }
    }

    private func tabItem(_ tab: QueryTab) -> some View {
        let isActive = workspace.activeTabID == tab.id
        let isHovered = hoveredTab == tab.id
        let connection = workspace.app.connections.connection(id: tab.connectionID)

        return HStack(spacing: 7) {
            Icon(tab.state.tabSymbol, size: 14, solid: isActive)
                .foregroundStyle(tab.state.tabColor(isActive: isActive))

            Text(tab.title + (tab.hasUnsavedChanges ? " •" : ""))
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

            if let connection, connection.isProduction {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .help("Conexão de produção")
            } else if let connection, connection.safeMode.isRestricted {
                Circle()
                    .fill(connection.safeMode.tint)
                    .frame(width: 6, height: 6)
                    .help("Proteção: \(connection.safeMode.displayName)")
            }

            Button {
                workspace.closeTab(tab)
            } label: {
                Icon(.close, size: 11)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isActive || isHovered ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 120, maxWidth: 180)
        .frame(height: 27)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color(nsColor: .windowBackgroundColor) : (isHovered ? Color.primary.opacity(0.06) : .clear))
                .shadow(color: isActive ? .black.opacity(0.08) : .clear, radius: 2, y: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.activeTabID = tab.id }
        .contextMenu {
            Button("Fechar") { workspace.closeTab(tab) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Fechar outras") { workspace.closeOthers(except: tab) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(workspace.tabs.count < 2)
            Button("Fechar à direita") { workspace.closeTabs(after: tab) }
                .disabled(workspace.tabs.last?.id == tab.id)
            Button("Fechar todas") { workspace.closeAllTabs() }
                .keyboardShortcut("w", modifiers: [.command, .shift])

            Divider()

            Button("Copiar SQL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.sql, forType: .string)
            }
            .disabled(!tab.hasText)
            Button("Copiar nome") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.title, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
        }
        .onHover { hoveredTab = $0 ? tab.id : nil }
    }
}

struct WindowIconButton: View {
    let symbol: IconSymbol
    let selected: Bool
    let help: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    init(symbol: IconSymbol, selected: Bool, help: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.selected = selected
        self.help = help
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(symbol, size: 16, solid: selected)
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : (selected ? Color.primary : Color.secondary))
                .frame(width: 26, height: 28)
                .background((hovering && !disabled) ? Color.primary.opacity(0.09) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(help)
        .help(help)
        .onHover { inside in
            hovering = inside
        }
    }
}

struct EmptyWorkspaceView: View {
    let workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 14) {
            Icon(.newQuery, size: 30)
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }

            VStack(spacing: 5) {
                Text("Nenhum script aberto")
                    .font(.system(size: 15, weight: .semibold))

                Text("Abra uma tabela na barra lateral ou comece um novo script.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                workspace.newQueryTab()
            } label: {
                HStack(spacing: 7) {
                    Icon(.newQuery, size: 14)
                    Text("Novo script")
                    KeyHint("⌘T", onProminent: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 2)

        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension QueryRunState {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var tabSymbol: IconSymbol {
        if isFailure { return .warning }
        if isCancelled { return .closeCircle }
        return .newQuery
    }

    func tabColor(isActive: Bool) -> Color {
        if isFailure { return .red }
        if isCancelled { return .secondary }
        return isActive ? Color.primary.opacity(0.75) : Color.secondary
    }
}
