import AppKit
import SwiftUI

@MainActor
final class AnalyzeModel: ObservableObject {
    struct Level: Identifiable {
        let id = UUID()
        let title: String
        let path: String?   // nil = Mole's whole-disk overview
        var result: AnalyzeResult?
    }

    @Published var stack: [Level] = []
    @Published var loading = false
    @Published var error: String?
    @Published var sidebarMode = 0  // 0 current folder, 1 largest files
    @Published var hovered: String?
    private var cache: [String: AnalyzeResult] = [:]
    private var task: Task<Void, Never>?

    var current: Level? { stack.last }

    func start() {
        guard stack.isEmpty else { return }
        open(title: "Whole Disk", path: nil)
    }

    func open(title: String, path: String?) {
        stack.append(Level(title: title, path: path))
        load()
    }

    func pop(to index: Int) {
        guard index < stack.count else { return }
        stack = Array(stack.prefix(index + 1))
        if stack.last?.result == nil { load() }
    }

    func refresh() {
        cache[current?.path ?? "__overview__"] = nil
        if !stack.isEmpty { stack[stack.count - 1].result = nil }
        load()
    }

    private func load() {
        guard let level = stack.last else { return }
        let key = level.path ?? "__overview__"
        if let cached = cache[key] {
            stack[stack.count - 1].result = cached
            return
        }
        task?.cancel()
        loading = true
        error = nil
        task = Task {
            var args = ["analyze", "--json"]
            if let path = level.path { args.append(path) }
            do {
                let output = try await MoleCLI.run(args)
                if Task.isCancelled { return }
                if let parsed = AnalyzeResult.decode(output.output) {
                    cache[key] = parsed
                    if let idx = stack.firstIndex(where: { $0.id == level.id }) { stack[idx].result = parsed }
                } else {
                    error = ANSI.strip(output.errorOutput + output.output)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: "\n").last.map(String.init) ?? "Analyze returned no data."
                }
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    func moveToTrash(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.error = error.localizedDescription
                    return
                }
                // Invalidate every cached level that contains this path.
                for key in self.cache.keys where key == "__overview__" || path.hasPrefix(key) {
                    self.cache[key] = nil
                }
                self.refresh()
            }
        }
    }
}

struct AnalyzeView: View {
    @ObservedObject var model: AnalyzeModel
    @State private var confirmTrash: String?

    var body: some View {
        HStack(spacing: 18) {
            sidebar.frame(width: 240)
            VStack(spacing: 10) {
                header
                ZStack {
                    if let result = model.current?.result {
                        Treemap(entries: result.sortedEntries.filter { $0.size > 0 },
                                total: result.computedTotal,
                                hovered: $model.hovered,
                                open: { entry in
                                    if entry.isDir ?? true { model.open(title: entry.name, path: entry.path) }
                                },
                                menu: { entry in contextMenu(for: entry.path) })
                    }
                    if model.loading {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Measuring \(model.current?.title ?? "")…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                            Text("A first scan of a large folder can take a minute.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(22)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.35)))
                    }
                    if let error = model.error {
                        Text(error).font(.mono(12)).foregroundStyle(Color.warnAmber).padding()
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .onAppear { model.start() }
        .alert("Move to Trash?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let path = confirmTrash { model.moveToTrash(path) }
                confirmTrash = nil
            }
            Button("Cancel", role: .cancel) { confirmTrash = nil }
        } message: {
            Text(confirmTrash.map { Format.tildePath($0) } ?? "")
        }
    }

    @ViewBuilder
    private func contextMenu(for path: String) -> some View {
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        Button("Open in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        Divider()
        Button("Move to Trash") { confirmTrash = path }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.stack.enumerated()), id: \.element.id) { index, level in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
                Button(level.title) { model.pop(to: index) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: index == model.stack.count - 1 ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(index == model.stack.count - 1 ? 1 : 0.65))
            }
            Spacer()
            if let disk = diskUsage {
                ProgressView(value: disk.used, total: disk.total)
                    .progressViewStyle(.linear).tint(Color(hex: 0xE3A766)).frame(width: 80)
                Text("Used \(Format.gigabytes(disk.used)) / \(Format.gigabytes(disk.total)) GB")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).padding(.leading, 6)
        }
        .frame(height: 28)
    }

    private var diskUsage: (used: Double, total: Double)? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Double(Int64(total) - free), Double(total))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                PlanetView(kind: .jupiter, spinSeconds: 70).frame(width: 120, height: 120)
                if let result = model.current?.result {
                    Text(summary(result)).font(.mono(13)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)

            HStack(spacing: 14) {
                tabButton("Current Folder", 0)
                tabButton("Largest Files", 1)
            }
            .padding(.top, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let result = model.current?.result {
                        if model.sidebarMode == 0 {
                            ForEach(result.sortedEntries) { entry in
                                SidebarRow(name: entry.name, size: sizeLabel(entry), isDir: entry.isDir ?? true,
                                           highlighted: model.hovered == entry.path) {
                                    if entry.isDir ?? true { model.open(title: entry.name, path: entry.path) }
                                }
                                .contextMenu { contextMenu(for: entry.path) }
                            }
                        } else {
                            ForEach(result.largeFiles ?? []) { file in
                                SidebarRow(name: file.name, size: Format.bytes(file.size), isDir: false, highlighted: false) {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                                }
                                .contextMenu { contextMenu(for: file.path) }
                            }
                            if (result.largeFiles ?? []).isEmpty {
                                Text("No large files reported here.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }
            }
            Text("Right-click: Copy path · Finder · Trash").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func tabButton(_ title: String, _ index: Int) -> some View {
        Button(title) { model.sidebarMode = index }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(model.sidebarMode == index ? 1 : 0.5))
    }

    private func sizeLabel(_ e: AnalyzeResult.Entry) -> String {
        if e.isUnavailable { return "unavailable" }
        return (e.isPartial ? "≥ " : "") + Format.bytes(e.size)
    }

    private func summary(_ r: AnalyzeResult) -> String {
        let count = r.entries?.count ?? 0
        // Overview locations overlap (Home contains User Library), so no total.
        if r.overview == true { return "\(count) locations" }
        return "\(count) items, \(r.scanStatus == "partial" ? "≥ " : "")\(Format.bytes(r.computedTotal))"
    }
}

struct SidebarRow: View {
    var name: String
    var size: String
    var isDir: Bool
    var highlighted: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isDir ? "folder" : "doc").foregroundStyle(.white.opacity(0.65)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(size).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                if isDir { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover || highlighted ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Treemap

struct Treemap<Menu: View>: View {
    var entries: [AnalyzeResult.Entry]
    var total: Int64
    @Binding var hovered: String?
    var open: (AnalyzeResult.Entry) -> Void
    @ViewBuilder var menu: (AnalyzeResult.Entry) -> Menu

    private let palette: [Color] = [
        Color(hex: 0x8C6A57), Color(hex: 0x9C7040), Color(hex: 0xA6553A), Color(hex: 0x6E5A4C),
        Color(hex: 0x7F6A3E), Color(hex: 0x8E4F3F), Color(hex: 0x6B4E3A), Color(hex: 0x9A7B5C),
    ]

    var body: some View {
        GeometryReader { geo in
            let shown = Array(entries.prefix(9))
            let rest = entries.dropFirst(9)
            let restSize = rest.reduce(Int64(0)) { $0 + $1.size }
            let weights = shown.map { Double($0.size) } + (restSize > 0 ? [Double(restSize)] : [])
            let rects = Squarify.layout(weights: weights, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(rects.enumerated()), id: \.offset) { index, rect in
                    if index < shown.count {
                        let entry = shown[index]
                        tile(title: entry.name,
                             subtitle: (entry.isPartial ? "≥ " : "") + Format.bytes(entry.size),
                             icon: (entry.isDir ?? true) ? "folder" : "doc",
                             color: palette[index % palette.count],
                             rect: rect,
                             highlighted: hovered == entry.path)
                            .onHover { hovered = $0 ? entry.path : (hovered == entry.path ? nil : hovered) }
                            .onTapGesture { open(entry) }
                            .contextMenu { menu(entry) }
                    } else {
                        tile(title: "\(rest.count) items", subtitle: Format.bytes(restSize), icon: "square.grid.2x2",
                             color: Color(hex: 0x5E4E44), rect: rect, highlighted: false)
                    }
                }
            }
        }
    }

    private func tile(title: String, subtitle: String, icon: String, color: Color, rect: CGRect, highlighted: Bool) -> some View {
        let inset = rect.insetBy(dx: 2.5, dy: 2.5)
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(highlighted ? 1 : 0.88))
            if inset.width > 70 && inset.height > 34 {
                VStack(spacing: 2) {
                    Label(title, systemImage: icon).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if inset.height > 50 {
                        Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(6)
            }
        }
        .frame(width: max(0, inset.width), height: max(0, inset.height))
        .offset(x: inset.minX, y: inset.minY)
        .help("\(title) · \(subtitle)")
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk).
enum Squarify {
    static func layout(weights: [Double], in rect: CGRect) -> [CGRect] {
        let total = weights.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return weights.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = weights.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: weights.count)
        var remaining = rect
        var index = 0
        while index < areas.count {
            var row: [Int] = [index]
            let side = Double(min(remaining.width, remaining.height))
            var best = worst(row.map { areas[$0] }, side: side)
            var next = index + 1
            while next < areas.count {
                let candidate = row + [next]
                let score = worst(candidate.map { areas[$0] }, side: side)
                if score > best { break }
                row = candidate
                best = score
                next += 1
            }
            let rowArea = row.reduce(0.0) { $0 + areas[$1] }
            if remaining.width >= remaining.height {
                let w = CGFloat(rowArea / Double(remaining.height))
                var y = remaining.minY
                for i in row {
                    let h = CGFloat(areas[i]) / w
                    result[i] = CGRect(x: remaining.minX, y: y, width: w, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY,
                                   width: max(0, remaining.width - w), height: remaining.height)
            } else {
                let h = CGFloat(rowArea / Double(remaining.width))
                var x = remaining.minX
                for i in row {
                    let w = CGFloat(areas[i]) / h
                    result[i] = CGRect(x: x, y: remaining.minY, width: w, height: h)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h,
                                   width: remaining.width, height: max(0, remaining.height - h))
            }
            index = next
        }
        return result
    }

    private static func worst(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard let maxA = row.max(), let minA = row.min(), sum > 0, minA > 0 else { return .infinity }
        let s2 = side * side
        return max(s2 * maxA / (sum * sum), (sum * sum) / (s2 * minA))
    }
}
