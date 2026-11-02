import SwiftUI

/// Planet, two-line verse and one main action.
struct HeroScreen: View {
    var planet: PlanetKind
    var satellite: PlanetKind?
    var verse: [String]
    var buttonTitle: String
    var footnote: String?
    var action: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let satellite {
                    PlanetView(kind: satellite, spinSeconds: 60)
                        .frame(width: 52, height: 52)
                        .position(x: geo.size.width * 0.78, y: geo.size.height * 0.12)
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                    PlanetView(kind: planet)
                        .frame(width: 290, height: 290)
                    Spacer().frame(height: 70)
                    VStack(spacing: 6) {
                        ForEach(verse, id: \.self) { line in
                            Text(line).font(.verse(17)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    Spacer().frame(height: 26)
                    Button(buttonTitle, action: action)
                        .buttonStyle(PrimaryPillStyle())
                        .keyboardShortcut(.defaultAction)
                    if let footnote {
                        Text(footnote).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).padding(.top, 14)
                    }
                    Spacer(minLength: 30)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct WorkingScreen: View {
    var planet: PlanetKind
    var title: String
    var detail: String
    var cancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            PlanetView(kind: planet, spinSeconds: 18).frame(width: 290, height: 290)
            Spacer().frame(height: 60)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title).font(.system(size: 28, weight: .bold))
            }
            Text(detail)
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 520)
                .padding(.top, 8)
            if let cancel {
                Button("Cancel", action: cancel).buttonStyle(SubtleButtonStyle()).padding(.top, 22)
            }
            Spacer(minLength: 30)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Live view of a terminal-backed CLI run, with the password sheet and a
/// fallback when the CLI waits on a prompt the app does not recognize.
struct JobScreen: View {
    var planet: PlanetKind
    var title: String
    @ObservedObject var job: CLIJob
    var progress: (done: Int, total: Int, label: String)?
    var steps: [StepLine] = []

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            PlanetView(kind: planet, spinSeconds: 16).frame(width: 260, height: 260)
            Spacer().frame(height: 46)
            Text(job.isRunning ? "\(title)…" : title).font(.system(size: 30, weight: .bold))
            HStack(spacing: 8) {
                Circle().fill(Color.white.opacity(0.6)).frame(width: 7, height: 7)
                Text(progressText).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 560)
            .padding(.top, 8)

            Group {
                if steps.isEmpty {
                    LogTail(lines: job.transcript.all, maxLines: 7)
                } else {
                    StepList(steps: steps)
                }
            }
            .frame(width: 460)
            .padding(.top, 18)

            if let prompt = job.stalledPrompt {
                VStack(spacing: 8) {
                    Text("Mole is waiting for input:").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    Text(prompt).font(.mono(12)).multilineTextAlignment(.center)
                    HStack {
                        Button("Continue (Enter)") { job.sendKeys("\r") }
                        Button("Skip (Space)") { job.sendKeys(" ") }
                        Button("Cancel") { job.cancel() }
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                .padding(.top, 14)
            }

            if job.isRunning {
                Button("Stop") { job.cancel() }.buttonStyle(SubtleButtonStyle()).padding(.top, 18)
            }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: Binding(get: { job.passwordRequest != nil },
                                    set: { if !$0 && job.passwordRequest != nil { job.cancelPassword() } })) {
            PasswordSheet(job: job)
        }
    }

    private var progressText: String {
        if let progress { return "\(progress.label) · \(progress.done) / \(progress.total)" }
        let last = job.transcript.all.reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return last?.trimmingCharacters(in: .whitespaces) ?? "Starting…"
    }
}

struct StepLine: Identifiable, Hashable {
    let id: Int
    let text: String
    let done: Bool
    let isHeader: Bool
}

struct StepList: View {
    var steps: [StepLine]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(steps) { step in
                        HStack(spacing: 8) {
                            if step.isHeader {
                                Circle().fill(Color.white.opacity(0.5)).frame(width: 7, height: 7).frame(width: 12)
                            } else {
                                Image(systemName: step.done ? "checkmark" : "circle.dotted")
                                    .font(.system(size: 10, weight: .bold)).frame(width: 12)
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                            Text(step.text).font(.mono(12)).foregroundStyle(.white.opacity(step.isHeader ? 0.65 : 0.85))
                                .lineLimit(1)
                        }
                        .id(step.id)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06)))
            .onChange(of: steps.count) { _, _ in
                if let last = steps.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

struct LogTail: View {
    var lines: [String]
    var maxLines: Int

    var body: some View {
        let visible = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(maxLines)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                Text(line.trimmingCharacters(in: .whitespaces))
                    .font(.mono(12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06)))
    }
}

struct LogDisclosure: View {
    @ObservedObject var job: CLIJob
    @State private var open = false

    var body: some View {
        VStack(spacing: 8) {
            Button(open ? "Hide log" : "Show log") { withAnimation { open.toggle() } }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            if open {
                ScrollView {
                    Text(job.transcript.all.joined(separator: "\n"))
                        .font(.mono(11)).foregroundStyle(.white.opacity(0.75))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxWidth: 720, maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
            }
        }
    }
}

struct PasswordSheet: View {
    @ObservedObject var job: CLIJob
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 26)).foregroundStyle(Color.warnAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Administrator password").font(.headline)
                    Text(job.passwordRequest ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if job.passwordRejected {
                Text("That password was not accepted. Try again.").font(.system(size: 12)).foregroundStyle(Color.dangerRed)
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Text("The password goes only to the Mole CLI's sudo prompt. Burrow never stores it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Skip") { job.cancelPassword() }
                Button("Continue", action: submit).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        job.submitPassword(password)
        password = ""
    }
}

struct FailureScreen: View {
    var planet: PlanetKind
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            PlanetView(kind: planet).frame(width: 200, height: 200).opacity(0.6)
            Text("Something went wrong").font(.system(size: 24, weight: .bold))
            Text(message).font(.mono(12)).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).frame(maxWidth: 560).textSelection(.enabled)
            Button("Back", action: retry).buttonStyle(PrimaryPillStyle(width: 180))
            Spacer()
        }
    }
}
