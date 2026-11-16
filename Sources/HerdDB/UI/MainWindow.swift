import AppKit
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
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 270
    @State private var dragStartWidth: Double?
    @State private var isFullScreen = false

    /// Espaço reservado à esquerda para os semáforos + botão da sidebar.
    private let controlsInset: CGFloat = 128

    init(app: AppModel) {
        _workspace = State(initialValue: WorkspaceState(app: app))
    }

    var body: some View {
        @Bindable var workspace = workspace

        ZStack(alignment: .topLeading) {
            VisualEffectBackground(material: .sidebar)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                if workspace.sidebarVisible {
                    SidebarView(workspace: workspace)
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    resizeHandle
                }

                VStack(spacing: 0) {
                    TopBarView(
                        workspace: workspace,
                        leadingInset: workspace.sidebarVisible ? 4 : (isFullScreen ? 8 : controlsInset)
                    )
                    DetailView(workspace: workspace)
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                        .padding(.leading, workspace.sidebarVisible ? 0 : 8)
                }
            }
            .ignoresSafeArea()

            if !isFullScreen { sidebarToggle }

            if workspace.palette.isPresented {
                CommandPaletteOverlay(palette: workspace.palette)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .background(WindowConfigurator(
            onFullScreenChange: { isFullScreen = $0 },
            onCloseRequest: { workspace.confirmCloseWindow() }
        ))
        .focusEffectDisabled()
        .navigationTitle(workspace.windowTitle)
        .frame(minWidth: 960, minHeight: 600)
        .focusedSceneValue(\.workspace, workspace)
        .sheet(item: $workspace.connectionEditor) { editor in
            ConnectionSheet(editor: editor, workspace: workspace)
                .environment(app)
        }
        .sheet(item: $workspace.tableWizard) { wizard in
            CreateTableSheet(wizard: wizard, workspace: workspace)
                .environment(app)
        }
        .sheet(item: $workspace.schemaWizard) { wizard in
            CreateSchemaSheet(wizard: wizard, workspace: workspace)
                .environment(app)
        }
        .sheet(item: $workspace.databaseWizard) { wizard in
            CreateDatabaseSheet(wizard: wizard, workspace: workspace)
                .environment(app)
        }
        .sheet(item: $workspace.tableStructure) { state in
            TableStructureSheet(state: state, workspace: workspace)
                .environment(app)
        }
        .sheet(item: $workspace.dropWizard) { wizard in
            DropObjectSheet(wizard: wizard, workspace: workspace)
                .environment(app)
        }
        .sheet(item: $workspace.backupWizard) { wizard in
            BackupSheet(wizard: wizard, workspace: workspace)
                .environment(app)
        }
        .sheet(item: $workspace.restoreWizard) { wizard in
            RestoreSheet(wizard: wizard, workspace: workspace)
                .environment(app)
        }
        .sheet(item: $workspace.tableSubObjectWizard) { wizard in
            CreateTableSubObjectSheet(wizard: wizard, workspace: workspace)
                .environment(app)
        }
        .onChange(of: workspace.processes.visible) { _, visible in
            if visible { workspace.activeTabID = workspace.processesTabID }
            else if workspace.activeTabID == workspace.processesTabID {
                workspace.activeTabID = workspace.tabs.last?.id
            }
        }
        .onChange(of: workspace.processes.entries.count) { oldCount, newCount in
            if newCount > oldCount { workspace.openProcesses() }
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

    private var sidebarToggle: some View {
        WindowIconButton(symbol: .sidebarLeft, selected: workspace.sidebarVisible,
                         help: "Mostrar ou ocultar a barra lateral (⌘B)") {
            withAnimation(.snappy(duration: 0.25)) { workspace.sidebarVisible.toggle() }
        }
        .padding(.leading, 82)
        .padding(.top, 4)
        .ignoresSafeArea()
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? sidebarWidth
                        dragStartWidth = start
                        sidebarWidth = min(420, max(220, start + value.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .padding(.horizontal, -3)
    }
}
