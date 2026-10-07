import SwiftUI
import AppKit
import Sparkle

/// Keeps the process alive when the only window is closed, so playback continues
/// in the background and the window can be reopened from the Dock.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct YT_MusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // App-level state lives for the whole process, so closing the single window
    // (and reopening it from the Dock) restores the same state — and playback
    // keeps going while no window is open. The player also persists its last
    // track so a fresh launch repopulates the now-playing bar.
    @State private var settings: AppSettings
    @State private var player: PlayerState
    @State private var auth = AuthStore()
    @State private var downloader: Downloader
    @State private var pluginHost: PluginHost
    @State private var navigator = Navigator()
    @State private var playlists = PlaylistCoordinator()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    init() {
        CrashHandler.install()

        // Settings must exist before the player, which reads audio-quality /
        // crossfade preferences from it on every track.
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        let player = PlayerState(
            store: UserDefaultsPlaybackStore(),
            settings: settings
        )
        _player = State(initialValue: player)

        // The plugin registry. Adding a plugin = add one line here.
        let downloader = Downloader()
        _downloader = State(initialValue: downloader)
        let plugins: [any Plugin] = [
            DiscordPlugin(player: player),
            NotificationsPlugin(),
            LastfmPlugin(),
            DownloaderPlugin(downloader: downloader),
        ]
        _pluginHost = State(initialValue: PluginHost(plugins: plugins))
    }

    var body: some Scene {
        // `Window` (not `WindowGroup`) is a single unique window: no "New Window"
        // command and no ⌘N, so the user can't open multiple copies.
        Window("YouTube Music", id: "main") {
            ContentView()
                .environment(player)
                .environment(auth)
                .environment(settings)
                .environment(downloader)
                .environment(pluginHost)
                .environment(navigator)
                .environment(playlists)
                .pluginBridge(player: player, host: pluginHost)
        }
        .commands {
            MediaCommands(player: player, navigator: navigator)
            UpdateCommands(updater: updaterController.updater)
        }

        // The native macOS settings window (app menu → Settings…, ⌘,). Scenes
        // don't inherit each other's environments, so inject the same app-level
        // state here — plugin configuration views reach for it too.
        Settings {
            SettingsView(updater: updaterController.updater)
                .environment(player)
                .environment(auth)
                .environment(settings)
                .environment(downloader)
                .environment(pluginHost)
                .environment(navigator)
                .environment(playlists)
        }
    }
}
