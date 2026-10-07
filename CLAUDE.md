# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native **macOS SwiftUI** YouTube Music client (bundle id `moe.tenshii.YT-Music`). There is no official YT Music API, so the app reverse-implements YouTube's private **InnerTube** API directly in Swift as the `WEB_REMIX` (YT Music web) client — no Python, sidecar, or yt-dlp at runtime. Playback (including signature/`n` deciphering) is all native Swift + JavaScriptCore. Beyond browsing/playback it covers: listening **history**, **uploads** (browse + upload + delete your own files), **playlist** editing (create/rename/delete, add/remove tracks), a now-playing **queue/lyrics/comments** inspector panel, timed **lyrics** (three providers), and a menu-bar command set with keyboard shortcuts.

## Commands

`xcode-select -p` should point at a full Xcode install (not bare CommandLineTools) for `xcodebuild` to work. If it doesn't, point `DEVELOPER_DIR` at your installed Xcode.app for each command below.

```sh
# Build
xcodebuild -scheme "YouTube Music" -destination 'platform=macOS' build

# Run all tests
xcodebuild -scheme "YouTube Music" -destination 'platform=macOS' test

# Run a single test (Swift Testing) — filter by suite/test name
xcodebuild -scheme "YouTube Music" -destination 'platform=macOS' test \
  -only-testing:"YT MusicTests/StreamSelectionTests"
```

- The project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 110): any `.swift` file dropped under `YT Music/` or `YT MusicTests/` is auto-included in its target — **never hand-edit `project.pbxproj` to add sources.**
- Tests use **Swift Testing** (`import Testing`, `@Test`/`@Suite`/`#expect`/`#require`), hosted in the app (`@testable import YT_Music`). The shared scheme `YouTube Music.xcscheme` wires the test action — required for `xcodebuild test` to find it.

## Concurrency model (important, easy to trip on)

The module sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. So **everything is `@MainActor` by default.** Networking/parsing types that must run off-main are explicitly marked `nonisolated` (the InnerTube client, the decipher/resolver actors, DTOs, parsers). Any new model with computed properties touched off-main must be `nonisolated` too.

## Architecture

UI/state are `@Observable` + environment-injected; network layer is `nonisolated` actors. App-level state (`PlayerState`, `AuthStore`, sidebar `selection`) lives on the `App` struct as `@State` and is passed via environment, so the single `Window` (not `WindowGroup` — no ⌘N / multi-window) can close and reopen with state intact. An `AppDelegate` keeps the process alive after the last window closes so playback continues in the background.

Layers under `YT Music/`:

- **`Auth/`** — sign-in is a `WKWebView` sheet (`LoginView`) to music.youtube.com that captures the cookie jar once a SAPISID appears (uses a desktop Safari user agent). `Credentials` turns cookies into request headers (`Cookie` + `Authorization: SAPISIDHASH …` + `X-Goog-AuthUser`). `CredentialStore` (actor singleton) persists creds in the **Keychain** and supplies headers to every request (empty when signed out, so auth is purely additive). `AuthStore` (`@MainActor @Observable`) drives UI + a `generation` counter that views key `.task(id:)` on to re-personalize on sign-in/out.
- **`InnerTube/`** — the API client and DTOs. `InnerTubeClient` POSTs to `youtubei/v1/browse` (home feed, entity pages, `FEmusic_history`, `FEmusic_library_privately_owned_landing` uploads) and `youtubei/v1/next` (radio: `playlistId="RDAMVM<videoId>"`; also the lyrics-tab browse id and the comments token). `BrowseResponse`/`EntityBrowseResponse`/`WatchNextResponse` are shared Decodable renderers (all keys optional). `*Parser` files turn raw renderers into domain models. Multi-client: a `ClientProfile` selects `webRemix` (default, music.youtube.com) or `web` (www.youtube.com) — **comments are fetched anonymously via the `web` client** because they're a YouTube surface, not a YT Music one (audio-only tracks often have no panel). New capability groups: `LyricsProviding.lyrics(for:)` (two-step: `next` → lyrics browse id → `browse`; `InnerTubeClient` conforms alongside the standalone providers), `CommentsProviding` (`comments`/`moreComments`/`commentReplies`), playlist edits (`createPlaylist`/`deletePlaylist`/`renamePlaylist`/`addToPlaylist`/`removeFromPlaylist` via `browse/edit_playlist` batch actions — **remove needs both `videoId` and the playlist-scoped `setVideoId`**; `addToPlaylistOptions` from `playlist/get_add_to_playlist`), history (`history()` + `removeHistoryItems(feedbackTokens:)` via `feedback` — per-row tokens, no bulk clear), and uploads (`uploads()`, two-step resumable `uploadSong(fileURL:)` to `upload.youtube.com`, `deleteUpload(entityId:)`). Auth 401 → `InnerTubeError.unauthorized` + a `.ytmSessionExpired` notification (see session-expiry gotcha).
- **`Models/`** — domain types: `HomeFeed`, `EntityPage`/`EntityHeader`/`Track`, `EntityDestination` (Hashable nav value), `HistorySection` (date-bucketed, each its own playable queue), `EditablePlaylist` (the "add to playlist" picker model), `Comment`/`CommentPage` (paginated, with reply tokens), and the lyrics types — `Lyrics` (plain `text` + optional synced `lines` + `source`), `LyricLine`/`TimedWord` (per-word richsync timing), `LyricsFocus` (`.none`/`.line`/`.interlude(progress:)`), `LyricsProvider` (`.youtubeMusic`/`.lrclib`/`.musixmatch`), `LyricsQuery`, plus `LRCParser`/`MusixmatchRichSync` decoders (all `nonisolated`, unit-tested).
- **`Features/`** — screens. `Home` owns the `NavigationStack` + `navigationDestination(for: EntityDestination.self)`; cards push entity pages. `Components/Cards.swift` holds reusable `ShelfView`/`ItemCard`/`ArtworkView` and the `.musicContextMenu(...)` modifier. `Library` requires auth (signed-out → prompt). The now-playing bar is a **docked** full-width row at the bottom of the VStack wrapping the NavigationSplitView (not an overlay/safeAreaInset).
- **`Player/`** — `AudioPlayer` (`@MainActor @Observable` AVPlayer wrapper) publishes to Control Center / media keys via `MPNowPlayingInfoCenter` and routes `MPRemoteCommandCenter` commands back. It holds **two AVPlayers** (`active`/`idle`) for crossfade. `PlayerState` owns the queue + `repeatMode` + transport, and persists/restores a snapshot via `PlaybackStore` (`UserDefaultsPlaybackStore`; nil in tests). `PlayerState` init takes optional `AudioOutput`/`StreamResolving`/`AppSettings` for test injection (nil → real defaults). **Autoplay**: when a track starts with nothing after it (a one-off from home, or the last album/playlist track) and repeat is off, `maybeContinueWithRadio`/`appendRadio` fetch a radio for it and append the new tracks so playback continues (one-off → seed becomes the queue head; explicit `startRadio` still replaces the queue).
- **`Settings/`** — `AppSettings` (`@MainActor @Observable`, UserDefaults-backed, env-injected, created before `PlayerState`) holds audio prefs only: `audioQuality`/`preferAudioOverVideo`/`streamSourceMode`/`customStreamSources` (→ a Sendable `StreamPreferences` passed to the resolver), `crossfade` enable/seconds, a 10-band **equalizer** (`equalizerEnabled` + per-band dB `equalizerGains`, exposed as a Sendable `EqualizerSettings` via an `onEqualizerChange` callback wired by `PlayerState`), and the downloader's `downloadDirectory` (a security-scoped bookmark). `SettingsView` is the native macOS `Settings` scene (⌘,): a toolbar-tab window (Playback / Equalizer / Plugins, `Tab`-based `TabView`; environments injected separately from the main window scene). Its Plugins tab is registry-driven (see below).
- **Equalizer** (`Player/Equalizer.swift` + `Player/EqualizerTap.swift`) — AVPlayer has no native EQ, so a graphic EQ is applied via an `MTAudioProcessingTap` installed per `AVPlayerItem`, running RBJ peaking biquads (`Biquad`/`BiquadState`) over the decoded PCM. The pure DSP/model (bands, presets, `EqualizerSettings`, processor) is `nonisolated` and unit-tested; the tap glue is the untested realtime layer. Gotcha: tap C-callbacks must be `nonisolated` to form `@convention(c)` pointers under the module's default `@MainActor` isolation.
- **`Plugins/`** — a registry, not hardcoded wiring. `Plugin` (`@MainActor` protocol: `id`/`name`/`summary`, `setActive`, `playbackDidChange`, optional `configuration: AnyView?`). `PluginHost` (`@Observable`) owns `[any Plugin]`, persists enabled ids (`"plugins.enabled"`), and fans `PlayerState.onPlaybackChange` (a Sendable `PlaybackSnapshot`) out to enabled plugins via the generic `PluginBridge`. **Adding a plugin = write one type + add one line to the `plugins` array in `YT_MusicApp.init()`.** Concrete: `DiscordPlugin` (→ `DiscordRPC` unix-socket IPC), `NotificationsPlugin` (→ `TrackChangeNotifier`), `LastfmPlugin` (→ `LastfmClient`/`ScrobbleTracker`; scrobbles to Last.fm — testable signature + eligibility + tracker, network/auth layer untested; the user enters their own API key + shared secret in the plugin config and approves access in the browser (Last.fm's desktop token flow: `auth.getToken` → approve on last.fm → `auth.getSession`), yielding a session key persisted with the account in the Keychain — no hardcoded credentials, password never touches the app), `DownloaderPlugin` (→ `Downloader` service; batch album/playlist downloads into per-collection subfolders; `ENABLE_USER_SELECTED_FILES = readwrite`).

App Sandbox is disabled for this app, so `DiscordPlugin` → `DiscordRPC` reaches Discord's local IPC socket (`discord-ipc-N` in the real host `$TMPDIR`) without issue.

### Playback / deciphering (the fragile, high-value part)

The signature + `n`-parameter solving is the most brittle code and breaks whenever YouTube ships a new `base.js`:

- `StreamResolver` (actor) tries the **stream sources** in the order `StreamSourcePolicy` gives and picks the highest-bitrate **AAC/MP4** format (AVPlayer can't decode Opus/WebM):
  - **visionOS** (`InnerTubeClient.visionOSPlayer`, values from yt-dlp's `visionos` client): anonymous, plain URLs, no signature/`n` solving and no PO token. Needs a `visitorData`: the first request answers `LOGIN_REQUIRED` with a fresh one, which is cached (`retryVisitorData`). Max 128 kbps AAC (itag 140); no private uploads, age-restricted or made-for-kids videos. yt-dlp added it in 2026-07 after `android_vr` started requiring tokens, so it may close some day.
  - **account** (WEB_REMIX with `sts`, deciphered in JavaScriptCore): googlevideo serves it in full without a PO token only to **Premium** accounts (yt-dlp `not_required_for_premium`, innertubex `premiumMayBypass`); free accounts get cut off after ~1 MB.
  - **PO token** (`PoTokenProvider`, BotGuard in a short-lived hidden `WKWebView`, Safari UA, binding per `PlayerPageConfig`): used only by the account source when the account isn't Premium (`AccountTokenPlan`). Premium accounts are probed once per session (`streamPlaysPastFirstMegabyte`, ranged GET at 1.5 MB → 206/403); a token-free stream that breaks off sets `tokenFreeRejected` for the session.
  - Automatic order: visionOS first; the account first once one of its responses listed itag 141 (Premium audio, held for the session in `StreamSession`; a rejected token-free stream only switches to tokens) and quality is Auto/High. The first track of a session waits at most 0.5 s for the account response. The WEB_REMIX request always runs, because its stats URLs record the play in history (`ResolvedStream.lateTracking` when visionOS streams).
  - Settings → Playback → Streaming: **Automatic** or **Custom** (`StreamSourceEntry` list, normalized so one stays on; a new `StreamSource` case appears in it automatically). `StreamStatus` feeds the `Last stream` row.
- `SignatureDecipher` (actor) fetches `base.js`, extracts `signatureTimestamp`, and solves sig + `n` by **running YouTube's own player code in JavaScriptCore** (it stubs browser globals, finds the URL-signer candidate structurally via the `.set("alr","yes")` fingerprint, and injects a solver before the IIFE close). `JSExtraction.swift` provides regex + brace-matching helpers with nonisolated testing seams.
- When this breaks: reference **yt-dlp**'s `youtube` extractor and its bundled deno solver (`yt.solver.core.js`) as ground truth. `PlaybackLog` (OSLog subsystem `moe.tenshii.YT-Music`, category `playback`, 🎵) logs every resolve stage; on solver failure it dumps the live base.js to `Caches/yt-base.js`. Read with `log stream --predicate 'subsystem == "moe.tenshii.YT-Music"'`.
- WEB_REMIX without auth/PoToken can return `LOGIN_REQUIRED`/`UNPLAYABLE`, and some tracks get SABR/DRM experiments that hide plain URLs.

## Gotchas

- **Mid-track stream failures are recovered, not skipped.** `AudioPlayer` turns `failedToPlayToEndTime` into `onStreamFailed(position)`; `PlayerState` reports the stream to `StreamResolving.streamFailed` and reloads at that position (while paused: on the next play). A second failure without 10 s of progress skips the track. The resolver treats streams older than 1 h as expired and otherwise skips the failed source for that video for 10 min (`StreamFailureMemory`).
- **`BrowseResponse.SectionContent` is a `final class`, not a struct, deliberately.** As a large aggregate struct it hit a toolchain value-witness miscompile (`outlined init with copy` → EXC_BAD_ACCESS). Reference semantics avoid the bulk value copy. Apply the same fix if other big aggregate DTOs crash similarly.
- Required entitlement `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` (both build configs; App Sandbox is on). JavaScriptCore runs via its non-JIT interpreter under hardened runtime — no extra entitlement.
- **End-of-track relies on a backstop, not just the notification.** With two AVPlayers, `AudioPlayer` fires `signalEnd()` once per item (`hasSignalledEnd`); besides `didPlayToEndTimeNotification`, `tick` signals end when `timeControlStatus != .playing && currentTime >= duration-0.5`, and clamps `currentTime` to `duration`. `PlayerState.crossfadeLoading` stops a faded-out track's natural end from double-advancing. Don't remove these or a missed notification will hang playback (the original symptom).

## Playback latency (expected, not a bug)

Starting a track runs a multi-stage async pipeline (`StreamResolver.audioStream`): `signatureTimestamp()` → `player` POST → `selectAudioFormat` → `streamURL(for:)` decipher → AVPlayer buffers the googlevideo stream before audio starts. The base.js fetch + JSCore solver build is **cached** (`SignatureDecipher.cached`), so the *first* play of a session is slowest; later plays still pay one `player` round-trip + remote buffering (typically 1–3s).

**Seeking**: `AudioPlayer.seek` uses a 0.75s `toleranceBefore/After` so AVPlayer snaps to the nearest keyframe instead of decoding to the exact frame over a remote stream — near-instant scrubbing at the cost of frame precision, which is fine for a music player.

## Test coverage

Playback pipeline only, all network-free: sig/`n` decipher against a synthetic base.js (`SignatureDecipherTests`), JS extraction helpers, `StreamResolver.selectAudioFormat`, `Credentials` header building, `PlayerState` resolve→load/error via injected fakes, link building, library/account/watch-next parsing. Not covered (needs live network/AVPlayer): the real `player` request, `playabilityStatus` handling, live base.js extraction, audio output.
