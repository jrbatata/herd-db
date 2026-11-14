import XCTest
@testable import HerdCore

final class SQLFormatterTests: XCTestCase {
    func testFormatsClausesWithoutChangingLiteralsOrComments() {
        let sql = "select 'from where' as value from users -- select from\nwhere id = 1;"
        XCTAssertEqual(
            SQLFormatter.format(sql, dialect: .postgres),
            "SELECT 'from where' AS value\nFROM users -- select from\nWHERE id = 1;"
        )
    }

    func testPreservesQuotedIdentifierAndDollarString() {
        let sql = "select \"from\", $$where select$$ from data;"
        XCTAssertEqual(
            SQLFormatter.format(sql, dialect: .postgres),
            "SELECT \"from\", $$where select$$\nFROM data;"
        )
    }

    func testFormatsSQLServerTopAndBracketIdentifier() {
        XCTAssertEqual(
            SQLFormatter.format("select top 10 [from] from users", dialect: .sqlServer),
            "SELECT TOP 10 [from]\nFROM users"
        )
    }
}
