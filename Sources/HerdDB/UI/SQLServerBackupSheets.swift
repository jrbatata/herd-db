import SwiftUI
import HerdCore

struct SQLServerBackupState: Identifiable {
    let id = UUID()
    let node: TreeNode
    let connectionName: String
    let database: String
}

struct SQLServerRestoreState: Identifiable {
    let id = UUID()
    let node: TreeNode
    let connectionName: String
    let database: String
}

/// Backup nativo do SQL Server: o `.bak` é escrito no servidor, não no Mac.
struct SQLServerBackupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let wizard: SQLServerBackupState
    let workspace: WorkspaceState

    @State private var path = ""
    @State private var compression = true
    @State private var checksum = true
    @State private var copyOnly = false
    @State private var isRunning = false
    @State private var progress: Double?
    @State private var error: String?
    @State private var success: String?
    @State private var isLoadingDefaultPath = false

    private var config: ConnectionConfig? {
        workspace.app.connections.connection(id: wizard.node.connectionID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    destinationCard
                    optionsCard
                    statusCard
                    helperNote
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let error {
                WizardValidationBanner(message: error) { self.error = nil }
            }

            Divider()
            footer
        }
        .frame(width: 580, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await loadDefaultPath() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Icon(.download, size: 18, solid: true)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Backup · SQL Server")
                    .font(.system(size: 14.5, weight: .semibold))
                Text("\(wizard.connectionName) · \(wizard.database)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { dismiss() } label: {
                Icon(.close, size: 12)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var destinationCard: some View {
        WizardFormCard(title: "Destino no servidor") {
            WizardFormRow(label: "Arquivo") {
                HStack(spacing: 8) {
                    TextField("C:\\Backup\\banco.bak", text: $path)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 280)

                    Button(isLoadingDefaultPath ? "…" : "Sugerir") {
                        Task { await loadDefaultPath(force: true) }
                    }
                    .controlSize(.small)
                    .disabled(isLoadingDefaultPath || isRunning)
                }
            }
        }
    }

    private var optionsCard: some View {
        WizardFormCard(title: "Opções do backup") {
            optionRow("Compactar backup", detail: "COMPRESSION", isOn: $compression)
            Divider()
            optionRow("Verificar integridade", detail: "CHECKSUM", isOn: $checksum)
            Divider()
            optionRow("Não alterar o histórico", detail: "COPY_ONLY", isOn: $copyOnly)
        }
    }

    private func optionRow(_ label: String, detail: String, isOn: Binding<Bool>) -> some View {
        WizardFormRow(label: label) {
            HStack(spacing: 10) {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(isRunning)
            }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if isRunning || progress != nil || success != nil {
            WizardFormCard(title: "Andamento") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress ?? 0, total: 100)
                    HStack(spacing: 6) {
                        if let success {
                            Icon(.check, size: 13, solid: true)
                                .foregroundStyle(.green)
                            Text(success)
                                .foregroundStyle(.green)
                        } else {
                            Text(isRunning ? "Fazendo backup… \(Int(progress ?? 0))%" : "Preparando…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var helperNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(.info, size: 15, solid: true)
                .foregroundStyle(.secondary)
            Text("O arquivo .bak é criado no servidor. Use um caminho que exista na máquina do SQL Server ou um compartilhamento UNC (\\\\servidor\\pasta). O login precisa de permissão de backup no banco.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(success == nil ? "Cancelar" : "Concluir") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunning)

            Button {
                startBackup()
            } label: {
                Text("Fazer backup")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isRunning || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func loadDefaultPath(force: Bool = false) async {
        guard let config, (force || path.isEmpty), !isRunning else { return }
        isLoadingDefaultPath = true
        defer { isLoadingDefaultPath = false }
        let driver = workspace.app.drivers.driver(for: config)
        guard let sqlServer = driver as? SQLServerDriver else { return }
        if let suggested = try? await sqlServer.suggestedBackupPath(for: wizard.database) {
            path = suggested
        }
    }

    private func startBackup() {
        guard let config else { return }
        let driver = workspace.app.drivers.driver(for: config)
        guard let sqlServer = driver as? SQLServerDriver else { return }

        isRunning = true
        error = nil
        success = nil
        progress = 0

        let database = wizard.database
        let target = path
        let options = SQLServerBackupOptions(
            compression: compression,
            checksum: checksum,
            copyOnly: copyOnly
        )

        Task {
            do {
                try await sqlServer.backupDatabase(database, to: target, options: options) { value in
                    Task { @MainActor in progress = value }
                }
                await MainActor.run {
                    progress = 100
                    isRunning = false
                    success = "Backup concluído em \(target)"
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

/// Restore nativo do SQL Server a partir de um `.bak` que já esteja no servidor.
struct SQLServerRestoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    let wizard: SQLServerRestoreState
    let workspace: WorkspaceState

    @State private var path = ""
    @State private var targetDatabase = ""
    @State private var files: [SQLServerBackupFile] = []
    @State private var physicalPaths: [String: String] = [:]
    @State private var pathsEdited = false
    @State private var replace = false
    @State private var closeExisting = true
    @State private var targetExists = false
    @State private var isLoadingFiles = false
    @State private var isRestoring = false
    @State private var progress: Double?
    @State private var error: String?
    @State private var success: String?

    private var config: ConnectionConfig? {
        workspace.app.connections.connection(id: wizard.node.connectionID)
    }

    private var moves: [SQLServerRestoreMove] {
        files.compactMap { file in
            let physical = (physicalPaths[file.logicalName] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !physical.isEmpty else { return nil }
            return SQLServerRestoreMove(logicalName: file.logicalName, physicalName: physical)
        }
    }

    private var canRestore: Bool {
        !isRestoring
            && !files.isEmpty
            && moves.count == files.count
            && !targetDatabase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    backupFileCard
                    if !files.isEmpty {
                        filesCard
                        targetCard
                    }
                    statusCard
                    helperNote
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let error {
                WizardValidationBanner(message: error) { self.error = nil }
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if targetDatabase.isEmpty {
                targetDatabase = "\(wizard.database)_restore"
            }
        }
        .task(id: targetDatabase) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if !pathsEdited, !files.isEmpty {
                rebuildPhysicalPaths()
            }
            await checkTarget()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Icon(.download, size: 18, solid: true)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Restore · SQL Server")
                    .font(.system(size: 14.5, weight: .semibold))
                Text("\(wizard.connectionName) · \(wizard.database)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { dismiss() } label: {
                Icon(.close, size: 12)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isRestoring)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var backupFileCard: some View {
        WizardFormCard(title: "Arquivo de backup no servidor") {
            WizardFormRow(label: "Arquivo") {
                HStack(spacing: 8) {
                    TextField("C:\\Backup\\banco.bak", text: $path)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 280)

                    Button(isLoadingFiles ? "Lendo…" : "Ler backup") {
                        Task { await readBackup() }
                    }
                    .controlSize(.small)
                    .disabled(isLoadingFiles || isRestoring || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var filesCard: some View {
        WizardFormCard(title: "Arquivos do backup") {
            HStack {
                Text("Caminhos físicos no servidor")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Recalcular para o destino") {
                    rebuildPhysicalPaths()
                }
                .controlSize(.mini)
                .disabled(isRestoring)
            }
            .padding(.vertical, 7)
            Divider()
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(file.logicalName)
                            .font(.system(size: 11.5, weight: .medium))
                        Text(file.isLog ? "LOG" : "DATA")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        Spacer()
                    }
                    TextField("Caminho físico no servidor", text: binding(for: file))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.vertical, 2)
                }
                .padding(.vertical, 7)
            }
        }
    }

    private var targetCard: some View {
        WizardFormCard(title: "Destino") {
            WizardFormRow(label: "Novo banco") {
                TextField("nome_do_banco", text: $targetDatabase)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 240)
            }
            if targetExists {
                Divider()
                HStack(alignment: .top, spacing: 7) {
                    Icon(.warning, size: 13)
                        .foregroundStyle(.orange)
                    Text("Esse banco já existe. Ligue “Substituir banco existente” para sobrescrevê-lo.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.vertical, 9)
                Divider()
                optionRow("Substituir banco existente", detail: "REPLACE", isOn: $replace)
                Divider()
                optionRow("Desconectar usuários antes", detail: "SINGLE_USER", isOn: $closeExisting)
            }
        }
    }

    private func optionRow(_ label: String, detail: String, isOn: Binding<Bool>) -> some View {
        WizardFormRow(label: label) {
            HStack(spacing: 10) {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(isRestoring)
            }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if isRestoring || progress != nil || success != nil {
            WizardFormCard(title: "Andamento") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress ?? 0, total: 100)
                    HStack(spacing: 6) {
                        if let success {
                            Icon(.check, size: 13, solid: true)
                                .foregroundStyle(.green)
                            Text(success)
                                .foregroundStyle(.green)
                        } else {
                            Text(isRestoring ? "Restaurando… \(Int(progress ?? 0))%" : "Preparando…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var helperNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(.info, size: 15, solid: true)
                .foregroundStyle(.secondary)
            Text("O restore lê o .bak do disco do servidor. Os caminhos físicos dos arquivos .mdf/.ldf também precisam existir na máquina do SQL Server. O login precisa de permissão de restore (dbcreator ou sysadmin).")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(success == nil ? "Cancelar" : "Concluir") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isRestoring)

            Button {
                startRestore()
            } label: {
                Text("Restaurar")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canRestore)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func binding(for file: SQLServerBackupFile) -> Binding<String> {
        Binding(
            get: { physicalPaths[file.logicalName] ?? file.physicalName },
            set: {
                physicalPaths[file.logicalName] = $0
                pathsEdited = true
            }
        )
    }

    private func readBackup() async {
        guard let config else { return }
        let driver = workspace.app.drivers.driver(for: config)
        guard let sqlServer = driver as? SQLServerDriver else { return }

        isLoadingFiles = true
        error = nil
        success = nil
        defer { isLoadingFiles = false }

        do {
            let list = try await sqlServer.backupFileList(path)
            guard !list.isEmpty else {
                self.error = "Nenhum arquivo encontrado no backup. Confira o caminho no servidor."
                return
            }
            files = list
            pathsEdited = false
            rebuildPhysicalPaths()
            await checkTarget()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rebuildPhysicalPaths() {
        for file in files {
            physicalPaths[file.logicalName] = suggestedPhysicalPath(for: file)
        }
    }

    private func suggestedPhysicalPath(for file: SQLServerBackupFile) -> String {
        let separator = file.physicalName.contains("\\") ? "\\" : "/"
        let components = file.physicalName.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let directory = components.dropLast().joined(separator: separator)
        let originalExtension = (file.physicalName as NSString).pathExtension
        let target = targetDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = target.isEmpty ? wizard.database + "_restore" : target
        let name = base + (file.isLog ? "_log" : "")
        let filename = originalExtension.isEmpty ? name : "\(name).\(originalExtension)"
        return directory.isEmpty ? filename : "\(directory)\(separator)\(filename)"
    }

    private func checkTarget() async {
        guard let config else { return }
        let name = targetDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            targetExists = false
            return
        }
        let driver = workspace.app.drivers.driver(for: config)
        guard let sqlServer = driver as? SQLServerDriver else { return }
        targetExists = (try? await sqlServer.databaseExists(name)) ?? false
        if targetExists {
            replace = true
            closeExisting = true
        }
    }

    private func startRestore() {
        guard let config else { return }
        let driver = workspace.app.drivers.driver(for: config)
        guard let sqlServer = driver as? SQLServerDriver else { return }

        let target = targetDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            error = "Informe o nome do banco de destino."
            return
        }
        if targetExists && !replace {
            error = "O banco \(target) já existe. Ligue “Substituir banco existente” para continuar."
            return
        }

        isRestoring = true
        error = nil
        success = nil
        progress = 0

        let source = path
        let restoreMoves = moves
        let replaceExisting = replace
        let disconnect = closeExisting

        Task {
            do {
                try await sqlServer.restoreDatabase(
                    target,
                    from: source,
                    moves: restoreMoves,
                    replace: replaceExisting,
                    closeExisting: disconnect
                ) { value in
                    Task { @MainActor in progress = value }
                }
                await MainActor.run {
                    progress = 100
                    isRestoring = false
                    success = "Banco \(target) restaurado."
                    workspace.tree.reloadAll()
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
