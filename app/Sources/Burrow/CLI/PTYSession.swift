import Darwin
import Foundation

/// Runs the Mole CLI inside a pseudo-terminal.
///
/// Mole only accepts confirmations and sudo passwords from a real terminal
/// (`[[ -t 0 ]]`). The GUI's Remove / Clean / Optimize buttons are that
/// confirmation, so the app gives the CLI a terminal and answers its prompts
/// on the user's behalf after the user has reviewed the plan in the window.
final class PTYSession: @unchecked Sendable {
    private var masterFD: Int32 = -1
    private(set) var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "burrow.pty")

    /// Raw output chunks (still containing escape sequences), on the main queue.
    var onOutput: ((String) -> Void)?
    /// Exit status, on the main queue.
    var onExit: ((Int32) -> Void)?

    deinit { terminate() }

    func start(executable: URL, arguments: [String], environment: [String: String]) throws {
        let path = executable.path
        let argv: [String] = [path] + arguments
        let envList = environment.map { "\($0.key)=\($0.value)" }

        // Allocate every C string before fork: the child may only exec.
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = envList.map { strdup($0) } + [nil]
        let cPath = strdup(path)
        let cHome = strdup(NSHomeDirectory())
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cPath)
            free(cHome)
        }

        var master: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&master, nil, nil, &size)
        if child < 0 {
            throw MoleCLI.CLIError.failed("Could not open a terminal for the CLI (errno \(errno)).")
        }
        if child == 0 {
            _ = chdir(cHome)
            cArgs.withUnsafeBufferPointer { argsPtr in
                cEnv.withUnsafeBufferPointer { envPtr in
                    _ = execve(cPath,
                               UnsafeMutablePointer(mutating: argsPtr.baseAddress!),
                               UnsafeMutablePointer(mutating: envPtr.baseAddress!))
                }
            }
            _exit(127)
        }

        masterFD = master
        pid = child

        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        readSource = source

        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.handleExit() }
        exit.resume()
        exitSource = exit
    }

    private func drain() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        var collected = Data()
        while true {
            let n = read(masterFD, &buffer, buffer.count)
            if n > 0 {
                collected.append(buffer, count: n)
            } else {
                break
            }
        }
        guard !collected.isEmpty else { return }
        let text = String(decoding: collected, as: UTF8.self)
        DispatchQueue.main.async { [weak self] in self?.onOutput?(text) }
    }

    private func handleExit() {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // Give the last bytes a moment to arrive.
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.drain()
            self.readSource?.cancel()
            self.readSource = nil
            self.exitSource?.cancel()
            self.exitSource = nil
            if self.masterFD >= 0 { close(self.masterFD) }
            self.masterFD = -1
            let code: Int32
            if (status & 0x7F) == 0 {
                code = (status >> 8) & 0xFF
            } else {
                code = 128 + (status & 0x7F)
            }
            self.pid = 0
            DispatchQueue.main.async { self.onExit?(code) }
        }
    }

    /// Sends keystrokes to the CLI as if typed in a terminal.
    func send(_ text: String) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { ptr in
                _ = write(self.masterFD, ptr.baseAddress, ptr.count)
            }
        }
    }

    func interrupt() {
        if pid > 0 { kill(pid, SIGINT) }
    }

    func terminate() {
        if pid > 0 { kill(pid, SIGTERM) }
    }

    var isRunning: Bool { pid > 0 }
}
