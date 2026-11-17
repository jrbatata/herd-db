import AppKit
import HerdCore
import SwiftUI
import UniformTypeIdentifiers

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

private enum SQLServerBackupMode: String, CaseIterable, Identifiable {
    case local
    case native

    var id: String { rawValue }
}

private enum SQLServerRestoreMode: String, CaseIterable, Identifiable {
    case local
    case native

    var id: String { rawValue }
}

/// Backup do SQL Server.
///
/// O modo padrão grava um `.sql` no Mac (schema + dados), como o `pg_dump` do
/// PostgreSQL. O `.bak` nativo fica no disco do servidor e continua disponível
/// como opção avançada.
struct SQLServerBackupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let wizard: SQLServerBackupState
    let workspace: WorkspaceState

    @State private var mode: SQLServerBackupMode = .local

    // Backup lógico
    @State private var fileURL: URL?
    @State private var includeData = true
    @State private var includeDrop = true

    // Backup nativo
    @State private var path = ""
    @State private var compression = true
    @State private var checksum = true
    @State private var copyOnly = false
    @State private var isLoadingDefaultPath = false

    // Execução
    @State private var isRunning = false
    @State private var progress: Double?
    @State private var status = ""
    @State private var detail = ""
    @State private var warnings: [String] = []
    @State private var error: String?
    @State private var success: String?
    @State private var finishedURL: URL?
    @State private var runTask: Task<Void, Never>?

    private var config: ConnectionConfig? {
        workspace.app.connections.connection(id: wizard.node.connectionID)
    }

    private var isTableBackup: Bool { wizard.node.kind == .table }

    private var tableFilter: [String]? {
        guard isTableBackup else { return nil }
        let schema = wizard.node.schema ?? "dbo"
        let table = wizard.node.table ?? wizard.node.title
        return ["\(schema).\(table)"]
    }

    private var targetLabel: String {
        tableFilter?.first ?? wizard.database
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modeCard
                    if mode == .local {
                        localFileCard
                        localOptionsCard
                    } else {
                        nativeDestinationCard
                        nativeOptionsCard
                    }
                    statusCard
                    if !warnings.isEmpty {
                        warningsCard
                    }
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
        .frame(width: 640, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if isTableBackup {
                mode = .local
            }
            if fileURL == nil {
                fileURL = suggestedFileURL()
            }
        }
        .task(id: mode) {
            guard mode == .native else { return }
            await loadDefaultPath()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Icon(.download, size: 18, solid: true)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Backup · SQL Server")
                    .font(.system(size: 14.5, weight: .semibold))
                Text("\(wizard.connectionName) · \(targetLabel)")
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

    // MARK: - Mode

    private var modeCard: some View {
        WizardFormCard(title: "Onde salvar") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $mode) {
                    Text("No meu Mac (.sql)").tag(SQLServerBackupMode.local)
                    Text("No servidor (.bak)").tag(SQLServerBackupMode.native)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isRunning || isTableBackup)

                Text(mode == .local
                     ? "Script com schema e dados, gravado no Mac. Pode ser restaurado em qualquer SQL Server."
                     : "Arquivo .bak criado no disco do SQL Server. Mais rápido e completo, mas fica no servidor.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isTableBackup {
                    Label {
                        Text("O .sql inclui só esta tabela. FKs para outras tabelas e objetos dependentes ficam de fora. O .bak nativo é sempre do banco inteiro.")
                    } icon: {
                        Icon(.info, size: 12)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: - Local

    private var localFileCard: some View {
        WizardFormCard(title: "Arquivo no Mac") {
            WizardFormRow(label: "Destino") {
                HStack(spacing: 8) {
                    Text(fileURL?.path ?? "Nenhum arquivo selecionado")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(fileURL == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 330, alignment: .trailing)

                    Button("Escolher…") { chooseFile() }
                        .controlSize(.small)
                        .disabled(isRunning)
                }
            }
        }
    }

    private var localOptionsCard: some View {
        WizardFormCard(title: "Conteúdo") {
            optionRow("Incluir dados", detail: "INSERTs", isOn: $includeData)
            Divider()
            optionRow("Incluir DROP antes de criar", detail: "script reexecutável", isOn: $includeDrop)
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

    // MARK: - Native

    private var nativeDestinationCard: some View {
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

    private var nativeOptionsCard: some View {
        WizardFormCard(title: "Opções do backup") {
            optionRow("Compactar backup", detail: "COMPRESSION", isOn: $compression)
            Divider()
            optionRow("Verificar integridade", detail: "CHECKSUM", isOn: $checksum)
            Divider()
            optionRow("Não alterar o histórico", detail: "COPY_ONLY", isOn: $copyOnly)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusCard: some View {
        if isRunning || progress != nil || success != nil {
            WizardFormCard(title: "Andamento") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress ?? 0, total: 1)
                    HStack(spacing: 6) {
                        if let success {
                            Icon(.check, size: 13, solid: true)
                                .foregroundStyle(.green)
                            Text(success)
                                .foregroundStyle(.green)
                                .lineLimit(2)
                        } else {
                            Text(status.isEmpty ? "Preparando…" : status)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))

                    if !detail.isEmpty, success == nil {
                        Text(detail)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    if let finishedURL {
                        Button("Mostrar no Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([finishedURL])
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Icon(.warning, size: 13)
                    .foregroundStyle(.orange)
                Text(warnings.count == 1 ? "1 aviso" : "\(warnings.count) avisos")
                    .font(.system(size: 11.5, weight: .medium))
            }
            ForEach(Array(warnings.prefix(5).enumerated()), id: \.offset) { _, warning in
                Text("• \(warning)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var helperNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(.info, size: 15, solid: true)
                .foregroundStyle(.secondary)
            Text(mode == .local
                 ? "O backup lógico lê o catálogo e os dados e grava tudo no seu Mac. Tipos como sql_variant, geometry, geography, hierarchyid e colunas Always Encrypted ainda não são exportados — nesses casos use o .bak nativo."
                 : "O arquivo .bak é criado no servidor. Use um caminho que exista na máquina do SQL Server ou um compartilhamento UNC (\\\\servidor\\pasta). O login precisa de permissão de backup no banco.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(isRunning ? "Cancelar" : (success == nil ? "Cancelar" : "Concluir")) {
                if isRunning {
                    runTask?.cancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Button {
                start()
            } label: {
                Text(mode == .local ? "Salvar .sql" : "Fazer backup")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isRunning || success != nil || !canStart)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var canStart: Bool {
        if mode == .local {
            return fileURL != nil
        }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start() {
        if mode == .local {
            startLocalBackup()
        } else {
            startNativeBackup()
        }
    }

    // MARK: - Actions

    private func suggestedFileURL() -> URL? {
        let name = tableFilter?.first?.split(separator: ".").last.map(String.init) ?? wizard.database
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "\(name)_\(formatter.string(from: Date())).sql"
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return directory?.appendingPathComponent(fileName)
    }

    private func chooseFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "backup.sql"
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url.pathExtension.lowercased() == "sql"
                ? url
                : url.appendingPathExtension("sql")
            error = nil
        }
    }

    private func startLocalBackup() {
        guard let fileURL, let config else { return }
        let driver = workspace.app.drivers.driver(for: config)
        guard let sqlServer = driver as? SQLServerDriver else { return }

        isRunning = true
        error = nil
        success = nil
        warnings = []
        finishedURL = nil
        progress = 0
        status = "Lendo catálogo…"
        detail = ""

        let options = SQLServerLogicalBackupOptions(
            includeData: includeData,
            includeDropStatements: includeDrop,
            tables: tableFilter
        )

        runTask = Task {
            do {
                let result = try await sqlServer.exportLogicalBackup(
                    database: wizard.database,
                    to: fileURL,
                    options: options
                ) { value in
                    Task { @MainActor in
                        status = value.stage
                        detail = value.total > 0
                            ? "\(value.current) de \(value.total) tabela(s) · \(Self.formatRows(value.rows)) · \(Self.formatBytes(value.bytes))"
                            : "\(Self.formatRows(value.rows)) · \(Self.formatBytes(value.bytes))"
                        if value.total > 0 {
                            progress = min(1, Double(value.current) / Double(value.total))
                        }
                    }
                }
                await MainActor.run {
                    progress = 1
                    isRunning = false
                    success = "Backup salvo em \(result.url.path)"
                    detail = "\(result.tableCount) tabela(s) · \(Self.formatRows(result.rowCount)) · \(Self.formatBytes(result.bytes))"
                    warnings = result.warnings
                    finishedURL = result.url
                    workspace.tree.reloadAll()
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    progress = nil
                    self.error = error is CancellationError
                        ? "Backup cancelado."
                        : error.localizedDescription
                }
            }
        }
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

    private func startNativeBackup() {
        guard let config else { return }
        let driver = workspace.app.drivers.driver(for: config)
        guard let sqlServer = driver as? SQLServerDriver else { return }

        isRunning = true
        error = nil
        success = nil
        warnings = []
        finishedURL = nil
        progress = 0
        status = "Fazendo backup no servidor…"
        detail = ""

        let database = wizard.database
        let target = path
        let options = SQLServerBackupOptions(
            compression: compression,
            checksum: checksum,
            copyOnly: copyOnly
        )

        runTask = Task {
            do {
                try await sqlServer.backupDatabase(database, to: target, options: options) { value in
                    Task { @MainActor in
                        progress = min(1, value / 100)
                        detail = "\(Int(value))%"
                    }
                }
                await MainActor.run {
                    progress = 1
                    isRunning = false
                    success = "Backup concluído em \(target)"
                    detail = "O arquivo está no disco do servidor."
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    progress = nil
                    self.error = error is CancellationError
                        ? "Backup cancelado."
                        : error.localizedDescription
                }
            }
        }
    }

    private static func formatRows(_ rows: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: rows)) ?? "\(rows)") linha(s)"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Restore do SQL Server a partir de um `.sql` local ou de um `.bak` no servidor.
struct SQLServerRestoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    let wizard: SQLServerRestoreState
    let workspace: WorkspaceState

    @State private var mode: SQLServerRestoreMode = .local

    // Restore lógico
    @State private var localFileURL: URL?
    @State private var localTarget = ""
    @State private var createIfMissing = true
    @State private var stopOnError = true
    @State private var localTargetExists = false
    @State private var isCheckingTarget = false

    // Restore nativo
    @State private var path = ""
    @State private var targetDatabase = ""
    @State private var files: [SQLServerBackupFile] = []
    @State private var physicalPaths: [String: String] = [:]
    @State private var pathsEdited = false
    @State private var replace = false
    @State private var closeExisting = true
    @State private var targetExists = false
    @State private var isLoadingFiles = false

    // Execução
    @State private var isRestoring = false
    @State private var progress: Double?
    @State private var status = ""
    @State private var detail = ""
    @State private var warnings: [String] = []
    @State private var error: String?
    @State private var success: String?
    @State private var runTask: Task<Void, Never>?

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
        guard !isRestoring else { return false }
        if mode == .local {
            return localFileURL != nil
                && !localTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !files.isEmpty
            && moves.count == files.count
            && !targetDatabase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modeCard
                    if mode == .local {
                        localFileCard
                        localDestinationCard
                        localOptionsCard
                    } else {
                        nativeFileCard
                        if !files.isEmpty {
                            nativeFilesCard
                            nativeTargetCard
                        }
                    }
                    statusCard
                    if !warnings.isEmpty {
                        warningsCard
                    }
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
        .frame(width: 660, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if localTarget.isEmpty {
                localTarget = "\(wizard.database)_restore"
            }
            if targetDatabase.isEmpty {
                targetDatabase = "\(wizard.database)_restore"
            }
        }
        .task(id: localTarget) {
            guard mode == .local else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await checkLocalTarget()
        }
        .task(id: targetDatabase) {
            guard mode == .native else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if !pathsEdited, !files.isEmpty {
                rebuildPhysicalPaths()
            }
            await checkNativeTarget()
        }
    }

    // MARK: - Header

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

    // MARK: - Mode

    private var modeCard: some View {
        WizardFormCard(title: "Origem do backup") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $mode) {
                    Text("Arquivo .sql no Mac").tag(SQLServerRestoreMode.local)
                    Text("Arquivo .bak no servidor").tag(SQLServerRestoreMode.native)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isRestoring)

                Text(mode == .local
                     ? "Executa um script gerado pelo backup lógico do herd, pelo SSMS ou por sqlcmd."
                     : "Lê um .bak que já esteja no disco do SQL Server. Os caminhos .mdf/.ldf também precisam existir lá.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: - Local

    private var localFileCard: some View {
        WizardFormCard(title: "Arquivo .sql") {
            WizardFormRow(label: "Backup") {
                HStack(spacing: 8) {
                    Text(localFileURL?.lastPathComponent ?? "Nenhum arquivo selecionado")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(localFileURL == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Escolher…") { chooseLocalFile() }
                        .controlSize(.small)
                        .disabled(isRestoring)
                }
            }
        }
    }

    private var localDestinationCard: some View {
        WizardFormCard(title: "Destino") {
            WizardFormRow(label: "Banco de destino") {
                TextField("nome_do_banco", text: $localTarget)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 260)
                    .disabled(isRestoring)
            }
            Divider()
            optionRow("Criar banco se não existir", detail: "CREATE DATABASE", isOn: $createIfMissing)
            Divider()
            if isCheckingTarget {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Verificando o banco…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 9)
            } else if localTargetExists {
                HStack(alignment: .top, spacing: 7) {
                    Icon(.info, size: 13)
                        .foregroundStyle(.secondary)
                    Text("O banco já existe. Objetos com o mesmo nome serão substituídos se o script tiver DROP; os demais continuam.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.vertical, 9)
            }
        }
    }

    private var localOptionsCard: some View {
        WizardFormCard(title: "Opções") {
            optionRow("Parar no primeiro erro", detail: "recomendado", isOn: $stopOnError)
        }
    }

    // MARK: - Native

    private var nativeFileCard: some View {
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

    private var nativeFilesCard: some View {
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

    private var nativeTargetCard: some View {
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

    // MARK: - Shared rows

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

    // MARK: - Status

    @ViewBuilder
    private var statusCard: some View {
        if isRestoring || progress != nil || success != nil {
            WizardFormCard(title: "Andamento") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress ?? 0, total: 1)
                    HStack(spacing: 6) {
                        if let success {
                            Icon(.check, size: 13, solid: true)
                                .foregroundStyle(.green)
                            Text(success)
                                .foregroundStyle(.green)
                                .lineLimit(2)
                        } else {
                            Text(status.isEmpty ? "Preparando…" : status)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))

                    if !detail.isEmpty, success == nil {
                        Text(detail)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Icon(.warning, size: 13)
                    .foregroundStyle(.orange)
                Text(warnings.count == 1 ? "1 aviso" : "\(warnings.count) avisos")
                    .font(.system(size: 11.5, weight: .medium))
            }
            ForEach(Array(warnings.prefix(5).enumerated()), id: \.offset) { _, warning in
                Text("• \(warning)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var helperNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(.info, size: 15, solid: true)
                .foregroundStyle(.secondary)
            Text(mode == .local
                 ? "O script é executado lote a lote no banco de destino. O login precisa de permissão para criar objetos (db_owner ou equivalente). Para um banco novo, o herd pode criá-lo antes."
                 : "O restore lê o .bak do disco do servidor. Os caminhos físicos dos arquivos .mdf/.ldf também precisam existir na máquina do SQL Server. O login precisa de permissão de restore (dbcreator ou sysadmin).")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(isRestoring ? "Cancelar" : (success == nil ? "Cancelar" : "Concluir")) {
                if isRestoring {
                    runTask?.cancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Button {
                start()
            } label: {
                Text("Restaurar")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canRestore || success != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func start() {
        if mode == .local {
            startLocalRestore()
        } else {
            startNativeRestore()
        }
    }

    // MARK: - Actions

    private func chooseLocalFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .data]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            localFileURL = panel.url
            error = nil
        }
    }

    private func checkLocalTarget() async {
        guard let config, !isRestoring else { return }
        let name = localTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            localTargetExists = false
            return
        }
        isCheckingTarget = true
        defer { isCheckingTarget = false }
        let driver = workspace.app.drivers.driver(for: config)
        guard let sqlServer = driver as? SQLServerDriver else { return }
        localTargetExists = (try? await sqlServer.databaseExists(name)) ?? false
    }

    private func startLocalRestore() {
        guard let config, let localFileURL else { return }
        let driver = workspace.app.drivers.driver(for: config)
        guard let sqlServer = driver as? SQLServerDriver else { return }

        let target = localTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            error = "Informe o nome do banco de destino."
            return
        }

        isRestoring = true
        error = nil
        success = nil
        warnings = []
        progress = 0
        status = "Preparando o banco de destino…"
        detail = ""

        let stop = stopOnError
        let shouldCreate = createIfMissing

        runTask = Task {
            do {
                // Confirma na hora: o estado do campo pode ter mudado desde a
                // última verificação (ou ela ainda não terminou).
                let exists = (try? await sqlServer.databaseExists(target)) ?? localTargetExists
                if !exists {
                    guard shouldCreate else {
                        await MainActor.run {
                            isRestoring = false
                            progress = nil
                            error = "O banco \(target) não existe. Ligue “Criar banco se não existir” ou informe outro nome."
                        }
                        return
                    }
                    try await sqlServer.createDatabaseForRestore(target)
                }
                await MainActor.run {
                    status = "Executando o script…"
                }
                let result = try await sqlServer.restoreLogicalScript(
                    database: target,
                    from: localFileURL,
                    options: SQLServerScriptRestoreOptions(stopOnError: stop)
                ) { value in
                    Task { @MainActor in
                        progress = min(1, value.fraction)
                        status = "Executando o script…"
                        detail = "\(value.batch) lote(s) · linha \(value.line)"
                    }
                }
                await MainActor.run {
                    progress = 1
                    isRestoring = false
                    success = "Script restaurado em \(target)."
                    detail = "\(result.batchCount) lote(s) executado(s)."
                    warnings = result.warnings
                    localTargetExists = true
                    workspace.tree.reloadAll()
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    progress = nil
                    self.error = error is CancellationError
                        ? "Restore cancelado."
                        : error.localizedDescription
                }
            }
        }
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
            await checkNativeTarget()
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

    private func checkNativeTarget() async {
        guard let config, !isRestoring else { return }
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

    private func startNativeRestore() {
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
        warnings = []
        progress = 0
        status = "Restaurando no servidor…"
        detail = ""

        let source = path
        let restoreMoves = moves
        let replaceExisting = replace
        let disconnect = closeExisting

        runTask = Task {
            do {
                try await sqlServer.restoreDatabase(
                    target,
                    from: source,
                    moves: restoreMoves,
                    replace: replaceExisting,
                    closeExisting: disconnect
                ) { value in
                    Task { @MainActor in
                        progress = min(1, value / 100)
                        detail = "\(Int(value))%"
                    }
                }
                await MainActor.run {
                    progress = 1
                    isRestoring = false
                    success = "Banco \(target) restaurado."
                    workspace.tree.reloadAll()
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    progress = nil
                    self.error = error is CancellationError
                        ? "Restore cancelado."
                        : error.localizedDescription
                }
            }
        }
    }
}
