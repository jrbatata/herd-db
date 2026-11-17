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

    func testLogicalBackupAndRestoreToNewDatabase() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let source = "herd_log_src_\(suffix)"
        let restored = "herd_log_dst_\(suffix)"
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herd-log-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backupURL = backupDirectory.appendingPathComponent("\(source).sql")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: backupDirectory)
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
        _ = try await driver.run("CREATE SCHEMA [app];", database: source)
        _ = try await driver.run(
            "CREATE SEQUENCE [app].[order_seq] AS int START WITH 100 INCREMENT BY 5;",
            database: source
        )
        _ = try await driver.run(
            "CREATE TYPE [app].[phone] FROM varchar(20) NOT NULL;",
            database: source
        )
        _ = try await driver.run(
            """
            CREATE TABLE [app].[owners] (
                id int IDENTITY(1,1) NOT NULL CONSTRAINT [pk_owners] PRIMARY KEY,
                name nvarchar(100) NOT NULL,
                phone [app].[phone] NULL,
                payload varbinary(max) NULL,
                balance decimal(18,2) NOT NULL CONSTRAINT [df_owners_balance] DEFAULT 0,
                created datetime2(7) NOT NULL CONSTRAINT [df_owners_created] DEFAULT sysutcdatetime(),
                CONSTRAINT [ck_owners_balance] CHECK (balance >= 0)
            );
            """,
            database: source
        )
        _ = try await driver.run(
            """
            CREATE TABLE [app].[items] (
                id int NOT NULL CONSTRAINT [pk_items] PRIMARY KEY,
                owner_id int NULL,
                title nvarchar(200) NOT NULL,
                code varchar(10) NULL,
                qty smallint NOT NULL,
                price money NULL,
                active bit NOT NULL CONSTRAINT [df_items_active] DEFAULT 1,
                uid uniqueidentifier NOT NULL CONSTRAINT [df_items_uid] DEFAULT newid(),
                notes xml NULL,
                created date NULL,
                at_time time(7) NULL,
                stamp datetimeoffset(7) NULL,
                big nvarchar(max) NULL,
                blob varbinary(max) NULL,
                CONSTRAINT [fk_items_owner] FOREIGN KEY (owner_id)
                    REFERENCES [app].[owners](id) ON DELETE SET NULL
            );
            """,
            database: source
        )
        _ = try await driver.run(
            "CREATE INDEX [ix_items_owner] ON [app].[items](owner_id) INCLUDE (title);",
            database: source
        )
        _ = try await driver.run(
            "CREATE VIEW [app].[v_items] AS SELECT id, title FROM [app].[items];",
            database: source
        )
        _ = try await driver.run(
            "CREATE PROCEDURE [app].[p_items] AS SELECT COUNT(*) AS total FROM [app].[items];",
            database: source
        )
        _ = try await driver.run(
            "CREATE FUNCTION [app].[f_double](@n int) RETURNS int AS BEGIN RETURN @n * 2 END",
            database: source
        )
        _ = try await driver.run(
            "CREATE TRIGGER [app].[trg_items] ON [app].[items] AFTER INSERT AS RETURN",
            database: source
        )

        _ = try await driver.run(
            """
            INSERT INTO [app].[owners] (name, phone, payload, balance) VALUES
                (N'Ana ''Bia''', '11999999999', 0x00FF10, 10.50),
                (N'João 🚀' + NCHAR(10) + N'GO' + NCHAR(10) + N'fim', NULL, NULL, 0);
            """,
            database: source
        )
        _ = try await driver.run(
            """
            INSERT INTO [app].[items]
                (id, owner_id, title, code, qty, price, active, notes, created, at_time, stamp)
            SELECT TOP (1200)
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
                CASE WHEN ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 3 = 0 THEN 1 ELSE NULL END,
                N'Item ' + CONVERT(nvarchar(10), ROW_NUMBER() OVER (ORDER BY (SELECT NULL))),
                'C' + RIGHT('000' + CONVERT(varchar(10), ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 10), 3),
                (ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 100),
                CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) * 1.25 AS money),
                1,
                N'<r><n>1</n></r>',
                '2024-01-15',
                '13:45:12.1234567',
                '2024-01-15T13:45:12.1234567+00:00'
            FROM sys.all_objects a CROSS JOIN sys.all_objects b;
            """,
            database: source
        )
        _ = try await driver.run(
            """
            UPDATE [app].[items]
            SET big = REPLICATE(CAST(N'á' AS nvarchar(max)), 200000),
                blob = CONVERT(varbinary(max), REPLICATE(CAST('x' AS varchar(max)), 200000))
            WHERE id = 1;
            """,
            database: source
        )
        let sequence = try await driver.run(
            "SELECT NEXT VALUE FOR [app].[order_seq] AS value;",
            database: source
        )
        XCTAssertEqual(sequence.rows, [["100"]])

        let backup = try await driver.exportLogicalBackup(
            database: source,
            to: backupURL,
            options: SQLServerLogicalBackupOptions(
                includeData: true,
                includeDropStatements: true,
                includeIndexes: true,
                includeProgrammability: true,
                pageSize: 500,
                insertBatchSize: 100
            )
        )
        XCTAssertEqual(backup.tableCount, 2)
        XCTAssertEqual(backup.rowCount, 1202)
        XCTAssertGreaterThan(backup.bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let script = try String(contentsOf: backupURL, encoding: .utf8)
        XCTAssertTrue(script.contains("CREATE TABLE [app].[items]"))
        XCTAssertTrue(script.contains("IDENTITY(1,1)"))
        XCTAssertTrue(script.contains("SET IDENTITY_INSERT [app].[owners] ON"))
        XCTAssertTrue(script.contains("<r><n>1</n></r>"))
        XCTAssertTrue(script.contains("CREATE VIEW [app].[v_items]"))

        _ = try await driver.run("CREATE DATABASE [\(restored)];", database: "master")
        let restore = try await driver.restoreLogicalScript(
            database: restored,
            from: backupURL,
            options: SQLServerScriptRestoreOptions(stopOnError: true)
        )
        XCTAssertGreaterThan(restore.batchCount, 10)
        XCTAssertTrue(restore.warnings.isEmpty, restore.warnings.joined(separator: "\n"))

        let counts = try await driver.run(
            """
            SELECT
                (SELECT COUNT(*) FROM [app].[owners]),
                (SELECT COUNT(*) FROM [app].[items]),
                (SELECT COUNT(*) FROM [app].[v_items]);
            """,
            database: restored
        )
        XCTAssertEqual(counts.rows, [["2", "1200", "1200"]])

        let ownersSQL = """
            SELECT name, phone, payload, balance, created
            FROM [app].[owners] ORDER BY id;
            """
        let sourceOwners = try await driver.run(ownersSQL, database: source)
        let restoredOwners = try await driver.run(ownersSQL, database: restored)
        XCTAssertEqual(sourceOwners.rows, restoredOwners.rows)

        let accountsSQL = """
            SELECT id, owner_id, title, code, qty, price, active,
                   CONVERT(nvarchar(max), notes), created, at_time, stamp, uid,
                   LEN(big), DATALENGTH(blob),
                   CONVERT(varchar(64), HASHBYTES('SHA2_256', big), 2),
                   CONVERT(varchar(64), HASHBYTES('SHA2_256', blob), 2)
            FROM [app].[items] WHERE id IN (1, 7, 600, 1200) ORDER BY id;
            """
        let sourceItems = try await driver.run(accountsSQL, database: source)
        let restoredItems = try await driver.run(accountsSQL, database: restored)
        XCTAssertEqual(sourceItems.rows, restoredItems.rows)
        XCTAssertEqual(restoredItems.rows[1][2], "Item 7")
        XCTAssertEqual(restoredItems.rows[1][7], "<r><n>1</n></r>")
        XCTAssertEqual(restoredItems.rows[0][12], "200000")
        XCTAssertEqual(restoredItems.rows[0][13], "200000")

        let objects = try await driver.run(
            """
            SELECT
                OBJECT_ID(N'[app].[v_items]', N'V'),
                OBJECT_ID(N'[app].[p_items]', N'P'),
                OBJECT_ID(N'[app].[f_double]', N'FN'),
                OBJECT_ID(N'[app].[trg_items]', N'TR'),
                OBJECT_ID(N'[app].[fk_items_owner]', N'F'),
                OBJECT_ID(N'[app].[ck_owners_balance]', N'C'),
                TYPE_ID(N'[app].[phone]');
            """,
            database: restored
        )
        XCTAssertFalse(objects.rows[0].contains(nil), objects.rows[0].compactMap { $0 }.joined(separator: ", "))

        let index = try await driver.run(
            "SELECT COUNT(*) FROM sys.indexes WHERE name = N'ix_items_owner';",
            database: restored
        )
        XCTAssertEqual(index.rows, [["1"]])

        let nextSequence = try await driver.run(
            "SELECT NEXT VALUE FOR [app].[order_seq] AS value;",
            database: restored
        )
        XCTAssertEqual(nextSequence.rows, [["105"]])

        _ = try await driver.run(
            "INSERT INTO [app].[owners] (name) VALUES (N'Novo');",
            database: restored
        )
        let identity = try await driver.run(
            "SELECT MAX(id) FROM [app].[owners];",
            database: restored
        )
        XCTAssertEqual(identity.rows, [["3"]])

        let invalidOwner = await XCTAssertThrowsErrorAsync {
            try await driver.run(
                "INSERT INTO [app].[items] (id, owner_id, title, qty, active) VALUES (99999, 777, N'x', 1, 0);",
                database: restored
            )
        }
        XCTAssertNotNil(invalidOwner)

        // Reexecutar o script no mesmo banco precisa funcionar (DROP + CREATE).
        let rerun = try await driver.restoreLogicalScript(database: restored, from: backupURL)
        XCTAssertTrue(rerun.warnings.isEmpty, rerun.warnings.joined(separator: "\n"))
        let rerunCounts = try await driver.run(
            """
            SELECT
                (SELECT COUNT(*) FROM [app].[owners]),
                (SELECT COUNT(*) FROM [app].[items]);
            """,
            database: restored
        )
        XCTAssertEqual(rerunCounts.rows, [["2", "1200"]])
    }

    func testLogicalBackupOfSingleTableSkipsItsDependencies() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let source = "herd_tbl_src_\(suffix)"
        let restored = "herd_tbl_dst_\(suffix)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herd-tbl-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = directory.appendingPathComponent("tabela.sql")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
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
        _ = try await driver.run("CREATE SCHEMA [app];", database: source)
        _ = try await driver.run(
            "CREATE TABLE [app].[authors] (id int PRIMARY KEY, name nvarchar(50) NOT NULL);",
            database: source
        )
        _ = try await driver.run(
            """
            CREATE TABLE [app].[books] (
                id int PRIMARY KEY,
                author_id int NULL,
                title nvarchar(100) NOT NULL,
                CONSTRAINT [fk_books_author] FOREIGN KEY (author_id) REFERENCES [app].[authors](id)
            );
            """,
            database: source
        )
        _ = try await driver.run(
            "INSERT INTO [app].[authors] VALUES (1, N'Autora'); INSERT INTO [app].[books] VALUES (1, 1, N'Livro');",
            database: source
        )

        _ = try await driver.exportLogicalBackup(
            database: source,
            to: backupURL,
            options: SQLServerLogicalBackupOptions(tables: ["app.books"])
        )
        let script = try String(contentsOf: backupURL, encoding: .utf8)
        XCTAssertTrue(script.contains("CREATE TABLE [app].[books]"))
        XCTAssertFalse(script.contains("CREATE TABLE [app].[authors]"))
        XCTAssertFalse(script.contains("fk_books_author"))

        _ = try await driver.run("CREATE DATABASE [\(restored)];", database: "master")
        _ = try await driver.restoreLogicalScript(database: restored, from: backupURL)

        let result = try await driver.run(
            "SELECT COUNT(*) FROM [app].[books];",
            database: restored
        )
        XCTAssertEqual(result.rows, [["1"]])
        let authors = try await driver.run(
            "SELECT OBJECT_ID(N'[app].[authors]');",
            database: restored
        )
        XCTAssertEqual(authors.rows, [[nil]])
    }

    func testLargeBatchKeepsTheConnectionUsable() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let text = String(repeating: "a", count: 200_000)
        let length = try await driver.run("SELECT LEN(N'\(text)') AS n;", database: "master")
        XCTAssertEqual(length.rows, [["200000"]])

        let after = try await driver.run("SELECT 42 AS answer;", database: "master")
        XCTAssertEqual(after.rows, [["42"]])
    }

    func testLogicalBackupRejectsUnsupportedColumnType() async throws {
        let driver = try makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let source = "herd_unsup_\(suffix)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herd-unsup-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = directory.appendingPathComponent("backup.sql")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            await driver.shutdown()
            _ = try? await driver.run(
                "ALTER DATABASE [\(source)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [\(source)];",
                database: "master"
            )
        }

        _ = try await driver.run("CREATE DATABASE [\(source)];", database: "master")
        _ = try await driver.run("CREATE SCHEMA [app];", database: source)
        _ = try await driver.run(
            "CREATE TABLE [app].[variants] (id int PRIMARY KEY, value sql_variant NULL);",
            database: source
        )

        do {
            _ = try await driver.exportLogicalBackup(database: source, to: backupURL)
            XCTFail("O backup deveria recusar sql_variant.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sql_variant"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
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

    func testScriptSplitterRecognizesGO() {
        XCTAssertTrue(SQLServerScriptSplitter.isBatchSeparator("GO"))
        XCTAssertTrue(SQLServerScriptSplitter.isBatchSeparator("  go  "))
        XCTAssertTrue(SQLServerScriptSplitter.isBatchSeparator("GO 3"))
        XCTAssertTrue(SQLServerScriptSplitter.isBatchSeparator("go 10"))
        XCTAssertFalse(SQLServerScriptSplitter.isBatchSeparator("GOTO label"))
        XCTAssertFalse(SQLServerScriptSplitter.isBatchSeparator("GO;"))
        XCTAssertFalse(SQLServerScriptSplitter.isBatchSeparator("SELECT 1"))
        XCTAssertEqual(SQLServerScriptSplitter.repeatCount(for: "GO"), 1)
        XCTAssertEqual(SQLServerScriptSplitter.repeatCount(for: "go 4"), 4)
        XCTAssertNil(SQLServerScriptSplitter.repeatCount(for: "SELECT 1"))
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
