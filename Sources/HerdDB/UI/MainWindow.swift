import SwiftUI
import HerdCore

struct WorkspaceFocusedValueKey: FocusedValueKey {
    typealias Value = WorkspaceState
}

extension FocusedValues {
    var workspace: WorkspaceState? {
        get { self[WorkspaceFocusedValueKey.self] }
        set { self[WorkspaceFocusedValueKey.self] = newValue }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @State private var workspace: WorkspaceState

    init(app: AppModel) {
        _workspace = State(initialValue: WorkspaceState(app: app))
    }

    var body: some View {
        @Bindable var workspace = workspace

        NavigationSplitView {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            DetailView(workspace: workspace)
        }
        .navigationTitle(workspace.windowTitle)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 960, minHeight: 600)
        .toolbar { toolbar }
        .focusedSceneValue(\.workspace, workspace)
        .sheet(item: $workspace.connectionEditor) { editor in
            ConnectionSheet(editor: editor, workspace: workspace)
                .environment(app)
        }
        .alert(
            workspace.alert?.title ?? "",
            isPresented: Binding(
                get: { workspace.alert != nil },
                set: { if !$0 { workspace.alert = nil } }
            ),
            presenting: workspace.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .onChange(of: app.connections.connections) { _, _ in
            workspace.tree.syncConnections()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.newQueryTab()
            } label: {
                Label("Nova consulta", systemImage: "plus.bubble")
            }
            .help("Nova consulta (⌘T)")

            Button {
                workspace.tree.reloadAll()
            } label: {
                Label("Atualizar", systemImage: "arrow.clockwise")
            }
            .help("Atualizar árvore (⌘R)")
        }
    }
}
