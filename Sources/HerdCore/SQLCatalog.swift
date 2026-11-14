import Foundation

/// One column of the catalog, flattened across schemas and tables so the
/// autocomplete can suggest columns without one query per table.
public struct CatalogColumn: Hashable, Sendable {
    public var schema: String
    public var table: String
    public var name: String
    public var dataType: String

    public init(schema: String, table: String, name: String, dataType: String) {
        self.schema = schema
        self.table = table
        self.name = name
        self.dataType = dataType
    }
}

/// Snapshot of the objects of a database, used by autocomplete and ready-made queries.
public struct SQLCatalog: Equatable, Sendable {
    public var schemas: [String]
    public var tables: [TableInfo]
    public var columns: [CatalogColumn]

    public init(schemas: [String] = [], tables: [TableInfo] = [], columns: [CatalogColumn] = []) {
        self.schemas = schemas
        self.tables = tables
        self.columns = columns
    }

    public static let empty = SQLCatalog()

    public var isEmpty: Bool {
        schemas.isEmpty && tables.isEmpty && columns.isEmpty
    }

    public func tables(in schema: String) -> [TableInfo] {
        tables.filter { $0.schema.caseInsensitiveCompare(schema) == .orderedSame }
    }

    public func columns(schema: String, table: String) -> [CatalogColumn] {
        columns.filter {
            $0.schema.caseInsensitiveCompare(schema) == .orderedSame
                && $0.table.caseInsensitiveCompare(table) == .orderedSame
        }
    }

    public func table(named name: String, schema: String? = nil) -> TableInfo? {
        if let schema {
            return tables.first {
                $0.schema.caseInsensitiveCompare(schema) == .orderedSame
                    && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
        }
        return tables.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
