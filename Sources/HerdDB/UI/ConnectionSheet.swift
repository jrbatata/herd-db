import SwiftUI
import HerdCore

struct ConnectionSheet: View {
    private enum TestState {
        case idle
        case success(String)
        case failure(String)
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let editor: ConnectionEditorState
    let workspace: WorkspaceState

    @State private var config: ConnectionConfig
    @State private var password: String
    @State private var showPassword = false
    @State private var testState: TestState = .idle
    @State private var isTesting = false
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool

    init(editor: ConnectionEditorState, workspace: WorkspaceState) {
        self.editor = editor
        self.workspace = workspace
        var initial = editor.config
        // Conexões antigas podem ter ficado sem proteção com produção marcada.
        if initial.isProduction, !initial.safeMode.isRestricted {
            initial.safeMode = .secure
        }
        _config = State(initialValue: initial)
        _password = State(initialValue: editor.password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 18) {
                group(nil) {
                    field("Nome") {
                        TextField("prod-postgres", text: $config.name)
                            .focused($nameFocused)
                    }
                    Divider()
                    field("Tipo") {
                        Picker("Tipo", selection: $config.engine) {
                            ForEach(DatabaseEngine.allCases) { engine in
                                Label {
                                    Text(engine.isAvailable ? engine.displayName : "\(engine.displayName) (em breve)")
                                } icon: {
                                    Image(nsImage: engine.iconSymbol.image(solid: false))
                                }
                                .tag(engine)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }

                group("Conexão") {
                    field("Host") {
                        TextField("localhost", text: $config.host)
                    }
                    Divider()
                    field("Porta") {
                        TextField("5432", value: $config.port, format: .number.grouping(.never))
                    }
                    Divider()
                    field("Banco") {
                        TextField(config.engine == .sqlServer ? "master" : "Opcional", text: $config.database)
                    }
                }

                group("Autenticação") {
                    field("Usuário") {
                        TextField(config.engine == .sqlServer ? "sa" : "postgres", text: $config.username)
                    }
                    Divider()
                    field("Senha") {
                        HStack(spacing: 6) {
                            Group {
                                if showPassword {
                                    TextField("Chaveiro do macOS", text: $password)
                                } else {
                                    SecureField("Chaveiro do macOS", text: $password)
                                }
                            }
                            Button {
                                showPassword.toggle()
                            } label: {
                                Icon(showPassword ? .eyeOff : .eye, size: 14)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(showPassword ? "Ocultar senha" : "Mostrar senha")
                        }
                    }
                }

                group("Segurança") {
                    field(config.engine == .sqlServer ? "Exigir TLS" : "Usar SSL") {
                        Toggle("Usar SSL", isOn: $config.useTLS)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help(config.engine == .sqlServer
                                  ? "Desligado, usa TLS se o servidor oferecer. Ligado, recusa conexões sem criptografia."
                                  : "Exige uma conexão criptografada.")
                    }
                    if config.engine == .sqlServer {
                        Divider()
                        field("Confiar no certificado") {
                            Toggle("Confiar no certificado", isOn: $config.trustServerCertificate)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .help("Aceita certificados autoassinados, como os de servidores de desenvolvimento.")
                        }
                    }
                    Divider()
                    field("Proteção") {
                        Picker("Proteção", selection: $config.safeMode) {
                            if !config.isProduction {
                                Text(SafeMode.silent.displayName)
                                    .tag(SafeMode.silent)
                            }
                            Text(SafeMode.alert.displayName)
                                .tag(SafeMode.alert)
                            Text(SafeMode.alertReadOnly.displayName)
                                .tag(SafeMode.alertReadOnly)
                            Text(SafeMode.secure.displayName)
                                .tag(SafeMode.secure)
                            Text(SafeMode.secureReadOnly.displayName)
                                .tag(SafeMode.secureReadOnly)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .help(config.safeMode.summary)
                    }
                    Divider()
                    field("Produção") {
                        Toggle("Produção", isOn: $config.isProduction)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("Destaca a conexão como produção na aba e na barra de título")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(config.safeMode.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if config.isProduction {
                        Label {
                            Text("Conexões de produção não podem ficar sem proteção.")
                        } icon: {
                            Icon(.info, size: 12)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 4)

                if config.engine == .sqlServer {
                    Label {
                        Text("Autenticação SQL com usuário e senha. Windows/NTLM ainda não é suportado.")
                    } icon: {
                        Icon(.info, size: 14)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)

            if let saveError {
                Label { Text(saveError) } icon: { Icon(.warning, size: 14) }
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
            }

            footer
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { nameFocused = editor.isNew }
        .onChange(of: config.engine) { oldEngine, newEngine in
            if config.port == oldEngine.defaultPort || config.port == 0 {
                config.port = newEngine.defaultPort
            }
            // SQL Server costuma usar certificado autoassinado em desenvolvimento.
            if newEngine == .sqlServer, oldEngine != .sqlServer {
                config.trustServerCertificate = true
            }
        }
        .onChange(of: config.isProduction) { _, isProduction in
            // Produção nunca começa sem proteção: assume o modo mais forte e deixa o usuário ajustar.
            if isProduction, !config.safeMode.isRestricted {
                config.safeMode = .secure
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editor.isNew ? "Nova conexão" : "Editar conexão")
                .font(.system(size: 15, weight: .semibold))
            Text("Os dados ficam em Application Support; a senha vai para o Chaveiro do macOS.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Testar conexão") { testConnection() }
                .controlSize(.small)
                .disabled(!config.isRunnable || isTesting)

            testStatus

            Spacer()

            Button("Cancelar") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Salvar") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!config.isRunnable || !config.engine.isAvailable)
        }
        .padding(20)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .success(let message):
            Label { Text(message) } icon: { Icon(.check, size: 14, solid: true) }
                .font(.system(size: 10.5))
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failure(let message):
            Label { Text(message) } icon: { Icon(.closeCircle, size: 14, solid: true) }
                .font(.system(size: 10.5))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func group<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
            Spacer(minLength: 12)
            content()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12.5))
        }
        .frame(minHeight: 34)
    }

    private func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        testState = .idle
        let config = self.config
        let password = self.password

        Task {
            let driver = DatabaseDriverFactory.make(config: config, password: password)
            do {
                let info = try await driver.test()
                await driver.shutdown()
                testState = .success("Conectou · \(info.shortVersion)")
            } catch {
                await driver.shutdown()
                testState = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }

    private func save() {
        saveError = nil
        if config.isProduction, !config.safeMode.isRestricted {
            config.safeMode = .secure
        }
        do {
            try app.save(config, password: password)
            workspace.tree.syncConnections()
            workspace.connectionEditor = nil
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
