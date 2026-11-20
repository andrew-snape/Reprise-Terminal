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
              reprise --server     choose a different server
              reprise --sign-out   forget this Mac's Plex sign-in
            """)
            return
        }
        let chooseServer = arguments.contains("--server")

        Task {
            do {
                let connection = try await CLISignIn.connect(chooseServer: chooseServer)
                let app = CLIApp(connection: connection)
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
        dispatchMain()
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
