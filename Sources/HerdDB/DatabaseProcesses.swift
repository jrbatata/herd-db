import AppKit
import Foundation
import HerdCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct BackupOptions {
    var fileURL: URL
    var ignoreOwnership = true
    var ignorePrivileges = true

    var isPlainSQL: Bool { fileURL.pathExtension.lowercased() == "sql" }
}

struct RestoreOptions {
    var fileURL: URL
    var ignoreOwnership = true
    var ignorePrivileges = true
    var cleanBeforeRestore = true
    var singleTransaction = false
    var stopOnError = false

    var isPlainSQL: Bool { fileURL.pathExtension.lowercased() == "sql" }
}

@MainActor
@Observable
final class DatabaseProcesses {
    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let target: String
        let started = Date()
        var status = "Em andamento"
        var output = ""
    }

    private(set) var entries: [Entry] = []
    private var running: [UUID: Process] = [:]
    var visible = false

    func backup(_ node: TreeNode, options: BackupOptions, connections: ConnectionStore) {
        guard let config = connections.connection(id: node.connectionID), let database = node.database else { return }
        var arguments = [
            "--verbose",
            options.isPlainSQL ? "--format=plain" : "--format=custom"
        ]
        if options.ignoreOwnership { arguments.append("--no-owner") }
        if options.ignorePrivileges { arguments.append("--no-acl") }
        arguments += ["--file", options.fileURL.path]
        if let table = node.table { arguments += ["--table", qualified(node.schema, table)] }
        arguments.append(database)
        launch("pg_dump", arguments: arguments, node: node, config: config, connections: connections,
               title: "Backup")
    }

    func restore(_ node: TreeNode, options: RestoreOptions, connections: ConnectionStore) {
        guard let config = connections.connection(id: node.connectionID), let database = node.database else { return }
        if options.isPlainSQL {
            launch("psql", arguments: ["--dbname", database, "--file", options.fileURL.path],
                   node: node, config: config, connections: connections, title: "Restore (SQL)")
            return
        }

        var arguments = ["--verbose"]
        if options.cleanBeforeRestore { arguments += ["--clean", "--if-exists"] }
        if options.ignoreOwnership { arguments.append("--no-owner") }
        if options.ignorePrivileges { arguments.append("--no-acl") }
        if options.singleTransaction { arguments.append("--single-transaction") }
        if options.stopOnError { arguments.append("--exit-on-error") }
        arguments += ["--dbname", database, options.fileURL.path]
        launch("pg_restore", arguments: arguments,
               node: node, config: config, connections: connections, title: "Restore")
    }

    func transferCSV(_ node: TreeNode, connections: ConnectionStore, importing: Bool) {
        guard let config = connections.connection(id: node.connectionID),
              let database = node.database, let table = node.table else { return }
        let url: URL?
        if importing {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            url = panel.runModal() == .OK ? panel.url : nil
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "\(table).csv"
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return }
        let target = SQLDialect.postgres.qualify(schema: node.schema, table: table)
        let file = url.path.replacingOccurrences(of: "'", with: "''")
        let direction = importing ? "FROM" : "TO"
        let command = "\\copy \(target) \(direction) '\(file)' WITH (FORMAT csv, HEADER true)"
        launch("psql", arguments: ["--dbname", database, "--command", command],
               node: node, config: config, connections: connections,
               title: importing ? "Importar CSV" : "Exportar CSV")
    }

    func cancel(_ id: UUID) { running[id]?.terminate() }
    func clearFinished() { entries.removeAll { running[$0.id] == nil } }

    private func qualified(_ schema: String?, _ table: String) -> String {
        guard let schema else { return table }
        return "\(schema).\(table)"
    }

    private func launch(_ executable: String, arguments: [String], node: TreeNode,
                        config: ConnectionConfig, connections: ConnectionStore, title: String) {
        let candidates = [
            "/opt/homebrew/opt/postgresql@18/bin/\(executable)",
            "/opt/homebrew/opt/postgresql@17/bin/\(executable)",
            "/opt/homebrew/opt/postgresql@16/bin/\(executable)",
            "/opt/homebrew/bin/\(executable)",
            "/usr/local/bin/\(executable)",
            "/Applications/Postgres.app/Contents/Versions/latest/bin/\(executable)"
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            entries.insert(Entry(title: title, target: node.title, status: "Ferramenta \(executable) não encontrada"), at: 0)
            visible = true
            return
        }
        var entry = Entry(title: title, target: node.title)
        let id = entry.id
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--host", config.host, "--port", String(config.port), "--username", config.username] + arguments
        var environment = ProcessInfo.processInfo.environment
        if let password = connections.password(for: config.id) { environment["PGPASSWORD"] = password }
        environment["PGSSLMODE"] = config.useTLS ? "require" : "prefer"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let output = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                self.entries[index].output += output
            }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                self.entries[index].status = finished.terminationStatus == 0 ? "Concluído" :
                    (finished.terminationReason == .uncaughtSignal ? "Cancelado" : "Falhou")
                self.running[id] = nil
            }
        }
        do {
            try process.run()
            entries.insert(entry, at: 0)
            running[id] = process
        } catch {
            entry.status = "Falhou"
            entry.output = error.localizedDescription
            entries.insert(entry, at: 0)
        }
        visible = true
    }
}

struct DatabaseProcessesView: View {
    @Bindable var processes: DatabaseProcesses
    @State private var selectedID: UUID?

    private var selected: DatabaseProcesses.Entry? {
        processes.entries.first { $0.id == selectedID } ?? processes.entries.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Icon(.processes, size: 19)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Processos").font(.system(size: 16, weight: .semibold))
                    Text("Backups, restaurações e transferências CSV")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if processes.entries.contains(where: { $0.status == "Em andamento" }) {
                    ProgressView().controlSize(.small)
                }
                Button("Limpar concluídos") { processes.clearFinished() }
                    .disabled(!processes.entries.contains { $0.status != "Em andamento" })
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            Divider()
            if processes.entries.isEmpty {
                VStack(spacing: 10) {
                    Icon(.processes, size: 28).foregroundStyle(.tertiary)
                    Text("Nenhum processo ainda").font(.system(size: 13, weight: .medium))
                    Text("Inicie um backup, restore ou transferência pelo menu de um banco ou tabela.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(processes.entries) { entry in
                                Button { selectedID = entry.id } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.title).font(.system(size: 12, weight: .medium))
                                        Text(entry.target).font(.system(size: 11)).lineLimit(1)
                                        Text(entry.status).font(.system(size: 10))
                                            .foregroundStyle(entry.status == "Falhou" ? Color.red : Color.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(selected?.id == entry.id ? Color.accentColor.opacity(0.13) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: 230)
                    Divider()
                    if let entry = selected { details(entry) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func details(_ entry: DatabaseProcesses.Entry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(entry.title) · \(entry.target)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Iniciado em \(entry.started.formatted(date: .abbreviated, time: .standard))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(entry.status == "Falhou" ? Color.red : Color.secondary)
                if entry.status == "Em andamento" {
                    Button("Cancelar") { processes.cancel(entry.id) }
                }
            }
            Divider()
            Text("Saída do processo").font(.system(size: 11, weight: .semibold))
            ScrollView {
                Text(entry.output.isEmpty ? "Aguardando saída…" : entry.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(entry.output.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
