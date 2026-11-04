import Foundation
import MailDigestCore

/// Loads the JSON fixtures from the test bundle.
enum FixtureLoader {
    /// 2026-11-04 06:30 Australia/Brisbane.
    static let today = Date(timeIntervalSince1970: 1_793_737_800)
    static let timeZone = TimeZone(identifier: "Australia/Brisbane")!

    private static func files(_ dir: String) throws -> [URL] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(dir)")
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadEmails() throws -> [EmailMessage] {
        let decoder = MailJSONDecoder()
        return try files("emails").map { try decoder.decodeMessage(Data(contentsOf: $0)) }
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
