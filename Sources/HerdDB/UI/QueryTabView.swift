import AppKit
import SwiftUI
import HerdCore

struct QueryTabView: View {
    @Environment(AppModel.self) private var app
    @Bindable var tab: QueryTab

    /// Altura do editor; o grid fica com o restante. Arrastável pelo divisor.
    @State private var editorHeight: CGFloat = 230
    @State private var dragOrigin: CGFloat?

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
    }

    private func effectiveEditorHeight(in available: CGFloat) -> CGFloat {
        min(max(editorHeight, 120), max(120, available - 180))
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            SolarIcon(.database, size: 13)
                .foregroundStyle(.secondary)

            Text(tab.contextLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            status

            Button {
                tab.run(app: app)
            } label: {
                Label("Executar", systemImage: "play.fill")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(tab.isRunning || tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Executar consulta (⌘↵)")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var status: some View {
        switch tab.state {
        case .idle:
            Text("⌘↵ para executar")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
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
        case .failure:
            Text("Erro na execução")
                .font(.system(size: 10.5))
                .foregroundStyle(.red)
        }
    }

    private func resultSummary(_ result: QueryResult) -> String {
        let ms = Int((result.elapsed * 1000).rounded())
        if result.isEmptyResultSet {
            return "Comando executado · \(ms) ms"
        }
        let rows = result.rows.count
        return "\(rows) \(rows == 1 ? "linha" : "linhas") · \(ms) ms"
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $tab.sql)
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .padding(6)

            if tab.sql.isEmpty {
                Text("Escreva SQL aqui…")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var results: some View {
        QueryResultsView(state: tab.state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
