import Foundation

struct Client: Identifiable, Hashable {
    var id: Int64
    var name: String
    var hourlyRateCents: Int
    var address: String
    var notes: String
    var archived: Bool

    static func from(_ row: Row) -> Client {
        Client(
            id: row.intOr("id"),
            name: row.stringOr("name"),
            hourlyRateCents: Int(row.intOr("hourly_rate_cents")),
            address: row.stringOr("address"),
            notes: row.stringOr("notes"),
            archived: row.bool("archived")
        )
    }
}

struct Project: Identifiable, Hashable {
    var id: Int64
    var clientId: Int64
    var clientName: String
    var name: String
    /// nil means "use the client's rate"
    var hourlyRateCents: Int?
    var archived: Bool
    /// The rate actually charged, after inheritance.
    var effectiveRateCents: Int

    var displayName: String { "\(clientName) › \(name)" }

    static func from(_ row: Row) -> Project {
        let override = row.int("hourly_rate_cents").map(Int.init)
        return Project(
            id: row.intOr("id"),
            clientId: row.intOr("client_id"),
            clientName: row.stringOr("client_name"),
            name: row.stringOr("name"),
            hourlyRateCents: override,
            archived: row.bool("archived"),
            effectiveRateCents: override ?? Int(row.intOr("client_rate_cents"))
        )
    }
}

struct Entry: Identifiable, Hashable {
    var id: Int64
    var projectId: Int64
    var projectName: String
    var clientId: Int64
    var clientName: String
    var startedAt: Date
    var endedAt: Date?
    var note: String
    var rateCents: Int
    var invoiceId: Int64?

    var isRunning: Bool { endedAt == nil }

    /// Elapsed seconds as of `now`, which is only consulted for a running timer.
    func seconds(asOf now: Date) -> Int {
        let end = endedAt ?? now
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }

    func hours(asOf now: Date) -> Double { Double(seconds(asOf: now)) / 3600 }

    func amountCents(asOf now: Date) -> Int {
        Int((hours(asOf: now) * Double(rateCents)).rounded())
    }

    static func from(_ row: Row) -> Entry {
        Entry(
            id: row.intOr("id"),
            projectId: row.intOr("project_id"),
            projectName: row.stringOr("project_name"),
            clientId: row.intOr("client_id"),
            clientName: row.stringOr("client_name"),
            startedAt: Date(timeIntervalSince1970: TimeInterval(row.intOr("started_at"))),
            endedAt: row.int("ended_at").map { Date(timeIntervalSince1970: TimeInterval($0)) },
            note: row.stringOr("note"),
            rateCents: Int(row.intOr("rate_cents")),
            invoiceId: row.int("invoice_id")
        )
    }
}

/// One line of a report: total time for a client, or for a project within a client.
struct BreakdownRow: Identifiable, Hashable {
    var id: String
    var clientId: Int64
    var clientName: String
    var projectId: Int64?
    var projectName: String?
    var seconds: Int
    var rateCents: Int

    var hours: Double { Double(seconds) / 3600 }
    var amountCents: Int { Int((hours * Double(rateCents)).rounded()) }
    var label: String { projectName.map { "\(clientName) › \($0)" } ?? clientName }
}

struct DayTotal: Identifiable, Hashable {
    var id: Date { day }
    var day: Date
    var seconds: Int

    var hours: Double { Double(seconds) / 3600 }
}

struct Invoice: Identifiable, Hashable {
    var id: Int64
    var clientId: Int64
    var clientName: String
    var number: String
    var issuedAt: Date
    var periodStart: Date
    var periodEnd: Date
    var totalCents: Int
    var seconds: Int
    var filePath: String

    var hours: Double { Double(seconds) / 3600 }

    static func from(_ row: Row) -> Invoice {
        Invoice(
            id: row.intOr("id"),
            clientId: row.intOr("client_id"),
            clientName: row.stringOr("client_name"),
            number: row.stringOr("number"),
            issuedAt: Date(timeIntervalSince1970: TimeInterval(row.intOr("issued_at"))),
            periodStart: Date(timeIntervalSince1970: TimeInterval(row.intOr("period_start"))),
            periodEnd: Date(timeIntervalSince1970: TimeInterval(row.intOr("period_end"))),
            totalCents: Int(row.intOr("total_cents")),
            seconds: Int(row.intOr("seconds")),
            filePath: row.stringOr("file_path")
        )
    }
}

/// Business identity and preferences, persisted in the `settings` key/value table.
struct AppSettings {
    var businessName: String = ""
    var businessAddress: String = ""
    var businessEmail: String = ""
    var invoiceTerms: String = "Payable within 30 days."
    var invoicePrefix: String = "INV-"
    var nextInvoiceNumber: Int = 1
    /// Calendar.firstWeekday convention: 1 = Sunday, 2 = Monday.
    var firstWeekday: Int = 2
    /// Local midnight on a day that begins a two-week billing period.
    var periodAnchor: Date = Calendar.current.startOfDay(for: Date())
}
