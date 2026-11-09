import Foundation

/// The text of the one-line "last Daily digest" row in the menu panel.
public struct MenuSuggestionsRow: Sendable, Equatable {
    /// "3 suggestions from this morning".
    public var title: String
    /// "8 emails · finished 7:28 am".
    public var subtitle: String
}

/// What the menu panel's attention card says and offers.
public struct MenuAttentionCard: Sendable, Equatable {
    public var title: String
    public var message: String
    /// Whether the card offers "Start Ollama" next to Retry.
    public var offersStartOllama: Bool
}

/// Wording for the menu bar panel: job titles, the last-run row and the attention state. Pure; the calendar
/// (time zone), locale and `now` are injected so results are testable.
public enum MenuPanelPresentation {
    // MARK: Job title

    /// "Daily Digest", or for Backlog the scope: "Backlog · 12 Nov" for one day, "Backlog · 10 Oct – 12 Nov"
    /// for several. `to` is exclusive (mail is listed in [from, to)), so the last included day is the one that
    /// holds `to - 1 s`. A scope that starts before 1990 is "everything": "Backlog · Up to 12 Nov".
    public static func jobTitle(kind: JobKind, from: Date, to: Date, calendar: Calendar, locale: Locale) -> String {
        guard kind == .backlog else { return "Daily Digest" }
        let last = max(to.addingTimeInterval(-1), from)
        let end = dayMonth(last, calendar: calendar, locale: locale)
        if from.timeIntervalSince1970 < 631_152_000 { return "Backlog · Up to \(end)" }
        let start = dayMonth(from, calendar: calendar, locale: locale)
        if calendar.isDate(from, inSameDayAs: last) { return "Backlog · \(start)" }
        return "Backlog · \(start) \u{2013} \(end)"
    }

    public static func jobTitle(_ job: Job, calendar: Calendar, locale: Locale) -> String {
        jobTitle(kind: job.kind, from: job.scopeFrom, to: job.scopeTo, calendar: calendar, locale: locale)
    }

    // MARK: Status line

    /// The line under the title while a job is active. Listing, pausing, paused (with its reason) and
    /// stopping keep the wording the progress strip has always used; running is the reading summary.
    public static func statusLine(_ p: JobProgress, pauseReason: String? = nil, locale: Locale = .current) -> String {
        switch p.state {
        case .listing: return "Looking for new mail…"
        case .paused:
            return ReviewPresentation.pausedText(p, reason: pauseReason ?? p.pauseReason?.displayText, locale: locale)
        case .pausing: return "Pausing after this email · " + ReviewPresentation.counts(p, locale: locale)
        case .stopping: return "Stopping…"
        default: return p.total == 0 ? "Looking for new mail…" : ReviewPresentation.readingSummary(p, locale: locale)
        }
    }

    // MARK: Last Daily digest row

    /// "3 suggestions from this morning" with "8 emails · finished 7:28 am". The count is pending plus failed,
    /// the same number the menu bar badge counts. With none left: "No suggestions from this morning".
    public static func suggestionsRow(_ digest: DigestSummary, now: Date, calendar: Calendar,
                                      locale: Locale) -> MenuSuggestionsRow {
        let count = digest.pendingCount + digest.failedCount
        let when = timePhrase(digest.createdAt, now: now, calendar: calendar, locale: locale)
        let head = count == 0 ? "No suggestions" : "\(count) \(count == 1 ? "suggestion" : "suggestions")"
        let emails = "\(digest.emailCount) \(digest.emailCount == 1 ? "email" : "emails")"
        let time = clockTime(digest.createdAt, calendar: calendar, locale: locale)
        return MenuSuggestionsRow(title: "\(head) from \(when)", subtitle: "\(emails) · finished \(time)")
    }

    /// "this morning" before noon today, "today" later, "yesterday", otherwise "7 Nov".
    static func timePhrase(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return calendar.component(.hour, from: date) < 12 ? "this morning" : "today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return dayMonth(date, calendar: calendar, locale: locale)
    }

    // MARK: Attention state

    /// "Started 6:30 am · stopped before reading any emails", or "… stopped after 12 of 23 emails". Without a
    /// start time the first part is dropped and the sentence starts with a capital.
    public static func attentionSubtitle(startedAt: Date?, done: Int, total: Int, calendar: Calendar,
                                         locale: Locale) -> String {
        let stopped = done > 0 ? "stopped after \(done) of \(total) emails" : "stopped before reading any emails"
        guard let startedAt else { return stopped.prefix(1).uppercased() + stopped.dropFirst() }
        return "Started \(clockTime(startedAt, calendar: calendar, locale: locale)) · \(stopped)"
    }

    /// The card for a failure. `message` is the error text shown for `.other` (a job's `lastError` or a
    /// banner); `jobTitle` is nil for a banner that belongs to no job.
    public static func attentionCard(kind: JobFailureKind?, jobTitle: String?, message: String,
                                     model: String) -> MenuAttentionCard {
        switch kind {
        case .ollamaUnreachable:
            return MenuAttentionCard(
                title: "Ollama Isn\u{2019}t Running",
                message: "Mail Digest reads your mail with a local model. Start Ollama, then try again.",
                offersStartOllama: true)
        case .modelMissing:
            return MenuAttentionCard(title: "Model Isn\u{2019}t Installed",
                                     message: "Run `ollama pull \(model)` in Terminal, then try again.",
                                     offersStartOllama: false)
        case .other, .none:
            return MenuAttentionCard(title: jobTitle.map { "\($0) Couldn\u{2019}t Finish" } ?? "Needs Attention",
                                     message: message, offersStartOllama: false)
        }
    }

    // MARK: Formatting

    private static func dayMonth(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
    }

    /// "7:28 am": short time with a lowercase meridiem and a plain space, as the design shows.
    private static func clockTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }
}
