import AppKit
import SwiftUI
import HerdCore

// MARK: - Wizard States

struct TableWizardState: Identifiable {
    let id = UUID()
    var connectionID: UUID
    var connectionName: String
    var database: String
    var defaultSchema: String
    var defaultOwner: String
    var reloadNode: TreeNode?
}

struct SchemaWizardState: Identifiable {
    let id = UUID()
    var connectionID: UUID
    var connectionName: String
    var database: String
    var defaultOwner: String
    var reloadNode: TreeNode?
}

struct DatabaseWizardState: Identifiable {
    let id = UUID()
    var connectionID: UUID
    var connectionName: String
    var maintenanceDatabase: String
    var defaultOwner: String
}

struct TableStructureState: Identifiable {
    let id = UUID()
    var connectionID: UUID
    var connectionName: String
    var database: String
    var schema: String
    var table: String
}

struct DropWizardState: Identifiable {
    enum ObjectKind: String {
        case table = "TABLE"
        case view = "VIEW"
        case schema = "SCHEMA"
        case database = "DATABASE"

        var displayName: String {
            switch self {
            case .table: "Tabela"
            case .view: "View"
            case .schema: "Schema"
            case .database: "Banco de dados"
            }
        }

        var icon: IconSymbol {
            switch self {
            case .table: .table
            case .view: .view
            case .schema: .folder
            case .database: .database
            }
        }
    }

    let id = UUID()
    var connectionID: UUID
    var connectionName: String
    var database: String
    var schema: String?
    var objectName: String
    var kind: ObjectKind
    var force: Bool = false
    var reloadNode: TreeNode?
}

struct TableSubObjectWizardState: Identifiable {
    enum SubObjectKind {
        case column
        case index
        case rule
        case trigger
        case policy

        var title: String {
            switch self {
            case .column: "Coluna"
            case .index: "Índice"
            case .rule: "Regra"
            case .trigger: "Trigger"
            case .policy: "Política RLS"
            }
        }
    }

    let id = UUID()
    var connectionID: UUID
    var connectionName: String
    var database: String
    var schema: String?
    var table: String
    var kind: SubObjectKind
}

// MARK: - Create Table Wizard

struct CreateTableSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "Geral"
        case columns = "Colunas"
        case advanced = "Avançado"
        case constraints = "Constraints"
        case partitions = "Partições"
        case parameters = "Parâmetros"
        case security = "Segurança"
        case sql = "SQL"

        var id: String { rawValue }
    }

    enum ConstraintSubTab: String, CaseIterable, Identifiable {
        case primaryKey = "Chave primária"
        case foreignKey = "Chave estrangeira"
        case check = "Check"
        case unique = "Unique"
        case exclude = "Exclude"

        var id: String { rawValue }
    }

    struct ColumnDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""
        var dataType: String = "bigint"
        var length: String = ""
        var scale: String = ""
        var notNull: Bool = false
        var isPrimaryKey: Bool = false
        var defaultValue: String = ""

        static let availableTypes: [String] = [
            "bigint", "bigserial", "integer", "serial", "smallint", "smallserial",
            "text", "varchar", "char", "boolean", "uuid",
            "numeric", "real", "double precision", "money",
            "date", "timestamp", "timestamptz", "time", "timetz", "interval",
            "jsonb", "json", "bytea", "inet", "cidr", "macaddr", "xml",
            "int4[]", "int8[]", "text[]", "uuid[]"
        ]

        var acceptsLength: Bool {
            switch dataType {
            case "varchar", "char", "numeric", "timestamp", "timestamptz", "time", "timetz", "interval":
                true
            default:
                false
            }
        }

        var acceptsScale: Bool {
            dataType == "numeric"
        }

        var formattedType: String {
            let trimmedLen = length.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedScale = scale.trimmingCharacters(in: .whitespacesAndNewlines)
            guard acceptsLength, !trimmedLen.isEmpty else { return dataType }
            if acceptsScale, !trimmedScale.isEmpty {
                return "\(dataType)(\(trimmedLen), \(trimmedScale))"
            }
            return "\(dataType)(\(trimmedLen))"
        }
    }

    struct ForeignKeyDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""
        var localColumn: String = ""
        var referencedTable: String = ""
        var referencedColumn: String = "id"
        var onUpdate: String = "NO ACTION"
        var onDelete: String = "NO ACTION"

        static let actions = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]
    }

    struct CheckDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""
        var expression: String = ""
    }

    struct UniqueDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""
        var columns: String = ""
    }

    struct ExcludeDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""
        var method: String = "gist"
        var expression: String = ""
    }

    struct PartitionDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""
        var valuesClause: String = ""
    }

    struct ParameterDraft: Identifiable, Equatable {
        let id = UUID()
        var key: String = "fillfactor"
        var value: String = "100"

        static let commonKeys = [
            "fillfactor",
            "autovacuum_enabled",
            "toast_tuple_target",
            "parallel_workers",
            "autovacuum_vacuum_scale_factor",
            "autovacuum_analyze_scale_factor"
        ]
    }

    struct GrantDraft: Identifiable, Equatable {
        let id = UUID()
        var grantee: String = "PUBLIC"
        var privilege: String = "SELECT"
        var withGrantOption: Bool = false

        static let privileges = ["ALL", "SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER"]
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let wizard: TableWizardState
    let workspace: WorkspaceState

    @State private var activeTab: Tab = .general
    @State private var constraintTab: ConstraintSubTab = .primaryKey

    // General
    @State private var name: String = ""
    @State private var owner: String
    @State private var schema: String
    @State private var tablespace: String = ""
    @State private var isPartitioned: Bool = false
    @State private var comment: String = ""

    // Columns & Inheritance
    @State private var inheritedTables: [String] = []
    @State private var columns: [ColumnDraft] = [
        ColumnDraft(name: "id", dataType: "bigint", notNull: true, isPrimaryKey: true)
    ]

    // Advanced
    @State private var isUnlogged: Bool = false
    @State private var ifNotExists: Bool = false
    @State private var likeTable: String = ""
    @State private var likeDefaults: Bool = true
    @State private var likeConstraints: Bool = false
    @State private var likeIndexes: Bool = false
    @State private var enableRLS: Bool = false
    @State private var forceRLS: Bool = false

    // Constraints
    @State private var primaryKeyName: String = ""
    @State private var foreignKeys: [ForeignKeyDraft] = []
    @State private var checks: [CheckDraft] = []
    @State private var uniques: [UniqueDraft] = []
    @State private var excludes: [ExcludeDraft] = []

    // Partitions
    @State private var partitionStrategy: String = "RANGE"
    @State private var partitionKey: String = ""
    @State private var partitions: [PartitionDraft] = []

    // Parameters & Security
    @State private var parameters: [ParameterDraft] = []
    @State private var grants: [GrantDraft] = []

    // Catalog Metadata
    @State private var availableRoles: [String] = []
    @State private var availableSchemas: [String] = []
    @State private var availableTablespaces: [String] = []
    @State private var availableTables: [String] = []
    @State private var catalogColumns: [CatalogColumn] = []

    // Execution & UI State
    @State private var isSaving: Bool = false
    @State private var executionError: String?
    @State private var bannerDismissed: Bool = false
    @State private var sqlSelection = NSRange(location: 0, length: 0)
    @FocusState private var nameFocused: Bool

    init(wizard: TableWizardState, workspace: WorkspaceState) {
        self.wizard = wizard
        self.workspace = workspace
        _owner = State(initialValue: wizard.defaultOwner)
        _schema = State(initialValue: wizard.defaultSchema)
    }

    private var dialect: SQLDialect { .postgres }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        if let executionError { return executionError }
        if trimmedName.isEmpty { return "O campo 'Nome' não pode ficar vazio." }
        let validCols = columns.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if validCols.isEmpty && likeTable.isEmpty {
            return "Adicione pelo menos uma coluna na aba 'Colunas'."
        }
        if isPartitioned && partitionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Informe a chave de partição na aba 'Partições'."
        }
        return nil
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
            && (!columns.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.isEmpty || !likeTable.isEmpty)
            && (!isPartitioned || !partitionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Divider()

            Group {
                switch activeTab {
                case .general:
                    generalTab
                case .columns:
                    columnsTab
                case .advanced:
                    advancedTab
                case .constraints:
                    constraintsTab
                case .partitions:
                    partitionsTab
                case .parameters:
                    parametersTab
                case .security:
                    securityTab
                case .sql:
                    sqlTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let message = validationError, !bannerDismissed {
                WizardValidationBanner(message: message) {
                    if executionError != nil {
                        executionError = nil
                    } else {
                        bannerDismissed = true
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 780, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { nameFocused = true }
        .onChange(of: name) { _, _ in bannerDismissed = false; executionError = nil }
        .onChange(of: columns) { _, _ in bannerDismissed = false; executionError = nil }
        .onChange(of: isPartitioned) { _, newValue in
            bannerDismissed = false
            if newValue, partitionKey.isEmpty, let firstCol = columns.first?.name, !firstCol.isEmpty {
                partitionKey = firstCol
            }
        }
        .task { await loadServerMetadata() }
    }

    // MARK: - Header & Tabs

    private var header: some View {
        HStack(spacing: 10) {
            Icon(.table, size: 18, solid: true)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Criar · Tabela")
                    .font(.system(size: 14.5, weight: .semibold))
                Text("\(wizard.connectionName) · \(wizard.database)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Icon(.close, size: 12)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fechar (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    WizardTabButton(
                        title: tab.rawValue,
                        badge: badge(for: tab),
                        isSelected: activeTab == tab
                    ) {
                        activeTab = tab
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 34)
        .background(Color.primary.opacity(0.02))
    }

    private func badge(for tab: Tab) -> Int? {
        switch tab {
        case .columns:
            let count = columns.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            return count > 0 ? count : nil
        case .constraints:
            let pkCount = columns.contains(where: \.isPrimaryKey) ? 1 : 0
            let total = pkCount + foreignKeys.count + checks.count + uniques.count + excludes.count
            return total > 0 ? total : nil
        case .partitions:
            return partitions.isEmpty ? nil : partitions.count
        case .parameters:
            return parameters.isEmpty ? nil : parameters.count
        case .security:
            return grants.isEmpty ? nil : grants.count
        default:
            return nil
        }
    }

    // MARK: - General Tab (Image 3)

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WizardFormCard {
                    WizardFormRow(label: "Nome", isInvalid: trimmedName.isEmpty) {
                        HStack(spacing: 6) {
                            if trimmedName.isEmpty {
                                Icon(.alertCircle, size: 14, solid: true)
                                    .foregroundStyle(.red)
                            }
                            TextField("nova_tabela", text: $name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                                .focused($nameFocused)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(trimmedName.isEmpty ? Color.red.opacity(0.8) : Color.primary.opacity(0.15), lineWidth: 1)
                                )
                        }
                    }

                    Divider()

                    WizardFormRow(label: "Dono") {
                        Picker("Dono", selection: $owner) {
                            ForEach(roleOptions, id: \.self) { role in
                                Text(role).tag(role)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .trailing)
                    }

                    Divider()

                    WizardFormRow(label: "Schema") {
                        Picker("Schema", selection: $schema) {
                            ForEach(schemaOptions, id: \.self) { item in
                                Text(item).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .trailing)
                    }

                    Divider()

                    WizardFormRow(label: "Tablespace") {
                        Picker("Tablespace", selection: $tablespace) {
                            Text("Padrão (pg_default)").tag("")
                            ForEach(availableTablespaces, id: \.self) { ts in
                                Text(ts).tag(ts)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .trailing)
                    }

                    Divider()

                    WizardFormRow(label: "Tabela particionada?") {
                        HStack {
                            Spacer()
                            Toggle("", isOn: $isPartitioned)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    }
                }

                WizardFormCard(title: "Comentário") {
                    TextEditor(text: $comment)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(height: 84)
                        .padding(6)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Columns Tab (Image 2)

    private var columnsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            WizardFormCard {
                WizardFormRow(label: "Herdada da(s) tabela(s)") {
                    HStack(spacing: 6) {
                        if inheritedTables.isEmpty {
                            Text(isPartitioned ? "Indisponível para tabelas particionadas" : "Selecione para herdar…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(inheritedTables, id: \.self) { parent in
                                        HStack(spacing: 4) {
                                            Text(parent)
                                                .font(.system(size: 11, design: .monospaced))
                                            Button {
                                                inheritedTables.removeAll { $0 == parent }
                                            } label: {
                                                Icon(.close, size: 9)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    }
                                }
                            }
                        }

                        Spacer()

                        Menu {
                            if availableTables.isEmpty {
                                Text("Nenhuma tabela encontrada")
                            } else {
                                ForEach(availableTables, id: \.self) { tbl in
                                    Button {
                                        if inheritedTables.contains(tbl) {
                                            inheritedTables.removeAll { $0 == tbl }
                                        } else {
                                            inheritedTables.append(tbl)
                                        }
                                    } label: {
                                        HStack {
                                            Text(tbl)
                                            if inheritedTables.contains(tbl) {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Icon(.chevron, size: 11)
                                .rotationEffect(.degrees(90))
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .disabled(isPartitioned)
                    }
                }
            }

            // Columns Grid
            VStack(spacing: 0) {
                HStack {
                    Text("Colunas")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button {
                        columns.append(ColumnDraft(name: "coluna_\(columns.count + 1)", dataType: "text"))
                    } label: {
                        HStack(spacing: 4) {
                            Icon(.plus, size: 12)
                            Text("Adicionar")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Adicionar coluna")
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.primary.opacity(0.04))

                Divider()

                // Table Header
                HStack(spacing: 8) {
                    Color.clear.frame(width: 22)
                    Text("Nome").frame(width: 140, alignment: .leading)
                    Text("Tipo de dado").frame(width: 135, alignment: .leading)
                    Text("Tam./Precisão").frame(width: 86, alignment: .leading)
                    Text("Escala").frame(width: 56, alignment: .leading)
                    Text("Não nulo?").frame(width: 68, alignment: .center)
                    Text("Chave prim.?").frame(width: 78, alignment: .center)
                    Text("Padrão").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

                Divider()

                if columns.isEmpty {
                    VStack(spacing: 6) {
                        Spacer()
                        Icon(.table, size: 22).foregroundStyle(.tertiary)
                        Text("Nenhuma coluna adicionada")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Button("Adicionar primeira coluna") {
                            columns.append(ColumnDraft(name: "id", dataType: "bigint", notNull: true, isPrimaryKey: true))
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach($columns) { $col in
                                columnRow(col: $col)
                                Divider()
                            }
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
        }
        .padding(20)
    }

    private func columnRow(col: Binding<ColumnDraft>) -> some View {
        let current = col.wrappedValue
        return HStack(spacing: 8) {
            Button {
                columns.removeAll { $0.id == current.id }
            } label: {
                Icon(.close, size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remover coluna")

            TextField("nome_coluna", text: col.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .frame(width: 140)

            Picker("", selection: col.dataType) {
                ForEach(ColumnDraft.availableTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 135)

            TextField(current.acceptsLength ? "ex: 255" : "—", text: col.length)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(current.acceptsLength ? 0.04 : 0.015), in: RoundedRectangle(cornerRadius: 5))
                .disabled(!current.acceptsLength)
                .frame(width: 86)

            TextField(current.acceptsScale ? "ex: 2" : "—", text: col.scale)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(current.acceptsScale ? 0.04 : 0.015), in: RoundedRectangle(cornerRadius: 5))
                .disabled(!current.acceptsScale)
                .frame(width: 56)

            Toggle("", isOn: col.notNull)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 68)

            Toggle("", isOn: Binding(
                get: { col.wrappedValue.isPrimaryKey },
                set: { newValue in
                    col.wrappedValue.isPrimaryKey = newValue
                    if newValue { col.wrappedValue.notNull = true }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(width: 78)

            TextField("NULL / expressão", text: col.defaultValue)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WizardFormCard(title: "Opções de criação") {
                    WizardFormRow(label: "Criar se não existir (IF NOT EXISTS)") {
                        HStack {
                            Spacer()
                            Toggle("", isOn: $ifNotExists)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    }

                    Divider()

                    WizardFormRow(label: "Tabela sem log (UNLOGGED)") {
                        HStack {
                            Spacer()
                            Toggle("", isOn: $isUnlogged)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    }
                }

                WizardFormCard(title: "Copiar estrutura (LIKE)") {
                    WizardFormRow(label: "Tabela base") {
                        Picker("Tabela base", selection: $likeTable) {
                            Text("Nenhuma").tag("")
                            ForEach(availableTables, id: \.self) { tbl in
                                Text(tbl).tag(tbl)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .trailing)
                    }

                    if !likeTable.isEmpty {
                        Divider()
                        WizardFormRow(label: "Incluir valores padrão (INCLUDING DEFAULTS)") {
                            HStack {
                                Spacer()
                                Toggle("", isOn: $likeDefaults).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            }
                        }
                        Divider()
                        WizardFormRow(label: "Incluir constraints (INCLUDING CONSTRAINTS)") {
                            HStack {
                                Spacer()
                                Toggle("", isOn: $likeConstraints).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            }
                        }
                        Divider()
                        WizardFormRow(label: "Incluir índices (INCLUDING INDEXES)") {
                            HStack {
                                Spacer()
                                Toggle("", isOn: $likeIndexes).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            }
                        }
                    }
                }

                WizardFormCard(title: "Row Level Security (RLS)") {
                    WizardFormRow(label: "Habilitar Row Level Security") {
                        HStack {
                            Spacer()
                            Toggle("", isOn: $enableRLS)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    }

                    if enableRLS {
                        Divider()
                        WizardFormRow(label: "Forçar RLS para o dono da tabela") {
                            HStack {
                                Spacer()
                                Toggle("", isOn: $forceRLS)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Constraints Tab (Images 4 & 5)

    private var constraintsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(ConstraintSubTab.allCases) { sub in
                    WizardTabButton(
                        title: sub.rawValue,
                        badge: constraintSubBadge(sub),
                        isSelected: constraintTab == sub
                    ) {
                        constraintTab = sub
                    }
                }
                Spacer()
            }

            Group {
                switch constraintTab {
                case .primaryKey:
                    primaryKeyView
                case .foreignKey:
                    foreignKeyView
                case .check:
                    checkConstraintsView
                case .unique:
                    uniqueConstraintsView
                case .exclude:
                    excludeConstraintsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
    }

    private func constraintSubBadge(_ sub: ConstraintSubTab) -> Int? {
        switch sub {
        case .primaryKey:
            let count = columns.filter(\.isPrimaryKey).count
            return count > 0 ? count : nil
        case .foreignKey:
            return foreignKeys.isEmpty ? nil : foreignKeys.count
        case .check:
            return checks.isEmpty ? nil : checks.count
        case .unique:
            return uniques.isEmpty ? nil : uniques.count
        case .exclude:
            return excludes.isEmpty ? nil : excludes.count
        }
    }

    private var primaryKeyView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chave primária")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Menu {
                    let nonPK = columns.filter { !$0.isPrimaryKey && !$0.name.isEmpty }
                    if nonPK.isEmpty {
                        Text("Todas as colunas já fazem parte da PK")
                    } else {
                        ForEach(nonPK) { col in
                            Button("Adicionar '\(col.name)' à chave primária") {
                                if let idx = columns.firstIndex(where: { $0.id == col.id }) {
                                    columns[idx].isPrimaryKey = true
                                    columns[idx].notNull = true
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Adicionar coluna")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 12) {
                Text("Nome").frame(width: 200, alignment: .leading)
                Text("Colunas").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            HStack(spacing: 12) {
                TextField(trimmedName.isEmpty ? "opcional (ex: tabela_pkey)" : "\(trimmedName)_pkey", text: $primaryKeyName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                    .frame(width: 200)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        let pkCols = columns.filter { $0.isPrimaryKey && !$0.name.isEmpty }
                        if pkCols.isEmpty {
                            Text("Nenhuma coluna marcada como chave primária")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(pkCols) { col in
                                HStack(spacing: 4) {
                                    Icon(.key, size: 11)
                                        .foregroundStyle(.orange)
                                    Text(col.name)
                                        .font(.system(size: 11.5, design: .monospaced))
                                    Button {
                                        if let idx = columns.firstIndex(where: { $0.id == col.id }) {
                                            columns[idx].isPrimaryKey = false
                                        }
                                    } label: {
                                        Icon(.close, size: 9)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()
            Spacer()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    private var foreignKeyView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chaves estrangeiras")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    let defaultLocal = columns.first?.name ?? ""
                    let defaultRef = availableTables.first ?? ""
                    foreignKeys.append(ForeignKeyDraft(localColumn: defaultLocal, referencedTable: defaultRef))
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Adicionar")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 8) {
                Color.clear.frame(width: 22)
                Text("Nome").frame(width: 125, alignment: .leading)
                Text("Coluna local").frame(width: 125, alignment: .leading)
                Text("Tabela referenciada").frame(width: 165, alignment: .leading)
                Text("Coluna ref.").frame(width: 110, alignment: .leading)
                Text("ON DELETE").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            if foreignKeys.isEmpty {
                emptyConstraintPlaceholder("Nenhuma chave estrangeira definida.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($foreignKeys) { $fk in
                            let current = fk
                            HStack(spacing: 8) {
                                Button {
                                    foreignKeys.removeAll { $0.id == current.id }
                                } label: {
                                    Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                TextField("opcional", text: $fk.name)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(width: 125)

                                Picker("", selection: $fk.localColumn) {
                                    Text("Selecione…").tag("")
                                    ForEach(columns.map(\.name).filter { !$0.isEmpty }, id: \.self) { colName in
                                        Text(colName).tag(colName)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .controlSize(.small)
                                .frame(width: 125)

                                Picker("", selection: $fk.referencedTable) {
                                    Text("Selecione…").tag("")
                                    ForEach(availableTables, id: \.self) { tbl in
                                        Text(tbl).tag(tbl)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .controlSize(.small)
                                .frame(width: 165)

                                TextField("id", text: $fk.referencedColumn)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(width: 110)

                                Picker("", selection: $fk.onDelete) {
                                    ForEach(ForeignKeyDraft.actions, id: \.self) { act in
                                        Text(act).tag(act)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    private var checkConstraintsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Restrições CHECK")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    checks.append(CheckDraft())
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Adicionar").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 8) {
                Color.clear.frame(width: 22)
                Text("Nome").frame(width: 180, alignment: .leading)
                Text("Expressão booleana").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            if checks.isEmpty {
                emptyConstraintPlaceholder("Nenhuma restrição CHECK adicionada.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($checks) { $chk in
                            let current = chk
                            HStack(spacing: 8) {
                                Button { checks.removeAll { $0.id == current.id } } label: {
                                    Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                TextField("opcional", text: $chk.name)
                                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(width: 180)

                                TextField("ex: quantidade >= 0", text: $chk.expression)
                                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 10).frame(height: 36)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    private var uniqueConstraintsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Restrições UNIQUE")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    uniques.append(UniqueDraft(columns: columns.first?.name ?? ""))
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Adicionar").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 8) {
                Color.clear.frame(width: 22)
                Text("Nome").frame(width: 180, alignment: .leading)
                Text("Colunas (separadas por vírgula)").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            if uniques.isEmpty {
                emptyConstraintPlaceholder("Nenhuma restrição UNIQUE adicionada.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($uniques) { $u in
                            let current = u
                            HStack(spacing: 8) {
                                Button { uniques.removeAll { $0.id == current.id } } label: {
                                    Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                TextField("opcional", text: $u.name)
                                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(width: 180)

                                TextField("ex: email, tenant_id", text: $u.columns)
                                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 10).frame(height: 36)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    private var excludeConstraintsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Restrições EXCLUDE")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    excludes.append(ExcludeDraft())
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Adicionar").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 8) {
                Color.clear.frame(width: 22)
                Text("Nome").frame(width: 160, alignment: .leading)
                Text("Método").frame(width: 100, alignment: .leading)
                Text("Elemento WITH Operador").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            if excludes.isEmpty {
                emptyConstraintPlaceholder("Nenhuma restrição EXCLUDE adicionada.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($excludes) { $ex in
                            let current = ex
                            HStack(spacing: 8) {
                                Button { excludes.removeAll { $0.id == current.id } } label: {
                                    Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                TextField("opcional", text: $ex.name)
                                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(width: 160)

                                Picker("", selection: $ex.method) {
                                    Text("gist").tag("gist")
                                    Text("btree").tag("btree")
                                    Text("spgist").tag("spgist")
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .frame(width: 100)

                                TextField("ex: periodo WITH &&", text: $ex.expression)
                                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 10).frame(height: 36)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    private func emptyConstraintPlaceholder(_ text: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Icon(.key, size: 20).foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Partitions Tab

    private var partitionsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            WizardFormCard {
                WizardFormRow(label: "Tabela particionada?") {
                    HStack {
                        Spacer()
                        Toggle("", isOn: $isPartitioned)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }

                if isPartitioned {
                    Divider()
                    WizardFormRow(label: "Estratégia (PARTITION BY)") {
                        Picker("Estratégia", selection: $partitionStrategy) {
                            Text("RANGE").tag("RANGE")
                            Text("LIST").tag("LIST")
                            Text("HASH").tag("HASH")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    Divider()
                    WizardFormRow(label: "Coluna / Expressão chave") {
                        HStack(spacing: 6) {
                            TextField("ex: created_at", text: $partitionKey)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                                .frame(width: 200)

                            Menu {
                                ForEach(columns.map(\.name).filter { !$0.isEmpty }, id: \.self) { colName in
                                    Button(colName) { partitionKey = colName }
                                }
                            } label: {
                                Icon(.chevron, size: 11).rotationEffect(.degrees(90))
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 22)
                        }
                    }
                }
            }

            if isPartitioned {
                VStack(spacing: 0) {
                    HStack {
                        Text("Partições filhas")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button {
                            let base = trimmedName.isEmpty ? "tabela" : trimmedName
                            partitions.append(PartitionDraft(
                                name: "\(base)_p\(partitions.count + 1)",
                                valuesClause: partitionStrategy == "RANGE"
                                    ? "FROM ('2026-01-01') TO ('2027-01-01')"
                                    : (partitionStrategy == "LIST" ? "IN ('valor')" : "WITH (MODULUS 4, REMAINDER \(partitions.count))")
                            ))
                        } label: {
                            HStack(spacing: 4) {
                                Icon(.plus, size: 12)
                                Text("Adicionar partição").font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.04))

                    Divider()

                    HStack(spacing: 8) {
                        Color.clear.frame(width: 22)
                        Text("Nome da partição").frame(width: 190, alignment: .leading)
                        Text("Expressão FOR VALUES").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

                    Divider()

                    if partitions.isEmpty {
                        emptyConstraintPlaceholder("Nenhuma partição filha adicionada.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach($partitions) { $part in
                                    let current = part
                                    HStack(spacing: 8) {
                                        Button { partitions.removeAll { $0.id == current.id } } label: {
                                            Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                        }
                                        .buttonStyle(.plain)

                                        TextField("nome_particao", text: $part.name)
                                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                            .frame(width: 190)

                                        TextField("FOR VALUES ...", text: $part.valuesClause)
                                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                            .frame(maxWidth: .infinity)
                                    }
                                    .padding(.horizontal, 10).frame(height: 36)
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
            } else {
                Spacer()
            }
        }
        .padding(20)
    }

    // MARK: - Parameters Tab

    private var parametersTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Parâmetros de armazenamento (WITH)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    parameters.append(ParameterDraft())
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Adicionar").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 8) {
                Color.clear.frame(width: 22)
                Text("Parâmetro").frame(width: 240, alignment: .leading)
                Text("Valor").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            if parameters.isEmpty {
                emptyConstraintPlaceholder("Nenhum parâmetro customizado.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($parameters) { $param in
                            let current = param
                            HStack(spacing: 8) {
                                Button { parameters.removeAll { $0.id == current.id } } label: {
                                    Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                Picker("", selection: $param.key) {
                                    ForEach(ParameterDraft.commonKeys, id: \.self) { k in
                                        Text(k).tag(k)
                                    }
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .frame(width: 240)

                                TextField("valor", text: $param.value)
                                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 10).frame(height: 36)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
        .padding(20)
    }

    // MARK: - Security Tab

    private var securityTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privilégios (GRANT)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    grants.append(GrantDraft(grantee: roleOptions.first ?? "PUBLIC"))
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Adicionar").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 8) {
                Color.clear.frame(width: 22)
                Text("Role / Usuário (Grantee)").frame(width: 200, alignment: .leading)
                Text("Privilégio").frame(width: 180, alignment: .leading)
                Text("WITH GRANT OPTION").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            if grants.isEmpty {
                emptyConstraintPlaceholder("Nenhum privilégio adicional configurado.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($grants) { $grant in
                            let current = grant
                            HStack(spacing: 8) {
                                Button { grants.removeAll { $0.id == current.id } } label: {
                                    Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                Picker("", selection: $grant.grantee) {
                                    Text("PUBLIC").tag("PUBLIC")
                                    ForEach(roleOptions, id: \.self) { r in
                                        Text(r).tag(r)
                                    }
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .frame(width: 200)

                                Picker("", selection: $grant.privilege) {
                                    ForEach(GrantDraft.privileges, id: \.self) { p in
                                        Text(p).tag(p)
                                    }
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .frame(width: 180)

                                Toggle("", isOn: $grant.withGrantOption)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                Spacer()
                            }
                            .padding(.horizontal, 10).frame(height: 36)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
        .padding(20)
    }

    // MARK: - SQL Preview Tab (Image 6)

    private var sqlTab: some View {
        let preview = isValid ? generatedSQL : "-- Definição incompleta.\n-- Informe o nome da tabela na aba 'Geral'."
        return SQLEditorView(
            text: .constant(preview),
            selection: $sqlSelection
        )
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                openInEditor()
            } label: {
                HStack(spacing: 5) {
                    Icon(.newQuery, size: 13)
                    Text("Abrir no editor")
                }
            }
            .controlSize(.regular)
            .disabled(!isValid || isSaving)
            .help("Abrir o SQL gerado em uma nova aba de script")

            Spacer()

            Button("Fechar") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button {
                resetForm()
            } label: {
                HStack(spacing: 4) {
                    Icon(.refresh, size: 12)
                    Text("Limpar")
                }
            }
            .disabled(isSaving)

            Button {
                saveTable()
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    }
                    Text("Salvar")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isValid || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - SQL Generation

    private var generatedSQL: String {
        guard !trimmedName.isEmpty else { return "" }
        let qualifiedTable = dialect.qualify(schema: schema.isEmpty ? nil : schema, table: trimmedName)

        var bodyLines: [String] = []

        if !likeTable.isEmpty {
            var clauses = ["LIKE \(likeTable)"]
            if likeDefaults { clauses.append("INCLUDING DEFAULTS") }
            if likeConstraints { clauses.append("INCLUDING CONSTRAINTS") }
            if likeIndexes { clauses.append("INCLUDING INDEXES") }
            bodyLines.append("    " + clauses.joined(separator: " "))
        }

        let validColumns = columns.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let pkColumns = validColumns.filter(\.isPrimaryKey)
        let inlineSinglePK = pkColumns.count == 1 && primaryKeyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        for col in validColumns {
            let colName = dialect.quote(col.name.trimmingCharacters(in: .whitespacesAndNewlines))
            var parts = ["\(colName) \(col.formattedType)"]
            if col.notNull || col.isPrimaryKey {
                parts.append("NOT NULL")
            }
            let def = col.defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !def.isEmpty {
                parts.append("DEFAULT \(def)")
            }
            if inlineSinglePK && col.isPrimaryKey {
                parts.append("PRIMARY KEY")
            }
            bodyLines.append("    " + parts.joined(separator: " "))
        }

        if !pkColumns.isEmpty && !inlineSinglePK {
            let pkList = pkColumns.map { dialect.quote($0.name.trimmingCharacters(in: .whitespacesAndNewlines)) }.joined(separator: ", ")
            let pkTrimmedName = primaryKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
            if pkTrimmedName.isEmpty {
                bodyLines.append("    PRIMARY KEY (\(pkList))")
            } else {
                bodyLines.append("    CONSTRAINT \(dialect.quote(pkTrimmedName)) PRIMARY KEY (\(pkList))")
            }
        }

        for fk in foreignKeys {
            let local = fk.localColumn.trimmingCharacters(in: .whitespacesAndNewlines)
            let refTbl = fk.referencedTable.trimmingCharacters(in: .whitespacesAndNewlines)
            let refCol = fk.referencedColumn.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !local.isEmpty, !refTbl.isEmpty, !refCol.isEmpty else { continue }
            var prefix = "    "
            let fkName = fk.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fkName.isEmpty {
                prefix += "CONSTRAINT \(dialect.quote(fkName)) "
            }
            var clause = "\(prefix)FOREIGN KEY (\(dialect.quote(local))) REFERENCES \(refTbl) (\(dialect.quote(refCol)))"
            if fk.onUpdate != "NO ACTION" { clause += " ON UPDATE \(fk.onUpdate)" }
            if fk.onDelete != "NO ACTION" { clause += " ON DELETE \(fk.onDelete)" }
            bodyLines.append(clause)
        }

        for u in uniques {
            let cols = u.columns.split(separator: ",").map { dialect.quote($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { $0 != "\"\"" }
            guard !cols.isEmpty else { continue }
            let uName = u.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = uName.isEmpty ? "    " : "    CONSTRAINT \(dialect.quote(uName)) "
            bodyLines.append("\(prefix)UNIQUE (\(cols.joined(separator: ", ")))")
        }

        for chk in checks {
            let expr = chk.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else { continue }
            let cName = chk.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = cName.isEmpty ? "    " : "    CONSTRAINT \(dialect.quote(cName)) "
            bodyLines.append("\(prefix)CHECK (\(expr))")
        }

        for ex in excludes {
            let expr = ex.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else { continue }
            let eName = ex.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = eName.isEmpty ? "    " : "    CONSTRAINT \(dialect.quote(eName)) "
            bodyLines.append("\(prefix)EXCLUDE USING \(ex.method) (\(expr))")
        }

        var createHeader = "CREATE"
        if isUnlogged { createHeader += " UNLOGGED" }
        createHeader += " TABLE"
        if ifNotExists { createHeader += " IF NOT EXISTS" }
        createHeader += " \(qualifiedTable)"

        var statement = "\(createHeader) (\n\(bodyLines.joined(separator: ",\n"))\n)"

        if !isPartitioned && !inheritedTables.isEmpty {
            statement += "\nINHERITS (\(inheritedTables.joined(separator: ", ")))"
        }

        if isPartitioned {
            let key = partitionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                statement += "\nPARTITION BY \(partitionStrategy) (\(key))"
            }
        }

        let validParams = parameters.filter {
            !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !validParams.isEmpty {
            let pairs = validParams.map { "\($0.key) = \($0.value)" }.joined(separator: ", ")
            statement += "\nWITH (\(pairs))"
        }

        if !tablespace.isEmpty {
            statement += "\nTABLESPACE \(dialect.quote(tablespace))"
        }

        statement += ";"

        var statements: [String] = [statement]

        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOwner.isEmpty {
            statements.append("ALTER TABLE IF EXISTS \(qualifiedTable)\n    OWNER to \(dialect.quote(trimmedOwner));")
        }

        if enableRLS {
            statements.append("ALTER TABLE \(qualifiedTable) ENABLE ROW LEVEL SECURITY;")
            if forceRLS {
                statements.append("ALTER TABLE \(qualifiedTable) FORCE ROW LEVEL SECURITY;")
            }
        }

        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedComment.isEmpty {
            let escaped = trimmedComment.replacingOccurrences(of: "'", with: "''")
            statements.append("COMMENT ON TABLE \(qualifiedTable)\n    IS '\(escaped)';")
        }

        if isPartitioned {
            for part in partitions {
                let pName = part.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let pVals = part.valuesClause.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pName.isEmpty, !pVals.isEmpty else { continue }
                let qualifiedPart = dialect.qualify(schema: schema.isEmpty ? nil : schema, table: pName)
                statements.append("CREATE TABLE \(qualifiedPart)\n    PARTITION OF \(qualifiedTable)\n    FOR VALUES \(pVals);")
            }
        }

        for grant in grants {
            let grantee = grant.grantee == "PUBLIC" ? "PUBLIC" : dialect.quote(grant.grantee)
            var grantSQL = "GRANT \(grant.privilege) ON TABLE \(qualifiedTable) TO \(grantee)"
            if grant.withGrantOption { grantSQL += " WITH GRANT OPTION" }
            grantSQL += ";"
            statements.append(grantSQL)
        }

        return statements.joined(separator: "\n\n")
    }

    // MARK: - Actions & Metadata

    private var roleOptions: [String] {
        var list = availableRoles
        if !owner.isEmpty && !list.contains(owner) {
            list.insert(owner, at: 0)
        }
        return list.isEmpty ? ["postgres"] : list
    }

    private var schemaOptions: [String] {
        var list = availableSchemas
        if !schema.isEmpty && !list.contains(schema) {
            list.insert(schema, at: 0)
        }
        return list.isEmpty ? ["public"] : list
    }

    private func resetForm() {
        name = ""
        owner = wizard.defaultOwner
        schema = wizard.defaultSchema
        tablespace = ""
        isPartitioned = false
        comment = ""
        inheritedTables = []
        columns = [ColumnDraft(name: "id", dataType: "bigint", notNull: true, isPrimaryKey: true)]
        isUnlogged = false
        ifNotExists = false
        likeTable = ""
        enableRLS = false
        forceRLS = false
        primaryKeyName = ""
        foreignKeys = []
        checks = []
        uniques = []
        excludes = []
        partitions = []
        parameters = []
        grants = []
        executionError = nil
        bannerDismissed = false
    }

    private func openInEditor() {
        let context = QueryContext(
            connectionID: wizard.connectionID,
            connectionName: wizard.connectionName,
            database: wizard.database,
            schema: schema.isEmpty ? nil : schema
        )
        workspace.newQueryTab(context: context, sql: generatedSQL, title: "Criar · \(trimmedName)")
        dismiss()
    }

    private func saveTable() {
        guard isValid, !isSaving else { return }
        guard let config = app.connections.connection(id: wizard.connectionID) else { return }
        let sql = generatedSQL
        guard SafeModeGate.authorize(sql: sql, config: config, connections: app.connections,
                                     action: "criar a tabela") else { return }
        isSaving = true
        executionError = nil
        bannerDismissed = false
        let driver = app.drivers.driver(for: config)

        Task {
            do {
                let result = try await driver.run(sql, database: wizard.database)
                app.history.record(
                    connectionID: wizard.connectionID,
                    database: wizard.database,
                    sql: sql,
                    duration: result.elapsed,
                    rowCount: result.rows.count
                )
                app.catalog.invalidate(connectionID: wizard.connectionID)
                workspace.reloadAfterDDL(connectionID: wizard.connectionID, database: wizard.database, schema: schema)
                isSaving = false
                dismiss()
            } catch {
                executionError = error.localizedDescription
                bannerDismissed = false
                isSaving = false
            }
        }
    }

    private func loadServerMetadata() async {
        guard let config = app.connections.connection(id: wizard.connectionID) else { return }
        let driver = app.drivers.driver(for: config)

        if let schemas = try? await driver.listSchemas(database: wizard.database) {
            availableSchemas = schemas.map(\.name)
        }

        if let rolesResult = try? await driver.run("SELECT rolname FROM pg_roles ORDER BY rolname;", database: wizard.database) {
            availableRoles = rolesResult.rows.compactMap { $0.first ?? nil }
        }

        if let tsResult = try? await driver.run("SELECT spcname FROM pg_tablespace ORDER BY spcname;", database: wizard.database) {
            availableTablespaces = tsResult.rows.compactMap { $0.first ?? nil }
        }

        if let catalog = await app.catalog.catalog(connectionID: wizard.connectionID, database: wizard.database, driver: driver) {
            availableTables = catalog.tables
                .filter { $0.kind == .table }
                .map { dialect.qualify(schema: $0.schema, table: $0.name) }
            catalogColumns = catalog.columns
        }
    }
}

// MARK: - Create Schema Wizard (Images 7 & 8)

struct CreateSchemaSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "Geral"
        case security = "Segurança"
        case defaultPrivileges = "Privilégios padrão"
        case sql = "SQL"

        var id: String { rawValue }
    }

    struct SchemaGrantDraft: Identifiable, Equatable {
        let id = UUID()
        var grantee: String = "PUBLIC"
        var privilege: String = "USAGE"
        var withGrantOption: Bool = false

        static let privileges = ["ALL", "USAGE", "CREATE"]
    }

    struct DefaultPrivilegeDraft: Identifiable, Equatable {
        let id = UUID()
        var objectType: String = "TABLES"
        var grantee: String = "PUBLIC"
        var privilege: String = "SELECT"
        var withGrantOption: Bool = false

        static let objectTypes = ["TABLES", "SEQUENCES", "FUNCTIONS", "TYPES"]
        static let privileges = ["ALL", "SELECT", "INSERT", "UPDATE", "DELETE", "USAGE", "EXECUTE"]
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let wizard: SchemaWizardState
    let workspace: WorkspaceState

    @State private var activeTab: Tab = .general
    @State private var name: String = ""
    @State private var owner: String
    @State private var ifNotExists: Bool = false
    @State private var comment: String = ""
    @State private var grants: [SchemaGrantDraft] = []
    @State private var defaultPrivileges: [DefaultPrivilegeDraft] = []

    @State private var availableRoles: [String] = []
    @State private var isSaving: Bool = false
    @State private var executionError: String?
    @State private var bannerDismissed: Bool = false
    @State private var sqlSelection = NSRange(location: 0, length: 0)
    @FocusState private var nameFocused: Bool

    init(wizard: SchemaWizardState, workspace: WorkspaceState) {
        self.wizard = wizard
        self.workspace = workspace
        _owner = State(initialValue: wizard.defaultOwner)
    }

    private var dialect: SQLDialect { .postgres }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
    }

    private var validationError: String? {
        if let executionError { return executionError }
        if trimmedName.isEmpty { return "O campo 'Nome' não pode ficar vazio." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Divider()

            Group {
                switch activeTab {
                case .general:
                    generalTab
                case .security:
                    securityTab
                case .defaultPrivileges:
                    defaultPrivilegesTab
                case .sql:
                    sqlTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let message = validationError, !bannerDismissed {
                WizardValidationBanner(message: message) {
                    if executionError != nil {
                        executionError = nil
                    } else {
                        bannerDismissed = true
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 640, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { nameFocused = true }
        .onChange(of: name) { _, _ in bannerDismissed = false; executionError = nil }
        .task { await loadRoles() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Icon(.folder, size: 18, solid: true)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Criar · Schema")
                    .font(.system(size: 14.5, weight: .semibold))
                Text("\(wizard.connectionName) · \(wizard.database)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Icon(.close, size: 12)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fechar (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { tab in
                WizardTabButton(
                    title: tab.rawValue,
                    badge: badge(for: tab),
                    isSelected: activeTab == tab
                ) {
                    activeTab = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Color.primary.opacity(0.02))
    }

    private func badge(for tab: Tab) -> Int? {
        switch tab {
        case .security:
            return grants.isEmpty ? nil : grants.count
        case .defaultPrivileges:
            return defaultPrivileges.isEmpty ? nil : defaultPrivileges.count
        default:
            return nil
        }
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WizardFormCard {
                    WizardFormRow(label: "Nome", isInvalid: trimmedName.isEmpty) {
                        HStack(spacing: 6) {
                            if trimmedName.isEmpty {
                                Icon(.alertCircle, size: 14, solid: true)
                                    .foregroundStyle(.red)
                            }
                            TextField("novo_schema", text: $name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                                .focused($nameFocused)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(trimmedName.isEmpty ? Color.red.opacity(0.8) : Color.primary.opacity(0.15), lineWidth: 1)
                                )
                        }
                    }

                    Divider()

                    WizardFormRow(label: "Dono") {
                        Picker("Dono", selection: $owner) {
                            ForEach(roleOptions, id: \.self) { role in
                                Text(role).tag(role)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .trailing)
                    }

                    Divider()

                    WizardFormRow(label: "Criar se não existir (IF NOT EXISTS)") {
                        HStack {
                            Spacer()
                            Toggle("", isOn: $ifNotExists)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    }
                }

                WizardFormCard(title: "Comentário") {
                    TextEditor(text: $comment)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(height: 84)
                        .padding(6)
                }
            }
            .padding(20)
        }
    }

    private var securityTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privilégios no schema (GRANT)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    grants.append(SchemaGrantDraft(grantee: roleOptions.first ?? "PUBLIC"))
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Adicionar").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 8) {
                Color.clear.frame(width: 22)
                Text("Role / Usuário").frame(width: 190, alignment: .leading)
                Text("Privilégio").frame(width: 150, alignment: .leading)
                Text("WITH GRANT OPTION").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            if grants.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Icon(.key, size: 20).foregroundStyle(.tertiary)
                    Text("Nenhum privilégio adicional configurado.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($grants) { $grant in
                            let current = grant
                            HStack(spacing: 8) {
                                Button { grants.removeAll { $0.id == current.id } } label: {
                                    Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                Picker("", selection: $grant.grantee) {
                                    Text("PUBLIC").tag("PUBLIC")
                                    ForEach(roleOptions, id: \.self) { r in Text(r).tag(r) }
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .frame(width: 190)

                                Picker("", selection: $grant.privilege) {
                                    ForEach(SchemaGrantDraft.privileges, id: \.self) { p in Text(p).tag(p) }
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .frame(width: 150)

                                Toggle("", isOn: $grant.withGrantOption)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                Spacer()
                            }
                            .padding(.horizontal, 10).frame(height: 36)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
        .padding(20)
    }

    private var defaultPrivilegesTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privilégios padrão (ALTER DEFAULT PRIVILEGES)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    defaultPrivileges.append(DefaultPrivilegeDraft(grantee: roleOptions.first ?? "PUBLIC"))
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Adicionar").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 8) {
                Color.clear.frame(width: 22)
                Text("Objeto").frame(width: 130, alignment: .leading)
                Text("Role").frame(width: 160, alignment: .leading)
                Text("Privilégio").frame(width: 130, alignment: .leading)
                Text("GRANT OPTION").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            if defaultPrivileges.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Icon(.key, size: 20).foregroundStyle(.tertiary)
                    Text("Nenhum privilégio padrão configurado.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($defaultPrivileges) { $priv in
                            let current = priv
                            HStack(spacing: 8) {
                                Button { defaultPrivileges.removeAll { $0.id == current.id } } label: {
                                    Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                Picker("", selection: $priv.objectType) {
                                    ForEach(DefaultPrivilegeDraft.objectTypes, id: \.self) { t in Text(t).tag(t) }
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .frame(width: 130)

                                Picker("", selection: $priv.grantee) {
                                    Text("PUBLIC").tag("PUBLIC")
                                    ForEach(roleOptions, id: \.self) { r in Text(r).tag(r) }
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .frame(width: 160)

                                Picker("", selection: $priv.privilege) {
                                    ForEach(DefaultPrivilegeDraft.privileges, id: \.self) { p in Text(p).tag(p) }
                                }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .frame(width: 130)

                                Toggle("", isOn: $priv.withGrantOption)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                Spacer()
                            }
                            .padding(.horizontal, 10).frame(height: 36)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
        .padding(20)
    }

    private var sqlTab: some View {
        let preview = isValid ? generatedSQL : "-- Nenhuma alteração.\n-- Informe o nome do schema na aba 'Geral'."
        return SQLEditorView(
            text: .constant(preview),
            selection: $sqlSelection
        )
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                let context = QueryContext(
                    connectionID: wizard.connectionID,
                    connectionName: wizard.connectionName,
                    database: wizard.database,
                    schema: trimmedName
                )
                workspace.newQueryTab(context: context, sql: generatedSQL, title: "Criar · \(trimmedName)")
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Icon(.newQuery, size: 13)
                    Text("Abrir no editor")
                }
            }
            .disabled(!isValid || isSaving)

            Spacer()

            Button("Fechar") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button {
                name = ""
                owner = wizard.defaultOwner
                ifNotExists = false
                comment = ""
                grants = []
                defaultPrivileges = []
                executionError = nil
                bannerDismissed = false
            } label: {
                HStack(spacing: 4) {
                    Icon(.refresh, size: 12)
                    Text("Limpar")
                }
            }
            .disabled(isSaving)

            Button {
                saveSchema()
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    }
                    Text("Salvar")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isValid || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var roleOptions: [String] {
        var list = availableRoles
        if !owner.isEmpty && !list.contains(owner) {
            list.insert(owner, at: 0)
        }
        return list.isEmpty ? ["postgres"] : list
    }

    private var generatedSQL: String {
        guard !trimmedName.isEmpty else { return "" }
        let quotedSchema = dialect.quote(trimmedName)
        var create = "CREATE SCHEMA"
        if ifNotExists { create += " IF NOT EXISTS" }
        create += " \(quotedSchema)"

        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOwner.isEmpty {
            create += "\n    AUTHORIZATION \(dialect.quote(trimmedOwner))"
        }
        create += ";"

        var statements: [String] = [create]

        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedComment.isEmpty {
            let escaped = trimmedComment.replacingOccurrences(of: "'", with: "''")
            statements.append("COMMENT ON SCHEMA \(quotedSchema)\n    IS '\(escaped)';")
        }

        for grant in grants {
            let grantee = grant.grantee == "PUBLIC" ? "PUBLIC" : dialect.quote(grant.grantee)
            var stmt = "GRANT \(grant.privilege) ON SCHEMA \(quotedSchema) TO \(grantee)"
            if grant.withGrantOption { stmt += " WITH GRANT OPTION" }
            stmt += ";"
            statements.append(stmt)
        }

        for priv in defaultPrivileges {
            let grantee = priv.grantee == "PUBLIC" ? "PUBLIC" : dialect.quote(priv.grantee)
            var stmt = "ALTER DEFAULT PRIVILEGES IN SCHEMA \(quotedSchema)\n    GRANT \(priv.privilege) ON \(priv.objectType) TO \(grantee)"
            if priv.withGrantOption { stmt += " WITH GRANT OPTION" }
            stmt += ";"
            statements.append(stmt)
        }

        return statements.joined(separator: "\n\n")
    }

    private func saveSchema() {
        guard isValid, !isSaving else { return }
        guard let config = app.connections.connection(id: wizard.connectionID) else { return }
        let sql = generatedSQL
        guard SafeModeGate.authorize(sql: sql, config: config, connections: app.connections,
                                     action: "criar o schema") else { return }
        isSaving = true
        executionError = nil
        bannerDismissed = false
        let driver = app.drivers.driver(for: config)

        Task {
            do {
                let result = try await driver.run(sql, database: wizard.database)
                app.history.record(
                    connectionID: wizard.connectionID,
                    database: wizard.database,
                    sql: sql,
                    duration: result.elapsed,
                    rowCount: result.rows.count
                )
                app.catalog.invalidate(connectionID: wizard.connectionID)
                workspace.reloadAfterDDL(connectionID: wizard.connectionID, database: wizard.database, schema: nil)
                isSaving = false
                dismiss()
            } catch {
                executionError = error.localizedDescription
                bannerDismissed = false
                isSaving = false
            }
        }
    }

    private func loadRoles() async {
        guard let config = app.connections.connection(id: wizard.connectionID) else { return }
        let driver = app.drivers.driver(for: config)
        if let result = try? await driver.run("SELECT rolname FROM pg_roles ORDER BY rolname;", database: wizard.database) {
            availableRoles = result.rows.compactMap { $0.first ?? nil }
        }
    }
}

// MARK: - Drop Object Wizard

struct DropObjectSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "Geral"
        case sql = "SQL"

        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let wizard: DropWizardState
    let workspace: WorkspaceState

    @State private var activeTab: Tab = .general
    @State private var ifExists: Bool = true
    @State private var cascade: Bool = false
    @State private var forceDisconnect: Bool = false
    @State private var confirmation: String = ""
    @FocusState private var confirmationFocused: Bool

    init(wizard: DropWizardState, workspace: WorkspaceState) {
        self.wizard = wizard
        self.workspace = workspace
        _cascade = State(initialValue: wizard.force && wizard.kind != .database)
        _forceDisconnect = State(initialValue: wizard.force && wizard.kind == .database)
    }

    private var isConfirmed: Bool {
        confirmation.trimmingCharacters(in: .whitespacesAndNewlines) == wizard.objectName
    }
    @State private var isExecuting: Bool = false
    @State private var executionError: String?
    @State private var sqlSelection = NSRange(location: 0, length: 0)

    private var dialect: SQLDialect { .postgres }

    private var targetDisplayName: String {
        switch wizard.kind {
        case .table, .view:
            return dialect.qualify(schema: wizard.schema, table: wizard.objectName)
        case .schema, .database:
            return dialect.quote(wizard.objectName)
        }
    }

    private var generatedSQL: String {
        var sql = "DROP \(wizard.kind.rawValue)"
        if ifExists { sql += " IF EXISTS" }
        sql += " \(targetDisplayName)"
        if wizard.kind == .database {
            if forceDisconnect { sql += " WITH (FORCE)" }
        } else if cascade {
            sql += " CASCADE"
        }
        sql += ";"
        return sql
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Icon(wizard.kind.icon, size: 18, solid: true)
                    .foregroundStyle(Color.red)
                    .frame(width: 30, height: 30)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Excluir · \(wizard.kind.displayName)")
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
            .padding(.bottom, 10)

            HStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    WizardTabButton(title: tab.rawValue, badge: nil, isSelected: activeTab == tab) {
                        activeTab = tab
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Color.primary.opacity(0.02))

            Divider()

            Group {
                switch activeTab {
                case .general:
                    VStack(alignment: .leading, spacing: 16) {
                        WizardFormCard {
                            WizardFormRow(label: wizard.kind.displayName) {
                                Text(targetDisplayName)
                                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            }

                            Divider()

                            WizardFormRow(label: "Ignorar se não existir (IF EXISTS)") {
                                HStack {
                                    Spacer()
                                    Toggle("", isOn: $ifExists)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                }
                            }

                            Divider()

                            if wizard.kind == .database {
                                WizardFormRow(label: "Encerrar conexões ativas (WITH FORCE)") {
                                    HStack {
                                        Spacer()
                                        Toggle("", isOn: $forceDisconnect)
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .controlSize(.mini)
                                    }
                                }
                            } else {
                                WizardFormRow(label: "Excluir dependentes em cascata (CASCADE)") {
                                    HStack {
                                        Spacer()
                                        Toggle("", isOn: $cascade)
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .controlSize(.mini)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Icon(.alertCircle, size: 15, solid: true)
                                    .foregroundStyle(.red)
                                Text("Esta ação não pode ser desfeita. Para confirmar, digite \(Text(wizard.objectName).font(.system(size: 11.5, weight: .semibold, design: .monospaced))) abaixo.")
                                    .font(.system(size: 11.5))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            TextField(wizard.objectName, text: $confirmation)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .focused($confirmationFocused)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(isConfirmed ? Color.red.opacity(0.7) : Color.primary.opacity(0.15), lineWidth: 1)
                                )
                                .onSubmit { if isConfirmed { executeDrop() } }
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.3), lineWidth: 0.5))
                    }
                    .padding(20)

                case .sql:
                    SQLEditorView(
                        text: .constant(generatedSQL),
                        selection: $sqlSelection
                    )
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let executionError {
                WizardValidationBanner(message: executionError) {
                    self.executionError = nil
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    let targetDB = wizard.kind == .database ? "postgres" : wizard.database
                    let context = QueryContext(
                        connectionID: wizard.connectionID,
                        connectionName: wizard.connectionName,
                        database: targetDB,
                        schema: wizard.schema
                    )
                    workspace.newQueryTab(context: context, sql: generatedSQL, title: "DROP · \(wizard.objectName)")
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Icon(.newQuery, size: 13)
                        Text("Abrir no editor")
                    }
                }
                .disabled(isExecuting)

                Spacer()

                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(role: .destructive) {
                    executeDrop()
                } label: {
                    HStack(spacing: 6) {
                        if isExecuting {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                        }
                        Text("Excluir")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isExecuting || !isConfirmed)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { confirmationFocused = true }
    }

    private func executeDrop() {
        guard !isExecuting, isConfirmed else { return }
        guard let config = app.connections.connection(id: wizard.connectionID) else { return }
        let sql = generatedSQL
        guard SafeModeGate.authorize(sql: sql, config: config, connections: app.connections,
                                     action: "excluir o objeto") else { return }
        isExecuting = true
        executionError = nil
        let targetDB = wizard.kind == .database ? "postgres" : wizard.database
        let driver = app.drivers.driver(for: config)

        Task {
            do {
                let result = try await driver.run(sql, database: targetDB)
                app.history.record(
                    connectionID: wizard.connectionID,
                    database: targetDB,
                    sql: sql,
                    duration: result.elapsed,
                    rowCount: result.rows.count
                )
                app.catalog.invalidate(connectionID: wizard.connectionID)
                workspace.reloadAfterDDL(
                    connectionID: wizard.connectionID,
                    database: wizard.kind == .database ? nil : wizard.database,
                    schema: (wizard.kind == .table || wizard.kind == .view) ? wizard.schema : nil
                )
                isExecuting = false
                dismiss()
            } catch {
                executionError = error.localizedDescription
                isExecuting = false
            }
        }
    }
}

// MARK: - Table Sub-Object Wizard (Column, Index, Rule, Trigger, RLS Policy)

struct CreateTableSubObjectSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "Geral"
        case sql = "SQL"

        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let wizard: TableSubObjectWizardState
    let workspace: WorkspaceState

    @State private var activeTab: Tab = .general
    @State private var name: String = ""

    // Column fields
    @State private var dataType: String = "text"
    @State private var length: String = ""
    @State private var notNull: Bool = false
    @State private var defaultValue: String = ""

    // Index fields
    @State private var indexColumns: String = ""
    @State private var indexMethod: String = "btree"
    @State private var indexUnique: Bool = false
    @State private var indexConcurrent: Bool = false

    // Rule fields
    @State private var ruleEvent: String = "INSERT"
    @State private var ruleInstead: Bool = true
    @State private var ruleCommand: String = "NOTHING"

    // Trigger fields
    @State private var triggerTiming: String = "BEFORE"
    @State private var triggerEvent: String = "INSERT"
    @State private var triggerForEachRow: Bool = true
    @State private var triggerFunction: String = ""

    // Policy fields
    @State private var policyCommand: String = "ALL"
    @State private var policyRole: String = "PUBLIC"
    @State private var policyUsing: String = "true"
    @State private var policyCheck: String = ""

    @State private var tableColumns: [String] = []
    @State private var isSaving: Bool = false
    @State private var executionError: String?
    @State private var bannerDismissed: Bool = false
    @State private var sqlSelection = NSRange(location: 0, length: 0)
    @FocusState private var nameFocused: Bool

    private var dialect: SQLDialect { .postgres }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var qualifiedTable: String {
        dialect.qualify(schema: wizard.schema, table: wizard.table)
    }

    private var validationError: String? {
        if let executionError { return executionError }
        if trimmedName.isEmpty { return "O campo 'Nome' não pode ficar vazio." }
        if wizard.kind == .index && indexColumns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Informe pelo menos uma coluna para o índice."
        }
        if wizard.kind == .trigger && triggerFunction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Informe a função que o trigger executará."
        }
        return nil
    }

    private var isValid: Bool {
        validationError == nil || executionError != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Icon(.table, size: 18, solid: true)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Criar · \(wizard.kind.title)")
                        .font(.system(size: 14.5, weight: .semibold))
                    Text("\(wizard.connectionName) · \(wizard.database) · \(wizard.table)")
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
            .padding(.bottom, 10)

            HStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    WizardTabButton(title: tab.rawValue, badge: nil, isSelected: activeTab == tab) {
                        activeTab = tab
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Color.primary.opacity(0.02))

            Divider()

            Group {
                switch activeTab {
                case .general:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            WizardFormCard {
                                WizardFormRow(label: "Nome", isInvalid: trimmedName.isEmpty) {
                                    HStack(spacing: 6) {
                                        if trimmedName.isEmpty {
                                            Icon(.alertCircle, size: 14, solid: true).foregroundStyle(.red)
                                        }
                                        TextField("nome", text: $name)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 12.5))
                                            .focused($nameFocused)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .strokeBorder(trimmedName.isEmpty ? Color.red.opacity(0.8) : Color.primary.opacity(0.15))
                                            )
                                    }
                                }

                                Divider()
                                specificFields
                            }
                        }
                        .padding(20)
                    }
                case .sql:
                    SQLEditorView(
                        text: .constant(trimmedName.isEmpty ? "-- Definição incompleta." : generatedSQL),
                        selection: $sqlSelection
                    )
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let message = validationError, !bannerDismissed {
                WizardValidationBanner(message: message) {
                    if executionError != nil { executionError = nil }
                    else { bannerDismissed = true }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    let context = QueryContext(
                        connectionID: wizard.connectionID,
                        connectionName: wizard.connectionName,
                        database: wizard.database,
                        schema: wizard.schema
                    )
                    workspace.newQueryTab(context: context, sql: generatedSQL, title: "Criar \(wizard.kind.title) · \(trimmedName)")
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Icon(.newQuery, size: 13)
                        Text("Abrir no editor")
                    }
                }
                .disabled(!isValid || trimmedName.isEmpty || isSaving)

                Spacer()

                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    save()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                        }
                        Text("Salvar")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || trimmedName.isEmpty || isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 580, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { nameFocused = true }
        .onChange(of: name) { _, _ in bannerDismissed = false; executionError = nil }
        .task { await loadColumns() }
    }

    @ViewBuilder
    private var specificFields: some View {
        switch wizard.kind {
        case .column:
            WizardFormRow(label: "Tipo de dado") {
                Picker("", selection: $dataType) {
                    ForEach(CreateTableSheet.ColumnDraft.availableTypes, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .trailing)
            }
            Divider()
            WizardFormRow(label: "Tamanho / Precisão") {
                TextField("opcional", text: $length)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
            Divider()
            WizardFormRow(label: "Não nulo (NOT NULL)") {
                HStack { Spacer(); Toggle("", isOn: $notNull).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
            }
            Divider()
            WizardFormRow(label: "Valor padrão (DEFAULT)") {
                TextField("opcional", text: $defaultValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }

        case .index:
            WizardFormRow(label: "Colunas") {
                HStack(spacing: 6) {
                    TextField("ex: email, created_at", text: $indexColumns)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                    if !tableColumns.isEmpty {
                        Menu {
                            ForEach(tableColumns, id: \.self) { col in
                                Button(col) {
                                    if indexColumns.isEmpty { indexColumns = col }
                                    else { indexColumns += ", \(col)" }
                                }
                            }
                        } label: {
                            Icon(.chevron, size: 11).rotationEffect(.degrees(90))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 20)
                    }
                }
            }
            Divider()
            WizardFormRow(label: "Método") {
                Picker("", selection: $indexMethod) {
                    ForEach(["btree", "hash", "gist", "gin", "spgist", "brin"], id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 140)
            }
            Divider()
            WizardFormRow(label: "Índice único (UNIQUE)") {
                HStack { Spacer(); Toggle("", isOn: $indexUnique).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
            }
            Divider()
            WizardFormRow(label: "Concorrente (CONCURRENTLY)") {
                HStack { Spacer(); Toggle("", isOn: $indexConcurrent).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
            }

        case .rule:
            WizardFormRow(label: "Evento") {
                Picker("", selection: $ruleEvent) {
                    ForEach(["SELECT", "INSERT", "UPDATE", "DELETE"], id: \.self) { ev in Text(ev).tag(ev) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 260)
            }
            Divider()
            WizardFormRow(label: "Modo (DO INSTEAD)") {
                HStack { Spacer(); Toggle("", isOn: $ruleInstead).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
            }
            Divider()
            WizardFormRow(label: "Comando (DO ...)") {
                TextField("NOTHING", text: $ruleCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }

        case .trigger:
            WizardFormRow(label: "Momento") {
                Picker("", selection: $triggerTiming) {
                    ForEach(["BEFORE", "AFTER", "INSTEAD OF"], id: \.self) { tm in Text(tm).tag(tm) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 240)
            }
            Divider()
            WizardFormRow(label: "Evento") {
                Picker("", selection: $triggerEvent) {
                    ForEach(["INSERT", "UPDATE", "DELETE", "TRUNCATE"], id: \.self) { ev in Text(ev).tag(ev) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 160)
            }
            Divider()
            WizardFormRow(label: "Para cada linha (FOR EACH ROW)") {
                HStack { Spacer(); Toggle("", isOn: $triggerForEachRow).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
            }
            Divider()
            WizardFormRow(label: "Função (EXECUTE FUNCTION)") {
                TextField("ex: atualizar_timestamp()", text: $triggerFunction)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }

        case .policy:
            WizardFormRow(label: "Comando") {
                Picker("", selection: $policyCommand) {
                    ForEach(["ALL", "SELECT", "INSERT", "UPDATE", "DELETE"], id: \.self) { cmd in Text(cmd).tag(cmd) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 160)
            }
            Divider()
            WizardFormRow(label: "Role (TO)") {
                TextField("PUBLIC", text: $policyRole)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
            Divider()
            WizardFormRow(label: "Expressão USING") {
                TextField("true", text: $policyUsing)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
            Divider()
            WizardFormRow(label: "Expressão WITH CHECK") {
                TextField("opcional", text: $policyCheck)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var generatedSQL: String {
        let quotedName = dialect.quote(trimmedName)
        switch wizard.kind {
        case .column:
            let len = length.trimmingCharacters(in: .whitespacesAndNewlines)
            let fullType = len.isEmpty ? dataType : "\(dataType)(\(len))"
            var sql = "ALTER TABLE \(qualifiedTable)\n    ADD COLUMN \(quotedName) \(fullType)"
            if notNull { sql += " NOT NULL" }
            let def = defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !def.isEmpty { sql += " DEFAULT \(def)" }
            return sql + ";"

        case .index:
            var sql = "CREATE"
            if indexUnique { sql += " UNIQUE" }
            sql += " INDEX"
            if indexConcurrent { sql += " CONCURRENTLY" }
            let cols = indexColumns.split(separator: ",").map { dialect.quote($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.joined(separator: ", ")
            sql += " \(quotedName)\n    ON \(qualifiedTable) USING \(indexMethod) (\(cols));"
            return sql

        case .rule:
            let mode = ruleInstead ? "INSTEAD" : "ALSO"
            let cmd = ruleCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return "CREATE RULE \(quotedName) AS\n    ON \(ruleEvent) TO \(qualifiedTable)\n    DO \(mode) \(cmd.isEmpty ? "NOTHING" : cmd);"

        case .trigger:
            let each = triggerForEachRow ? "ROW" : "STATEMENT"
            var fn = triggerFunction.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fn.hasSuffix(")") { fn += "()" }
            return "CREATE TRIGGER \(quotedName)\n    \(triggerTiming) \(triggerEvent) ON \(qualifiedTable)\n    FOR EACH \(each)\n    EXECUTE FUNCTION \(fn);"

        case .policy:
            let role = policyRole.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetRole = (role.isEmpty || role.uppercased() == "PUBLIC") ? "PUBLIC" : dialect.quote(role)
            var sql = "ALTER TABLE \(qualifiedTable) ENABLE ROW LEVEL SECURITY;\n\nCREATE POLICY \(quotedName)\n    ON \(qualifiedTable)\n    FOR \(policyCommand)\n    TO \(targetRole)"
            let usingExpr = policyUsing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !usingExpr.isEmpty { sql += "\n    USING (\(usingExpr))" }
            let checkExpr = policyCheck.trimmingCharacters(in: .whitespacesAndNewlines)
            if !checkExpr.isEmpty { sql += "\n    WITH CHECK (\(checkExpr))" }
            return sql + ";"
        }
    }

    private func save() {
        guard isValid, !trimmedName.isEmpty, !isSaving else { return }
        guard let config = app.connections.connection(id: wizard.connectionID) else { return }
        let sql = generatedSQL
        guard SafeModeGate.authorize(sql: sql, config: config, connections: app.connections,
                                     action: "criar o objeto") else { return }
        isSaving = true
        executionError = nil
        let driver = app.drivers.driver(for: config)

        Task {
            do {
                let result = try await driver.run(sql, database: wizard.database)
                app.history.record(
                    connectionID: wizard.connectionID,
                    database: wizard.database,
                    sql: sql,
                    duration: result.elapsed,
                    rowCount: result.rows.count
                )
                app.catalog.invalidate(connectionID: wizard.connectionID)
                workspace.reloadAfterDDL(connectionID: wizard.connectionID, database: wizard.database, schema: wizard.schema)
                isSaving = false
                dismiss()
            } catch {
                executionError = error.localizedDescription
                bannerDismissed = false
                isSaving = false
            }
        }
    }

    private func loadColumns() async {
        guard let config = app.connections.connection(id: wizard.connectionID) else { return }
        let driver = app.drivers.driver(for: config)
        if let cols = try? await driver.listColumns(database: wizard.database, schema: wizard.schema ?? "public", table: wizard.table) {
            tableColumns = cols.map(\.name)
            if indexColumns.isEmpty, let first = tableColumns.first {
                indexColumns = first
            }
        }
    }
}

// MARK: - Create Database Wizard (Phase 7)

struct CreateDatabaseSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "Geral"
        case definition = "Definição"
        case sql = "SQL"

        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let wizard: DatabaseWizardState
    let workspace: WorkspaceState

    @State private var activeTab: Tab = .general
    @State private var name: String = ""
    @State private var owner: String
    @State private var comment: String = ""
    @State private var encoding: String = "UTF8"
    @State private var template: String = "template1"
    @State private var tablespace: String = ""
    @State private var connectionLimit: String = "-1"
    @State private var isTemplate: Bool = false

    @State private var availableRoles: [String] = []
    @State private var availableTablespaces: [String] = []
    @State private var isSaving: Bool = false
    @State private var executionError: String?
    @State private var bannerDismissed: Bool = false
    @State private var sqlSelection = NSRange(location: 0, length: 0)
    @FocusState private var nameFocused: Bool

    init(wizard: DatabaseWizardState, workspace: WorkspaceState) {
        self.wizard = wizard
        self.workspace = workspace
        _owner = State(initialValue: wizard.defaultOwner)
    }

    private var dialect: SQLDialect { .postgres }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !trimmedName.isEmpty }
    private var validationError: String? {
        if let executionError { return executionError }
        if trimmedName.isEmpty { return "O campo 'Nome' não pode ficar vazio." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Icon(.database, size: 18, solid: true)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Criar · Banco de dados")
                        .font(.system(size: 14.5, weight: .semibold))
                    Text(wizard.connectionName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button { dismiss() } label: {
                    Icon(.close, size: 12).foregroundStyle(.secondary).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            HStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    WizardTabButton(title: tab.rawValue, badge: nil, isSelected: activeTab == tab) {
                        activeTab = tab
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 34).background(Color.primary.opacity(0.02))

            Divider()

            Group {
                switch activeTab {
                case .general:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            WizardFormCard {
                                WizardFormRow(label: "Nome", isInvalid: trimmedName.isEmpty) {
                                    HStack(spacing: 6) {
                                        if trimmedName.isEmpty {
                                            Icon(.alertCircle, size: 14, solid: true).foregroundStyle(.red)
                                        }
                                        TextField("novo_banco", text: $name)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 12.5))
                                            .focused($nameFocused)
                                            .padding(.horizontal, 8).padding(.vertical, 5)
                                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .strokeBorder(trimmedName.isEmpty ? Color.red.opacity(0.8) : Color.primary.opacity(0.15))
                                            )
                                    }
                                }
                                Divider()
                                WizardFormRow(label: "Dono") {
                                    Picker("Dono", selection: $owner) {
                                        ForEach(roleOptions, id: \.self) { r in Text(r).tag(r) }
                                    }
                                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 240, alignment: .trailing)
                                }
                            }

                            WizardFormCard(title: "Comentário") {
                                TextEditor(text: $comment)
                                    .font(.system(size: 12))
                                    .scrollContentBackground(.hidden)
                                    .frame(height: 80)
                                    .padding(6)
                            }
                        }
                        .padding(20)
                    }

                case .definition:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            WizardFormCard {
                                WizardFormRow(label: "Codificação (Encoding)") {
                                    Picker("", selection: $encoding) {
                                        ForEach(["UTF8", "SQL_ASCII", "LATIN1", "WIN1252"], id: \.self) { enc in
                                            Text(enc).tag(enc)
                                        }
                                    }
                                    .labelsHidden().pickerStyle(.menu).frame(width: 180)
                                }
                                Divider()
                                WizardFormRow(label: "Template") {
                                    Picker("", selection: $template) {
                                        Text("template1 (padrão)").tag("template1")
                                        Text("template0").tag("template0")
                                    }
                                    .labelsHidden().pickerStyle(.menu).frame(width: 180)
                                }
                                Divider()
                                WizardFormRow(label: "Tablespace") {
                                    Picker("", selection: $tablespace) {
                                        Text("Padrão (pg_default)").tag("")
                                        ForEach(availableTablespaces, id: \.self) { ts in Text(ts).tag(ts) }
                                    }
                                    .labelsHidden().pickerStyle(.menu).frame(width: 180)
                                }
                                Divider()
                                WizardFormRow(label: "Limite de conexões") {
                                    TextField("-1", text: $connectionLimit)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12, design: .monospaced))
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 80)
                                }
                                Divider()
                                WizardFormRow(label: "Banco template (IS_TEMPLATE)") {
                                    HStack { Spacer(); Toggle("", isOn: $isTemplate).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                                }
                            }
                        }
                        .padding(20)
                    }

                case .sql:
                    SQLEditorView(
                        text: .constant(isValid ? generatedSQL : "-- Definição incompleta.\n-- Informe o nome do banco na aba 'Geral'."),
                        selection: $sqlSelection
                    )
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let message = validationError, !bannerDismissed {
                WizardValidationBanner(message: message) {
                    if executionError != nil { executionError = nil }
                    else { bannerDismissed = true }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    let context = QueryContext(
                        connectionID: wizard.connectionID,
                        connectionName: wizard.connectionName,
                        database: wizard.maintenanceDatabase,
                        schema: nil
                    )
                    workspace.newQueryTab(context: context, sql: generatedSQL, title: "Criar · \(trimmedName)")
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Icon(.newQuery, size: 13)
                        Text("Abrir no editor")
                    }
                }
                .disabled(!isValid || isSaving)

                Spacer()

                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    name = ""
                    owner = wizard.defaultOwner
                    comment = ""
                    encoding = "UTF8"
                    template = "template1"
                    tablespace = ""
                    connectionLimit = "-1"
                    isTemplate = false
                    executionError = nil
                    bannerDismissed = false
                } label: {
                    HStack(spacing: 4) {
                        Icon(.refresh, size: 12)
                        Text("Limpar")
                    }
                }
                .disabled(isSaving)

                Button {
                    saveDatabase()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                        }
                        Text("Salvar")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isSaving)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 600, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { nameFocused = true }
        .onChange(of: name) { _, _ in bannerDismissed = false; executionError = nil }
        .task { await loadMetadata() }
    }

    private var roleOptions: [String] {
        var list = availableRoles
        if !owner.isEmpty && !list.contains(owner) { list.insert(owner, at: 0) }
        return list.isEmpty ? ["postgres"] : list
    }

    private var generatedSQL: String {
        guard !trimmedName.isEmpty else { return "" }
        let quotedDB = dialect.quote(trimmedName)
        var options: [String] = []
        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOwner.isEmpty { options.append("OWNER = \(dialect.quote(trimmedOwner))") }
        options.append("ENCODING = '\(encoding)'")
        if template != "template1" { options.append("TEMPLATE = \(dialect.quote(template))") }
        if !tablespace.isEmpty { options.append("TABLESPACE = \(dialect.quote(tablespace))") }
        if let limit = Int(connectionLimit), limit != -1 { options.append("CONNECTION LIMIT = \(limit)") }
        if isTemplate { options.append("IS_TEMPLATE = true") }

        var sql = "CREATE DATABASE \(quotedDB)\n    WITH \(options.joined(separator: "\n         "));"
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedComment.isEmpty {
            let escaped = trimmedComment.replacingOccurrences(of: "'", with: "''")
            sql += "\n\nCOMMENT ON DATABASE \(quotedDB)\n    IS '\(escaped)';"
        }
        return sql
    }

    private func saveDatabase() {
        guard isValid, !isSaving else { return }
        guard let config = app.connections.connection(id: wizard.connectionID) else { return }
        executionError = nil
        let quotedDB = dialect.quote(trimmedName)
        var options: [String] = []
        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOwner.isEmpty { options.append("OWNER = \(dialect.quote(trimmedOwner))") }
        options.append("ENCODING = '\(encoding)'")
        if template != "template1" { options.append("TEMPLATE = \(dialect.quote(template))") }
        if !tablespace.isEmpty { options.append("TABLESPACE = \(dialect.quote(tablespace))") }
        if let limit = Int(connectionLimit), limit != -1 { options.append("CONNECTION LIMIT = \(limit)") }
        if isTemplate { options.append("IS_TEMPLATE = true") }
        let createSQL = "CREATE DATABASE \(quotedDB) WITH \(options.joined(separator: " "));"
        guard SafeModeGate.authorize(sql: createSQL, config: config, connections: app.connections,
                                     action: "criar o banco de dados") else { return }
        isSaving = true
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let driver = app.drivers.driver(for: config)

        Task {
            do {
                let res = try await driver.run(createSQL, database: wizard.maintenanceDatabase)
                if !trimmedComment.isEmpty {
                    let escaped = trimmedComment.replacingOccurrences(of: "'", with: "''")
                    _ = try? await driver.run("COMMENT ON DATABASE \(quotedDB) IS '\(escaped)';", database: wizard.maintenanceDatabase)
                }
                app.history.record(
                    connectionID: wizard.connectionID,
                    database: wizard.maintenanceDatabase,
                    sql: createSQL,
                    duration: res.elapsed,
                    rowCount: 0
                )
                workspace.reloadAfterDDL(connectionID: wizard.connectionID, database: nil, schema: nil)
                isSaving = false
                dismiss()
            } catch {
                executionError = error.localizedDescription
                bannerDismissed = false
                isSaving = false
            }
        }
    }

    private func loadMetadata() async {
        guard let config = app.connections.connection(id: wizard.connectionID) else { return }
        let driver = app.drivers.driver(for: config)
        if let rolesResult = try? await driver.run("SELECT rolname FROM pg_roles ORDER BY rolname;", database: wizard.maintenanceDatabase) {
            availableRoles = rolesResult.rows.compactMap { $0.first ?? nil }
        }
        if let tsResult = try? await driver.run("SELECT spcname FROM pg_tablespace ORDER BY spcname;", database: wizard.maintenanceDatabase) {
            availableTablespaces = tsResult.rows.compactMap { $0.first ?? nil }
        }
    }
}

// MARK: - Table Structure / DDL Inspector & ALTER Wizard (Phase 5 - ⌘I)

struct TableStructureSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case columns = "Colunas"
        case indexes = "Índices"
        case constraints = "Chaves e Constraints"
        case ddl = "DDL (CREATE)"
        case alter = "Alterações (ALTER)"

        var id: String { rawValue }
    }

    struct EditableColumn: Identifiable, Equatable {
        let id = UUID()
        var originalName: String?
        var name: String
        var dataType: String
        var isNullable: Bool
        var defaultValue: String
        var isPrimaryKey: Bool
        var references: String?
        var isDeleted: Bool = false
    }

    struct IndexEntry: Identifiable {
        let id = UUID()
        let name: String
        let isUnique: Bool
        let isPrimary: Bool
        let definition: String
    }

    struct ConstraintEntry: Identifiable {
        let id = UUID()
        let name: String
        let kind: String
        let definition: String
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let state: TableStructureState
    let workspace: WorkspaceState

    @State private var activeTab: Tab = .columns
    @State private var originalColumns: [EditableColumn] = []
    @State private var columns: [EditableColumn] = []
    @State private var indexes: [IndexEntry] = []
    @State private var constraints: [ConstraintEntry] = []
    @State private var isLoading: Bool = true
    @State private var isApplying: Bool = false
    @State private var executionError: String?
    @State private var sqlSelection = NSRange(location: 0, length: 0)

    private var dialect: SQLDialect { .postgres }
    private var qualifiedTable: String { dialect.qualify(schema: state.schema, table: state.table) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Icon(.table, size: 18, solid: true)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Estrutura · \(state.table)")
                        .font(.system(size: 14.5, weight: .semibold))
                    Text("\(state.connectionName) · \(state.database) · \(state.schema)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLoading {
                    ProgressView().controlSize(.small)
                }

                Button { dismiss() } label: {
                    Icon(.close, size: 12).foregroundStyle(.secondary).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            HStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    WizardTabButton(
                        title: tab.rawValue,
                        badge: badge(for: tab),
                        isSelected: activeTab == tab
                    ) {
                        activeTab = tab
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 34).background(Color.primary.opacity(0.02))

            Divider()

            Group {
                switch activeTab {
                case .columns:
                    columnsView
                case .indexes:
                    indexesView
                case .constraints:
                    constraintsView
                case .ddl:
                    SQLEditorView(text: .constant(generatedCreateDDL), selection: $sqlSelection)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipped()
                case .alter:
                    SQLEditorView(
                        text: .constant(alterStatements.isEmpty ? "-- Nenhuma alteração pendente nas colunas." : alterSQL),
                        selection: $sqlSelection
                    )
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let executionError {
                WizardValidationBanner(message: executionError) {
                    self.executionError = nil
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    let sql = activeTab == .alter && !alterStatements.isEmpty ? alterSQL : generatedCreateDDL
                    let title = activeTab == .alter && !alterStatements.isEmpty ? "ALTER · \(state.table)" : "DDL · \(state.table)"
                    let context = QueryContext(
                        connectionID: state.connectionID,
                        connectionName: state.connectionName,
                        database: state.database,
                        schema: state.schema
                    )
                    workspace.newQueryTab(context: context, sql: sql, title: title)
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Icon(.newQuery, size: 13)
                        Text("Abrir DDL no editor")
                    }
                }

                Button {
                    let sql = activeTab == .alter && !alterStatements.isEmpty ? alterSQL : generatedCreateDDL
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                } label: {
                    HStack(spacing: 5) {
                        Icon(.copy, size: 13)
                        Text("Copiar DDL")
                    }
                }

                Spacer()

                if !alterStatements.isEmpty {
                    Button("Descartar alterações") {
                        columns = originalColumns
                        executionError = nil
                    }
                    .disabled(isApplying)
                }

                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                if !alterStatements.isEmpty {
                    Button {
                        applyAlter()
                    } label: {
                        HStack(spacing: 6) {
                            if isApplying {
                                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                            }
                            Text("Aplicar ALTER (\(alterStatements.count))")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 780, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await loadStructure() }
    }

    private func badge(for tab: Tab) -> Int? {
        switch tab {
        case .columns:
            let count = columns.filter { !$0.isDeleted }.count
            return count > 0 ? count : nil
        case .indexes:
            return indexes.isEmpty ? nil : indexes.count
        case .constraints:
            return constraints.isEmpty ? nil : constraints.count
        case .alter:
            return alterStatements.isEmpty ? nil : alterStatements.count
        case .ddl:
            return nil
        }
    }

    private var columnsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Colunas de \(qualifiedTable)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    columns.append(EditableColumn(
                        originalName: nil,
                        name: "nova_coluna_\(columns.count + 1)",
                        dataType: "text",
                        isNullable: true,
                        defaultValue: "",
                        isPrimaryKey: false,
                        references: nil
                    ))
                } label: {
                    HStack(spacing: 4) {
                        Icon(.plus, size: 12)
                        Text("Nova coluna").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).frame(height: 36).background(Color.primary.opacity(0.04))

            Divider()

            HStack(spacing: 8) {
                Color.clear.frame(width: 22)
                Text("Nome").frame(width: 160, alignment: .leading)
                Text("Tipo de dado").frame(width: 150, alignment: .leading)
                Text("Permite NULL").frame(width: 85, alignment: .center)
                Text("Padrão (DEFAULT)").frame(width: 150, alignment: .leading)
                Text("Chave / Ref.").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($columns) { $col in
                        let current = col
                        if !current.isDeleted {
                            HStack(spacing: 8) {
                                Button {
                                    if current.originalName == nil {
                                        columns.removeAll { $0.id == current.id }
                                    } else {
                                        col.isDeleted = true
                                    }
                                } label: {
                                    Icon(.close, size: 11).foregroundStyle(.secondary).frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .help("Remover coluna")

                                TextField("nome", text: $col.name)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(width: 160)

                                TextField("tipo", text: $col.dataType)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(width: 150)

                                Toggle("", isOn: $col.isNullable)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                    .disabled(current.isPrimaryKey)
                                    .frame(width: 85)

                                TextField("NULL", text: $col.defaultValue)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(width: 150)

                                HStack(spacing: 6) {
                                    if current.isPrimaryKey {
                                        HStack(spacing: 3) {
                                            Icon(.key, size: 11).foregroundStyle(.orange)
                                            Text("PK").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                                        }
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.14), in: Capsule())
                                    }
                                    if let ref = current.references {
                                        HStack(spacing: 3) {
                                            Icon(.link, size: 11).foregroundStyle(.secondary)
                                            Text(ref).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                    if current.originalName == nil {
                                        Text("NOVA").font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12).frame(height: 36)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var indexesView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if indexes.isEmpty {
                    Text("Nenhum índice encontrado.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    ForEach(indexes) { idx in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Icon(idx.isPrimary ? .key : .table, size: 13)
                                    .foregroundStyle(idx.isPrimary ? .orange : .secondary)
                                Text(idx.name)
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                if idx.isPrimary {
                                    Text("PRIMARY").font(.system(size: 9.5, weight: .semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                                        .background(Color.orange.opacity(0.15), in: Capsule())
                                } else if idx.isUnique {
                                    Text("UNIQUE").font(.system(size: 9.5, weight: .semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                                Spacer()
                            }
                            Text(idx.definition + ";")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(20)
        }
    }

    private var constraintsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if constraints.isEmpty {
                    Text("Nenhuma constraint encontrada.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    ForEach(constraints) { con in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Icon(con.kind == "PRIMARY KEY" ? .key : .link, size: 13)
                                    .foregroundStyle(con.kind == "PRIMARY KEY" ? .orange : .secondary)
                                Text(con.name)
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                Text(con.kind)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                                Spacer()
                            }
                            Text(con.definition)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(20)
        }
    }

    private var generatedCreateDDL: String {
        var lines: [String] = []
        for col in originalColumns {
            var line = "    \(dialect.quote(col.name)) \(col.dataType)"
            if !col.defaultValue.isEmpty {
                line += " DEFAULT \(col.defaultValue)"
            }
            if !col.isNullable {
                line += " NOT NULL"
            }
            lines.append(line)
        }
        for con in constraints {
            lines.append("    CONSTRAINT \(dialect.quote(con.name)) \(con.definition)")
        }
        var ddl = "CREATE TABLE \(qualifiedTable) (\n\(lines.joined(separator: ",\n"))\n);"
        let nonPKIndexes = indexes.filter { !$0.isPrimary }
        if !nonPKIndexes.isEmpty {
            ddl += "\n\n" + nonPKIndexes.map { "\($0.definition);" }.joined(separator: "\n")
        }
        return ddl
    }

    private var alterStatements: [String] {
        var stmts: [String] = []
        for col in columns {
            let trimmed = col.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if col.isDeleted {
                if let orig = col.originalName {
                    stmts.append("ALTER TABLE \(qualifiedTable) DROP COLUMN \(dialect.quote(orig));")
                }
                continue
            }
            guard !trimmed.isEmpty else { continue }
            guard let origName = col.originalName,
                  let orig = originalColumns.first(where: { $0.originalName == origName }) else {
                var add = "ALTER TABLE \(qualifiedTable) ADD COLUMN \(dialect.quote(trimmed)) \(col.dataType)"
                if !col.isNullable { add += " NOT NULL" }
                let def = col.defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !def.isEmpty { add += " DEFAULT \(def)" }
                stmts.append(add + ";")
                continue
            }

            let targetColName = dialect.quote(trimmed)
            if trimmed != origName {
                stmts.append("ALTER TABLE \(qualifiedTable) RENAME COLUMN \(dialect.quote(origName)) TO \(targetColName);")
            }
            let newType = col.dataType.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newType.isEmpty && newType != orig.dataType {
                stmts.append("ALTER TABLE \(qualifiedTable) ALTER COLUMN \(targetColName) TYPE \(newType);")
            }
            if col.isNullable != orig.isNullable {
                stmts.append("ALTER TABLE \(qualifiedTable) ALTER COLUMN \(targetColName) \(col.isNullable ? "DROP NOT NULL" : "SET NOT NULL");")
            }
            let newDef = col.defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if newDef != orig.defaultValue {
                if newDef.isEmpty {
                    stmts.append("ALTER TABLE \(qualifiedTable) ALTER COLUMN \(targetColName) DROP DEFAULT;")
                } else {
                    stmts.append("ALTER TABLE \(qualifiedTable) ALTER COLUMN \(targetColName) SET DEFAULT \(newDef);")
                }
            }
        }
        return stmts
    }

    private var alterSQL: String {
        alterStatements.joined(separator: "\n")
    }

    private func applyAlter() {
        guard !alterStatements.isEmpty, !isApplying else { return }
        guard let config = app.connections.connection(id: state.connectionID) else { return }
        let sql = alterSQL
        guard SafeModeGate.authorize(sql: sql, config: config, connections: app.connections,
                                     action: "aplicar as alterações de estrutura") else { return }
        isApplying = true
        executionError = nil
        let driver = app.drivers.driver(for: config)

        Task {
            do {
                let res = try await driver.run(sql, database: state.database)
                app.history.record(
                    connectionID: state.connectionID,
                    database: state.database,
                    sql: sql,
                    duration: res.elapsed,
                    rowCount: 0
                )
                app.catalog.invalidate(connectionID: state.connectionID)
                workspace.reloadAfterDDL(connectionID: state.connectionID, database: state.database, schema: state.schema)
                await loadStructure()
                isApplying = false
            } catch {
                executionError = error.localizedDescription
                isApplying = false
            }
        }
    }

    private func loadStructure() async {
        guard let config = app.connections.connection(id: state.connectionID) else { return }
        isLoading = true
        defer { isLoading = false }
        let driver = app.drivers.driver(for: config)
        let escSchema = state.schema.replacingOccurrences(of: "'", with: "''")
        let escTable = state.table.replacingOccurrences(of: "'", with: "''")

        if let cols = try? await driver.listColumns(database: state.database, schema: state.schema, table: state.table) {
            let defaultsRes = try? await driver.run("""
                SELECT a.attname, pg_get_expr(d.adbin, d.adrelid)
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                JOIN pg_attribute a ON a.attrelid = c.oid
                LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
                WHERE n.nspname = '\(escSchema)' AND c.relname = '\(escTable)' AND a.attnum > 0 AND NOT a.attisdropped;
                """, database: state.database)
            var defaultMap: [String: String] = [:]
            for row in defaultsRes?.rows ?? [] where row.count >= 2 {
                if let colName = row[0], let defVal = row[1] {
                    defaultMap[colName] = defVal
                }
            }
            let mapped = cols.map { c in
                EditableColumn(
                    originalName: c.name,
                    name: c.name,
                    dataType: c.dataType,
                    isNullable: c.isNullable,
                    defaultValue: defaultMap[c.name] ?? "",
                    isPrimaryKey: c.isPrimaryKey,
                    references: c.references
                )
            }
            originalColumns = mapped
            columns = mapped
        }

        if let idxRes = try? await driver.run("""
            SELECT ic.relname, i.indisunique, i.indisprimary, pg_get_indexdef(i.indexrelid)
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE n.nspname = '\(escSchema)' AND c.relname = '\(escTable)'
            ORDER BY i.indisprimary DESC, ic.relname;
            """, database: state.database) {
            indexes = idxRes.rows.compactMap { row in
                guard row.count >= 4, let name = row[0], let def = row[3] else { return nil }
                return IndexEntry(
                    name: name,
                    isUnique: row[1] == "true",
                    isPrimary: row[2] == "true",
                    definition: def
                )
            }
        }

        if let conRes = try? await driver.run("""
            SELECT con.conname,
                   CASE con.contype
                       WHEN 'p' THEN 'PRIMARY KEY'
                       WHEN 'f' THEN 'FOREIGN KEY'
                       WHEN 'u' THEN 'UNIQUE'
                       WHEN 'c' THEN 'CHECK'
                       WHEN 'x' THEN 'EXCLUDE'
                       ELSE con.contype::text
                   END,
                   pg_get_constraintdef(con.oid)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(escSchema)' AND c.relname = '\(escTable)'
            ORDER BY con.contype, con.conname;
            """, database: state.database) {
            constraints = conRes.rows.compactMap { row in
                guard row.count >= 3, let name = row[0], let kind = row[1], let def = row[2] else { return nil }
                return ConstraintEntry(name: name, kind: kind, definition: def)
            }
        }
    }
}

// MARK: - Shared Wizard UI Components

private struct WizardTabButton: View {
    let title: String
    let badge: Int?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                        )
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.07) : (isHovering ? Color.primary.opacity(0.04) : .clear))
            }
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2.5)
                        .padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct WizardFormCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
        }
    }
}

struct WizardFormRow<Content: View>: View {
    let label: String
    var isInvalid: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12.5, weight: isInvalid ? .medium : .regular))
                .foregroundStyle(isInvalid ? Color.red : Color.primary)
            Spacer(minLength: 16)
            content()
        }
        .frame(minHeight: 38)
    }
}

struct WizardValidationBanner: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Icon(.alertCircle, size: 15, solid: true)
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
            Button(action: onClose) {
                Icon(.close, size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.red.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}
