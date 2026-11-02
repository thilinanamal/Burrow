import Foundation

enum ANSI {
    /// Removes CSI / OSC escape sequences and stray control bytes (except tab).
    static func strip(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard let next = iterator.next() else { break }
                if next == "[" {
                    // CSI: parameters then a final byte in 0x40...0x7E
                    while let c = iterator.next() {
                        if (0x40...0x7E).contains(c.value) { break }
                    }
                } else if next == "]" {
                    // OSC: terminated by BEL or ESC \
                    while let c = iterator.next() {
                        if c == "\u{07}" { break }
                        if c == "\u{1B}" { _ = iterator.next(); break }
                    }
                } else if next == "(" || next == ")" {
                    _ = iterator.next()
                }
                continue
            }
            if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
            if scalar.value == 0x7F { continue }
            result.append(scalar)
        }
        return String(result)
    }
}

/// Turns a raw terminal byte stream into log lines. Carriage returns without a
/// newline (spinners, progress) overwrite the current line instead of
/// appending, so the log stays readable.
struct TerminalTranscript {
    private(set) var lines: [String] = []
    private(set) var current: String = ""
    private var pendingCR = false

    mutating func feed(_ rawChunk: String) {
        // Erase-line sequences mean "start this line over".
        let chunk = rawChunk
            .replacingOccurrences(of: "\u{1B}[2K", with: "\r")
            .replacingOccurrences(of: "\u{1B}[K", with: "")
        let clean = ANSI.strip(chunk)
        for ch in clean {
            switch ch {
            case "\r\n", "\n":
                if !Self.isSpinnerFrame(current) { lines.append(current) }
                current = ""
                pendingCR = false
            case "\r":
                pendingCR = true
            default:
                if pendingCR {
                    current = ""
                    pendingCR = false
                }
                current.append(ch)
            }
        }
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
    }

    /// Braille spinner frames ("⠖ Scanning…") are progress noise once done.
    static func isSpinnerFrame(_ line: String) -> Bool {
        guard let first = line.trimmingCharacters(in: .whitespaces).unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(first.value)
    }

    var all: [String] { current.isEmpty ? lines : lines + [current] }

    /// Recent visible text for prompt detection.
    var tail: String {
        (lines.suffix(3) + [current]).joined(separator: "\n")
    }
}
