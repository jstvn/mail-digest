import Foundation

/// One info item as it is appended to the note: a title line, the summary and its key facts.
public struct NotesEntry: Sendable, Equatable {
    public var title: String
    public var summary: String
    public var keyFacts: [String]

    public init(title: String, summary: String, keyFacts: [String]) {
        self.title = title
        self.summary = summary
        self.keyFacts = keyFacts
    }

    /// Builds the entry for an info item. The title is "4 Nov 2026 · Sender · Subject" (sender and subject only
    /// when the email's context is known).
    public static func make(for item: InfoItem, email: EmailContext?, date: Date,
                            timeZone: TimeZone = .current) -> NotesEntry {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy"
        var parts = [formatter.string(from: date)]
        if let email {
            parts.append(ReviewPresentation.senderName(email.sender))
            parts.append(email.subject)
        }
        return NotesEntry(title: parts.map(Self.oneLine).filter { !$0.isEmpty }.joined(separator: " · "),
                          summary: item.summary, keyFacts: item.keyFacts)
    }

    /// The entry as Notes HTML. Email text is untrusted, so every piece of text is escaped.
    public var html: String {
        var out = "<div><b>\(Self.escape(title))</b></div><div>\(Self.escape(summary))</div>"
        if !keyFacts.isEmpty {
            out += "<ul>" + keyFacts.map { "<li>\(Self.escape($0))</li>" }.joined() + "</ul>"
        }
        return out + "<div><br></div>"
    }

    /// Escapes the five HTML-significant characters and turns line breaks into `<br>`.
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "\n", "\r\n", "\r": out += "<br>"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
