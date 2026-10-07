//
//  SettingsView.swift
//  YT Music
//
//  The native macOS settings window (Settings scene, ⌘,): a toolbar tab bar
//  with General, Playback, Equalizer, Plugins, and Storage tabs. Plugins
//  render themselves from the PluginHost, so new plugins appear here
//  automatically without editing this file.
//

import Sparkle
import SwiftUI

struct SettingsView: View {
    let updater: SPUUpdater?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsTab(updater: updater)
            }
            Tab("Playback", systemImage: "speaker.wave.2") {
                PlaybackSettingsTab()
            }
            Tab("Equalizer", systemImage: "slider.horizontal.3") {
                EqualizerSettingsTab()
            }
            Tab("Plugins", systemImage: "puzzlepiece.extension") {
                PluginsSettingsTab()
            }
            Tab("Storage", systemImage: "internaldrive") {
                StorageSettingsTab()
            }
        }
    }
}

/// Login item, network proxy, and automatic update checks.
private struct GeneralSettingsTab: View {
    let updater: SPUUpdater?
    @Environment(AppSettings.self) private var settings
    @State private var checksForUpdates = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: $settings.openAtLogin)
            }

            Section("Network") {
                TextField("HTTP proxy URL", text: $settings.proxyURL)
                    .textFieldStyle(.roundedBorder)
                Text(verbatim: "Example: http://localhost:8888. Leave blank to use the system connection. "
                    + "Relaunch the app after changing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                if !settings.proxyURL.isEmpty && NetworkProxy(string: settings.proxyURL) == nil {
                    Text("Enter a valid http:// or https:// proxy URL.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let updater {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $checksForUpdates)
                        .onChange(of: checksForUpdates) { _, enabled in
                            updater.automaticallyChecksForUpdates = enabled
                        }
                }
                .onAppear { checksForUpdates = updater.automaticallyChecksForUpdates }
            }
        }
        .formStyle(.grouped)
    }
}

/// The user's stream source order: drag (or use the context menu) to reorder,
/// toggle to include. The last enabled source can't be turned off.
private struct CustomStreamSourcesList: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let sources = settings.customStreamSources

        ForEach($settings.customStreamSources) { $entry in
            let index = sources.firstIndex(of: entry) ?? 0
            let isLastEnabled = entry.isEnabled && sources.filter(\.isEnabled).count == 1

            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Toggle(isOn: $entry.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.source.title)
                        Text(entry.source.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isLastEnabled)
                .help(isLastEnabled ? "At least one source must stay on." : "")
            }
            .contextMenu {
                Button("Move Up", systemImage: "arrow.up") { move(from: index, by: -1) }
                    .disabled(index == 0)
                Button("Move Down", systemImage: "arrow.down") { move(from: index, by: 1) }
                    .disabled(index == sources.count - 1)
            }
        }
        .onMove { offsets, destination in
            withAnimation { settings.customStreamSources.move(fromOffsets: offsets, toOffset: destination) }
        }
    }

    private func move(from index: Int, by delta: Int) {
        let target = index + delta
        guard settings.customStreamSources.indices.contains(target) else { return }
        withAnimation { settings.customStreamSources.swapAt(index, target) }
    }
}

/// What the last stream actually came from, so the stream-source choice (and
/// an automatic switch to Premium audio) is visible.
private struct StreamStatusRow: View {
    private let status = StreamStatus.shared

    var body: some View {
        LabeledContent("Last stream") {
            Label(summary, systemImage: status.premiumAudioDetected ? "checkmark.seal.fill" : "waveform")
                .foregroundStyle(status.premiumAudioDetected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.opacity)
        }
        .animation(.default, value: summary)
    }

    private var summary: String {
        guard let source = status.lastSource else { return "Nothing played yet" }
        var parts = [source.title]
        if let bitrate = status.lastBitrate, bitrate > 0 { parts.append("\(bitrate / 1000) kbps") }
        if source == .account && status.premiumAudioDetected { parts.append("Premium") }
        if status.lastUsedToken { parts.append("web token") }
        return parts.joined(separator: " · ")
    }
}

/// Audio quality, crossfade, autoplay, and lyrics-source preferences.
private struct PlaybackSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Audio") {
                Picker("Audio quality", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                Toggle("Prefer audio over video", isOn: $settings.preferAudioOverVideo)
                Text("Play music videos as audio-only streams. Turn off to allow combined video+audio streams when they're higher quality.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Normalize volume", isOn: $settings.volumeNormalization)
                Text("Turn down tracks that are louder than YouTube's reference level, as YouTube does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Streaming") {
                Picker("Stream source", selection: $settings.streamSourceMode.animation()) {
                    ForEach(StreamSourceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch settings.streamSourceMode {
                case .automatic:
                    Text("Picks the best source for each track: visionOS for speed and efficiency, "
                        + "your account for uploads and Premium quality.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .custom:
                    CustomStreamSourcesList()
                    Text("Sources are tried from top to bottom. Drag to reorder; turn one off to never use it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                StreamStatusRow()
            }

            Section("Crossfade") {
                Toggle("Crossfade between tracks", isOn: $settings.crossfadeEnabled)
                if settings.crossfadeEnabled {
                    HStack {
                        Slider(value: $settings.crossfadeSeconds, in: 1...12, step: 1)
                        Text("\(Int(settings.crossfadeSeconds))s")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    Text("Overlap the end of each track with the start of the next.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Next track") {
                Toggle("Autoplay", isOn: $settings.autoplay)
                Text("When the queue ends, keep playing a radio based on the last track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Preload next track", isOn: Binding(
                    get: { settings.nextTrackPreloadSeconds > 0 },
                    set: { settings.nextTrackPreloadSeconds = $0 ? 5 : 0 }
                ))
                HStack {
                    Slider(
                        value: Binding(
                            get: { max(5, settings.nextTrackPreloadSeconds) },
                            set: { settings.nextTrackPreloadSeconds = $0 }
                        ),
                        in: 5...60,
                        step: 5
                    )
                    Text(settings.nextTrackPreloadSeconds > 0
                         ? "\(Int(settings.nextTrackPreloadSeconds))s"
                         : "Off")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .disabled(settings.nextTrackPreloadSeconds == 0)
                Text("Start buffering the next track before the current one ends. This can reduce gaps on a slow connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shuffle") {
                Toggle("Keep shuffle on for new queues", isOn: $settings.keepShuffle)
                Text("When shuffle is on, albums, playlists and radios you start next are shuffled too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Lyrics") {
                Picker("Lyrics source", selection: $settings.lyricsProvider) {
                    ForEach(LyricsProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                Text("YouTube Music matches the playing track exactly; LRCLIB is a free open database "
                    + "matched by title and artist, with wider coverage and synced (karaoke) lyrics. "
                    + "Musixmatch adds word-by-word timing where available, via an unofficial endpoint "
                    + "that can be less reliable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The equalizer: enable toggle, preset picker, and a row of vertical gain
/// sliders (one per band).
private struct EqualizerSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    /// The preset matching the current gains, or nil → "Custom".
    private var selectedPreset: EqualizerPreset? {
        EqualizerPreset.matching(settings.equalizerGains)
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle("Enable equalizer", isOn: $settings.equalizerEnabled)
            }

            if settings.equalizerEnabled {
                Section {
                    Picker("Preset", selection: Binding(
                        get: { selectedPreset },
                        set: { if let preset = $0 { settings.applyEqualizerPreset(preset) } }
                    )) {
                        if selectedPreset == nil {
                            Text("Custom").tag(EqualizerPreset?.none)
                        }
                        ForEach(EqualizerPreset.allCases) { preset in
                            Text(preset.label).tag(EqualizerPreset?.some(preset))
                        }
                    }

                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(Array(EqualizerBands.frequencies.indices), id: \.self) { index in
                            BandSlider(
                                gain: Binding(
                                    get: { settings.equalizerGains[index] },
                                    set: { setGain($0, at: index) }
                                ),
                                label: EqualizerBands.label(forIndex: index)
                            )
                        }
                    }
                    .padding(.vertical, 4)

                    Button("Reset to flat") { settings.applyEqualizerPreset(.flat) }
                        .disabled(selectedPreset == .flat)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Writes a single band's gain without replacing the whole array binding
    /// (which would otherwise need a full copy on each slider tick).
    private func setGain(_ value: Double, at index: Int) {
        var gains = settings.equalizerGains
        guard index < gains.count else { return }
        gains[index] = value
        settings.equalizerGains = gains
    }
}

/// The registry-driven plugins list: one toggle, description, and (when
/// enabled) configuration UI per plugin.
private struct PluginsSettingsTab: View {
    @Environment(PluginHost.self) private var pluginHost

    var body: some View {
        Form {
            Section {
                ForEach(pluginHost.plugins, id: \.id) { plugin in
                    PluginRow(plugin: plugin, host: pluginHost)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Disk usage of the shared HTTP cache (API responses and artwork) with a
/// button to clear it along with the in-memory artwork cache.
private struct StorageSettingsTab: View {
    @State private var cacheBytes = URLCache.shared.currentDiskUsage

    var body: some View {
        Form {
            Section("Cache") {
                LabeledContent("Cache size") {
                    Text(Int64(cacheBytes).formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                }
                Button("Clear Cache") {
                    URLCache.shared.removeAllCachedResponses()
                    ImageCache.shared.removeAll()
                    cacheBytes = URLCache.shared.currentDiskUsage
                }
                .disabled(cacheBytes == 0)
                Text("Cached API responses and artwork. They are downloaded again as needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { cacheBytes = URLCache.shared.currentDiskUsage }
    }
}

/// One band's vertical gain slider with its frequency label underneath.
private struct BandSlider: View {
    @Binding var gain: Double
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: $gain, in: EqualizerBands.gainRange, step: 1)
                .frame(height: 90)
                .rotationEffect(.degrees(-90))
                .frame(width: 24, height: 90)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// One plugin's toggle, description, and (when enabled) its configuration UI.
private struct PluginRow: View {
    let plugin: any Plugin
    let host: PluginHost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(plugin.name, isOn: Binding(
                get: { host.isEnabled(plugin) },
                set: { host.setEnabled($0, for: plugin) }
            ))
            Text(plugin.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if host.isEnabled(plugin), let configuration = plugin.configuration {
                configuration
                    .padding(.top, 4)
            }
        }
    }
}

#Preview {
    SettingsView(updater: nil)
        .environment(AppSettings())
        .environment(PluginHost(plugins: [DiscordPlugin(), NotificationsPlugin()]))
}
