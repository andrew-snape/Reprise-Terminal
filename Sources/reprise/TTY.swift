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
        // Save the window title (xterm title stack) so quitting can put it back.
        write("\u{1B}[22;0t\u{1B}[?1049h\u{1B}[?25l")

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
        // An empty title first, for terminals without a title stack.
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l\u{1B}]2;\u{07}\u{1B}[23;0t")
        lastTitle = nil
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

    private static var lastTitle: String?

    /// Sets the terminal window's title, only when it changes. Control
    /// characters are dropped, so metadata can't inject escape sequences.
    static func setTitle(_ title: String) {
        let clean = title.printable
        guard clean != lastTitle else { return }
        lastTitle = clean
        write("\u{1B}]2;\(clean)\u{07}")
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
                if i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                    // CSI: parameters 0x30–0x3F, intermediates 0x20–0x2F, then a final
                    // byte 0x40–0x7E. Modifiers (ESC [ 1 ; 2 A) are read and dropped.
                    var j = i + 2
                    while j < bytes.count, (0x30...0x3F).contains(bytes[j]) { j += 1 }
                    let params = String(decoding: bytes[(i + 2)..<j], as: UTF8.self)
                    while j < bytes.count, (0x20...0x2F).contains(bytes[j]) { j += 1 }
                    // An unfinished sequence ends the read.
                    guard j < bytes.count, (0x40...0x7E).contains(bytes[j]) else { break }
                    let first = params.split(separator: ";").first.map(String.init) ?? ""
                    if let key = csiKey(final: bytes[j], first: first) { keys.append(key) }
                    i = j + 1
                } else if i + 2 < bytes.count, bytes[i + 1] == 0x4F {
                    // SS3: ESC O and one final byte.
                    if let key = csiKey(final: bytes[i + 2], first: "") { keys.append(key) }
                    i += 3
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

    private static func csiKey(final: UInt8, first: String) -> Key? {
        switch final {
        case 0x41: .up
        case 0x42: .down
        case 0x43: .right
        case 0x44: .left
        case 0x48: .home
        case 0x46: .end
        case 0x7E:
            switch first {
            case "1", "7": .home
            case "4", "8": .end
            case "5": .pageUp
            case "6": .pageDown
            default: nil
            }
        default: nil
        }
    }
}

// MARK: - Text fitting

extension Character {
    /// Terminal columns: 2 for East Asian wide and emoji, else 1.
    var columns: Int {
        guard let scalar = unicodeScalars.first else { return 0 }
        if scalar.properties.isEmojiPresentation || unicodeScalars.contains("\u{FE0F}") { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

extension String {
    /// Width in terminal columns, ignoring ANSI styling.
    var columns: Int {
        var total = 0
        var inEscape = false
        for c in self {
            if inEscape {
                if c.isLetter { inEscape = false }
            } else if c == "\u{1B}" {
                inEscape = true
            } else {
                total += c.columns
            }
        }
        return total
    }

    /// Without control characters (metadata is untrusted).
    var printable: String {
        String(unicodeScalars.filter { $0.properties.generalCategory != .control }.map(Character.init))
    }

    /// Clipped to `width` columns, with an ellipsis when cut. Plain text only.
    func fitted(_ width: Int) -> String {
        guard width > 0 else { return "" }
        let text = printable
        if text.columns <= width { return text }
        var out = ""
        var used = 0
        for c in text {
            if used + c.columns > width - 1 { break }
            out.append(c)
            used += c.columns
        }
        return out + "…"
    }

    /// Clipped and padded to exactly `width` columns.
    func padded(_ width: Int) -> String {
        let f = fitted(width)
        return f + String(repeating: " ", count: max(0, width - f.columns))
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "-:--" }
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}
