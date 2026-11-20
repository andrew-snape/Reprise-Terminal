// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLISignIn.swift
//  reprise (terminal)
//
//  Plex PIN sign-in, server choice and connection, kept apart from the app's
//  Keychain: the token is a 0600 file in Application Support/reprise-cli.
//

import Foundation

/// What the terminal client remembers between runs.
struct CLIConfig: Codable {
    var authToken: String
    var serverID: String?
    var serverName: String?

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "reprise-cli", directoryHint: .isDirectory)
    }
    private static var file: URL { directory.appending(path: "config.json") }

    static func load() -> CLIConfig? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(CLIConfig.self, from: data)
    }

    func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(self) else { return }
        fm.createFile(atPath: Self.file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    static func delete() {
        try? FileManager.default.removeItem(at: file)
    }
}

/// A server reached at one address, with the token its requests use.
struct CLIConnection {
    let serverName: String
    let serverURL: String
    let token: String

    var isRelay: Bool { PlexRelay.isRelayURL(serverURL) }
}

enum CLISignInError: LocalizedError {
    case pinExpired
    case noServers
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .pinExpired: "The sign-in code expired. Run reprise again."
        case .noServers: "No Plex servers on this account."
        case .unreachable(let name): "Could not reach \(name). Check your network."
        }
    }
}

enum CLISignIn {
    private static let network = PlexNetworkManager.shared

    static func connect(chooseServer: Bool) async throws -> CLIConnection {
        var config: CLIConfig
        if let saved = CLIConfig.load() {
            config = saved
        } else {
            config = CLIConfig(authToken: try await signIn())
            config.save()
        }

        print("Finding your Plex servers…")
        let servers = try await network.getServers(authToken: config.authToken)
        guard !servers.isEmpty else { throw CLISignInError.noServers }

        let server: PlexDevice
        if !chooseServer, let id = config.serverID, let saved = servers.first(where: { $0.clientIdentifier == id }) {
            server = saved
        } else if servers.count == 1 {
            server = servers[0]
        } else {
            server = pick(from: servers)
        }
        config.serverID = server.clientIdentifier
        config.serverName = server.name
        config.save()

        let token = server.accessToken ?? config.authToken
        print("Connecting to \(server.name)…")
        guard let url = await bestConnection(for: server, token: token) else {
            throw CLISignInError.unreachable(server.name)
        }
        return CLIConnection(serverName: server.name, serverURL: url, token: token)
    }

    // MARK: - PIN

    private static func signIn() async throws -> String {
        let (code, pinID) = try await network.requestPin()
        print("""

          \(TTY.accent)Reprise\(TTY.reset) needs to sign in to Plex.

          Go to \(TTY.bold)plex.tv/link\(TTY.reset) and enter  \(TTY.bold)\(TTY.accent)\(code)\(TTY.reset)

        Waiting…
        """)
        for _ in 0..<150 {
            try await Task.sleep(for: .seconds(2))
            if let token = try await network.checkPinAuthentication(pinId: pinID) {
                print("Signed in.\n")
                return token
            }
        }
        throw CLISignInError.pinExpired
    }

    private static func pick(from servers: [PlexDevice]) -> PlexDevice {
        print("\nChoose a server:")
        for (i, server) in servers.enumerated() {
            print("  \(TTY.accent)\(i + 1)\(TTY.reset)  \(server.name)")
        }
        while true {
            print("> ", terminator: "")
            if let line = readLine(), let n = Int(line.trimmingCharacters(in: .whitespaces)),
               servers.indices.contains(n - 1) {
                return servers[n - 1]
            }
        }
    }

    // MARK: - Connection

    /// Probes every candidate at once and takes the best that answers, in this
    /// order: local plex.direct, remote plex.direct, local plain HTTP, relay.
    /// Raw-IP HTTPS is skipped: AVPlayer would reject its certificate.
    private static func bestConnection(for server: PlexDevice, token: String) async -> String? {
        let candidates = (server.connections ?? []).compactMap { c -> (Int, String)? in
            let isDirect = URL(string: c.uri)?.host?.hasSuffix(".plex.direct") == true
            if c.relay { return (3, c.uri) }
            if isDirect { return (c.local ? 0 : 1, c.uri) }
            if c.local, c.protocolType == "http", !PlexAuthManager.isLoopbackAddress(c.address),
               !PlexAuthManager.looksLikeDockerBridge(c.address) {
                return (2, c.uri)
            }
            return nil
        }
        let answered = await withTaskGroup(of: (Int, String)?.self) { group in
            for (rank, uri) in candidates {
                group.addTask { await answers(uri, token: token) ? (rank, uri) : nil }
            }
            var found: [(Int, String)] = []
            for await result in group { if let result { found.append(result) } }
            return found
        }
        return answered.min { $0.0 < $1.0 }?.1
    }

    nonisolated private static func answers(_ uri: String, token: String) async -> Bool {
        guard let url = URL(string: uri + "/identity") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await PlexCertificateDelegate.session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
