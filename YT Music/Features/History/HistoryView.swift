//
//  HistoryView.swift
//  YT Music
//
//  The History tab: the signed-in user's listening history, grouped into date
//  buckets ("Today", "Yesterday", …) as track rows. Requires authentication;
//  prompts to sign in otherwise. Each date section plays as its own queue.
//

import SwiftUI

struct HistoryView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(Navigator.self) private var navigator
    @State private var model = HistoryViewModel()
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var navigator = navigator

        NavigationStack(path: $navigator.historyPath) {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                switch model.state {
                case .loading:
                    ProgressView("Loading History…")
                        .controlSize(.large)
                        .tint(.primary)
                        .foregroundStyle(.primary)

                case .signedOut:
                    signedOutView

                case .loaded(let sections):
                    content(sections)

                case .failed(let message):
                    errorView(message)
                }
            }
            .navigationTitle("History")
            .toolbar {
                if model.canClear {
                    ToolbarItem {
                        Button(role: .destructive) {
                            confirmingClear = true
                        } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                        .help("Remove everything from your listening history")
                    }
                }
            }
            .confirmationDialog(
                "Clear your entire listening history?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    Task { await model.clearAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            .navigationDestination(for: EntityDestination.self) { destination in
                EntityView(destination: destination)
            }
        }
        .task(id: auth.generation) { await model.load(isSignedIn: auth.isSignedIn) }
    }

    private func content(_ sections: [HistorySection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(sections) { section in
                    HistorySectionView(section: section, model: model)
                }
            }
            .padding(.vertical, 24)
        }
    }

    private var signedOutView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Your history lives here")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Sign in to see the music you've recently played.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign in") { auth.isPresentingLogin = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(40)
        .frame(maxWidth: 380)
    }

    private func errorView(_ text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await model.load(isSignedIn: auth.isSignedIn) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(40)
        .frame(maxWidth: 380)
    }
}

/// One date bucket: a title followed by its track rows.
private struct HistorySectionView: View {
    let section: HistorySection
    let model: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 24)

            VStack(spacing: 0) {
                ForEach(Array(section.tracks.enumerated()), id: \.element.id) { index, track in
                    HistoryTrackRow(track: track, index: index, tracks: section.tracks, model: model)
                    if track.id != section.tracks.last?.id {
                        Divider().overlay(.primary.opacity(0.08))
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }
}

/// A single history entry. Double-clicking plays this date bucket as the queue,
/// starting at the tapped track.
private struct HistoryTrackRow: View {
    @Environment(PlayerState.self) private var player
    let track: Track
    let index: Int
    let tracks: [Track]
    let model: HistoryViewModel

    @State private var hovering = false

    /// Whether this row is the track currently loaded in the player.
    private var isCurrent: Bool {
        track.videoId != nil && track.videoId == player.nowPlaying?.videoId
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                ArtworkView(url: track.thumbnailURL, size: 40)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.45))
                        .frame(width: 40, height: 40)
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

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
        .onTapGesture { player.play(tracks, startAt: index, album: "") }
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
            if track.feedbackToken != nil {
                Divider()
                Button(role: .destructive) {
                    Task { await model.remove(track) }
                } label: {
                    Label("Remove from history", systemImage: "clock.badge.xmark")
                }
            }
        }
    }
}

#Preview {
    HistoryView()
        .environment(PlayerState())
        .environment(AuthStore())
        .environment(Navigator())
        .environment(PlaylistCoordinator())
        .frame(width: 900, height: 600)
}
