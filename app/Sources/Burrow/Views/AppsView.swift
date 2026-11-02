import AppKit
import SwiftUI

@MainActor
final class AppsModel: ObservableObject {
    enum Sub: String, CaseIterable { case uninstall = "Uninstall", updates = "Updates", startup = "Startup" }
    enum Sort: String, CaseIterable { case name = "Name", size = "App size", lastUsed = "Last Used", installed = "Installed" }

    @Published var sub: Sub = .uninstall
    @Published var apps: [InstalledApp] = []
    @Published var details: [String: AppDetails] = [:]
    @Published var installedDates: [String: Date] = [:]
    @Published var loading = false
    @Published var error: String?
    @Published var sort: Sort = .size
    @Published var search = ""
    @Published var searching = false
    @Published var selected: Set<String> = []
    @Published var expanded: String?
    @Published var plans: [String: UninstallPlan] = [:]
    @Published var loadingPlans: Set<String> = []
    @Published var withData = false
    @Published var job: CLIJob?
    @Published var showRunningAlert = false
    /// Leftovers Burrow found beyond Mole's plan, per app path.
    @Published var extras: [String: [ExtraLeftover]] = [:]
    /// User overrides of the default (ready = checked) extra selection.
    @Published var extraChecked: [String: Bool] = [:]
    @Published var extraReport: String?

    let updates = UpdatesModel()
    let startup = StartupModel()
    private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let result = try await MoleCLI.run(["uninstall", "--list"])
                guard let start = result.output.firstIndex(of: "[") else {
                    error = ANSI.strip(result.errorOutput + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                apps = try decoder.decode([InstalledApp].self, from: Data(result.output[start...].utf8))
                selected = selected.filter { path in apps.contains { $0.path == path } }
                inspectAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func inspectAll() {
        let list = apps
        Task.detached(priority: .utility) {
            await withTaskGroup(of: (String, AppDetails, Date?).self) { group in
                var iterator = list.makeIterator()
                for _ in 0..<6 {
                    guard let app = iterator.next() else { break }
                    group.addTask { (app.path, AppInspector.details(for: app), Self.creationDate(app.path)) }
                }
                while let (path, d, created) = await group.next() {
                    await MainActor.run {
                        self.details[path] = d
                        if let created { self.installedDates[path] = created }
                    }
                    if let app = iterator.next() {
                        group.addTask { (app.path, AppInspector.details(for: app), Self.creationDate(app.path)) }
                    }
                }
            }
        }
    }

    nonisolated static func creationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    var visibleApps: [InstalledApp] {
        let filtered = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .name:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            return filtered.sorted { (details[$0.path]?.sizeBytes ?? 0) > (details[$1.path]?.sizeBytes ?? 0) }
        case .lastUsed:
            return filtered.sorted { (details[$0.path]?.lastUsed ?? .distantPast) < (details[$1.path]?.lastUsed ?? .distantPast) }
        case .installed:
            return filtered.sorted { (installedDates[$0.path] ?? .distantPast) > (installedDates[$1.path] ?? .distantPast) }
        }
    }

    var totalSize: Int64 { apps.reduce(0) { $0 + (details[$1.path]?.sizeBytes ?? 0) } }

    var selectedApps: [InstalledApp] { apps.filter { selected.contains($0.path) } }

    var selectedSize: Int64 { selectedApps.reduce(0) { $0 + removalSize($1) } }

    func toggleExpand(_ app: InstalledApp) {
        if expanded == app.path { expanded = nil; return }
        expanded = app.path
        loadPlan(app)
    }

    func loadPlan(_ app: InstalledApp) {
        guard plans[app.path] == nil, !loadingPlans.contains(app.path) else { return }
        loadingPlans.insert(app.path)
        Task {
            defer { loadingPlans.remove(app.path) }
            guard let result = try? await MoleCLI.run(["uninstall", "--dry-run", app.uninstallName]) else { return }
            let plan = UninstallPlan.parse(result.output + "\n" + result.errorOutput)
            plans[app.path] = plan
            let known = (plan.toRemove + plan.personalData).map(\.path)
            let others = apps.filter { $0.path != app.path }
            let otherNames = Set(others.map { $0.name.lowercased() })
            let otherIDs = Set(others.compactMap(\.bundleId))
            let found = await Task.detached(priority: .userInitiated) {
                LeftoverScanner.scan(app: app, known: known, otherNames: otherNames, otherIDs: otherIDs)
            }.value
            extras[app.path] = found
        }
    }

    func isChecked(_ extra: ExtraLeftover) -> Bool { extraChecked[extra.path] ?? extra.ready }

    func toggle(_ extra: ExtraLeftover) { extraChecked[extra.path] = !isChecked(extra) }

    /// "Select all" under Needs review: Mole's personal data and Burrow's review extras together.
    func reviewAllChecked(_ app: InstalledApp) -> Bool {
        withData && (extras[app.path] ?? []).filter { !$0.ready }.allSatisfy(isChecked)
    }

    func setReviewAll(_ app: InstalledApp, _ on: Bool) {
        withData = on
        for extra in extras[app.path] ?? [] where !extra.ready { extraChecked[extra.path] = on }
    }

    func removalSize(_ app: InstalledApp) -> Int64 {
        let base = details[app.path]?.sizeBytes ?? 0
        return base + (extras[app.path] ?? []).filter(isChecked).reduce(0) { $0 + ($1.size ?? 0) }
    }

    func select(_ app: InstalledApp, _ on: Bool) {
        if on {
            selected.insert(app.path)
            loadPlan(app)
        } else {
            selected.remove(app.path)
        }
    }

    /// Moves the chosen extras of apps Mole actually removed to the Trash.
    private func trashExtras(for removed: [InstalledApp], chosen: [String: [ExtraLeftover]]) async {
        let gone = removed.filter { !FileManager.default.fileExists(atPath: $0.path) }
        let urls = gone.flatMap { chosen[$0.path] ?? [] }
            .filter { FileManager.default.fileExists(atPath: $0.path) || $0.isLink }
            .map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        var moved = 0
        var failed: [String] = []
        for url in urls {
            do {
                try await NSWorkspace.shared.recycle([url])
                moved += 1
            } catch {
                failed.append(Format.tildePath(url.path))
            }
        }
        var report = "Burrow moved \(moved) extra leftover\(moved == 1 ? "" : "s") to the Trash."
        if !failed.isEmpty {
            report += " \(failed.count) need administrator rights or are in use; remove them in Finder: "
                + failed.prefix(4).joined(separator: ", ") + (failed.count > 4 ? " …" : "")
        }
        extraReport = report
    }

    var runningSelected: [NSRunningApplication] {
        selectedApps.compactMap(\.bundleId).flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    func requestUninstall() {
        if !runningSelected.isEmpty { showRunningAlert = true } else { uninstall() }
    }

    func quitRunningThenUninstall() {
        runningSelected.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.uninstall() }
    }

    func uninstall() {
        let names = selectedApps.map(\.uninstallName)
        guard !names.isEmpty else { return }
        let removing = selectedApps
        var chosen: [String: [ExtraLeftover]] = [:]
        for app in removing { chosen[app.path] = (extras[app.path] ?? []).filter(isChecked) }
        extraReport = nil
        let job = CLIJob(title: "Uninstall")
        var args = ["uninstall"]
        if withData { args.append("--with-data") }
        args += names
        job.onFinish = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.trashExtras(for: removing, chosen: chosen)
                self.plans = [:]
                self.extras = [:]
                self.extraChecked = [:]
                self.selected = []
                self.reload()
            }
        }
        self.job = job
        // The user confirmed in the window; answer the CLI's Enter prompt.
        job.start(args, responders: [
            .init(name: "confirm",
                  matches: { $0.contains("Enter") && $0.contains("confirm") && $0.contains("cancel") },
                  action: { .send("\r") },
                  delay: 0.8),
        ])
    }
}

struct AppsView: View {
    @ObservedObject var model: AppsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(AppsModel.Sub.allCases, id: \.self) { sub in
                        Button(sub.rawValue) { model.sub = sub }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(model.sub == sub ? 1 : 0.6))
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(model.sub == sub ? 0.1 : 0)))
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))

                Button {
                    switch model.sub {
                    case .uninstall: model.reload()
                    case .updates: model.updates.reload()
                    case .startup: model.startup.reload()
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).padding(.leading, 10)

                Spacer()
                if model.sub == .uninstall {
                    ForEach(AppsModel.Sort.allCases, id: \.self) { sort in
                        Button {
                            model.sort = sort
                        } label: {
                            Text(sort.rawValue + (model.sort == sort ? " ↓" : ""))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(model.sort == sort ? 1 : 0.55))
                        .padding(.horizontal, 8)
                    }
                    if model.searching {
                        TextField("Search", text: $model.search)
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    Button { model.searching.toggle(); if !model.searching { model.search = "" } } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).padding(.leading, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            switch model.sub {
            case .uninstall: UninstallList(model: model)
            case .updates: UpdatesView(model: model.updates)
            case .startup: StartupView(model: model.startup)
            }
        }
        .onAppear { model.loadIfNeeded() }
        .sheet(item: Binding(get: { model.job }, set: { if $0 == nil { model.job = nil } })) { job in
            JobSheet(job: job, footer: model.extraReport) { model.job = nil }
        }
        .alert("Quit running apps first?", isPresented: $model.showRunningAlert) {
            Button("Quit and Remove") { model.quitRunningThenUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.runningSelected.compactMap(\.localizedName).joined(separator: ", ") + " must close before removal.")
        }
    }
}

struct UninstallList: View {
    @ObservedObject var model: AppsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Installed Apps").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text("\(model.apps.count) apps · \(Format.bytes(model.totalSize))").font(.mono(12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 6)

            if let error = model.error {
                Text(error).font(.mono(12)).foregroundStyle(Color.warnAmber).padding()
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.visibleApps) { app in
                        AppRow(model: model, app: app)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 12) {
                HStack(spacing: -6) {
                    ForEach(model.selectedApps.prefix(4)) { app in
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 26, height: 26)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text("\(model.selected.count) apps · \(Format.bytes(model.selectedSize))")
                            .font(.system(size: 13, weight: .semibold))
                        Toggle("Also remove user data", isOn: $model.withData)
                            .toggleStyle(.checkbox).font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xE58A80))
                        Button("Clear selection") { model.selected = [] }
                            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color(hex: 0xE58A80))
                    }
                    Text("Apps and leftovers go to the Trash, so you can restore them.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button("Remove \(model.selected.count)") { model.requestUninstall() }
                    .buttonStyle(PrimaryPillStyle(width: 240))
                    .disabled(model.selected.isEmpty)
                    .opacity(model.selected.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }
}

struct AppRow: View {
    @ObservedObject var model: AppsModel
    let app: InstalledApp
    @State private var hover = false

    var body: some View {
        let d = model.details[app.path]
        let isOpen = model.expanded == app.path
        let isSelected = model.selected.contains(app.path)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 15, weight: .semibold))
                    subtitle(d).font(.mono(12))
                }
                Spacer()
                if isSelected || isOpen {
                    Button {
                        model.toggleExpand(app)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Removes \(Format.bytes(model.removalSize(app)))").font(.system(size: 13))
                            Image(systemName: "chevron.down").rotationEffect(.degrees(isOpen ? 180 : 0))
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                }
                Toggle("", isOn: Binding(get: { isSelected }, set: { on in
                    model.select(app, on)
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(Color(hex: 0xE58A80))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleExpand(app) }

            if isOpen { PlanView(model: model, app: app) }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(isOpen || hover || isSelected ? 0.06 : 0)))
        .onHover { hover = $0 }
    }

    private func subtitle(_ d: AppDetails?) -> Text {
        var parts: [String] = []
        if let v = d?.version { parts.append(v) }
        if let s = d?.sizeBytes { parts.append(Format.bytes(s)) } else if let s = app.size, s != "--" { parts.append(s) }
        if let data = d?.dataBytes, data > 1_000_000 { parts.append("\(Format.bytes(data)) data") }
        if d?.isMenuBarApp == true { parts.append("Menu bar app") }
        if app.source == "Homebrew" { parts.append("Homebrew") }
        var text = Text(parts.joined(separator: " · ")).foregroundColor(.white.opacity(0.55))
        if d?.isRunning == true {
            text = text + Text(" · active now").foregroundColor(Color.goodGreen)
        } else if let last = d?.lastUsed {
            let months = Date().timeIntervalSince(last) / (86400 * 30)
            let label = " · opened " + (Format.relative(last) ?? "")
            text = text + Text(label).foregroundColor(months > 6 ? Color.warnAmber : .white.opacity(0.55))
        }
        return text
    }
}

struct PlanView: View {
    @ObservedObject var model: AppsModel
    let app: InstalledApp

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = model.plans[app.path] {
                let extras = model.extras[app.path] ?? []
                let readyExtras = extras.filter(\.ready)
                let reviewExtras = extras.filter { !$0.ready }
                Text("Ready to remove").font(.system(size: 13, weight: .semibold)).padding(.top, 4)
                ForEach(plan.toRemove) { row in planRow(row, checked: true) }
                ForEach(readyExtras) { extra in extraRow(extra) }
                if !plan.personalData.isEmpty || !reviewExtras.isEmpty {
                    HStack {
                        Text("Needs review").font(.system(size: 13, weight: .semibold))
                        Text("May hold data you want to keep").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        let all = model.reviewAllChecked(app)
                        Button(all ? "Keep all" : "Select all") { model.setReviewAll(app, !all) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0xE58A80))
                    }
                    .padding(.top, 8)
                    ForEach(plan.personalData) { row in
                        planRow(row, checked: model.withData) { model.withData.toggle() }
                    }
                    ForEach(reviewExtras) { extra in extraRow(extra) }
                    if !plan.personalData.isEmpty {
                        Text("Mole's personal data rows follow “Also remove user data”, for every selected app.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                if model.extras[app.path] == nil {
                    HStack { ProgressView().controlSize(.mini); Text("Looking for more leftovers…").font(.system(size: 11)) }
                        .foregroundStyle(.white.opacity(0.5))
                }
                if plan.toRemove.isEmpty && plan.personalData.isEmpty && extras.isEmpty {
                    Text(ANSI.strip(plan.raw).trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.mono(11)).foregroundStyle(.white.opacity(0.6)).lineLimit(8)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Reading removal plan from Mole…").font(.system(size: 12)) }
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func planRow(_ row: UninstallPlan.Row, checked: Bool, toggle: (() -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            Button { toggle?() } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color(hex: 0xE58A80) : .white.opacity(0.5))
            }
            .buttonStyle(.plain).disabled(toggle == nil)
            Text(row.kind).font(.system(size: 13, weight: .semibold)).frame(width: 120, alignment: .leading)
            Text(row.path).font(.mono(12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let size = row.size { Text(size).font(.mono(12)).foregroundStyle(.white.opacity(0.7)) }
        }
    }

    private func extraRow(_ extra: ExtraLeftover) -> some View {
        let checked = model.isChecked(extra)
        return HStack(spacing: 12) {
            Button { model.toggle(extra) } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color(hex: 0xE58A80) : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            Text(extra.kind).font(.system(size: 13, weight: .semibold)).frame(width: 120, alignment: .leading)
            Text(Format.tildePath(extra.path)).font(.mono(12)).foregroundStyle(.white.opacity(0.75))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: extra.path)])
            } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).help("Show in Finder")
            Text(extra.isLink ? "Link" : Format.bytes(extra.size ?? 0))
                .font(.mono(12)).foregroundStyle(.white.opacity(0.7))
        }
        .help("Found by Burrow (not in Mole's plan). Goes to the Trash after the app is removed.")
    }
}

/// Sheet showing a running terminal-backed CLI job (uninstall, brew upgrade).
struct JobSheet: View {
    @ObservedObject var job: CLIJob
    var footer: String? = nil
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if job.isRunning { ProgressView().controlSize(.small) }
                Text(job.isRunning ? "\(job.title) in progress…" : "\(job.title) finished").font(.headline)
                Spacer()
                if let code = job.exitCode {
                    Chip(text: code == 0 ? "Done" : "Exit \(code)", tint: code == 0 ? Color.goodGreen : Color.warnAmber)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(job.transcript.all.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.mono(11)).foregroundStyle(.white.opacity(0.8)).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                .onChange(of: job.transcript.all.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            }
            if let prompt = job.stalledPrompt {
                HStack {
                    Text(prompt).font(.mono(11)).lineLimit(2)
                    Spacer()
                    Button("Enter") { job.sendKeys("\r") }
                    Button("Cancel") { job.cancel() }
                }
            }
            HStack {
                Spacer()
                if job.isRunning {
                    Button("Stop") { job.cancel() }
                } else {
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 440)
        .sheet(isPresented: Binding(get: { job.passwordRequest != nil },
                                    set: { if !$0 && job.passwordRequest != nil { job.cancelPassword() } })) {
            PasswordSheet(job: job)
        }
    }
}
