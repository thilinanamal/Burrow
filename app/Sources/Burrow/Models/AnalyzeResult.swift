import Foundation

/// `mo analyze --json [path]`.
struct AnalyzeResult: Decodable {
    struct Entry: Decodable, Identifiable, Hashable {
        var scanStatus: String?
        var name: String
        var path: String
        var size: Int64
        var isDir: Bool?
        var insight: Bool?
        var cleanable: Bool?
        var id: String { path }
        var isPartial: Bool { scanStatus == "partial" }
        var isUnavailable: Bool { scanStatus == "unavailable" }
    }

    struct LargeFile: Decodable, Identifiable, Hashable {
        var name: String
        var path: String
        var size: Int64
        var id: String { path }
    }

    var scanStatus: String?
    var path: String?
    var overview: Bool?
    var totalSize: Int64?
    var totalFiles: Int?
    var entries: [Entry]?
    var largeFiles: [LargeFile]?

    static func decode(_ text: String) -> AnalyzeResult? {
        // Tolerate any log noise before the JSON object.
        guard let start = text.firstIndex(of: "{") else { return nil }
        let data = Data(text[start...].utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(AnalyzeResult.self, from: data)
    }

    var sortedEntries: [Entry] { (entries ?? []).sorted { $0.size > $1.size } }
    var computedTotal: Int64 { totalSize ?? (entries ?? []).reduce(0) { $0 + max(0, $1.size) } }
}
