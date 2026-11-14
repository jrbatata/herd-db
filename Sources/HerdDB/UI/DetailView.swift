import SwiftUI
import HerdCore

struct DetailView: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 0) {
            if workspace.tabs.isEmpty {
                EmptyWorkspaceView(workspace: workspace)
            } else {
                TabBarView(workspace: workspace)
                Divider()
                if let tab = workspace.activeTab {
                    QueryTabView(tab: tab)
                        .id(tab.id)
                } else {
                    EmptyWorkspaceView(workspace: workspace)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TabBarView: View {
    @Bindable var workspace: WorkspaceState
    @State private var hoveredTab: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.tabs) { tab in
                    tabItem(tab)
                }

                Button {
                    workspace.newQueryTab()
                } label: {
                    SolarIcon(.plus, size: 14)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Nova consulta (⌘T)")
                .padding(.leading, 4)
            }
            .padding(.vertical, 5)
        }
        .padding(.leading, 6)
        .frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabItem(_ tab: QueryTab) -> some View {
        let isActive = workspace.activeTabID == tab.id
        let isHovered = hoveredTab == tab.id

        return HStack(spacing: 6) {
            SolarIcon(tab.state.isFailure ? .warning : .code, size: 13)
                .foregroundStyle(tab.state.isFailure ? Color.red : (isActive ? Color.secondary : Color.secondary.opacity(0.7)))

            Text(tab.title)
                .font(.system(size: 11.5, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

            Button {
                workspace.closeTab(tab)
            } label: {
                SolarIcon(.close, size: 11)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isActive || isHovered ? 1 : 0)
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color(nsColor: .controlBackgroundColor) : (isHovered ? Color.primary.opacity(0.05) : .clear))
                .shadow(color: isActive ? .black.opacity(0.07) : .clear, radius: 1, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isActive ? Color(nsColor: .separatorColor) : .clear, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.activeTabID = tab.id }
        .onHover { hoveredTab = $0 ? tab.id : nil }
    }
}

struct EmptyWorkspaceView: View {
    let workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 10) {
            SolarIcon(.database, size: 46)
                .foregroundStyle(.tertiary)

            Text("Sem aba aberta")
                .font(.system(size: 15, weight: .semibold))

            Text("Selecione uma tabela na barra lateral ou abra uma consulta.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button("Nova consulta") {
                workspace.newQueryTab()
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension QueryRunState {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
