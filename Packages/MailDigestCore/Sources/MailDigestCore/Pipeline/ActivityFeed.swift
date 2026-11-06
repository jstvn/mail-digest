import Foundation

/// One line of the activity log. Never carries email bodies; sender and subject only.
public struct ActivityRow: Sendable, Equatable, Identifiable {
    public var id: UUID          // the job item id
    public var position: Int
    public var sender: String
    public var subject: String
    public var mailbox: MailboxRef
    public var state: JobItemState
    public var outcome: String?
    public var seconds: Double?
    public var finishedAt: Date?

    public init(id: UUID, position: Int, sender: String, subject: String, mailbox: MailboxRef,
                state: JobItemState, outcome: String?, seconds: Double?, finishedAt: Date?) {
        self.id = id
        self.position = position
        self.sender = sender
        self.subject = subject
        self.mailbox = mailbox
        self.state = state
        self.outcome = outcome
        self.seconds = seconds
        self.finishedAt = finishedAt
    }
}

/// Turns job items and progress into the text and rows the progress UI shows.
public struct ActivityFeed: Sendable {
    public init() {}

    /// All rows by position, optionally only one state.
    public func rows(_ items: [JobItem], filter: JobItemState? = nil) -> [ActivityRow] {
        items.filter { filter == nil || $0.state == filter }
            .sorted { $0.position < $1.position }
            .map(row)
    }

    /// The last finished emails: newest `finishedAt` first, ties by higher position.
    public func recent(_ items: [JobItem], limit: Int = 5) -> [ActivityRow] {
        let finished = items.filter { [.done, .failed, .skipped].contains($0.state) }
        let sorted = finished.sorted {
            let a = $0.finishedAt ?? .distantPast, b = $1.finishedAt ?? .distantPast
            return a != b ? a > b : $0.position > $1.position
        }
        return sorted.prefix(max(0, limit)).map(row)
    }

    /// "Paused after #412 · Ray White · Rent due Friday. Next: #413 · QUT Canvas · Assessment 2 reminder".
    /// Nil unless the job is paused. Either half is left out when there is no such item.
    public func pausedSummary(progress: JobProgress) -> String? {
        guard progress.state == .paused else { return nil }
        func part(_ s: JobItemSummary) -> String { "#\(s.position) · \(Self.displayName(s.sender)) · \(s.subject)" }
        switch (progress.lastFinished, progress.nextUp) {
        case let (last?, next?): return "Paused after \(part(last)). Next: \(part(next))"
        case let (last?, nil): return "Paused after \(part(last))"
        case let (nil, next?): return "Paused. Next: \(part(next))"
        case (nil, nil): return "Paused"
        }
    }

    /// "Summarising · Ray White · Rent due Friday · Outlook Inbox", or nil when no email is in flight.
    public func nowLine(progress: JobProgress) -> String? {
        guard let c = progress.current else { return nil }
        let stage = progress.stage.rawValue.prefix(1).uppercased() + progress.stage.rawValue.dropFirst()
        return "\(stage) · \(Self.displayName(c.sender)) · \(c.subject) · \(c.mailbox.account) \(c.mailbox.name)"
    }

    /// "412 of 1,081 · 6 failed · about 3 h 50 min left"; failed and time are left out when zero or unknown.
    public func statusLine(progress: JobProgress) -> String {
        var parts = ["\(JobFormat.number(progress.done)) of \(JobFormat.number(progress.total))"]
        if progress.failed > 0 { parts.append("\(JobFormat.number(progress.failed)) failed") }
        if let eta = progress.eta { parts.append("\(JobFormat.duration(eta)) left") }
        return parts.joined(separator: " · ")
    }

    /// The name part of "Name <addr>", or the bare address when there is no name.
    static func displayName(_ sender: String) -> String {
        guard let open = sender.firstIndex(of: "<") else { return sender.trimmingCharacters(in: .whitespaces) }
        let name = sender[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        return name.isEmpty ? MailFilter.address(from: sender) : name
    }

    private func row(_ i: JobItem) -> ActivityRow {
        ActivityRow(id: i.id, position: i.position, sender: i.sender, subject: i.subject, mailbox: i.mailbox,
                    state: i.state, outcome: i.outcome, seconds: i.seconds, finishedAt: i.finishedAt)
    }
}
