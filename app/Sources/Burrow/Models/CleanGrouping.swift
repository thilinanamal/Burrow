import AppKit
import Foundation

/// Turns Mole's flat candidate path list into the rows people actually reason
/// about ("Chrome Profile 14 Service Worker Cache" instead of 300 hash
/// folders), and decides what the Recommended selection leaves alone.
///
/// Display only: Mole still receives exact paths (exclusions become whitelist
/// entries), so grouping never widens what gets deleted.
enum CleanGrouping {
    static let home = NSHomeDirectory()

    // MARK: Display categories

    static let appCaches = "App Caches & Logs"
    static let developer = "Developer Tools"
    static let aiTools = "AI Tools"
    static let leftovers = "Uninstalled App Leftovers"
    static let systemData = "System Data"

    /// Mole CLI section -> display category.
    static func displayCategory(forSection section: String) -> String {
        switch section {
        case "Developer tools", "Project artifacts": return developer
        case "App leftovers": return leftovers
        case "Device backups & firmware", "Time Machine", "Apple Silicon updates", "System": return systemData
        case CleanPreview.trashName: return CleanPreview.trashName
        default:
            if section.lowercased().contains("system") { return systemData }
            return appCaches
        }
    }

    static let categoryOrder = [appCaches, developer, aiTools, leftovers, systemData, CleanPreview.trashName]

    private static let aiMarkers = ["/.gemini/", "/antigravity", "/.claude/", "/claude/", "/.codex/", "/.cursor/",
                                    "/cursor/", "/chatgpt", "/com.openai.", "/lm studio/", "/.lmstudio/", "/ollama",
                                    "/.copilot/", "/claude-", "/github copilot", "/windsurf", "/.windsurf/"]

    static func isAITool(_ path: String) -> Bool {
        let lower = path.lowercased() + "/"
        return aiMarkers.contains { lower.contains($0) }
    }

    // MARK: Group roots

    /// Anchors and how many path components below them make one item.
    private static var anchors: [(String, Int)] {
        let h = home
        return [
            (h + "/Library/Application Support", 2),
            (h + "/Library/Caches", 1),
            (h + "/Library/Logs", 1),
            (h + "/Library/Containers", 1),
            (h + "/Library/Group Containers", 1),
            (h + "/Library/Messages", 1),
            (h + "/Library/Developer", 2),
            (h + "/Library/HTTPStorages", 1),
            (h + "/Library/WebKit", 1),
            (h + "/.Trash", 1),
            ("/Library/Caches", 1),
            ("/Library/Logs", 1),
            ("/private/var/folders", 4),
            ("/var/folders", 4),
        ]
    }

    static func root(for path: String) -> String {
        if let range = path.range(of: "/Service Worker/CacheStorage/") {
            return String(path[..<range.lowerBound]) + "/Service Worker/CacheStorage"
        }
        var best: (String, Int)?
        for (anchor, depth) in anchors where path.hasPrefix(anchor + "/") {
            if best == nil || anchor.count > best!.0.count { best = (anchor, depth) }
        }
        // Dot folders in home: ~/.npm/_cacache, ~/.bun/install/...
        if best == nil, path.hasPrefix(home + "/."), let first = path.dropFirst(home.count + 1).split(separator: "/").first {
            best = (home + "/" + first, 2)
        }
        guard let (anchor, depth) = best else { return artifactRoot(path) ?? path }
        let rest = path.dropFirst(anchor.count + 1).split(separator: "/", omittingEmptySubsequences: true)
        if rest.count <= depth { return path }
        return anchor + "/" + rest.prefix(depth).joined(separator: "/")
    }

    /// Build-output folder names that mark a project artifact.
    static let artifactNames: Set<String> = [".next", ".nuxt", ".build", ".dart_tool", "node_modules", "__pycache__",
                                             ".pytest_cache", ".mypy_cache", ".ruff_cache", ".gradle", "DerivedData",
                                             ".turbo", ".parcel-cache", ".svelte-kit", ".angular", ".expo", "target",
                                             ".tox", ".venv", "venv", "build", "dist", ".cache"]

    /// ~/proj/frontend/.next/cache/webpack -> ~/proj/frontend/.next
    static func artifactRoot(_ path: String) -> String? {
        guard path.hasPrefix(home + "/") else { return nil }
        let comps = path.split(separator: "/").map(String.init)
        guard let index = comps.firstIndex(where: { artifactNames.contains($0) }) else { return nil }
        return "/" + comps[...index].joined(separator: "/")
    }

    // MARK: Names

    private static let genericNames: Set<String> = [
        "cache", "caches", "data", "logs", "log", "default", "install", "resources", "generated", "tmp", "t", "c",
        "cachestorage", "users", "applications", "library", "storage", "code cache", "gpucache", "blob_storage",
        "shared", "content-v2", "sha512", "index-v5", "_cacache", "modulecache", "user data",
    ]

    static func name(forRoot root: String) -> String {
        let comps = root.split(separator: "/").map(String.init)
        if root.hasSuffix("/Service Worker/CacheStorage"), comps.count >= 4 {
            let profile = comps[comps.count - 3]
            let browser = browserName(from: root)
            return "\(browser) \(profile) Service Worker Cache"
        }
        if root.hasPrefix(home + "/.Trash/") { return comps.last ?? root }
        // Project build output: "VA/frontend · .next".
        if let artifact = artifactRoot(root), let index = comps.lastIndex(of: (artifact as NSString).lastPathComponent) {
            let owner = comps[max(0, index - 2)..<index].joined(separator: "/")
            let rest = comps[index...].joined(separator: "/")
            return owner.isEmpty ? rest : "\(owner) · \(rest)"
        }
        // Walk up past generic folder names ("Cache", "content-v2", "Default").
        var i = comps.count - 1
        var generic: [String] = []
        while i > 0, genericNames.contains(comps[i].lowercased()) {
            generic.insert(comps[i], at: 0)
            i -= 1
        }
        guard i >= 0 else { return root }
        var base = prettyBundle(comps[i])
        while base.hasPrefix(".") || base.hasPrefix("_") { base.removeFirst() }
        let isCacheLocation = root.hasPrefix(home + "/Library/Caches/") || root.hasPrefix("/Library/Caches/")
            || root.contains("/var/folders/")
        if let last = generic.last {
            let lower = last.lowercased()
            let wantsCache = generic.contains { $0.lowercased().contains("cache") } || isCacheLocation
            if lower == "cache" || lower == "caches" || (wantsCache && !lower.contains("cache")) {
                return "\(base) Cache"
            }
            return "\(base) \(last)"
        }
        if root.hasPrefix(home + "/Library/Logs/") && !base.lowercased().contains("log") { return "\(base) Logs" }
        if isCacheLocation && !base.lowercased().contains("cache") { return "\(base) Cache" }
        return base
    }

    private static func browserName(from path: String) -> String {
        let table: [(String, String)] = [
            ("/Google/Chrome Beta/", "Chrome Beta"), ("/Google/Chrome Canary/", "Chrome Canary"),
            ("/Google/Chrome/", "Chrome"), ("/BraveSoftware/", "Brave"), ("/Microsoft Edge/", "Edge"),
            ("/Arc/", "Arc"), ("/Vivaldi/", "Vivaldi"), ("/com.operasoftware.", "Opera"), ("/Chromium/", "Chromium"),
        ]
        for (marker, name) in table where path.contains(marker) { return name }
        if let r = path.range(of: "/Application Support/") {
            return path[r.upperBound...].split(separator: "/").first.map(String.init) ?? "Browser"
        }
        return "Browser"
    }

    private static var bundleNameCache: [String: String] = [:]

    /// "com.apple.helpd" -> app display name when installed, else "helpd".
    static func prettyBundle(_ component: String) -> String {
        let parts = component.split(separator: ".")
        guard parts.count >= 3, ["com", "org", "net", "io", "dev", "app", "group"].contains(parts[0].lowercased())
            || (parts.count >= 3 && parts[0].count == 10 && parts[0].uppercased() == parts[0]) else { return component }
        if let cached = bundleNameCache[component] { return cached }
        var id = component
        if id.hasPrefix("group.") { id.removeFirst(6) }
        if parts[0].count == 10, parts[0].uppercased() == parts[0] { id = parts.dropFirst().joined(separator: ".") }
        var result = String(id.split(separator: ".").last ?? Substring(id))
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            result = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        bundleNameCache[component] = result
        return result
    }

    // MARK: Review policy

    /// Why an item is not part of the Recommended selection, or nil.
    static func reviewReason(root: String, category: String) -> String? {
        if category == leftovers { return "Belongs to an app that is no longer installed. Check it before removing." }
        let h = home
        let lower = root.lowercased()
        let redownload = [
            h + "/.npm/_npx", h + "/.pub-cache", h + "/go/pkg/mod", h + "/.bun/install",
            h + "/.gradle/caches", h + "/.m2", h + "/.cargo/registry", h + "/.cocoapods", h + "/.pnpm-store",
            h + "/Library/pnpm", h + "/Library/Caches/CocoaPods", h + "/.rustup", h + "/.nuget",
            h + "/Library/Caches/pnpm", h + "/.yarn", h + "/Library/Caches/Yarn",
        ]
        if redownload.contains(where: { root == $0 || root.hasPrefix($0 + "/") || $0.hasPrefix(root + "/") }) {
            if root.contains("/content-v2") { return nil }
            return "Packages must download again on the next install."
        }
        if root.hasPrefix("/opt/homebrew/Cellar/") || root.hasPrefix("/usr/local/Cellar/") {
            return "Old Homebrew version; something may still link to it."
        }
        if lower.contains("spotify") { return "May contain music downloaded for offline listening." }
        if lower.contains("/library/messages/") && !lower.contains("cache") {
            return "May contain message attachments."
        }
        // Build output inside your own folders (not Library, dot folders or temp).
        let systemish = [h + "/Library/", h + "/.", "/private/var/", "/var/", "/Library/", "/opt/", "/usr/"]
        if root.hasPrefix(h + "/"), !systemish.contains(where: { root.hasPrefix($0) }) {
            return "Build output in one of your projects. The next build will take longer."
        }
        return nil
    }

    /// Owner-command cleanups (npm cache clean, ...) check their tool's cache
    /// root against the whitelist, not the subfolder shown. Excluding the row
    /// must therefore also whitelist that root.
    static func extraWhitelist(forExcludedRoot root: String) -> [String] {
        let npm = home + "/.npm"
        if root == npm + "/_cacache" || root.hasPrefix(npm + "/_cacache/") { return [npm] }
        return []
    }

    // MARK: In use

    struct RunningApp: Hashable {
        let name: String
        let bundleID: String
        let pid: pid_t
    }

    /// Regular apps that are running right now, keyed by lowercase match keys.
    static func runningApps() -> [String: RunningApp] {
        var map: [String: RunningApp] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, bid != Bundle.main.bundleIdentifier,
                  !bid.hasPrefix("com.apple.finder") else { continue }
            let name = app.localizedName ?? bid
            let entry = RunningApp(name: name, bundleID: bid, pid: app.processIdentifier)
            map[bid.lowercased()] = entry
            map[name.lowercased()] = entry
            if let file = app.bundleURL?.deletingPathExtension().lastPathComponent { map[file.lowercased()] = entry }
        }
        return map
    }

    /// The running app whose live data folder holds this item. Only app data
    /// folders count (Application Support, containers); plain ~/Library/Caches
    /// entries are safe to clear while the app runs.
    static func holdingApp(root: String, running: [String: RunningApp]) -> RunningApp? {
        let h = home
        let liveBases = [h + "/Library/Application Support/", h + "/Library/Containers/",
                         h + "/Library/Group Containers/"]
        guard let base = liveBases.first(where: { root.hasPrefix($0) }) else { return nil }
        let comps = root.dropFirst(base.count).split(separator: "/").map(String.init)
        guard let first = comps.first else { return nil }
        var keys = [first.lowercased()]
        if comps.count > 1 { keys.append("\(first) \(comps[1])".lowercased()); keys.append(comps[1].lowercased()) }
        var groupID = first
        if groupID.hasPrefix("group.") { groupID.removeFirst(6) }
        keys.append(groupID.lowercased())
        for key in keys {
            if let app = running[key] { return app }
        }
        // "Antigravity IDE" folder vs "Antigravity" app and similar.
        let firstLower = first.lowercased()
        for (key, app) in running where key.count >= 4 && !key.contains(".") {
            if firstLower.hasPrefix(key + " ") { return app }
        }
        return nil
    }
}

/// Whether Burrow (and so the Mole CLI it launches) may read protected
/// folders such as the Trash and Safari/Mail caches.
enum FullDiskAccess {
    static var isGranted: Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
        ]
        for probe in probes where FileManager.default.fileExists(atPath: probe) {
            if let handle = FileHandle(forReadingAtPath: probe) {
                try? handle.close()
                return true
            }
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash")) != nil { return true }
        return false
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
