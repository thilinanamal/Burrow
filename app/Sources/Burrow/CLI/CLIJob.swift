import Foundation
import SwiftUI

/// A CLI run inside a pseudo-terminal, with prompt handling.
///
/// Responders answer the CLI's own prompts (confirmation, sudo choice) after
/// the user has already confirmed in the GUI. Password prompts are surfaced as
/// a native sheet; the password is only ever written to the CLI's terminal.
@MainActor
final class CLIJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case running
        case finished(Int32)
        case failed(String)
    }

    enum Action {
        case send(String)
        case askPassword(reason: String)
    }

    struct Responder {
        let name: String
        let matches: (String) -> Bool
        let action: () -> Action
        var once = true
        var delay: TimeInterval = 0.6
    }

    let id = UUID()
    let title: String
    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = TerminalTranscript()
    @Published var passwordRequest: String?
    @Published var passwordRejected = false
    @Published var stalledPrompt: String?

    private let session = PTYSession()
    private var responders: [Responder] = []
    private var firedResponders = Set<String>()
    private var handledPromptKeys = Set<String>()
    private var passwordAttempts = 0
    private var stallTimer: Timer?
    private var lastOutputAt = Date()
    var onFinish: ((Int32) -> Void)?

    init(title: String) { self.title = title }

    var isRunning: Bool { state == .running }

    var exitCode: Int32? {
        if case .finished(let code) = state { return code }
        return nil
    }

    func start(_ args: [String], responders: [Responder] = []) {
        guard let exe = MoleCLI.executableURL else {
            state = .failed(MoleCLI.CLIError.notFound.localizedDescription)
            return
        }
        start(executable: exe, args, responders: responders)
    }

    func start(executable: URL, _ args: [String], responders: [Responder] = []) {
        self.responders = responders
        session.onOutput = { [weak self] chunk in self?.handle(chunk) }
        session.onExit = { [weak self] code in self?.finish(code) }
        do {
            try session.start(executable: executable, arguments: args, environment: MoleCLI.environment)
            state = .running
            lastOutputAt = Date()
            stallTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkStall() }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func handle(_ chunk: String) {
        transcript.feed(chunk)
        lastOutputAt = Date()
        stalledPrompt = nil
        let tail = transcript.tail
        let currentLine = transcript.current

        // sudo's native prompt, or a retry after a wrong password.
        if currentLine.range(of: #"(?i)password[^:]*:\s*$"#, options: .regularExpression) != nil {
            let key = "pw-\(transcript.lines.count)-\(currentLine)"
            if !handledPromptKeys.contains(key) {
                handledPromptKeys.insert(key)
                if tail.localizedCaseInsensitiveContains("Sorry, try again") { passwordRejected = true }
                askForPassword(reason: "Administrator access is required to continue.")
            }
            return
        }

        for responder in responders where !(responder.once && firedResponders.contains(responder.name)) {
            guard responder.matches(tail) else { continue }
            firedResponders.insert(responder.name)
            let action = responder.action()
            switch action {
            case .send(let text):
                DispatchQueue.main.asyncAfter(deadline: .now() + responder.delay) { [weak self] in
                    self?.session.send(text)
                }
            case .askPassword(let reason):
                askForPassword(reason: reason)
            }
        }
    }

    private func askForPassword(reason: String) {
        passwordAttempts += 1
        if passwordAttempts > 3 {
            session.send("\u{03}")
            return
        }
        passwordRequest = reason
    }

    func submitPassword(_ password: String) {
        passwordRequest = nil
        session.send(password + "\n")
    }

    /// Declining a password: Ctrl-C to sudo, which Mole treats as failed
    /// authentication and continues at user level where it can.
    func cancelPassword() {
        passwordRequest = nil
        session.send("\u{03}")
    }

    func sendKeys(_ text: String) {
        stalledPrompt = nil
        session.send(text)
    }

    func cancel() {
        session.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isRunning else { return }
            self.session.terminate()
        }
    }

    private func checkStall() {
        guard isRunning, passwordRequest == nil else { return }
        let line = transcript.current.trimmingCharacters(in: .whitespaces)
        if Date().timeIntervalSince(lastOutputAt) > 20, !line.isEmpty,
           line.hasSuffix(":") || line.contains("Enter") || line.contains("[y/N]") {
            stalledPrompt = line
        }
    }

    private func finish(_ code: Int32) {
        stallTimer?.invalidate()
        stallTimer = nil
        passwordRequest = nil
        stalledPrompt = nil
        state = .finished(code)
        onFinish?(code)
    }
}
