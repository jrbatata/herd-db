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
    /// Asks the editor to open the completion list again right after inserting
    /// this item. Used by keywords such as `WHERE`, which open a new position
    /// where the next useful step is picking a column.
    public var continuesCompletion: Bool

    public var id: String { "\(kind.rawValue)|\(title)|\(insertText)|\(detail ?? "")" }

    /// True when accepting this item would only reproduce `prefix`, so the
    /// popup has nothing left to complete. Case-insensitive because the filter
    /// that produced the item is case-insensitive too.
    ///
    /// An item whose title already matches the prefix still counts as useful
    /// when it has a `caretOffset` (a snippet or a `column = ''` condition) or
    /// when `insertText` adds schema qualification: accepting it adds the
    /// surrounding template or the schema. Plain identifiers have neither, so
    /// typing the whole name means there is nothing left.
    public func completesNothing(for prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        if insertText.caseInsensitiveCompare(prefix) == .orderedSame {
            return true
        }
        // A plain identifier is inserted exactly as its title. When `insertText`
        // adds schema qualification or a template, accepting it still changes
        // the text even if the title already matches what was typed.
        guard caretOffset == nil,
              title.caseInsensitiveCompare(prefix) == .orderedSame
        else { return false }
        return insertText.caseInsensitiveCompare(title) == .orderedSame
    }

    public init(
        kind: SQLCompletionKind,
        title: String,
        insertText: String,
        detail: String? = nil,
        caretOffset: Int? = nil,
        continuesCompletion: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.insertText = insertText
        self.detail = detail
        self.caretOffset = caretOffset
        self.continuesCompletion = continuesCompletion
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
        let statementInfo = statementLocation(containing: context.replacementRange.location, in: sql)
        let statement = statementInfo.text
        let references = tableReferences(in: statement)
        let prefix = context.prefix
        let condition = isConditionPosition(in: statement, at: statementInfo.offset)

        var items: [SQLCompletionItem] = []

        switch context.kind {
        case .member(let qualifier):
            items = memberSuggestions(
                qualifier: qualifier,
                references: references,
                catalog: catalog,
                defaultSchema: defaultSchema,
                dialect: dialect,
                condition: condition
            )

        case .tableName:
            items = tableNameSuggestions(
                catalog: catalog,
                dialect: dialect
            )

        case .general:
            items = generalSuggestions(
                references: references,
                catalog: catalog,
                defaultSchema: defaultSchema,
                dialect: dialect,
                includeSnippets: includeSnippets,
                condition: condition
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
        dialect: SQLDialect,
        condition: Bool
    ) -> [SQLCompletionItem] {
        if let reference = references.first(where: { matches(qualifier, $0.alias) || matches(qualifier, $0.table) }) {
            let schema = reference.schema
                ?? defaultSchema
                ?? catalog.table(named: reference.table)?.schema
                ?? "public"
            let columns = catalog.columns(schema: schema, table: reference.table)
            if !columns.isEmpty {
                return columns.map { columnItem($0, dialect: dialect, condition: condition) }
            }
        }

        let schemaTables = catalog.tables(in: qualifier)
        if !schemaTables.isEmpty {
            return schemaTables.map { tableItem($0, qualification: .plain, dialect: dialect) }
        }

        if let table = catalog.table(named: qualifier) {
            let columns = catalog.columns(schema: table.schema, table: table.name)
            if !columns.isEmpty {
                return columns.map { columnItem($0, dialect: dialect, condition: condition) }
            }
        }

        return []
    }

    // MARK: Table-name suggestions

    private static func tableNameSuggestions(
        catalog: SQLCatalog,
        dialect: SQLDialect
    ) -> [SQLCompletionItem] {
        var items: [SQLCompletionItem] = []

        // Always qualify: the connection's search_path may not include the
        // tab's schema, so a bare table name can fail at execution time.
        for table in catalog.tables {
            items.append(tableItem(table, qualification: .schemaQualified, dialect: dialect))
        }

        for schema in catalog.schemas {
            items.append(
                SQLCompletionItem(
                    kind: .schema,
                    title: schema,
                    insertText: identifier(schema, dialect: dialect) + ".",
                    detail: nil,
                    continuesCompletion: true
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
        includeSnippets: Bool,
        condition: Bool
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
                add(columnItem(column, dialect: dialect, condition: condition))
            }
        }

        for table in catalog.tables {
            add(tableItem(table, qualification: .schemaQualified, dialect: dialect))
        }

        for schema in catalog.schemas {
            add(
                SQLCompletionItem(
                    kind: .schema,
                    title: schema,
                    insertText: identifier(schema, dialect: dialect) + ".",
                    detail: nil,
                    continuesCompletion: true
                )
            )
        }

        if includeSnippets {
            for snippet in SQLSnippets.items(dialect: dialect) {
                add(snippet)
            }
        }

        for word in sqlKeywords {
            switch word {
            case "WHERE":
                add(
                    SQLCompletionItem(
                        kind: .keyword,
                        title: word,
                        insertText: "WHERE ",
                        detail: "condição"
                    )
                )
            case "SELECT":
                // Selecting SELECT already writes the star and FROM, then
                // reopens the list so the table can be picked right away.
                let insertText = "SELECT *\nFROM "
                add(
                    SQLCompletionItem(
                        kind: .keyword,
                        title: word,
                        insertText: insertText,
                        detail: "consulta",
                        caretOffset: (insertText as NSString).length,
                        continuesCompletion: true
                    )
                )
            case "CASE":
                let insertText = "CASE\n    WHEN  THEN\n    ELSE \nEND"
                add(
                    SQLCompletionItem(
                        kind: .keyword,
                        title: word,
                        insertText: insertText,
                        detail: "modelo CASE WHEN",
                        caretOffset: "CASE\n    WHEN ".utf16.count
                    )
                )
            default:
                add(SQLCompletionItem(kind: .keyword, title: word, insertText: word))
            }
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

    private static func columnItem(
        _ column: CatalogColumn,
        dialect: SQLDialect,
        condition: Bool
    ) -> SQLCompletionItem {
        let name = identifier(column.name, dialect: dialect)
        guard condition else {
            return SQLCompletionItem(
                kind: .column,
                title: column.name,
                insertText: name,
                detail: column.dataType
            )
        }

        let insertText: String
        let caretOffset: Int?
        if needsQuotedLiteral(column.dataType) {
            insertText = "\(name) = ''"
            caretOffset = (insertText as NSString).length - 1
        } else {
            insertText = "\(name) = "
            caretOffset = (insertText as NSString).length
        }

        return SQLCompletionItem(
            kind: .column,
            title: column.name,
            insertText: insertText,
            detail: column.dataType,
            caretOffset: caretOffset
        )
    }

    /// Types whose literals are written without quotes. Arrays and everything
    /// else keep `''` so the user only types the value.
    private static func needsQuotedLiteral(_ dataType: String) -> Bool {
        let base = dataType
            .lowercased()
            .split(separator: "(", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            ?? ""

        let unquoted: Set<String> = [
            "smallint", "integer", "int", "int2", "int4", "int8", "bigint",
            "smallserial", "serial", "bigserial", "serial2", "serial4", "serial8",
            "numeric", "decimal", "real", "double precision", "float", "float4", "float8",
            "money", "oid", "boolean", "bool",
        ]

        return !unquoted.contains(base)
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

    /// The statement under `location` along with the offset of `location` inside it.
    private static func statementLocation(
        containing location: Int,
        in sql: String
    ) -> (text: String, offset: Int) {
        let statements = SQLStatementSplitter.statements(in: sql)
        for statement in statements {
            if NSLocationInRange(location, statement.range)
                || location == NSMaxRange(statement.range)
                || (location > 0 && NSLocationInRange(location - 1, statement.range)) {
                return (statement.text, max(0, location - statement.range.location))
            }
        }
        return (sql, location)
    }

    /// Keywords after which a column suggestion means "compare this column",
    /// so it can be completed as `column = ''` with the caret inside the quotes.
    private static let conditionKeywords: Set<String> = [
        "WHERE", "AND", "OR", "HAVING", "ON", "WHEN",
    ]

    /// True when the caret sits where a new condition starts, e.g. after
    /// `WHERE `, `AND ` or `ON `. A comparison already typed (`=`, `>`, `LIKE`)
    /// disables it so a value suggestion is not turned into a new condition.
    private static func isConditionPosition(in statement: String, at offset: Int) -> Bool {
        let ns = statement as NSString
        var lastKeyword: SQLToken?

        for token in SQLTokenizer.tokens(in: statement) {
            guard NSMaxRange(token.range) <= offset else { break }
            if token.kind == .keyword {
                lastKeyword = token
            }
        }

        guard let keyword = lastKeyword,
              conditionKeywords.contains(ns.substring(with: keyword.range).uppercased())
        else { return false }

        let tailStart = NSMaxRange(keyword.range)
        guard tailStart < offset else { return true }
        let tail = ns.substring(with: NSRange(location: tailStart, length: offset - tailStart))
        return !tail.contains { "=<>!".contains($0) }
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
            ("case", "CASE WHEN", "CASE\n    WHEN | THEN\n    ELSE \nEND"),
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
