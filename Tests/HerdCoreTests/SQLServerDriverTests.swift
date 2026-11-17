import Foundation
import XCTest
@testable import HerdCore

/// Hits a real SQL Server. Disabled unless HERD_TEST_MSSQL=1.
final class SQLServerDriverTests: XCTestCase {
    func testBrowseAndQuery() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let info = try await driver.test()
        XCTAssertTrue(info.version.localizedCaseInsensitiveContains("sql"), info.version)
        XCTAssertTrue(info.shortVersion.contains("SQL"), info.shortVersion)

        let databases = try await driver.listDatabases()
        XCTAssertTrue(databases.contains { $0.name == "master" })

        let schema = "herd_test_\(UUID().uuidString.prefix(8).lowercased())"
        addTeardownBlock {
            _ = try? await driver.run(
                "DROP TABLE IF EXISTS [\(schema)].[items]; DROP TABLE IF EXISTS [\(schema)].[owners]; DROP SCHEMA IF EXISTS [\(schema)];",
                database: "master"
            )
        }

        _ = try await driver.run("CREATE SCHEMA [\(schema)];", database: "master")
        _ = try await driver.run(
            "CREATE TABLE [\(schema)].[owners] (id int IDENTITY(1,1) PRIMARY KEY, name nvarchar(100) NOT NULL);",
            database: "master"
        )
        _ = try await driver.run(
            """
            CREATE TABLE [\(schema)].[items] (
                id int IDENTITY(1,1) PRIMARY KEY,
                owner_id int NULL,
                name nvarchar(100) NOT NULL,
                price decimal(10,2) NULL,
                created_at datetime2 NULL DEFAULT sysutcdatetime(),
                CONSTRAINT [fk_\(schema)_owner] FOREIGN KEY (owner_id) REFERENCES [\(schema)].[owners](id)
            );
            """,
            database: "master"
        )
        _ = try await driver.run(
            "INSERT INTO [\(schema)].[items] (owner_id, name, price) VALUES (NULL, N'Água', 12.50), (NULL, N'Café', NULL);",
            database: "master"
        )

        let schemas = try await driver.listSchemas(database: "master")
        XCTAssertTrue(schemas.contains { $0.name == schema })

        let tables = try await driver.listTables(database: "master", schema: schema)
        XCTAssertEqual(Set(tables.map(\.name)), ["owners", "items"])

        let columns = try await driver.listColumns(database: "master", schema: schema, table: "items")
        XCTAssertEqual(columns.map(\.name), ["id", "owner_id", "name", "price", "created_at"])

        let id = try XCTUnwrap(columns.first { $0.name == "id" })
        XCTAssertTrue(id.isPrimaryKey)
        XCTAssertFalse(id.isNullable)
        XCTAssertEqual(id.dataType, "int")

        let name = try XCTUnwrap(columns.first { $0.name == "name" })
        XCTAssertEqual(name.dataType, "nvarchar(100)")

        let owner = try XCTUnwrap(columns.first { $0.name == "owner_id" })
        XCTAssertEqual(owner.references, "\(schema).owners.id")

        let price = try XCTUnwrap(columns.first { $0.name == "price" })
        XCTAssertTrue(price.isNullable)
        XCTAssertEqual(price.dataType, "decimal(10,2)")

        let result = try await driver.run(
            "SELECT name, price FROM [\(schema)].[items] ORDER BY name;",
            database: "master"
        )
        XCTAssertEqual(result.columns, ["name", "price"])
        XCTAssertEqual(result.rows.count, 2)

        let agua = try XCTUnwrap(result.rows.first { $0[0] == "Água" })
        XCTAssertEqual(agua[1], "12.5")

        let cafe = try XCTUnwrap(result.rows.first { $0[0] == "Café" })
        XCTAssertNil(cafe[1])

        let firstPage = try await driver.browseTable(
            database: "master", schema: schema, table: "items", page: 0,
            pageSize: 1, filter: "", sortColumn: nil, descending: false
        )
        XCTAssertEqual(firstPage.totalRows, 2)
        XCTAssertEqual(firstPage.result.rows.count, 1)
        XCTAssertEqual(firstPage.result.rows.first?[2], "Água")

        let secondPage = try await driver.browseTable(
            database: "master", schema: schema, table: "items", page: 1,
            pageSize: 1, filter: "", sortColumn: "name", descending: false
        )
        XCTAssertEqual(secondPage.page, 1)
        XCTAssertEqual(secondPage.result.rows.first?[2], "Café")

        let filteredPage = try await driver.browseTable(
            database: "master", schema: schema, table: "items", page: 0,
            pageSize: 500, filter: "Ág", sortColumn: "name", descending: true
        )
        XCTAssertEqual(filteredPage.totalRows, 1)
        XCTAssertEqual(filteredPage.result.rows.first?[2], "Água")
    }

    func testCatalogSnapshotIncludesSchemasTablesViewsAndColumns() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let schema = "herd_catalog_\(UUID().uuidString.prefix(8).lowercased())"
        addTeardownBlock {
            _ = try? await driver.run(
                "DROP VIEW IF EXISTS [\(schema)].[owner_names]; DROP TABLE IF EXISTS [\(schema)].[owners]; DROP SCHEMA IF EXISTS [\(schema)];",
                database: "master"
            )
        }

        _ = try await driver.run("CREATE SCHEMA [\(schema)];", database: "master")
        _ = try await driver.run(
            """
            CREATE TABLE [\(schema)].[owners] (id int PRIMARY KEY, name nvarchar(100) NOT NULL);
            """,
            database: "master"
        )
        _ = try await driver.run(
            "CREATE VIEW [\(schema)].[owner_names] AS SELECT name FROM [\(schema)].[owners];",
            database: "master"
        )

        let catalog = try await driver.catalog(database: "master")
        XCTAssertTrue(catalog.schemas.contains(schema))
        XCTAssertFalse(catalog.schemas.contains("sys"))
        XCTAssertFalse(catalog.schemas.contains("INFORMATION_SCHEMA"))

        let tables = catalog.tables(in: schema)
        XCTAssertEqual(Set(tables.map(\.name)), ["owners", "owner_names"])
        XCTAssertEqual(tables.first { $0.name == "owner_names" }?.kind, .view)

        let columns = catalog.columns(schema: schema, table: "owners")
        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        XCTAssertEqual(columns.first { $0.name == "id" }?.dataType, "int")

        let flat = try await driver.listCatalogColumns(database: "master")
        XCTAssertTrue(flat.contains { $0.schema == schema && $0.table == "owners" && $0.name == "name" })
    }

    func testRunsScriptSequentiallyAndReturnsLastResultSet() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let result = try await driver.run(
            """
            SELECT 1 AS first;
            SELECT 2 AS second;
            """,
            database: "master"
        )

        XCTAssertEqual(result.statementCount, 2)
        XCTAssertEqual(result.columns, ["second"])
        XCTAssertEqual(result.rows, [["2"]])
        XCTAssertEqual(result.message, "2 comandos executados")
    }

    func testScriptErrorNamesTheFailingCommand() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let error = await XCTAssertThrowsErrorAsync {
            _ = try await driver.run(
                "SELECT 1; SELECT * FROM dbo.herd_table_that_does_not_exist;",
                database: "master"
            )
        }
        let message = try XCTUnwrap(error?.localizedDescription)
        XCTAssertTrue(message.hasPrefix("Comando 2 de 2:"), message)
        XCTAssertTrue(message.contains("herd_table_that_does_not_exist"), message)
    }

    func testCancelKeepsTheConnectionUsable() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let start = Date()
        let task = Task {
            try await driver.run("WAITFOR DELAY '00:00:30';", database: "master")
        }

        try await Task.sleep(for: .milliseconds(700))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A execução deveria ter sido cancelada.")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Erro inesperado ao cancelar: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 10)

        let after = try await driver.run("SELECT 42 AS answer;", database: "master")
        XCTAssertEqual(after.rows, [["42"]])
    }

    func testNativeBackupAndRestore() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let source = "herd_bkp_src_\(suffix)"
        let restored = "herd_bkp_dst_\(suffix)"
        let backupPath = "/var/opt/mssql/data/\(source).bak"
        addTeardownBlock {
            await driver.shutdown()
            _ = try? await driver.run(
                "ALTER DATABASE [\(restored)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [\(restored)];",
                database: "master"
            )
            _ = try? await driver.run(
                "ALTER DATABASE [\(source)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [\(source)];",
                database: "master"
            )
        }

        _ = try await driver.run("CREATE DATABASE [\(source)];", database: "master")
        _ = try await driver.run(
            "CREATE TABLE [dbo].[items] (id int PRIMARY KEY, name nvarchar(50) NOT NULL);",
            database: source
        )
        _ = try await driver.run(
            "INSERT INTO [dbo].[items] VALUES (1, N'primeiro');",
            database: source
        )

        let suggested = try await driver.suggestedBackupPath(for: source)
        XCTAssertTrue(suggested.hasSuffix(".bak"), suggested)

        try await driver.backupDatabase(
            source,
            to: backupPath,
            options: SQLServerBackupOptions(compression: true, checksum: true, copyOnly: true)
        )

        let files = try await driver.backupFileList(backupPath)
        XCTAssertEqual(files.filter { !$0.isLog }.count, 1)
        XCTAssertEqual(files.filter(\.isLog).count, 1)

        let existsBefore = try await driver.databaseExists(restored)
        XCTAssertFalse(existsBefore)
        let moves = files.map { file in
            SQLServerRestoreMove(
                logicalName: file.logicalName,
                physicalName: "/var/opt/mssql/data/\(restored)\(file.isLog ? "_log" : "").\(file.isLog ? "ldf" : "mdf")"
            )
        }
        try await driver.restoreDatabase(
            restored,
            from: backupPath,
            moves: moves,
            replace: false,
            closeExisting: false
        )
        let existsAfter = try await driver.databaseExists(restored)
        XCTAssertTrue(existsAfter)

        let rows = try await driver.run(
            "SELECT name FROM [\(restored)].[dbo].[items];",
            database: "master"
        )
        XCTAssertEqual(rows.rows, [["primeiro"]])
    }

    // MARK: - Helpers

    private func makeDriver() throws -> SQLServerDriver {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HERD_TEST_MSSQL"] == "1",
            "Set HERD_TEST_MSSQL=1 to run against a SQL Server instance."
        )
        let env = ProcessInfo.processInfo.environment
        let config = ConnectionConfig(
            name: "local",
            engine: .sqlServer,
            host: env["MSSQL_HOST"] ?? "127.0.0.1",
            port: Int(env["MSSQL_PORT"] ?? "") ?? 1433,
            username: env["MSSQL_USER"] ?? "sa",
            database: "master",
            useTLS: false,
            trustServerCertificate: true
        )
        let password = env["MSSQL_PASSWORD"]
        return SQLServerDriver(config: config, password: password)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Error? {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
        return nil
    } catch {
        return error
    }
}

final class SQLServerFormattingTests: XCTestCase {
    func testShortVersionExtractsSQLServerYear() {
        let info = ServerInfo(version: "Microsoft SQL Server 2022 (RTM-CU14) (KB5040940) - 16.0.4115.5 (X64)")
        XCTAssertEqual(info.shortVersion, "SQL Server 2022")
    }

    func testValueFormatting() {
        XCTAssertNil(SQLServerCellFormatter.string(.null, typeID: nil))
        XCTAssertEqual(SQLServerCellFormatter.string(.bool(true), typeID: nil), "true")
        XCTAssertEqual(SQLServerCellFormatter.string(.int32(42), typeID: nil), "42")
        XCTAssertEqual(SQLServerCellFormatter.string(.decimal(Decimal(string: "12.50")!), typeID: nil), "12.5")
        XCTAssertEqual(SQLServerCellFormatter.string(.bytes([0x00, 0xFF]), typeID: nil), "0x00ff")
        XCTAssertEqual(
            SQLServerCellFormatter.string(
                .uuid(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
                typeID: nil
            ),
            "00000000-0000-0000-0000-000000000001"
        )
    }

    func testDateColumnsDoNotShiftWithLocalTimeZone() {
        let day = Date(timeIntervalSince1970: 1_705_276_800) // 2024-01-15 00:00 UTC
        XCTAssertEqual(
            SQLServerCellFormatter.string(.date(day), typeID: 0x28),
            "2024-01-15"
        )
        XCTAssertEqual(
            SQLServerCellFormatter.string(.date(day), typeID: 0x2A),
            "2024-01-15 00:00:00"
        )
    }
}
