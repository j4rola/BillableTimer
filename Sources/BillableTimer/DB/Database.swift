import Foundation
import SQLite3

/// Tells SQLite to copy bound strings/blobs rather than assume they outlive the call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DBError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

/// One row of a result set, addressed by column name.
struct Row {
    private let values: [String: SQLValue]

    init(_ values: [String: SQLValue]) { self.values = values }

    func int(_ column: String) -> Int64? {
        if case .int(let v)? = values[column] { return v }
        if case .double(let v)? = values[column] { return Int64(v) }
        return nil
    }

    func intOr(_ column: String, _ fallback: Int64 = 0) -> Int64 { int(column) ?? fallback }

    func double(_ column: String) -> Double? {
        if case .double(let v)? = values[column] { return v }
        if case .int(let v)? = values[column] { return Double(v) }
        return nil
    }

    func string(_ column: String) -> String? {
        if case .text(let v)? = values[column] { return v }
        return nil
    }

    func stringOr(_ column: String, _ fallback: String = "") -> String { string(column) ?? fallback }

    func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }
}

/// Thin wrapper over the system libsqlite3. No third-party dependencies, so the
/// app ships as a single self-contained binary with nothing to install.
final class Database {
    private var db: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw DBError("Could not open database at \(path): \(message)")
        }
        db = handle
        // WAL keeps reads from blocking the UI while a write is in flight.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA busy_timeout = 3000;")
    }

    deinit { sqlite3_close_v2(db) }

    private func lastError(_ context: String) -> DBError {
        DBError("\(context): \(String(cString: sqlite3_errmsg(db)))")
    }

    /// Runs one or more statements with no parameters and no results.
    func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw DBError("SQL failed: \(message)\n\(sql)")
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError("Could not prepare statement\n\(sql)")
        }
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch param {
            case .null: result = sqlite3_bind_null(stmt, index)
            case .int(let v): result = sqlite3_bind_int64(stmt, index, v)
            case .double(let v): result = sqlite3_bind_double(stmt, index, v)
            case .text(let v): result = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            }
            if result != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw lastError("Could not bind parameter \(index)")
            }
        }
        return stmt
    }

    /// Executes a statement that returns no rows. Returns the last inserted row id.
    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw lastError("Statement failed\n\(sql)")
        }
        return sqlite3_last_insert_rowid(db)
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }

        let columnCount = sqlite3_column_count(stmt)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(stmt, index)))
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw lastError("Query failed\n\(sql)") }

            var values: [String: SQLValue] = [:]
            values.reserveCapacity(Int(columnCount))
            for index in 0..<columnCount {
                let value: SQLValue
                switch sqlite3_column_type(stmt, index) {
                case SQLITE_INTEGER: value = .int(sqlite3_column_int64(stmt, index))
                case SQLITE_FLOAT: value = .double(sqlite3_column_double(stmt, index))
                case SQLITE_TEXT:
                    if let raw = sqlite3_column_text(stmt, index) {
                        value = .text(String(cString: raw))
                    } else {
                        value = .null
                    }
                default: value = .null
                }
                values[names[Int(index)]] = value
            }
            rows.append(Row(values))
        }
        return rows
    }

    func queryOne(_ sql: String, _ params: [SQLValue] = []) throws -> Row? {
        try query(sql, params).first
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }
}
