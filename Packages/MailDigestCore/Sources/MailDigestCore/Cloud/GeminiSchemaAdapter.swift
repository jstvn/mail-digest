import Foundation

/// Converts `ExtractionSchema.json` into a `responseJsonSchema` Gemini accepts.
public enum GeminiSchemaAdapter {
    /// Keywords Gemini strips without enforcing. The decoder and validator still enforce them.
    static let unsupportedKeywords: Set<String> = [
        "minLength", "maxLength", "minProperties", "maxProperties", "uniqueItems",
    ]
    /// Keywords whose value is a map of name -> subschema (names must never be filtered).
    private static let schemaMaps: Set<String> = ["properties", "$defs", "definitions"]
    /// Keywords whose value is a single subschema.
    private static let subschemas: Set<String> = ["items", "additionalProperties"]

    public static func adapt(_ schema: JSONValue = ExtractionSchema.json) -> JSONValue {
        adaptSchema(schema)
    }

    private static func adaptSchema(_ value: JSONValue) -> JSONValue {
        guard case .object(let dict) = value else { return value }
        var out: [String: JSONValue] = [:]
        for (key, v) in dict where !unsupportedKeywords.contains(key) {
            if schemaMaps.contains(key), case .object(let map) = v {
                out[key] = .object(map.mapValues(adaptSchema))
            } else if subschemas.contains(key) {
                out[key] = adaptSchema(v)
            } else {
                out[key] = v
            }
        }
        return nullableFromAnyOf(out)
    }

    /// Rewrites `anyOf: [{type: T}, {type: "null"}]` into `type: [T, "null"]`.
    private static func nullableFromAnyOf(_ dict: [String: JSONValue]) -> JSONValue {
        guard case .array(let options)? = dict["anyOf"], options.count == 2 else { return .object(dict) }
        var types: [JSONValue] = []
        for option in options {
            guard case .object(let o) = option, o.count == 1, let t = o["type"] else { return .object(dict) }
            if case .array(let list) = t { types += list } else { types.append(t) }
        }
        guard types.contains(.string("null")) else { return .object(dict) }
        var out = dict
        out["anyOf"] = nil
        out["type"] = .array(types)
        return .object(out)
    }
}
