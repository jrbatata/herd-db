import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupWizardState: Identifiable {
    let id = UUID()
    let node: TreeNode
    let connectionName: String
    let database: String
    let target: String
}

enum BackupFormat: String, CaseIterable, Identifiable {
    case custom
    case plainSQL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "Custom (.dump)"
        case .plainSQL: "SQL (.sql)"
        }
    }

    var fileExtension: String {
        switch self {
        case .custom: "dump"
        case .plainSQL: "sql"
        }
    }
}

/// Folha de backup de um banco ou tabela PostgreSQL.
///
/// As opções `--no-owner` e `--no-acl` vêm ligadas por padrão para que o dump
/// não referencie roles do servidor de origem — o caso mais comum de falha ao
/// restaurar em outro cluster.
struct BackupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let wizard: BackupWizardState
    let workspace: WorkspaceState

    @State private var format: BackupFormat = .custom
    @State private var fileURL: URL?
    @State private var ignoreOwnership = true
    @State private var ignorePrivileges = true
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileCard
                    formatCard
                    optionsCard
                    helperNote
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let validationError {
                WizardValidationBanner(message: validationError) {
                    self.validationError = nil
                }
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: format) { _, newFormat in
            guard let fileURL else { return }
            self.fileURL = fileURL.deletingPathExtension().appendingPathExtension(newFormat.fileExtension)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Icon(wizard.node.kind == .table ? .table : .database, size: 18, solid: true)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Backup · \(wizard.node.kind == .table ? "Tabela" : "Banco de dados")")
                    .font(.system(size: 14.5, weight: .semibold))
                Text("\(wizard.connectionName) · \(wizard.target)")
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var fileCard: some View {
        WizardFormCard(title: "Destino") {
            WizardFormRow(label: "Arquivo") {
                HStack(spacing: 8) {
                    Text(fileURL?.lastPathComponent ?? "Nenhum arquivo selecionado")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(fileURL == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Escolher…") { chooseFile() }
                }
            }
        }
    }

    private var formatCard: some View {
        WizardFormCard(title: "Formato") {
            WizardFormRow(label: "Tipo de dump") {
                Picker("", selection: $format) {
                    ForEach(BackupFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }
        }
    }

    private var optionsCard: some View {
        WizardFormCard(title: "Opções do backup") {
            optionRow(
                "Ignorar ownership dos objetos",
                detail: "--no-owner",
                isOn: $ignoreOwnership
            )
            Divider()
            optionRow(
                "Ignorar permissões e GRANTs",
                detail: "--no-acl",
                isOn: $ignorePrivileges
            )
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
            }
        }
    }

    private var helperNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(.info, size: 15, solid: true)
                .foregroundStyle(.secondary)
            Text("Com as opções ligadas, o dump não referencia as roles do servidor de origem — ideal para restaurar em outro servidor. Desligue-as apenas se quiser preservar ownership e GRANTs, lembrando que as roles precisam existir no destino.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button("Cancelar") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button {
                startBackup()
            } label: {
                Text("Fazer backup")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(fileURL == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func chooseFile() {
        let panel = NSSavePanel()
        let base = wizard.node.kind == .table ? (wizard.node.table ?? wizard.node.title) : wizard.database
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        panel.allowedContentTypes = format == .plainSQL
            ? [UTType(filenameExtension: "sql") ?? .plainText]
            : [.data]
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
            format = url.pathExtension.lowercased() == "sql" ? .plainSQL : .custom
            validationError = nil
        }
    }

    private func startBackup() {
        guard let fileURL else {
            validationError = "Escolha um arquivo de destino."
            return
        }
        let options = BackupOptions(
            fileURL: fileURL,
            ignoreOwnership: ignoreOwnership,
            ignorePrivileges: ignorePrivileges
        )
        workspace.processes.backup(wizard.node, options: options, connections: workspace.app.connections)
        workspace.openProcesses()
        dismiss()
    }
}
