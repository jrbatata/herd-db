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
    @State private var testState: TestState = .idle
    @State private var isTesting = false
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool

    init(editor: ConnectionEditorState, workspace: WorkspaceState) {
        self.editor = editor
        self.workspace = workspace
        _config = State(initialValue: editor.config)
        _password = State(initialValue: editor.password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                row("Nome:") {
                    TextField("prod-postgres", text: $config.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                }

                row("Tipo:") {
                    HStack {
                        Picker("Tipo", selection: $config.engine) {
                            ForEach(DatabaseEngine.allCases) { engine in
                                Text(engine.isAvailable ? engine.displayName : "\(engine.displayName) (em breve)")
                                    .tag(engine)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220, alignment: .leading)
                        Spacer()
                    }
                }

                row("Host:") {
                    HStack(spacing: 8) {
                        TextField("localhost", text: $config.host)
                            .textFieldStyle(.roundedBorder)
                        TextField("5432", value: $config.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 76)
                    }
                }

                row("Usuário:") {
                    TextField("postgres", text: $config.username)
                        .textFieldStyle(.roundedBorder)
                }

                row("Senha:") {
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                row("Banco:") {
                    TextField("Opcional — mostra todos se vazio", text: $config.database)
                        .textFieldStyle(.roundedBorder)
                }

                row("Usar SSL:") {
                    HStack {
                        Toggle("Usar SSL", isOn: $config.useTLS)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Spacer()
                    }
                }

                if !config.engine.isAvailable {
                    GridRow {
                        Color.clear.frame(width: 1)
                        Label("O driver de SQL Server chega na fase 6. Por enquanto só PostgreSQL conecta.", systemImage: "info.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 22)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
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
        .padding(.bottom, 16)
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
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    private func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        testState = .idle
        let config = self.config
        let password = self.password

        Task {
            let driver = PostgresDriver(config: config, password: password)
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
