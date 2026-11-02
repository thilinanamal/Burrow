import Foundation

/// Extra leftovers Burrow finds on top of Mole's own uninstall plan.
///
/// Mole matches leftovers by exact bundle ID only. Many apps also write under
/// their product name ("Docker Desktop"), an Electron helper ID
/// (com.electron.dockerdesktop) or link command-line tools into /usr/local/bin.
/// Every match here comes from evidence inside the app bundle itself: its
/// bundle IDs, the names of the bundles it ships, or a symlink that resolves
/// into it. Nothing is matched by vendor prefix or partial name.
/// Selected extras go to the Trash after Mole has removed the app.
struct ExtraLeftover: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let kind: String
    /// Safe to remove with the app (caches, logs, saved state). Others hold
    /// settings or data and start unchecked.
    let ready: Bool
    var size: Int64?
    var isLink = false
}

enum LeftoverScanner {
    struct Evidence {
        var bundleIDs: Set<String> = []
        var names: Set<String> = []
        var appPath: String
    }

    static func evidence(for app: InstalledApp) -> Evidence {
        var ev = Evidence(appPath: app.path)
        if let id = app.bundleId { ev.bundleIDs.insert(id) }
        ev.names.insert(app.name)
        collect(bundleAt: URL(fileURLWithPath: app.path), into: &ev, depth: 0)
        // Electron helpers are "<base>.helper", "<base>.helper.GPU" ...: the
        // base ID is what the app writes preferences under.
        for id in ev.bundleIDs {
            if let r = id.range(of: ".helper", options: [.caseInsensitive]) {
                ev.bundleIDs.insert(String(id[..<r.lowerBound]))
            }
        }
        ev.bundleIDs = ev.bundleIDs.filter { !$0.lowercased().hasPrefix("com.apple.") && $0.split(separator: ".").count >= 3 }
        ev.names = ev.names.filter { $0.count >= 3 && !genericNames.contains($0.lowercased()) }
        return ev
    }

    private static let genericNames: Set<String> = ["helper", "app", "updater", "update", "crashpad", "launcher",
                                                    "service", "agent", "login", "loginhelper", "uninstaller"]

    /// Reads one bundle's identifiers, then walks the folders where apps
    /// ship nested helper bundles.
    private static func collect(bundleAt url: URL, into ev: inout Evidence, depth: Int) {
        if let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) {
            if let id = info["CFBundleIdentifier"] as? String { ev.bundleIDs.insert(id) }
            if depth == 0 || !(info["CFBundleIdentifier"] as? String ?? "").contains(".helper") {
                for key in ["CFBundleName", "CFBundleDisplayName"] {
                    if let name = info[key] as? String { ev.names.insert(name) }
                }
            }
        }
        guard depth < 3 else { return }
        let fm = FileManager.default
        for sub in ["Contents/MacOS", "Contents/Frameworks", "Contents/Library", "Contents/Library/LoginItems",
                    "Contents/Helpers", "Contents/PlugIns"] {
            let dir = url.appendingPathComponent(sub)
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for item in items {
                let child = dir.appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    // Electron helpers carry the bundle IDs, not names worth matching.
                    if let info = NSDictionary(contentsOf: child.appendingPathComponent("Contents/Info.plist")),
                       let id = info["CFBundleIdentifier"] as? String {
                        ev.bundleIDs.insert(id)
                        if !item.contains(" Helper") {
                            collect(bundleAt: child, into: &ev, depth: depth + 1)
                        }
                    }
                } else if sub == "Contents/Library", depth == 0 {
                    // Contents/Library/<Folder>/<Helper>.app
                    if let inner = try? fm.contentsOfDirectory(atPath: child.path) {
                        for name in inner where name.hasSuffix(".app") {
                            let innerURL = child.appendingPathComponent(name)
                            if let info = NSDictionary(contentsOf: innerURL.appendingPathComponent("Contents/Info.plist")),
                               let id = info["CFBundleIdentifier"] as? String { ev.bundleIDs.insert(id) }
                        }
                    }
                }
            }
        }
    }

    /// Scans the user's Library (and the standard command-line tool folders)
    /// for items owned by `app`. `known` are paths Mole already plans to
    /// handle; `otherApps` are the evidence of every other installed app, so a
    /// name two apps share is never claimed by one of them.
    static func scan(app: InstalledApp, known: [String], otherNames: Set<String>, otherIDs: Set<String>) -> [ExtraLeftover] {
        let ev = evidence(for: app)
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let lib = home + "/Library"
        let ids = ev.bundleIDs.subtracting(otherIDs)
        let names = Set(ev.names.filter { !otherNames.contains($0.lowercased()) })
        var found: [String: ExtraLeftover] = [:]

        func add(_ path: String, _ kind: String, ready: Bool, link: Bool = false) {
            guard found[path] == nil else { return }
            var isDir: ObjCBool = false
            guard link || fm.fileExists(atPath: path, isDirectory: &isDir) else { return }
            found[path] = ExtraLeftover(path: path, kind: kind, ready: ready, size: nil, isLink: link)
        }

        // Folders named exactly after a bundle ID or a bundle name.
        let keys = Array(ids) + Array(names)
        for key in keys {
            add("\(lib)/Application Support/\(key)", "App Support", ready: false)
            add("\(lib)/Caches/\(key)", "Cache", ready: true)
            add("\(lib)/Logs/\(key)", "Logs", ready: true)
            add("\(lib)/HTTPStorages/\(key)", "Web Storage", ready: true)
            add("\(lib)/HTTPStorages/\(key).binarycookies", "Cookies", ready: false)
            add("\(lib)/WebKit/\(key)", "Web Storage", ready: true)
        }
        for id in ids {
            add("\(lib)/Saved Application State/\(id).savedState", "Saved State", ready: true)
            add("\(lib)/Containers/\(id)", "Container", ready: false)
            add("\(lib)/Application Scripts/\(id)", "App Scripts", ready: false)
            add("\(lib)/Cookies/\(id).binarycookies", "Cookies", ready: false)
            add("/Library/Application Support/\(id)", "App Support", ready: false)
            add("/Library/Caches/\(id)", "Cache", ready: false)
        }
        for name in names {
            add("/Library/Application Support/\(name)", "App Support", ready: false)
        }

        // Files that begin with a bundle ID: preferences, launch agents, recents.
        let idPrefixedDirs: [(String, String, Bool)] = [
            ("\(lib)/Preferences", "Preferences", false),
            ("\(lib)/Preferences/ByHost", "Preferences", false),
            ("\(lib)/LaunchAgents", "Launch Agent", false),
            ("\(lib)/Group Containers", "Group Container", false),
            ("\(lib)/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
             "Shared File List", true),
            ("/Library/LaunchAgents", "Launch Agent", false),
            ("/Library/LaunchDaemons", "Launch Daemon", false),
            ("/Library/PrivilegedHelperTools", "Helper Tool", false),
        ]
        for (dir, kind, ready) in idPrefixedDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                let lower = item.lowercased()
                let match = ids.contains { id in
                    let l = id.lowercased()
                    if kind == "Group Container" { return lower == l || lower.hasSuffix("." + l) }
                    guard lower.hasPrefix(l + ".") else { return false }
                    // Only the file-type suffixes that ID owns, so com.google.Chrome
                    // never claims com.google.Chrome.for.testing.plist.
                    let rest = String(lower.dropFirst(l.count))
                    return rest.range(of: #"^(\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?\.(plist|sfl[0-9]?)$"#,
                                      options: .regularExpression) != nil
                }
                if match { add(dir + "/" + item, kind, ready: ready) }
            }
        }

        // Chromium/Electron caches inside the app's own support folder.
        let electronCaches = ["Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "Cache",
                              "blob_storage", "Crashpad", "ShaderCache", "GrShaderCache", "logs"]
        for key in keys {
            let base = "\(lib)/Application Support/\(key)"
            guard fm.fileExists(atPath: base) else { continue }
            for name in electronCaches { add(base + "/" + name, name == "logs" ? "Logs" : "Electron Cache", ready: true) }
        }

        // Command-line tools linked into the app bundle.
        for dir in ["/usr/local/bin", "/opt/homebrew/bin", home + "/.local/bin", home + "/bin"] {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                let path = dir + "/" + item
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: path) else { continue }
                let resolved = dest.hasPrefix("/") ? dest : (dir as NSString).appendingPathComponent(dest)
                if (resolved as NSString).standardizingPath.hasPrefix(ev.appPath + "/") {
                    add(path, "Helper Tool", ready: false, link: true)
                }
            }
        }

        // ~/.<appname> dot folder (e.g. ~/.docker).
        for name in names where !name.contains(" ") {
            add(home + "/." + name.lowercased(), "User Data", ready: false)
        }

        // Drop what Mole already handles and anything inside it.
        let knownExpanded = known.map { ($0 as NSString).expandingTildeInPath }
        let result = found.values.filter { extra in
            !knownExpanded.contains { extra.path == $0 || extra.path.hasPrefix($0 + "/") }
                && extra.path != ev.appPath
        }
        return result.map { item in
            var item = item
            if !item.isLink { item.size = AppInspector.directorySize(URL(fileURLWithPath: item.path)) }
            return item
        }
        .sorted { ($0.ready ? 0 : 1, -($0.size ?? 0)) < ($1.ready ? 0 : 1, -($1.size ?? 0)) }
    }
}
