import HerdCore
import SwiftUI

/// Preferências do app persistidas em `UserDefaults`.
enum Preferences {
    static let defaultSafeModeKey = "defaultSafeMode"
    static let touchIDKey = "safeModeTouchID"

    static var defaultSafeMode: SafeMode {
        get { SafeMode(rawValue: UserDefaults.standard.string(forKey: defaultSafeModeKey) ?? "") ?? .silent }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultSafeModeKey) }
    }

    /// Touch ID começa habilitado; cai para senha quando indisponível.
    static var touchIDEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: touchIDKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: touchIDKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: touchIDKey) }
    }
}

struct PreferencesView: View {
    @AppStorage(Preferences.defaultSafeModeKey) private var defaultSafeModeRaw = SafeMode.silent.rawValue
    @AppStorage(Preferences.touchIDKey) private var touchIDEnabled = true

    private var defaultSafeMode: SafeMode {
        SafeMode(rawValue: defaultSafeModeRaw) ?? .silent
    }

    var body: some View {
        Form {
            Section {
                Picker("Proteção padrão", selection: $defaultSafeModeRaw) {
                    Text(SafeMode.silent.displayName).tag(SafeMode.silent.rawValue)
                    Text(SafeMode.alert.displayName).tag(SafeMode.alert.rawValue)
                    Text(SafeMode.alertReadOnly.displayName).tag(SafeMode.alertReadOnly.rawValue)
                    Text(SafeMode.secure.displayName).tag(SafeMode.secure.rawValue)
                    Text(SafeMode.secureReadOnly.displayName).tag(SafeMode.secureReadOnly.rawValue)
                }
                Text(defaultSafeMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Novas conexões")
            }

            Section {
                Toggle("Usar Touch ID nos modos com senha", isOn: $touchIDEnabled)
                Text("Substitui a senha da conexão pela biometria do Mac ao executar comandos protegidos por senha e ao trocar de nível. Sem Touch ID disponível, a senha continua sendo pedida.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Proteção")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(20)
    }
}
