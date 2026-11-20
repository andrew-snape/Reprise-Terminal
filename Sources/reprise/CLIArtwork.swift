// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLIArtwork.swift
//  reprise (terminal)
//
//  The playing track's cover: fetched once per album through Plex's photo
//  transcoder (600 px), handed to Control Centre's Now Playing, and drawn on
//  the Now Playing screen as Matrix-style text: katakana and digits in shades
//  of coral, with drops of light falling down it while music plays.
//

import AppKit
import CoreGraphics
import ImageIO
import MediaPlayer

final class CLIArtwork {
    /// The cover path wanted (the playing track's), fetched or not.
    private(set) var key: String?
    private var image: CGImage?
    /// The cover for Control Centre, once fetched.
    private(set) var mediaArtwork: MPMediaItemArtwork?
    /// Bumped whenever the cover changes, so Now Playing republishes.
    private(set) var version = 0
    var onChange: (() -> Void)?

    var isLoaded: Bool { image != nil }

    /// A track's cover: its own thumb is its album's.
    static func thumb(of track: PlexMetadata) -> String? {
        track.thumb ?? track.parentThumb ?? track.grandparentThumb
    }

    /// Call often: fetches the cover for the track when it changes.
    func want(_ track: PlexMetadata?, connection: CLIConnection) {
        let thumb = track.flatMap(Self.thumb)
        guard thumb != key else { return }
        key = thumb
        image = nil
        mediaArtwork = nil
        levels = nil
        version += 1
        guard let thumb,
              let url = PlexNetworkManager.shared.buildThumbnailURL(
                serverURL: connection.serverURL, authToken: connection.token,
                thumbPath: thumb, width: 600, height: 600) else { return }
        Task {
            let image = await Self.fetch(url)
            guard key == thumb, let image else { return }  // A failed cover stays a placeholder.
            self.image = image
            mediaArtwork = Self.artwork(image)
            levels = nil
            version += 1
            onChange?()
        }
    }

    /// The cover's brightness, one value (0...1, contrast stretched) a cell.
    private var levels: (cols: Int, rows: Int, values: [Float])?

    /// Katakana (half width, one column each) and digits, as on the Matrix's screens.
    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789Z:=*+<>¦")
    private static let faint = Array(".·:")

    /// The cover as `rows` lines of `cols` characters, Matrix style: dark areas
    /// empty, the rest glyphs whose coral brightness follows the picture. With
    /// `frame`, glyphs flicker and drops of light fall down the columns.
    func lines(cols: Int, rows: Int, frame: Int?) -> [String]? {
        guard let values = brightness(cols: cols, rows: rows) else { return nil }
        let animate = frame != nil
        let frame = frame ?? 0
        var lines: [String] = []
        lines.reserveCapacity(rows)
        let cycle = rows + 14
        for y in 0..<rows {
            var line = ""
            var lastShade = -1
            for x in 0..<cols {
                let seed = Self.hash(x, y)
                var level = values[y * cols + x]
                var head = false
                if animate {
                    // Each column has its own drop: speed, start and trail.
                    let columnSeed = Self.hash(x, 7919)
                    let speed = 0.35 + Double(columnSeed % 100) / 100 * 0.9
                    let trail = 4 + Double(columnSeed % 7)
                    let position = (Double(columnSeed % UInt64(cycle)) + Double(frame) * speed)
                        .truncatingRemainder(dividingBy: Double(cycle))
                    let behind = position - Double(y)
                    if behind >= 0, behind < 1 { head = true }
                    if behind >= 0, behind < trail { level += Float(0.45 * (1 - behind / trail)) }
                }
                level = min(1, level)
                let character: Character
                if head, level > 0.2 {
                    character = Self.glyphs[Int((seed &+ UInt64(frame)) % UInt64(Self.glyphs.count))]
                } else if level < 0.13 {
                    character = " "
                } else if level < 0.26 {
                    character = Self.faint[Int(seed % UInt64(Self.faint.count))]
                } else {
                    // A few glyphs change each frame, the rest hold.
                    let flicker = animate && (seed &+ UInt64(frame)) % 23 == 0 ? UInt64(frame) : 0
                    character = Self.glyphs[Int((seed &+ flicker) % UInt64(Self.glyphs.count))]
                }
                let shade = head ? 16 : min(15, Int(level * 15.99))
                if character != " ", shade != lastShade {
                    line += Self.shades[shade]
                    lastShade = shade
                }
                line.append(character)
            }
            lines.append(line + TTY.reset)
        }
        return lines
    }

    /// Dark coral to the accent to near white, in 16 steps; the 17th lights a drop's head.
    private static let shades: [String] = {
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> String {
            let r = Int(a.0 + (b.0 - a.0) * t), g = Int(a.1 + (b.1 - a.1) * t), bl = Int(a.2 + (b.2 - a.2) * t)
            return "\u{1B}[38;2;\(r);\(g);\(bl)m"
        }
        let dark = (60.0, 18.0, 20.0), accent = (255.0, 112.0, 110.0), light = (255.0, 214.0, 208.0)
        var shades = (0..<16).map { i -> String in
            let t = Double(i) / 15
            return t < 0.7 ? mix(dark, accent, t / 0.7) : mix(accent, light, (t - 0.7) / 0.3)
        }
        shades.append("\u{1B}[1m\u{1B}[38;2;255;244;240m")
        return shades
    }()

    /// A cell's brightness from the cover drawn at one pixel a cell (a cell is
    /// twice as tall as wide, so a square cover is `2 × rows` cells across).
    private func brightness(cols: Int, rows: Int) -> [Float]? {
        guard let image, cols > 0, rows > 0 else { return nil }
        if let levels, levels.cols == cols, levels.rows == rows { return levels.values }
        var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: cols, height: rows,
                                          bitsPerComponent: 8, bytesPerRow: cols * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
            return true
        }
        guard drawn else { return nil }
        // Row 0 of the buffer is the top of the picture.
        var values = (0..<(cols * rows)).map { i -> Float in
            (0.2126 * Float(pixels[i * 4]) + 0.7152 * Float(pixels[i * 4 + 1]) + 0.0722 * Float(pixels[i * 4 + 2])) / 255
        }
        // Stretch between the 3rd and 97th percentiles, so dull covers still read.
        let sorted = values.sorted()
        let low = sorted[sorted.count * 3 / 100], high = sorted[min(sorted.count - 1, sorted.count * 97 / 100)]
        let range = max(0.05, high - low)
        values = values.map { min(1, max(0, ($0 - low) / range)) }
        levels = (cols, rows, values)
        return values
    }

    /// A fixed scramble of a cell's position, so its glyph is the same each draw.
    private static func hash(_ x: Int, _ y: Int) -> UInt64 {
        var h = UInt64(truncatingIfNeeded: x) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: y) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= h >> 29
        h = h &* 0xBF58_476D_1CE4_E5B9
        return h ^ (h >> 32)
    }

    nonisolated private static func fetch(_ url: URL) async -> CGImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await PlexCertificateDelegate.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Nonisolated so the handler, which MediaPlayer calls off the main thread, isn't main-actor bound.
    nonisolated private static func artwork(_ image: CGImage) -> MPMediaItemArtwork {
        let size = NSSize(width: image.width, height: image.height)
        let picture = NSImage(cgImage: image, size: size)
        return MPMediaItemArtwork(boundsSize: size) { _ in picture }
    }
}
