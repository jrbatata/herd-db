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

        Settings {
            PreferencesView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    private static let lightIcon = NSImage(named: "AppIcon")
    private static let darkIcon: NSImage? = Bundle.main.url(forResource: "AppIconDark", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        Self.updateIcon()
        UpdateController.shared.checkAtLaunch()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in Self.updateIcon() }
        }
    }

    /// Ícone claro (TintedLight) por padrão; no modo escuro troca pelo ícone Dark.
    @MainActor
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
        CommandGroup(after: .appInfo) {
            Button("Verificar Atualizações…") {
                UpdateController.shared.checkManually()
            }
            Divider()
        }

        CommandGroup(replacing: .newItem) {
            Button("Novo script") { workspace?.newQueryTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(workspace == nil)
            Button("Nova conexão…") { workspace?.presentNewConnection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Divider()
            ForEach(NewDBObject.allCases, id: \.self) { object in
                Button(object.fileMenuTitle) { workspace?.create(object) }
                    .keyboardShortcut(object.shortcut, modifiers: [.command, .option])
                    .disabled(workspace?.canCreate(object) != true)
            }
            Divider()
            Button("Abrir arquivo SQL…") { workspace?.openSQLFile() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(workspace == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Salvar script") { workspace?.saveActiveTab() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(workspace?.activeTab == nil)
            Button("Salvar script como…") { workspace?.saveActiveTab(as: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspace?.activeTab == nil)
            Divider()
            Button(workspace?.activeTab == nil ? "Fechar janela" : "Fechar aba") {
                if workspace?.activeTab != nil {
                    workspace?.closeActiveTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Buscar no SQL") { workspace?.performEditor(.find) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspace == nil)
            Button("Substituir no SQL") { workspace?.performEditor(.replace) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(workspace?.hasFocusedEditor != true)
            Button("Filtrar objetos na barra lateral") { workspace?.focusSidebarFilter() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("Ir para linha/coluna…") { workspace?.performEditor(.goToLine) }
                .keyboardShortcut("g", modifiers: .control)
                .disabled(workspace?.hasFocusedEditor != true)
            Divider()
            Button("Indentar seleção") { workspace?.performEditor(.indent) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(workspace?.hasFocusedEditor != true)
            Button("Remover indentação") { workspace?.performEditor(.unindent) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(workspace?.hasFocusedEditor != true)
            Button("Comentar/descomentar") { workspace?.performEditor(.comment) }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(workspace?.hasFocusedEditor != true)
            Button("Alternar maiúsculas/minúsculas") { workspace?.performEditor(.toggleCase) }
                .keyboardShortcut("u", modifiers: [.control, .shift])
                .disabled(workspace?.hasFocusedEditor != true || workspace?.activeTab?.selection.length == 0)
            Button("Limpar consulta") { workspace?.performEditor(.clear) }
                .disabled(workspace?.hasFocusedEditor != true || workspace?.activeTab?.sql.isEmpty != false)
            Button("Formatar SQL") { workspace?.performEditor(.format) }
                .keyboardShortcut("f", modifiers: [.option, .shift])
                .disabled(workspace?.hasFocusedEditor != true || workspace?.activeTab?.sql.isEmpty != false)
        }

        CommandGroup(replacing: .toolbar) {}

        // Remove o "Imprimir…" padrão para liberar ⌘P para a paleta.
        CommandGroup(replacing: .printItem) {}

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

            Button("Fechar outras") {
                if let tab = workspace?.activeTab { workspace?.closeOthers(except: tab) }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled((workspace?.tabs.count ?? 0) < 2)

            Button("Fechar todas") {
                workspace?.closeAllTabs()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(workspace?.activeTab == nil)

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Última aba" : "Aba \(number)") {
                    workspace?.selectTab(at: number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                .disabled((workspace?.tabs.count ?? 0) < (number == 9 ? 1 : number))
            }
        }

        CommandMenu("Ir") {
            Button("Abrir Qualquer Coisa…") { workspace?.openPalette() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(workspace == nil)
            Button("Abrir Banco…") { workspace?.openPalette(scope: .databases) }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(workspace == nil)
            Button("Abrir Conexão…") { workspace?.openPalette(scope: .connections) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Alternar barra lateral") {
                withAnimation(.snappy(duration: 0.25)) { workspace?.sidebarVisible.toggle() }
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(workspace == nil)

            Button("Alternar histórico") { workspace?.inspectorVisible.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(workspace?.activeTab == nil)

            Button("Alternar resultados") { workspace?.resultsVisible.toggle() }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(workspace?.activeTab == nil)

            Button("Alternar console") { workspace?.toggleConsole() }
                .keyboardShortcut("c", modifiers: [.control, .command])
                .disabled(workspace == nil)

            Divider()

            Button("Estrutura da tabela…") {
                workspace?.presentTableStructure()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(workspace?.canShowTableStructure != true)

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

private extension NewDBObject {
    var fileMenuTitle: String {
        switch self {
        case .database: "Novo banco de dados…"
        case .table: "Nova tabela…"
        case .schema: "Novo schema…"
        case .column: "Nova coluna…"
        case .index: "Novo índice…"
        case .rule: "Nova regra…"
        case .trigger: "Novo trigger…"
        case .policy: "Nova política RLS…"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .database: "d"
        case .table: "n"
        case .schema: "s"
        case .column: "k"
        case .index: "i"
        case .rule: "u"
        case .trigger: "g"
        case .policy: "y"
        }
    }
}
