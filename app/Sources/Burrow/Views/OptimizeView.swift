import SwiftUI

@MainActor
final class OptimizeModel: ObservableObject {
    enum Phase: Equatable { case idle, running, done }

    @Published var phase: Phase = .idle
    @Published var tasks: [String] = []
    @Published var diagnosis: [String] = []
    @Published var job: CLIJob?
    @Published var loadingPreview = false
    private var loaded = false

    func loadPreview() {
        guard !loaded else { return }
        loaded = true
        loadingPreview = true
        Task {
            defer { loadingPreview = false }
            guard let result = try? await MoleCLI.run(["optimize", "--dry-run"]) else { return }
            var tasks: [String] = []
            var diagnosis: [String] = []
            var inDiagnosis = false
            for raw in ANSI.strip(result.output).components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line == "Performance diagnosis" { inDiagnosis = true; continue }
                if line.hasPrefix("➤ ") {
                    inDiagnosis = false
                    tasks.append(String(line.dropFirst(2)))
                    continue
                }
                if inDiagnosis, line.hasPrefix("◎ ") { diagnosis.append(String(line.dropFirst(2))) }
            }
            self.tasks = tasks
            self.diagnosis = diagnosis
        }
    }

    func run() {
        let job = CLIJob(title: "Optimize")
        job.onFinish = { [weak self] _ in self?.phase = .done }
        self.job = job
        phase = .running
        job.start(["optimize"])
    }

    func reset() {
        job = nil
        phase = .idle
    }

    /// Section headers and their result lines from the live transcript.
    func steps(from transcript: TerminalTranscript) -> [StepLine] {
        var steps: [StepLine] = []
        var started = false
        for (index, raw) in transcript.all.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("➤ ") {
                started = true
                steps.append(StepLine(id: index, text: String(line.dropFirst(2)), done: false, isHeader: true))
            } else if started, let first = line.first, ["○", "✓", "◎", "⊙", "✗"].contains(first) {
                steps.append(StepLine(id: index, text: String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces),
                                      done: first != "✗", isHeader: false))
            }
        }
        return steps
    }

    func progress(from transcript: TerminalTranscript) -> (Int, Int, String)? {
        let headers = transcript.all.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("➤ ") }
        guard let last = headers.last else { return nil }
        let total = max(tasks.count, headers.count)
        return (headers.count, total, String(last.dropFirst(2)))
    }
}

struct OptimizeView: View {
    @ObservedObject var model: OptimizeModel

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                ZStack(alignment: .bottom) {
                    HeroScreen(planet: .mercury, satellite: nil,
                               verse: ["Small knots untied, the gears run true.", "A lighter step, and nothing drags."],
                               buttonTitle: "Optimize",
                               footnote: model.tasks.isEmpty ? nil : "\(model.tasks.count) maintenance tasks") { model.run() }
                    if !model.diagnosis.isEmpty {
                        DiagnosisStrip(lines: model.diagnosis).padding(.bottom, 18)
                    }
                }
            case .running, .done:
                if let job = model.job {
                    OptimizeRunView(model: model, job: job)
                }
            }
        }
        .onAppear { model.loadPreview() }
    }
}

struct OptimizeRunView: View {
    @ObservedObject var model: OptimizeModel
    @ObservedObject var job: CLIJob

    var body: some View {
        VStack(spacing: 0) {
            let progress = model.progress(from: job.transcript)
            JobScreen(planet: .mercury,
                      title: job.isRunning ? "Running maintenance" : "Maintenance complete",
                      job: job,
                      progress: progress.map { (done: $0.0, total: $0.1, label: $0.2) },
                      steps: model.steps(from: job.transcript))
            if !job.isRunning {
                VStack(spacing: 12) {
                    if let code = job.exitCode, code != 0 {
                        Text("Some tasks did not finish (exit \(code)). Open the log for details.")
                            .font(.system(size: 12)).foregroundStyle(Color.warnAmber)
                    }
                    LogDisclosure(job: job)
                    Button("Done") { model.reset() }.buttonStyle(PrimaryPillStyle(width: 200))
                }
                .padding(.bottom, 30)
            }
        }
    }
}

struct DiagnosisStrip: View {
    var lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PERFORMANCE NOTES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            ForEach(lines.prefix(3), id: \.self) { line in
                Text(line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }
}
