// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexNetworkManager+MusicExtras.swift
//  Rivulet
//
//  The rest of Plex's music API: lyrics, a track's loudness over time,
//  the four UltraBlur colours of a cover, the account's listening history,
//  a sonic path between two tracks, and server play queues.
//

import Foundation

/// A server play queue: its ID and the item ID Plex gave each track, in order.
nonisolated struct PlexPlayQueue: Sendable {
    let id: Int
    let itemIDs: [Int]
    let ratingKeys: [String]
}

/// One play from `/status/sessions/history/all`.
nonisolated struct PlexHistoryEntry: Codable, Identifiable, Sendable {
    let historyKey: String?
    let ratingKey: String?
    let title: String?
    let type: String?
    let thumb: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let parentTitle: String?
    let grandparentTitle: String?
    let viewedAt: Int?
    let accountID: Int?

    var id: String { historyKey ?? "\(ratingKey ?? "")-\(viewedAt ?? 0)" }
}

extension PlexNetworkManager {
    /// A lyric stream's text: LRC with timings, or plain lines.
    func getLyrics(serverURL: String, authToken: String, streamKey: String) async throws -> String {
        guard let url = URL(string: "\(serverURL)\(streamKey)") else { throw PlexAPIError.invalidURL }
        let data = try await requestData(url, headers: plexHeaders(authToken: authToken))
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw PlexAPIError.invalidResponse
        }
        return text
    }

    /// The stream's loudness in dB, every 100 ms, thinned to about `samples` values.
    func getLoudnessLevels(serverURL: String, authToken: String, streamID: Int, samples: Int) async throws -> [Double] {
        guard var components = URLComponents(string: "\(serverURL)/library/streams/\(streamID)/levels") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "subsample", value: "\(samples)")]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let wrapper: LevelsWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
        return (wrapper.MediaContainer.Level ?? []).compactMap(\.v?.value)
    }

    /// The four corner colours Plex picks from an image, as hex: top left, top
    /// right, bottom right, bottom left. `path` is a library path, never a URL with a token.
    func getUltraBlurColors(serverURL: String, authToken: String, path: String) async throws -> [String] {
        guard var components = URLComponents(string: "\(serverURL)/services/ultrablur/colors") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "url", value: path)]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let wrapper: UltraBlurWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
        guard let colors = wrapper.MediaContainer.UltraBlurColors?.first,
              let tl = colors.topLeft, let tr = colors.topRight,
              let br = colors.bottomRight, let bl = colors.bottomLeft else { return [] }
        return [tl, tr, br, bl]
    }

    /// Plays in a library, newest first. `accountID` is the server's own account
    /// number (1 for the owner).
    func getListeningHistory(
        serverURL: String,
        authToken: String,
        sectionID: String,
        accountID: Int?,
        start: Int,
        size: Int
    ) async throws -> (entries: [PlexHistoryEntry], total: Int?) {
        guard var components = URLComponents(string: "\(serverURL)/status/sessions/history/all") else {
            throw PlexAPIError.invalidURL
        }
        var query = [
            URLQueryItem(name: "librarySectionID", value: sectionID),
            URLQueryItem(name: "sort", value: "viewedAt:desc"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)")
        ]
        if let accountID { query.append(URLQueryItem(name: "accountID", value: "\(accountID)")) }
        components.queryItems = query
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let wrapper: HistoryWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
        return (wrapper.MediaContainer.Metadata ?? [], wrapper.MediaContainer.totalSize)
    }

    /// Tracks leading from `startKey` to `endKey`, each close in sound to the
    /// last. Empty when the library has not been sonically analysed.
    func getSonicPath(
        serverURL: String,
        authToken: String,
        sectionID: String,
        startKey: String,
        endKey: String,
        count: Int = 20
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionID)/computePath") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "startID", value: startKey),
            URLQueryItem(name: "endID", value: endKey),
            URLQueryItem(name: "count", value: "\(count)")
        ]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let container: PlexMediaContainerWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.Metadata ?? []
    }

    /// A server play queue holding `ratingKeys` in order, with `selectedKey` playing.
    func createPlayQueue(
        serverURL: String,
        authToken: String,
        machineIdentifier: String,
        ratingKeys: [String],
        selectedKey: String
    ) async throws -> PlexPlayQueue {
        guard var components = URLComponents(string: "\(serverURL)/playQueues") else {
            throw PlexAPIError.invalidURL
        }
        let uri = "server://\(machineIdentifier)/com.plexapp.plugins.library/library/metadata/"
            + ratingKeys.joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "type", value: "audio"),
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "key", value: "/library/metadata/\(selectedKey)"),
            URLQueryItem(name: "shuffle", value: "0"),
            URLQueryItem(name: "repeat", value: "0"),
            URLQueryItem(name: "continuous", value: "0")
        ]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let wrapper: PlayQueueWrapper = try await request(url, method: "POST", headers: plexHeaders(authToken: authToken))
        guard let id = wrapper.MediaContainer.playQueueID else { throw PlexAPIError.invalidResponse }
        let items = wrapper.MediaContainer.Metadata ?? []
        return PlexPlayQueue(id: id, itemIDs: items.compactMap(\.playQueueItemID),
                             ratingKeys: items.compactMap(\.ratingKey))
    }
}

// MARK: - Wire formats

private nonisolated struct LevelsWrapper: Decodable, Sendable {
    nonisolated struct Level: Decodable, Sendable { let v: PlexNumber? }
    nonisolated struct Inner: Decodable, Sendable { let Level: [Level]? }
    let MediaContainer: Inner
}

private nonisolated struct UltraBlurWrapper: Decodable, Sendable {
    nonisolated struct Colors: Decodable, Sendable {
        let topLeft: String?
        let topRight: String?
        let bottomRight: String?
        let bottomLeft: String?
    }
    nonisolated struct Inner: Decodable, Sendable { let UltraBlurColors: [Colors]? }
    let MediaContainer: Inner
}

private nonisolated struct HistoryWrapper: Decodable, Sendable {
    nonisolated struct Inner: Decodable, Sendable {
        let totalSize: Int?
        let Metadata: [PlexHistoryEntry]?
    }
    let MediaContainer: Inner
}

private nonisolated struct PlayQueueWrapper: Decodable, Sendable {
    nonisolated struct Item: Decodable, Sendable {
        let playQueueItemID: Int?
        let ratingKey: String?
    }
    nonisolated struct Inner: Decodable, Sendable {
        let playQueueID: Int?
        let Metadata: [Item]?
    }
    let MediaContainer: Inner
}
