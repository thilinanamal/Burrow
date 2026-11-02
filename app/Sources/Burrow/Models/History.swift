import Foundation

/// `mo history --json --limit N`.
struct HistoryReport: Decodable {
    struct Session: Decodable, Identifiable {
        struct Actions: Decodable {
            var removed: Int?
            var trashed: Int?
            var skipped: Int?
            var failed: Int?
            var rebuilt: Int?
            var other: Int?
        }

        var command: String?
        var runId: String?
        var startedAt: String?
        var endedAt: String?
        var items: Int?
        var size: String?
        var operationCount: Int?
        var failedTasks: Int?
        var actions: Actions?
        var id: String { runId ?? UUID().uuidString }
    }

    var sessions: [Session]?

    static func latest(command: String) async -> Session? {
        guard let result = try? await MoleCLI.run(["history", "--json", "--limit", "5"]),
              let start = result.output.firstIndex(of: "{") else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let report = try? decoder.decode(HistoryReport.self, from: Data(result.output[start...].utf8))
        else { return nil }
        return report.sessions?.first(where: { $0.command == command })
    }
}
