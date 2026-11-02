import Foundation

enum Format {
    static func bytes(_ value: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
        if value <= 0 { return "Zero KB" }
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: value)
    }

    static func gigabytes(_ value: Double) -> String {
        String(format: value >= 100 ? "%.0f" : "%.1f", value / 1_000_000_000)
    }

    /// Parses Mole's human sizes ("66.4MB", "7.63GB", "0B", "115KB").
    /// Mole uses 1024-based units.
    static func parseSize(_ text: String) -> Int64? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(B|KB|MB|GB|TB|K|M|G|T)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let match = matches.last,
              let value = Double(ns.substring(with: match.range(at: 1))) else { return nil }
        let unit = ns.substring(with: match.range(at: 2))
        let multiplier: Double
        switch unit {
        case "B": multiplier = 1
        case "KB", "K": multiplier = 1024
        case "MB", "M": multiplier = 1024 * 1024
        case "GB", "G": multiplier = 1024 * 1024 * 1024
        case "TB", "T": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f", max(0, value))
    }

    static func relative(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}
