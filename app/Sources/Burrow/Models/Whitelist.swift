import Foundation

/// Reads and writes Mole's clean protection list (`~/.config/mole/whitelist`),
/// the same file `mo clean --whitelist` edits.
///
/// Two uses:
/// - Permanent protection (the shield button): appends a path.
/// - Deselected items for one run: a marked temporary block that is removed as
///   soon as the run ends, and again at launch in case the app was killed.
enum Whitelist {
    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/mole/whitelist")
    private static let beginMarker = "# >>> burrow temporary exclusions (removed automatically) >>>"
    private static let endMarker = "# <<< burrow temporary exclusions <<<"
    private static let createdMarkerURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/mole/.burrow-created-whitelist")

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Mole's optional defaults, read from the bundled `lib/core/base.sh`.
    /// A whitelist file replaces these, so a newly created file must carry
    /// them to keep the same protection as no file at all.
    static func defaultPatterns() -> [String] {
        guard let root = MoleCLI.rootURL,
              let text = try? String(contentsOf: root.appendingPathComponent("lib/core/base.sh"), encoding: .utf8)
        else { return [] }
        guard let start = text.range(of: "declare -a DEFAULT_WHITELIST_PATTERNS=(") else { return [] }
        let after = text[start.upperBound...]
        guard let end = after.range(of: "\n)") else { return [] }
        return after[..<end.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"") }
            .map { line in
                var value = line.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                value = value.replacingOccurrences(of: "$FINDER_METADATA_SENTINEL", with: "FINDER_METADATA")
                return value
            }
    }

    static func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Protected entries the user saved (excluding our temporary block).
    static func userEntries() -> [String] {
        stripTemporary(read())
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func isProtected(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return userEntries().contains { entry in
            let expanded = entry.replacingOccurrences(of: "$HOME", with: home)
                .replacingOccurrences(of: "~", with: home, options: .anchored)
            return path == expanded || path.hasPrefix(expanded + "/")
        }
    }

    private static func ensureFile() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            var body = "# Mole whitelist, created by Burrow with Mole's default protections.\n"
            body += defaultPatterns().joined(separator: "\n") + "\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Permanently protect a path from `mo clean`.
    static func protect(_ path: String) throws {
        guard !path.contains("..") else { return }
        try ensureFile()
        try? FileManager.default.removeItem(at: createdMarkerURL)
        var text = read()
        if userEntries().contains(path) { return }
        if !text.hasSuffix("\n") && !text.isEmpty { text += "\n" }
        text += path + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func unprotect(_ path: String) throws {
        let lines = read().components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces) != path
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds a temporary exclusion block for one run.
    static func applyTemporary(_ paths: [String]) throws {
        let clean = paths.filter { $0.hasPrefix("/") && !$0.contains("..") && !$0.contains("\n") }
        guard !clean.isEmpty else { return }
        if !exists {
            try ensureFile()
            // Remember that the file did not exist so restore can delete it.
            try "1".write(to: createdMarkerURL, atomically: true, encoding: .utf8)
        }
        var text = stripTemporary(read())
        if !text.hasSuffix("\n") && !text.isEmpty { text += "\n" }
        text += beginMarker + "\n" + clean.joined(separator: "\n") + "\n" + endMarker + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes the temporary block; if Burrow created the file only for this
    /// run, deletes it so Mole's defaults behave exactly as before.
    static func restore() {
        let fm = FileManager.default
        if fm.fileExists(atPath: createdMarkerURL.path) {
            let remaining = stripTemporary(read())
            try? fm.removeItem(at: createdMarkerURL)
            let defaults = Set(defaultPatterns())
            let custom = remaining.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !defaults.contains($0) }
            if custom.isEmpty {
                try? fm.removeItem(at: url)
                return
            }
            try? remaining.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard exists else { return }
        let text = read()
        guard text.contains(beginMarker) else { return }
        try? stripTemporary(text).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func stripTemporary(_ text: String) -> String {
        var output: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            if line == beginMarker { skipping = true; continue }
            if line == endMarker { skipping = false; continue }
            if !skipping { output.append(line) }
        }
        return output.joined(separator: "\n")
    }
}
