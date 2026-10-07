# Stream Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Playback that works for free and Premium accounts with the lightest native path (visionOS first, the signed-in account token-free for Premium, a WebKit PO token only as fallback), plus Automatic/Custom stream source settings, as four stacked upstream-ready branches.

**Architecture:** Pure decision logic lives in a new networking-free `StreamSourcePolicy.swift` (source order, Premium detection, failure classification, short failure memory, session state). `StreamResolver` (actor) orchestrates requests and applies the policy. `PlayerState` reports mid-track stream failures back to the resolver and reloads at the position reached. Settings (`AppSettings` + `SettingsView`) select Automatic or a custom source order; `StreamStatus` shows what the last stream used.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), AVFoundation, WebKit (token fallback only), JavaScriptCore (existing decipher), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-07-stream-sources-design.md` (on branch `local/kvn`; not part of the PR branches)

## Global Constraints

- Repo: `~/Claude/review/YTM-Swift`. Base for PR 1: `origin/master` (upstream CuteTenshii/YTM-Swift, `00b6b5f` or newer).
- Branches (stacked): `feat/visionos-source` ← `origin/master`; `feat/stream-recovery` ← PR 1; `feat/po-token-fallback` ← PR 2; `feat/stream-source-settings` ← PR 3.
- Module default isolation is `MainActor`; anything used off-main (policy types, DTOs, resolver helpers) must be `nonisolated`.
- New `.swift` files go under `YT Music/` or `YT MusicTests/` (synchronized groups). Never edit `project.pbxproj`.
- SwiftLint runs in the build: multi-line collection literals need a trailing comma; no space before commas.
- All code, comments, UI strings and commit messages in English. UI strings: Apple style, `·` separators, no internal terms ("PO token", "WEB_REMIX").
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nothing is pushed and no PR is opened without the user's OK.
- Build: `mobilebuildmcp macos build --project-path "YT Music.xcodeproj" --scheme "YouTube Music" --extra-args 'CODE_SIGN_IDENTITY=-' --extra-args 'DEVELOPMENT_TEAM='`
- Test (one suite): `mobilebuildmcp macos test --project-path "YT Music.xcodeproj" --scheme "YouTube Music" --extra-args 'CODE_SIGN_IDENTITY=-' --extra-args 'DEVELOPMENT_TEAM=' --extra-args '-only-testing:YT MusicTests/<SuiteStruct>'`
- Tests are hosted in the app and need a GUI login session for `dev`. Over plain SSH the runner fails with "Failed to establish communication with the test runner"; then a step's minimum bar is `** TEST BUILD SUCCEEDED **` in the log, and the PR gate tasks (6, 10, 13, 16) require a real passing run in a GUI session before the PR counts as done.
- Constants (verbatim from the spec): first-track wait for the account response **0.5 s**; failure memory lifetime **10 minutes**; a stream older than **1 hour** counts as expired; token-free probe is a ranged GET at **1.5 MB** (`bytes=1500000-1500001`): 206 = works, 403 = needs a token, anything else = inconclusive; Premium audio = **itag 141** (AVPlayer-compatible).
- visionOS client values (verbatim): clientName `VISIONOS`, clientVersion `1.02`, header client name `101`, deviceMake `Apple`, deviceModel `RealityDevice17,1`, osName `visionOS`, osVersion `26.5.23O471`, user agent `Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15`, base `https://www.youtube.com/youtubei/v1/`, API key `AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8`.
- Nothing is persisted except the user's settings (mode + custom order). Session state resets on relaunch and on sign-in change (keyed by SAPISID).

## Review Focus

1. Signed-in free user, first track after launch: must start within ~0.5 s extra at most and never wait for a slow account response beyond that → test `firstTrackDeadline` in Task 3.
2. Premium detected, then a track whose account response lacks itag 141 (Premium expired / account switched): the next track must go back to visionOS, not keep preferring the account → test `premiumStateFollowsLatestResponse` in Task 3.
3. Track paused for hours, then resumed: must reload at the same position with the same source order, without blacklisting a healthy source → test `oldStreamCountsAsExpired` in Task 9.
4. A source that keeps failing for one video must not loop: reload once, then skip; the failed source is skipped for that video for 10 minutes, other videos unaffected → tests `skipsAfterRepeatedFailure` (Task 8) and `failureMemoryIsPerVideoAndExpires` (Task 9).
5. Custom order with every source switched off (corrupt or hand-edited defaults): must still play using the automatic order → test `customWithNothingEnabled` in Task 14.

---

## PR 1 — `feat/visionos-source`: visionOS source, automatic order, Premium detection

### Task 1: Branch, response fields and the visionOS player request

**Files:**
- Modify: `YT Music/InnerTube/PlayerResponse.swift`
- Modify: `YT Music/InnerTube/InnerTubeClient.swift` (ClientProfile, `player` neighborhood, `applyClientHeaders`, `context`)
- Test: `YT MusicTests/StreamPolicyTests.swift` (create)

**Interfaces:**
- Produces: `PlayerResponse.responseContext?.visitorData: String?`; `PlayerResponse.PlaybackTracking.playbackURL: URL?`, `.watchtimeURL: URL?`; `InnerTubeClient.visionOSPlayer(videoId: String, visitorData: String?) async throws -> PlayerResponse`.

- [ ] **Step 1: Create the branch**

```bash
cd ~/Claude/review/YTM-Swift
git fetch origin
git switch -c feat/visionos-source origin/master
```

- [ ] **Step 2: Write the failing test**

Create `YT MusicTests/StreamPolicyTests.swift`:

```swift
//
//  StreamPolicyTests.swift
//  YT MusicTests
//
//  Tests for choosing where a track's stream comes from (StreamSourcePolicy)
//  and the response fields the choice reads.
//

import Testing
import Foundation
@testable import YT_Music

func playerResponse(_ json: String) throws -> PlayerResponse {
    try JSONDecoder().decode(PlayerResponse.self, from: Data(json.utf8))
}

@Suite("Stream policy")
struct StreamPolicyTests {
    @Test("Reads the visitor id and the stats URLs")
    func readsResponseContextAndTracking() throws {
        let response = try playerResponse("""
        { "responseContext": { "visitorData": "Cgt4" },
          "playbackTracking": {
            "videostatsPlaybackUrl": { "baseUrl": "https://s.youtube.com/api/stats/playback?docid=a" },
            "videostatsWatchtimeUrl": { "baseUrl": "https://s.youtube.com/api/stats/watchtime?docid=a" } } }
        """)
        #expect(response.responseContext?.visitorData == "Cgt4")
        #expect(response.playbackTracking?.playbackURL?.query == "docid=a")
        #expect(response.playbackTracking?.watchtimeURL?.path == "/api/stats/watchtime")
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: Test command with `<SuiteStruct>` = `StreamPolicyTests`.
Expected: build FAILS with "value of type 'PlayerResponse' has no member 'responseContext'".

- [ ] **Step 4: Add the response fields**

In `YT Music/InnerTube/PlayerResponse.swift`, inside `struct PlayerResponse` after `let playerConfig: PlayerConfig?`:

```swift
    var responseContext: ResponseContext? = nil

    /// The visitor id YouTube assigned this session. The visionOS client needs
    /// one to play (see `StreamResolver`).
    nonisolated struct ResponseContext: Decodable, Sendable {
        let visitorData: String?
    }
```

Inside `PlaybackTracking`, after `let videostatsWatchtimeUrl: TrackingURL?`:

```swift

        var playbackURL: URL? { videostatsPlaybackUrl?.baseUrl.flatMap { URL(string: $0) } }
        var watchtimeURL: URL? { videostatsWatchtimeUrl?.baseUrl.flatMap { URL(string: $0) } }
```

- [ ] **Step 5: Add the visionOS client**

In `InnerTubeClient.swift`, replace `private struct ClientProfile { … }` with:

```swift
    private struct ClientProfile {
        let baseURL: URL
        let clientName: String        // context.client.clientName
        let clientVersion: String
        let clientNameHeader: String  // X-YouTube-Client-Name
        let origin: String
        let apiKey: String
        /// Overrides the default desktop Chrome user agent.
        var userAgent: String? = nil
        /// Extra `context.client` fields (device and OS for native app clients).
        var clientDetails: [String: String] = [:]
    }
```

After the `private let web = ClientProfile(…)` declaration add:

```swift

    /// The YouTube app for visionOS (Apple Vision Pro). Only used for anonymous
    /// `player` requests; values follow yt-dlp's `visionos` client.
    private let visionOS = ClientProfile(
        baseURL: URL(string: "https://www.youtube.com/youtubei/v1/")!,
        clientName: "VISIONOS",
        clientVersion: "1.02",
        clientNameHeader: "101",
        origin: "https://www.youtube.com",
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        clientDetails: [
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice17,1",
            "osName": "visionOS",
            "osVersion": "26.5.23O471",
        ]
    )
```

In `applyClientHeaders`, replace `request.setValue(userAgent, forHTTPHeaderField: "User-Agent")` with:

```swift
        request.setValue(profile.userAgent ?? userAgent, forHTTPHeaderField: "User-Agent")
```

In `context(client:visitorData:)`, before `if let visitorData { … }` insert:

```swift
        clientContext.merge(profile.clientDetails) { current, _ in current }
```

Directly after the existing `func player(videoId:signatureTimestamp:playlistId:)` add:

```swift

    /// Loads playback streams for a video as the visionOS YouTube app, which
    /// currently serves complete streams with plain URLs: no signature or `n`
    /// solving and no PO token (see `StreamResolver`). Always anonymous. Without
    /// `visitorData` YouTube answers `LOGIN_REQUIRED` and hands out a fresh one
    /// in `responseContext`.
    func visionOSPlayer(videoId: String, visitorData: String?) async throws -> PlayerResponse {
        try await post(
            "player",
            body: ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true],
            client: visionOS,
            authenticated: false,
            visitorData: visitorData
        )
    }
```

- [ ] **Step 6: Run the test to verify it passes**

Run: Test command with `StreamPolicyTests`. Expected: PASS (or, without a GUI session, `** TEST BUILD SUCCEEDED **`).

- [ ] **Step 7: Commit**

```bash
git add "YT Music/InnerTube/PlayerResponse.swift" "YT Music/InnerTube/InnerTubeClient.swift" "YT MusicTests/StreamPolicyTests.swift"
git commit -m "feat(innertube): add an anonymous visionOS player request

The visionOS YouTube client serves complete AAC streams with plain URLs:
no signature or n solving and no PO token. Client profiles can carry
their own user agent and device fields, and player responses expose the
visitor id and stats URLs.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: StreamSourcePolicy — sources, automatic order, Premium detection, visionOS helpers

**Files:**
- Create: `YT Music/InnerTube/StreamSourcePolicy.swift`
- Test: `YT MusicTests/StreamPolicyTests.swift`

**Interfaces:**
- Consumes: `PlayerResponse` (Task 1), `AudioQuality` (existing, `AppSettings.swift`).
- Produces: `enum StreamSource: String, Codable, CaseIterable, Sendable, Hashable { case visionOS, account }`; `enum StreamSourcePolicy` with `static func automaticOrder(quality: AudioQuality, premiumAudio: Bool) -> [StreamSource]`, `static func offersPremiumAudio(_ response: PlayerResponse) -> Bool`, `static func retryVisitorData(after response: PlayerResponse, sentWith sent: String?) -> String?`, `static func directURL(of format: PlayerResponse.Format) -> URL?`.

- [ ] **Step 1: Write the failing tests**

Append inside `struct StreamPolicyTests`:

```swift
    @Test("Without Premium audio, visionOS comes first")
    func automaticOrderWithoutPremium() {
        for quality in AudioQuality.allCases {
            #expect(StreamSourcePolicy.automaticOrder(quality: quality, premiumAudio: false) == [.visionOS, .account])
        }
    }

    @Test("With Premium audio, the account comes first only for the best quality")
    func automaticOrderWithPremium() {
        #expect(StreamSourcePolicy.automaticOrder(quality: .auto, premiumAudio: true) == [.account, .visionOS])
        #expect(StreamSourcePolicy.automaticOrder(quality: .high, premiumAudio: true) == [.account, .visionOS])
        #expect(StreamSourcePolicy.automaticOrder(quality: .medium, premiumAudio: true) == [.visionOS, .account])
        #expect(StreamSourcePolicy.automaticOrder(quality: .low, premiumAudio: true) == [.visionOS, .account])
    }

    @Test("Premium audio means an AVPlayer-compatible itag 141")
    func detectsPremiumAudio() throws {
        let premium = try playerResponse("""
        { "streamingData": { "adaptiveFormats": [
            { "itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 130000 },
            { "itag": 141, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 260000 }
        ] } }
        """)
        let free = try playerResponse("""
        { "streamingData": { "adaptiveFormats": [
            { "itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 130000 },
            { "itag": 251, "mimeType": "audio/webm; codecs=\\"opus\\"", "bitrate": 160000 }
        ] } }
        """)
        #expect(StreamSourcePolicy.offersPremiumAudio(premium))
        #expect(!StreamSourcePolicy.offersPremiumAudio(free))
        #expect(!StreamSourcePolicy.offersPremiumAudio(try playerResponse("{}")))
    }

    @Test("A LOGIN_REQUIRED visionOS answer with a new visitor id is retried with it")
    func retriesWithFreshVisitorData() throws {
        let response = try playerResponse("""
        { "playabilityStatus": { "status": "LOGIN_REQUIRED" },
          "responseContext": { "visitorData": "fresh" } }
        """)
        #expect(StreamSourcePolicy.retryVisitorData(after: response, sentWith: nil) == "fresh")
        #expect(StreamSourcePolicy.retryVisitorData(after: response, sentWith: "stale") == "fresh")
        #expect(StreamSourcePolicy.retryVisitorData(after: response, sentWith: "fresh") == nil)

        let playable = try playerResponse("""
        { "playabilityStatus": { "status": "OK" }, "responseContext": { "visitorData": "fresh" } }
        """)
        #expect(StreamSourcePolicy.retryVisitorData(after: playable, sentWith: nil) == nil)
    }

    @Test("Uses a plain URL as is but never a ciphered one")
    func directURLOnlyWithoutCipher() throws {
        let response = try playerResponse("""
        { "streamingData": { "adaptiveFormats": [
            { "itag": 140, "mimeType": "audio/mp4", "url": "https://rr1.googlevideo.com/videoplayback?itag=140" },
            { "itag": 141, "mimeType": "audio/mp4", "signatureCipher": "s=abc&url=https%3A%2F%2Fx" }
        ] } }
        """)
        let formats = try #require(response.streamingData?.adaptiveFormats)
        #expect(StreamSourcePolicy.directURL(of: formats[0])?.host == "rr1.googlevideo.com")
        #expect(StreamSourcePolicy.directURL(of: formats[1]) == nil)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: Test command with `StreamPolicyTests`. Expected: build FAILS, "cannot find 'StreamSourcePolicy' in scope".

- [ ] **Step 3: Implement**

Create `YT Music/InnerTube/StreamSourcePolicy.swift`:

```swift
//
//  StreamSourcePolicy.swift
//  YT Music
//
//  The decisions behind choosing where a track's stream comes from, kept free
//  of networking so they can be unit-tested. StreamResolver applies them.
//
//  Background (2026-10): googlevideo cuts signed-in WEB_REMIX streams without a
//  PO token after ~1 MB, except for Premium accounts (yt-dlp:
//  `not_required_for_premium`, innertubex: `premiumMayBypass`). The visionOS
//  client serves complete streams without a token or deciphering. So free
//  accounts stream from visionOS, Premium accounts from the account (256 kbps,
//  itag 141), each falling back to the other.
//

import Foundation

/// Where a track's stream URL comes from.
nonisolated enum StreamSource: String, Codable, CaseIterable, Sendable, Hashable {
    /// The anonymous visionOS client: complete AAC streams up to 128 kbps with
    /// no PO token and no deciphering. Can't play private uploads or
    /// age-restricted / made-for-kids videos.
    case visionOS
    /// The signed-in WEB_REMIX client. Plays everything the account can,
    /// including Premium's 256 kbps AAC.
    case account
}

nonisolated enum StreamSourcePolicy {
    /// The automatic order: visionOS first, unless the account offers Premium
    /// audio and the best quality is wanted. Both sources are always listed, so
    /// each is the other's fallback.
    static func automaticOrder(quality: AudioQuality, premiumAudio: Bool) -> [StreamSource] {
        let wantsBest = quality == .auto || quality == .high
        return premiumAudio && wantsBest ? [.account, .visionOS] : [.visionOS, .account]
    }

    /// Whether a player response lists Premium's 256 kbps AAC (itag 141). YT
    /// Music serves it only to Premium accounts, so it doubles as detection.
    static func offersPremiumAudio(_ response: PlayerResponse) -> Bool {
        (response.streamingData?.adaptiveFormats ?? []).contains { $0.itag == 141 && $0.isAVPlayerCompatible }
    }

    /// The visitor id to retry a visionOS request with: YouTube answers a
    /// request without one (or with one it no longer accepts) with
    /// `LOGIN_REQUIRED` and a fresh id. nil when a retry wouldn't help.
    static func retryVisitorData(after response: PlayerResponse, sentWith sent: String?) -> String? {
        guard response.playabilityStatus?.status == "LOGIN_REQUIRED",
              let fresh = response.responseContext?.visitorData,
              fresh != sent else { return nil }
        return fresh
    }

    /// The format's URL when it is served ready to play, nil when it is hidden
    /// behind a signature cipher.
    static func directURL(of format: PlayerResponse.Format) -> URL? {
        guard format.cipherString == nil else { return nil }
        return format.url.flatMap { URL(string: $0) }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: Test command with `StreamPolicyTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add "YT Music/InnerTube/StreamSourcePolicy.swift" "YT MusicTests/StreamPolicyTests.swift"
git commit -m "feat(playback): add the stream source policy

Two sources, visionOS and the signed-in account, with an automatic
order that prefers visionOS unless the account offers Premium audio
(itag 141) and the best quality is wanted.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: Session state and the first-track deadline

**Files:**
- Modify: `YT Music/InnerTube/StreamSourcePolicy.swift`
- Test: `YT MusicTests/StreamPolicyTests.swift`

**Interfaces:**
- Consumes: `StreamSourcePolicy.offersPremiumAudio` (Task 2).
- Produces: `struct StreamSession: Sendable` with `var sapisid: String? { get }`, `var premiumAudio: Bool? { get }`, `mutating func reset(for sapisid: String?)`, `mutating func record(_ response: PlayerResponse)`; free function `func awaitValue<T: Sendable>(of task: Task<T, Error>, within seconds: Double) async -> T?`.

- [ ] **Step 1: Write the failing tests**

Append inside `struct StreamPolicyTests`:

```swift
    private let premiumJSON = """
    { "streamingData": { "adaptiveFormats": [
        { "itag": 141, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 260000 }
    ] } }
    """
    private let freeJSON = """
    { "streamingData": { "adaptiveFormats": [
        { "itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"", "bitrate": 130000 }
    ] } }
    """

    @Test("Premium state follows the latest account response")
    func premiumStateFollowsLatestResponse() throws {
        var session = StreamSession()
        session.reset(for: "sapisid-a")
        #expect(session.premiumAudio == nil)

        session.record(try playerResponse(premiumJSON))
        #expect(session.premiumAudio == true)

        session.record(try playerResponse(freeJSON))   // Premium ended mid-session
        #expect(session.premiumAudio == false)
    }

    @Test("A sign-in change starts the session over")
    func signInChangeResetsSession() throws {
        var session = StreamSession()
        session.reset(for: "sapisid-a")
        session.record(try playerResponse(premiumJSON))

        session.reset(for: "sapisid-a")                  // same account: kept
        #expect(session.premiumAudio == true)

        session.reset(for: "sapisid-b")                  // other account: unknown again
        #expect(session.premiumAudio == nil)
        #expect(session.sapisid == "sapisid-b")
    }

    @Test("The first-track deadline returns a fast result and gives up on a slow one")
    func firstTrackDeadline() async {
        let fast = Task<Int, Error> { 7 }
        #expect(await awaitValue(of: fast, within: 0.5) == 7)

        let slow = Task<Int, Error> {
            try await Task.sleep(for: .seconds(5))
            return 8
        }
        let started = ContinuousClock.now
        #expect(await awaitValue(of: slow, within: 0.05) == nil)
        #expect(ContinuousClock.now - started < .seconds(1))
        slow.cancel()

        let failing = Task<Int, Error> { throw URLError(.notConnectedToInternet) }
        #expect(await awaitValue(of: failing, within: 0.5) == nil)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: Test command with `StreamPolicyTests`. Expected: build FAILS, "cannot find 'StreamSession' in scope".

- [ ] **Step 3: Implement**

Append to `YT Music/InnerTube/StreamSourcePolicy.swift`:

```swift

/// What the resolver knows about the signed-in account during this app
/// session. Nothing is persisted: it starts over on relaunch and when the
/// signed-in account (SAPISID) changes.
nonisolated struct StreamSession: Sendable {
    private(set) var sapisid: String?
    /// Whether the latest account response offered Premium audio; nil until
    /// one was seen. Re-read on every response, so an expired or new
    /// subscription takes effect from the next track on.
    private(set) var premiumAudio: Bool?

    /// Starts over when the signed-in account changed.
    mutating func reset(for sapisid: String?) {
        guard sapisid != self.sapisid else { return }
        self = StreamSession()
        self.sapisid = sapisid
    }

    mutating func record(_ response: PlayerResponse) {
        premiumAudio = StreamSourcePolicy.offersPremiumAudio(response)
    }
}

/// The task's value if it succeeds within `seconds`, else nil. The task keeps
/// running either way, so its result can still be used later.
nonisolated func awaitValue<T: Sendable>(of task: Task<T, Error>, within seconds: Double) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await task.value }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: Test command with `StreamPolicyTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add "YT Music/InnerTube/StreamSourcePolicy.swift" "YT MusicTests/StreamPolicyTests.swift"
git commit -m "feat(playback): track Premium audio per session

The latest account response decides whether the account offers Premium
audio; a sign-in change starts over. A helper waits for a task only up
to a deadline, for the first track of a session.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: StreamResolver — try the sources in order

**Files:**
- Modify: `YT Music/InnerTube/StreamResolver.swift`
- Test: `YT MusicTests/StreamSelectionTests.swift` (existing tests must keep passing; no new tests — the resolver's network paths are covered live in Task 6, its decisions by Tasks 2–3)

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `ResolvedStream` gains `var videoId: String? = nil`, `var source: StreamSource? = nil`, `var usedToken = false`, `var resolvedAt = Date()`, `var lateTracking: Task<PlayerResponse.PlaybackTracking?, Never>? = nil`. Private resolver methods `visionOSStream(videoId:preferences:accountResponse:)`, `accountStream(videoId:response:preferences:)`, `resolved(url:format:response:tracking:videoId:source:usedToken:)`.

- [ ] **Step 1: Extend `ResolvedStream`**

In `StreamResolver.swift`, inside `struct ResolvedStream` after `var loudnessDb: Double? = nil` add:

```swift
    /// The track this stream plays, and where and when it was resolved, so a
    /// stream that dies mid-track can be reported back (see `StreamResolving`).
    var videoId: String? = nil
    var source: StreamSource? = nil
    /// Whether the URL carries a PO token minted in a web view.
    var usedToken = false
    var resolvedAt = Date()
    /// Stats URLs that arrive after the stream: the account's player response
    /// when visionOS answered first. Resolves to nil when there are none.
    var lateTracking: Task<PlayerResponse.PlaybackTracking?, Never>? = nil
```

Update the file header comment to:

```swift
//  Turns a videoId into a final, playable audio URL. Tries the stream sources
//  in the order StreamSourcePolicy gives (visionOS for free accounts, the
//  signed-in account for Premium), picks an AVPlayer-compatible audio stream,
//  and deciphers its URL when needed.
```

- [ ] **Step 2: Replace `audioStream` and add the source paths**

Replace the body of `actor StreamResolver` from `private let decipher = SignatureDecipher.shared` through the end of `audioStream(…)` with:

```swift
    private let decipher = SignatureDecipher.shared

    /// How long the first track of a session waits for the account response
    /// to learn whether the account offers Premium audio.
    static let firstTrackDeadline = 0.5

    private var session = StreamSession()
    /// The visitor id the visionOS client plays under, taken from its first
    /// `LOGIN_REQUIRED` answer and reused for later tracks.
    private var visionOSVisitorData: String?

    func audioStream(videoId: String, playlistId: String?, preferences: StreamPreferences) async throws -> ResolvedStream {
        PlaybackLog.note("resolving videoId=\(videoId) playlist=\(playlistId ?? "—")")
        let signatureTimestamp = try await decipher.signatureTimestamp()
        // The account's player response is needed whichever source streams: its
        // stats URLs record the play in the user's history, it tells whether the
        // account offers Premium audio, and it is the account source itself.
        let accountResponse = Task {
            try await playerResponse(
                videoId: videoId,
                signatureTimestamp: signatureTimestamp,
                playlistId: playlistId
            )
        }

        let premiumAudio = await premiumAudio(awaiting: accountResponse)
        let order = StreamSourcePolicy.automaticOrder(quality: preferences.audioQuality, premiumAudio: premiumAudio)
        PlaybackLog.note("source order: \(order.map(\.rawValue).joined(separator: ", ")) "
            + "(premium audio \(premiumAudio), quality \(preferences.audioQuality.rawValue))")

        var lastError: Error = StreamError.noCompatibleAudio
        for source in order {
            do {
                switch source {
                case .visionOS:
                    return try await visionOSStream(videoId: videoId, preferences: preferences,
                                                    accountResponse: accountResponse)
                case .account:
                    let response = try await accountResponse.value
                    session.record(response)
                    return try await accountStream(videoId: videoId, response: response, preferences: preferences)
                }
            } catch {
                PlaybackLog.problem("stream source \(source.rawValue) failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    /// Whether the signed-in account offers Premium audio. Known after the
    /// first account response of a session; for the first track, waits for it
    /// up to `firstTrackDeadline` and otherwise assumes no.
    private func premiumAudio(awaiting accountResponse: Task<PlayerResponse, Error>) async -> Bool {
        let sapisid = await CredentialStore.shared.credentials?.sapisid
        session.reset(for: sapisid)
        guard sapisid != nil else { return false }
        if let known = session.premiumAudio { return known }
        guard let response = await awaitValue(of: accountResponse, within: Self.firstTrackDeadline) else {
            PlaybackLog.note("account response not there in time; assuming no Premium audio for this track")
            return false
        }
        session.record(response)
        return session.premiumAudio ?? false
    }

    /// A stream from the visionOS client. Its URLs are complete as served: no
    /// signature, `n` parameter or PO token. Starts without waiting for the
    /// account response, whose stats URLs follow as `lateTracking`.
    private func visionOSStream(
        videoId: String,
        preferences: StreamPreferences,
        accountResponse: Task<PlayerResponse, Error>
    ) async throws -> ResolvedStream {
        let sentVisitorData = visionOSVisitorData
        var response = try await client.visionOSPlayer(videoId: videoId, visitorData: sentVisitorData)
        if let fresh = StreamSourcePolicy.retryVisitorData(after: response, sentWith: sentVisitorData) {
            visionOSVisitorData = fresh
            response = try await client.visionOSPlayer(videoId: videoId, visitorData: fresh)
        }
        PlaybackLog.note("visionOS playabilityStatus=\(response.playabilityStatus?.status ?? "nil")")
        try checkPlayability(response)

        let format = try selectAudioFormat(response, preferences: preferences)
        guard let url = StreamSourcePolicy.directURL(of: format) else {
            throw StreamError.notPlayable("visionOS stream URL needs deciphering")
        }
        PlaybackLog.note("visionOS selected itag=\(format.itag ?? -1) mime=\(format.mimeType ?? "?")")

        var stream = resolved(url: url, format: format, response: response, tracking: nil,
                              videoId: videoId, source: .visionOS, usedToken: false)
        let visionOSTracking = response.playbackTracking
        stream.lateTracking = Task {
            let account = try? await accountResponse.value
            if let account { recordAccountResponse(account) }
            return account?.playbackTracking ?? visionOSTracking
        }
        return stream
    }

    private func recordAccountResponse(_ response: PlayerResponse) {
        session.record(response)
    }

    /// A stream from the signed-in WEB_REMIX response, deciphered in
    /// JavaScriptCore. Plays in full without a PO token for Premium accounts.
    private func accountStream(
        videoId: String,
        response: PlayerResponse,
        preferences: StreamPreferences
    ) async throws -> ResolvedStream {
        let status = response.playabilityStatus?.status ?? "nil"
        let adaptiveCount = response.streamingData?.adaptiveFormats?.count ?? 0
        PlaybackLog.note(
            "playabilityStatus=\(status) · adaptiveFormats=\(adaptiveCount) "
                + "· lengthSeconds=\(response.videoDetails?.lengthSeconds ?? "nil")"
        )

        try checkPlayability(response)

        let format = try selectAudioFormat(response, preferences: preferences)
        PlaybackLog.note("selected itag=\(format.itag ?? -1) mime=\(format.mimeType ?? "?") quality=\(preferences.audioQuality.rawValue)")

        let deciphered = try await decipher.streamURL(for: format)
        return resolved(url: deciphered, format: format, response: response, tracking: response.playbackTracking,
                        videoId: videoId, source: .account, usedToken: false)
    }

    /// Tags `url` with a fresh content-playback nonce and packs the result. The
    /// same nonce goes into the history ping, so YouTube correlates the two and
    /// the play counts toward history.
    private func resolved(
        url: URL,
        format: PlayerResponse.Format,
        response: PlayerResponse,
        tracking: PlayerResponse.PlaybackTracking?,
        videoId: String,
        source: StreamSource,
        usedToken: Bool
    ) -> ResolvedStream {
        let cpn = WatchHistory.generateCPN()
        let url = WatchHistory.appendingCPN(to: url, cpn: cpn)
        PlaybackLog.note("resolved stream host=\(url.host ?? "?") source=\(source.rawValue)")
        return ResolvedStream(
            url: url,
            duration: response.videoDetails?.duration,
            historyURL: tracking?.playbackURL,
            watchtimeURL: tracking?.watchtimeURL,
            cpn: cpn,
            loudnessDb: format.loudnessDb ?? response.playerConfig?.audioConfig?.loudnessDb,
            videoId: videoId,
            source: source,
            usedToken: usedToken
        )
    }
```

(`playerResponse(…)`, `isTransient`, `checkPlayability`, `selectAudioFormat`, `pick` stay unchanged below.)

- [ ] **Step 3: Build and run the existing selection tests**

Run: Build command, then Test command with `StreamSelectionTests`.
Expected: `✅ Build succeeded`, tests PASS (or `** TEST BUILD SUCCEEDED **` without a GUI session).

- [ ] **Step 4: Live check of the request (no GUI needed)**

Run in the scratchpad (replicates `visionOSPlayer`; must print `OK` and `206`):

```bash
python3 - <<'EOF'
import json, urllib.request
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15'
def vis(vd=None):
    c={"clientName":"VISIONOS","clientVersion":"1.02","deviceMake":"Apple","deviceModel":"RealityDevice17,1","osName":"visionOS","osVersion":"26.5.23O471","hl":"en","gl":"US"}
    h={'Content-Type':'application/json','User-Agent':UA,'X-YouTube-Client-Name':'101','X-YouTube-Client-Version':'1.02','Origin':'https://www.youtube.com'}
    if vd: c['visitorData']=vd; h['X-Goog-Visitor-Id']=vd
    r=urllib.request.Request('https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false', json.dumps({"videoId":"eXrmLd5mer4","contentCheckOk":True,"racyCheckOk":True,"context":{"client":c,"user":{}}}).encode(), h)
    return json.load(urllib.request.urlopen(r, timeout=20))
d=vis(); d=vis(d['responseContext']['visitorData']); print(d['playabilityStatus']['status'])
u=[f['url'] for f in d['streamingData']['adaptiveFormats'] if f['itag']==140][0]
r=urllib.request.Request(u, headers={'Range':'bytes=1500000-1500001'}); print(urllib.request.urlopen(r, timeout=20).status)
EOF
```

- [ ] **Step 5: Commit**

```bash
git add "YT Music/InnerTube/StreamResolver.swift"
git commit -m "feat(playback): stream from visionOS, or the account for Premium

StreamResolver now tries the sources in the policy's order. Free and
signed-out accounts stream from the visionOS client: no token, no
deciphering, no web view. Accounts that offer Premium audio stream from
WEB_REMIX at 256 kbps, as before. Each source is the other's fallback.
The first track of a session waits at most 0.5 s for the account
response to tell Premium apart. Loudness is passed on from both sources.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: PlayerState — history URLs that arrive late

**Files:**
- Modify: `YT Music/Player/PlayerState.swift` (`armHistory`)
- Test: `YT MusicTests/LateHistoryTests.swift` (create)

**Interfaces:**
- Consumes: `ResolvedStream.lateTracking`, `PlaybackTracking.playbackURL/.watchtimeURL` (Tasks 1, 4); test helpers `FakeAudioOutput`, `FakeHistoryReporter`, `eventually` (existing in `PlayerTests.swift`).

- [ ] **Step 1: Write the failing tests**

Create `YT MusicTests/LateHistoryTests.swift`:

```swift
//
//  LateHistoryTests.swift
//  YT MusicTests
//
//  Tests for history stats URLs that arrive after the stream has started
//  (visionOS answers before the account's player response).
//

import Testing
import Foundation
@testable import YT_Music

/// Resolves at once and hands the stats URLs over only when `deliver` is called.
nonisolated final class LateTrackingResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<PlayerResponse.PlaybackTracking?, Never>] = []

    func audioStream(videoId: String, playlistId: String?, preferences: StreamPreferences) async throws -> ResolvedStream {
        var stream = ResolvedStream(url: URL(string: "https://stream.example.com/\(videoId).m4a")!,
                                    duration: 200, cpn: "NONCE0123456789")
        stream.lateTracking = Task {
            await withCheckedContinuation { continuation in
                self.lock.withLock { self.continuations.append(continuation) }
            }
        }
        return stream
    }

    var waiting: Int { lock.withLock { continuations.count } }

    /// Delivers stats URLs to the oldest stream still waiting for them.
    func deliver(videoId: String) {
        let tracking = PlayerResponse.PlaybackTracking(
            videostatsPlaybackUrl: .init(baseUrl: "https://music.youtube.com/api/stats/playback?docid=\(videoId)"),
            videostatsWatchtimeUrl: .init(baseUrl: "https://music.youtube.com/api/stats/watchtime?docid=\(videoId)")
        )
        let continuation = lock.withLock { continuations.removeFirst() }
        continuation.resume(returning: tracking)
    }
}

@Suite("Late history")
@MainActor
struct LateHistoryTests {
    private func tracks(_ ids: [String]) -> [Track] {
        ids.enumerated().map { index, id in
            Track(index: index + 1, title: id, subtitle: "Artist", duration: nil,
                  thumbnailURL: nil, videoId: id)
        }
    }

    @Test("The stream starts at once and history follows when its URLs arrive")
    func armsWhenTrackingArrives() async {
        let resolver = LateTrackingResolver()
        let reporter = FakeHistoryReporter()
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: resolver, historyReporter: reporter)
        player.play(tracks(["a"]), startAt: 0)
        await eventually { audio.loadCount == 1 && resolver.waiting == 1 }
        #expect(audio.loadCount == 1)

        audio.onProgress?(2, 200)
        await eventually { false }
        #expect(reporter.playbackStarts.isEmpty)

        resolver.deliver(videoId: "a")
        await eventually { false }
        audio.onProgress?(3, 200)
        await eventually { reporter.playbackStarts.count == 1 }
        #expect(reporter.playbackStarts.first?.url.query == "docid=a")
    }

    @Test("URLs arriving after the track changed are dropped")
    func dropsTrackingOfAnEarlierTrack() async {
        let resolver = LateTrackingResolver()
        let reporter = FakeHistoryReporter()
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio, resolver: resolver, historyReporter: reporter)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 && resolver.waiting == 1 }

        player.next()
        await eventually { audio.loadCount == 2 && resolver.waiting == 2 }
        resolver.deliver(videoId: "a")
        await eventually { false }
        audio.onProgress?(3, 200)
        await eventually { false }

        #expect(reporter.playbackStarts.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: Test command with `LateHistoryTests`. Expected: `armsWhenTrackingArrives` FAILS (no playback start reported).

- [ ] **Step 3: Implement**

In `PlayerState.swift`, replace the start of `private func armHistory(_ resolved: ResolvedStream) {` up to and including its first `guard` line with:

```swift
    private func armHistory(_ resolved: ResolvedStream) {
        // Stats URLs still on their way: arm once they arrive, unless another
        // track is playing by then.
        if let late = resolved.lateTracking {
            let videoId = nowPlaying?.videoId
            Task { [weak self] in
                let tracking = await late.value
                guard let self, self.nowPlaying?.videoId == videoId else { return }
                var stream = resolved
                stream.lateTracking = nil
                stream.historyURL = tracking?.playbackURL
                stream.watchtimeURL = tracking?.watchtimeURL
                self.armHistory(stream)
            }
            return
        }
        guard resolved.historyURL != nil || resolved.watchtimeURL != nil, resolved.cpn != nil else {
```

- [ ] **Step 4: Run to verify they pass**

Run: Test command with `LateHistoryTests`, then with `PlayerStateTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add "YT Music/Player/PlayerState.swift" "YT MusicTests/LateHistoryTests.swift"
git commit -m "feat(player): arm history when its URLs arrive after the stream

A visionOS stream starts before the account response with the stats
URLs is in. History is armed once they arrive, unless another track is
playing by then; it only reports after a few seconds of playback anyway.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: PR 1 gate — docs, full test run, live check

**Files:**
- Modify: `CLAUDE.md` (section "Playback / deciphering")

- [ ] **Step 1: Document the sources**

In `CLAUDE.md`, replace the bullet that starts with "- `StreamResolver` (actor) makes the `player` request" with:

```markdown
- `StreamResolver` (actor) tries the **stream sources** in the order `StreamSourcePolicy` gives and picks the highest-bitrate **AAC/MP4** format (AVPlayer can't decode Opus/WebM):
  - **visionOS** (`InnerTubeClient.visionOSPlayer`, values from yt-dlp's `visionos` client): anonymous, plain URLs, no signature/`n` solving and no PO token. Needs a `visitorData`: the first request answers `LOGIN_REQUIRED` with a fresh one, which is cached (`retryVisitorData`). Max 128 kbps AAC (itag 140); no private uploads, age-restricted or made-for-kids videos. yt-dlp added it in 2026-07 after `android_vr` started requiring tokens, so it may close some day.
  - **account** (WEB_REMIX with `sts`, deciphered in JavaScriptCore): googlevideo serves it in full without a PO token only to **Premium** accounts (yt-dlp `not_required_for_premium`, innertubex `premiumMayBypass`); free accounts get cut off after ~1 MB.
  - Automatic order: visionOS first; the account first when its latest response lists itag 141 (Premium audio, `StreamSession`) and quality is Auto/High. The first track of a session waits at most 0.5 s for the account response. The WEB_REMIX request always runs, because its stats URLs record the play in history (`ResolvedStream.lateTracking` when visionOS streams).
```

- [ ] **Step 2: Full test run (GUI session for `dev` required)**

Run: `mobilebuildmcp macos test --project-path "YT Music.xcodeproj" --scheme "YouTube Music" --extra-args 'CODE_SIGN_IDENTITY=-' --extra-args 'DEVELOPMENT_TEAM='`
Expected: all tests PASS. If the runner can't start, stop and ask the user to log in as `dev` (fast user switching); do not mark the PR done.

- [ ] **Step 3: Live check on the user's Mac**

Build Release, copy to `/Users/Shared/YTM-Test/YouTube Music (PR1).app` (`ditto`, `chmod -R a+rX`, `codesign --verify --deep`). Ask the user to play 3+ tracks and run as `user`:
`log show --last 15m --predicate 'subsystem == "moe.tenshii.YT-Music"' --style compact > /Users/Shared/YTM-Test/log.txt`
Expected in the log: `source order: visionOS, account (premium audio false, …)`, `visionOS playabilityStatus=OK`, `source=visionOS`, no `stream source … failed`; tracks appear in the YT Music history.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe the stream sources

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## PR 2 — `feat/stream-recovery`: reload after a mid-track failure, failure memory

### Task 7: AudioPlayer reports a stream that dies mid-track

**Files:**
- Modify: `YT Music/Player/AudioOutput.swift`
- Modify: `YT Music/Player/AudioPlayer.swift`
- Modify: `YT MusicTests/PlayerTests.swift` (`FakeAudioOutput`)

**Interfaces:**
- Produces: `AudioOutput.onStreamFailed: ((Double) -> Void)? { get set }` (default no-op in the protocol extension); `FakeAudioOutput.onStreamFailed` stored property.

- [ ] **Step 1: Create the branch**

```bash
git switch -c feat/stream-recovery feat/visionos-source
```

- [ ] **Step 2: Extend the protocol and the fake**

In `AudioOutput.swift`, after `var onTrackFinished: (() -> Void)? { get set }` add:

```swift
    /// Called with the position reached when the current item's stream dies
    /// before its end (dropped connection, expired or rejected URL), so the
    /// owner can reload it there. Without a handler that counts as the end.
    var onStreamFailed: ((Double) -> Void)? { get set }
```

In the `extension AudioOutput`, after `var onTogglePlayPause: …` add:

```swift
    var onStreamFailed: ((Double) -> Void)? { get { nil } set {} }
```

In `PlayerTests.swift`, in `FakeAudioOutput` after `var onTrackFinished: (() -> Void)?` add:

```swift
    var onStreamFailed: ((Double) -> Void)?
```

- [ ] **Step 3: Observe failures in AudioPlayer**

In `AudioPlayer.swift`:
- next to `@ObservationIgnored private var endObserver: NSObjectProtocol?` add `@ObservationIgnored private var failObserver: NSObjectProtocol?`
- next to `@ObservationIgnored var onTrackFinished: (() -> Void)?` add `@ObservationIgnored var onStreamFailed: ((Double) -> Void)?`
- at the end of `observeEnd(of:)` (after the `endObserver = …` statement) add:

```swift
        // A stream that dies mid-way (dropped connection, expired or rejected
        // URL) never reaches its end; reload or move on instead of sitting silent.
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                self?.streamFailed(error)
            }
        }
```

- before `/// Fires `onTrackFinished` exactly once per item.` add:

```swift
    /// Hands a stream that died before its end to `onStreamFailed` with the
    /// position reached. Within the last seconds, or without a handler, the
    /// track just counts as finished.
    private func streamFailed(_ error: Error?) {
        guard !hasSignalledEnd else { return }
        let position = currentTime
        PlaybackLog.problem("stream failed at \(Int(position))s: \(error?.localizedDescription ?? "unknown error")")
        guard let onStreamFailed, duration <= 0 || position < duration - 2 else {
            signalEnd()
            return
        }
        // The item is dead: its end must not advance the queue as well.
        hasSignalledEnd = true
        onStreamFailed(position)
    }
```

- [ ] **Step 4: Build**

Run: Build command. Expected: `✅ Build succeeded`.

- [ ] **Step 5: Commit**

```bash
git add "YT Music/Player/AudioOutput.swift" "YT Music/Player/AudioPlayer.swift" "YT MusicTests/PlayerTests.swift"
git commit -m "feat(player): report streams that die before their end

AVPlayer posts failedToPlayToEndTime when a stream breaks off (expired or
rejected URL, dropped connection); until now the track just hung. The
audio output reports the position reached so its owner can reload.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 8: PlayerState reloads at the position reached

**Files:**
- Modify: `YT Music/InnerTube/StreamResolver.swift` (protocol `StreamResolving`)
- Modify: `YT Music/Player/PlayerState.swift`
- Modify: `YT MusicTests/PlayerTests.swift` (`ResolverCalls`, `StubResolver`)
- Test: `YT MusicTests/StreamFailureTests.swift` (create)

**Interfaces:**
- Consumes: `AudioOutput.onStreamFailed` (Task 7), `ResolvedStream` fields (Task 4).
- Produces: `StreamResolving.streamFailed(_ stream: ResolvedStream) async` (default no-op); `PlayerState.loadStream(videoId:startAt:keepingHistory:)`; `ResolverCalls.failures: [URL]`.

- [ ] **Step 1: Extend the resolver protocol and the stub**

In `StreamResolver.swift`, inside `protocol StreamResolving` add:

```swift
    /// Tells the resolver a stream it returned died mid-track, before the
    /// player reloads it, so the next resolve can avoid the cause.
    func streamFailed(_ stream: ResolvedStream) async
```

and in `extension StreamResolving` add:

```swift
    func streamFailed(_ stream: ResolvedStream) async {}
```

In `PlayerTests.swift`, inside `ResolverCalls` add:

```swift
    private var _failures: [URL] = []
    func recordFailure(_ url: URL) { lock.withLock { _failures.append(url) } }
    var failures: [URL] { lock.withLock { _failures } }
```

and inside `StubResolver` add:

```swift
    func streamFailed(_ stream: ResolvedStream) async {
        calls.recordFailure(stream.url)
    }
```

- [ ] **Step 2: Write the failing tests**

Create `YT MusicTests/StreamFailureTests.swift`:

```swift
//
//  StreamFailureTests.swift
//  YT MusicTests
//
//  Tests for reloading a track whose stream dies mid-way (expired or rejected
//  URL) instead of skipping it.
//

import Testing
import Foundation
@testable import YT_Music

@Suite("Stream failure")
@MainActor
struct StreamFailureTests {
    private func tracks(_ ids: [String]) -> [Track] {
        ids.enumerated().map { index, id in
            Track(index: index + 1, title: id, subtitle: "Artist", duration: nil,
                  thumbnailURL: nil, videoId: id)
        }
    }

    @Test("A stream that dies while playing is reported and reloaded at the position reached")
    func reloadsAtPosition() async {
        let audio = FakeAudioOutput()
        let resolver = StubResolver()
        let player = PlayerState(audio: audio, resolver: resolver)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 }

        audio.onStreamFailed?(42)
        await eventually { audio.loadCount == 2 }

        #expect(resolver.calls.calls.map(\.videoId) == ["a", "a"])
        #expect(resolver.calls.failures == [resolver.url])   // reported before the reload resolved
        #expect(audio.seekedTo == 42)
        #expect(player.currentIndex == 0)
    }

    @Test("Dying again without progress skips to the next track")
    func skipsAfterRepeatedFailure() async {
        let audio = FakeAudioOutput()
        let resolver = StubResolver()
        let player = PlayerState(audio: audio, resolver: resolver)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 }

        audio.onStreamFailed?(42)
        await eventually { audio.loadCount == 2 }
        audio.onStreamFailed?(45)
        await eventually { audio.loadCount == 3 }

        #expect(resolver.calls.calls.map(\.videoId) == ["a", "a", "b"])
        #expect(player.currentIndex == 1)
    }

    @Test("A stream that dies while paused reloads only on the next play")
    func waitsForPlayWhenPaused() async {
        let audio = FakeAudioOutput()
        let resolver = StubResolver()
        let player = PlayerState(audio: audio, resolver: resolver)
        player.play(tracks(["a", "b"]), startAt: 0)
        await eventually { audio.loadCount == 1 }
        player.togglePlayPause()
        #expect(!audio.isPlaying)

        audio.onStreamFailed?(42)
        await eventually { false }
        #expect(audio.loadCount == 1)

        player.seek(to: 50)                       // moves where it will resume
        player.togglePlayPause()
        await eventually { audio.loadCount == 2 }
        #expect(resolver.calls.calls.map(\.videoId) == ["a", "a"])
        #expect(audio.seekedTo == 50)
        #expect(audio.isPlaying)
    }

    @Test("A reload doesn't report the play to history a second time")
    func reloadKeepsHistory() async {
        let reporter = FakeHistoryReporter()
        let audio = FakeAudioOutput()
        let player = PlayerState(audio: audio,
                                 resolver: StubResolver(duration: 200,
                                                        historyURL: URL(string: "https://m.youtube.com/p")!,
                                                        watchtimeURL: URL(string: "https://m.youtube.com/w")!,
                                                        cpn: "NONCE0123456789"),
                                 historyReporter: reporter)
        player.play(tracks(["a"]), startAt: 0)
        await eventually { audio.loadCount == 1 }
        audio.onProgress?(5, 200)
        await eventually { reporter.playbackStarts.count == 1 }

        audio.onStreamFailed?(42)
        await eventually { audio.loadCount == 2 }
        audio.onProgress?(43, 200)
        await eventually { false }

        #expect(reporter.playbackStarts.count == 1)
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: Test command with `StreamFailureTests`. Expected: FAIL (no reload: `loadCount` stays 1).

- [ ] **Step 4: Implement in PlayerState**

In `PlayerState.swift`:

After `private var restoredDuration: Double = 0` add:

```swift
    /// The stream the engine is playing, so a mid-track failure can be
    /// reported to the resolver.
    private var currentStream: ResolvedStream?
    /// Where the current track's stream last died, so a reload that fails
    /// again without progress skips the track instead of looping.
    private var lastStreamFailure: (videoId: String, position: Double)?
    /// Set when the current track's stream died while paused: the next play
    /// reloads it from here.
    private var reloadOnResume: Double?
    /// How much further (seconds) a reloaded stream must get before another
    /// failure is reloaded again rather than skipped.
    private static let streamFailureProgress: Double = 10
```

In `init`, after `self.audio.onTrackFinished = …` add:

```swift
        self.audio.onStreamFailed = { [weak self] position in self?.handleStreamFailure(at: position) }
```

In `togglePlayPause()`, after the `if awaitingResume { … }` block add:

```swift
        // The paused track's stream died meanwhile; play reloads it.
        if let position = reloadOnResume {
            reloadOnResume = nil
            reloadCurrentStream(at: position)
            return
        }
```

At the start of `seek(to:)` add:

```swift
        if reloadOnResume != nil { reloadOnResume = max(0, seconds) }
```

Before `private func handleTrackFinished() {` add:

```swift
    /// Reloads a track whose stream died mid-way (typically a URL that expired
    /// during a long pause) at the position reached, after telling the resolver
    /// which stream failed. If it dies again without getting further, it is
    /// skipped as before.
    private func handleStreamFailure(at position: Double) {
        if crossfadeLoading { return }
        guard let videoId = nowPlaying?.videoId else { return }
        let failed = currentStream
        currentStream = nil
        if let last = lastStreamFailure, last.videoId == videoId,
           position < last.position + Self.streamFailureProgress {
            if let failed { Task { await resolver.streamFailed(failed) } }
            handleTrackFinished()
            return
        }
        lastStreamFailure = (videoId, position)
        // Loading starts playback, so a track that died while paused waits
        // for the next play instead of starting on its own.
        if audio.isPlaying {
            reloadCurrentStream(at: position, after: failed)
        } else {
            if let failed { Task { await resolver.streamFailed(failed) } }
            reloadOnResume = position
        }
    }

    /// Reloads the current track at `position`. A failed stream is reported
    /// first, so the resolver can avoid its cause on this very resolve.
    private func reloadCurrentStream(at position: Double, after failed: ResolvedStream? = nil) {
        guard let videoId = nowPlaying?.videoId else { return }
        if preparedVideoId == videoId {
            preparedVideoId = nil
            preparedStream = nil
        }
        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            if let failed { await resolver.streamFailed(failed) }
            await loadStream(videoId: videoId, startAt: position, keepingHistory: true)
        }
    }
```

In `startTrack(…)`, after `awaitingResume = false` add:

```swift
        lastStreamFailure = nil
        reloadOnResume = nil
        currentStream = nil
```

Change the signature and history line of `loadStream`:

```swift
    /// Resolves the stream and hands it to the audio engine. Split out from
    /// `startTrack` so tests can await it directly (no Task race).
    /// `keepingHistory` reloads the playing track without reporting it to
    /// history a second time.
    func loadStream(videoId: String, startAt position: Double? = nil, keepingHistory: Bool = false) async {
```

and inside it replace `armHistory(resolved)` with:

```swift
            currentStream = resolved
            if !keepingHistory { armHistory(resolved) }
```

In the crossfade load path (the second `armHistory(resolved)` call, inside `loadCrossfade`), add `currentStream = resolved` on the line before it.

- [ ] **Step 5: Run to verify they pass**

Run: Test command with `StreamFailureTests`, then `PlayerStateTests`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "YT Music/InnerTube/StreamResolver.swift" "YT Music/Player/PlayerState.swift" "YT MusicTests/PlayerTests.swift" "YT MusicTests/StreamFailureTests.swift"
git commit -m "fix(player): reload a stream that dies mid-track instead of hanging

The track is reported to the resolver, re-resolved once and resumes where
it stopped; if it dies again without getting further, it is skipped. A
stream that dies while paused reloads on the next play, so nothing starts
on its own, and the reload is not reported to history twice.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 9: Failure classification and the 10-minute memory

**Files:**
- Modify: `YT Music/InnerTube/StreamSourcePolicy.swift`
- Modify: `YT Music/InnerTube/StreamResolver.swift`
- Test: `YT MusicTests/StreamPolicyTests.swift`

**Interfaces:**
- Consumes: `ResolvedStream.videoId/.source/.resolvedAt` (Task 4), `StreamResolving.streamFailed` (Task 8).
- Produces: `enum StreamFailure: Equatable { case expired, sourceFailed(StreamSource) }`; `StreamSourcePolicy.classify(_ stream: ResolvedStream, at now: Date) -> StreamFailure?`; `StreamSourcePolicy.expiryAge: TimeInterval = 3600`; `struct StreamFailureMemory: Sendable` with `static let lifetime: TimeInterval = 600`, `mutating func record(_ source: StreamSource, videoId: String, at now: Date)`, `func excluded(for videoId: String, at now: Date) -> Set<StreamSource>`; `StreamSession.failures: StreamFailureMemory`.

- [ ] **Step 1: Write the failing tests**

Append inside `struct StreamPolicyTests`:

```swift
    private func stream(source: StreamSource, age: TimeInterval, now: Date) -> ResolvedStream {
        var stream = ResolvedStream(url: URL(string: "https://rr1.googlevideo.com/videoplayback")!, duration: 200)
        stream.videoId = "a"
        stream.source = source
        stream.resolvedAt = now.addingTimeInterval(-age)
        return stream
    }

    @Test("A stream older than an hour counts as expired, not as a failing source")
    func oldStreamCountsAsExpired() {
        let now = Date()
        #expect(StreamSourcePolicy.classify(stream(source: .visionOS, age: 3700, now: now), at: now) == .expired)
        #expect(StreamSourcePolicy.classify(stream(source: .visionOS, age: 60, now: now), at: now)
            == .sourceFailed(.visionOS))
        #expect(StreamSourcePolicy.classify(stream(source: .account, age: 60, now: now), at: now)
            == .sourceFailed(.account))

        var unknown = stream(source: .visionOS, age: 60, now: now)
        unknown.source = nil
        #expect(StreamSourcePolicy.classify(unknown, at: now) == nil)
    }

    @Test("Failure memory is per video and expires after 10 minutes")
    func failureMemoryIsPerVideoAndExpires() {
        let now = Date()
        var memory = StreamFailureMemory()
        memory.record(.visionOS, videoId: "a", at: now)

        #expect(memory.excluded(for: "a", at: now.addingTimeInterval(60)) == [.visionOS])
        #expect(memory.excluded(for: "b", at: now.addingTimeInterval(60)).isEmpty)
        #expect(memory.excluded(for: "a", at: now.addingTimeInterval(601)).isEmpty)

        memory.record(.account, videoId: "a", at: now.addingTimeInterval(30))
        #expect(memory.excluded(for: "a", at: now.addingTimeInterval(60)) == [.visionOS, .account])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: Test command with `StreamPolicyTests`. Expected: build FAILS, "cannot find 'StreamFailureMemory' in scope".

- [ ] **Step 3: Implement the policy**

Append to `StreamSourcePolicy.swift`:

```swift

/// Why a stream died mid-track.
nonisolated enum StreamFailure: Equatable, Sendable {
    /// The URL outlived googlevideo's expiry (e.g. a long pause): the source is fine.
    case expired
    /// The source served a stream that broke off.
    case sourceFailed(StreamSource)
}

extension StreamSourcePolicy {
    /// A stream older than this has most likely just expired.
    static let expiryAge: TimeInterval = 3600

    /// Classifies a stream that died mid-track; nil when its source is unknown.
    static func classify(_ stream: ResolvedStream, at now: Date) -> StreamFailure? {
        guard let source = stream.source else { return nil }
        if now.timeIntervalSince(stream.resolvedAt) > expiryAge { return .expired }
        return .sourceFailed(source)
    }
}

/// Sources that broke off for a video recently, skipped for that video for a
/// while (like Metrolist's `streamClientFailures`). Nothing outlives the session.
nonisolated struct StreamFailureMemory: Sendable {
    static let lifetime: TimeInterval = 600

    private var entries: [String: [StreamSource: Date]] = [:]

    mutating func record(_ source: StreamSource, videoId: String, at now: Date) {
        entries[videoId, default: [:]][source] = now
    }

    func excluded(for videoId: String, at now: Date) -> Set<StreamSource> {
        Set((entries[videoId] ?? [:]).filter { now.timeIntervalSince($0.value) < Self.lifetime }.keys)
    }
}
```

Inside `struct StreamSession`, after `private(set) var premiumAudio: Bool?` add:

```swift
    /// Sources to skip for a video after its stream broke off.
    var failures = StreamFailureMemory()
```

- [ ] **Step 4: Apply it in the resolver**

In `StreamResolver.swift`:

Replace the line `let order = StreamSourcePolicy.automaticOrder(…)` with:

```swift
        let excluded = session.failures.excluded(for: videoId, at: Date())
        let preferred = StreamSourcePolicy.automaticOrder(quality: preferences.audioQuality, premiumAudio: premiumAudio)
        // Never skip everything: with every source excluded, try them all again.
        let remaining = preferred.filter { !excluded.contains($0) }
        let order = remaining.isEmpty ? preferred : remaining
```

Add to the actor (e.g. after `audioStream`):

```swift
    func streamFailed(_ stream: ResolvedStream) async {
        guard let videoId = stream.videoId,
              let failure = StreamSourcePolicy.classify(stream, at: Date()) else { return }
        switch failure {
        case .expired:
            PlaybackLog.note("stream for \(videoId) expired; re-resolving with the same order")
        case .sourceFailed(let source):
            session.failures.record(source, videoId: videoId, at: Date())
            PlaybackLog.problem("stream source \(source.rawValue) broke off for \(videoId); skipping it for 10 min")
        }
    }
```

- [ ] **Step 5: Run to verify they pass**

Run: Test command with `StreamPolicyTests`, then `StreamFailureTests`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "YT Music/InnerTube/StreamSourcePolicy.swift" "YT Music/InnerTube/StreamResolver.swift" "YT MusicTests/StreamPolicyTests.swift"
git commit -m "feat(playback): skip a source that broke off, for that track

A stream older than an hour just expired and is re-resolved as before.
Otherwise its source is skipped for that video for 10 minutes, so the
reload comes from the other source. Nothing is kept beyond the session.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 10: PR 2 gate

- [ ] **Step 1:** In `CLAUDE.md`, in the Gotchas section, add:

```markdown
- **Mid-track stream failures are recovered, not skipped.** `AudioPlayer` turns `failedToPlayToEndTime` into `onStreamFailed(position)`; `PlayerState` reports the stream to `StreamResolving.streamFailed` and reloads at that position (while paused: on the next play). A second failure without 10 s of progress skips the track. The resolver treats streams older than 1 h as expired and otherwise skips the failed source for that video for 10 min (`StreamFailureMemory`).
```

- [ ] **Step 2:** Full test run (GUI session), as in Task 6 Step 2. Expected: all PASS.
- [ ] **Step 3:** Commit: `git add CLAUDE.md && git commit -m "docs: describe stream failure recovery" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`

---

## PR 3 — `feat/po-token-fallback`: PO token for the account source

### Task 11: Bring in the PO token provider and page config

**Files (from the archived branch `fix/playback-po-token`):**
- Create: `YT Music/InnerTube/PoTokenProvider.swift`, `YT MusicTests/PoTokenTests.swift`
- Modify: `YT Music/InnerTube/InnerTubeClient.swift` (`PlayerPageConfig`, `playerPageConfig()`)

**Interfaces:**
- Produces: `PoTokenProvider.shared.token(for binding: String) async throws -> String` (`@MainActor`); `InnerTubeClient.playerPageConfig() async throws -> PlayerPageConfig` with `dataSyncId: String?`, `bindsToVideoId: Bool`; `StreamResolver.appendingPoToken(_ token: String?, to url: URL) -> URL` (static, nonisolated).

- [ ] **Step 1: Create the branch and cherry-pick**

```bash
git switch -c feat/po-token-fallback feat/stream-recovery
git cherry-pick 18ec971 b2f96a2 f6ff07a
```

Conflicts to expect:
- `18ec971` also adds `responseContext` to `PlayerResponse`, which Task 1 already added: keep the Task 1 version (`git checkout --ours "YT Music/InnerTube/PlayerResponse.swift"`), `git add` it, `git cherry-pick --continue`.
- `f6ff07a` edits a `CLAUDE.md` line that doesn't exist on this base: keep the current file (`git checkout --ours CLAUDE.md`), `git add`, continue. Task 13 documents the token.

Do **not** cherry-pick `baecf1d` (its resolver wiring is replaced by Task 12).

- [ ] **Step 1b: Add `appendingPoToken`, which `PoTokenTests` already uses**

In `StreamResolver.swift`, inside the actor (e.g. after `checkPlayability`), add:

```swift
    /// Adds `pot` to a stream URL (no-op for a nil token). `nonisolated` so it
    /// can be unit-tested without the actor hop.
    nonisolated static func appendingPoToken(_ token: String?, to url: URL) -> URL {
        guard let token, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = (components.queryItems ?? []).filter { $0.name != "pot" }
        items.append(URLQueryItem(name: "pot", value: token))
        components.queryItems = items
        return components.url ?? url
    }
```

- [ ] **Step 2: Remove the provider's outdated header sentence**

In `PoTokenProvider.swift`, replace the header paragraph that starts with "All four steps run in one short-lived web view" with:

```swift
//  All four steps run in one short-lived web view per binding (~0.5 s); the
//  token is cached until it expires. Only the account source needs it, and only
//  when the account isn't Premium (see StreamSourcePolicy). Reference
//  implementations: LuanRT/BgUtils (MIT) and NewPipe's
```

- [ ] **Step 3: Run the token tests**

Run: Test command with `PoTokenTests`. Expected: PASS (or TEST BUILD SUCCEEDED).

- [ ] **Step 4: Commit** (the header edit and `appendingPoToken`)

```bash
git add "YT Music/InnerTube/PoTokenProvider.swift" "YT Music/InnerTube/StreamResolver.swift"
git commit -m "feat(playback): add pot to stream URLs; note when the token is needed

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 12: Token decision for the account source

**Files:**
- Modify: `YT Music/InnerTube/StreamSourcePolicy.swift`
- Modify: `YT Music/InnerTube/StreamResolver.swift`
- Modify: `YT Music/InnerTube/InnerTubeClient.swift` (`streamPlaysPastFirstMegabyte`)
- Test: `YT MusicTests/StreamPolicyTests.swift`

**Interfaces:**
- Consumes: Task 11, `StreamSession` (Task 3), `StreamFailure` (Task 9).
- Produces: `enum AccountTokenPlan: Equatable { case tokenFree, probeThenDecide, mint }`; `StreamSourcePolicy.accountTokenPlan(premiumAudio: Bool, tokenFreeRejected: Bool, tokenFreeWorks: Bool?) -> AccountTokenPlan`; `StreamFailure.tokenFreeRejected`; `StreamSession.tokenFreeRejected: Bool`, `StreamSession.tokenFreeWorks: Bool?`; `InnerTubeClient.streamPlaysPastFirstMegabyte(_ url: URL) async -> Bool?`.

- [ ] **Step 1: Write the failing tests**

Append inside `struct StreamPolicyTests`:

```swift
    @Test("Only Premium accounts try without a token, and only until it was rejected")
    func accountTokenPlan() {
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: false, tokenFreeRejected: false, tokenFreeWorks: nil) == .mint)
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: true, tokenFreeRejected: false, tokenFreeWorks: nil) == .probeThenDecide)
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: true, tokenFreeRejected: false, tokenFreeWorks: true) == .tokenFree)
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: true, tokenFreeRejected: false, tokenFreeWorks: false) == .mint)
        #expect(StreamSourcePolicy.accountTokenPlan(premiumAudio: true, tokenFreeRejected: true, tokenFreeWorks: true) == .mint)
    }

    @Test("A token-free account stream that broke off means the account needs a token")
    func tokenFreeFailureIsClassified() {
        let now = Date()
        var tokenFree = stream(source: .account, age: 60, now: now)
        tokenFree.usedToken = false
        #expect(StreamSourcePolicy.classify(tokenFree, at: now) == .tokenFreeRejected)

        var minted = stream(source: .account, age: 60, now: now)
        minted.usedToken = true
        #expect(StreamSourcePolicy.classify(minted, at: now) == .sourceFailed(.account))
    }
```

In the existing test `oldStreamCountsAsExpired`, change the account expectation to use a minted stream:

```swift
        var mintedAccount = stream(source: .account, age: 60, now: now)
        mintedAccount.usedToken = true
        #expect(StreamSourcePolicy.classify(mintedAccount, at: now) == .sourceFailed(.account))
```

(replacing the line `#expect(StreamSourcePolicy.classify(stream(source: .account, age: 60, now: now), at: now) == .sourceFailed(.account))`).

- [ ] **Step 2: Run to verify they fail**

Run: Test command with `StreamPolicyTests`. Expected: build FAILS, "type 'StreamFailure' has no member 'tokenFreeRejected'".

- [ ] **Step 3: Implement the policy**

In `StreamSourcePolicy.swift`:
- add the case to `StreamFailure`:

```swift
    /// A token-free account stream broke off: the Premium exemption no longer
    /// applies, so the account needs a token for the rest of the session.
    case tokenFreeRejected
```

- in `classify`, after the expiry check, add:

```swift
        if source == .account && !stream.usedToken { return .tokenFreeRejected }
```

- in `StreamSession`, after `var failures = StreamFailureMemory()` add:

```swift
    /// A token-free account stream was rejected this session.
    var tokenFreeRejected = false
    /// Result of the one-off probe whether token-free account streams play in
    /// full; nil until probed (or after an inconclusive probe).
    var tokenFreeWorks: Bool?
```

- append:

```swift

/// How the account source gets a stream that plays in full.
nonisolated enum AccountTokenPlan: Equatable, Sendable {
    /// Premium, and known to work without a token.
    case tokenFree
    /// Premium, not probed yet: probe once, then go token-free or mint.
    case probeThenDecide
    /// Mint a PO token in a web view.
    case mint
}

extension StreamSourcePolicy {
    static func accountTokenPlan(premiumAudio: Bool, tokenFreeRejected: Bool, tokenFreeWorks: Bool?) -> AccountTokenPlan {
        guard premiumAudio, !tokenFreeRejected else { return .mint }
        switch tokenFreeWorks {
        case true?:  return .tokenFree
        case false?: return .mint
        case nil:    return .probeThenDecide
        }
    }
}
```

- [ ] **Step 4: Add the probe to the client**

In `InnerTubeClient.swift`, before `func visionOSPlayer(` add:

```swift
    /// Whether googlevideo serves `url` past its first ~1 MB, the point where a
    /// stream without a valid PO token gets cut off with 403. nil when that
    /// can't be told (e.g. the track is shorter, or the request failed).
    func streamPlaysPastFirstMegabyte(_ url: URL) async -> Bool? {
        var request = URLRequest(url: url)
        request.setValue("bytes=1500000-1500001", forHTTPHeaderField: "Range")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        switch status {
        case 206: return true
        case 403: return false
        default:  return nil
        }
    }

```

- [ ] **Step 5: Use the plan in the resolver**

In `StreamResolver.swift`, in `accountStream(…)` replace

```swift
        let deciphered = try await decipher.streamURL(for: format)
        return resolved(url: deciphered, format: format, response: response, tracking: response.playbackTracking,
                        videoId: videoId, source: .account, usedToken: false)
```

with:

```swift
        let deciphered = try await decipher.streamURL(for: format)
        let token = try await accountToken(videoId: videoId, response: response, url: deciphered)
        return resolved(url: Self.appendingPoToken(token, to: deciphered), format: format, response: response,
                        tracking: response.playbackTracking, videoId: videoId, source: .account,
                        usedToken: token != nil)
```

and add to the actor:

```swift
    /// The PO token the account stream needs, or nil when it plays in full
    /// without one (Premium, verified once per session by a probe).
    private func accountToken(videoId: String, response: PlayerResponse, url: URL) async throws -> String? {
        let plan = StreamSourcePolicy.accountTokenPlan(
            premiumAudio: session.premiumAudio ?? false,
            tokenFreeRejected: session.tokenFreeRejected,
            tokenFreeWorks: session.tokenFreeWorks
        )
        switch plan {
        case .tokenFree:
            return nil
        case .probeThenDecide:
            if let works = await client.streamPlaysPastFirstMegabyte(url) {
                session.tokenFreeWorks = works
                PlaybackLog.note("potoken: Premium streams \(works ? "play" : "don't play") without a token")
                if works { return nil }
            }
        case .mint:
            break
        }
        let config = await currentPageConfig()
        let binding: String? = config.bindsToVideoId
            ? videoId
            : config.dataSyncId ?? response.responseContext?.visitorData
        guard let binding else {
            throw StreamError.notPlayable("no session to bind a stream token to")
        }
        return try await PoTokenProvider.shared.token(for: binding)
    }
```

Add `currentPageConfig()` and its stored property (`appendingPoToken` came in Task 11):

```swift
    /// The page config deciding PO token bindings, keyed by the SAPISID it was
    /// read with (nil = signed out) so a sign-in change re-reads it.
    private var pageConfig: (sapisid: String?, config: PlayerPageConfig)?

    /// The YT Music page config, read once per sign-in state. A failed read
    /// falls back to binding by video id, the binding YouTube currently uses.
    private func currentPageConfig() async -> PlayerPageConfig {
        let sapisid = await CredentialStore.shared.credentials?.sapisid
        if let pageConfig, pageConfig.sapisid == sapisid { return pageConfig.config }

        let config: PlayerPageConfig
        do {
            config = try await client.playerPageConfig()
            PlaybackLog.note("potoken: bind to \(config.bindsToVideoId ? "video id" : config.dataSyncId != nil ? "account" : "visitor")")
            pageConfig = (sapisid, config)
        } catch {
            PlaybackLog.problem("potoken: page config unavailable (\(error.localizedDescription))")
            config = PlayerPageConfig(dataSyncId: nil, bindsToVideoId: true)
        }
        return config
    }
```

In `streamFailed(_:)`, add the new case:

```swift
        case .tokenFreeRejected:
            session.tokenFreeRejected = true
            PlaybackLog.problem("token-free account stream rejected; using a token for this session")
```

- [ ] **Step 6: Run to verify they pass**

Run: Test command with `StreamPolicyTests`, then `PoTokenTests`. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add "YT Music/InnerTube/StreamSourcePolicy.swift" "YT Music/InnerTube/StreamResolver.swift" "YT Music/InnerTube/InnerTubeClient.swift" "YT MusicTests/StreamPolicyTests.swift"
git commit -m "feat(playback): mint a PO token when the account stream needs one

Free accounts streaming from the account source (uploads, restricted
tracks, or when visionOS fails) now get a BotGuard PO token, so the
stream no longer breaks off after the first megabyte. Premium accounts
stay token-free: one probe per session confirms it, and a token-free
stream that breaks off switches the session to tokens.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 13: PR 3 gate

- [ ] **Step 1:** In `CLAUDE.md`, add after the account bullet from Task 6:

```markdown
  - **PO token** (`PoTokenProvider`, BotGuard in a short-lived hidden `WKWebView`, Safari UA, binding per `PlayerPageConfig`): used only by the account source when the account isn't Premium (`AccountTokenPlan`). Premium accounts are probed once per session (`streamPlaysPastFirstMegabyte`, ranged GET at 1.5 MB → 206/403); a token-free stream that breaks off sets `tokenFreeRejected` for the session.
```

- [ ] **Step 2:** Full test run (GUI session). Expected: all PASS.
- [ ] **Step 3:** Live check: build PR3 to `/Users/Shared/YTM-Test`. There is no setting yet to force the account source, so play an own upload if the user has one; expected log `potoken: minted` and full playback. Without an upload, report that this path is covered by unit tests plus the earlier live test of `fix/playback-po-token` (six tracks minted and played in full on 2026-10-07), and re-check it in Task 16 with Custom mode.
- [ ] **Step 4:** Commit `CLAUDE.md` ("docs: describe the PO token fallback").

---

## PR 4 — `feat/stream-source-settings`: Automatic / Custom and status

### Task 14: Settings model — mode and custom order

**Files:**
- Modify: `YT Music/Settings/AppSettings.swift`
- Modify: `YT Music/InnerTube/StreamSourcePolicy.swift`
- Modify: `YT Music/InnerTube/StreamResolver.swift` (order line)
- Test: `YT MusicTests/StreamPolicyTests.swift`

**Interfaces:**
- Produces: `enum StreamSourceMode: String, Codable, CaseIterable, Sendable, Identifiable { case automatic, custom }` with `label`; `struct StreamSourceEntry: Codable, Hashable, Sendable, Identifiable { var source: StreamSource; var isEnabled = true }` with `static let defaults`, `static func normalized(_:) -> [StreamSourceEntry]`; `StreamSource.title`, `.summary`; `StreamPreferences.sourceMode`, `.customSources`; `AppSettings.streamSourceMode`, `.customStreamSources`; `StreamSourcePolicy.order(mode:custom:quality:premiumAudio:) -> [StreamSource]`.

- [ ] **Step 1: Create the branch**

```bash
git switch -c feat/stream-source-settings feat/po-token-fallback
```

- [ ] **Step 2: Write the failing tests**

Append inside `struct StreamPolicyTests`:

```swift
    @Test("Custom mode uses the enabled sources in the user's order")
    func customOrder() {
        let custom = [StreamSourceEntry(source: .account), StreamSourceEntry(source: .visionOS)]
        #expect(StreamSourcePolicy.order(mode: .custom, custom: custom, quality: .auto, premiumAudio: false)
            == [.account, .visionOS])

        let accountOnly = [StreamSourceEntry(source: .visionOS, isEnabled: false), StreamSourceEntry(source: .account)]
        #expect(StreamSourcePolicy.order(mode: .custom, custom: accountOnly, quality: .auto, premiumAudio: false)
            == [.account])

        #expect(StreamSourcePolicy.order(mode: .automatic, custom: accountOnly, quality: .auto, premiumAudio: false)
            == [.visionOS, .account])
    }

    @Test("Custom mode with nothing enabled falls back to automatic")
    func customWithNothingEnabled() {
        let none = StreamSource.allCases.map { StreamSourceEntry(source: $0, isEnabled: false) }
        #expect(StreamSourcePolicy.order(mode: .custom, custom: none, quality: .auto, premiumAudio: true)
            == [.account, .visionOS])
    }

    @Test("A stored order is repaired: no duplicates, new sources added, one always on")
    func normalizesStoredOrder() {
        #expect(StreamSourceEntry.normalized([]) == StreamSourceEntry.defaults)

        let duplicated = [StreamSourceEntry(source: .account), StreamSourceEntry(source: .account, isEnabled: false)]
        #expect(StreamSourceEntry.normalized(duplicated)
            == [StreamSourceEntry(source: .account), StreamSourceEntry(source: .visionOS)])

        let allOff = [
            StreamSourceEntry(source: .account, isEnabled: false),
            StreamSourceEntry(source: .visionOS, isEnabled: false),
        ]
        #expect(StreamSourceEntry.normalized(allOff)
            == [StreamSourceEntry(source: .account), StreamSourceEntry(source: .visionOS, isEnabled: false)])
    }

    @Test("Automatic is the default")
    func automaticIsDefault() {
        #expect(StreamPreferences().sourceMode == .automatic)
        #expect(StreamPreferences().customSources == StreamSourceEntry.defaults)
    }
```

- [ ] **Step 3: Run to verify they fail**

Run: Test command with `StreamPolicyTests`. Expected: build FAILS, "cannot find 'StreamSourceEntry' in scope".

- [ ] **Step 4: Implement the model**

In `AppSettings.swift`, before `/// The subset of settings the (nonisolated) stream resolver needs.` insert:

```swift
/// How the resolver picks where a track's stream comes from (see `StreamSource`).
nonisolated enum StreamSourceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// visionOS first, the account first when it offers Premium audio.
    case automatic
    /// The user's own order of `StreamSourceEntry`s.
    case custom

    var id: Self { self }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .custom:    "Custom"
        }
    }
}

/// One row of the custom stream source order.
nonisolated struct StreamSourceEntry: Codable, Hashable, Sendable, Identifiable {
    var source: StreamSource
    var isEnabled = true

    var id: StreamSource { source }

    static let defaults = StreamSource.allCases.map { StreamSourceEntry(source: $0) }

    /// Repairs a stored order: drops duplicates, appends sources added since
    /// (enabled), and keeps at least one source enabled.
    static func normalized(_ entries: [StreamSourceEntry]) -> [StreamSourceEntry] {
        var seen = Set<StreamSource>()
        var result = entries.filter { seen.insert($0.source).inserted }
        result += StreamSource.allCases.filter { !seen.contains($0) }.map { StreamSourceEntry(source: $0) }
        if !result.contains(where: \.isEnabled) { result[0].isEnabled = true }
        return result
    }
}

extension StreamSource {
    var title: String {
        switch self {
        case .visionOS: "visionOS"
        case .account:  "YouTube Music account"
        }
    }

    var summary: String {
        switch self {
        case .visionOS: "No sign-in · up to 128 kbps · no web view"
        case .account:  "Signed in · up to 256 kbps with Premium · plays uploads"
        }
    }
}

```

Inside `struct StreamPreferences`, after `var preferAudioOverVideo: Bool = true` add:

```swift
    var sourceMode: StreamSourceMode = .automatic
    var customSources: [StreamSourceEntry] = StreamSourceEntry.defaults
```

In `final class AppSettings`, after the `preferAudioOverVideo` property add:

```swift

    var streamSourceMode: StreamSourceMode {
        didSet { store(streamSourceMode.rawValue, for: .streamSourceMode) }
    }

    /// The order and on/off state of the sources in custom mode.
    var customStreamSources: [StreamSourceEntry] {
        didSet {
            let normalized = StreamSourceEntry.normalized(customStreamSources)
            if normalized != customStreamSources { customStreamSources = normalized; return }
            store(try? JSONEncoder().encode(customStreamSources), for: .customStreamSources)
        }
    }
```

In `streamPreferences`, pass the new fields:

```swift
        StreamPreferences(audioQuality: audioQuality,
                          preferAudioOverVideo: preferAudioOverVideo,
                          sourceMode: streamSourceMode,
                          customSources: customStreamSources)
```

In `init`, after the `preferAudioOverVideo` line add:

```swift
        self.streamSourceMode = (defaults.string(forKey: Key.streamSourceMode.rawValue)
            .flatMap(StreamSourceMode.init)) ?? .automatic
        self.customStreamSources = StreamSourceEntry.normalized(
            defaults.data(forKey: Key.customStreamSources.rawValue)
                .flatMap { try? JSONDecoder().decode([StreamSourceEntry].self, from: $0) } ?? []
        )
```

In `enum Key`, after `preferAudioOverVideo` add:

```swift
        case streamSourceMode    = "settings.streamSourceMode"
        case customStreamSources = "settings.customStreamSources"
```

In `StreamSourcePolicy.swift`, inside `enum StreamSourcePolicy` add:

```swift
    /// The order to try the sources in: the automatic order, or the user's
    /// enabled sources (falling back to automatic if none is enabled).
    static func order(
        mode: StreamSourceMode,
        custom: [StreamSourceEntry],
        quality: AudioQuality,
        premiumAudio: Bool
    ) -> [StreamSource] {
        if mode == .custom {
            let enabled = custom.filter(\.isEnabled).map(\.source)
            if !enabled.isEmpty { return enabled }
        }
        return automaticOrder(quality: quality, premiumAudio: premiumAudio)
    }
```

In `StreamResolver.audioStream`, replace

```swift
        let preferred = StreamSourcePolicy.automaticOrder(quality: preferences.audioQuality, premiumAudio: premiumAudio)
```

with:

```swift
        let preferred = StreamSourcePolicy.order(
            mode: preferences.sourceMode,
            custom: preferences.customSources,
            quality: preferences.audioQuality,
            premiumAudio: premiumAudio
        )
```

and in `premiumAudio(awaiting:)`, only wait on the first track in Automatic mode — change its signature to `premiumAudio(awaiting accountResponse: Task<PlayerResponse, Error>, waits: Bool)`, replace the line `guard let response = await value(…)` block's condition with:

```swift
        guard waits, let response = await awaitValue(of: accountResponse, within: Self.firstTrackDeadline) else {
            if waits { PlaybackLog.note("account response not there in time; assuming no Premium audio for this track") }
            return false
        }
```

and call it with `waits: preferences.sourceMode == .automatic`.

- [ ] **Step 5: Run to verify they pass**

Run: Test command with `StreamPolicyTests`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "YT Music/Settings/AppSettings.swift" "YT Music/InnerTube/StreamSourcePolicy.swift" "YT Music/InnerTube/StreamResolver.swift" "YT MusicTests/StreamPolicyTests.swift"
git commit -m "feat(settings): store an automatic or custom stream source order

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 15: Streaming section, status, and the all-failed hint

**Files:**
- Create: `YT Music/Player/StreamStatus.swift`
- Modify: `YT Music/InnerTube/StreamResolver.swift` (record status; all-failed hint)
- Modify: `YT Music/Settings/SettingsView.swift` (`PlaybackSettingsTab`)

**Interfaces:**
- Consumes: Task 14.
- Produces: `@MainActor @Observable final class StreamStatus` with `static let shared`, `lastSource: StreamSource?`, `lastBitrate: Int?`, `lastUsedToken: Bool`, `premiumAudioDetected: Bool`, `recordStream(from:bitrate:usedToken:)`, `recordPremiumAudio(_:)`.

- [ ] **Step 1: Status model**

Create `YT Music/Player/StreamStatus.swift`:

```swift
//
//  StreamStatus.swift
//  YT Music
//
//  What the stream resolver last did, for the Playback settings: which source
//  served the last stream at what bitrate, whether it needed a web token, and
//  whether the signed-in account offers Premium audio.
//

import Foundation

@MainActor
@Observable
final class StreamStatus {
    static let shared = StreamStatus()

    private(set) var lastSource: StreamSource?
    /// Bitrate of the last stream in bits per second, as YouTube reports it.
    private(set) var lastBitrate: Int?
    private(set) var lastUsedToken = false
    private(set) var premiumAudioDetected = false

    func recordStream(from source: StreamSource, bitrate: Int?, usedToken: Bool) {
        lastSource = source
        lastBitrate = bitrate
        lastUsedToken = usedToken
    }

    func recordPremiumAudio(_ detected: Bool) {
        premiumAudioDetected = detected
    }
}
```

- [ ] **Step 2: Record status in the resolver**

In `StreamResolver.resolved(…)`, before `return ResolvedStream(`, add:

```swift
        let bitrate = format.bitrate
        let premium = session.premiumAudio ?? false
        Task { @MainActor in
            StreamStatus.shared.recordStream(from: source, bitrate: bitrate, usedToken: usedToken)
            StreamStatus.shared.recordPremiumAudio(premium)
        }
```

In `audioStream`, replace the final `throw lastError` with:

```swift
        if preferences.sourceMode == .custom, preferences.customSources.filter(\.isEnabled).count == 1 {
            throw StreamError.notPlayable(
                "\(lastError.localizedDescription) Turn on another source in Settings → Streaming to try it as a fallback."
            )
        }
        throw lastError
```

- [ ] **Step 3: Settings UI**

In `SettingsView.swift`, inside `PlaybackSettingsTab`'s `Form`, directly after the closing brace of `Section("Audio") { … }` insert:

```swift

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
```

Before `private struct PlaybackSettingsTab: View {` add:

```swift
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

```

- [ ] **Step 4: Build and run all policy tests**

Run: Build command, then Test command with `StreamPolicyTests`. Expected: build succeeds, tests PASS.

- [ ] **Step 5: Commit**

```bash
git add "YT Music/Player/StreamStatus.swift" "YT Music/InnerTube/StreamResolver.swift" "YT Music/Settings/SettingsView.swift"
git commit -m "feat(settings): choose the stream source and see what played

Settings > Playback gains a Streaming section: Automatic (default) or
Custom, where the sources are tried top to bottom, can be reordered by
dragging or from the context menu, and switched off while one stays on.
A status line names the source and bitrate of the last stream, and
whether Premium audio or a web token was involved.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 16: PR 4 gate, review, fork integration

- [ ] **Step 1: Docs.** In `CLAUDE.md`, extend the `Settings/` bullet's list of audio prefs with `streamSourceMode`/`customStreamSources`, and add to the stream sources bullet: "Settings → Playback → Streaming: **Automatic** or **Custom** (`StreamSourceEntry` list, normalized so one stays on; a new `StreamSource` case appears in it automatically). `StreamStatus` feeds the `Last stream` row." Commit: "docs: describe the streaming settings".
- [ ] **Step 2: Full test run (GUI session).** Expected: all PASS, with output shown to the user.
- [ ] **Step 3: Live check.** Release build to `/Users/Shared/YTM-Test/YouTube Music (PR4).app`. User checks: Automatic plays via visionOS; Custom with the account on top shows "YouTube Music account · … · web token"; visionOS off still plays; dragging and the context menu reorder; history still records. Read the log as before.
- [ ] **Step 4: Code review.** Use superpowers:requesting-code-review on `origin/master..feat/stream-source-settings`; fix findings with tests.
- [ ] **Step 5: Fork integration** (local only):

```bash
git switch local/kvn
git merge origin/master
git merge feat/stream-source-settings
```

Resolve conflicts in favor of the new branches for `StreamResolver.swift`, `PlayerState.swift`, `AudioPlayer.swift`, `AudioOutput.swift`, `AppSettings.swift`, `SettingsView.swift` (the fork's `fix/playback-po-token` and `feat/visionos-stream` merges are superseded). Build, full test run, commit the merge.
- [ ] **Step 6: Hand-off.** Report to the user: test output, live log summary, review result. Draft PR texts for the four branches (with a "how to verify with Premium" section: expected log `source order: account, visionOS (premium audio true, quality auto)` and `potoken: Premium streams play without a token`). Push and open PRs only after the user's OK.
