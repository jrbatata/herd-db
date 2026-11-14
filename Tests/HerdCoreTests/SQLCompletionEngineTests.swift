import XCTest
@testable import HerdCore

final class SQLCompletionEngineTests: XCTestCase {
    private let catalog = SQLCatalog(
        schemas: ["public", "vendas"],
        tables: [
            TableInfo(schema: "public", name: "orders", kind: .table),
            TableInfo(schema: "public", name: "users", kind: .table),
            TableInfo(schema: "public", name: "order_summary", kind: .view),
            TableInfo(schema: "vendas", name: "pedidos", kind: .table),
        ],
        columns: [
            CatalogColumn(schema: "public", table: "orders", name: "id", dataType: "integer"),
            CatalogColumn(schema: "public", table: "orders", name: "user_id", dataType: "integer"),
            CatalogColumn(schema: "public", table: "orders", name: "total", dataType: "numeric"),
            CatalogColumn(schema: "public", table: "users", name: "id", dataType: "integer"),
            CatalogColumn(schema: "public", table: "users", name: "name", dataType: "text"),
            CatalogColumn(schema: "vendas", table: "pedidos", name: "valor", dataType: "numeric"),
        ]
    )

    // MARK: - Context

    func testTableContextAfterFrom() {
        let sql = "SELECT * FROM "
        let context = SQLCompletionEngine.context(in: sql, at: (sql as NSString).length)

        XCTAssertEqual(context?.kind, .tableName)
        XCTAssertEqual(context?.prefix, "")
        XCTAssertEqual(context?.replacementRange, NSRange(location: (sql as NSString).length, length: 0))
    }

    func testTableContextAfterJoin() {
        let sql = "SELECT * FROM orders o JOIN "
        let context = SQLCompletionEngine.context(in: sql, at: (sql as NSString).length)
        XCTAssertEqual(context?.kind, .tableName)
    }

    func testMemberContextAfterAlias() {
        let sql = "SELECT * FROM public.orders o WHERE o."
        let context = SQLCompletionEngine.context(in: sql, at: (sql as NSString).length)
        XCTAssertEqual(context?.kind, .member(qualifier: "o"))
        XCTAssertEqual(context?.prefix, "")
    }

    func testMemberContextAfterPartialColumn() {
        let sql = "SELECT o.to FROM public.orders o"
        let cursor = (sql as NSString).range(of: "o.to").location + 4
        let context = SQLCompletionEngine.context(in: sql, at: cursor)
        XCTAssertEqual(context?.kind, .member(qualifier: "o"))
        XCTAssertEqual(context?.prefix, "to")
        XCTAssertEqual(context?.replacementRange, NSRange(location: cursor - 2, length: 2))
    }

    func testGeneralContextNeedsPrefixByDefault() {
        let sql = "SELECT  FROM orders"
        let cursor = (sql as NSString).range(of: "SELECT ").location + 7
        XCTAssertNil(SQLCompletionEngine.context(in: sql, at: cursor))
        XCTAssertEqual(
            SQLCompletionEngine.context(in: sql, at: cursor, allowEmptyPrefix: true)?.kind,
            .general
        )
    }

    func testLexicalContextsAreIgnored() {
        let comment = "SELECT * FROM orders -- com"
        XCTAssertNil(
            SQLCompletionEngine.context(in: comment, at: (comment as NSString).length)
        )

        let string = "SELECT 'from"
        XCTAssertNil(SQLCompletionEngine.context(in: string, at: (string as NSString).length))
    }

    func testQuotedMemberContext() {
        let sql = "SELECT * FROM \"Pedidos\" p WHERE p."
        let context = SQLCompletionEngine.context(in: sql, at: (sql as NSString).length)
        XCTAssertEqual(context?.kind, .member(qualifier: "p"))
    }

    // MARK: - Suggestions

    func testMemberSuggestionsForAlias() {
        let sql = "SELECT * FROM public.orders o WHERE o."
        let items = SQLCompletionEngine.suggestions(
            in: sql,
            at: (sql as NSString).length,
            catalog: catalog
        )

        XCTAssertEqual(items.map(\.title), ["id", "total", "user_id"])
        XCTAssertTrue(items.allSatisfy { $0.kind == .column })
        XCTAssertEqual(items.first?.detail, "integer")
    }

    func testMemberSuggestionsForAliasWithSchemaLessTable() {
        let sql = "SELECT * FROM orders o WHERE o."
        let items = SQLCompletionEngine.suggestions(
            in: sql,
            at: (sql as NSString).length,
            catalog: catalog
        )
        XCTAssertEqual(items.map(\.title), ["id", "total", "user_id"])
    }

    func testMemberSuggestionsForTableName() {
        let sql = "SELECT orders. FROM orders"
        let cursor = (sql as NSString).range(of: "orders.").location + 7
        let items = SQLCompletionEngine.suggestions(in: sql, at: cursor, catalog: catalog)
        XCTAssertEqual(items.map(\.title), ["id", "total", "user_id"])
    }

    func testSchemaMembersSuggestTables() {
        let sql = "SELECT * FROM public."
        let items = SQLCompletionEngine.suggestions(
            in: sql,
            at: (sql as NSString).length,
            catalog: catalog
        )
        XCTAssertEqual(Set(items.map(\.title)), ["orders", "users", "order_summary"])
        XCTAssertTrue(items.contains { $0.kind == .view })
    }

    func testTableNameSuggestionsPreferDefaultSchema() {
        let items = SQLCompletionEngine.suggestions(
            in: "SELECT * FROM ",
            at: 14,
            catalog: catalog,
            defaultSchema: "public"
        )

        let orders = items.first { $0.title == "orders" }
        let pedidos = items.first { $0.title == "pedidos" }
        XCTAssertEqual(orders?.insertText, "orders")
        XCTAssertEqual(pedidos?.insertText, "vendas.pedidos")
        XCTAssertNotNil(items.first { $0.kind == .schema && $0.insertText == "vendas." })
    }

    func testTableNameFilteringByPrefix() {
        let items = SQLCompletionEngine.suggestions(
            in: "SELECT * FROM ord",
            at: 16,
            catalog: catalog
        )
        XCTAssertEqual(items.map(\.title), ["orders", "order_summary"])
    }

    func testGeneralSuggestionsIncludeColumnsOfReferencedTables() {
        let sql = "SELECT na FROM users"
        let cursor = (sql as NSString).range(of: "na").location + 2
        let items = SQLCompletionEngine.suggestions(in: sql, at: cursor, catalog: catalog)
        XCTAssertTrue(items.contains { $0.kind == .column && $0.title == "name" })
    }

    func testGeneralSuggestionsOnlyUseCurrentStatementAliases() {
        let sql = "SELECT name FROM users;\nSELECT tot FROM orders"
        let cursor = (sql as NSString).range(of: "tot").location + 3
        let items = SQLCompletionEngine.suggestions(in: sql, at: cursor, catalog: catalog)
        XCTAssertTrue(items.contains { $0.kind == .column && $0.title == "total" })
        XCTAssertFalse(items.contains { $0.kind == .column && $0.title == "name" })
    }

    func testSnippetsAreAvailableAndFilterable() {
        let all = SQLSnippets.items()
        XCTAssertEqual(all.map(\.title), ["sel", "selt", "ins", "upd", "del"])

        let items = SQLCompletionEngine.suggestions(
            in: "se",
            at: 2,
            catalog: catalog
        )
        let snippets = items.filter { $0.kind == .snippet }
        XCTAssertEqual(snippets.map(\.title), ["sel", "selt"])
        XCTAssertTrue(items.contains { $0.kind == .keyword && $0.title == "SELECT" })
    }

    func testSnippetCaretOffsetPointsAtTablePosition() {
        let inserts = SQLSnippets.items()
        guard let insert = inserts.first(where: { $0.title == "ins" }) else {
            return XCTFail("ins snippet missing")
        }

        XCTAssertEqual(insert.insertText, "INSERT INTO \nVALUES ();")
        XCTAssertEqual(insert.caretOffset, "INSERT INTO ".utf16.count)
    }

    func testQuotedIdentifiersGetQuotedInsertText() {
        let quoted = SQLCatalog(
            schemas: ["public"],
            tables: [TableInfo(schema: "public", name: "Pedidos", kind: .table)],
            columns: [CatalogColumn(schema: "public", table: "Pedidos", name: "Nome Cliente", dataType: "text")]
        )

        let tables = SQLCompletionEngine.suggestions(
            in: "SELECT * FROM ",
            at: 14,
            catalog: quoted,
            defaultSchema: "public"
        )
        let table = tables.first { $0.kind == .table }
        XCTAssertEqual(table?.insertText, "\"Pedidos\"")

        let sql = "SELECT * FROM \"Pedidos\" p WHERE p."
        let columns = SQLCompletionEngine.suggestions(
            in: sql,
            at: (sql as NSString).length,
            catalog: quoted,
            defaultSchema: "public"
        )
        XCTAssertEqual(columns.first?.insertText, "\"Nome Cliente\"")
    }

    func testSuggestionsAreEmptyInsideCommentsAndStrings() {
        XCTAssertTrue(
            SQLCompletionEngine.suggestions(
                in: "SELECT * FROM orders -- ord",
                at: 27,
                catalog: catalog
            ).isEmpty
        )
        XCTAssertTrue(
            SQLCompletionEngine.suggestions(
                in: "SELECT 'ord",
                at: 11,
                catalog: catalog
            ).isEmpty
        )
    }

    func testSuggestionsIgnoreOtherSchemasForTablePositions() {
        let items = SQLCompletionEngine.suggestions(
            in: "SELECT * FROM ",
            at: 14,
            catalog: catalog,
            defaultSchema: "vendas"
        )
        let vendas = items.first { $0.title == "pedidos" }
        let publicOrders = items.first { $0.title == "orders" }
        XCTAssertEqual(vendas?.insertText, "pedidos")
        XCTAssertEqual(publicOrders?.insertText, "public.orders")
    }
}
