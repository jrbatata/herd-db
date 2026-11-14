import AppKit
import SwiftUI
import HerdCore

struct QueryTabView: View {
    @Environment(AppModel.self) private var app
    @Bindable var tab: QueryTab

    /// Altura do editor; o grid fica com o restante. Arrastável pelo divisor.
    @State private var editorHeight: CGFloat = 230
    @State private var dragOrigin: CGFloat?
    @State private var databases: [String] = []
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()

            GeometryReader { proxy in
                VStack(spacing: 0) {
                    editor
                        .frame(height: effectiveEditorHeight(in: proxy.size.height))

                    SplitHandle()
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if dragOrigin == nil { dragOrigin = editorHeight }
                                    let proposed = (dragOrigin ?? editorHeight) + value.translation.height
                                    let maximum = max(140, proxy.size.height - 180)
                                    editorHeight = min(max(proposed, 120), maximum)
                                }
                                .onEnded { _ in dragOrigin = nil }
                        )

                    results
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: tab.connectionID) { await loadDatabases() }
        .inspector(isPresented: $showHistory) {
            QueryHistoryInspector(
                entries: app.history.latest(for: tab.connectionID, database: tab.database, limit: 500),
                onPick: { entry in tab.sql = entry.sql },
                onClear: { app.history.clear() },
                onClose: { showHistory = false }
            )
            .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
    }

    private func effectiveEditorHeight(in available: CGFloat) -> CGFloat {
        min(max(editorHeight, 120), max(120, available - 180))
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            Icon(.database, size: 13)
                .foregroundStyle(.secondary)

            Text(tab.connectionName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            databasePicker

            Spacer(minLength: 8)

            status

            historyButton

            if tab.isRunning {
                Button {
                    tab.cancel()
                } label: {
                    HStack(spacing: 6) {
                        Icon(.stop, size: 12, solid: true)
                        Text("Cancelar")
                        KeyHint("⌘.", onProminent: false)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Cancelar execução (⌘.)")
            } else {
                Button {
                    tab.run(app: app)
                } label: {
                    HStack(spacing: 6) {
                        Icon(.play, size: 11, solid: true)
                        Text("Executar")
                        KeyHint("⌘↵", onProminent: true)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!tab.hasText)
                .help("Executar script (⌘↵)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var databasePicker: some View {
        Picker("Banco de dados", selection: $tab.database) {
            ForEach(databaseOptions, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: 190)
        .disabled(tab.isRunning)
        .help("Banco de dados deste script")
    }

    private var databaseOptions: [String] {
        var names = databases
        if !names.contains(tab.database) {
            names.insert(tab.database, at: 0)
        }
        return names
    }

    @ViewBuilder
    private var status: some View {
        switch tab.state {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                Text("Executando…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        case .success(let result):
            Text(resultSummary(result))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .cancelled:
            Text("Execução cancelada")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .failure:
            Text("Erro na execução")
                .font(.system(size: 10.5))
                .foregroundStyle(.red)
        }
    }

    private func resultSummary(_ result: QueryResult) -> String {
        let ms = Int((result.elapsed * 1000).rounded())
        var parts: [String] = []

        if result.statementCount > 1 {
            parts.append("\(result.statementCount) comandos")
        }

        if result.isEmptyResultSet {
            if result.statementCount <= 1 {
                parts.append("comando executado")
            }
        } else {
            let rows = result.rows.count
            parts.append("\(rows) \(rows == 1 ? "linha" : "linhas")")
        }

        parts.append("\(ms) ms")
        return parts.joined(separator: " · ")
    }

    private var historyButton: some View {
        Button {
            showHistory.toggle()
        } label: {
            Icon(.clock, size: 14)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Histórico de scripts")
    }

    // MARK: - Editor and results

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            SQLEditorView(text: $tab.sql, selection: $tab.selection)

            if tab.sql.isEmpty {
                Text("Escreva SQL aqui…")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 52)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
    }

    private var results: some View {
        QueryResultsView(state: tab.state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadDatabases() async {
        guard let config = app.connections.connection(id: tab.connectionID) else { return }
        let driver = app.drivers.driver(for: config)
        guard let list = try? await driver.listDatabases() else { return }
        databases = list.map(\.name)
    }
}

/// Divisor fino entre editor e resultados, com cursor de redimensionamento.
private struct SplitHandle: View {
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 7)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside != isHovering else { return }
            isHovering = inside
            if inside {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Key hint

/// Atalho em formato de tecla, com fundo translúcido sobre o botão.
private struct KeyHint: View {
    let text: String
    let onProminent: Bool

    init(_ text: String, onProminent: Bool) {
        self.text = text
        self.onProminent = onProminent
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(onProminent ? Color.white.opacity(0.22) : Color.primary.opacity(0.08))
            }
            .opacity(0.9)
    }
}

// MARK: - History inspector

private struct QueryHistoryInspector: View {
    let entries: [QueryHistoryEntry]
    let onPick: (QueryHistoryEntry) -> Void
    let onClear: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Histórico")
                    .font(.system(size: 11.5, weight: .semibold))

                Spacer()

                Button("Limpar") {
                    onClear()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .disabled(entries.isEmpty)

                Button(action: onClose) {
                    Icon(.close, size: 11)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if entries.isEmpty {
                VStack(spacing: 6) {
                    Icon(.clock, size: 22)
                        .foregroundStyle(.tertiary)
                    Text("Nenhum script neste banco.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry) {
                                onPick(entry)
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HistoryRow: View {
    let entry: QueryHistoryEntry
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(entry.isFailure ? Color.red : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    if entry.isFailure {
                        Icon(.warning, size: 11)
                            .foregroundStyle(.red)
                    }
                }

                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var detail: String {
        var parts = [entry.date.formatted(.relative(presentation: .named))]
        let ms = Int((entry.duration * 1000).rounded())
        parts.append("\(ms) ms")
        if entry.isFailure {
            parts.append("erro")
        } else if entry.rowCount > 0 {
            parts.append("\(entry.rowCount) \(entry.rowCount == 1 ? "linha" : "linhas")")
        }
        return parts.joined(separator: " · ")
    }
}
