import AppKit
import SwiftUI
import HerdCore
import UniformTypeIdentifiers

struct QueryResultsView: View {
    let state: QueryRunState
    var tablePage: TablePage? = nil
    var tableFilter = ""
    var tableSortColumn: String? = nil
    var tableSortDescending = false
    var sourceTable: String? = nil
    var schema: String? = nil
    var dialect: SQLDialect = .postgres
    var onBrowsePage: ((Int) -> Void)? = nil
    var onApplyFilter: ((String) -> Void)? = nil
    var onSort: ((String) -> Void)? = nil
    var onCommitSQL: (([String]) async throws -> Void)? = nil
    var onOpenForeignKey: ((String, String) -> Void)? = nil

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
                    Label { Text("Falha ao executar") } icon: { Icon(.alertCircle, size: 14, solid: true) }
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
            if result.isEmptyResultSet && sourceTable == nil {
                placeholder(
                    icon: .check,
                    title: result.message ?? "Comando executado",
                    subtitle: "\(Int((result.elapsed * 1000).rounded())) ms"
                )
            } else if result.sets.count > 1 {
                MultiResultView(sets: result.sets)
                    .id(result.sets.count)
            } else {
                let columns = result.columns.isEmpty ? (tablePage?.columns.map(\.name) ?? []) : result.columns
                ResultTable(
                    resultSet: ResultSet(columns: columns, rows: result.rows),
                    message: result.message,
                    tablePage: tablePage,
                    tableFilter: tableFilter,
                    tableSortColumn: tableSortColumn,
                    tableSortDescending: tableSortDescending,
                    sourceTable: sourceTable,
                    schema: schema,
                    dialect: dialect,
                    onBrowsePage: onBrowsePage,
                    onApplyFilter: onApplyFilter,
                    onSort: onSort,
                    onCommitSQL: onCommitSQL,
                    onOpenForeignKey: onOpenForeignKey
                )
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

/// Vários resultados empilhados, cada bloco com altura própria ajustável pelos divisores.
private struct MultiResultView: View {
    let sets: [ResultSet]

    @State private var weights: [CGFloat]
    @State private var closed: Set<Int> = []
    @State private var dragOrigin: [CGFloat]?

    private let minimumBlockHeight: CGFloat = 80
    private let handleHeight: CGFloat = 7

    init(sets: [ResultSet]) {
        self.sets = sets
        _weights = State(initialValue: Array(repeating: 1, count: sets.count))
    }

    private var visible: [Int] {
        sets.indices.filter { !closed.contains($0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let shown = visible
            let available = max(1, proxy.size.height - handleHeight * CGFloat(max(0, shown.count - 1)))
            let total = max(0.001, shown.map { weights[$0] }.reduce(0, +))

            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element) { position, index in
                    if position > 0 {
                        SplitHandle()
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        if dragOrigin == nil { dragOrigin = weights }
                                        resize(
                                            upper: shown[position - 1],
                                            lower: index,
                                            shown: shown,
                                            translation: value.translation.height,
                                            available: available
                                        )
                                    }
                                    .onEnded { _ in dragOrigin = nil }
                            )
                    }

                    block(index: index, set: sets[index])
                        .frame(height: available * weights[index] / total)
                }

                if shown.isEmpty {
                    Spacer()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .textBackgroundColor))
            .transaction { $0.animation = nil }
        }
    }

    private func block(index: Int, set: ResultSet) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Resultado \(index + 1)")
                    .font(.system(size: 10.5, weight: .medium))
                Text("\(set.rows.count) \(set.rows.count == 1 ? "linha" : "linhas")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()

                Button {
                    closed.insert(index)
                } label: {
                    Icon(.close, size: 10)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fechar este resultado")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Color(nsColor: .windowBackgroundColor))

            ResultTable(resultSet: set)
        }
        .clipped()
    }

    private func resize(upper: Int, lower: Int, shown: [Int], translation: CGFloat, available: CGFloat) {
        guard let origin = dragOrigin else { return }
        let total = shown.map { origin[$0] }.reduce(0, +)
        let pointsPerWeight = available / total

        let upperStart = origin[upper] * pointsPerWeight
        let lowerStart = origin[lower] * pointsPerWeight
        let pair = upperStart + lowerStart

        let newUpper = min(max(upperStart + translation, minimumBlockHeight), pair - minimumBlockHeight)
        var updated = origin
        updated[upper] = newUpper / pointsPerWeight
        updated[lower] = (pair - newUpper) / pointsPerWeight
        weights = updated
    }
}

private struct CellCoord: Hashable {
    var rowOffset: Int
    var colIndex: Int
}

private struct InsertedRow: Identifiable, Equatable {
    let id = UUID()
    var values: [String?]
}

private struct ResultTable: View {
    let resultSet: ResultSet
    let message: String?
    let tablePage: TablePage?
    let tableFilter: String
    let tableSortColumn: String?
    let tableSortDescending: Bool
    let sourceTable: String?
    let schema: String?
    let dialect: SQLDialect
    let onBrowsePage: ((Int) -> Void)?
    let onApplyFilter: ((String) -> Void)?
    let onSort: ((String) -> Void)?
    let onCommitSQL: (([String]) async throws -> Void)?
    let onOpenForeignKey: ((String, String) -> Void)?

    @State private var columnWidths: [CGFloat]
    @State private var dragWidths: [CGFloat]?
    @State private var filter = ""
    @State private var page = 0
    @State private var selectedRows: Set<Int> = []
    @State private var selectionAnchor: Int?
    @State private var showMessages = false
    @State private var copyMenuHovering = false

    // Edição inline
    @State private var editedCells: [Int: [Int: String?]] = [:]
    @State private var insertedRows: [InsertedRow] = []
    @State private var deletedRowOffsets: Set<Int> = []
    @State private var editingCell: CellCoord?
    @State private var editingText: String = ""
    @State private var isCommitting = false
    @State private var commitError: String?
    @State private var showReviewSheet = false

    @FocusState private var cellEditorFocused: Bool
    @FocusState private var filterFieldFocused: Bool

    private var pageSize: Int { tablePage == nil ? 100 : 500 }
    private var canEditInline: Bool { sourceTable != nil && onCommitSQL != nil }

    init(
        resultSet: ResultSet,
        message: String? = nil,
        tablePage: TablePage? = nil,
        tableFilter: String = "",
        tableSortColumn: String? = nil,
        tableSortDescending: Bool = false,
        sourceTable: String? = nil,
        schema: String? = nil,
        dialect: SQLDialect = .postgres,
        onBrowsePage: ((Int) -> Void)? = nil,
        onApplyFilter: ((String) -> Void)? = nil,
        onSort: ((String) -> Void)? = nil,
        onCommitSQL: (([String]) async throws -> Void)? = nil,
        onOpenForeignKey: ((String, String) -> Void)? = nil
    ) {
        self.resultSet = resultSet
        self.message = message
        self.tablePage = tablePage
        self.tableFilter = tableFilter
        self.tableSortColumn = tableSortColumn
        self.tableSortDescending = tableSortDescending
        self.sourceTable = sourceTable
        self.schema = schema
        self.dialect = dialect
        self.onBrowsePage = onBrowsePage
        self.onApplyFilter = onApplyFilter
        self.onSort = onSort
        self.onCommitSQL = onCommitSQL
        self.onOpenForeignKey = onOpenForeignKey
        _columnWidths = State(initialValue: Self.initialWidths(for: resultSet))
        _filter = State(initialValue: tableFilter)
    }

    private var filteredRows: [(offset: Int, element: [String?])] {
        let all = Array(resultSet.rows.enumerated())
        if tablePage != nil { return all }
        guard !filter.isEmpty else { return all }
        return all.filter { row in
            row.element.contains { ($0 ?? "NULL").localizedCaseInsensitiveContains(filter) }
        }
    }

    private var basePageRows: [(offset: Int, element: [String?])] {
        if let tablePage {
            return filteredRows.map { (offset: tablePage.page * pageSize + $0.offset, element: $0.element) }
        }
        let start = min(page * pageSize, filteredRows.count)
        return Array(filteredRows.dropFirst(start).prefix(pageSize))
    }

    private var pageRows: [(offset: Int, element: [String?])] {
        var rows = basePageRows
        let baseNextOffset = (basePageRows.last?.offset ?? ((tablePage?.page ?? page) * pageSize - 1)) + 1
        for (idx, ins) in insertedRows.enumerated() {
            rows.append((offset: baseNextOffset + idx, element: ins.values))
        }
        return rows
    }

    private func isInsertedOffset(_ offset: Int) -> Int? {
        let baseNextOffset = (basePageRows.last?.offset ?? ((tablePage?.page ?? page) * pageSize - 1)) + 1
        let idx = offset - baseNextOffset
        guard insertedRows.indices.contains(idx) else { return nil }
        return idx
    }

    private var hasPendingChanges: Bool {
        !editedCells.isEmpty || !insertedRows.isEmpty || !deletedRowOffsets.isEmpty
    }

    private var pendingChangesCount: Int {
        editedCells.count + insertedRows.count + deletedRowOffsets.count
    }

    private var pageCount: Int { max(1, ((tablePage?.totalRows ?? filteredRows.count) + pageSize - 1) / pageSize) }
    private var currentPage: Int { tablePage?.page ?? page }

    private static func initialWidths(for set: ResultSet) -> [CGFloat] {
        set.columns.enumerated().map { index, name in
            var longest = name.count
            for row in set.rows.prefix(60) where row.indices.contains(index) {
                longest = max(longest, min(row[index]?.count ?? 4, 90))
            }
            return min(max(CGFloat(longest) * 6.9 + 26, 84), 380)
        }
    }

    private func width(_ index: Int) -> CGFloat {
        columnWidths.indices.contains(index) ? columnWidths[index] : 120
    }

    private func columnInfo(at colIndex: Int) -> ColumnInfo? {
        guard let cols = tablePage?.columns, resultSet.columns.indices.contains(colIndex) else { return nil }
        let name = resultSet.columns[colIndex]
        return cols.first { $0.name == name }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .zIndex(10)
            if let commitError {
                HStack(spacing: 8) {
                    Icon(.alertCircle, size: 14, solid: true)
                        .foregroundStyle(.red)
                    Text(commitError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        self.commitError = nil
                    } label: {
                        Icon(.close, size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.12))
                Divider()
            }
            Divider()
            if showMessages {
                ScrollView {
                    Text(message ?? (resultSet.rows.isEmpty ? "Nenhuma linha retornada." : "\(resultSet.rows.count) linhas retornadas."))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                GeometryReader { proxy in
                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                headerRow
                                ScrollView(.vertical) {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(pageRows, id: \.offset) { item in
                                            dataRow(index: item.offset, row: item.element)
                                                .id(item.offset)
                                        }
                                    }
                                }
                            }
                            .frame(minWidth: proxy.size.width, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .onChange(of: insertedRows.count) { oldCount, newCount in
                            if newCount > oldCount, let last = pageRows.last {
                                withAnimation(.snappy(duration: 0.2)) {
                                    scrollProxy.scrollTo(last.offset, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            pagination
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: filter) { _, _ in
            if tablePage == nil { page = 0; selectedRows.removeAll(); selectionAnchor = nil }
        }
        .onChange(of: resultSet) { _, _ in
            columnWidths = Self.initialWidths(for: resultSet)
            discardChanges()
        }
        .sheet(isPresented: $showReviewSheet) {
            ReviewSQLChangesSheet(
                statements: generateSQLStatements(),
                isCommitting: isCommitting,
                onConfirm: {
                    showReviewSheet = false
                    commitChanges()
                }
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            // Ações rápidas de edição e exportação (tamanho fixo para nunca serem cortadas)
            HStack(spacing: 3) {
                if canEditInline {
                    WindowIconButton(
                        symbol: .plus,
                        selected: false,
                        help: "Adicionar nova linha no final (⌘I / Duplo clique para editar)"
                    ) {
                        addInlineRow()
                    }

                    WindowIconButton(
                        symbol: .trash,
                        selected: false,
                        help: "Remover linhas selecionadas (⌘⌫)",
                        disabled: selectedRows.isEmpty
                    ) {
                        deleteSelectedRows()
                    }

                    WindowIconButton(
                        symbol: .save,
                        selected: hasPendingChanges,
                        help: hasPendingChanges ? "Salvar alterações no banco (\(pendingChangesCount) pendente\(pendingChangesCount == 1 ? "" : "s"))" : "Sem alterações pendentes",
                        disabled: !hasPendingChanges || isCommitting
                    ) {
                        commitChanges()
                    }

                    if hasPendingChanges {
                        WindowIconButton(
                            symbol: .undo,
                            selected: false,
                            help: "Descartar alterações não salvas (⌘Z)"
                        ) {
                            discardChanges()
                        }

                        Button("Revisar SQL (\(pendingChangesCount))") {
                            commitActiveCellEdit()
                            showReviewSheet = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.system(size: 10.5, weight: .medium))
                        .help("Visualizar comandos INSERT / UPDATE / DELETE antes de salvar")
                    }

                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 2)
                }

                Menu {
                    Button("Copiar") { copyRows(withHeaders: false) }
                        .keyboardShortcut("c", modifiers: .command)
                    Button("Copiar com cabeçalhos") { copyRows(withHeaders: true) }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                } label: {
                    Icon(.copy, size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 28)
                        .background(
                            copyMenuHovering ? Color.primary.opacity(0.09) : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                } primaryAction: {
                    copyRows(withHeaders: false)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .controlSize(.small)
                .fixedSize()
                .help("Copiar linhas selecionadas (⌘C)")
                .onHover { copyMenuHovering = $0 }

                WindowIconButton(
                    symbol: .download,
                    selected: false,
                    help: "Exportar resultado em CSV",
                    disabled: resultSet.columns.isEmpty
                ) {
                    exportCSV()
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            // Campo de filtro com fundo limpo (sem cobrir os divisores ou ícones)
            HStack(spacing: 5) {
                Icon(.search, size: 13)
                    .foregroundStyle(.secondary)
                TextField("Filtrar resultados", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($filterFieldFocused)
                    .onSubmit { onApplyFilter?(filter) }
                if !filter.isEmpty {
                    Button {
                        filter = ""
                        onApplyFilter?("")
                    } label: {
                        Icon(.close, size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Limpar filtro")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(minWidth: 120, maxWidth: 220)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            if let onApplyFilter, tablePage != nil {
                Button("Aplicar") { onApplyFilter(filter) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .font(.system(size: 10.5))
                    .disabled(filter == tableFilter)
                    .help("Filtrar todas as linhas no servidor")
            }

            Spacer(minLength: 8)

            Button {
                showMessages.toggle()
            } label: {
                Text(showMessages ? "Dados" : "Mensagens")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(showMessages ? "Mostrar dados" : "Mostrar mensagens da execução")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var pagination: some View {
        HStack(spacing: 10) {
            let count = (tablePage?.totalRows ?? filteredRows.count) + insertedRows.count - deletedRowOffsets.count
            Text("\(max(0, count)) \(count == 1 ? "linha" : "linhas")")
                .foregroundStyle(.secondary)
            if !selectedRows.isEmpty {
                Text("· \(selectedRows.count) selecionada\(selectedRows.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            if hasPendingChanges {
                Text("· \(pendingChangesCount) alteração\(pendingChangesCount == 1 ? "" : "ões") não salva\(pendingChangesCount == 1 ? "" : "s")")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button { changePage(max(0, currentPage - 1)) } label: {
                Icon(.chevron, size: 12).rotationEffect(.degrees(180))
            }
            .disabled(currentPage == 0)
            .help("Página anterior")
            Text("Página \(currentPage + 1) de \(pageCount)")
            Button { changePage(min(pageCount - 1, currentPage + 1)) } label: {
                Icon(.chevron, size: 12)
            }
            .disabled(currentPage >= pageCount - 1)
            .help("Próxima página")
        }
        .font(.system(size: 10.5))
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func changePage(_ target: Int) {
        commitActiveCellEdit()
        selectedRows.removeAll()
        selectionAnchor = nil
        if let onBrowsePage, tablePage != nil { onBrowsePage(target) }
        else { page = target }
    }

    // MARK: - Selection

    private func handleRowClick(_ rowOffset: Int) {
        if editingCell?.rowOffset != rowOffset {
            commitActiveCellEdit()
        }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift), let anchor = selectionAnchor {
            let visibleOffsets = pageRows.map(\.offset)
            if let i1 = visibleOffsets.firstIndex(of: anchor),
               let i2 = visibleOffsets.firstIndex(of: rowOffset) {
                let lower = min(i1, i2)
                let upper = max(i1, i2)
                selectedRows = Set(visibleOffsets[lower...upper])
                return
            }
        }
        if flags.contains(.command) {
            if selectedRows.contains(rowOffset) {
                selectedRows.remove(rowOffset)
            } else {
                selectedRows.insert(rowOffset)
                selectionAnchor = rowOffset
            }
            return
        }
        if selectedRows.count == 1 && selectedRows.contains(rowOffset) {
            selectedRows.removeAll()
            selectionAnchor = nil
        } else {
            selectedRows = [rowOffset]
            selectionAnchor = rowOffset
        }
    }

    // MARK: - Inline Editing Actions

    private func addInlineRow() {
        commitActiveCellEdit()
        let emptyValues: [String?] = Array(repeating: nil, count: resultSet.columns.count)
        insertedRows.append(InsertedRow(values: emptyValues))
        if let newOffset = pageRows.last?.offset {
            selectedRows = [newOffset]
            selectionAnchor = newOffset
            if !resultSet.columns.isEmpty {
                startEditing(rowOffset: newOffset, colIndex: 0)
            }
        }
    }

    private func deleteSelectedRows() {
        commitActiveCellEdit()
        guard !selectedRows.isEmpty else { return }
        let baseNextOffset = (basePageRows.last?.offset ?? ((tablePage?.page ?? page) * pageSize - 1)) + 1
        var insertedIndicesToRemove: IndexSet = []

        for offset in selectedRows {
            if offset >= baseNextOffset {
                let idx = offset - baseNextOffset
                if insertedRows.indices.contains(idx) {
                    insertedIndicesToRemove.insert(idx)
                }
            } else {
                if deletedRowOffsets.contains(offset) {
                    deletedRowOffsets.remove(offset)
                } else {
                    deletedRowOffsets.insert(offset)
                }
            }
        }
        for idx in insertedIndicesToRemove.sorted(by: >) {
            insertedRows.remove(at: idx)
        }
        selectedRows.removeAll()
        selectionAnchor = nil
    }

    private func discardChanges() {
        editingCell = nil
        editedCells.removeAll()
        insertedRows.removeAll()
        deletedRowOffsets.removeAll()
        commitError = nil
    }

    private func effectiveValue(rowOffset: Int, colIndex: Int, originalRow: [String?]) -> String? {
        if let insIdx = isInsertedOffset(rowOffset) {
            return insertedRows[insIdx].values.indices.contains(colIndex) ? insertedRows[insIdx].values[colIndex] : nil
        }
        if let rowEdits = editedCells[rowOffset], let edited = rowEdits[colIndex] {
            return edited
        }
        return originalRow.indices.contains(colIndex) ? originalRow[colIndex] : nil
    }

    private func isCellModified(rowOffset: Int, colIndex: Int) -> Bool {
        if isInsertedOffset(rowOffset) != nil { return true }
        return editedCells[rowOffset]?[colIndex] != nil
    }

    private func startEditing(rowOffset: Int, colIndex: Int) {
        guard canEditInline else { return }
        if editingCell != nil {
            commitActiveCellEdit()
        }
        guard let row = pageRows.first(where: { $0.offset == rowOffset })?.element else { return }
        let current = effectiveValue(rowOffset: rowOffset, colIndex: colIndex, originalRow: row)
        editingText = current ?? ""
        editingCell = CellCoord(rowOffset: rowOffset, colIndex: colIndex)
        selectedRows = [rowOffset]
        selectionAnchor = rowOffset
        Task { @MainActor in
            cellEditorFocused = true
        }
    }

    private func commitActiveCellEdit() {
        guard let coord = editingCell else { return }
        let newValue: String? = editingText.uppercased() == "NULL" ? nil : editingText

        if let insIdx = isInsertedOffset(coord.rowOffset) {
            let finalVal: String? = editingText.isEmpty ? nil : newValue
            if insertedRows[insIdx].values.indices.contains(coord.colIndex) {
                insertedRows[insIdx].values[coord.colIndex] = finalVal
            }
        } else if let originalRow = basePageRows.first(where: { $0.offset == coord.rowOffset })?.element {
            let origVal = originalRow.indices.contains(coord.colIndex) ? originalRow[coord.colIndex] : nil
            if newValue == origVal || (editingText.isEmpty && origVal == nil) {
                editedCells[coord.rowOffset]?.removeValue(forKey: coord.colIndex)
                if editedCells[coord.rowOffset]?.isEmpty == true {
                    editedCells.removeValue(forKey: coord.rowOffset)
                }
            } else {
                var rowDict = editedCells[coord.rowOffset] ?? [:]
                rowDict[coord.colIndex] = .some(newValue)
                editedCells[coord.rowOffset] = rowDict
            }
        }
        editingCell = nil
    }

    private func advanceEditingCell(reverse: Bool = false) {
        guard let coord = editingCell else { return }
        commitActiveCellEdit()
        let colCount = resultSet.columns.count
        guard colCount > 0 else { return }

        if !reverse {
            if coord.colIndex + 1 < colCount {
                startEditing(rowOffset: coord.rowOffset, colIndex: coord.colIndex + 1)
            } else {
                let offsets = pageRows.map(\.offset)
                if let idx = offsets.firstIndex(of: coord.rowOffset), idx + 1 < offsets.count {
                    startEditing(rowOffset: offsets[idx + 1], colIndex: 0)
                }
            }
        } else {
            if coord.colIndex - 1 >= 0 {
                startEditing(rowOffset: coord.rowOffset, colIndex: coord.colIndex - 1)
            } else {
                let offsets = pageRows.map(\.offset)
                if let idx = offsets.firstIndex(of: coord.rowOffset), idx - 1 >= 0 {
                    startEditing(rowOffset: offsets[idx - 1], colIndex: colCount - 1)
                }
            }
        }
    }

    // MARK: - SQL Generation & Commit

    private func sqlLiteral(_ value: String?) -> String {
        guard let value else { return "NULL" }
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        let prefix = dialect.family == .sqlServer ? "N" : ""
        return "\(prefix)'\(escaped)'"
    }

    private func whereClause(for originalRow: [String?], dialect: SQLDialect) -> String {
        let pkIndices: [Int] = resultSet.columns.enumerated().compactMap { idx, colName in
            if tablePage?.columns.first(where: { $0.name == colName })?.isPrimaryKey == true {
                return idx
            }
            return nil
        }
        let targetIndices = pkIndices.isEmpty ? Array(resultSet.columns.indices) : pkIndices
        let predicates: [String] = targetIndices.compactMap { idx in
            guard resultSet.columns.indices.contains(idx) else { return nil }
            let col = dialect.quote(resultSet.columns[idx])
            let val = originalRow.indices.contains(idx) ? originalRow[idx] : nil
            if let val {
                return "\(col) = \(sqlLiteral(val))"
            } else {
                return "\(col) IS NULL"
            }
        }
        return predicates.joined(separator: " AND ")
    }

    private func generateSQLStatements() -> [String] {
        guard let sourceTable else { return [] }
        let dialect = self.dialect
        let target = dialect.qualify(schema: schema ?? (dialect.family == .sqlServer ? "dbo" : "public"), table: sourceTable)
        var statements: [String] = []

        // 1. DELETEs
        for offset in deletedRowOffsets.sorted() {
            guard let origRow = basePageRows.first(where: { $0.offset == offset })?.element else { continue }
            let predicate = whereClause(for: origRow, dialect: dialect)
            if !predicate.isEmpty {
                statements.append("DELETE FROM \(target) WHERE \(predicate);")
            }
        }

        // 2. UPDATEs
        for offset in editedCells.keys.sorted() where !deletedRowOffsets.contains(offset) {
            guard let changes = editedCells[offset], !changes.isEmpty,
                  let origRow = basePageRows.first(where: { $0.offset == offset })?.element else { continue }
            let setPairs: [String] = changes.keys.sorted().compactMap { colIdx in
                guard resultSet.columns.indices.contains(colIdx),
                      let newVal = changes[colIdx] else { return nil }
                let colName = dialect.quote(resultSet.columns[colIdx])
                return "\(colName) = \(sqlLiteral(newVal))"
            }
            let predicate = whereClause(for: origRow, dialect: dialect)
            if !setPairs.isEmpty, !predicate.isEmpty {
                statements.append("UPDATE \(target) SET \(setPairs.joined(separator: ", ")) WHERE \(predicate);")
            }
        }

        // 3. INSERTs
        for ins in insertedRows {
            var cols: [String] = []
            var vals: [String] = []
            for (colIdx, val) in ins.values.enumerated() where resultSet.columns.indices.contains(colIdx) {
                if let val {
                    cols.append(dialect.quote(resultSet.columns[colIdx]))
                    vals.append(sqlLiteral(val))
                }
            }
            if cols.isEmpty {
                statements.append("INSERT INTO \(target) DEFAULT VALUES;")
            } else {
                statements.append("INSERT INTO \(target) (\(cols.joined(separator: ", "))) VALUES (\(vals.joined(separator: ", ")));")
            }
        }

        return statements
    }

    private func commitChanges() {
        commitActiveCellEdit()
        let statements = generateSQLStatements()
        guard !statements.isEmpty, let onCommitSQL else { return }
        isCommitting = true
        commitError = nil
        Task { @MainActor in
            do {
                try await onCommitSQL(statements)
                isCommitting = false
                discardChanges()
            } catch is CancellationError {
                // Safe Mode cancelado: mantém as edições pendentes.
                isCommitting = false
            } catch {
                isCommitting = false
                commitError = error.localizedDescription
            }
        }
    }

    // MARK: - Copy & CSV Export

    private func copyRows(withHeaders: Bool) {
        let chosen = pageRows.filter { selectedRows.isEmpty || selectedRows.contains($0.offset) }
        var lines: [String] = []
        if withHeaders { lines.append(resultSet.columns.joined(separator: "\t")) }
        lines += chosen.map { item in
            item.element.enumerated().map { colIdx, _ in
                let val = effectiveValue(rowOffset: item.offset, colIndex: colIdx, originalRow: item.element)
                return (val ?? "").replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }.joined(separator: "\t")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(sourceTable ?? "resultado").csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        func escapeCSV(_ field: String) -> String {
            if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return field
        }

        var lines: [String] = []
        lines.append(resultSet.columns.map(escapeCSV).joined(separator: ","))
        let rowsToExport: [[String?]] = selectedRows.isEmpty
            ? filteredRows.map(\.element)
            : pageRows.filter { selectedRows.contains($0.offset) }.map { item in
                resultSet.columns.indices.map { colIdx in
                    effectiveValue(rowOffset: item.offset, colIndex: colIdx, originalRow: item.element)
                }
            }

        for row in rowsToExport {
            lines.append(row.map { escapeCSV($0 ?? "") }.joined(separator: ","))
        }

        let content = lines.joined(separator: "\n") + "\n"
        try? content.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - Grid Rows

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
                .padding(.leading, 10)

            ForEach(Array(resultSet.columns.enumerated()), id: \.offset) { index, name in
                let colMeta = columnInfo(at: index)
                HStack(spacing: 4) {
                    if colMeta?.isPrimaryKey == true {
                        Icon(.key, size: 10)
                            .foregroundStyle(.orange)
                    } else if colMeta?.references != nil {
                        Icon(.link, size: 10)
                            .foregroundStyle(.secondary)
                    }
                    Text(name + (tableSortColumn == name ? (tableSortDescending ? " ↓" : " ↑") : ""))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: width(index), alignment: .leading)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onTapGesture { if tablePage != nil { onSort?(name) } }
                .help(tablePage == nil ? name : "Ordenar por \(name)")
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 0.5)
                }
                .overlay(alignment: .trailing) {
                    Color.clear.frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragWidths == nil { dragWidths = columnWidths }
                                let start = dragWidths?[index] ?? width(index)
                                columnWidths[index] = min(700, max(60, start + value.translation.width))
                            }
                            .onEnded { _ in dragWidths = nil })
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
        let isDeleted = deletedRowOffsets.contains(index)
        let isInserted = isInsertedOffset(index) != nil
        let isSelected = selectedRows.contains(index)

        return HStack(spacing: 0) {
            Text(isInserted ? "+" : String(index + 1))
                .font(.system(size: 10.5, weight: isInserted ? .bold : .regular, design: .monospaced))
                .foregroundStyle(isInserted ? Color.green : (isDeleted ? Color.red : Color.secondary.opacity(0.6)))
                .frame(width: 46, alignment: .leading)
                .padding(.leading, 10)

            ForEach(Array(resultSet.columns.enumerated()), id: \.offset) { colIndex, _ in
                cellView(rowOffset: index, colIndex: colIndex, originalRow: row, isDeleted: isDeleted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
        .background(rowBackground(index: index, isSelected: isSelected, isInserted: isInserted, isDeleted: isDeleted))
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                handleRowClick(index)
            }
        )
        .contextMenu {
            Button("Copiar linha") {
                if !selectedRows.contains(index) { selectedRows = [index] }
                copyRows(withHeaders: false)
            }
            Button("Copiar com cabeçalhos") {
                if !selectedRows.contains(index) { selectedRows = [index] }
                copyRows(withHeaders: true)
            }
            if canEditInline {
                Divider()
                Button("Adicionar linha") { addInlineRow() }
                Button(isDeleted ? "Restaurar linha" : "Remover linha", role: isDeleted ? nil : .destructive) {
                    if !selectedRows.contains(index) { selectedRows = [index] }
                    deleteSelectedRows()
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func cellView(rowOffset: Int, colIndex: Int, originalRow: [String?], isDeleted: Bool) -> some View {
        let value = effectiveValue(rowOffset: rowOffset, colIndex: colIndex, originalRow: originalRow)
        let isEditing = editingCell == CellCoord(rowOffset: rowOffset, colIndex: colIndex)
        let isModified = isCellModified(rowOffset: rowOffset, colIndex: colIndex)
        let colMeta = columnInfo(at: colIndex)

        if isEditing {
            InlineCellTextField(
                text: $editingText,
                placeholder: colMeta?.name ?? "NULL",
                onCommit: { commitActiveCellEdit() },
                onTab: { reverse in advanceEditingCell(reverse: reverse) },
                onCancel: { editingCell = nil }
            )
            .frame(width: width(colIndex), height: 22)
            .padding(.horizontal, 6)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(.horizontal, 2)
            )
        } else {
            HStack(spacing: 4) {
                Text(value ?? "NULL")
                    .font(.system(size: 11, design: .monospaced))
                    .italic(value == nil)
                    .strikethrough(isDeleted, color: .red)
                    .foregroundStyle(isDeleted ? Color.red.opacity(0.75) : (value == nil ? Color.secondary : Color.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if let ref = colMeta?.references, let value, !isDeleted, let onOpenForeignKey {
                    Button {
                        onOpenForeignKey(ref, value)
                    } label: {
                        Icon(.link, size: 10)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Abrir registro referenciado em \(ref)")
                }
            }
            .frame(width: width(colIndex), height: 24, alignment: .leading)
            .padding(.horizontal, 8)
            .background(isModified && !isDeleted ? Color.orange.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                startEditing(rowOffset: rowOffset, colIndex: colIndex)
            }
            .help(value ?? "NULL")
        }
    }

    private func rowBackground(index: Int, isSelected: Bool, isInserted: Bool, isDeleted: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.20)
        }
        if isDeleted {
            return Color.red.opacity(0.10)
        }
        if isInserted {
            return Color.green.opacity(0.10)
        }
        return index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.028)
    }
}

/// Campo NSTextField nativo para edição inline de célula com suporte a Tab, Shift+Tab, Return e Esc.
private struct InlineCellTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onTab: (Bool) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.placeholderString = placeholder
        tf.delegate = context.coordinator
        DispatchQueue.main.async {
            tf.window?.makeFirstResponder(tf)
            tf.currentEditor()?.selectAll(nil)
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineCellTextField
        private var didFinish = false

        init(_ parent: InlineCellTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !didFinish else { return }
            didFinish = true
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                didFinish = true
                parent.text = control.stringValue
                parent.onTab(false)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                didFinish = true
                parent.text = control.stringValue
                parent.onTab(true)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                didFinish = true
                parent.text = control.stringValue
                parent.onTab(false)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                didFinish = true
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

/// Sheet para revisar o SQL gerado pelas edições inline antes de aplicar a transação.
private struct ReviewSQLChangesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let statements: [String]
    let isCommitting: Bool
    let onConfirm: () -> Void

    private var fullSQL: String {
        (["BEGIN;"] + statements + ["COMMIT;"]).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Icon(.newQuery, size: 16, solid: true)
                    .foregroundStyle(Color.accentColor)
                Text("Revisar alterações SQL")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Icon(.close, size: 12)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                Text(fullSQL)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack {
                Button("Copiar SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullSQL, forType: .string)
                }
                .controlSize(.small)

                Spacer()

                Button("Cancelar") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)

                Button("Aplicar transação") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCommitting || statements.isEmpty)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 620, height: 380)
    }
}
