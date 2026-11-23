// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLIUpdate.swift
//  reprise (terminal)
//
//  `reprise update`: replaces this binary with the latest GitHub release's,
//  and a once-a-day check that mentions a newer one on launch. The new binary
//  is unpacked beside the old one, must run and report the release's version,
//  and is then renamed over it (never copied onto it: writing into a signed
//  Mach-O's file gets the next launch killed). A copy built from source is
//  left to git.
//

import Foundation

enum CLIUpdate {
    /// Must equal the release tag (without the "v") of the build that ships.
    static let version = "0.1.5"

    private static let latestURL = URL(string: "https://api.github.com/repos/andrew-snape/Reprise-Terminal/releases/latest")!
    private static let sourceHint = "git pull && scripts/install.sh"

    struct Release {
        let version: String
        let asset: URL?
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
    }

    /// This binary, symlinks resolved.
    private static var executable: URL? { Bundle.main.executableURL?.resolvingSymlinksInPath() }

    /// Built from a clone (`scripts/install.sh` links into `.build`): git updates it.
    private static var isSourceBuild: Bool { executable?.path.contains("/.build/") ?? false }

    static func latest(timeout: TimeInterval = 10) async throws -> Release {
        var request = URLRequest(url: latestURL, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("reprise", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "GitHub answered HTTP \(status)"]) }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let asset = release.assets.first { $0.name.hasSuffix("-macos-arm64.tar.gz") }?.browser_download_url
        let tag = release.tag_name
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, asset: asset)
    }

    /// Dotted numbers compared in turn: 0.1.10 is newer than 0.1.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// A line for the status bar when a newer release is out. GitHub is asked at
    /// most once a day; the answer is remembered in between.
    static func notice() async -> String? {
        let defaults = UserDefaults.standard
        let checked = defaults.object(forKey: "updateCheckedAt") as? Date ?? .distantPast
        if Date().timeIntervalSince(checked) > 86_400, let release = try? await latest(timeout: 5) {
            defaults.set(Date(), forKey: "updateCheckedAt")
            defaults.set(release.version, forKey: "latestVersion")
        }
        guard let latest = defaults.string(forKey: "latestVersion"), isNewer(latest, than: version) else { return nil }
        return "Reprise \(latest) is out. Quit and run: " + (isSourceBuild ? sourceHint : "reprise update")
    }

    /// `reprise update`. Returns the exit status.
    static func run() async -> Int32 {
        print("reprise \(version)")
        guard let executable else {
            print("reprise: can't find this binary.")
            return 1
        }
        if isSourceBuild {
            print("This copy was built from source. Update it with:\n  \(sourceHint)")
            return 1
        }
        let release: Release
        do {
            release = try await latest()
        } catch {
            print("reprise: couldn't check for updates: \(SensitiveDataRedactor.redact(error.localizedDescription))")
            return 1
        }
        guard isNewer(release.version, than: version) else {
            print("Up to date.")
            return 0
        }
        guard let asset = release.asset else {
            print("Reprise \(release.version) has no Mac download yet. Try again later.")
            return 1
        }

        let fm = FileManager.default
        let folder = executable.deletingLastPathComponent()
        let work = folder.appending(path: ".reprise-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: false)
        } catch {
            print("reprise: can't write to \(folder.path). Try: sudo reprise update")
            return 1
        }
        defer { try? fm.removeItem(at: work) }

        print("Downloading \(release.version)…")
        let archive = work.appending(path: "reprise.tar.gz")
        do {
            var request = URLRequest(url: asset, timeoutInterval: 60)
            request.setValue("reprise", forHTTPHeaderField: "User-Agent")
            let (temp, response) = try await URLSession.shared.download(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                try? fm.removeItem(at: temp)
                print("reprise: the download failed (HTTP \(status)). Nothing changed.")
                return 1
            }
            try fm.moveItem(at: temp, to: archive)
        } catch {
            print("reprise: the download failed: \(SensitiveDataRedactor.redact(error.localizedDescription)). Nothing changed.")
            return 1
        }

        guard Self.exec("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path]).status == 0 else {
            print("reprise: couldn't unpack the download. Nothing changed.")
            return 1
        }
        let new = work.appending(path: "reprise")
        guard fm.isExecutableFile(atPath: new.path) else {
            print("reprise: the download has no reprise binary. Nothing changed.")
            return 1
        }
        // It must run here and be the release it claims to be.
        let check = Self.exec(new.path, ["--version"])
        guard !check.output.isEmpty else {
            print("reprise: the new version wouldn't run on this Mac. Nothing changed.")
            return 1
        }
        guard check.status == 0, check.output == "reprise \(release.version)" else {
            let said = check.output.split(separator: "\n").first.map { String($0.prefix(60)) } ?? ""
            print("reprise: the download didn't report version \(release.version) (it said \"\(said)\"). Nothing changed.")
            return 1
        }
        // Renamed over the old file, so the old one is never written into.
        guard rename(new.path, executable.path) == 0 else {
            print("reprise: couldn't replace \(executable.path) (\(String(cString: strerror(errno)))). Try: sudo reprise update")
            return 1
        }
        print("Updated to \(release.version).")
        return 0
    }

    /// Runs a program and waits; its trimmed output, with stderr folded in.
    private static func exec(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}
