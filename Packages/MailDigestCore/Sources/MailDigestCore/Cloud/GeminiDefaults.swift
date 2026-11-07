import Foundation

/// Central Gemini constants.
public enum GeminiDefaults {
    public static let model = "gemini-3.5-flash-lite"
    public static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    /// Seconds allowed for one extraction request.
    public static let requestTimeout: TimeInterval = 60
    public static let maxOutputTokens = 2048
    /// Header that carries the key; the key is never put in a URL.
    static let apiKeyHeader = "x-goog-api-key"
}
