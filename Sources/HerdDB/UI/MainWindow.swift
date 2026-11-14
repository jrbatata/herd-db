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
                        leadingInset: workspace.sidebarVisible ? 4 : controlsInset
                    )
                    DetailView(workspace: workspace)
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                        .padding(.leading, workspace.sidebarVisible ? 0 : 8)
                }
            }
            .ignoresSafeArea()

            sidebarToggle
        }
        .background(WindowConfigurator())
        .focusEffectDisabled()
        .navigationTitle(workspace.windowTitle)
        .frame(minWidth: 960, minHeight: 600)
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

    private var sidebarToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { workspace.sidebarVisible.toggle() }
        } label: {
            Icon(.sidebar, size: 18)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mostrar ou ocultar a barra lateral (⌃⌘S)")
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
