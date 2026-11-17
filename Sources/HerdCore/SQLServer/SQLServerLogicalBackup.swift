import CosmoMSSQL
import CosmoSQLCore
import Foundation

// MARK: - Public models

/// Opções do backup lógico do SQL Server.
///
/// O resultado é um script `.sql` gravado no Mac, com schema e dados. É o
/// equivalente ao `pg_dump` do PostgreSQL: o arquivo pode ser restaurado em
/// qualquer SQL Server, sem depender de um caminho no servidor.
public struct SQLServerLogicalBackupOptions: Sendable {
    /// Inclui `INSERT`s com os dados. Desligue para gerar só o schema.
    public var includeData: Bool
    /// Inclui `DROP ... IF EXISTS` antes de cada objeto, tornando o script
    /// reexecutável contra um banco que já tenha os mesmos objetos.
    public var includeDropStatements: Bool
    /// Inclui índices e chaves estrangeiras.
    public var includeIndexes: Bool
    /// Inclui views, procedures, functions, triggers e synonyms.
    public var includeProgrammability: Bool
    /// Limita o backup a estas tabelas (`schema.tabela`). `nil` exporta o banco.
    public var tables: [String]?
    /// Linhas lidas por página e gravadas por `INSERT`.
    public var pageSize: Int
    public var insertBatchSize: Int

    public init(
        includeData: Bool = true,
        includeDropStatements: Bool = true,
        includeIndexes: Bool = true,
        includeProgrammability: Bool = true,
        tables: [String]? = nil,
        pageSize: Int = 500,
        insertBatchSize: Int = 100
    ) {
        self.includeData = includeData
        self.includeDropStatements = includeDropStatements
        self.includeIndexes = includeIndexes
        self.includeProgrammability = includeProgrammability
        self.tables = tables
        self.pageSize = max(1, min(pageSize, 5_000))
        self.insertBatchSize = max(1, min(insertBatchSize, 1_000))
    }
}

public struct SQLServerLogicalBackupProgress: Sendable {
    public var stage: String
    public var current: Int
    public var total: Int
    public var rows: Int
    public var bytes: Int64

    public init(stage: String, current: Int, total: Int, rows: Int, bytes: Int64) {
        self.stage = stage
        self.current = current
        self.total = total
        self.rows = rows
        self.bytes = bytes
    }
}

public struct SQLServerLogicalBackupResult: Sendable {
    public var url: URL
    public var tableCount: Int
    public var rowCount: Int
    public var bytes: Int64
    public var warnings: [String]
    public var duration: TimeInterval

    public init(
        url: URL,
        tableCount: Int,
        rowCount: Int,
        bytes: Int64,
        warnings: [String],
        duration: TimeInterval
    ) {
        self.url = url
        self.tableCount = tableCount
        self.rowCount = rowCount
        self.bytes = bytes
        self.warnings = warnings
        self.duration = duration
    }
}

public struct SQLServerScriptRestoreOptions: Sendable {
    /// Interrompe no primeiro erro. Quando `false`, continua e devolve avisos.
    public var stopOnError: Bool

    public init(stopOnError: Bool = true) {
        self.stopOnError = stopOnError
    }
}

public struct SQLServerScriptRestoreProgress: Sendable {
    public var batch: Int
    public var line: Int
    public var fraction: Double

    public init(batch: Int, line: Int, fraction: Double) {
        self.batch = batch
        self.line = line
        self.fraction = fraction
    }
}

public struct SQLServerScriptRestoreResult: Sendable {
    public var batchCount: Int
    public var warnings: [String]
    public var duration: TimeInterval

    public init(batchCount: Int, warnings: [String], duration: TimeInterval) {
        self.batchCount = batchCount
        self.warnings = warnings
        self.duration = duration
    }
}

// MARK: - Script splitter

/// Reconhece separadores de lote (`GO`) em scripts do SQL Server.
///
/// O `GO` não é T-SQL: é uma diretiva do SSMS/sqlcmd que separa lotes. Um
/// `CREATE PROCEDURE`, por exemplo, precisa ser o primeiro comando do lote.
public enum SQLServerScriptSplitter {
    public static func isBatchSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        guard trimmed.prefix(2).uppercased() == "GO" else { return false }
        let remainder = trimmed.dropFirst(2)
        guard let first = remainder.first else { return true }
        guard first.isWhitespace else { return false }
        let rest = remainder.drop(while: { $0.isWhitespace })
        return rest.isEmpty || rest.allSatisfy(\.isNumber)
    }

    /// Quantas vezes o lote deve ser repetido (`GO 3`). Devolve `nil` quando a
    /// linha não é um separador.
    public static func repeatCount(for line: String) -> Int? {
        guard isBatchSeparator(line) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = trimmed.dropFirst(2).drop(while: { $0.isWhitespace })
        guard !rest.isEmpty, let value = Int(rest) else { return 1 }
        return max(1, value)
    }
}

// MARK: - Catalog models

private struct LogicalTable {
    var objectID: Int
    var schema: String
    var name: String
    var temporalType: Int
    var columns: [LogicalColumn] = []
    var identityColumn: LogicalColumn?
    var primaryKey: LogicalIndex?
    var uniqueConstraints: [LogicalIndex] = []
    var indexes: [LogicalIndex] = []
    var foreignKeys: [LogicalForeignKey] = []
    var checks: [LogicalCheck] = []

    var qualified: String { LogicalSQL.quote(schema: schema, name: name) }
    var displayName: String { "\(schema).\(name)" }
}

private struct LogicalColumn {
    var columnID: Int
    var name: String
    var declaredType: String
    var baseType: String
    var isUserDefined: Bool
    var typeSchema: String?
    var maxLength: Int
    var precision: Int
    var scale: Int
    var isNullable: Bool
    var isIdentity: Bool
    var identitySeed: String?
    var identityIncrement: String?
    var isComputed: Bool
    var computedDefinition: String?
    var isPersisted: Bool
    var defaultDefinition: String?
    var defaultName: String?
    var collation: String?
    var isSparse: Bool
    var isColumnSet: Bool
    var isRowVersion: Bool
    var isEncrypted: Bool
    var generatedAlwaysType: Int

    var isInsertable: Bool {
        !isComputed && !isColumnSet && !isRowVersion && !isEncrypted
    }
}

private struct LogicalIndex {
    var indexID: Int
    var name: String
    var isPrimaryKey: Bool
    var isUniqueConstraint: Bool
    var isUnique: Bool
    var isClustered: Bool
    var keyColumns: [(name: String, descending: Bool)] = []
    var includedColumns: [String] = []
    var filter: String?

    var isConstraint: Bool { isPrimaryKey || isUniqueConstraint }
}

private struct LogicalForeignKey {
    var name: String
    var parentSchema: String
    var parentTable: String
    var referencedSchema: String
    var referencedTable: String
    var columns: [(parent: String, referenced: String)] = []
    var onDelete: String
    var onUpdate: String
    var isDisabled: Bool
    var isNotTrusted: Bool

    var parentQualified: String { LogicalSQL.quote(schema: parentSchema, name: parentTable) }
    var referencedQualified: String { LogicalSQL.quote(schema: referencedSchema, name: referencedTable) }
}

private struct LogicalCheck {
    var name: String
    var definition: String
    var isDisabled: Bool
    var isNotTrusted: Bool
}

private struct LogicalSequence {
    var schema: String
    var name: String
    var typeName: String
    var startValue: String
    var increment: String
    var minimumValue: String
    var maximumValue: String
    var isCycling: Bool
    var isCached: Bool
    var cacheSize: String?
    var currentValue: String?

    var qualified: String { LogicalSQL.quote(schema: schema, name: name) }
}

private struct LogicalModule {
    var objectID: Int
    var schema: String
    var name: String
    var type: String
    var definition: String
    var usesAnsiNulls: Bool
    var usesQuotedIdentifier: Bool
    var isDisabled: Bool
    var triggerTable: String?

    var qualified: String { LogicalSQL.quote(schema: schema, name: name) }
}

private struct LogicalSynonym {
    var schema: String
    var name: String
    var baseObject: String
}

private struct LogicalType {
    var schema: String
    var name: String
    var baseType: String
    var maxLength: Int
    var precision: Int
    var scale: Int
    var isNullable: Bool
}

// MARK: - Identifier helpers

private enum LogicalSQL {
    static func quote(_ name: String) -> String {
        "[" + name.replacingOccurrences(of: "]", with: "]]") + "]"
    }

    static func quote(schema: String, name: String) -> String {
        "\(quote(schema)).\(quote(name))"
    }

    static func literal(_ value: String) -> String {
        "N'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

// MARK: - Literal formatting

/// Converte valores decodificados do TDS em literais T-SQL.
///
/// Os formatadores são criados uma vez por backup: `DateFormatter` é caro e o
/// backup pode ter milhões de linhas.
private struct LogicalLiteralFormatter {
    private let dateFormatter: DateFormatter
    private let timeFormatter: DateFormatter
    private let timestampFormatter: DateFormatter

    init() {
        dateFormatter = Self.makeFormatter("yyyy-MM-dd")
        timeFormatter = Self.makeFormatter("HH:mm:ss.SSSSSSS")
        timestampFormatter = Self.makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSSSSS")
    }

    func literal(_ value: SQLValue, column: LogicalColumn) -> String {
        switch value {
        case .null:
            return "NULL"
        case .bool(let value):
            return value ? "1" : "0"
        case .int(let value):
            return String(value)
        case .int8(let value):
            return String(value)
        case .int16(let value):
            return String(value)
        case .int32(let value):
            return String(value)
        case .int64(let value):
            return String(value)
        case .float(let value):
            guard value.isFinite else { return "NULL" }
            return String(value)
        case .double(let value):
            guard value.isFinite else { return "NULL" }
            return String(value)
        case .decimal(let value):
            return NSDecimalNumber(decimal: value).stringValue
        case .string(let value):
            return stringLiteral(value, column: column)
        case .bytes(let bytes):
            return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
        case .uuid(let value):
            return "'\(value.uuidString.uppercased())'"
        case .date(let value):
            return dateLiteral(value, baseType: column.baseType)
        }
    }

    private func stringLiteral(_ value: String, column: LogicalColumn) -> String {
        // Um CHAR(0) quebra literais T-SQL. Nesses casos usamos o valor binário
        // e deixamos o servidor converter para o tipo da coluna.
        if value.contains("\0") {
            let base = column.baseType.lowercased()
            if base == "nvarchar" || base == "nchar" || base == "ntext" || base == "sysname" {
                var bytes: [UInt8] = []
                for unit in value.utf16 {
                    bytes.append(UInt8(unit & 0xFF))
                    bytes.append(UInt8((unit >> 8) & 0xFF))
                }
                return "CONVERT(\(column.declaredType), 0x\(hex(bytes)))"
            }
            return "CONVERT(\(column.declaredType), 0x\(hex(Array(value.utf8))))"
        }
        // Quebras de linha viram NCHAR(...) para que nenhuma linha do arquivo
        // pareça um separador de lote (GO) — inclusive dentro de um texto.
        if value.contains("\n") || value.contains("\r") {
            var pieces: [String] = []
            var current = ""
            var index = value.startIndex
            while index < value.endIndex {
                let character = value[index]
                if character == "\r" || character == "\n" {
                    pieces.append("N'" + current.replacingOccurrences(of: "'", with: "''") + "'")
                    current = ""
                    if character == "\r", value.index(after: index) < value.endIndex,
                       value[value.index(after: index)] == "\n" {
                        pieces.append("NCHAR(13) + NCHAR(10)")
                        index = value.index(index, offsetBy: 2)
                        continue
                    }
                    pieces.append(character == "\r" ? "NCHAR(13)" : "NCHAR(10)")
                } else {
                    current.append(character)
                }
                index = value.index(after: index)
            }
            pieces.append("N'" + current.replacingOccurrences(of: "'", with: "''") + "'")
            return pieces.joined(separator: " + ")
        }
        return "N'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func dateLiteral(_ value: Date, baseType: String) -> String {
        switch baseType.lowercased() {
        case "date":
            return "'\(dateFormatter.string(from: value))'"
        case "time":
            return "'\(timeFormatter.string(from: value))'"
        case "datetimeoffset":
            return "'\(timestampFormatter.string(from: value))+00:00'"
        case "smalldatetime":
            return "'\(timestampFormatter.string(from: value))'"
        default:
            return "'\(timestampFormatter.string(from: value))'"
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - File writer

private final class LogicalScriptWriter {
    private let handle: FileHandle
    private var buffer = ""
    private var writeError: Error?
    private(set) var bytes: Int64 = 0
    private let flushThreshold = 256 * 1024

    init(url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        guard manager.createFile(atPath: url.path, contents: nil) else {
            throw HerdError.file("Não foi possível criar \(url.path).")
        }
        handle = try FileHandle(forWritingTo: url)
        append("\u{FEFF}")
    }

    deinit {
        try? handle.close()
    }

    func append(_ text: String) {
        buffer += text
        if buffer.utf8.count >= flushThreshold {
            flush()
        }
    }

    func appendLine(_ text: String = "") {
        append(text + "\n")
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        let data = Data(buffer.utf8)
        do {
            try handle.write(contentsOf: data)
            bytes += Int64(data.count)
        } catch {
            writeError = error
        }
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws {
        flush()
        try handle.close()
        if let writeError {
            throw HerdError.file("Falha ao gravar o backup: \(writeError.localizedDescription)")
        }
    }
}

// MARK: - Line reader for restore

private final class LogicalScriptReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var reachedEOF = false
    private(set) var bytesRead: Int64 = 0
    let totalBytes: Int64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        totalBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    deinit {
        try? handle.close()
    }

    func nextLine() throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.last == 0x0D {
                    line = line.dropLast()
                }
                return String(decoding: line, as: UTF8.self)
            }
            if reachedEOF {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer.removeAll(keepingCapacity: false)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty {
                reachedEOF = true
            } else {
                bytesRead += Int64(chunk.count)
                buffer.append(chunk)
            }
        }
    }
}

// MARK: - Driver

public extension SQLServerDriver {

    /// Gera um backup lógico (`.sql`) do banco direto no Mac.
    ///
    /// O arquivo contém schemas, tipos, sequences, tabelas, dados, índices,
    /// chaves estrangeiras e objetos programáveis. O catálogo é lido com
    /// `sys.*`; os dados são lidos em páginas para não carregar a tabela inteira
    /// na memória.
    func exportLogicalBackup(
        database: String,
        to url: URL,
        options: SQLServerLogicalBackupOptions = SQLServerLogicalBackupOptions(),
        progress: (@Sendable (SQLServerLogicalBackupProgress) -> Void)? = nil
    ) async throws -> SQLServerLogicalBackupResult {
        let started = Date()
        let writer = try LogicalScriptWriter(url: url)
        let formatter = LogicalLiteralFormatter()

        let connection: MSSQLConnection
        do {
            connection = try await MSSQLConnection.connect(
                configuration: connectionConfiguration(database: database)
            )
        } catch {
            throw HerdError.connectionFailed(Self.describe(error))
        }
        defer { Task { try? await connection.close() } }

        do {
            progress?(SQLServerLogicalBackupProgress(
                stage: "Lendo catálogo",
                current: 0,
                total: 0,
                rows: 0,
                bytes: writer.bytes
            ))

            let catalog = try await readLogicalCatalog(
                connection: connection,
                database: database,
                options: options
            )

            try validateSupportedTypes(catalog.tables)

            let tableCount = catalog.tables.count
            var rowCount = 0
            let warnings = catalog.warnings
            let tableOnly = options.tables != nil

            // Cabeçalho
            writer.appendLine("-- herd — backup lógico do SQL Server")
            writer.appendLine("-- Banco: \(database)")
            writer.appendLine("-- Gerado em: \(ISO8601DateFormatter().string(from: Date()))")
            writer.appendLine("-- Tabelas: \(tableCount)")
            writer.appendLine("-- Restaure pelo herd (Backup e restore → Script .sql), pelo SSMS ou por sqlcmd.")
            writer.appendLine("--")
            writer.appendLine("-- Limitações deste formato: não inclui usuários, permissões, filegroups,")
            writer.appendLine("-- partições, full-text, índices de views nem estatísticas. Tabelas temporais")
            writer.appendLine("-- são exportadas como tabelas comuns.")
            if tableOnly {
                writer.appendLine("-- Este arquivo contém apenas as tabelas selecionadas.")
            }
            writer.appendLine()

            writer.appendLine("SET NOCOUNT ON;")
            writer.appendLine("SET XACT_ABORT ON;")
            writer.appendLine("SET QUOTED_IDENTIFIER ON;")
            writer.appendLine("SET ANSI_NULLS ON;")
            writer.appendLine("SET ANSI_PADDING ON;")
            writer.appendLine("SET ANSI_WARNINGS ON;")
            writer.appendLine("SET ARITHABORT ON;")
            writer.appendLine("SET CONCAT_NULL_YIELDS_NULL ON;")
            writer.appendLine("SET NUMERIC_ROUNDABORT OFF;")
            writer.appendLine("GO")
            writer.appendLine()

            // DROP
            if options.includeDropStatements {
                try writeDropSection(
                    writer: writer,
                    catalog: catalog,
                    includeProgrammability: options.includeProgrammability && !tableOnly,
                    dropTypesAndSequences: !tableOnly
                )
            }

            // Schemas
            try writeSchemaSection(writer: writer, catalog: catalog)

            // Tipos e sequences
            if !catalog.types.isEmpty {
                writer.appendLine("-- Tipos definidos pelo usuário")
                for type in catalog.types {
                    let qualified = LogicalSQL.quote(schema: type.schema, name: type.name)
                    let definition = "CREATE TYPE \(qualified) FROM " +
                        renderType(type.baseType, maxLength: type.maxLength, precision: type.precision, scale: type.scale)
                    writer.appendLine(
                        "IF TYPE_ID(N'\(type.schema).\(type.name)') IS NULL " +
                        "EXEC(N'\(definition.replacingOccurrences(of: "'", with: "''"))');"
                    )
                }
                writer.appendLine("GO")
                writer.appendLine()
            }

            if !catalog.sequences.isEmpty {
                writer.appendLine("-- Sequences")
                for sequence in catalog.sequences {
                    let definition = renderSequence(sequence).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                    writer.appendLine(
                        "IF OBJECT_ID(N'\(sequence.schema).\(sequence.name)', N'SO') IS NULL " +
                        "EXEC(N'\(definition.replacingOccurrences(of: "'", with: "''"))');"
                    )
                }
                for sequence in catalog.sequences {
                    if let current = sequence.currentValue,
                       let next = nextSequenceValue(current: current, increment: sequence.increment) {
                        writer.appendLine("ALTER SEQUENCE \(sequence.qualified) RESTART WITH \(next);")
                    }
                }
                writer.appendLine("GO")
                writer.appendLine()
            }

            // Tabelas
            for (index, table) in catalog.tables.enumerated() {
                try Task.checkCancellation()
                writer.appendLine("-- Tabela \(table.displayName)")
                if table.temporalType != 0 {
                    writer.appendLine("-- AVISO: tabela temporal exportada como tabela comum.")
                }
                writer.appendLine(renderCreateTable(table))
                writer.appendLine("GO")
                writer.appendLine()

                if let primaryKey = table.primaryKey {
                    writer.appendLine(renderConstraint(primaryKey, table: table))
                }
                for unique in table.uniqueConstraints {
                    writer.appendLine(renderConstraint(unique, table: table))
                }
                if !table.checks.isEmpty {
                    for check in table.checks {
                        writer.appendLine(renderCheck(check, table: table))
                    }
                }
                if table.primaryKey != nil || !table.uniqueConstraints.isEmpty || !table.checks.isEmpty {
                    writer.appendLine("GO")
                    writer.appendLine()
                }

                if options.includeData, !table.columns.filter(\.isInsertable).isEmpty {
                    progress?(SQLServerLogicalBackupProgress(
                        stage: "Exportando \(table.displayName)",
                        current: index,
                        total: tableCount,
                        rows: rowCount,
                        bytes: writer.bytes
                    ))
                    let rows = try await writeTableData(
                        connection: connection,
                        writer: writer,
                        table: table,
                        formatter: formatter,
                        options: options,
                        alreadyWritten: rowCount
                    ) { rowsSoFar in
                        progress?(SQLServerLogicalBackupProgress(
                            stage: "Exportando \(table.displayName)",
                            current: index,
                            total: tableCount,
                            rows: rowsSoFar,
                            bytes: writer.bytes
                        ))
                    }
                    rowCount += rows
                }

                // Índices comuns depois dos dados: carregar a tabela fica bem mais rápido.
                if options.includeIndexes, !table.indexes.isEmpty {
                    for index in table.indexes where !index.isConstraint {
                        writer.appendLine(renderIndex(index, table: table))
                    }
                    writer.appendLine("GO")
                    writer.appendLine()
                }
            }

            // Chaves estrangeiras
            let foreignKeys = includedForeignKeys(catalog)
            if options.includeIndexes, !foreignKeys.isEmpty {
                writer.appendLine("-- Chaves estrangeiras")
                for fk in foreignKeys {
                    writer.appendLine(renderForeignKey(fk))
                }
                writer.appendLine("GO")
                writer.appendLine()
            }

            // Objetos programáveis
            if options.includeProgrammability, !tableOnly {
                if !catalog.modules.isEmpty {
                    writer.appendLine("-- Views, funções, procedures e triggers")
                    for module in catalog.modules {
                        writer.appendLine("SET ANSI_NULLS \(module.usesAnsiNulls ? "ON" : "OFF");")
                        writer.appendLine("SET QUOTED_IDENTIFIER \(module.usesQuotedIdentifier ? "ON" : "OFF");")
                        writer.appendLine("GO")
                        writer.appendLine(normalizedModuleDefinition(module.definition))
                        writer.appendLine("GO")
                        if module.type == "TR", module.isDisabled, let triggerTable = module.triggerTable {
                            writer.appendLine(
                                "DISABLE TRIGGER \(module.qualified) ON \(triggerTable);"
                            )
                            writer.appendLine("GO")
                        }
                        writer.appendLine()
                    }
                }

                if !catalog.synonyms.isEmpty {
                    writer.appendLine("-- Synonyms")
                    for synonym in catalog.synonyms {
                        writer.appendLine(
                            "CREATE SYNONYM \(LogicalSQL.quote(schema: synonym.schema, name: synonym.name)) " +
                            "FOR \(synonym.baseObject);"
                        )
                    }
                    writer.appendLine("GO")
                    writer.appendLine()
                }
            }

            writer.appendLine("-- Fim do backup · \(rowCount) linha(s) em \(tableCount) tabela(s).")
            writer.appendLine("PRINT N'Backup lógico restaurado.';")
            writer.appendLine("GO")
            try writer.close()

            progress?(SQLServerLogicalBackupProgress(
                stage: "Concluído",
                current: tableCount,
                total: tableCount,
                rows: rowCount,
                bytes: writer.bytes
            ))

            return SQLServerLogicalBackupResult(
                url: url,
                tableCount: tableCount,
                rowCount: rowCount,
                bytes: writer.bytes,
                warnings: warnings,
                duration: Date().timeIntervalSince(started)
            )
        } catch {
            try? writer.close()
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if error is HerdError {
                throw error
            }
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    /// Restaura um script `.sql` local no banco informado.
    ///
    /// O arquivo é lido em streaming e dividido em lotes por `GO` (ou pelo fim
    /// do arquivo). O banco precisa existir.
    func restoreLogicalScript(
        database: String,
        from url: URL,
        options: SQLServerScriptRestoreOptions = SQLServerScriptRestoreOptions(),
        progress: (@Sendable (SQLServerScriptRestoreProgress) -> Void)? = nil
    ) async throws -> SQLServerScriptRestoreResult {
        let started = Date()
        let reader: LogicalScriptReader
        do {
            reader = try LogicalScriptReader(url: url)
        } catch {
            throw HerdError.file("Não foi possível ler \(url.path): \(error.localizedDescription)")
        }

        let connection: MSSQLConnection
        do {
            connection = try await MSSQLConnection.connect(
                configuration: connectionConfiguration(database: database)
            )
        } catch {
            throw HerdError.connectionFailed(Self.describe(error))
        }
        defer { Task { try? await connection.close() } }
        var batchLines: [String] = []
        var batchStartLine = 1
        var lineNumber = 0
        var batchCount = 0
        var warnings: [String] = []
        var firstLine = true

        do {
            while let rawLine = try reader.nextLine() {
                lineNumber += 1
                var line = rawLine
                if firstLine {
                    firstLine = false
                    if line.hasPrefix("\u{FEFF}") {
                        line.removeFirst()
                    }
                }

                if let repeatCount = SQLServerScriptSplitter.repeatCount(for: line) {
                    let batch = batchLines.joined(separator: "\n")
                    for _ in 0..<repeatCount {
                        if batch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                        batchCount += 1
                        let warning = try await executeRestoreBatch(
                            connection: connection,
                            batch: batch,
                            startLine: batchStartLine,
                            batchNumber: batchCount,
                            stopOnError: options.stopOnError,
                            fraction: reader.totalBytes > 0
                                ? min(1, Double(reader.bytesRead) / Double(reader.totalBytes))
                                : 0,
                            progress: progress
                        )
                        if let warning { warnings.append(warning) }
                    }
                    batchLines.removeAll(keepingCapacity: true)
                    batchStartLine = lineNumber + 1
                } else {
                    if batchLines.isEmpty {
                        batchStartLine = lineNumber
                    }
                    batchLines.append(line)
                }
            }

            if !batchLines.isEmpty {
                let batch = batchLines.joined(separator: "\n")
                if !batch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    batchCount += 1
                    let warning = try await executeRestoreBatch(
                        connection: connection,
                        batch: batch,
                        startLine: batchStartLine,
                        batchNumber: batchCount,
                        stopOnError: options.stopOnError,
                        fraction: 1,
                        progress: progress
                    )
                    if let warning { warnings.append(warning) }
                }
            }

            return SQLServerScriptRestoreResult(
                batchCount: batchCount,
                warnings: warnings,
                duration: Date().timeIntervalSince(started)
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if error is HerdError {
                throw error
            }
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    /// Executa um lote e devolve a mensagem de erro quando `stopOnError` está
    /// desligado. Lança quando o erro deve interromper o restore.
    private func executeRestoreBatch(
        connection: MSSQLConnection,
        batch: String,
        startLine: Int,
        batchNumber: Int,
        stopOnError: Bool,
        fraction: Double,
        progress: (@Sendable (SQLServerScriptRestoreProgress) -> Void)?
    ) async throws -> String? {
        do {
            _ = try await withTaskCancellationHandler {
                try await connection.query(batch, [])
            } onCancel: {
                Task { try? await connection.close() }
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            let message = "Linha \(startLine): \(Self.describe(error))"
            if stopOnError {
                throw HerdError.queryFailed(message)
            }
            progress?(SQLServerScriptRestoreProgress(
                batch: batchNumber,
                line: startLine,
                fraction: fraction
            ))
            return message
        }
        progress?(SQLServerScriptRestoreProgress(
            batch: batchNumber,
            line: startLine,
            fraction: fraction
        ))
        return nil
    }

    /// Cria um banco vazio. Usado pelo restore lógico quando o destino ainda
    /// não existe.
    func createDatabaseForRestore(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HerdError.queryFailed("Informe o nome do banco de destino.")
        }
        do {
            _ = try await queryRows(
                "CREATE DATABASE \(dialect.quote(trimmed));",
                database: config.maintenanceDatabase
            )
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    // MARK: - Catalog

    private struct Catalog {
        var tables: [LogicalTable]
        var sequences: [LogicalSequence]
        var modules: [LogicalModule]
        var synonyms: [LogicalSynonym]
        var types: [LogicalType]
        var schemas: [String]
        var warnings: [String]
    }

    private func readLogicalCatalog(
        connection: MSSQLConnection,
        database: String,
        options: SQLServerLogicalBackupOptions
    ) async throws -> Catalog {
        var warnings: [String] = []
        let tableFilter = options.tables.map { Set($0.map { $0.lowercased() }) }

        let tableRows = try await connection.query(
            """
            SELECT t.object_id, s.name, t.name, t.temporal_type
            FROM sys.tables t
            JOIN sys.schemas s ON s.schema_id = t.schema_id
            WHERE t.is_ms_shipped = 0
            ORDER BY s.name, t.name;
            """,
            []
        )

        var tables: [LogicalTable] = []
        for row in tableRows {
            guard row.values.count >= 4,
                  let objectID = SQLServerCellFormatter.int(row.values[0]).map(Int.init),
                  let schema = row.values[1].asString(),
                  let name = row.values[2].asString() else { continue }
            let qualified = "\(schema).\(name)".lowercased()
            if let tableFilter, !tableFilter.contains(qualified) { continue }
            tables.append(LogicalTable(
                objectID: objectID,
                schema: schema,
                name: name,
                temporalType: SQLServerCellFormatter.int(row.values[3]).map(Int.init) ?? 0
            ))
        }

        if tables.isEmpty, options.tables != nil {
            throw HerdError.queryFailed("A tabela selecionada não foi encontrada em \(database).")
        }

        let databaseCollation = try? await connection.query(
            "SELECT CONVERT(nvarchar(128), DATABASEPROPERTYEX(DB_NAME(), 'Collation'));",
            []
        ).first?.values.first?.asString()

        for index in tables.indices {
            let objectID = tables[index].objectID
            tables[index].columns = try await readColumns(
                connection: connection,
                objectID: objectID,
                databaseCollation: databaseCollation
            )
            tables[index].identityColumn = tables[index].columns.first(where: \.isIdentity)

            let indexes = try await readIndexes(connection: connection, objectID: objectID)
            tables[index].primaryKey = indexes.first(where: \.isPrimaryKey)
            tables[index].uniqueConstraints = indexes.filter(\.isUniqueConstraint)
            tables[index].indexes = indexes.filter { !$0.isConstraint }
            tables[index].foreignKeys = try await readForeignKeys(
                connection: connection,
                objectID: objectID
            )
            tables[index].checks = try await readChecks(connection: connection, objectID: objectID)

            if tables[index].temporalType != 0 {
                warnings.append("\(tables[index].displayName) é temporal e foi exportada como tabela comum.")
            }
        }

        let isTableOnly = options.tables != nil
        let sequences = try await readSequences(connection: connection)
        let types = try await readTypes(connection: connection)
        var modules: [LogicalModule] = []
        var synonyms: [LogicalSynonym] = []
        if options.includeProgrammability, !isTableOnly {
            let result = try await readModules(connection: connection)
            modules = result.modules
            warnings.append(contentsOf: result.warnings)
            synonyms = try await readSynonyms(connection: connection)
        }

        var schemaNames = Set<String>()
        tables.forEach { schemaNames.insert($0.schema) }
        types.forEach { schemaNames.insert($0.schema) }
        sequences.forEach { schemaNames.insert($0.schema) }
        modules.forEach { schemaNames.insert($0.schema) }
        synonyms.forEach { schemaNames.insert($0.schema) }
        schemaNames.remove("dbo")
        schemaNames.remove("sys")
        schemaNames.remove("guest")
        schemaNames.remove("INFORMATION_SCHEMA")

        return Catalog(
            tables: tables,
            sequences: sequences,
            modules: modules,
            synonyms: synonyms,
            types: types,
            schemas: schemaNames.sorted(),
            warnings: warnings
        )
    }

    private func readColumns(
        connection: MSSQLConnection,
        objectID: Int,
        databaseCollation: String?
    ) async throws -> [LogicalColumn] {
        let sql = """
            SELECT c.column_id, c.name,
                   ty.name AS declared_type,
                   ty.is_user_defined,
                   ts.name AS type_schema,
                   bt.name AS base_type,
                   c.max_length, c.precision, c.scale,
                   c.is_nullable, c.is_identity, c.is_computed,
                   c.is_column_set, c.is_sparse,
                   c.collation_name,
                   dc.definition AS default_definition,
                   dc.name AS default_name,
                   cc.definition AS computed_definition,
                   cc.is_persisted,
                   c.generated_always_type,
                   c.encryption_type,
                   CONVERT(bigint, ic.seed_value) AS identity_seed,
                   CONVERT(bigint, ic.increment_value) AS identity_increment
            FROM sys.columns c
            JOIN sys.types ty ON ty.user_type_id = c.user_type_id
            JOIN sys.types bt ON bt.user_type_id = c.system_type_id
            LEFT JOIN sys.schemas ts ON ts.schema_id = ty.schema_id
            LEFT JOIN sys.default_constraints dc
              ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
            LEFT JOIN sys.computed_columns cc
              ON cc.object_id = c.object_id AND cc.column_id = c.column_id
            LEFT JOIN sys.identity_columns ic
              ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE c.object_id = ?
            ORDER BY c.column_id;
            """
        let rows = try await connection.query(sql, [.int(objectID)])
        return rows.compactMap { row in
            guard row.values.count >= 22,
                  let columnID = SQLServerCellFormatter.int(row.values[0]).map(Int.init),
                  let name = row.values[1].asString(),
                  let declared = row.values[2].asString(),
                  let baseType = row.values[5].asString() else { return nil }

            let isUserDefined = SQLServerCellFormatter.bool(row.values[3]) ?? false
            let typeSchema = row.values[4].asString()
            let maxLength = Int(SQLServerCellFormatter.int(row.values[6]) ?? 0)
            let precision = Int(SQLServerCellFormatter.int(row.values[7]) ?? 0)
            let scale = Int(SQLServerCellFormatter.int(row.values[8]) ?? 0)
            let isNullable = SQLServerCellFormatter.bool(row.values[9]) ?? true
            let isIdentity = SQLServerCellFormatter.bool(row.values[10]) ?? false
            let isComputed = SQLServerCellFormatter.bool(row.values[11]) ?? false
            let isColumnSet = SQLServerCellFormatter.bool(row.values[12]) ?? false
            let isSparse = SQLServerCellFormatter.bool(row.values[13]) ?? false
            let rawCollation = row.values[14].asString()
            // COLLATE não é válido para tipos definidos pelo usuário, e a
            // collation padrão do banco já é aplicada automaticamente.
            let collation = isUserDefined || rawCollation?.caseInsensitiveCompare(databaseCollation ?? "") == .orderedSame
                ? nil
                : rawCollation
            let defaultDefinition = row.values[15].asString()
            let defaultName = row.values[16].asString()
            let computedDefinition = row.values[17].asString()
            let isPersisted = SQLServerCellFormatter.bool(row.values[18]) ?? false
            let generatedAlways = Int(SQLServerCellFormatter.int(row.values[19]) ?? 0)
            let isEncrypted = !row.values[20].isNull
            let identitySeed = SQLServerCellFormatter.int(row.values[21]).map(String.init)
            let identityIncrement = row.values.count > 22
                ? SQLServerCellFormatter.int(row.values[22]).map(String.init)
                : nil

            let isRowVersion = baseType.lowercased() == "timestamp" || baseType.lowercased() == "rowversion"

            return LogicalColumn(
                columnID: columnID,
                name: name,
                declaredType: renderColumnType(
                    declared: declared,
                    schema: typeSchema,
                    isUserDefined: isUserDefined,
                    base: baseType,
                    maxLength: maxLength,
                    precision: precision,
                    scale: scale
                ),
                baseType: baseType,
                isUserDefined: isUserDefined,
                typeSchema: typeSchema,
                maxLength: maxLength,
                precision: precision,
                scale: scale,
                isNullable: isNullable,
                isIdentity: isIdentity,
                identitySeed: identitySeed,
                identityIncrement: identityIncrement,
                isComputed: isComputed,
                computedDefinition: computedDefinition,
                isPersisted: isPersisted,
                defaultDefinition: defaultDefinition,
                defaultName: defaultName,
                collation: collation,
                isSparse: isSparse,
                isColumnSet: isColumnSet,
                isRowVersion: isRowVersion,
                isEncrypted: isEncrypted,
                generatedAlwaysType: generatedAlways
            )
        }
    }

    private func readIndexes(
        connection: MSSQLConnection,
        objectID: Int
    ) async throws -> [LogicalIndex] {
        let sql = """
            SELECT i.index_id, i.name, i.type,
                   i.is_unique, i.is_primary_key, i.is_unique_constraint,
                   i.has_filter, i.filter_definition,
                   c.name AS column_name,
                   ic.key_ordinal, ic.index_column_id,
                   ic.is_descending_key, ic.is_included_column
            FROM sys.indexes i
            JOIN sys.index_columns ic
              ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            JOIN sys.columns c
              ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE i.object_id = ?
              AND i.type IN (1, 2)
              AND i.is_hypothetical = 0
              AND i.name IS NOT NULL
            ORDER BY i.index_id, ic.is_included_column, ic.key_ordinal, ic.index_column_id;
            """
        let rows = try await connection.query(sql, [.int(objectID)])
        var grouped: [Int: LogicalIndex] = [:]
        var order: [Int] = []

        for row in rows {
            guard row.values.count >= 13,
                  let indexID = SQLServerCellFormatter.int(row.values[0]).map(Int.init),
                  let name = row.values[1].asString(),
                  let column = row.values[8].asString() else { continue }
            let isUnique = SQLServerCellFormatter.bool(row.values[3]) ?? false
            let isPrimary = SQLServerCellFormatter.bool(row.values[4]) ?? false
            let isUniqueConstraint = SQLServerCellFormatter.bool(row.values[5]) ?? false
            let hasFilter = SQLServerCellFormatter.bool(row.values[6]) ?? false
            let filter = row.values[7].asString()
            let keyOrdinal = Int(SQLServerCellFormatter.int(row.values[9]) ?? 0)
            let isDescending = SQLServerCellFormatter.bool(row.values[11]) ?? false
            let isIncluded = SQLServerCellFormatter.bool(row.values[12]) ?? false
            let isClustered = (SQLServerCellFormatter.int(row.values[2]) ?? 0) == 1

            if grouped[indexID] == nil {
                grouped[indexID] = LogicalIndex(
                    indexID: indexID,
                    name: name,
                    isPrimaryKey: isPrimary,
                    isUniqueConstraint: isUniqueConstraint,
                    isUnique: isUnique,
                    isClustered: isClustered,
                    filter: hasFilter ? filter : nil
                )
                order.append(indexID)
            }
            if isIncluded {
                grouped[indexID]?.includedColumns.append(column)
            } else if keyOrdinal > 0 {
                grouped[indexID]?.keyColumns.append((name: column, descending: isDescending))
            }
        }

        return order.compactMap { grouped[$0] }
    }

    private func readForeignKeys(
        connection: MSSQLConnection,
        objectID: Int
    ) async throws -> [LogicalForeignKey] {
        let sql = """
            SELECT fk.name, fk.is_disabled, fk.is_not_trusted,
                   fk.delete_referential_action_desc,
                   fk.update_referential_action_desc,
                   sp.name AS parent_schema, tp.name AS parent_table,
                   sr.name AS referenced_schema, tr.name AS referenced_table,
                   pc.name AS parent_column, rc.name AS referenced_column,
                   fkc.constraint_column_id
            FROM sys.foreign_keys fk
            JOIN sys.tables tp ON tp.object_id = fk.parent_object_id
            JOIN sys.schemas sp ON sp.schema_id = tp.schema_id
            JOIN sys.tables tr ON tr.object_id = fk.referenced_object_id
            JOIN sys.schemas sr ON sr.schema_id = tr.schema_id
            JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
            JOIN sys.columns pc
              ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
            JOIN sys.columns rc
              ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
            WHERE fk.parent_object_id = ?
            ORDER BY fk.name, fkc.constraint_column_id;
            """
        let rows = try await connection.query(sql, [.int(objectID)])
        var grouped: [String: LogicalForeignKey] = [:]
        var order: [String] = []

        for row in rows {
            guard row.values.count >= 12,
                  let name = row.values[0].asString(),
                  let parentSchema = row.values[5].asString(),
                  let parentTable = row.values[6].asString(),
                  let referencedSchema = row.values[7].asString(),
                  let referencedTable = row.values[8].asString(),
                  let parentColumn = row.values[9].asString(),
                  let referencedColumn = row.values[10].asString() else { continue }

            if grouped[name] == nil {
                grouped[name] = LogicalForeignKey(
                    name: name,
                    parentSchema: parentSchema,
                    parentTable: parentTable,
                    referencedSchema: referencedSchema,
                    referencedTable: referencedTable,
                    onDelete: row.values[3].asString() ?? "NO_ACTION",
                    onUpdate: row.values[4].asString() ?? "NO_ACTION",
                    isDisabled: SQLServerCellFormatter.bool(row.values[1]) ?? false,
                    isNotTrusted: SQLServerCellFormatter.bool(row.values[2]) ?? false
                )
                order.append(name)
            }
            grouped[name]?.columns.append((parent: parentColumn, referenced: referencedColumn))
        }

        return order.compactMap { grouped[$0] }
    }

    private func readChecks(
        connection: MSSQLConnection,
        objectID: Int
    ) async throws -> [LogicalCheck] {
        let sql = """
            SELECT cc.name, cc.definition, cc.is_disabled, cc.is_not_trusted
            FROM sys.check_constraints cc
            WHERE cc.parent_object_id = ? AND cc.is_ms_shipped = 0
            ORDER BY cc.name;
            """
        let rows = try await connection.query(sql, [.int(objectID)])
        return rows.compactMap { row in
            guard row.values.count >= 4,
                  let name = row.values[0].asString(),
                  let definition = row.values[1].asString() else { return nil }
            return LogicalCheck(
                name: name,
                definition: definition,
                isDisabled: SQLServerCellFormatter.bool(row.values[2]) ?? false,
                isNotTrusted: SQLServerCellFormatter.bool(row.values[3]) ?? false
            )
        }
    }

    private func readSequences(connection: MSSQLConnection) async throws -> [LogicalSequence] {
        let sql = """
            SELECT s.name, sc.name, t.name,
                   CONVERT(nvarchar(100), s.start_value),
                   CONVERT(nvarchar(100), s.increment),
                   CONVERT(nvarchar(100), s.minimum_value),
                   CONVERT(nvarchar(100), s.maximum_value),
                   s.is_cycling, s.is_cached,
                   CONVERT(nvarchar(100), s.cache_size),
                   CONVERT(nvarchar(100), s.current_value)
            FROM sys.sequences s
            JOIN sys.schemas sc ON sc.schema_id = s.schema_id
            JOIN sys.types t ON t.user_type_id = s.user_type_id
            WHERE s.is_ms_shipped = 0
            ORDER BY sc.name, s.name;
            """
        let rows = try await connection.query(sql, [])
        return rows.compactMap { row in
            guard row.values.count >= 11,
                  let name = row.values[0].asString(),
                  let schema = row.values[1].asString(),
                  let typeName = row.values[2].asString(),
                  let start = row.values[3].asString(),
                  let increment = row.values[4].asString(),
                  let minimum = row.values[5].asString(),
                  let maximum = row.values[6].asString() else { return nil }
            return LogicalSequence(
                schema: schema,
                name: name,
                typeName: typeName,
                startValue: start,
                increment: increment,
                minimumValue: minimum,
                maximumValue: maximum,
                isCycling: SQLServerCellFormatter.bool(row.values[7]) ?? false,
                isCached: SQLServerCellFormatter.bool(row.values[8]) ?? true,
                cacheSize: row.values[9].asString(),
                currentValue: row.values[10].asString()
            )
        }
    }

    private func readTypes(connection: MSSQLConnection) async throws -> [LogicalType] {
        let sql = """
            SELECT s.name, t.name, bt.name,
                   t.max_length, t.precision, t.scale, t.is_nullable
            FROM sys.types t
            JOIN sys.schemas s ON s.schema_id = t.schema_id
            JOIN sys.types bt ON bt.user_type_id = t.system_type_id
            WHERE t.is_user_defined = 1
              AND t.is_table_type = 0
              AND t.is_assembly_type = 0
              AND s.name NOT IN ('sys', 'INFORMATION_SCHEMA')
            ORDER BY s.name, t.name;
            """
        let rows = try await connection.query(sql, [])
        return rows.compactMap { row in
            guard row.values.count >= 7,
                  let schema = row.values[0].asString(),
                  let name = row.values[1].asString(),
                  let base = row.values[2].asString() else { return nil }
            return LogicalType(
                schema: schema,
                name: name,
                baseType: base,
                maxLength: Int(SQLServerCellFormatter.int(row.values[3]) ?? 0),
                precision: Int(SQLServerCellFormatter.int(row.values[4]) ?? 0),
                scale: Int(SQLServerCellFormatter.int(row.values[5]) ?? 0),
                isNullable: SQLServerCellFormatter.bool(row.values[6]) ?? true
            )
        }
    }

    private func readModules(
        connection: MSSQLConnection
    ) async throws -> (modules: [LogicalModule], warnings: [String]) {
        let sql = """
            SELECT o.object_id, s.name, o.name, o.type,
                   m.definition, m.uses_ansi_nulls, m.uses_quoted_identifier,
                   tr.is_disabled, tr.parent_id
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            JOIN sys.sql_modules m ON m.object_id = o.object_id
            LEFT JOIN sys.triggers tr ON tr.object_id = o.object_id
            WHERE o.is_ms_shipped = 0
              AND o.type IN ('V', 'P', 'FN', 'IF', 'TF', 'TR')
            ORDER BY s.name, o.name;
            """
        let rows = try await connection.query(sql, [])
        var modules: [LogicalModule] = []
        var warnings: [String] = []
        var triggerParents: [Int: Int] = [:]

        for row in rows {
            guard row.values.count >= 9,
                  let objectID = SQLServerCellFormatter.int(row.values[0]).map(Int.init),
                  let schema = row.values[1].asString(),
                  let name = row.values[2].asString(),
                  let rawType = row.values[3].asString() else { continue }
            let type = rawType.trimmingCharacters(in: .whitespaces)
            guard let definition = row.values[4].asString() else {
                warnings.append(
                    "A definição de \(schema).\(name) não pôde ser lida (objeto criptografado ou sem permissão VIEW DEFINITION)."
                )
                continue
            }
            let parentID = SQLServerCellFormatter.int(row.values[8]).map(Int.init)
            if let parentID { triggerParents[objectID] = parentID }
            modules.append(LogicalModule(
                objectID: objectID,
                schema: schema,
                name: name,
                type: type,
                definition: definition,
                usesAnsiNulls: SQLServerCellFormatter.bool(row.values[5]) ?? true,
                usesQuotedIdentifier: SQLServerCellFormatter.bool(row.values[6]) ?? true,
                isDisabled: SQLServerCellFormatter.bool(row.values[7]) ?? false,
                triggerTable: nil
            ))
        }

        if !triggerParents.isEmpty {
            let ids = triggerParents.values.map(String.init).joined(separator: ",")
            let names = try await connection.query(
                """
                SELECT t.object_id, s.name, t.name
                FROM sys.tables t
                JOIN sys.schemas s ON s.schema_id = t.schema_id
                WHERE t.object_id IN (\(ids));
                """,
                []
            )
            var tableNames: [Int: String] = [:]
            for row in names {
                guard row.values.count >= 3,
                      let objectID = SQLServerCellFormatter.int(row.values[0]).map(Int.init),
                      let schema = row.values[1].asString(),
                      let table = row.values[2].asString() else { continue }
                tableNames[objectID] = "\(schema).\(table)"
            }
            for index in modules.indices {
                if let parentID = triggerParents[modules[index].objectID],
                   let table = tableNames[parentID] {
                    let parts = table.split(separator: ".", maxSplits: 1).map(String.init)
                    modules[index].triggerTable = parts.count == 2
                        ? LogicalSQL.quote(schema: parts[0], name: parts[1])
                        : table
                }
            }
        }

        let ordered = try await orderModulesByDependency(modules, connection: connection)
        return (ordered, warnings)
    }

    private func readSynonyms(connection: MSSQLConnection) async throws -> [LogicalSynonym] {
        let sql = """
            SELECT s.name, sy.name, sy.base_object_name
            FROM sys.synonyms sy
            JOIN sys.schemas s ON s.schema_id = sy.schema_id
            WHERE sy.is_ms_shipped = 0
            ORDER BY s.name, sy.name;
            """
        let rows = try await connection.query(sql, [])
        return rows.compactMap { row in
            guard row.values.count >= 3,
                  let schema = row.values[0].asString(),
                  let name = row.values[1].asString(),
                  let base = row.values[2].asString() else { return nil }
            return LogicalSynonym(schema: schema, name: name, baseObject: base)
        }
    }

    /// Ordena views e funções pelas dependências para que uma view que usa
    /// outra seja criada depois dela.
    private func orderModulesByDependency(
        _ modules: [LogicalModule],
        connection: MSSQLConnection
    ) async throws -> [LogicalModule] {
        let candidates = modules.filter { ["V", "FN", "IF", "TF"].contains($0.type) }
        guard candidates.count > 1 else { return modules }

        let idList = candidates.map { String($0.objectID) }.joined(separator: ",")
        let rows = try await connection.query(
            """
            SELECT d.referencing_id, d.referenced_id
            FROM sys.sql_expression_dependencies d
            WHERE d.referenced_id IS NOT NULL
              AND d.referencing_id IN (\(idList))
              AND d.referenced_id IN (\(idList));
            """,
            []
        )
        var dependencies: [Int: Set<Int>] = [:]
        for row in rows {
            guard row.values.count >= 2,
                  let referencing = SQLServerCellFormatter.int(row.values[0]).map(Int.init),
                  let referenced = SQLServerCellFormatter.int(row.values[1]).map(Int.init) else { continue }
            dependencies[referencing, default: []].insert(referenced)
        }

        var ordered: [LogicalModule] = []
        var remaining = candidates
        while !remaining.isEmpty {
            var progress = false
            var index = 0
            while index < remaining.count {
                let module = remaining[index]
                let pending = dependencies[module.objectID] ?? []
                let ready = pending.allSatisfy { dependency in
                    !remaining.contains(where: { $0.objectID == dependency })
                }
                if ready {
                    ordered.append(module)
                    remaining.remove(at: index)
                    progress = true
                } else {
                    index += 1
                }
            }
            if !progress {
                // Ciclo (possível com schemabinding): mantém a ordem original.
                ordered.append(contentsOf: remaining)
                remaining.removeAll()
            }
        }

        let others = modules.filter { !["V", "FN", "IF", "TF"].contains($0.type) }
        return ordered + others
    }

    // MARK: - Validation

    private func validateSupportedTypes(_ tables: [LogicalTable]) throws {
        var unsupported: [String] = []
        for table in tables {
            for column in table.columns {
                if column.isEncrypted {
                    unsupported.append("\(table.displayName).\(column.name) (Always Encrypted)")
                    continue
                }
                let base = column.baseType.lowercased()
                if ["sql_variant", "hierarchyid", "geometry", "geography", "vector", "json"].contains(base) {
                    unsupported.append("\(table.displayName).\(column.name) (\(base))")
                }
            }
        }
        guard unsupported.isEmpty else {
            let list = unsupported.prefix(8).joined(separator: ", ")
            let extra = unsupported.count > 8 ? " e mais \(unsupported.count - 8)" : ""
            throw HerdError.queryFailed(
                "Estas colunas usam tipos que o backup lógico ainda não exporta: \(list)\(extra). " +
                "Use o backup nativo (.bak) para este banco."
            )
        }
    }

    // MARK: - Rendering

    private func renderColumnType(
        declared: String,
        schema: String?,
        isUserDefined: Bool,
        base: String,
        maxLength: Int,
        precision: Int,
        scale: Int
    ) -> String {
        if isUserDefined {
            return LogicalSQL.quote(schema: schema ?? "dbo", name: declared)
        }
        return renderType(base, maxLength: maxLength, precision: precision, scale: scale)
    }

    private func renderType(_ base: String, maxLength: Int, precision: Int, scale: Int) -> String {
        switch base.lowercased() {
        case "varchar", "char", "varbinary", "binary":
            return maxLength == -1 ? "\(base)(max)" : "\(base)(\(maxLength))"
        case "nvarchar", "nchar":
            return maxLength == -1 ? "\(base)(max)" : "\(base)(\(maxLength / 2))"
        case "decimal", "numeric":
            return "\(base)(\(precision),\(scale))"
        case "datetime2", "time", "datetimeoffset":
            return "\(base)(\(scale))"
        case "float":
            return precision == 53 ? "float" : "float(\(precision))"
        case "sysname":
            return "nvarchar(128)"
        case "timestamp":
            return "rowversion"
        default:
            return base
        }
    }

    private func renderCreateTable(_ table: LogicalTable) -> String {
        var lines: [String] = []
        for column in table.columns {
            if column.isComputed {
                let expression = column.computedDefinition ?? "NULL"
                let persisted = column.isPersisted ? " PERSISTED" : ""
                lines.append("    \(LogicalSQL.quote(column.name)) AS \(expression)\(persisted)")
                continue
            }
            if column.isColumnSet {
                lines.append("    \(LogicalSQL.quote(column.name)) xml COLUMN_SET FOR ALL_SPARSE_COLUMNS")
                continue
            }

            var parts = [LogicalSQL.quote(column.name), column.declaredType]
            if let collation = column.collation {
                parts.append("COLLATE \(collation)")
            }
            if column.isIdentity {
                let seed = column.identitySeed ?? "1"
                let increment = column.identityIncrement ?? "1"
                parts.append("IDENTITY(\(seed),\(increment))")
            }
            // SPARSE vem antes da nulabilidade; colunas sparse não aceitam
            // DEFAULT nem IDENTITY no SQL Server.
            if column.isSparse {
                parts.append("SPARSE")
            }
            parts.append(column.isNullable ? "NULL" : "NOT NULL")
            if let defaultDefinition = column.defaultDefinition {
                if let name = column.defaultName {
                    parts.append("CONSTRAINT \(LogicalSQL.quote(name)) DEFAULT \(defaultDefinition)")
                } else {
                    parts.append("DEFAULT \(defaultDefinition)")
                }
            }
            // Colunas de tabelas temporais são exportadas como colunas comuns,
            // por isso GENERATED ALWAYS AS ROW START/END não é reproduzido.
            lines.append("    " + parts.joined(separator: " "))
        }

        return "CREATE TABLE \(table.qualified) (\n" + lines.joined(separator: ",\n") + "\n);"
    }

    private func renderConstraint(_ index: LogicalIndex, table: LogicalTable) -> String {
        let kind = index.isPrimaryKey ? "PRIMARY KEY" : "UNIQUE"
        let clustering = index.isClustered ? "CLUSTERED" : "NONCLUSTERED"
        let columns = index.keyColumns
            .map { "\(LogicalSQL.quote($0.name)) \($0.descending ? "DESC" : "ASC")" }
            .joined(separator: ", ")
        return "ALTER TABLE \(table.qualified) ADD CONSTRAINT \(LogicalSQL.quote(index.name)) " +
            "\(kind) \(clustering) (\(columns));"
    }

    private func renderIndex(_ index: LogicalIndex, table: LogicalTable) -> String {
        let unique = index.isUnique ? "UNIQUE " : ""
        let clustering = index.isClustered ? "CLUSTERED" : "NONCLUSTERED"
        let columns = index.keyColumns
            .map { "\(LogicalSQL.quote($0.name)) \($0.descending ? "DESC" : "ASC")" }
            .joined(separator: ", ")
        var sql = "CREATE \(unique)\(clustering) INDEX \(LogicalSQL.quote(index.name)) " +
            "ON \(table.qualified) (\(columns))"
        if !index.includedColumns.isEmpty {
            let included = index.includedColumns.map(LogicalSQL.quote).joined(separator: ", ")
            sql += " INCLUDE (\(included))"
        }
        if let filter = index.filter, !filter.isEmpty {
            sql += " WHERE \(filter)"
        }
        return sql + ";"
    }

    private func renderCheck(_ check: LogicalCheck, table: LogicalTable) -> String {
        let withCheck = check.isNotTrusted ? "WITH NOCHECK" : "WITH CHECK"
        var sql = "ALTER TABLE \(table.qualified) \(withCheck) ADD CONSTRAINT " +
            "\(LogicalSQL.quote(check.name)) CHECK \(check.definition);"
        if check.isDisabled {
            sql += "\nALTER TABLE \(table.qualified) NOCHECK CONSTRAINT \(LogicalSQL.quote(check.name));"
        }
        return sql
    }

    private func renderForeignKey(_ fk: LogicalForeignKey) -> String {
        let columns = fk.columns.map { LogicalSQL.quote($0.parent) }.joined(separator: ", ")
        let referenced = fk.columns.map { LogicalSQL.quote($0.referenced) }.joined(separator: ", ")
        let withCheck = fk.isNotTrusted ? "WITH NOCHECK" : "WITH CHECK"
        var sql = "ALTER TABLE \(fk.parentQualified) \(withCheck) ADD CONSTRAINT " +
            "\(LogicalSQL.quote(fk.name)) FOREIGN KEY (\(columns)) " +
            "REFERENCES \(fk.referencedQualified) (\(referenced))"
        if fk.onDelete != "NO_ACTION" {
            sql += " ON DELETE \(fk.onDelete.replacingOccurrences(of: "_", with: " "))"
        }
        if fk.onUpdate != "NO_ACTION" {
            sql += " ON UPDATE \(fk.onUpdate.replacingOccurrences(of: "_", with: " "))"
        }
        sql += ";"
        if fk.isDisabled {
            sql += "\nALTER TABLE \(fk.parentQualified) NOCHECK CONSTRAINT \(LogicalSQL.quote(fk.name));"
        }
        return sql
    }

    private func renderSequence(_ sequence: LogicalSequence) -> String {
        var sql = "CREATE SEQUENCE \(sequence.qualified) AS \(sequence.typeName)" +
            " START WITH \(sequence.startValue)" +
            " INCREMENT BY \(sequence.increment)" +
            " MINVALUE \(sequence.minimumValue)" +
            " MAXVALUE \(sequence.maximumValue)"
        sql += sequence.isCycling ? " CYCLE" : " NO CYCLE"
        if sequence.isCached {
            sql += " CACHE"
            if let size = sequence.cacheSize, size != "0" {
                sql += " \(size)"
            }
        } else {
            sql += " NO CACHE"
        }
        return sql + ";"
    }

    private func nextSequenceValue(current: String, increment: String) -> String? {
        guard let currentValue = Decimal(string: current, locale: Locale(identifier: "en_US_POSIX")),
              let incrementValue = Decimal(string: increment, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return NSDecimalNumber(decimal: currentValue + incrementValue).stringValue
    }

    private func normalizedModuleDefinition(_ definition: String) -> String {
        var text = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = text.uppercased()
        if upper.hasPrefix("CREATE OR ALTER") {
            text = "CREATE" + text.dropFirst("CREATE OR ALTER".count)
        } else if upper.hasPrefix("ALTER ") {
            text = "CREATE" + text.dropFirst("ALTER".count)
        }
        return text
    }

    // MARK: - Sections

    /// Só recria (e só remove) FKs cujas duas pontas estão no backup.
    /// Num backup de tabela única, uma FK para outra tabela seria inválida.
    private func includedForeignKeys(_ catalog: Catalog) -> [LogicalForeignKey] {
        let selected = Set(catalog.tables.map { "\($0.schema).\($0.name)".lowercased() })
        return catalog.tables.flatMap(\.foreignKeys).filter { fk in
            selected.contains("\(fk.parentSchema).\(fk.parentTable)".lowercased()) &&
            selected.contains("\(fk.referencedSchema).\(fk.referencedTable)".lowercased())
        }
    }

    private func writeDropSection(
        writer: LogicalScriptWriter,
        catalog: Catalog,
        includeProgrammability: Bool,
        dropTypesAndSequences: Bool
    ) throws {
        writer.appendLine("-- Remove os objetos que este arquivo recria")
        if includeProgrammability {
            for module in catalog.modules.reversed() {
                switch module.type {
                case "V":
                    writer.appendLine(
                        "IF OBJECT_ID(N'\(module.schema).\(module.name)', N'V') IS NOT NULL " +
                        "DROP VIEW \(module.qualified);"
                    )
                case "P":
                    writer.appendLine(
                        "IF OBJECT_ID(N'\(module.schema).\(module.name)', N'P') IS NOT NULL " +
                        "DROP PROCEDURE \(module.qualified);"
                    )
                case "FN", "IF", "TF":
                    writer.appendLine(
                        "IF OBJECT_ID(N'\(module.schema).\(module.name)') IS NOT NULL " +
                        "DROP FUNCTION \(module.qualified);"
                    )
                case "TR":
                    writer.appendLine(
                        "IF OBJECT_ID(N'\(module.schema).\(module.name)', N'TR') IS NOT NULL " +
                        "DROP TRIGGER \(module.qualified);"
                    )
                default:
                    break
                }
            }
            for synonym in catalog.synonyms.reversed() {
                writer.appendLine(
                    "IF OBJECT_ID(N'\(synonym.schema).\(synonym.name)', N'SN') IS NOT NULL " +
                    "DROP SYNONYM \(LogicalSQL.quote(schema: synonym.schema, name: synonym.name));"
                )
            }
        }

        let foreignKeys = includedForeignKeys(catalog)
        for fk in foreignKeys {
            writer.appendLine(
                "IF OBJECT_ID(N'\(fk.parentSchema).\(fk.name)', N'F') IS NOT NULL " +
                "ALTER TABLE \(fk.parentQualified) DROP CONSTRAINT \(LogicalSQL.quote(fk.name));"
            )
        }
        if !foreignKeys.isEmpty { writer.appendLine("GO") }

        for table in catalog.tables.reversed() {
            writer.appendLine("DROP TABLE IF EXISTS \(table.qualified);")
        }
        if dropTypesAndSequences {
            for sequence in catalog.sequences.reversed() {
                writer.appendLine("DROP SEQUENCE IF EXISTS \(sequence.qualified);")
            }
            for type in catalog.types.reversed() {
                writer.appendLine("DROP TYPE IF EXISTS \(LogicalSQL.quote(schema: type.schema, name: type.name));")
            }
        }
        writer.appendLine("GO")
        writer.appendLine()
    }

    private func writeSchemaSection(writer: LogicalScriptWriter, catalog: Catalog) throws {
        guard !catalog.schemas.isEmpty else { return }
        writer.appendLine("-- Schemas")
        for schema in catalog.schemas {
            writer.appendLine(
                "IF SCHEMA_ID(N'\(schema.replacingOccurrences(of: "'", with: "''"))') IS NULL " +
                "EXEC(N'CREATE SCHEMA \(LogicalSQL.quote(schema)) AUTHORIZATION [dbo]');"
            )
        }
        writer.appendLine("GO")
        writer.appendLine()
    }

    // MARK: - Data

    /// Grava os dados de uma tabela e devolve quantas linhas foram escritas.
    private func writeTableData(
        connection: MSSQLConnection,
        writer: LogicalScriptWriter,
        table: LogicalTable,
        formatter: LogicalLiteralFormatter,
        options: SQLServerLogicalBackupOptions,
        alreadyWritten: Int,
        progress: (Int) -> Void
    ) async throws -> Int {
        let columns = table.columns.filter(\.isInsertable)
        guard !columns.isEmpty else { return 0 }

        let columnList = columns.map { LogicalSQL.quote($0.name) }.joined(separator: ", ")
        let identity = columns.contains(where: \.isIdentity)
        let keyColumns = table.primaryKey?.keyColumns ?? []
        let pagination = paginationPlan(for: table, columns: columns, keyColumns: keyColumns)

        var keyValues: [SQLValue]? = nil
        var offset = 0
        var total = 0
        var pendingValues: [String] = []
        var pendingRows = 0
        var wroteIdentityInsert = false
        var lastProgressAt = Date.distantPast

        func flush() {
            guard !pendingValues.isEmpty else { return }
            writer.appendLine("INSERT INTO \(table.qualified) (\(columnList)) VALUES")
            writer.appendLine(pendingValues.joined(separator: ",\n") + ";")
            writer.appendLine("GO")
            pendingValues.removeAll(keepingCapacity: true)
            pendingRows = 0
        }

        while true {
            try Task.checkCancellation()
            let rows: [SQLRow]
            switch pagination {
            case .keyset:
                rows = try await fetchKeyedPage(
                    connection: connection,
                    table: table,
                    columns: columns,
                    keyColumns: keyColumns,
                    keyValues: keyValues,
                    pageSize: options.pageSize
                )
            case .offset:
                rows = try await fetchOffsetPage(
                    connection: connection,
                    table: table,
                    columns: columns,
                    offset: offset,
                    pageSize: options.pageSize
                )
            }

            if rows.isEmpty { break }

            if identity, !wroteIdentityInsert {
                writer.appendLine("SET IDENTITY_INSERT \(table.qualified) ON;")
                writer.appendLine("GO")
                wroteIdentityInsert = true
            }

            for row in rows {
                let values = row.values.enumerated().map { index, value in
                    formatter.literal(value, column: columns[index])
                }
                pendingValues.append("(" + values.joined(separator: ", ") + ")")
                pendingRows += 1
                if pendingRows >= options.insertBatchSize {
                    flush()
                }
            }

            total += rows.count
            let now = Date()
            if now.timeIntervalSince(lastProgressAt) >= 0.15 {
                lastProgressAt = now
                progress(alreadyWritten + total)
            }

            if pagination == .keyset {
                keyValues = keyColumns.indices.map { rows[rows.count - 1].values[$0] }
            } else {
                offset += rows.count
            }

            if rows.count < options.pageSize { break }
        }

        flush()
        progress(alreadyWritten + total)
        if wroteIdentityInsert {
            writer.appendLine("SET IDENTITY_INSERT \(table.qualified) OFF;")
            writer.appendLine("GO")
        }
        if total == 0 {
            writer.appendLine("-- \(table.displayName): sem linhas.")
        } else {
            writer.appendLine("-- \(table.displayName): \(total) linha(s).")
        }
        writer.appendLine("GO")
        writer.appendLine()
        return total
    }

    private enum PaginationPlan {
        case keyset
        case offset
    }

    private func paginationPlan(
        for table: LogicalTable,
        columns: [LogicalColumn],
        keyColumns: [(name: String, descending: Bool)]
    ) -> PaginationPlan {
        guard !keyColumns.isEmpty else { return .offset }
        let insertableNames = Set(columns.map { $0.name.lowercased() })
        let allInsertable = keyColumns.allSatisfy { insertableNames.contains($0.name.lowercased()) }
        return allInsertable ? .keyset : .offset
    }

    private func fetchKeyedPage(
        connection: MSSQLConnection,
        table: LogicalTable,
        columns: [LogicalColumn],
        keyColumns: [(name: String, descending: Bool)],
        keyValues: [SQLValue]?,
        pageSize: Int
    ) async throws -> [SQLRow] {
        let select = columns.map(selectExpression).joined(separator: ", ")
        let order = keyColumns
            .map { "\(LogicalSQL.quote($0.name)) \($0.descending ? "DESC" : "ASC")" }
            .joined(separator: ", ")

        var sql = "SELECT TOP (@p1) \(select) FROM \(table.qualified)"
        var binds: [SQLValue] = [.int(pageSize)]

        if let keyValues, keyValues.count == keyColumns.count {
            var predicates: [String] = []
            for index in keyColumns.indices {
                var parts: [String] = []
                for prefix in 0..<index {
                    parts.append("\(LogicalSQL.quote(keyColumns[prefix].name)) = @p\(prefix + 2)")
                }
                let comparison = keyColumns[index].descending ? "<" : ">"
                parts.append("\(LogicalSQL.quote(keyColumns[index].name)) \(comparison) @p\(index + 2)")
                predicates.append("(" + parts.joined(separator: " AND ") + ")")
            }
            sql += "\nWHERE " + predicates.joined(separator: " OR ")
            binds.append(contentsOf: keyValues)
        }

        sql += "\nORDER BY \(order);"
        return try await safeQuery(connection, sql, binds: binds)
    }

    private func fetchOffsetPage(
        connection: MSSQLConnection,
        table: LogicalTable,
        columns: [LogicalColumn],
        offset: Int,
        pageSize: Int
    ) async throws -> [SQLRow] {
        let select = columns.map(selectExpression).joined(separator: ", ")
        let sql = """
            SELECT \(select)
            FROM \(table.qualified)
            ORDER BY (SELECT NULL)
            OFFSET \(offset) ROWS FETCH NEXT \(pageSize) ROWS ONLY;
            """
        return try await safeQuery(connection, sql, binds: [])
    }

    /// O driver TDS não decodifica `xml`; pedimos ao servidor o texto para não
    /// perder a coluna.
    private func selectExpression(_ column: LogicalColumn) -> String {
        let quoted = LogicalSQL.quote(column.name)
        if column.baseType.lowercased() == "xml" {
            return "CONVERT(nvarchar(max), \(quoted)) AS \(quoted)"
        }
        return quoted
    }

    private func safeQuery(
        _ connection: MSSQLConnection,
        _ sql: String,
        binds: [SQLValue]
    ) async throws -> [SQLRow] {
        do {
            return try await withTaskCancellationHandler {
                try await connection.query(sql, binds)
            } onCancel: {
                Task { try? await connection.close() }
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw HerdError.queryFailed(Self.describe(error))
        }
    }
}
