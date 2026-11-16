import AppKit
import HerdCore
import SwiftUI

/// Console inferior com todas as consultas enviadas ao servidor, inclusive as
/// internas (catálogo, paginação e commit do grid). Separado do histórico, que
/// guarda apenas o que o usuário executa.
struct QueryConsoleView: View {
    @Environment(AppModel.self) private var app
    @Bindable var workspace: WorkspaceState
    @AppStorage("queryConsoleHighlight") private var highlight = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if app.queryLog.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(app.queryLog.entries) { entry in
                            QueryConsoleRow(entry: entry, highlight: highlight)
                            Divider().opacity(0.45)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 1)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Icon(.clock, size: 13)
                .foregroundStyle(.secondary)
            Text("Console")
                .font(.system(size: 11.5, weight: .semibold))

            Text("\(app.queryLog.entries.count)")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: Capsule())

            Spacer()

            Toggle("Realce", isOn: $highlight)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))
                .help("Realçar a sintaxe do SQL")

            Button("Limpar") {
                app.queryLog.clear()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .disabled(app.queryLog.entries.isEmpty)

            Button {
                workspace.consoleVisible = false
            } label: {
                Icon(.close, size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Fechar console (⌃⌘C)")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Icon(.clock, size: 22)
                .foregroundStyle(.tertiary)
            Text("Nenhuma consulta registrada")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Tudo o que for enviado ao servidor aparece aqui, inclusive catálogo e paginação.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QueryConsoleRow: View {
    let entry: QueryLogEntry
    let highlight: Bool

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                sourceBadge

                Text("\(entry.connectionName) · \(entry.database)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if entry.isFailure {
                    Icon(.alertCircle, size: 11, solid: true)
                        .foregroundStyle(.red)
                }

                Text(Self.durationText(entry.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Text("\(entry.rowCount) lin.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Button {
                    expanded.toggle()
                } label: {
                    Icon(.chevron, size: 9)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Recolher SQL" : "Expandir SQL")
            }

            Text(highlight ? Self.highlighted(entry.sql) : AttributedString(entry.sql))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let note = entry.truncatedNote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }

            if let error = entry.errorMessage {
                Text(error)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .contextMenu {
            Button("Copiar SQL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.sql, forType: .string)
            }
            Button("Copiar tudo") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.fullText(for: entry), forType: .string)
            }
        }
    }

    private var sourceBadge: some View {
        Text(entry.source.displayName)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Self.sourceColor(entry.source))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Self.sourceColor(entry.source).opacity(0.12), in: Capsule())
    }

    private static func sourceColor(_ source: QueryLogSource) -> Color {
        switch source {
        case .user: .init(nsColor: .systemBlue)
        case .browse: .init(nsColor: .systemTeal)
        case .catalog: .secondary
        case .commit: .init(nsColor: .systemPurple)
        case .cancel: .init(nsColor: .systemOrange)
        case .system: .secondary
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let milliseconds = duration * 1_000
        if milliseconds < 1 { return "<1 ms" }
        if milliseconds < 1_000 { return String(format: "%.1f ms", milliseconds) }
        return String(format: "%.2f s", duration)
    }

    private static func fullText(for entry: QueryLogEntry) -> String {
        var text = "\(timeFormatter.string(from: entry.date))  "
        text += "\(entry.source.displayName)  "
        text += "\(entry.connectionName) · \(entry.database)  "
        text += "\(durationText(entry.duration))  \(entry.rowCount) linhas\n"
        text += entry.sql
        if let error = entry.errorMessage {
            text += "\n\n-- Erro: \(error)"
        }
        return text
    }

    private static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }

    // MARK: - Syntax highlighting

    private static func highlighted(_ sql: String) -> AttributedString {
        let text = sql as NSString
        var result = AttributedString()
        var cursor = 0

        for token in SQLTokenizer.tokens(in: sql) {
            guard token.range.location >= cursor,
                  token.range.location + token.range.length <= text.length else { continue }

            if token.range.location > cursor {
                let plain = text.substring(with: NSRange(
                    location: cursor,
                    length: token.range.location - cursor
                ))
                result += AttributedString(plain)
            }

            var piece = AttributedString(text.substring(with: token.range))
            piece.foregroundColor = color(for: token.kind)
            result += piece
            cursor = token.range.location + token.range.length
        }

        if cursor < text.length {
            result += AttributedString(text.substring(from: cursor))
        }
        return result
    }

    private static func color(for kind: SQLTokenKind) -> Color {
        switch kind {
        case .keyword: .init(nsColor: .systemBlue)
        case .string: .init(nsColor: .systemRed)
        case .number: .init(nsColor: .systemPurple)
        case .comment: .secondary
        case .quotedIdentifier: .init(nsColor: .systemTeal)
        case .parameter: .init(nsColor: .systemOrange)
        }
    }
}
