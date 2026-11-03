import Foundation
import MailDigestCore

/// Loads the JSON fixtures from the test bundle.
enum FixtureLoader {
    /// 2026-11-04 06:30 Australia/Brisbane.
    static let today = Date(timeIntervalSince1970: 1_793_737_800)
    static let timeZone = TimeZone(identifier: "Australia/Brisbane")!

    private struct RawEmail: Decodable {
        var id: String, account: String, mailbox: String, sender: String, subject: String
        var receivedAt: Date, body: String, rawHeaders: String
    }

    private static func files(_ dir: String) throws -> [URL] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(dir)")
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // Replaced by MailJSONDecoder in T04
    static func loadEmails() throws -> [EmailMessage] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try files("emails").map { file in
            let raw = try decoder.decode(RawEmail.self, from: Data(contentsOf: file))
            return EmailMessage(
                id: raw.id.trimmingCharacters(in: CharacterSet(charactersIn: "<>")),
                account: raw.account, mailbox: raw.mailbox, sender: raw.sender, subject: raw.subject,
                receivedAt: raw.receivedAt, body: raw.body, headers: parseHeaders(raw.rawHeaders))
        }
    }

    /// Keeps only the three headers the filter needs; unfolds continuation lines.
    private static func parseHeaders(_ raw: String) -> [String: String] {
        var unfolded: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == " " || line.first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(String(line))
            }
        }
        let keep = ["List-Unsubscribe", "Precedence", "Auto-Submitted"]
        var out: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            if let canonical = keep.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                out[canonical] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    /// Canned model answers keyed by email id (without angle brackets).
    static func loadResults() throws -> [String: ExtractionResult] {
        var out: [String: ExtractionResult] = [:]
        for file in try files("llm") {
            let id = file.deletingPathExtension().lastPathComponent
            out[id] = try JSONDecoder().decode(ExtractionResult.self, from: Data(contentsOf: file))
        }
        return out
    }

    /// Canned answers keyed by the matching email's id.
    static func loadResultsByEmailID() throws -> [String: ExtractionResult] {
        let byName = try loadResults()
        var out: [String: ExtractionResult] = [:]
        for file in try files("emails") {
            let name = file.deletingPathExtension().lastPathComponent
            let decoder = JSONDecoder()
            struct IDOnly: Decodable { var id: String }
            let id = try decoder.decode(IDOnly.self, from: Data(contentsOf: file)).id
            out[id.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))] = byName[name]
        }
        return out
    }
}
