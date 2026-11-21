import Foundation

/// Decides whether a `.partial.emlx` file was actually inspected in full (Q66). Mail writes that name
/// for messages whose parts may still be on the server; but when every part is present in the file and
/// nothing is stored separately, the file is as complete as a normal `.emlx`.
public enum PartialEmlxPolicy {
    /// `.complete` only when the normal rules passed, no leaf is a placeholder, and Mail has no
    /// `Attachments/<rowid>` directory for the message. Otherwise `.uninspectedParts` with `.partialMessage`.
    public static func verdict(for parsed: ParsedEmlx, hasAttachmentsDirectory: Bool)
        -> (inspection: ContentInspection, gap: InspectionGap?) {
        if parsed.inspection == .complete, !parsed.hasPlaceholderPart, !hasAttachmentsDirectory {
            return (.complete, nil)
        }
        return (.uninspectedParts, .partialMessage)
    }
}
