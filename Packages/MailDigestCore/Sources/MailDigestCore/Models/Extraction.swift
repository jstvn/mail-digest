import Foundation

/// A raw task as returned by the model, before validation.
public struct ExtractedTask: Codable, Sendable, Equatable {
    public var title: String
    public var due: String?
    public var dueHasTime: Bool
    public var priority: Priority
    public var evidence: String
    public var confidence: Double

    public init(title: String, due: String?, dueHasTime: Bool, priority: Priority, evidence: String, confidence: Double) {
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.priority = priority
        self.evidence = evidence
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case title, due
        case dueHasTime = "due_has_time"
        case priority, evidence, confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        dueHasTime = try c.decode(Bool.self, forKey: .dueHasTime)
        priority = try c.decode(Priority.self, forKey: .priority)
        evidence = try c.decode(String.self, forKey: .evidence)
        confidence = try c.decode(Double.self, forKey: .confidence)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        // The schema requires the key, so nil is written as an explicit null.
        if let due { try c.encode(due, forKey: .due) } else { try c.encodeNil(forKey: .due) }
        try c.encode(dueHasTime, forKey: .dueHasTime)
        try c.encode(priority, forKey: .priority)
        try c.encode(evidence, forKey: .evidence)
        try c.encode(confidence, forKey: .confidence)
    }
}

/// The model's structured answer for one email; keys match the JSON schema.
public struct ExtractionResult: Codable, Sendable, Equatable {
    public var summary: String
    public var category: Category
    public var importance: Int
    public var keyFacts: [String]
    public var tasks: [ExtractedTask]

    public init(summary: String, category: Category, importance: Int, keyFacts: [String], tasks: [ExtractedTask]) {
        self.summary = summary
        self.category = category
        self.importance = importance
        self.keyFacts = keyFacts
        self.tasks = tasks
    }

    enum CodingKeys: String, CodingKey {
        case summary, category, importance
        case keyFacts = "key_facts"
        case tasks
    }
}

extension ExtractionResult {
    /// The one decoding path for model output, shared by the local and cloud clients.
    /// Returns nil when the text is not valid extraction JSON.
    static func decode(jsonText: String) -> ExtractionResult? {
        try? JSONDecoder().decode(ExtractionResult.self, from: Data(jsonText.utf8))
    }
}
