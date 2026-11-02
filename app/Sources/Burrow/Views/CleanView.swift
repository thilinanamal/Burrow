import AppKit
import SwiftUI

@MainActor
final class CleanModel: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning, review, cleaning, done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var scanLine = ""
    @Published var preview: CleanPreview?
    @Published var excluded: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published var includeSystem = false
    @Published var job: CLIJob?
    @Published var result: HistoryReport.Session?
    @Published var removedLine: String?
    @Published var protectedPaths: Set<String> = []

    private var scanTask: Task<Void, Never>?

    // MARK: Scan

    func scan() {
        phase = .scanning
        scanLine = "Starting scan…"
        excluded = []
        expanded = []
        scanTask?.cancel()
        scanTask = Task {
            do {
                let result = try await MoleCLI.run(["clean", "--dry-run"]) { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("➤ ") || trimmed.hasPrefix("○ ") else { return }
                    Task { @MainActor in self.scanLine = String(trimmed.dropFirst(2)) }
                }
                if Task.isCancelled { return }
                let listURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/mole/clean-list.txt")
                let list = (try? String(contentsOf: listURL, encoding: .utf8)) ?? ""
                let parsed = CleanPreview.parse(stdout: result.output + "\n" + result.errorOutput, cleanList: list)
                guard result.succeeded || !parsed.categories.isEmpty else {
                    phase = .failed(lastMeaningfulLine(result.errorOutput + result.output) ?? "Scan failed (exit \(result.status)).")
                    return
                }
                preview = parsed
                refreshInUse()
                applyRecommended()
                phase = .review
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        phase = .idle
    }

    // MARK: Selection

    /// Rows whose live data folder belongs to a running app, keyed by group root.
    @Published var holding: [String: CleanGrouping.RunningApp] = [:]
    @Published var showQuitAlert = false
    @Published var hasFullDiskAccess = FullDiskAccess.isGranted

    func isTrash(_ cat: CleanPreview.Category) -> Bool { cat.name == CleanPreview.trashName }

    func isLocked(_ group: CleanPreview.Group) -> Bool { holding[group.root] != nil }

    func refreshInUse() {
        let running = CleanGrouping.runningApps()
        var map: [String: CleanGrouping.RunningApp] = [:]
        for cat in preview?.categories ?? [] where !isTrash(cat) {
            for group in cat.groups {
                if let app = CleanGrouping.holdingApp(root: group.root, running: running) { map[group.root] = app }
            }
        }
        holding = map
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    var holdingApps: [CleanGrouping.RunningApp] {
        var seen = Set<String>()
        return holding.values.filter { seen.insert($0.bundleID).inserted }.sorted { $0.name < $1.name }
    }

    func quitHoldingApps() {
        for app in holdingApps {
            NSRunningApplication(processIdentifier: app.pid)?.terminate()
        }
        Task {
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                refreshInUse()
                if holding.isEmpty { break }
            }
        }
    }

    enum CheckState { case on, off, mixed }

    func state(_ group: CleanPreview.Group) -> CheckState {
        if isLocked(group) { return .off }
        let n = group.paths.reduce(0) { $0 + (excluded.contains($1.path) ? 0 : 1) }
        if n == 0 { return .off }
        return n == group.paths.count ? .on : .mixed
    }

    func selectedSize(_ group: CleanPreview.Group) -> Int64 {
        if isLocked(group) { return 0 }
        return group.paths.reduce(0) { $0 + (excluded.contains($1.path) ? 0 : $1.size) }
    }

    func selectedCount(_ cat: CleanPreview.Category) -> Int {
        cat.groups.reduce(0) { $0 + (state($1) == .off ? 0 : 1) }
    }

    func selectedSize(_ cat: CleanPreview.Category) -> Int64 {
        cat.groups.reduce(0) { $0 + selectedSize($1) }
    }

    func state(_ cat: CleanPreview.Category) -> CheckState {
        guard !cat.groups.isEmpty else { return isTrash(cat) ? .off : .on }
        let states = cat.groups.map(state)
        if states.allSatisfy({ $0 == .off }) { return .off }
        return states.allSatisfy { $0 == .on } ? .on : .mixed
    }

    func toggle(_ cat: CleanPreview.Category) {
        let free = cat.groups.filter { !isLocked($0) }
        let paths = free.flatMap { $0.paths.map(\.path) }
        if !free.isEmpty && free.allSatisfy({ state($0) == .on }) {
            excluded.formUnion(paths)
        } else {
            excluded.subtract(paths)
        }
    }

    func toggle(_ group: CleanPreview.Group) {
        let paths = group.paths.map(\.path)
        if state(group) == .off { excluded.subtract(paths) } else { excluded.formUnion(paths) }
    }

    func selectAll() { excluded = protectedPaths }

    func selectNone() {
        excluded = Set(preview?.categories.flatMap { $0.paths.map(\.path) } ?? [])
    }

    /// Leaves out the Trash, rows that need a look first (re-downloads,
    /// project build output, leftovers of removed apps) and rows still held by
    /// a running app (those are locked anyway).
    func applyRecommended() {
        var out = Set<String>()
        for cat in preview?.categories ?? [] {
            for group in cat.groups where isTrash(cat) || group.reviewReason != nil {
                out.formUnion(group.paths.map(\.path))
            }
        }
        excluded = out.union(protectedPaths)
    }

    var totalSelectedSize: Int64 {
        preview?.categories.reduce(0) { $0 + selectedSize($1) } ?? 0
    }

    var totalSelectedCount: Int {
        preview?.categories.reduce(0) { $0 + selectedCount($1) } ?? 0
    }

    var totalItemCount: Int {
        preview?.categories.reduce(0) { $0 + $1.groups.count } ?? 0
    }

    /// Whitelist entries that keep every unselected or locked row out of the run.
    func temporaryExclusions() -> [String] {
        guard let preview else { return [] }
        let home = NSHomeDirectory()
        var list: [String] = []
        for cat in preview.categories {
            if isTrash(cat) {
                // The Trash is emptied as a whole; leaving any of it out keeps all of it.
                if cat.groups.isEmpty || cat.groups.contains(where: { state($0) != .on }) {
                    list.append(home + "/.Trash")
                }
                continue
            }
            for group in cat.groups {
                let st = state(group)
                if st == .off {
                    list.append(group.root)
                    list += CleanGrouping.extraWhitelist(forExcludedRoot: group.root)
                } else if st == .mixed {
                    list += group.paths.map(\.path).filter { excluded.contains($0) }
                }
            }
        }
        return Array(Set(list).subtracting(protectedPaths)).sorted()
    }

    // MARK: Protect

    func protect(_ path: String) {
        do {
            try Whitelist.protect(path)
            protectedPaths.insert(path)
            excluded.insert(path)
        } catch {
            NSSound.beep()
        }
    }

    func unprotect(_ path: String) {
        try? Whitelist.unprotect(path)
        protectedPaths.remove(path)
    }

    // MARK: Clean

    func startClean() {
        guard preview != nil else { return }
        let temporary = temporaryExclusions()
        do {
            try Whitelist.applyTemporary(temporary)
        } catch {
            phase = .failed("Could not prepare exclusions: \(error.localizedDescription)")
            return
        }

        let job = CLIJob(title: "Clean")
        let wantsSystem = includeSystem
        let responders: [CLIJob.Responder] = [
            .init(name: "system-sudo",
                  matches: { $0.contains("System caches need sudo") && $0.contains("skip") },
                  action: {
                      wantsSystem ? .askPassword(reason: "Cleaning system caches needs your administrator password.")
                          : .send(" ")
                  }),
        ]
        job.onFinish = { [weak self] _ in
            Whitelist.restore()
            Task { @MainActor in await self?.finishClean() }
        }
        self.job = job
        phase = .cleaning
        job.start(["clean"], responders: responders)
    }

    private func finishClean() async {
        removedLine = job?.transcript.all.reversed().first(where: { $0.contains("Removed:") })?
            .trimmingCharacters(in: .whitespaces)
        result = await HistoryReport.latest(command: "clean")
        phase = .done
    }

    func reset() {
        job = nil
        preview = nil
        result = nil
        removedLine = nil
        phase = .idle
    }

    private func lastMeaningfulLine(_ text: String) -> String? {
        ANSI.strip(text).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
    }
}

// MARK: - Views

struct CleanView: View {
    @ObservedObject var model: CleanModel

    var body: some View {
        content.onAppear {
            // Screenshot / QA hook: start a (read-only) preview scan immediately.
            if ProcessInfo.processInfo.environment["BURROW_AUTOSCAN"] == "1", model.phase == .idle { model.scan() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            HeroScreen(planet: .earth, satellite: .moon,
                       verse: ["Old dust gathers where no one looks.", "One sweep, and every room breathes again."],
                       buttonTitle: "Scan your Mac") { model.scan() }
        case .scanning:
            WorkingScreen(planet: .earth, title: "Scanning", detail: model.scanLine,
                          cancel: { model.cancelScan() })
        case .review:
            CleanReviewView(model: model)
        case .cleaning:
            if let job = model.job {
                JobScreen(planet: .earth, title: "Cleaning", job: job)
            }
        case .done:
            CleanDoneView(model: model)
        case .failed(let message):
            FailureScreen(planet: .earth, message: message) { model.reset() }
        }
    }
}

struct CleanReviewView: View {
    @ObservedObject var model: CleanModel

    var body: some View {
        let preview = model.preview ?? CleanPreview()
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ready to clean").font(.system(size: 26, weight: .bold))
                    HStack(spacing: 0) {
                        Text(subtitle(preview))
                        if !model.holdingApps.isEmpty {
                            Text(" · \(model.holdingApps.map(\.name).joined(separator: ", ")) holding cache · ")
                            Button("Quit") { model.showQuitAlert = true }
                                .buttonStyle(.plain).foregroundStyle(.white)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                }
                Spacer()
                Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Scan again")
                Button { model.reset() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 18)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).padding(.leading, 12)
                    .help("Close")
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 16)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if !model.hasFullDiskAccess {
                        FullDiskAccessNote(text: "Without Full Disk Access, macOS hides the Trash and some app caches from Mole. Grant it, then scan again.")
                    }
                    ForEach(preview.categories) { cat in
                        CategoryCard(model: model, category: cat)
                    }
                    if !preview.manageSeparately.isEmpty {
                        ManageSeparatelyCard(items: preview.manageSeparately)
                    }
                    if preview.systemNeedsSudo {
                        Toggle(isOn: $model.includeSystem) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Also clean system caches").font(.system(size: 13, weight: .semibold))
                                Text("Mole will ask for your administrator password during the run.")
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .toggleStyle(.switch)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 14) {
                Text("\(model.totalSelectedCount) selected").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Button("All") { model.selectAll() }
                    Text("·").foregroundStyle(.white.opacity(0.4))
                    Button("None") { model.selectNone() }
                    Text("·").foregroundStyle(.white.opacity(0.4))
                    Button("Recommended") { model.applyRecommended() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x8FB4FF))
                Spacer()
                Button("Permanently clean · \(Format.bytes(model.totalSelectedSize))") { model.startClean() }
                    .buttonStyle(PrimaryPillStyle(width: 260))
                    .disabled(model.totalSelectedCount == 0 && !model.includeSystem)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .alert("Quit apps holding cache?", isPresented: $model.showQuitAlert) {
            Button("Quit Apps") { model.quitHoldingApps() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.holdingApps.map(\.name).joined(separator: ", ")
                 + " will be asked to quit (unsaved work prompts as usual). Their caches then become selectable.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshInUse()
        }
    }

    private func subtitle(_ p: CleanPreview) -> String {
        let total = p.categories.reduce(Int64(0)) { $0 + $1.totalSize }
        return ["\(Format.bytes(model.totalSelectedSize)) of \(Format.bytes(total)) selected",
                "\(model.totalItemCount) items",
                "\(p.categories.count) categories"].joined(separator: " · ")
    }
}

struct CheckBox: View {
    var state: CleanModel.CheckState
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(state == .off ? Color.clear : Color(hex: 0x8FB4FF).opacity(disabled ? 0.4 : 0.9))
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(state == .off ? 0.45 : 0), lineWidth: 1.2)
                if state == .on {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: 0x1D2134))
                } else if state == .mixed {
                    Rectangle().fill(Color(hex: 0x1D2134)).frame(width: 8, height: 2)
                }
            }
            .frame(width: 17, height: 17)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct CategoryCard: View {
    @ObservedObject var model: CleanModel
    let category: CleanPreview.Category
    private let rowLimit = 300
    @State private var showSummary = false

    var isOpen: Bool { model.expanded.contains(category.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                CheckBox(state: model.state(category), disabled: category.groups.isEmpty) { model.toggle(category) }
                    .help(category.groups.isEmpty ? "Handled by Mole as one step (e.g. a package manager's own cleanup)." : "")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(category.name).font(.system(size: 15, weight: .semibold))
                        if !category.groups.isEmpty {
                            Text("\(model.selectedCount(category))/\(category.groups.count) selected")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Text(CleanPreview.subtitle(for: category.name))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text(model.selectedSize(category) == category.totalSize
                     ? Format.bytes(category.totalSize)
                     : "\(Format.bytes(model.selectedSize(category))) / \(Format.bytes(category.totalSize))")
                    .font(.mono(13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x8FB4FF))
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen { model.expanded.remove(category.id) } else { model.expanded.insert(category.id) }
                }
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    if model.isTrash(category) && category.groups.isEmpty && !model.hasFullDiskAccess {
                        FullDiskAccessNote(text: "macOS hides the Trash from Burrow until it has Full Disk Access.")
                            .padding(.horizontal, 50).padding(.vertical, 6)
                    }
                    ForEach(category.groups.prefix(rowLimit)) { group in
                        GroupRow(model: model, group: group, wholeCategory: model.isTrash(category) ? category : nil)
                    }
                    if category.groups.count > rowLimit {
                        Text("and \(category.groups.count - rowLimit) smaller items (follow the category checkbox)")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 50).padding(.vertical, 8)
                    }
                    if !category.items.isEmpty {
                        Button {
                            withAnimation { showSummary.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showSummary ? "chevron.down" : "chevron.right").font(.system(size: 9))
                                Text("Mole's summary (\(category.items.count) steps)")
                            }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 50).padding(.top, 10).padding(.bottom, 4)
                        if showSummary {
                            ForEach(category.items) { item in
                                HStack {
                                    Text(item.label).font(.system(size: 12))
                                    Spacer()
                                    Text(item.detail).font(.mono(11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                                }
                                .padding(.horizontal, 50)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

struct GroupRow: View {
    @ObservedObject var model: CleanModel
    let group: CleanPreview.Group
    /// Set for the Trash: its rows follow the whole category (it is emptied at once).
    var wholeCategory: CleanPreview.Category?
    @State private var hovering = false

    var body: some View {
        let isProtected = model.protectedPaths.contains(group.root)
        let holder = model.holding[group.root]
        HStack(spacing: 12) {
            if isProtected {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(width: 17)
            } else if holder != nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.3), lineWidth: 1.2)
                    Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(width: 17, height: 17)
                .help("\(holder!.name) is running and using this data. Quit it to clean this item.")
            } else {
                CheckBox(state: model.state(group)) {
                    if let wholeCategory { model.toggle(wholeCategory) } else { model.toggle(group) }
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(group.name).font(.system(size: 13))
                        .foregroundStyle(.white.opacity(isProtected ? 0.5 : 0.92))
                    if holder != nil {
                        Text("In use").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }
                    if group.paths.count > 1 {
                        Text("\(group.paths.count) items").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                    }
                }
                if let reason = group.reviewReason, model.state(group) == .off, holder == nil, !isProtected {
                    HStack(spacing: 6) {
                        Text("Not selected automatically: \(reason.prefix(1).lowercased() + reason.dropFirst())")
                            .foregroundStyle(.white.opacity(0.5))
                        Text(Format.tildePath(group.root)).font(.mono(11)).foregroundStyle(Color(hex: 0xE0C38C))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                } else {
                    Text(Format.tildePath(group.root)).font(.mono(11)).foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(isProtected ? "Protected" : Format.bytes(group.size))
                .font(.mono(12)).foregroundStyle(.white.opacity(0.7))
            Button {
                if isProtected { model.unprotect(group.root) } else { model.protect(group.root) }
            } label: {
                Image(systemName: isProtected ? "shield.fill" : "shield")
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
            .help(isProtected ? "Remove protection" : "Always protect this item (adds it to Mole's whitelist)")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: group.root)])
            } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                .help("Show in Finder")
        }
        .padding(.leading, 50)
        .padding(.trailing, 20)
        .padding(.vertical, 6)
        .background(hovering ? Color.white.opacity(0.04) : Color.clear)
        .onHover { hovering = $0 }
    }
}

struct FullDiskAccessNote: View {
    var text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(Color.warnAmber)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button("Grant Full Disk Access") { FullDiskAccess.openSettings() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x8FB4FF))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.warnAmber.opacity(0.08)))
    }
}

struct ManageSeparatelyCard: View {
    let items: [CleanPreview.Item]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "circle.inset.filled").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage Separately").font(.system(size: 15, weight: .semibold))
                    Text("Storage usage only, excluded from cleaning. Review these in their app or System Settings.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { open.toggle() } }
            if open {
                ForEach(items) { item in
                    HStack {
                        Text(item.label).font(.system(size: 13))
                        Spacer()
                        Text(item.detail).font(.mono(11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    .padding(.horizontal, 50).padding(.vertical, 4)
                }
                .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}

struct CleanDoneView: View {
    @ObservedObject var model: CleanModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            PlanetView(kind: .earth).frame(width: 220, height: 220)
            Text(headline).font(.system(size: 30, weight: .bold))
            if let s = model.result {
                HStack(spacing: 26) {
                    stat("Items", "\(s.items ?? 0)")
                    stat("Removed", "\(s.actions?.removed ?? 0)")
                    stat("Skipped", "\(s.actions?.skipped ?? 0)")
                    stat("Failed", "\(s.actions?.failed ?? 0)")
                }
            }
            if let code = model.job?.exitCode, code != 0 {
                Text("Mole exited with code \(code). See the log for details.")
                    .font(.system(size: 13)).foregroundStyle(Color.warnAmber)
            }
            if let job = model.job { LogDisclosure(job: job) }
            Button("Done") { model.reset() }.buttonStyle(PrimaryPillStyle(width: 200))
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var headline: String {
        if let line = model.removedLine { return line.replacingOccurrences(of: "Removed:", with: "Freed") }
        if let size = model.result?.size { return "Freed \(size)" }
        return "Cleanup finished"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 22, weight: .semibold))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
        }
    }
}
