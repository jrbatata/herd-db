import Foundation
import XCTest
@testable import HerdCore

final class SQLTokenizerTests: XCTestCase {
    private func kinds(_ sql: String) -> [(String, SQLTokenKind)] {
        let ns = sql as NSString
        return SQLTokenizer.tokens(in: sql).map { (ns.substring(with: $0.range), $0.kind) }
    }

    func testHighlightsKeywordsCaseInsensitively() {
        XCTAssertEqual(
            kinds("select id from users").map(\.1),
            [.keyword, .keyword]
        )
        XCTAssertEqual(kinds("select id from users").map(\.0), ["select", "from"])
        XCTAssertEqual(kinds("SeLeCt 1").first?.1, .keyword)
    }

    func testIgnoresKeywordsInsideStringsAndComments() {
        let sql = "SELECT 'from -- where', \"select\" -- from here\nFROM t"
        let result = kinds(sql)
        XCTAssertEqual(result.map(\.0), ["SELECT", "'from -- where'", "\"select\"", "-- from here", "FROM"])
        XCTAssertEqual(result.map(\.1), [.keyword, .string, .quotedIdentifier, .comment, .keyword])
    }

    func testStringWithDoubledQuotes() {
        let sql = "SELECT 'it''s from'"
        let result = kinds(sql)
        XCTAssertEqual(result.map(\.0), ["SELECT", "'it''s from'"])
        XCTAssertEqual(result.map(\.1), [.keyword, .string])
    }

    func testEscapeStringWithBackslash() {
        let sql = "SELECT E'a\\'from'"
        let result = kinds(sql)
        XCTAssertEqual(result.map(\.0), ["SELECT", "'a\\'from'"])
        XCTAssertEqual(result.map(\.1), [.keyword, .string])
    }

    func testNumbers() {
        let result = kinds("SELECT 42, 3.14, 1e10, table1 FROM t1")
        XCTAssertEqual(result.map(\.0), ["SELECT", "42", "3.14", "1e10", "FROM"])
        XCTAssertEqual(result.map(\.1), [.keyword, .number, .number, .number, .keyword])
    }

    func testParameters() {
        let result = kinds("SELECT $1, $2")
        XCTAssertEqual(result.map(\.0), ["SELECT", "$1", "$2"])
        XCTAssertEqual(result.map(\.1), [.keyword, .parameter, .parameter])
    }

    func testDollarQuotedBodyIsString() {
        let sql = "DO $$ BEGIN SELECT 1; END $$; SELECT 2"
        let result = kinds(sql)
        XCTAssertEqual(result[1].1, .string)
        XCTAssertEqual(result[1].0, "$$ BEGIN SELECT 1; END $$")
        XCTAssertEqual(result.last?.1, .number)
    }

    func testNestedBlockComment() {
        let sql = "SELECT /* outer /* inner */ still */ 1"
        let result = kinds(sql)
        XCTAssertEqual(result[1].0, "/* outer /* inner */ still */")
        XCTAssertEqual(result[1].1, .comment)
        XCTAssertEqual(result.last?.1, .number)
    }

    func testQuotedIdentifierIsNotKeyword() {
        XCTAssertEqual(kinds("\"from\"").map(\.1), [.quotedIdentifier])
    }

    func testRangesMatchSubstrings() {
        let sql = "SELECT '🐎' AS horse, -- note\n  count(*) FROM t;"
        let ns = sql as NSString
        for token in SQLTokenizer.tokens(in: sql) {
            XCTAssertTrue(NSMaxRange(token.range) <= ns.length)
            XCTAssertFalse(ns.substring(with: token.range).isEmpty)
        }
    }

    func testDoesNotTokenizeOperatorsOrIdentifiers() {
        XCTAssertTrue(SQLTokenizer.tokens(in: "a + b = c").isEmpty)
    }
}
