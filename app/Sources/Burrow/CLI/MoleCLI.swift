import Foundation

/// Locates the bundled Mole CLI and runs it as a child process.
///
/// The app never reimplements cleanup logic: every scan and removal goes
/// through the same `mole` entry script the terminal uses.
enum MoleCLI {
    struct Result {
        let output: String
        let errorOutput: String
        let status: Int32
        var succeeded: Bool { status == 0 }
    }

    enum CLIError: LocalizedError {
        case notFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "The bundled Mole CLI could not be found inside the app."
            case .failed(let message):
                return message
            }
        }
    }

    /// `Contents/Resources/mole/mole` in the app bundle. During development the
    /// `BURROW_MOLE_PATH` environment variable or a checkout next to the build
    /// directory is used instead.
    static let executableURL: URL? = {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["BURROW_MOLE_PATH"],
           fm.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("mole/mole"),
           fm.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        var dir = Bundle.main.bundleURL
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("mole")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue,
               fm.isExecutableFile(atPath: candidate.path),
               fm.fileExists(atPath: dir.appendingPathComponent("lib/core/base.sh").path) {
                return candidate
            }
        }
        return nil
    }()

    /// Root directory of the bundled CLI (contains `lib/` and `bin/`).
    static var rootURL: URL? { executableURL?.deletingLastPathComponent() }

    /// GUI apps start with a minimal PATH. Mole shells out to brew, npm, go and
    /// friends for developer cleanups, so give it the usual locations.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let preferred = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/go/bin",
            NSHomeDirectory() + "/.cargo/bin",
        ]
        var seen = Set<String>()
        var parts: [String] = []
        for entry in preferred + (env["PATH"] ?? "").split(separator: ":").map(String.init)
        where !entry.isEmpty && !seen.contains(entry) {
            seen.insert(entry)
            parts.append(entry)
        }
        env["PATH"] = parts.joined(separator: ":")
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        env["HOME"] = NSHomeDirectory()
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = "160"
        return env
    }()

    // MARK: - One-shot runs

    /// Runs `mole <args>` with pipes (no terminal). Suitable for every
    /// read-only surface: `--json`, `--list`, `--dry-run`.
    static func run(_ args: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        guard let exe = executableURL else { throw CLIError.notFound }
        return try await runExecutable(exe, args, onLine: onLine)
    }

    static func runExecutable(_ exe: URL, _ args: [String],
                              onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector(onLine: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendOut(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendErr(data) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                process.terminationHandler = { proc in
                    // Drain whatever is left in the pipes.
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let restOut = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil
                    let restErr = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil
                    if let restOut { collector.appendOut(restOut) }
                    if let restErr { collector.appendErr(restErr) }
                    collector.flush()
                    cont.resume(returning: Result(output: collector.outString,
                                                  errorOutput: collector.errString,
                                                  status: proc.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Streaming

    /// Streams stdout lines of a long-running command (e.g. `status --watch`).
    /// Cancelling the consuming task terminates the process.
    static func stream(_ args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let exe = executableURL else {
                continuation.finish(throwing: CLIError.notFound)
                return
            }
            let process = Process()
            process.executableURL = exe
            process.arguments = args
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                for line in buffer.append(data) { continuation.yield(line) }
            }
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let last = buffer.flush() { continuation.yield(last) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do { try process.run() } catch { continuation.finish(throwing: error) }
        }
    }

    // MARK: - Helpers

    static func version() async -> String? {
        guard let result = try? await run(["--version"]) else { return nil }
        let first = result.output.split(separator: "\n").first.map(String.init) ?? ""
        return first.replacingOccurrences(of: "Mole version ", with: "")
    }
}

/// Thread-safe accumulator for process output.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private let lineBuffer = LineBuffer()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ data: Data) {
        lock.lock()
        out.append(data)
        lock.unlock()
        if let onLine {
            for line in lineBuffer.append(data) { onLine(ANSI.strip(line)) }
        }
    }

    func appendErr(_ data: Data) {
        lock.lock()
        err.append(data)
        lock.unlock()
        if let onLine {
            for line in lineBuffer.append(data) { onLine(ANSI.strip(line)) }
        }
    }

    func flush() {
        if let onLine, let last = lineBuffer.flush() { onLine(ANSI.strip(last)) }
    }

    var outString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var errString: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}

/// Splits a byte stream into newline-terminated lines.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let idx = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<idx]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...idx)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return line
    }
}
