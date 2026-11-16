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
                Picker("Safe Mode padrão", selection: $defaultSafeModeRaw) {
                    ForEach(SafeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                Text(defaultSafeMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Novas conexões")
            }

            Section {
                Toggle("Usar Touch ID no modo Seguro", isOn: $touchIDEnabled)
                Text("Substitui a senha da conexão pela biometria do Mac ao executar comandos no modo Seguro e ao trocar o nível. Sem Touch ID disponível, a senha continua sendo pedida.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Safe Mode")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(20)
    }
}
