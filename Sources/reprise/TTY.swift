// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  TTY.swift
//  reprise (terminal)
//
//  Raw mode, the alternate screen, key decoding and ANSI styling. The
//  terminal is always put back on exit, Ctrl-C and SIGTERM.
//

import Foundation

enum Key: Equatable {
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, escape, backspace, tab
    case char(Character)
}

enum TTY {
    // Styling. The accent is the coral of the app icon.
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let accent = "\u{1B}[38;2;255;112;110m"
    static let accentBG = "\u{1B}[48;2;255;112;110m\u{1B}[38;2;20;20;20m"
    static let pink = "\u{1B}[38;2;255;92;160m"
    static let clearLine = "\u{1B}[2K"

    private static var original: termios?
    private static var signalSources: [DispatchSourceSignal] = []

    static var size: (rows: Int, cols: Int) {
        var w = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_row > 0 else { return (24, 80) }
        return (Int(w.ws_row), Int(w.ws_col))
    }

    static func enter(onResize: @escaping @MainActor () -> Void, onQuit: @escaping @MainActor () -> Void) {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        original = raw
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        write("\u{1B}[?1049h\u{1B}[?25l")

        for (sig, handler) in [(SIGINT, onQuit), (SIGTERM, onQuit), (SIGWINCH, onResize)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { handler() } }
            source.resume()
            signalSources.append(source)
        }
    }

    static func restore() {
        guard var saved = original else { return }
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        original = nil
    }

    static func write(_ text: String) {
        var text = text
        text.withUTF8 { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    static func move(row: Int, col: Int = 1) -> String { "\u{1B}[\(row);\(col)H" }

    // MARK: - Keys

    /// Decodes one read's worth of bytes into keys. An escape sequence always
    /// arrives in a single read from a terminal; a lone ESC byte is Escape.
    static func decode(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B {
                if i + 2 < bytes.count, bytes[i + 1] == 0x5B || bytes[i + 1] == 0x4F {
                    let code = bytes[i + 2]
                    i += 3
                    switch code {
                    case 0x41: keys.append(.up)
                    case 0x42: keys.append(.down)
                    case 0x43: keys.append(.right)
                    case 0x44: keys.append(.left)
                    case 0x48: keys.append(.home)
                    case 0x46: keys.append(.end)
                    case 0x35, 0x36, 0x31, 0x34:
                        // ESC [ 5 ~ (page up), 6 ~ (page down), 1 ~ / 4 ~ (home / end)
                        if i < bytes.count, bytes[i] == 0x7E { i += 1 }
                        keys.append([0x35: Key.pageUp, 0x36: .pageDown, 0x31: .home, 0x34: .end][code]!)
                    default:
                        // Skip any other CSI sequence to its final byte.
                        while i < bytes.count, !(0x40...0x7E).contains(bytes[i]) { i += 1 }
                        i += 1
                    }
                } else {
                    keys.append(.escape)
                    i += 1
                }
                continue
            }
            switch b {
            case 0x0D, 0x0A: keys.append(.enter)
            case 0x7F, 0x08: keys.append(.backspace)
            case 0x09: keys.append(.tab)
            case 0x03: keys.append(.char("\u{03}"))
            default:
                // One UTF-8 scalar.
                let length = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
                let end = min(i + length, bytes.count)
                if let s = String(bytes: bytes[i..<end], encoding: .utf8), let c = s.first, !c.isASCII || c.isLetter
                    || c.isNumber || c.isPunctuation || c.isSymbol || c == " " {
                    keys.append(.char(c))
                }
                i = end
                continue
            }
            i += 1
        }
        return keys
    }
}

// MARK: - Text fitting

extension String {
    /// Clipped to `width` columns, with an ellipsis when cut.
    func fitted(_ width: Int) -> String {
        guard width > 0 else { return "" }
        if count <= width { return self }
        return String(prefix(max(0, width - 1))) + "…"
    }

    /// Clipped and padded to exactly `width` columns.
    func padded(_ width: Int) -> String {
        let f = fitted(width)
        return f + String(repeating: " ", count: max(0, width - f.count))
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "-:--" }
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}
