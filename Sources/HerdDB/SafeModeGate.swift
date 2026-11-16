import AppKit
import HerdCore
import SwiftUI

/// Centraliza a confirmação do Safe Mode.
///
/// Deve ser chamado no MainActor, imediatamente antes de enviar comandos que
/// podem alterar dados. Retorna `false` quando o usuário cancela.
@MainActor
enum SafeModeGate {
    /// Autoriza a execução de `sql` de acordo com o nível da conexão.
    static func authorize(
        sql: String,
        config: ConnectionConfig,
        connections: ConnectionStore,
        action: String
    ) -> Bool {
        let mode = config.safeMode
        guard mode.isRestricted else { return true }
        if mode.skipsReadOnly, SQLClassification.isReadOnly(sql) { return true }

        if mode.requiresPassword {
            return askPassword(config: config, connections: connections, action: action)
        }
        return confirm(config: config, sql: sql, action: action)
    }

    /// Autoriza um lote de comandos (por exemplo, o commit do grid).
    static func authorize(
        statements: [String],
        config: ConnectionConfig,
        connections: ConnectionStore,
        action: String
    ) -> Bool {
        authorize(sql: statements.joined(separator: ";\n"), config: config,
                  connections: connections, action: action)
    }

    /// Pede a senha da conexão, usado ao trocar de nível no modo Seguro.
    static func confirmPassword(
        config: ConnectionConfig,
        connections: ConnectionStore,
        action: String
    ) -> Bool {
        askPassword(config: config, connections: connections, action: action)
    }

    // MARK: - Alerts

    private static func confirm(config: ConnectionConfig, sql: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Confirmar execução"
        alert.informativeText = """
        A conexão \(config.name) está no modo \(config.safeMode.displayName).
        Deseja \(action)?

        \(preview(sql))
        """
        alert.addButton(withTitle: "Executar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func askPassword(
        config: ConnectionConfig,
        connections: ConnectionStore,
        action: String
    ) -> Bool {
        guard let expected = connections.password(for: config.id), !expected.isEmpty else {
            // Sem senha no Chaveiro não há o que verificar: cai para a confirmação simples.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Senha não encontrada"
            alert.informativeText = "A conexão \(config.name) está no modo \(config.safeMode.displayName), mas não há senha salva no Chaveiro. Confirme para \(action)."
            alert.addButton(withTitle: "Continuar")
            alert.addButton(withTitle: "Cancelar")
            return alert.runModal() == .alertFirstButtonReturn
        }

        for _ in 0..<3 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Senha necessária"
            alert.informativeText = "A conexão \(config.name) está no modo \(config.safeMode.displayName). Digite a senha para \(action)."
            alert.addButton(withTitle: "Executar")
            alert.addButton(withTitle: "Cancelar")

            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Senha da conexão"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if field.stringValue == expected { return true }

            let error = NSAlert()
            error.alertStyle = .critical
            error.messageText = "Senha incorreta"
            error.informativeText = "Tente novamente."
            error.addButton(withTitle: "OK")
            error.runModal()
        }
        return false
    }

    private static func preview(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 600
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

extension SafeMode {
    /// Cor usada nos indicadores da aba e da barra de título.
    var tint: Color {
        switch self {
        case .silent: .secondary
        case .alert, .alertReadOnly: .orange
        case .secure, .secureReadOnly: .red
        }
    }
}
