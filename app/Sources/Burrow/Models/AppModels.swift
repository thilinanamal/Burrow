import AppKit
import Foundation

/// One row of `mo uninstall --list`.
struct InstalledApp: Decodable, Identifiable, Hashable {
    var name: String
    var bundleId: String?
    var source: String?
    var uninstallName: String
    var path: String
    var size: String?

    var id: String { path }
}

/// Values the GUI adds on top of the CLI list.
struct AppDetails {
    var sizeBytes: Int64?
    var dataBytes: Int64?
    var version: String?
    var lastUsed: Date?
    var isRunning = false
    var isMenuBarApp = false
}

/// Parsed `mo uninstall --dry-run <name>` plan.
struct UninstallPlan {
    struct Row: Identifiable, Hashable {
        let id = UUID()
        let path: String
        let size: String?
        var kind: String
    }

    var toRemove: [Row] = []
    var personalData: [Row] = []
    var runningWarning = false
    var raw = ""

    static func parse(_ text: String) -> UninstallPlan {
        var plan = UninstallPlan()
        plan.raw = text
        enum Section { case none, remove, personal }
        var section = Section.none
        for raw in ANSI.strip(text).components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Files to be removed") { section = .remove; continue }
            if line.hasPrefix("Personal data kept") || line.hasPrefix("Personal data") { section = .personal; continue }
            if line.contains("[Running]") || line.localizedCaseInsensitiveContains("is running") { plan.runningWarning = true }
            if line.isEmpty || line.hasPrefix("D choose") || line.hasPrefix("Dry run") { continue }
            guard let first = line.first, ["✓", "⊙", "○", "◎", "•"].contains(first) else { continue }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("/") || body.hasPrefix("~") else { continue }
            var path = body
            var size: String?
            if let comma = body.range(of: " , ", options: .backwards) {
                path = String(body[..<comma.lowerBound])
                size = String(body[comma.upperBound...])
            }
            let row = Row(path: path, size: size, kind: kind(for: path))
            switch section {
            case .remove: plan.toRemove.append(row)
            case .personal: plan.personalData.append(row)
            case .none: break
            }
        }
        return plan
    }

    static func kind(for path: String) -> String {
        let p = path.lowercased()
        if p.hasSuffix(".app") { return "Application" }
        if p.contains("/caches/") || p.hasSuffix("cache") || p.contains("cache") { return "Cache" }
        if p.contains("/preferences/") || p.hasSuffix(".plist") { return "Preferences" }
        if p.contains("/logs/") { return "Logs" }
        if p.contains("/application support/") { return "App Support" }
        if p.contains("/containers/") || p.contains("/group containers/") { return "Container" }
        if p.contains("launchagents") || p.contains("launchdaemons") { return "Launch Item" }
        if p.contains("/saved application state/") { return "Saved State" }
        if p.contains("/var/folders/") { return "Temp Files" }
        return "User Data"
    }
}

enum AppInspector {
    static func details(for app: InstalledApp) -> AppDetails {
        var d = AppDetails()
        let url = URL(fileURLWithPath: app.path)
        if let bundle = Bundle(url: url) {
            d.version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            d.isMenuBarApp = (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true
                || (bundle.object(forInfoDictionaryKey: "LSUIElement") as? String) == "1"
        }
        if let item = NSMetadataItem(url: url) {
            d.lastUsed = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            if let logical = item.value(forAttribute: "kMDItemLogicalSize") as? NSNumber {
                d.sizeBytes = logical.int64Value
            }
        }
        if d.sizeBytes == nil || d.sizeBytes == 0 {
            d.sizeBytes = directorySize(url)
        }
        if let id = app.bundleId {
            d.isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
            d.dataBytes = dataSize(bundleId: id, name: app.name)
        }
        return d
    }

    static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
            return Int64(v.totalFileAllocatedSize ?? 0)
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            if let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Rough size of the app's data folders, for the row subtitle only.
    static func dataSize(bundleId: String, name: String) -> Int64 {
        let lib = NSHomeDirectory() + "/Library"
        let candidates = [
            "\(lib)/Application Support/\(name)",
            "\(lib)/Application Support/\(bundleId)",
            "\(lib)/Containers/\(bundleId)",
            "\(lib)/Caches/\(bundleId)",
            "\(lib)/Caches/\(name)",
        ]
        var total: Int64 = 0
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            total += directorySize(URL(fileURLWithPath: path))
        }
        return total
    }
}
