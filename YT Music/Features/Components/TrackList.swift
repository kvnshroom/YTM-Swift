//
//  TrackList.swift
//  YT Music
//

import SwiftUI

/// A numbered track listing (album / playlist style rows). Double-click plays
/// from that row with the whole list as the queue.
struct TrackListView: View {
    let tracks: [Track]
    let album: String
    let hasMore: Bool
    /// Whether rows may offer "Remove from Playlist" (an editable playlist).
    var canRemove = false
    var onRemove: (Track) -> Void = { _ in }
    let onReachedEnd: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(tracks.indices, id: \.self) { index in
                let track = tracks[index]
                TrackRow(
                    track: track,
                    index: index,
                    tracks: tracks,
                    album: album,
                    canRemove: canRemove,
                    onRemove: onRemove
                )
                if index < tracks.count - 1 {
                    Divider().overlay(.primary.opacity(0.08))
                }
            }

            if hasMore {
                Color.clear
                    .frame(height: 1)
                    .id(tracks.count)
                    .onAppear(perform: onReachedEnd)
            }
        }
    }
}

private struct TrackRow: View {
    @Environment(PlayerState.self) private var player
    @Environment(AuthStore.self) private var auth
    let track: Track
    let index: Int
    let tracks: [Track]
    let album: String
    let canRemove: Bool
    let onRemove: (Track) -> Void

    @State private var hovering = false

    /// Whether this row is the track currently loaded in the player.
    private var isCurrent: Bool {
        track.videoId != nil && track.videoId == player.nowPlaying?.videoId
    }

    /// "Remove from Playlist" shows when the server said this row can be
    /// removed — its menu carried the remove action (only rows of playlists
    /// the signed-in user can edit get one) — and the row carries the
    /// playlist-scoped `setVideoId` the remove request needs.
    private var showsRemoveFromPlaylist: Bool {
        auth.isSignedIn
            && canRemove
            && track.videoId != nil
            && track.playlistSetVideoId != nil
            && track.canRemoveFromPlaylist
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                } else {
                    Text("\(track.index)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, alignment: .trailing)

            ArtworkView(url: track.thumbnailURL, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.red : .primary)
                    .lineLimit(1)
                if !track.subtitle.isEmpty {
                    Text(track.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let duration = track.duration {
                Text(duration)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .clipShape(.rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { player.play(tracks, startAt: index, album: album) }
        .musicContextMenu(
            title: track.title,
            subtitle: track.subtitle,
            thumbnailURL: track.thumbnailURL,
            videoId: track.videoId,
            playlistId: nil,
            browseId: nil,
            artists: track.artists,
            albumLink: track.albumLink,
            likeStatus: track.likeStatus
        ) {
            if showsRemoveFromPlaylist {
                Button(role: .destructive) {
                    onRemove(track)
                } label: {
                    Label("Remove from Playlist", systemImage: "minus.circle")
                }
            }
        }
    }
}
