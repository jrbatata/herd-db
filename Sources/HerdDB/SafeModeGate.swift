import AppKit
import Dispatch
import HerdCore
import LocalAuthentication
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
        if Preferences.touchIDEnabled {
            let reason = "Confirme para \(action) na conexão \(config.name)."
            switch biometricUnlock(reason: reason) {
            case .success:
                return true
            case .failed, .unavailable:
                break
            }
        }

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

    private enum BiometricResult {
        case success
        case failed
        case unavailable
    }

    /// Wrapper síncrono do Touch ID, no mesmo estilo dos alerts modais do app.
    /// O callback do LocalAuthentication chega numa fila privada, por isso o semáforo.
    private static func biometricUnlock(reason: String) -> BiometricResult {
        let context = LAContext()
        context.localizedCancelTitle = "Usar senha"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .unavailable
        }

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            box.set(success)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else { return .failed }
        return box.value ? .success : .failed
    }

    /// Contêiner com lock para o resultado do callback biométrico.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false

        func set(_ value: Bool) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
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
