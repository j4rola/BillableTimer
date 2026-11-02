import Foundation

/// Every read and write the app performs. Reports are assembled in Swift from a
/// single range query rather than several GROUP BY round-trips — a reporting range
/// is at most two weeks of entries, so this stays well under a millisecond and
/// keeps nothing but the visible window in memory.
final class Store {
    let db: Database

    /// Columns shared by every entry query, so `Entry.from` always finds what it needs.
    private static let entrySelect = """
        SELECT e.id, e.project_id, e.started_at, e.ended_at, e.note, e.invoice_id,
               m.name AS project_name,
               c.id   AS client_id,
               c.name AS client_name,
               COALESCE(m.hourly_rate_cents, c.hourly_rate_cents) AS rate_cents
        FROM entries e
        JOIN projects m ON m.id = e.project_id
        JOIN clients c ON c.id = m.client_id
        """

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("billabletimer.sqlite3")
        db = try Database(path: file.path)
        try Schema.migrate(db)
    }

    var databasePath: String { db.path }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

    // MARK: - Clients

    func clients(includeArchived: Bool = false) throws -> [Client] {
        let sql = """
            SELECT * FROM clients
            \(includeArchived ? "" : "WHERE archived = 0")
            ORDER BY archived, name COLLATE NOCASE
            """
        return try db.query(sql).map(Client.from)
    }

    @discardableResult
    func createClient(name: String, rateCents: Int, address: String = "", notes: String = "") throws -> Int64 {
        try db.run(
            """
            INSERT INTO clients (name, hourly_rate_cents, address, notes, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            [.text(name), .int(Int64(rateCents)), .text(address), .text(notes), .int(now())]
        )
    }

    func updateClient(_ client: Client) throws {
        try db.run(
            """
            UPDATE clients
            SET name = ?, hourly_rate_cents = ?, address = ?, notes = ?, archived = ?
            WHERE id = ?
            """,
            [
                .text(client.name), .int(Int64(client.hourlyRateCents)), .text(client.address),
                .text(client.notes), .int(client.archived ? 1 : 0), .int(client.id)
            ]
        )
    }

    /// Refuses to delete a client that still has time on the books — archive instead.
    func deleteClient(id: Int64) throws {
        let count = try db.queryOne(
            """
            SELECT COUNT(*) AS n FROM entries e
            JOIN projects m ON m.id = e.project_id
            WHERE m.client_id = ?
            """,
            [.int(id)]
        )?.intOr("n") ?? 0
        guard count == 0 else {
            throw DBError("This client has \(count) time entr\(count == 1 ? "y" : "ies"). Archive it instead of deleting, so the billing history stays intact.")
        }
        try db.transaction {
            try db.run("DELETE FROM projects WHERE client_id = ?;", [.int(id)])
            try db.run("DELETE FROM clients WHERE id = ?;", [.int(id)])
        }
    }

    // MARK: - Projects

    func projects(clientId: Int64? = nil, includeArchived: Bool = false) throws -> [Project] {
        var conditions: [String] = []
        var params: [SQLValue] = []
        if let clientId {
            conditions.append("m.client_id = ?")
            params.append(.int(clientId))
        }
        if !includeArchived {
            conditions.append("m.archived = 0 AND c.archived = 0")
        }
        let sql = """
            SELECT m.id, m.client_id, m.name, m.hourly_rate_cents, m.archived,
                   c.name AS client_name,
                   c.hourly_rate_cents AS client_rate_cents
            FROM projects m
            JOIN clients c ON c.id = m.client_id
            \(conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "))
            ORDER BY c.name COLLATE NOCASE, m.name COLLATE NOCASE
            """
        return try db.query(sql, params).map(Project.from)
    }

    @discardableResult
    func createProject(clientId: Int64, name: String, rateCents: Int?) throws -> Int64 {
        try db.run(
            "INSERT INTO projects (client_id, name, hourly_rate_cents, created_at) VALUES (?, ?, ?, ?)",
            [.int(clientId), .text(name), rateCents.map { .int(Int64($0)) } ?? .null, .int(now())]
        )
    }

    func updateProject(_ project: Project) throws {
        try db.run(
            "UPDATE projects SET name = ?, hourly_rate_cents = ?, archived = ? WHERE id = ?",
            [
                .text(project.name),
                project.hourlyRateCents.map { .int(Int64($0)) } ?? .null,
                .int(project.archived ? 1 : 0),
                .int(project.id)
            ]
        )
    }

    func deleteProject(id: Int64) throws {
        let count = try db.queryOne("SELECT COUNT(*) AS n FROM entries WHERE project_id = ?", [.int(id)])?.intOr("n") ?? 0
        guard count == 0 else {
            throw DBError("This project has \(count) time entr\(count == 1 ? "y" : "ies"). Archive it instead of deleting.")
        }
        try db.run("DELETE FROM projects WHERE id = ?", [.int(id)])
    }

    // MARK: - Timers

    /// Starts a new running entry. Concurrent timers are allowed by design, so
    /// this never stops anything else.
    @discardableResult
    func startTimer(projectId: Int64, note: String = "") throws -> Int64 {
        let stamp = now()
        return try db.run(
            "INSERT INTO entries (project_id, started_at, note, created_at) VALUES (?, ?, ?, ?)",
            [.int(projectId), .int(stamp), .text(note), .int(stamp)]
        )
    }

    func stopTimer(entryId: Int64) throws {
        // max() guards the pathological case of a clock change making end < start.
        try db.run(
            "UPDATE entries SET ended_at = MAX(?, started_at) WHERE id = ? AND ended_at IS NULL",
            [.int(now()), .int(entryId)]
        )
    }

    func stopAllTimers() throws {
        try db.run("UPDATE entries SET ended_at = MAX(?, started_at) WHERE ended_at IS NULL", [.int(now())])
    }

    /// Discards a running timer without recording any time.
    func cancelTimer(entryId: Int64) throws {
        try db.run("DELETE FROM entries WHERE id = ? AND ended_at IS NULL", [.int(entryId)])
    }

    func runningEntries() throws -> [Entry] {
        try db.query("\(Self.entrySelect) WHERE e.ended_at IS NULL ORDER BY e.started_at").map(Entry.from)
    }

    // MARK: - Entries

    /// Entries attributed to `range` by their start time, so an entry is never
    /// split between two days, periods, or invoices.
    func entries(in range: DateRange, clientId: Int64? = nil) throws -> [Entry] {
        var sql = "\(Self.entrySelect) WHERE e.started_at >= ? AND e.started_at < ?"
        var params: [SQLValue] = [
            .int(Int64(range.start.timeIntervalSince1970)),
            .int(Int64(range.end.timeIntervalSince1970))
        ]
        if let clientId {
            sql += " AND c.id = ?"
            params.append(.int(clientId))
        }
        sql += " ORDER BY e.started_at DESC"
        return try db.query(sql, params).map(Entry.from)
    }

    func entry(id: Int64) throws -> Entry? {
        try db.queryOne("\(Self.entrySelect) WHERE e.id = ?", [.int(id)]).map(Entry.from)
    }

    @discardableResult
    func addManualEntry(projectId: Int64, start: Date, end: Date, note: String) throws -> Int64 {
        let startStamp = Int64(start.timeIntervalSince1970)
        let endStamp = max(startStamp, Int64(end.timeIntervalSince1970))
        return try db.run(
            "INSERT INTO entries (project_id, started_at, ended_at, note, created_at) VALUES (?, ?, ?, ?, ?)",
            [.int(projectId), .int(startStamp), .int(endStamp), .text(note), .int(now())]
        )
    }

    /// Edits a stopped entry. Invoiced entries are locked so a sent invoice can't
    /// silently stop matching its underlying time.
    func updateEntry(id: Int64, projectId: Int64, start: Date, end: Date?, note: String) throws {
        if let existing = try entry(id: id), existing.invoiceId != nil {
            throw DBError("This entry is already on an invoice. Delete the invoice first if you need to change it.")
        }
        let startStamp = Int64(start.timeIntervalSince1970)
        let endValue: SQLValue = end.map { .int(max(startStamp, Int64($0.timeIntervalSince1970))) } ?? .null
        try db.run(
            "UPDATE entries SET project_id = ?, started_at = ?, ended_at = ?, note = ? WHERE id = ?",
            [.int(projectId), .int(startStamp), endValue, .text(note), .int(id)]
        )
    }

    func deleteEntry(id: Int64) throws {
        if let existing = try entry(id: id), existing.invoiceId != nil {
            throw DBError("This entry is already on an invoice. Delete the invoice first if you need to remove it.")
        }
        try db.run("DELETE FROM entries WHERE id = ?", [.int(id)])
    }

    // MARK: - Invoicing

    /// Stopped, not-yet-invoiced entries for one client in a period.
    func billableEntries(clientId: Int64, in range: DateRange) throws -> [Entry] {
        try db.query(
            """
            \(Self.entrySelect)
            WHERE c.id = ?
              AND e.invoice_id IS NULL
              AND e.ended_at IS NOT NULL
              AND e.started_at >= ? AND e.started_at < ?
            ORDER BY e.started_at
            """,
            [
                .int(clientId),
                .int(Int64(range.start.timeIntervalSince1970)),
                .int(Int64(range.end.timeIntervalSince1970))
            ]
        ).map(Entry.from)
    }

    /// Records the invoice and stamps its entries in one transaction, so a failure
    /// can't leave entries marked billed against an invoice that doesn't exist.
    @discardableResult
    func recordInvoice(
        clientId: Int64,
        number: String,
        periodStart: Date,
        periodEnd: Date,
        entries: [Entry],
        totalCents: Int,
        seconds: Int,
        filePath: String
    ) throws -> Int64 {
        try db.transaction {
            let invoiceId = try db.run(
                """
                INSERT INTO invoices (client_id, number, issued_at, period_start, period_end, total_cents, seconds, file_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int(clientId), .text(number), .int(now()),
                    .int(Int64(periodStart.timeIntervalSince1970)),
                    .int(Int64(periodEnd.timeIntervalSince1970)),
                    .int(Int64(totalCents)), .int(Int64(seconds)), .text(filePath)
                ]
            )
            for entry in entries {
                try db.run("UPDATE entries SET invoice_id = ? WHERE id = ?", [.int(invoiceId), .int(entry.id)])
            }
            return invoiceId
        }
    }

    func invoices() throws -> [Invoice] {
        try db.query(
            """
            SELECT i.*, c.name AS client_name,
                   (SELECT GROUP_CONCAT(name, ' + ') FROM (
                       SELECT DISTINCT other.name FROM entries e
                       JOIN projects m ON m.id = e.project_id
                       JOIN clients other ON other.id = m.client_id
                       WHERE e.invoice_id = i.id AND other.id <> i.client_id
                       ORDER BY other.name COLLATE NOCASE
                   )) AS other_clients
            FROM invoices i
            JOIN clients c ON c.id = i.client_id
            ORDER BY i.issued_at DESC
            """
        ).map(Invoice.from)
    }

    /// Deleting an invoice releases its entries back into the billable pool.
    func deleteInvoice(id: Int64) throws {
        try db.transaction {
            try db.run("UPDATE entries SET invoice_id = NULL WHERE invoice_id = ?", [.int(id)])
            try db.run("DELETE FROM invoices WHERE id = ?", [.int(id)])
        }
    }

    // MARK: - Settings

    func loadSettings() throws -> AppSettings {
        var settings = AppSettings()
        var values: [String: String] = [:]
        for row in try db.query("SELECT key, value FROM settings") {
            values[row.stringOr("key")] = row.stringOr("value")
        }
        settings.businessName = values["businessName"] ?? settings.businessName
        settings.businessAddress = values["businessAddress"] ?? settings.businessAddress
        settings.businessEmail = values["businessEmail"] ?? settings.businessEmail
        settings.invoiceTerms = values["invoiceTerms"] ?? settings.invoiceTerms
        settings.invoicePrefix = values["invoicePrefix"] ?? settings.invoicePrefix
        settings.nextInvoiceNumber = values["nextInvoiceNumber"].flatMap(Int.init) ?? settings.nextInvoiceNumber
        settings.firstWeekday = values["firstWeekday"].flatMap(Int.init) ?? settings.firstWeekday
        if let anchor = values["periodAnchor"].flatMap(Double.init) {
            settings.periodAnchor = Date(timeIntervalSince1970: anchor)
        }
        return settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        let pairs: [(String, String)] = [
            ("businessName", settings.businessName),
            ("businessAddress", settings.businessAddress),
            ("businessEmail", settings.businessEmail),
            ("invoiceTerms", settings.invoiceTerms),
            ("invoicePrefix", settings.invoicePrefix),
            ("nextInvoiceNumber", String(settings.nextInvoiceNumber)),
            ("firstWeekday", String(settings.firstWeekday)),
            ("periodAnchor", String(settings.periodAnchor.timeIntervalSince1970))
        ]
        try db.transaction {
            for (key, value) in pairs {
                try db.run(
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [.text(key), .text(value)]
                )
            }
        }
    }
}
