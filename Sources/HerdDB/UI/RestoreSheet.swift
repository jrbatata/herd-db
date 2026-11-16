import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RestoreWizardState: Identifiable {
    let id = UUID()
    let node: TreeNode
    let connectionName: String
    let database: String
}

/// Folha de restauração de um backup PostgreSQL.
///
/// O dump carrega referências a roles do servidor de origem (owner e GRANTs).
/// Ao restaurar em outro cluster, essas roles podem não existir. Por isso as
/// opções `--no-owner` e `--no-acl` vêm ligadas por padrão.
struct RestoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    let wizard: RestoreWizardState
    let workspace: WorkspaceState

    @State private var fileURL: URL?
    @State private var ignoreOwnership = true
    @State private var ignorePrivileges = true
    @State private var cleanBeforeRestore = true
    @State private var singleTransaction = false
    @State private var stopOnError = false
    @State private var validationError: String?

    private var isPlainSQL: Bool { fileURL?.pathExtension.lowercased() == "sql" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileCard
                    optionsCard
                    if isPlainSQL { plainSQLNote }
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
        .frame(width: 560, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Icon(.database, size: 18, solid: true)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Restaurar · Banco de dados")
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var fileCard: some View {
        WizardFormCard(title: "Arquivo") {
            WizardFormRow(label: "Backup") {
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

    private var optionsCard: some View {
        WizardFormCard(title: "Opções de restauração") {
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
            Divider()
            optionRow(
                "Limpar objetos antes de restaurar",
                detail: "--clean --if-exists",
                isOn: $cleanBeforeRestore
            )
            Divider()
            optionRow(
                "Executar em uma única transação",
                detail: "--single-transaction",
                isOn: $singleTransaction
            )
            Divider()
            optionRow(
                "Parar no primeiro erro",
                detail: "--exit-on-error",
                isOn: $stopOnError
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
        .disabled(isPlainSQL)
        .opacity(isPlainSQL ? 0.45 : 1)
    }

    private var plainSQLNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(.alertCircle, size: 15, solid: true)
                .foregroundStyle(.orange)
            Text("Arquivos .sql são restaurados com psql, que não aceita --no-owner nem --no-acl. Gere o dump com pg_dump --no-owner --no-acl, ou crie as roles no servidor de destino antes de restaurar.")
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button("Cancelar") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button {
                startRestore()
            } label: {
                Text("Restaurar")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(fileURL == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data, UTType(filenameExtension: "sql") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            fileURL = panel.url
            validationError = nil
        }
    }

    private func startRestore() {
        guard let fileURL else {
            validationError = "Selecione um arquivo de backup."
            return
        }
        let options = RestoreOptions(
            fileURL: fileURL,
            ignoreOwnership: ignoreOwnership,
            ignorePrivileges: ignorePrivileges,
            cleanBeforeRestore: cleanBeforeRestore,
            singleTransaction: singleTransaction,
            stopOnError: stopOnError
        )
        workspace.processes.restore(wizard.node, options: options, connections: workspace.app.connections)
        workspace.openProcesses()
        dismiss()
    }
}
