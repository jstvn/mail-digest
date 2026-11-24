import Foundation

/// Deterministic sanity check for a model-written headline (Q102), applied for every provider.
public enum HeadlineValidator {
    public static let maxLength = 280

    /// The trimmed headline, or nil when it is empty, spans several lines or is longer than
    /// `maxLength`: those shapes mean the model wrote reasoning or a list instead of a headline.
    public static func validated(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength,
              !trimmed.contains(where: \.isNewline) else { return nil }
        return trimmed
    }
}
