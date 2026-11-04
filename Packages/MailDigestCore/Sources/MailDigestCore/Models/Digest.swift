import Foundation

public enum Category: String, Codable, Sendable, Equatable, CaseIterable {
    case uni, work, finance, deliveries, events, newsletters, personal, other
}

public struct InfoItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String              // = email id
    public var emailID: String
    public var category: Category
    public var importance: Int         // 1...5
    public var summary: String         // one sentence, under 25 words
    public var keyFacts: [String]      // 0...4 short facts
    public var pinned: Bool

    public init(id: String, emailID: String, category: Category, importance: Int,
                summary: String, keyFacts: [String], pinned: Bool) {
        self.id = id
        self.emailID = emailID
        self.category = category
        self.importance = importance
        self.summary = summary
        self.keyFacts = keyFacts
        self.pinned = pinned
    }
}

public enum Priority: String, Codable, Sendable, Equatable { case high, medium, low }

public enum SuggestionStatus: String, Codable, Sendable, Equatable { case pending, approved, dismissed, failed }

public struct Suggestion: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var emailID: String
    public var title: String           // editable in the panel
    public var due: Date?
    public var dueHasTime: Bool
    public var priority: Priority
    public var evidence: String        // quote from the email
    public var confidence: Double      // 0...1
    public var preselected: Bool       // confidence >= 0.75 and no red flags
    public var flags: [String]         // e.g. "money-new-sender"
    public var status: SuggestionStatus
    public var reminderID: String?     // EKReminder.calendarItemIdentifier after approval

    public init(id: UUID, emailID: String, title: String, due: Date?, dueHasTime: Bool,
                priority: Priority, evidence: String, confidence: Double, preselected: Bool,
                flags: [String], status: SuggestionStatus, reminderID: String?) {
        self.id = id
        self.emailID = emailID
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.priority = priority
        self.evidence = evidence
        self.confidence = confidence
        self.preselected = preselected
        self.flags = flags
        self.status = status
        self.reminderID = reminderID
    }
}

/// An email that produced no digest entry, with the reason shown under Skipped.
public struct SkippedEmail: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sender: String
    public var subject: String
    public var reason: String

    public init(id: String, sender: String, subject: String, reason: String) {
        self.id = id
        self.sender = sender
        self.subject = subject
        self.reason = reason
    }
}

public struct Digest: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var headline: String        // 1 to 2 sentences from the digest pass
    public var emailCount: Int
    public var suggestions: [Suggestion]
    public var info: [InfoItem]
    public var skipped: [SkippedEmail] // id, sender, subject, reason

    public init(id: UUID, createdAt: Date, headline: String, emailCount: Int,
                suggestions: [Suggestion], info: [InfoItem], skipped: [SkippedEmail]) {
        self.id = id
        self.createdAt = createdAt
        self.headline = headline
        self.emailCount = emailCount
        self.suggestions = suggestions
        self.info = info
        self.skipped = skipped
    }
}

/// The user's approve or dismiss choice, kept for learned sender rules.
public struct Decision: Codable, Sendable, Equatable {
    public var suggestionID: UUID
    public var sender: String
    public var action: SuggestionStatus // approved or dismissed
    public var decidedAt: Date

    public init(suggestionID: UUID, sender: String, action: SuggestionStatus, decidedAt: Date) {
        self.suggestionID = suggestionID
        self.sender = sender
        self.action = action
        self.decidedAt = decidedAt
    }
}
