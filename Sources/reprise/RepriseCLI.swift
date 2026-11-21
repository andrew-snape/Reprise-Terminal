// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  RepriseCLI.swift
//  reprise (terminal)
//
//  Plex music in a terminal window, built with the vendored RivuletCore
//  (see CLAUDE.md).
//
//  It must never touch PlexAuthManager.shared or KeychainHelper: the auth
//  manager's init clears the app's Keychain vault when its UserDefaults
//  sentinel is missing, and this binary has its own, empty defaults domain.
//  Its token lives in CLIConfig instead.
//

import Foundation

@main
enum RepriseCLI {
    /// Held for the life of the process: its input, timer and signal handlers
    /// capture it weakly, and `run()` returns as soon as they are set up.
    private static var app: CLIApp?

    static func main() {
        PlexAPI.platform = "macOS"
        PlexAPI.deviceName = (Host.current().localizedName ?? "Mac") + " (Terminal)"

        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--sign-out") {
            CLIConfig.delete()
            print("Signed out of Plex.")
            return
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            reprise: Plex music in your terminal

              reprise              browse and play
              reprise <request>    play what you ask for, e.g. reprise mellow radiohead
              reprise --server     choose a different server
              reprise --sign-out   forget this Mac's Plex sign-in
            """)
            return
        }
        let chooseServer = arguments.contains("--server")
        // Hidden: `--ask "<request>"` prints how a request is read and what it finds.
        if let i = arguments.firstIndex(of: "--ask") {
            let text = arguments[(i + 1)...].joined(separator: " ")
            Task {
                await ask(text, chooseServer: chooseServer)
                exit(0)
            }
            dispatchMain()
        }

        // Anything that isn't a flag is a request to play, asked once the library loads.
        if let unknown = arguments.first(where: { $0.hasPrefix("-") && $0 != "--server" }) {
            print("reprise: unknown option \(unknown). See reprise --help.")
            exit(2)
        }
        let request = arguments.filter { $0 != "--server" }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        Task {
            do {
                let connection = try await CLISignIn.connect(chooseServer: chooseServer)
                let app = CLIApp(connection: connection, request: request.isEmpty ? nil : request)
                Self.app = app
                await app.run()
            } catch {
                TTY.restore()
                print("reprise: \(SensitiveDataRedactor.redact(error.localizedDescription))")
                if let plexError = error as? PlexAPIError, plexError.isAuthFailure {
                    print("Your Plex sign-in may have been revoked. Run: reprise --sign-out")
                }
                exit(1)
            }
        }
        // The main run loop, not dispatchMain(): Now Playing and the media keys need it.
        RunLoop.main.run()
    }
}

extension RepriseCLI {
    /// Titles only, never URLs.
    static func ask(_ text: String, chooseServer: Bool) async {
        do {
            let connection = try await CLISignIn.connect(chooseServer: chooseServer)
            let libraries = try await PlexNetworkManager.shared.getLibraries(
                serverURL: connection.serverURL, authToken: connection.token).filter { $0.type == "artist" }
            guard let library = libraries.first else { print("No music library."); return }
            print("Apple Intelligence:", CLIAsk.isAvailable ? "on" : "off")
            let start = Date()
            let session = await CLIAsk.session(connection: connection, section: library.key)
            let result = try await CLIAsk.run(text, session: session, connection: connection, section: library.key)
            if let request = CLIAsk.lastRequest { print("Read as:", request) }
            print(String(format: "%.1f s", Date().timeIntervalSince(start)))
            print(result.label, "·", result.action)
            if let note = result.note { print(note) }
            for t in result.tracks.prefix(10) {
                print("  ♪", t.title ?? "?", "—", t.grandparentTitle ?? "", "·", t.parentTitle ?? "")
            }
            if result.tracks.count > 10 { print("  … \(result.tracks.count) tracks") }
            for c in result.choices.prefix(12) {
                print("  ?", c.type ?? "", c.title ?? "?", "—", c.parentTitle ?? c.grandparentTitle ?? "")
            }
        } catch {
            print("reprise: \(SensitiveDataRedactor.redact(error.localizedDescription))")
        }
    }
}

private extension PlexAPIError {
    var isAuthFailure: Bool {
        switch self {
        case .authenticationFailed: true
        case .httpError(let status, _): status == 401
        default: false
        }
    }
}
