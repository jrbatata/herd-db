import Foundation
import XCTest
@testable import HerdCore

final class SQLStatementSplitterTests: XCTestCase {
    func testSplitsOnTopLevelSemicolons() {
        let statements = SQLStatementSplitter.split("SELECT 1; SELECT 2;\nSELECT 3")
        XCTAssertEqual(statements, ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    func testKeepsSemicolonInsideString() {
        XCTAssertEqual(
            SQLStatementSplitter.split("SELECT 'a;b' AS value;"),
            ["SELECT 'a;b' AS value"]
        )
    }

    func testHandlesDoubledQuotes() {
        XCTAssertEqual(
            SQLStatementSplitter.split("SELECT 'it''s; fine'; SELECT 2;"),
            ["SELECT 'it''s; fine'", "SELECT 2"]
        )
    }

    func testQuotedIdentifierMayContainSemicolon() {
        XCTAssertEqual(
            SQLStatementSplitter.split("SELECT \"odd;column\" FROM \"my;table\";"),
            ["SELECT \"odd;column\" FROM \"my;table\""]
        )
    }

    func testQuotedIdentifierWithDoubledQuotes() {
        XCTAssertEqual(
            SQLStatementSplitter.split("SELECT \"a\"\"b;c\" FROM t;"),
            ["SELECT \"a\"\"b;c\" FROM t"]
        )
    }

    func testLineCommentHidesSemicolon() {
        let sql = """
        SELECT 1 -- not the end; really
        ;
        SELECT 2;
        """
        XCTAssertEqual(SQLStatementSplitter.split(sql), ["SELECT 1", "SELECT 2"])
    }

    func testNestedBlockComment() {
        let sql = "SELECT /* outer /* inner; */ still; outer */ 1; SELECT 2;"
        XCTAssertEqual(
            SQLStatementSplitter.split(sql),
            ["SELECT /* outer /* inner; */ still; outer */ 1", "SELECT 2"]
        )
    }

    func testDollarQuotedBody() {
        let sql = """
        DO $$
        BEGIN
            RAISE NOTICE 'a;b';
        END $$;
        SELECT 1;
        """
        let statements = SQLStatementSplitter.split(sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].hasPrefix("DO $$"))
        XCTAssertTrue(statements[0].hasSuffix("END $$"))
        XCTAssertEqual(statements[1], "SELECT 1")
    }

    func testTaggedDollarQuoteReusesSameTag() {
        let sql = "SELECT $tag$ one $$ two $tag$; SELECT 2;"
        XCTAssertEqual(
            SQLStatementSplitter.split(sql),
            ["SELECT $tag$ one $$ two $tag$", "SELECT 2"]
        )
    }

    func testEmptyDollarTag() {
        let sql = "SELECT $$;$$; SELECT 2;"
        XCTAssertEqual(SQLStatementSplitter.split(sql), ["SELECT $$;$$", "SELECT 2"])
    }

    func testPositionalParameterIsNotDollarQuote() {
        let sql = "SELECT $1; SELECT $2;"
        XCTAssertEqual(SQLStatementSplitter.split(sql), ["SELECT $1", "SELECT $2"])
    }

    func testEscapeStringUsesBackslashEscapes() {
        let sql = "SELECT E'a\\';b'; SELECT 2;"
        XCTAssertEqual(SQLStatementSplitter.split(sql), ["SELECT E'a\\';b'", "SELECT 2"])
    }

    func testStandardStringDoesNotUseBackslashEscapes() {
        let sql = "SELECT 'a\\'; SELECT 2;"
        XCTAssertEqual(SQLStatementSplitter.split(sql), ["SELECT 'a\\'", "SELECT 2"])
    }

    func testLowerCaseEscapeString() {
        let sql = "SELECT e'x\\'y;z';"
        XCTAssertEqual(SQLStatementSplitter.split(sql), ["SELECT e'x\\'y;z'"])
    }

    func testIgnoresEmptyAndCommentOnlySegments() {
        let sql = """

        -- only a comment;
        ;
        /* another ; */
        ;;
        SELECT 1;
        """
        XCTAssertEqual(SQLStatementSplitter.split(sql), ["SELECT 1"])
    }

    func testEmptyScript() {
        XCTAssertTrue(SQLStatementSplitter.split("   \n\t ").isEmpty)
        XCTAssertTrue(SQLStatementSplitter.split("").isEmpty)
    }

    func testUnterminatedStringRunsToEnd() {
        XCTAssertEqual(SQLStatementSplitter.split("SELECT 'abc"), ["SELECT 'abc"])
    }

    func testUnterminatedDollarQuoteRunsToEnd() {
        XCTAssertEqual(SQLStatementSplitter.split("DO $$ BEGIN;"), ["DO $$ BEGIN;"])
    }

    func testRangesAreTrimmedAndMatchText() {
        let sql = "  SELECT 1;\n\nSELECT 'a;b';  "
        let statements = SQLStatementSplitter.statements(in: sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].text, "SELECT 1")
        XCTAssertEqual(statements[1].text, "SELECT 'a;b'")

        let ns = sql as NSString
        for statement in statements {
            XCTAssertEqual(ns.substring(with: statement.range), statement.text)
        }
    }

    func testRangesUseUTF16Offsets() {
        let sql = "SELECT '🐎'; SELECT 2;"
        let statements = SQLStatementSplitter.statements(in: sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[1].text, "SELECT 2")

        let ns = sql as NSString
        XCTAssertEqual(ns.substring(with: statements[1].range), "SELECT 2")
        XCTAssertEqual(statements[1].range.location, (sql as NSString).range(of: "SELECT 2").location)
    }

    func testSemicolonInsideFunctionBody() {
        let sql = """
        CREATE FUNCTION add(a int, b int) RETURNS int AS $$
        BEGIN
            RETURN a + b;
        END;
        $$ LANGUAGE plpgsql;
        SELECT add(1, 2);
        """
        let statements = SQLStatementSplitter.split(sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].hasSuffix("LANGUAGE plpgsql"))
        XCTAssertEqual(statements[1], "SELECT add(1, 2)")
    }
}
