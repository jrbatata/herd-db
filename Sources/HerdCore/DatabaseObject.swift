import Foundation

/// Kind of object the palette and the sidebar can search.
public enum DatabaseObjectKind: String, Codable, Hashable, Sendable, CaseIterable {
    case table
    case view
    case materializedView
    case function
    case procedure

    public var displayName: String {
        switch self {
        case .table: "Tabela"
        case .view: "View"
        case .materializedView: "View materializada"
        case .function: "Função"
        case .procedure: "Procedimento"
        }
    }

    public var isRoutine: Bool {
        self == .function || self == .procedure
    }
}

/// One object of a database, without the connection: the palette adds that context.
public struct DatabaseObject: Identifiable, Hashable, Sendable {
    public var schema: String
    public var name: String
    public var kind: DatabaseObjectKind

    public var id: String { "\(schema).\(name).\(kind.rawValue)" }

    public init(schema: String, name: String, kind: DatabaseObjectKind) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }
}

public enum RoutineKind: String, Codable, Hashable, Sendable, CaseIterable {
    case function
    case procedure

    public var displayName: String {
        switch self {
        case .function: "Função"
        case .procedure: "Procedimento"
        }
    }

    public var objectKind: DatabaseObjectKind {
        switch self {
        case .function: .function
        case .procedure: .procedure
        }
    }
}

/// A function or procedure, listed under its schema in the sidebar.
public struct RoutineInfo: Identifiable, Hashable, Sendable {
    public var schema: String
    public var name: String
    public var kind: RoutineKind

    public var id: String { "\(schema).\(name).\(kind.rawValue)" }

    public init(schema: String, name: String, kind: RoutineKind) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }
}
