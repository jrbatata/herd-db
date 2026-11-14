import Foundation

// MARK: - Suggestions

public enum SQLCompletionKind: String, Equatable, Sendable {
    case schema
    case table
    case view
    case column
    case snippet
    case keyword
}

public struct SQLCompletionItem: Identifiable, Hashable, Sendable {
    public var kind: SQLCompletionKind
    public var title: String
    public var insertText: String
    public var detail: String?
    /// UTF-16 offset from the start of `insertText` where the caret should land.
    public var caretOffset: Int?

    public var id: String { "\(kind.rawValue)|\(title)|\(insertText)|\(detail ?? "")" }

    public init(
        kind: SQLCompletionKind,
        title: String,
        insertText: String,
        detail: String? = nil,
        caretOffset: Int? = nil
    ) {
        self.kind = kind
        self.title = title
        self.insertText = insertText
        self.detail = detail
        self.caretOffset = caretOffset
    }
}

public struct SQLCompletionContext: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Right after `qualifier.`; suggestions are members of that qualifier.
        case member(qualifier: String)
        /// Right after FROM/JOIN/INTO/UPDATE/TABLE.
        case tableName
        /// A regular identifier anywhere else.
        case general
    }

    public var kind: Kind
    public var prefix: String
    /// UTF-16 range of the typed prefix that must be replaced on insertion.
    public var replacementRange: NSRange

    public init(kind: Kind, prefix: String, replacementRange: NSRange) {
        self.kind = kind
        self.prefix = prefix
        self.replacementRange = replacementRange
    }
}

// MARK: - Engine

/// Lightweight, single-pass SQL context parser used by the editor's completion popup.
/// It understands `schema.`/`alias.` members, table positions after FROM/JOIN and
/// the aliases declared in the current command.
public enum SQLCompletionEngine {
    private struct TableReference {
        var schema: String?
        var table: String
        var alias: String?
    }

    private static let tableIntroducers: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE"]

    private static let reservedAliases: Set<String> = [
        "WHERE", "JOIN", "ON", "GROUP", "ORDER", "LIMIT", "OFFSET", "SET", "VALUES",
        "RETURNING", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "UNION",
        "INTERSECT", "EXCEPT", "USING", "AS", "AND", "OR", "HAVING", "WINDOW",
        "LATERAL", "FETCH", "FOR", "NATURAL", "WITH",
    ]

    private static let tableReferenceRegex = try! NSRegularExpression(
        pattern: #"(?is)\b(?:FROM|JOIN|UPDATE|INTO)\s+((?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*)(?:\s*\.\s*(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*))?)(?:\s+(?:AS\s+)?([A-Za-z_][A-Za-z0-9_$]*))?"#,
        options: []
    )

    // MARK: Context

    public static func context(
        in sql: String,
        at cursor: Int,
        allowEmptyPrefix: Bool = false
    ) -> SQLCompletionContext? {
        let ns = sql as NSString
        let length = ns.length
        guard cursor >= 0, cursor <= length else { return nil }
        guard !isInsideLiteralOrComment(sql, cursor: cursor) else { return nil }

        let units = Array(sql.utf16)
        var start = cursor
        while start > 0, isIdentifierUnit(units[start - 1]) { start -= 1 }
        let prefix = ns.substring(with: NSRange(location: start, length: cursor - start))
        let replacement = NSRange(location: start, length: cursor - start)

        // schema. / alias. / table.
        if start > 0, units[start - 1] == ascii(".") {
            var qualifierEnd = start - 1
            while qualifierEnd > 0, isWhitespace(units[qualifierEnd - 1]) { qualifierEnd -= 1 }

            var qualifierStart = qualifierEnd
            if qualifierEnd > 0, units[qualifierEnd - 1] == ascii("\"") {
                var index = qualifierEnd - 2
                while index >= 0 {
                    if units[index] == ascii("\"") {
                        if index > 0, units[index - 1] == ascii("\"") {
                            index -= 2
                            continue
                        }
                        qualifierStart = index
                        break
                    }
                    index -= 1
                }
            } else {
                while qualifierStart > 0, isIdentifierUnit(units[qualifierStart - 1]) {
                    qualifierStart -= 1
                }
            }

            guard qualifierStart < qualifierEnd else { return nil }
            var qualifier = ns.substring(
                with: NSRange(location: qualifierStart, length: qualifierEnd - qualifierStart)
            )
            if qualifier.hasPrefix("\""), qualifier.hasSuffix("\""), qualifier.count >= 2 {
                qualifier.removeFirst()
                qualifier.removeLast()
                qualifier = qualifier.replacingOccurrences(of: "\"\"", with: "\"")
            }

            return SQLCompletionContext(
                kind: .member(qualifier: qualifier),
                prefix: prefix,
                replacementRange: replacement
            )
        }

        // Word before the prefix, to detect FROM/JOIN/... positions.
        var wordEnd = start
        while wordEnd > 0, isWhitespace(units[wordEnd - 1]) { wordEnd -= 1 }
        var wordStart = wordEnd
        while wordStart > 0, isIdentifierUnit(units[wordStart - 1]) { wordStart -= 1 }
        let previousWord = wordStart < wordEnd
            ? ns.substring(with: NSRange(location: wordStart, length: wordEnd - wordStart)).uppercased()
            : ""

        if tableIntroducers.contains(previousWord) {
            return SQLCompletionContext(kind: .tableName, prefix: prefix, replacementRange: replacement)
        }

        guard allowEmptyPrefix || !prefix.isEmpty else { return nil }
        return SQLCompletionContext(kind: .general, prefix: prefix, replacementRange: replacement)
    }

    // MARK: Suggestions

    public static func suggestions(
        in sql: String,
        at cursor: Int,
        catalog: SQLCatalog,
        defaultSchema: String? = nil,
        dialect: SQLDialect = .postgres,
        includeSnippets: Bool = true
    ) -> [SQLCompletionItem] {
        guard let context = context(in: sql, at: cursor) else { return [] }
        return suggestions(
            for: context,
            in: sql,
            catalog: catalog,
            defaultSchema: defaultSchema,
            dialect: dialect,
            includeSnippets: includeSnippets
        )
    }

    public static func suggestions(
        for context: SQLCompletionContext,
        in sql: String,
        catalog: SQLCatalog,
        defaultSchema: String? = nil,
        dialect: SQLDialect = .postgres,
        includeSnippets: Bool = true
    ) -> [SQLCompletionItem] {
        let statement = statementText(containing: context.replacementRange.location, in: sql)
        let references = tableReferences(in: statement)
        let prefix = context.prefix

        var items: [SQLCompletionItem] = []

        switch context.kind {
        case .member(let qualifier):
            items = memberSuggestions(
                qualifier: qualifier,
                references: references,
                catalog: catalog,
                defaultSchema: defaultSchema,
                dialect: dialect
            )

        case .tableName:
            items = tableNameSuggestions(
                catalog: catalog,
                defaultSchema: defaultSchema,
                dialect: dialect
            )

        case .general:
            items = generalSuggestions(
                references: references,
                catalog: catalog,
                defaultSchema: defaultSchema,
                dialect: dialect,
                includeSnippets: includeSnippets
            )
        }

        let needle = prefix.lowercased()
        let filtered = needle.isEmpty
            ? items
            : items.filter {
                $0.title.lowercased().hasPrefix(needle) || $0.insertText.lowercased().hasPrefix(needle)
            }

        return Array(filtered.sorted { rank($0, prefix: needle) < rank($1, prefix: needle) }.prefix(100))
    }

    // MARK: Member suggestions

    private static func memberSuggestions(
        qualifier: String,
        references: [TableReference],
        catalog: SQLCatalog,
        defaultSchema: String?,
        dialect: SQLDialect
    ) -> [SQLCompletionItem] {
        if let reference = references.first(where: { matches(qualifier, $0.alias) || matches(qualifier, $0.table) }) {
            let schema = reference.schema
                ?? defaultSchema
                ?? catalog.table(named: reference.table)?.schema
                ?? "public"
            let columns = catalog.columns(schema: schema, table: reference.table)
            if !columns.isEmpty {
                return columns.map { columnItem($0, dialect: dialect) }
            }
        }

        let schemaTables = catalog.tables(in: qualifier)
        if !schemaTables.isEmpty {
            return schemaTables.map { tableItem($0, qualification: .plain, dialect: dialect) }
        }

        if let table = catalog.table(named: qualifier) {
            let columns = catalog.columns(schema: table.schema, table: table.name)
            if !columns.isEmpty { return columns.map { columnItem($0, dialect: dialect) } }
        }

        return []
    }

    // MARK: Table-name suggestions

    private static func tableNameSuggestions(
        catalog: SQLCatalog,
        defaultSchema: String?,
        dialect: SQLDialect
    ) -> [SQLCompletionItem] {
        let current = defaultSchema ?? "public"
        var items: [SQLCompletionItem] = []

        for table in catalog.tables {
            let qualification: TableQualification =
                table.schema.caseInsensitiveCompare(current) == .orderedSame ? .plain : .schemaQualified
            items.append(tableItem(table, qualification: qualification, dialect: dialect))
        }

        for schema in catalog.schemas {
            items.append(
                SQLCompletionItem(
                    kind: .schema,
                    title: schema,
                    insertText: identifier(schema, dialect: dialect) + ".",
                    detail: nil
                )
            )
        }

        return items
    }

    // MARK: General suggestions

    private static func generalSuggestions(
        references: [TableReference],
        catalog: SQLCatalog,
        defaultSchema: String?,
        dialect: SQLDialect,
        includeSnippets: Bool
    ) -> [SQLCompletionItem] {
        let current = defaultSchema ?? "public"
        var items: [SQLCompletionItem] = []
        var seen = Set<String>()

        func add(_ item: SQLCompletionItem) {
            let key = "\(item.kind.rawValue)|\(item.title.lowercased())|\(item.detail ?? "")"
            guard seen.insert(key).inserted else { return }
            items.append(item)
        }

        for reference in references {
            let schema = reference.schema
                ?? defaultSchema
                ?? catalog.table(named: reference.table)?.schema
                ?? current
            for column in catalog.columns(schema: schema, table: reference.table) {
                add(columnItem(column, dialect: dialect))
            }
        }

        for table in catalog.tables {
            let sameSchema = table.schema.caseInsensitiveCompare(current) == .orderedSame
            add(tableItem(table, qualification: sameSchema ? .plain : .schemaQualified, dialect: dialect))
        }

        for schema in catalog.schemas {
            add(
                SQLCompletionItem(
                    kind: .schema,
                    title: schema,
                    insertText: identifier(schema, dialect: dialect) + ".",
                    detail: nil
                )
            )
        }

        if includeSnippets {
            for snippet in SQLSnippets.items(dialect: dialect) {
                add(snippet)
            }
        }

        for word in sqlKeywords {
            add(SQLCompletionItem(kind: .keyword, title: word, insertText: word))
        }

        return items
    }

    private static let sqlKeywords: [String] = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "ILIKE", "BETWEEN",
        "EXISTS", "DISTINCT", "AS", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN",
        "ON", "USING", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "UNION", "UNION ALL", "INTERSECT",
        "EXCEPT", "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING", "WITH", "CASE", "WHEN",
        "THEN", "ELSE", "END", "ASC", "DESC", "NULLS FIRST", "NULLS LAST", "CREATE TABLE", "ALTER TABLE",
        "DROP TABLE", "TRUNCATE", "BEGIN", "COMMIT", "ROLLBACK", "COUNT", "SUM", "AVG", "MIN", "MAX",
        "COALESCE", "NULLIF", "CAST", "NOW()", "CURRENT_DATE", "CURRENT_TIMESTAMP", "TRUE", "FALSE",
        "ON CONFLICT", "DO NOTHING", "EXPLAIN", "EXPLAIN ANALYZE"
    ]

    // MARK: Items

    private enum TableQualification {
        case plain
        case schemaQualified
    }

    private static func tableItem(
        _ table: TableInfo,
        qualification: TableQualification,
        dialect: SQLDialect
    ) -> SQLCompletionItem {
        let name: String
        switch qualification {
        case .plain:
            name = identifier(table.name, dialect: dialect)
        case .schemaQualified:
            name = "\(identifier(table.schema, dialect: dialect)).\(identifier(table.name, dialect: dialect))"
        }

        return SQLCompletionItem(
            kind: table.kind == .view ? .view : .table,
            title: table.name,
            insertText: name,
            detail: table.schema
        )
    }

    private static func columnItem(_ column: CatalogColumn, dialect: SQLDialect) -> SQLCompletionItem {
        SQLCompletionItem(
            kind: .column,
            title: column.name,
            insertText: identifier(column.name, dialect: dialect),
            detail: column.dataType
        )
    }

    // MARK: Ranking

    private static func rank(_ item: SQLCompletionItem, prefix: String) -> (Int, Int, Int, String) {
        let title = item.title.lowercased()
        let exact = !prefix.isEmpty && title == prefix ? 0 : 1
        let kindRank: Int
        switch item.kind {
        case .column: kindRank = 0
        case .table, .view: kindRank = 1
        case .schema: kindRank = 2
        case .snippet: kindRank = 3
        case .keyword: kindRank = 4
        }
        return (exact, kindRank, item.title.count, title)
    }

    // MARK: Parsing

    private static func tableReferences(in statement: String) -> [TableReference] {
        let ns = statement as NSString
        let range = NSRange(location: 0, length: ns.length)
        var result: [TableReference] = []

        for match in tableReferenceRegex.matches(in: statement, options: [], range: range) {
            guard match.numberOfRanges >= 2 else { continue }
            let rawName = ns.substring(with: match.range(at: 1))
            let parts = splitQualifiedName(rawName)
            guard let table = parts.last, !table.isEmpty else { continue }

            var alias: String?
            if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
                let candidate = ns.substring(with: match.range(at: 2))
                if !reservedAliases.contains(candidate.uppercased()) {
                    alias = candidate
                }
            }

            result.append(
                TableReference(
                    schema: parts.count > 1 ? parts[parts.count - 2] : nil,
                    table: table,
                    alias: alias
                )
            )
        }

        return result
    }

    /// Splits `schema.table` honouring quoted identifiers.
    private static func splitQualifiedName(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            if character == "\"" {
                let next = raw.index(after: index)
                if inQuotes, next < raw.endIndex, raw[next] == "\"" {
                    current.append("\"")
                    index = raw.index(after: next)
                    continue
                }
                inQuotes.toggle()
                index = next
                continue
            }
            if character == ".", !inQuotes {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index = raw.index(after: index)
                continue
            }
            current.append(character)
            index = raw.index(after: index)
        }

        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    private static func statementText(containing location: Int, in sql: String) -> String {
        let statements = SQLStatementSplitter.statements(in: sql)
        for statement in statements {
            if NSLocationInRange(location, statement.range)
                || location == NSMaxRange(statement.range)
                || (location > 0 && NSLocationInRange(location - 1, statement.range)) {
                return statement.text
            }
        }
        return sql
    }

    // MARK: Identifier helpers

    public static func identifier(_ name: String, dialect: SQLDialect) -> String {
        let simple = name.range(of: "^[a-z_][a-z0-9_$]*$", options: .regularExpression) != nil
        return simple ? name : dialect.quote(name)
    }

    private static func matches(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    // MARK: Scanning helpers

    private static func ascii(_ character: Character) -> UInt16 {
        UInt16(character.asciiValue ?? 0)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    private static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
            || (0x41...0x5A).contains(unit)
            || (0x61...0x7A).contains(unit)
            || unit == ascii("_")
            || unit == ascii("$")
            || unit >= 0x80
    }

    private static func isInsideLiteralOrComment(_ sql: String, cursor: Int) -> Bool {
        for token in SQLTokenizer.tokens(in: sql) {
            switch token.kind {
            case .string, .comment:
                if NSLocationInRange(cursor, token.range) { return true }
                if cursor > 0, NSLocationInRange(cursor - 1, token.range) { return true }
            case .keyword, .number, .quotedIdentifier, .parameter:
                continue
            }
        }
        return false
    }
}

// MARK: - Snippets

public enum SQLSnippets {
    public static func items(dialect: SQLDialect = .postgres) -> [SQLCompletionItem] {
        let limitedSelect = dialect.family == .sqlServer
            ? "SELECT TOP 100 *\nFROM |;"
            : "SELECT *\nFROM |\nLIMIT 100;"

        let templates: [(trigger: String, detail: String, template: String)] = [
            ("sel", "SELECT", "SELECT *\nFROM |\nWHERE "),
            ("selt", "SELECT com limite", limitedSelect),
            ("ins", "INSERT", "INSERT INTO |\nVALUES ();"),
            ("upd", "UPDATE", "UPDATE |\nSET \nWHERE ;"),
            ("del", "DELETE", "DELETE FROM |\nWHERE ;"),
        ]

        return templates.compactMap { entry in
            let ns = entry.template as NSString
            let marker = ns.range(of: "|")
            guard marker.location != NSNotFound else { return nil }

            var text = entry.template
            if let range = Range(marker, in: text) {
                text.removeSubrange(range)
            }

            return SQLCompletionItem(
                kind: .snippet,
                title: entry.trigger,
                insertText: text,
                detail: entry.detail,
                caretOffset: marker.location
            )
        }
    }
}
