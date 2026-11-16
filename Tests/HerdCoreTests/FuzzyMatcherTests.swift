import XCTest
@testable import HerdCore

final class FuzzyMatcherTests: XCTestCase {
    func testExactAnchors() {
        XCTAssertEqual(FuzzyMatcher.score("^users$", in: "users"), 1_000)
        XCTAssertEqual(FuzzyMatcher.score("^Users$", in: "USERS"), 1_000)
        XCTAssertNil(FuzzyMatcher.score("^users$", in: "users_archive"))
        XCTAssertNil(FuzzyMatcher.score("^users$", in: "app_users"))
    }

    func testPrefixAnchor() {
        XCTAssertNotNil(FuzzyMatcher.score("^user", in: "users"))
        XCTAssertNil(FuzzyMatcher.score("^user", in: "app_users"))
    }

    func testSuffixAnchor() {
        XCTAssertNotNil(FuzzyMatcher.score("users$", in: "app_users"))
        XCTAssertNil(FuzzyMatcher.score("users$", in: "users_archive"))
        XCTAssertNil(FuzzyMatcher.score("users$", in: "app_users_archive"))
    }

    func testFuzzySubsequence() {
        XCTAssertNotNil(FuzzyMatcher.score("usrs", in: "users"))
        XCTAssertNotNil(FuzzyMatcher.score("apu", in: "app_users"))
        XCTAssertNil(FuzzyMatcher.score("xyz", in: "users"))
        XCTAssertNil(FuzzyMatcher.score("sru", in: "users"))
    }

    func testCaseInsensitiveAndSpaces() {
        XCTAssertNotNil(FuzzyMatcher.score("USERS", in: "app_users"))
        XCTAssertNotNil(FuzzyMatcher.score("pub users", in: "public.users"))
        XCTAssertNil(FuzzyMatcher.score("pub orders", in: "public.users"))
    }

    func testAnchorsBeatFuzzyScore() {
        let prefix = FuzzyMatcher.score("^user", in: "users") ?? 0
        let fuzzy = FuzzyMatcher.score("user", in: "app_users") ?? 0
        XCTAssertGreaterThan(prefix, fuzzy)
    }

    func testEmptyPatternMatchesEverything() {
        XCTAssertEqual(FuzzyMatcher.score("", in: "qualquer"), 0)
        XCTAssertEqual(FuzzyMatcher.score("   ", in: "qualquer"), 0)
    }

    func testDatabaseObjectKinds() {
        XCTAssertTrue(DatabaseObjectKind.function.isRoutine)
        XCTAssertTrue(DatabaseObjectKind.procedure.isRoutine)
        XCTAssertFalse(DatabaseObjectKind.materializedView.isRoutine)
        XCTAssertEqual(RoutineKind.procedure.objectKind, .procedure)
    }
}
