// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
//  CLINowPlaying.swift
//  reprise (terminal)
//
//  The playing track in Control Centre's Now Playing, and the media keys
//  (play/pause, next, previous, scrubbing) sent to the player. Needs the main
//  run loop running (RepriseCLI runs RunLoop.main, not dispatchMain).
//

import Foundation
import MediaPlayer

final class CLINowPlaying {
    private let player: CLIPlayer
    private var lastKey: String?
    private var lastPlaying: Bool?
    private var lastPublished = Date.distantPast

    init(player: CLIPlayer, onChange: @escaping @MainActor () -> Void) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (CLIPlayer) -> Void) {
            command.isEnabled = true
            command.addTarget { [weak player] _ in
                // Not promised to arrive on the main thread: hop there.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let player else { return }
                        action(player)
                        onChange()
                    }
                }
                return .success
            }
        }
        handle(center.togglePlayPauseCommand) { $0.togglePause() }
        handle(center.playCommand) { $0.play() }
        handle(center.pauseCommand) { $0.pause() }
        handle(center.nextTrackCommand) { $0.next() }
        handle(center.previousTrackCommand) { $0.previous() }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let position { player?.seek(to: position) }
                    onChange()
                }
            }
            return .success
        }
    }

    /// Call often; publishes on a change of track or state, and every 5 s for the clock.
    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = player.current else {
            if lastKey != nil {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
                lastKey = nil
            }
            return
        }
        let playing = player.isPlaying
        guard track.ratingKey != lastKey || playing != lastPlaying || Date().timeIntervalSince(lastPublished) > 5
        else { return }
        lastKey = track.ratingKey
        lastPlaying = playing
        lastPublished = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title ?? "Untitled",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.time.isFinite ? player.time : 0),
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let artist = track.grandparentTitle { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.parentTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
    }
}
