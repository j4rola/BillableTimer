import Foundation

/// Schema versions are applied in order and recorded via `PRAGMA user_version`,
/// so upgrading an existing database never loses billing history.
enum Schema {
    static let migrations: [String] = [
        // v1 — clients, projects, entries, settings, invoices
        """
        CREATE TABLE clients (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            name              TEXT    NOT NULL,
            hourly_rate_cents INTEGER NOT NULL DEFAULT 0,
            address           TEXT    NOT NULL DEFAULT '',
            notes             TEXT    NOT NULL DEFAULT '',
            archived          INTEGER NOT NULL DEFAULT 0,
            created_at        INTEGER NOT NULL
        );

        CREATE TABLE projects (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            client_id         INTEGER NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
            name              TEXT    NOT NULL,
            hourly_rate_cents INTEGER,          -- NULL means inherit the client rate
            archived          INTEGER NOT NULL DEFAULT 0,
            created_at        INTEGER NOT NULL
        );

        CREATE TABLE entries (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id   INTEGER NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
            started_at  INTEGER NOT NULL,        -- unix seconds
            ended_at    INTEGER,                 -- NULL while the timer is running
            note        TEXT    NOT NULL DEFAULT '',
            invoice_id  INTEGER REFERENCES invoices(id) ON DELETE SET NULL,
            created_at  INTEGER NOT NULL
        );

        CREATE TABLE invoices (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            client_id    INTEGER NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
            number       TEXT    NOT NULL,
            issued_at    INTEGER NOT NULL,
            period_start INTEGER NOT NULL,
            period_end   INTEGER NOT NULL,
            total_cents  INTEGER NOT NULL,
            seconds      INTEGER NOT NULL,
            file_path    TEXT    NOT NULL DEFAULT ''
        );

        CREATE TABLE settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE INDEX idx_entries_started ON entries(started_at);
        CREATE INDEX idx_entries_project  ON entries(project_id);
        CREATE INDEX idx_entries_invoice ON entries(invoice_id);
        CREATE INDEX idx_projects_client  ON projects(client_id);
        -- Partial index: looking up what's currently running stays O(running), not O(all entries).
        CREATE INDEX idx_entries_running ON entries(id) WHERE ended_at IS NULL;
        """
    ]

    static func migrate(_ db: Database) throws {
        let current = Int(try db.queryOne("PRAGMA user_version;")?.intOr("user_version") ?? 0)
        guard current < migrations.count else { return }

        for version in current..<migrations.count {
            try db.transaction {
                try db.exec(migrations[version])
                // PRAGMA can't be parameterised, and `version` is a loop index we control.
                try db.exec("PRAGMA user_version = \(version + 1);")
            }
        }
    }
}
