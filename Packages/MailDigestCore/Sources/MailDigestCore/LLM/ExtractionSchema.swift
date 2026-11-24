import Foundation

/// The JSON schema sent to Ollama as `format` (see SPEC, "Extraction schema").
/// `tasks` allows the Trusted Newsletter maximum; validation applies the stricter per-sender limit.
public enum ExtractionSchema {
    private static func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }

    public static let json: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "summary": .object(["type": .string("string")]),
            "category": .object(["enum": strings(Category.allCases.map(\.rawValue))]),
            "importance": .object([
                "type": .string("integer"), "minimum": .number(1), "maximum": .number(5),
            ]),
            "key_facts": .object([
                "type": .string("array"), "maxItems": .number(4),
                "items": .object(["type": .string("string")]),
            ]),
            "tasks": .object([
                "type": .string("array"), "maxItems": .number(Double(MailFilter.trustedNewsletterSuggestionLimit)),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string")]),
                        "due": .object(["type": strings(["string", "null"])]),
                        "due_has_time": .object(["type": .string("boolean")]),
                        "priority": .object(["enum": strings(["high", "medium", "low"])]),
                        "evidence": .object(["type": .string("string")]),
                        "confidence": .object(["type": .string("number")]),
                        "steps": .object([
                            "type": .string("array"), "maxItems": .number(4),
                            "items": .object(["type": .string("string")]),
                        ]),
                    ]),
                    "required": strings(["title", "due", "due_has_time", "priority", "evidence", "confidence", "steps"]),
                ]),
            ]),
        ]),
        "required": strings(["summary", "category", "importance", "key_facts", "tasks"]),
    ])
}

/// The JSON schema for the headline call (Q102). Constrained decoding keeps qwen3 from writing
/// its reasoning into the answer, which free-text replies did.
public enum HeadlineSchema {
    public static let json: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["headline": .object(["type": .string("string")])]),
        "required": .array([.string("headline")]),
    ])
}
