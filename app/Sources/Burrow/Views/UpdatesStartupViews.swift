import AppKit
import SwiftUI

// MARK: - Updates (Homebrew)

/// Mole itself does not update other apps. This tab lists what Homebrew
/// reports as outdated and runs `brew upgrade` for the chosen package.
@MainActor
final class UpdatesModel: ObservableObject {
    struct Package: Identifiable, Hashable {
        let name: String
        let installed: String
        let current: String
        let isCask: Bool
        var id: String { (isCask ? "cask:" : "formula:") + name }
    }

    @Published var packages: [Package] = []
    @Published var loading = false
    @Published var message: String?
    @Published var job: CLIJob?
    private var loaded = false

    static let brewURL: URL? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        guard let brew = Self.brewURL else {
            message = "Homebrew is not installed. App Store and in-app updates are handled by each app."
            return
        }
        loading = true
        message = nil
        Task {
            defer { loading = false }
            guard let result = try? await MoleCLI.runExecutable(brew, ["outdated", "--json=v2", "--greedy-auto-updates"]),
                  let start = result.output.firstIndex(of: "{"),
                  let json = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [String: Any]
            else {
                message = "Could not read Homebrew's outdated list."
                return
            }
            var list: [Package] = []
            for (key, isCask) in [("formulae", false), ("casks", true)] {
                for item in json[key] as? [[String: Any]] ?? [] {
                    let name = item["name"] as? String ?? "?"
                    let installed: String
                    if let arr = item["installed_versions"] as? [String] { installed = arr.joined(separator: ", ") }
                    else { installed = item["installed_versions"] as? String ?? "" }
                    let current = item["current_version"] as? String ?? ""
                    list.append(Package(name: name, installed: installed, current: current, isCask: isCask))
                }
            }
            packages = list.sorted { $0.name < $1.name }
            if list.isEmpty { message = "Everything installed with Homebrew is up to date." }
        }
    }

    func upgrade(_ names: [Package]) {
        guard let brew = Self.brewURL, !names.isEmpty else { return }
        let job = CLIJob(title: "Homebrew upgrade")
        var args = ["upgrade"]
        if names.allSatisfy(\.isCask) { args.append("--cask") }
        args += names.map(\.name)
        job.onFinish = { [weak self] _ in self?.reload() }
        self.job = job
        job.start(executable: brew, args)
    }
}

struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Asking Homebrew…").padding(.top, 40)
            }
            if let message = model.message {
                Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).padding(.top, 40)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.packages) { pkg in
                        HStack(spacing: 14) {
                            Image(systemName: pkg.isCask ? "macwindow" : "terminal")
                                .font(.system(size: 18)).frame(width: 38, height: 38)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pkg.name).font(.system(size: 15, weight: .semibold))
                                Text("\(pkg.installed) → \(pkg.current) · \(pkg.isCask ? "Cask" : "Formula")")
                                    .font(.mono(12)).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Button("Update") { model.upgrade([pkg]) }.buttonStyle(SubtleButtonStyle())
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                    }
                }
                .padding(.horizontal, 24)
            }
            if !model.packages.isEmpty {
                HStack {
                    Text("\(model.packages.count) updates via Homebrew").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Update All") { model.upgrade(model.packages) }.buttonStyle(PrimaryPillStyle(width: 200))
                }
                .padding(.horizontal, 28).padding(.vertical, 14)
            }
        }
        .onAppear { model.loadIfNeeded() }
        .sheet(item: Binding(get: { model.job }, set: { if $0 == nil { model.job = nil } })) { job in
            JobSheet(job: job) { model.job = nil }
        }
    }
}

// MARK: - Startup (launchd)

@MainActor
final class StartupModel: ObservableObject {
    enum Domain: String { case user = "User agent", global = "Global agent", system = "System background service" }

    struct Item: Identifiable, Hashable {
        let label: String
        let plistPath: String
        let domain: Domain
        let program: String?
        let appPath: String?
        var disabled: Bool
        var id: String { plistPath }

        var displayName: String {
            if let appPath { return URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent }
            return label
        }
    }

    @Published var items: [Item] = []
    @Published var loading = false
    @Published var error: String?
    private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        loading = true
        Task {
            let uid = getuid()
            async let userDisabled = disabledLabels(domain: "gui/\(uid)")
            async let systemDisabled = disabledLabels(domain: "system")
            let (ud, sd) = await (userDisabled, systemDisabled)
            let home = NSHomeDirectory()
            var list: [Item] = []
            list += scan(dir: home + "/Library/LaunchAgents", domain: .user, disabled: ud)
            list += scan(dir: "/Library/LaunchAgents", domain: .global, disabled: ud)
            list += scan(dir: "/Library/LaunchDaemons", domain: .system, disabled: sd)
            items = list
            loading = false
        }
    }

    private func scan(dir: String, domain: Domain, disabled: Set<String>) -> [Item] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".plist") }.sorted().compactMap { file in
            let path = dir + "/" + file
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            let label = plist["Label"] as? String ?? (file as NSString).deletingPathExtension
            let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            var appPath: String?
            if let program, let range = program.range(of: ".app/") {
                appPath = String(program[..<range.lowerBound]) + ".app"
            }
            let isDisabled = disabled.contains(label) || plist["Disabled"] as? Bool == true
            return Item(label: label, plistPath: path, domain: domain, program: program, appPath: appPath, disabled: isDisabled)
        }
    }

    private func disabledLabels(domain: String) async -> Set<String> {
        guard let result = try? await MoleCLI.runExecutable(URL(fileURLWithPath: "/bin/launchctl"), ["print-disabled", domain])
        else { return [] }
        var set = Set<String>()
        for line in result.output.split(separator: "\n") {
            // "com.example.agent" => disabled   (or => true on older systems)
            guard line.contains("=>") else { continue }
            let parts = line.components(separatedBy: "=>")
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if value == "disabled" || value == "true" { set.insert(label) }
        }
        return set
    }

    func setEnabled(_ item: Item, enabled: Bool) {
        Task {
            let uid = getuid()
            let launchctl = URL(fileURLWithPath: "/bin/launchctl")
            switch item.domain {
            case .user, .global:
                let target = "gui/\(uid)/\(item.label)"
                if enabled {
                    _ = try? await MoleCLI.runExecutable(launchctl, ["enable", target])
                    _ = try? await MoleCLI.runExecutable(launchctl, ["bootstrap", "gui/\(uid)", item.plistPath])
                } else {
                    _ = try? await MoleCLI.runExecutable(launchctl, ["disable", target])
                    _ = try? await MoleCLI.runExecutable(launchctl, ["bootout", target])
                }
            case .system:
                // System daemons need an administrator; macOS shows its own prompt.
                let verb = enabled ? "enable" : "disable"
                let label = item.label.replacingOccurrences(of: "'", with: "")
                var command = "/bin/launchctl \(verb) system/\(label)"
                if !enabled { command += "; /bin/launchctl bootout system/\(label) 2>/dev/null; true" }
                let script = "do shell script \"\(command)\" with administrator privileges"
                _ = try? await MoleCLI.runExecutable(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
            }
            reload()
        }
    }
}

struct StartupView: View {
    @ObservedObject var model: StartupModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Login items").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Button("Open Login Items Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                .padding(.horizontal, 16).padding(.top, 4)
                Text("macOS manages login items and “Allow in the Background” in System Settings.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 16).padding(.bottom, 10)

                section(.user)
                section(.global)
                section(.system)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .onAppear { model.loadIfNeeded() }
    }

    @ViewBuilder
    private func section(_ domain: StartupModel.Domain) -> some View {
        let items = model.items.filter { $0.domain == domain }
        if !items.isEmpty {
            HStack(spacing: 6) {
                Text(title(domain)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text("\(items.count)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            ForEach(items) { item in StartupRow(model: model, item: item) }
        }
    }

    private func title(_ d: StartupModel.Domain) -> String {
        switch d {
        case .user: return "Your launch agents"
        case .global: return "Launch agents for all users"
        case .system: return "Background services"
        }
    }
}

struct StartupRow: View {
    @ObservedObject var model: StartupModel
    let item: StartupModel.Item
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let app = item.appPath, FileManager.default.fileExists(atPath: app) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable()
                } else {
                    Image(systemName: "gearshape").font(.system(size: 18)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(item.appPath == nil ? item.domain.rawValue : "\(item.domain.rawValue) · \(item.label)")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer()
            if hover {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Show plist in Finder")
            }
            Toggle("", isOn: Binding(get: { !item.disabled }, set: { model.setEnabled(item, enabled: $0) }))
                .toggleStyle(.switch).labelsHidden().tint(Color.goodGreen)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.05 : 0)))
        .onHover { hover = $0 }
    }
}
