import Domain
import Foundation
import SQLite3

public enum SQLiteError: Error, Sendable, Equatable {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case backupFailed(String)
}

enum SQLiteValue: Sendable {
    case text(String)
    case int(Int)
    case double(Double)
    case null
}

final class SQLiteRow: @unchecked Sendable {
    let statement: OpaquePointer

    init(statement: OpaquePointer) {
        self.statement = statement
    }

    func string(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func int(_ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    func double(_ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
