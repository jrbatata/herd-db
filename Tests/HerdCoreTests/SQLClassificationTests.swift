import XCTest
@testable import HerdCore

final class SQLClassificationTests: XCTestCase {
    func testReadOnlyStatements() {
        XCTAssertTrue(SQLClassification.isReadOnly("SELECT * FROM t"))
        XCTAssertTrue(SQLClassification.isReadOnly("  -- comentário\n SELECT 1;"))
        XCTAssertTrue(SQLClassification.isReadOnly("EXPLAIN SELECT * FROM t;"))
        XCTAssertTrue(SQLClassification.isReadOnly("SHOW search_path;"))
        XCTAssertTrue(SQLClassification.isReadOnly("/* c */ VALUES (1);"))
        XCTAssertTrue(SQLClassification.isReadOnly("(SELECT 1) UNION (SELECT 2);"))
        XCTAssertTrue(SQLClassification.isReadOnly("TABLE clientes;"))
    }

    func testWritingStatementsAreNotReadOnly() {
        XCTAssertFalse(SQLClassification.isReadOnly("INSERT INTO t VALUES (1)"))
        XCTAssertFalse(SQLClassification.isReadOnly("UPDATE t SET a = 1"))
        XCTAssertFalse(SQLClassification.isReadOnly("DELETE FROM t"))
        XCTAssertFalse(SQLClassification.isReadOnly("CREATE TABLE t (id int)"))
        XCTAssertFalse(SQLClassification.isReadOnly("WITH x AS (SELECT 1) DELETE FROM t"))
        XCTAssertFalse(SQLClassification.isReadOnly("SELECT 1; DELETE FROM t"))
        XCTAssertFalse(SQLClassification.isReadOnly(""))
    }

    func testSafeModeProperties() {
        XCTAssertFalse(SafeMode.silent.isRestricted)
        XCTAssertTrue(SafeMode.alert.isRestricted)
        XCTAssertFalse(SafeMode.alert.requiresPassword)
        XCTAssertTrue(SafeMode.secure.requiresPassword)
        XCTAssertTrue(SafeMode.alertReadOnly.skipsReadOnly)
        XCTAssertTrue(SafeMode.secureReadOnly.skipsReadOnly)
        XCTAssertFalse(SafeMode.secure.skipsReadOnly)
    }
}
