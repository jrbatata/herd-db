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
        .defaultSize(width: 1180, height: 760)
        .commands {
            HerdCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct HerdCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Nova consulta") {
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

        CommandMenu("Consulta") {
            Button("Executar") {
                workspace?.runActiveTab()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canRun)

            Button("Fechar aba") {
                workspace?.closeActiveTab()
            }
            .disabled(workspace?.activeTab == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Atualizar árvore") {
                workspace?.tree.reloadAll()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(workspace == nil)
        }
    }

    private var canRun: Bool {
        guard let tab = workspace?.activeTab else { return false }
        return !tab.isRunning && !tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
