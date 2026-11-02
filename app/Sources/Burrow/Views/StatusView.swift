import AppKit
import SwiftUI

@MainActor
final class StatusModel: ObservableObject {
    @Published var snapshot: StatusSnapshot?
    @Published var cpuHistory: [Double] = []
    @Published var memHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    @Published var rxHistory: [Double] = []
    @Published var error: String?
    private var task: Task<Void, Never>?
    private let historyLength = 60

    func start() {
        guard task == nil else { return }
        error = nil
        task = Task {
            do {
                for try await line in MoleCLI.stream(["status", "--watch", "--interval", "2s"]) {
                    guard let start = line.firstIndex(of: "{"),
                          let snap = StatusSnapshot.decode(Data(line[start...].utf8)) else { continue }
                    apply(snap)
                }
            } catch {
                self.error = error.localizedDescription
            }
            task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ snap: StatusSnapshot) {
        snapshot = snap
        push(&cpuHistory, snap.cpu?.usage ?? 0)
        push(&memHistory, snap.memory?.usedPercent ?? 0)
        if let usage = snap.gpu?.first?.usage, usage >= 0 { push(&gpuHistory, usage) }
        let rx = snap.network?.reduce(0) { $0 + ($1.rxRateMbs ?? 0) } ?? 0
        push(&rxHistory, rx)
    }

    private func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > historyLength { array.removeFirst(array.count - historyLength) }
    }
}

struct StatusView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Group {
            if let s = model.snapshot {
                VStack(spacing: 12) {
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            HealthCard(s: s)
                            CPUCard(s: s, history: model.cpuHistory)
                            GPUCard(s: s, history: model.gpuHistory)
                            MemoryCard(s: s, history: model.memHistory)
                        }
                        GridRow {
                            BatteryCard(s: s)
                            DiskCard(s: s)
                            NetworkCard(s: s, history: model.rxHistory)
                            ThermalCard(s: s)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    ProcessTable(processes: s.topProcesses ?? [], total: s.procs)
                        .frame(height: CGFloat(min(max(s.topProcesses?.count ?? 0, 3), 10)) * 35 + 46)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            } else {
                VStack(spacing: 14) {
                    PlanetView(kind: .sun).frame(width: 180, height: 180)
                    if let error = model.error {
                        Text(error).foregroundStyle(Color.warnAmber)
                        Button("Retry") { model.start() }.buttonStyle(SubtleButtonStyle())
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Reading system health…").foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - Cards

private let tab = AppTab.status

private struct CardHeader: View {
    var icon: String
    var title: String
    var chip: String?
    var chipTint: Color = .white
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(.white.opacity(0.7))
            Spacer()
            if let chip { Chip(text: chip, tint: chipTint) }
        }
    }
}

private struct BigValue: View {
    var value: String
    var unit: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 34, weight: .bold))
            Text(unit).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

struct HealthCard: View {
    var s: StatusSnapshot
    var body: some View {
        Card(tab: tab) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sun.max").font(.system(size: 11)).foregroundStyle(Color.goodGreen)
                    Text("HEALTH").font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Color.goodGreen)
                    Spacer()
                    if let cpu = s.hardware?.cpuModel { Chip(text: cpu.replacingOccurrences(of: "Apple ", with: "")) }
                    if let ram = s.hardware?.totalRam { Chip(text: ram.replacingOccurrences(of: ".0 ", with: " ")) }
                }
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(Int(s.healthScore ?? 0))").font(.system(size: 34, weight: .bold))
                            Text(s.healthScoreMsg ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        }
                        Text(healthNote).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                    }
                    Spacer()
                    PlanetView(kind: .sun, spinSeconds: 40).frame(width: 80, height: 80)
                }
                Spacer(minLength: 0)
                Text(["up \(s.uptime ?? "—")", s.hardware?.osVersion].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var healthNote: String {
        if let pressure = s.memory?.pressure, !pressure.isEmpty, pressure != "normal" { return "Memory pressure \(pressure)" }
        if (s.memory?.usedPercent ?? 0) > 85 { return "Memory is nearly full" }
        if (s.rootDisk?.usedPercent ?? 0) > 90 { return "Disk is nearly full" }
        if (s.cpu?.usage ?? 0) > 80 { return "CPU is busy" }
        return "Running smoothly"
    }
}

struct CPUCard: View {
    var s: StatusSnapshot
    var history: [Double]
    var body: some View {
        Card(tab: tab) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "cpu", title: "CPU",
                           chip: (s.thermal?.cpuTemp ?? 0) > 0 ? String(format: "%.0f°C", s.thermal!.cpuTemp!) : nil)
                BigValue(value: Format.percent(s.cpu?.usage ?? 0), unit: "%")
                CoreBars(values: s.cpu?.perCore ?? [])
                Spacer(minLength: 0)
                Text("\(label) · \(s.cpu?.logicalCpu ?? s.cpu?.coreCount ?? 0) cores · Load avg \(String(format: "%.1f", s.cpu?.load1 ?? 0))")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
    }
    private var label: String { (s.cpu?.usage ?? 0) < 25 ? "idle" : ((s.cpu?.usage ?? 0) < 70 ? "active" : "busy") }
}

struct CoreBars: View {
    var values: [Double]
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.goodGreen.opacity(0.55 + min(v, 100) / 250))
                        .frame(height: max(3, geo.size.height * min(v, 100) / 100))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 40)
    }
}

struct GPUCard: View {
    var s: StatusSnapshot
    var history: [Double]
    var body: some View {
        let usage = s.gpu?.first?.usage ?? -1
        Card(tab: tab) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "square.stack.3d.up", title: "GPU",
                           chip: (s.thermal?.gpuTemp ?? 0) > 0 ? String(format: "%.0f°C", s.thermal!.gpuTemp!) : nil)
                BigValue(value: usage >= 0 ? Format.percent(usage) : "—", unit: usage >= 0 ? "%" : "")
                Sparkline(values: history, color: Color(hex: 0xE3A766), maxValue: 100).frame(height: 40)
                Spacer(minLength: 0)
                Text([s.gpu?.first?.name, s.gpu?.first?.coreCount.map { "\($0) cores" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
    }
}

struct MemoryCard: View {
    var s: StatusSnapshot
    var history: [Double]
    var body: some View {
        let m = s.memory
        let pressure = (m?.pressure?.isEmpty ?? true) ? nil : m?.pressure
        Card(tab: tab) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "memorychip", title: "Memory",
                           chip: pressure.map { "Pressure \($0)" } ?? ((m?.usedPercent ?? 0) > 80 ? "Pressure high" : nil),
                           chipTint: Color.warnAmber)
                BigValue(value: Format.percent(m?.usedPercent ?? 0), unit: "%")
                Sparkline(values: history, color: Color(hex: 0xE8D7A0), maxValue: 100, filled: true).frame(height: 40)
                Spacer(minLength: 0)
                Text("\(Format.bytes(Int64(m?.used ?? 0))) · \(Format.bytes(Int64(m?.swapUsed ?? 0))) swap")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

struct BatteryCard: View {
    var s: StatusSnapshot
    var body: some View {
        let b = s.batteries?.first
        Card(tab: tab) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "battery.75percent", title: "Battery",
                           chip: b?.capacity.map { "\(Int($0))% Health" })
                if let b {
                    HStack {
                        BigValue(value: "\(Int(b.percent ?? 0))", unit: "%")
                        Spacer()
                        Ring(value: (b.percent ?? 0) / 100).frame(width: 40, height: 40)
                    }
                    Text(statusText(b)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 0)
                    Text(["\(b.cycleCount ?? 0) cycles", b.health].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                } else {
                    BigValue(value: "—", unit: "")
                    Text("No battery").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private func statusText(_ b: StatusSnapshot.Battery) -> String {
        let status = b.status?.lowercased() ?? ""
        if status.hasPrefix("ac") || status.contains("not charging") { return "Plugged in, not charging" }
        switch status {
        case "charging": return "Charging"
        case "charged", "full": return "Plugged in, charged"
        case "discharging": return b.timeLeft.map { "On battery · \($0) left" } ?? "On battery"
        case "not charging", "ac attached": return "Plugged in, not charging"
        default: return b.status?.capitalized ?? ""
        }
    }
}

struct DiskCard: View {
    var s: StatusSnapshot
    var body: some View {
        let d = s.rootDisk
        let free = max(0, (d?.total ?? 0) - (d?.used ?? 0))
        Card(tab: tab) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "internaldrive", title: "Free Space",
                           chip: d?.total.map { "\(Format.gigabytes($0)) GB" })
                BigValue(value: Format.gigabytes(free), unit: "GB")
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(LinearGradient(colors: [Color(hex: 0x5B7BB8), Color(hex: 0xE3A766)],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * (d?.usedPercent ?? 0) / 100)
                    }
                }
                .frame(height: 8)
                Spacer(minLength: 0)
                Text("\(Format.gigabytes(d?.used ?? 0)) GB used · \(Format.percent(d?.usedPercent ?? 0))%")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

struct NetworkCard: View {
    var s: StatusSnapshot
    var history: [Double]
    var body: some View {
        let rx = s.network?.reduce(0) { $0 + ($1.rxRateMbs ?? 0) } ?? 0
        let tx = s.network?.reduce(0) { $0 + ($1.txRateMbs ?? 0) } ?? 0
        Card(tab: tab) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "globe", title: "Network", chip: s.network?.first?.name)
                let (value, unit) = rate(rx)
                BigValue(value: value, unit: unit)
                Sparkline(values: history, color: Color(hex: 0x7FA8E8), maxValue: nil).frame(height: 40)
                Spacer(minLength: 0)
                HStack {
                    let (tv, tu) = rate(tx)
                    Text("Upload \(tv) \(tu)")
                    Spacer()
                    if let ip = s.network?.first?.ip { Text(ip) }
                }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func rate(_ mbs: Double) -> (String, String) {
        let kbs = mbs * 1024
        if kbs < 1 { return ("<1", "KB/s") }
        if kbs < 1024 { return (String(format: "%.0f", kbs), "KB/s") }
        return (String(format: "%.1f", mbs), "MB/s")
    }
}

struct ThermalCard: View {
    var s: StatusSnapshot
    var body: some View {
        let t = s.thermal
        Card(tab: tab) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "fan", title: "Fan & Power",
                           chip: (t?.fanCount ?? 0) > 0 ? "\(t!.fanCount!) fan" : "Fanless")
                BigValue(value: "\(Int(t?.fanSpeed ?? 0))", unit: "RPM")
                VStack(alignment: .leading, spacing: 3) {
                    if let bt = t?.batteryTemp, bt > 0 { Text(String(format: "Battery %.0f°C", bt)) }
                    if let p = t?.systemPower, p > 0 { Text(String(format: "System %.1f W", p)) }
                    else if let p = t?.batteryPower, p != 0 { Text(String(format: "Battery %.1f W", p)) }
                }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                Text("Managed by macOS").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

struct Ring: View {
    var value: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
            Circle().trim(from: 0, to: max(0, min(1, value)))
                .stroke(Color.goodGreen, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var maxValue: Double?
    var filled = false

    var body: some View {
        GeometryReader { geo in
            let maxV = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let count = max(values.count, 2)
            let step = geo.size.width / CGFloat(count - 1)
            let points: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step,
                        y: geo.size.height * (1 - CGFloat(min(v, maxV) / maxV)))
            }
            ZStack {
                if filled, points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Processes

struct ProcessTable: View {
    var processes: [StatusSnapshot.Process]
    var total: Int?
    @State private var confirmKill: StatusSnapshot.Process?

    var body: some View {
        let sorted = processes.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
        VStack(spacing: 0) {
            HStack {
                Text("NAME (\(total ?? processes.count))").frame(maxWidth: .infinity, alignment: .leading)
                Text("MEM").frame(width: 90, alignment: .trailing)
                Text("% CPU").frame(width: 150, alignment: .trailing)
                Text("PID").frame(width: 80, alignment: .trailing)
                Spacer().frame(width: 40)
            }
            .font(.system(size: 11, weight: .semibold)).kerning(0.5).foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 18).padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sorted) { proc in
                        ProcessRow(proc: proc) { confirmKill = proc }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(tab.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.07)))
        .alert("Quit \(confirmKill?.name ?? "process")?", isPresented: Binding(get: { confirmKill != nil }, set: { if !$0 { confirmKill = nil } })) {
            Button("Quit", role: .destructive) {
                if let p = confirmKill { terminate(p.pid, force: false) }
                confirmKill = nil
            }
            Button("Force Quit", role: .destructive) {
                if let p = confirmKill { terminate(p.pid, force: true) }
                confirmKill = nil
            }
            Button("Cancel", role: .cancel) { confirmKill = nil }
        } message: {
            Text("Unsaved work in this process may be lost.")
        }
    }

    private func terminate(_ pid: Int32, force: Bool) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(pid, force ? SIGKILL : SIGTERM)
        }
    }
}

struct ProcessRow: View {
    var proc: StatusSnapshot.Process
    var onQuit: () -> Void
    @State private var hover = false

    var body: some View {
        let app = NSRunningApplication(processIdentifier: proc.pid)
        HStack {
            HStack(spacing: 10) {
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "gearshape").frame(width: 18, height: 18).foregroundStyle(.white.opacity(0.5))
                }
                Text(app?.localizedName ?? proc.name ?? "pid \(proc.pid)").font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.bytes(Int64(proc.memoryBytes ?? 0))).font(.system(size: 13)).frame(width: 90, alignment: .trailing)
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(Color.white.opacity(0.55)).frame(width: geo.size.width * min(1, (proc.cpu ?? 0) / 100))
                    }
                }
                .frame(width: 50, height: 5)
                Text(String(format: "%.1f", proc.cpu ?? 0)).font(.system(size: 13)).frame(width: 44, alignment: .trailing)
            }
            .frame(width: 150, alignment: .trailing)
            Text("\(proc.pid)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).frame(width: 80, alignment: .trailing)
            Menu {
                Button("Quit…", action: onQuit)
                if let url = app?.bundleURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Copy PID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(proc.pid)", forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 40)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(hover ? Color.white.opacity(0.04) : Color.clear)
        .onHover { hover = $0 }
    }
}
