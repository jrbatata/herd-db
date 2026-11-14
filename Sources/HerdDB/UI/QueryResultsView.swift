import SwiftUI
import HerdCore

struct QueryResultsView: View {
    let state: QueryRunState

    var body: some View {
        switch state {
        case .idle:
            placeholder(
                icon: .table,
                title: "Sem resultados",
                subtitle: "Execute o script com ⌘↵."
            )

        case .running:
            VStack(spacing: 10) {
                ProgressView()
                Text("Executando…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("⌘. para cancelar")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .cancelled:
            placeholder(
                icon: .stop,
                title: "Execução cancelada",
                subtitle: "Use ⌘↵ para executar de novo."
            )

        case .failure(let message):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text("Falha ao executar") } icon: { Icon(.warning, size: 14) }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))

        case .success(let result):
            if result.isEmptyResultSet {
                placeholder(
                    icon: .check,
                    title: result.message ?? "Comando executado",
                    subtitle: "\(Int((result.elapsed * 1000).rounded())) ms"
                )
            } else {
                ResultTable(result: result)
            }
        }
    }

    private func placeholder(icon: IconSymbol, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Icon(icon, size: 30)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ResultTable: View {
    let result: QueryResult

    private let displayLimit = 1_000

    private var rows: ArraySlice<[String?]> {
        result.rows.prefix(displayLimit)
    }

    private var widths: [CGFloat] {
        result.columns.enumerated().map { index, name in
            var longest = name.count
            for row in result.rows.prefix(60) where row.indices.contains(index) {
                longest = max(longest, min(row[index]?.count ?? 4, 90))
            }
            return min(max(CGFloat(longest) * 6.9 + 26, 84), 380)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow

                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                dataRow(index: index, row: row)
                            }

                            if result.rows.count > displayLimit {
                                Text("Mostrando \(displayLimit) de \(result.rows.count) linhas. A paginação chega na fase 4.")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                }
                .frame(minWidth: proxy.size.width, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
                .padding(.leading, 10)

            ForEach(Array(result.columns.enumerated()), id: \.offset) { index, name in
                Text(name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: widths[index], alignment: .leading)
                    .padding(.horizontal, 8)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 0.5)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
        }
    }

    private func dataRow(index: Int, row: [String?]) -> some View {
        HStack(spacing: 0) {
            Text(String(index + 1))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .leading)
                .padding(.leading, 10)

            ForEach(Array(result.columns.enumerated()), id: \.offset) { index, _ in
                let value = row.indices.contains(index) ? row[index] : nil
                Text(value ?? "NULL")
                    .font(.system(size: 11, design: .monospaced))
                    .italic(value == nil)
                    .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: widths[index], alignment: .leading)
                    .padding(.horizontal, 8)
                    .help(value ?? "NULL")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 22)
        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.028))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 0.5)
        }
    }
}
