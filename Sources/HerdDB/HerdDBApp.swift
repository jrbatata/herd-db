import AppKit
import SwiftUI

@main
struct HerdDBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            MainWindow(app: app)
                .environment(app)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            HerdCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    private static let lightIcon = NSImage(named: "AppIcon")
    private static let darkIcon: NSImage? = Bundle.main.url(forResource: "AppIconDark", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.updateIcon()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { Self.updateIcon() }
        }
    }

    /// Ícone claro (TintedLight) por padrão; no modo escuro troca pelo ícone Dark.
    private static func updateIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSApp.applicationIconImage = isDark ? (darkIcon ?? lightIcon) : lightIcon
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct HerdCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Novo script") {
                workspace?.newQueryTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(workspace == nil)

            Button("Nova conexão…") {
                workspace?.presentNewConnection()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(workspace == nil)
        }

        CommandMenu("Script") {
            Button("Executar") {
                workspace?.runActiveTab(scope: .automatic)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canRun)

            Button("Executar seleção") {
                workspace?.runActiveTab(scope: .selection)
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(!canRun)

            Button("Executar tudo") {
                workspace?.runActiveTab(scope: .all)
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!canRun)

            Button("Cancelar execução") {
                workspace?.cancelActiveTab()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!isRunning)

            Divider()

            Button("Fechar aba") {
                workspace?.closeActiveTab()
            }
            .disabled(workspace?.activeTab == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Alternar barra lateral") {
                withAnimation(.snappy(duration: 0.25)) { workspace?.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(workspace == nil)

            Button("Atualizar árvore") {
                workspace?.tree.reloadAll()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(workspace == nil)
        }
    }

    private var canRun: Bool {
        guard let tab = workspace?.activeTab else { return false }
        return !tab.isRunning && tab.hasText
    }

    private var isRunning: Bool {
        workspace?.activeTab?.isRunning ?? false
    }
}
