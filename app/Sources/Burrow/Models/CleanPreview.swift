import Foundation

/// Parsed result of `mo clean --dry-run`: the terminal summary for labels and
/// `~/.config/mole/clean-list.txt` for the exact candidate paths.
struct CleanPreview {
    struct Item: Identifiable, Hashable {
        let id = UUID()
        let label: String
        let detail: String
        let size: Int64?
        let reviewOnly: Bool
        var children: [String] = []
    }

    struct PathEntry: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let size: Int64
    }

    /// One visible row: a folder that Mole cleans as one or more paths.
    struct Group: Identifiable, Hashable {
        var id: String { root }
        let root: String
        let name: String
        var paths: [PathEntry]
        var reviewReason: String?
        var size: Int64 { paths.reduce(0) { $0 + $1.size } }
    }

    struct Category: Identifiable {
        var id: String { name }
        let name: String
        var items: [Item]
        var paths: [PathEntry]
        var groups: [Group] = []
        var totalSize: Int64 { paths.reduce(0) { $0 + $1.size } }
    }

    var categories: [Category] = []
    var manageSeparately: [Item] = []
    var potentialSpace: String?
    var itemCount: Int?
    var systemNeedsSudo = false
    var freeSpace: String?

    static let trashName = "Trash"

    static func subtitle(for name: String) -> String {
        switch name {
        case "User essentials": return "App caches and old logs; sign-ins and browsing history are kept"
        case "App caches": return "Apple and app caches, temp files and previews"
        case "Browsers": return "Browser service worker and updater caches"
        case "Cloud & Office": return "Cloud drive and Office caches"
        case "Developer tools": return "Package manager, Xcode and build caches. The next build may take longer."
        case "Apps & utilities": return "Shell and utility caches"
        case "Virtualization": return "Virtual machine caches"
        case "Application Support": return "Logs and caches inside Application Support"
        case "App leftovers": return "Data left behind by apps that are no longer on this Mac"
        case "Device backups & firmware": return "Old firmware downloads and device backups"
        case "Time Machine": return "Local Time Machine leftovers"
        case "Project artifacts": return "Build output inside your projects"
        case trashName: return "Empties your Trash permanently."
        case CleanGrouping.appCaches: return "App, browser and cloud caches, plus old logs; sign-ins and browsing history are kept"
        case CleanGrouping.developer: return "Package manager, Xcode and build caches. The next build may take longer."
        case CleanGrouping.aiTools: return "AI app caches and old tool versions. Conversations, projects and local models are kept."
        case CleanGrouping.leftovers: return "Data left behind by apps that are no longer on this Mac"
        case CleanGrouping.systemData: return "System caches, diagnostic logs and local snapshots"
        default: return "Caches and logs found by Mole"
        }
    }

    static func parse(stdout: String, cleanList: String) -> CleanPreview {
        var preview = CleanPreview()
        var categoriesByName: [String: Category] = [:]
        var order: [String] = []

        func ensure(_ name: String) {
            if categoriesByName[name] == nil {
                categoriesByName[name] = Category(name: name, items: [], paths: [])
                order.append(name)
            }
        }

        // --- Terminal summary ---
        var section: String?
        let lines = ANSI.strip(stdout).components(separatedBy: "\n")
        for raw in lines {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("➤ ") {
                section = String(trimmed.dropFirst(2))
                continue
            }
            if trimmed.contains("System caches need sudo") { preview.systemNeedsSudo = true }
            if trimmed.hasPrefix("Potential space:") {
                let rest = trimmed.replacingOccurrences(of: "Potential space:", with: "")
                let parts = rest.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
                preview.potentialSpace = parts.first
                if parts.count > 1 {
                    preview.itemCount = Int(parts[1].components(separatedBy: " ").first ?? "")
                }
                continue
            }
            if let range = trimmed.range(of: "Free space: ") {
                preview.freeSpace = String(trimmed[range.upperBound...])
            }
            guard let current = section else { continue }
            if trimmed.hasPrefix("==========") { section = nil; continue }

            let indent = line.prefix(while: { $0 == " " }).count
            let markers: [Character] = ["○", "◎", "⊙", "•", "✓"]
            if indent == 2, let first = trimmed.first, markers.contains(first) {
                let body = trimmed.dropFirst(1).trimmingCharacters(in: .whitespaces)
                if body == "Nothing to clean" { continue }
                let (label, detail) = splitLabel(body)
                let item = Item(label: label, detail: detail,
                                size: Format.parseSize(detail),
                                reviewOnly: first == "⊙")
                if item.reviewOnly {
                    preview.manageSeparately.append(item)
                } else if current == "User essentials" && label == "Trash" {
                    ensure(trashName)
                    categoriesByName[trashName]?.items.append(item)
                } else {
                    let target = CleanGrouping.displayCategory(forSection: current)
                    ensure(target)
                    categoriesByName[target]?.items.append(item)
                }
            } else if indent >= 4, !trimmed.isEmpty {
                // Nested detail lines (e.g. Homebrew cleanup breakdown).
                let target = CleanGrouping.displayCategory(forSection: current)
                if var cat = categoriesByName[target], !cat.items.isEmpty {
                    cat.items[cat.items.count - 1].children.append(trimmed)
                    categoriesByName[target] = cat
                }
            }
        }

        // --- Exact candidate paths ---
        let trashPrefix = NSHomeDirectory() + "/.Trash/"
        var listSection: String?
        var entries: [(String, PathEntry)] = []
        var seen: Set<String> = []
        for raw in cleanList.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                listSection = String(line.dropFirst(4).dropLast(4))
                continue
            }
            guard let current = listSection, line.hasPrefix("/") || line.hasPrefix("~") else { continue }
            var path = line
            var size: Int64 = 0
            if let hash = line.range(of: "  # ", options: .backwards) {
                path = String(line[..<hash.lowerBound])
                size = Format.parseSize(String(line[hash.upperBound...])) ?? 0
            }
            path = (path as NSString).expandingTildeInPath
            guard seen.insert(path).inserted else { continue }
            var target = path.hasPrefix(trashPrefix) ? trashName : CleanGrouping.displayCategory(forSection: current)
            if target == CleanGrouping.appCaches || target == CleanGrouping.developer, CleanGrouping.isAITool(path) {
                target = CleanGrouping.aiTools
            }
            entries.append((target, PathEntry(path: path, size: size)))
        }

        // A path whose parent folder is also listed is already counted there.
        let all = Set(entries.map(\.1.path))
        for (target, entry) in entries {
            var parent = (entry.path as NSString).deletingLastPathComponent
            var nested = false
            while parent.count > 1 {
                if all.contains(parent) { nested = true; break }
                parent = (parent as NSString).deletingLastPathComponent
            }
            if nested { continue }
            ensure(target)
            categoriesByName[target]?.paths.append(entry)
        }

        var result: [Category] = []
        for name in CleanGrouping.categoryOrder + order where !result.contains(where: { $0.name == name }) {
            guard var cat = categoriesByName[name] else { continue }
            if cat.items.isEmpty && cat.paths.isEmpty { continue }
            cat.paths.sort { $0.size > $1.size }
            cat.groups = makeGroups(cat.paths, category: name)
            result.append(cat)
        }
        preview.categories = result
        return preview
    }

    static func makeGroups(_ paths: [PathEntry], category: String) -> [Group] {
        var byRoot: [String: [PathEntry]] = [:]
        for entry in paths { byRoot[CleanGrouping.root(for: entry.path), default: []].append(entry) }
        var groups: [Group] = []
        for (root, entries) in byRoot {
            // A single path is shown as itself so the row and its exclusion stay exact.
            let shownRoot = entries.count == 1 ? entries[0].path : root
            let nameRoot = entries.count == 1 && root != entries[0].path ? root : shownRoot
            groups.append(Group(root: shownRoot,
                                name: CleanGrouping.name(forRoot: nameRoot),
                                paths: entries.sorted { $0.size > $1.size },
                                reviewReason: CleanGrouping.reviewReason(root: shownRoot, category: category)))
        }
        return groups.sorted { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
    }

    /// "User app cache · 35 items, 5.65GB dry" -> ("User app cache", "35 items, 5.65GB")
    /// "Chrome Service Worker, would clean 262.2MB, 0 protected" -> label + detail
    private static func splitLabel(_ body: String) -> (String, String) {
        var label = body
        var detail = ""
        if let dot = body.range(of: " · ") {
            label = String(body[..<dot.lowerBound])
            detail = String(body[dot.upperBound...])
        } else if let comma = body.range(of: ", ") {
            label = String(body[..<comma.lowerBound])
            detail = String(body[comma.upperBound...])
        }
        detail = detail.replacingOccurrences(of: " dry", with: "")
        return (label, detail)
    }
}
