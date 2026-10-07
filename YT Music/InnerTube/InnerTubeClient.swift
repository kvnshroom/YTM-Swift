//
//  InnerTubeClient.swift
//  YT Music
//
//  Minimal native client for YouTube's private InnerTube API, configured as the
//  WEB_REMIX (YouTube Music web) client. No official API exists, so we send the
//  same context object and headers the web player uses.
//
//  This is unauthenticated: the home feed returns generic recommendations.
//  Personalized results would require forwarding the user's SAPISID cookie and
//  computing the Authorization hash — out of scope for this slice.
//

import Foundation

enum InnerTubeError: LocalizedError {
    case badStatus(Int)
    case emptyResponse
    /// An authenticated request was rejected (HTTP 401) — the signed-in session
    /// has expired and needs re-authentication.
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "YouTube Music returned HTTP \(code)."
        case .emptyResponse:       "YouTube Music returned an empty response."
        case .unauthorized:        "Your YouTube Music session expired. Sign in again."
        }
    }
}

extension Notification.Name {
    /// Posted (on any thread) when an authenticated InnerTube request is rejected
    /// with HTTP 401, so the app can prompt the user to sign in again. `AuthStore`
    /// observes it.
    static let ytmSessionExpired = Notification.Name("moe.tenshii.YT-Music.sessionExpired")

    /// Posted (on any thread) when the signed-in session changes (sign-in or
    /// sign-out), so caches keyed on account-relative data can be dropped.
    static let ytmCredentialsChanged = Notification.Name("moe.tenshii.YT-Music.credentialsChanged")
}

/// Failures specific to uploading a local file to YT Music.
enum UploadError: LocalizedError {
    case notSignedIn
    case unsupportedFormat(String)
    case uploadURLMissing
    case failed(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Sign in to upload music."
        case .unsupportedFormat(let ext):
            "Can't upload .\(ext) files. Use MP3, M4A, AAC, FLAC, OGG, or WMA."
        case .uploadURLMissing:
            "YouTube Music didn't return an upload URL."
        case .failed(let code):
            "Upload failed (HTTP \(code))."
        }
    }
}

/// Minimal decode target for action endpoints (subscribe, like) — we only care
/// that the request succeeded (a non-2xx throws before we get here).
private nonisolated struct EmptyActionResponse: Decodable {}

/// The id of a freshly created playlist (`playlist/create` response).
private nonisolated struct CreatePlaylistResponse: Decodable {
    let playlistId: String?
}

/// The parts of a `next(videoId)` response the now-playing UI needs, extracted
/// once and cached: the lyrics- and related-tab browse ids, plus the seed
/// track's like status. Sharing this spares us three separate `next` fetches for
/// the same track (lyrics, related, and like status each need one field of it).
private nonisolated struct WatchNextInfo: Sendable {
    let lyricsBrowseId: String?
    let relatedBrowseId: String?
    let likeStatus: LikeStatus
}

/// A small LRU cache of `WatchNextInfo` keyed by videoId. The browse ids are
/// immutable, so entries live until evicted; the like status is account-relative,
/// so a track's entry is invalidated when its rating changes, and the whole cache
/// is cleared on sign-in/out (see `ytmCredentialsChanged`).
private actor WatchNextStore {
    private var entries: [String: WatchNextInfo] = [:]
    private var order: [String] = []
    private let limit = 16

    func cached(_ videoId: String) -> WatchNextInfo? { entries[videoId] }

    func store(_ info: WatchNextInfo, for videoId: String) {
        if entries[videoId] == nil { order.append(videoId) }
        entries[videoId] = info
        while order.count > limit { entries[order.removeFirst()] = nil }
    }

    func invalidate(_ videoId: String) {
        entries[videoId] = nil
        order.removeAll { $0 == videoId }
    }

    func clear() {
        entries.removeAll()
        order.removeAll()
    }
}

/// Visibility of one of the user's playlists, as sent by `playlist/create`
/// and the `edit_playlist` set-privacy action.
nonisolated enum PlaylistPrivacy: String, Sendable, CaseIterable {
    case `private` = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"

    /// The visibility as labelled on an owned playlist's header/byline ("Private
    /// playlist" / "Unlisted playlist" / "Public playlist"), or nil when the
    /// text doesn't say — saved playlists and albums never do.
    init?(subtitleText: String) {
        let lowered = subtitleText.lowercased()
        if lowered.contains("private playlist") {
            self = .private
        } else if lowered.contains("unlisted playlist") {
            self = .unlisted
        } else if lowered.contains("public playlist") {
            self = .public
        } else {
            return nil
        }
    }
}

/// The bits of a YT Music page's ytcfg that decide a stream PO token's binding.
nonisolated struct PlayerPageConfig: Sendable, Equatable {
    /// The signed-in account's id (`DATASYNC_ID`); nil when signed out.
    var dataSyncId: String?
    /// YouTube's `html5_generate_content_po_token` experiment: when on, stream
    /// tokens are bound to the video id instead of the session.
    var bindsToVideoId: Bool

    init(dataSyncId: String?, bindsToVideoId: Bool) {
        self.dataSyncId = dataSyncId
        self.bindsToVideoId = bindsToVideoId
    }

    /// Parses the page HTML. The experiment flags sit in a JSON string, so `=`
    /// may appear escaped as `\u003d`.
    init(page html: String) {
        dataSyncId = Self.firstMatch(#""DATASYNC_ID"\s*:\s*"([^"]+)""#, in: html)
        bindsToVideoId = Self.firstMatch(
            #"html5_generate_content_po_token(?:=|\\u003d)(true|false)"#, in: html
        ) == "true"
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}

/// The signed-in user's rating of a track, mirroring YT Music's like/dislike UI.
nonisolated enum LikeStatus: String, Codable, Sendable {
    case indifferent
    case liked
    case disliked

    /// Maps YT's raw `likeButtonRenderer.likeStatus` string ("LIKE"/"DISLIKE"/
    /// "INDIFFERENT"). Anything else (including nil) is treated as indifferent.
    init(innerTube raw: String?) {
        switch raw {
        case "LIKE":    self = .liked
        case "DISLIKE": self = .disliked
        default:        self = .indifferent
        }
    }
}

/// Sets a track's like rating, and reads its current rating. Abstracted so
/// PlayerState can be driven by a fake in tests (no network).
protocol LikeProviding: Sendable {
    func setLikeStatus(videoId: String, status: LikeStatus) async throws
    func likeStatus(for videoId: String) async throws -> LikeStatus
}

extension InnerTubeClient: LikeProviding {}

/// Fetches a track's lyrics. Abstracted so the lyrics UI can be driven by a
/// fake in tests (no network), and so different sources (YT Music, LRCLIB) are
/// interchangeable.
protocol LyricsProviding: Sendable {
    func lyrics(for query: LyricsQuery) async throws -> Lyrics?
}

extension InnerTubeClient: LyricsProviding {}

/// Fetches a track's related-music shelves (similar songs, artists, recommended
/// playlists). Abstracted so the Related UI can be driven by a fake in tests.
protocol RelatedProviding: Sendable {
    func related(for videoId: String) async throws -> [HomeShelf]
}

extension InnerTubeClient: RelatedProviding {}

/// Fetches a track's comments. Abstracted so the comments UI can be driven by a
/// fake in tests (no network).
protocol CommentsProviding: Sendable {
    func comments(for videoId: String) async throws -> CommentPage
    /// Loads a further page of top-level comments via a paging token.
    func moreComments(token: String) async throws -> CommentPage
    /// Loads a page of replies for a comment thread via its reply token.
    func commentReplies(token: String, parentId: String) async throws -> CommentPage
}

extension InnerTubeClient: CommentsProviding {}

nonisolated final class InnerTubeClient: Sendable, WatchHistoryReporting {
    static let shared = InnerTubeClient()

    // Public WEB_REMIX client constants (these ship in the YT Music web bundle).
    private let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    private let clientName = "WEB_REMIX"
    private let clientVersion = "1.20260623.13.00"
    private let baseURL = URL(string: "https://music.youtube.com/youtubei/v1/")!
    private let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"

    private let session: URLSession

    /// Shares one `next(videoId)` round-trip across the lyrics, related, and
    /// like-status paths (see `watchNextInfo(for:)`).
    private let watchNextCache = WatchNextStore()

    init(session: URLSession? = nil) {
        self.session = session ?? NetworkSession.make()
        // The like status carried in cached watch-next info is account-relative,
        // so drop the whole cache whenever the session changes.
        NotificationCenter.default.addObserver(
            forName: .ytmCredentialsChanged, object: nil, queue: nil
        ) { [watchNextCache] _ in
            Task { await watchNextCache.clear() }
        }
    }

    /// Loads the YouTube Music home feed (`FEmusic_home`).
    func homeFeed() async throws -> HomeFeed {
        try await homeFeed(browseId: "FEmusic_home")
    }

    func homeFeed(browseId: String, params: String? = nil) async throws -> HomeFeed {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        let response: BrowseResponse = try await post(
            "browse",
            body: body
        )
        return HomeFeedParser.parse(response)
    }

    /// Loads the next batch of home feed shelves (no chips).
    func homeContinuation(_ token: String, visitorData: String?) async throws -> HomeFeed {
        let response: BrowseResponse = try await post(
            "browse",
            body: ["continuation": token],
            visitorData: visitorData
        )
        return HomeFeedParser.parseContinuation(response)
    }

    /// Loads the YouTube Music explore landing page (`FEmusic_explore`): new
    /// releases, charts, trending, and top music videos.
    func explore() async throws -> [HomeShelf] {
        let response: BrowseResponse = try await post(
            "browse",
            body: ["browseId": "FEmusic_explore"]
        )
        return ExploreParser.parse(response)
    }

    /// Runs a YouTube Music search, returning result shelves grouped by category
    /// ("Songs", "Albums", "Artists", …). An empty/blank query yields no shelves.
    /// Pass a `filter` other than `.all` to scope results to a single type, in
    /// which case YouTube returns its own pre-grouped, server-titled shelves.
    func search(_ query: String, filter: SearchFilter = .all) async throws -> [HomeShelf] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var body: [String: Any] = ["query": trimmed]
        if let params = filter.params { body["params"] = params }
        let response: SearchResponse = try await post("search", body: body)
        return SearchParser.parse(response)
    }

    /// Returns the server-ranked completions for the current search field text.
    func searchSuggestions(_ input: String) async throws -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response: SearchSuggestionsResponse = try await post(
            "music/get_search_suggestions",
            body: ["input": trimmed]
        )
        return SearchSuggestionsParser.parse(response)
    }

    /// Loads an album / playlist / artist page for the given browse id.
    func entity(_ destination: EntityDestination) async throws -> EntityPage {
        let response: EntityBrowseResponse = try await post(
            "browse",
            body: ["browseId": destination.browseId]
        )
        return EntityPageParser.parse(response, fallback: destination)
    }

    /// Loads the next batch of tracks from an album or playlist browse page.
    func entityContinuation(
        _ token: String,
        startIndex: Int,
        header: EntityHeader
    ) async throws -> EntityPage {
        let response: EntityBrowseResponse = try await post(
            "browse",
            body: ["continuation": token]
        )
        let next = EntityPageParser.parseContinuation(
            response,
            startIndex: startIndex,
            header: header
        )
        return EntityPage(
            header: header,
            tracks: next.tracks,
            shelves: [],
            continuationToken: next.continuationToken
        )
    }

    /// Reloads a playlist's track section through a filter or sort token.
    func entityTrackReload(_ token: String, header: EntityHeader) async throws -> EntityPage {
        let response: EntityBrowseResponse = try await post("browse", body: ["continuation": token])
        return EntityPageParser.parseTrackReload(response, header: header)
    }

    /// Loads the complete lightweight playlist index used by playlist search.
    /// This contains names and IDs, not full browse rows, so it does not create
    /// thousands of SwiftUI views or eagerly load artwork.
    func playlistFilterMetadata(playlistId: String) async throws -> [Track] {
        let response: PlaylistFilterMetadataResponse = try await post(
            "get_playlist_filter_search_metadata",
            body: ["playlistId": playlistId]
        )
        var seenVideoIds = Set<String>()
        return (response.tracks ?? []).compactMap(\.track).filter { track in
            guard let videoId = track.videoId else { return false }
            return seenVideoIds.insert(videoId).inserted
        }
    }

    /// Hydrates playlist-index matches with the full browse row renderers.
    func playlistFilterSearch(playlistId: String, tracks: [Track]) async throws -> [Track] {
        let identifiers = tracks.compactMap { track -> [String: String]? in
            guard let videoId = track.videoId,
                  let setVideoId = track.playlistSetVideoId else { return nil }
            return ["videoId": videoId, "encryptedSetVideoId": setVideoId]
        }
        guard !identifiers.isEmpty else { return [] }

        let response: EntityBrowseResponse = try await post(
            "browse",
            body: [
                "browseId": "FEplaylist_filter_search",
                "formData": [
                    "playlistFilterSearchFormData": [
                        "playlistId": playlistId,
                        "playlistVideoItemIdentifiers": identifiers,
                    ],
                ],
            ]
        )
        let fallback = EntityDestination(
            browseId: "VL\(playlistId)", kind: .playlist,
            title: "", subtitle: "", thumbnailURL: nil
        )
        return EntityPageParser.parse(response, fallback: fallback).tracks
    }

    /// Loads a library page (requires auth): the landing page by default, or a
    /// filter chip's page (`FEmusic_liked_playlists`, …).
    func library(browseId: String = "FEmusic_library_landing", params: String? = nil) async throws -> LibraryPage {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        let response: BrowseResponse = try await post("browse", body: body)
        return LibraryParser.parse(response)
    }

    /// Loads the next page of a library listing.
    func libraryContinuation(_ token: String) async throws -> LibraryPage {
        let response: BrowseResponse = try await post("browse", body: ["continuation": token])
        return LibraryParser.parseContinuation(response)
    }

    /// Loads the signed-in user's uploaded music landing page
    /// (`FEmusic_library_privately_owned_landing`): uploaded albums, artists, and
    /// songs. Requires auth; anonymous requests return nothing.
    func uploads() async throws -> [HomeShelf] {
        let data = try await postData(
            "browse",
            body: ["browseId": "FEmusic_library_privately_owned_landing"]
        )
        let response = try JSONDecoder().decode(BrowseResponse.self, from: data)
        let shelves = UploadsParser.parse(response)
        if shelves.isEmpty {
            // Can't reach this API from tests, so when the page comes back empty
            // dump the raw response to Caches (`yt-uploads.json`) to diagnose the
            // real layout. Read with Console.app or `open`.
            let path = PlaybackLog.dumpData(data, to: "yt-uploads.json") ?? "(dump failed)"
            PlaybackLog.problem("uploads: parsed 0 shelves — dumped response to \(path)")
        } else {
            PlaybackLog.note("uploads: parsed \(shelves.count) shelves")
        }
        return shelves
    }

    /// Uploads a local audio file to the signed-in user's YT Music uploads via
    /// YouTube's resumable upload protocol. This targets `upload.youtube.com` — a
    /// separate host from the InnerTube API — but authenticates with the same
    /// session headers (Cookie + SAPISIDHASH + `X-Goog-AuthUser`). Two steps: a
    /// `start` request that returns a one-time upload URL, then an
    /// `upload, finalize` request that streams the bytes. Requires auth. Newly
    /// uploaded tracks take a while to appear in `uploads()` while YouTube
    /// transcodes them server-side. Supported formats: mp3, m4a, aac, flac, ogg,
    /// wma.
    func uploadSong(fileURL: URL) async throws {
        let headers = await CredentialStore.shared.requestHeaders()
        guard !headers.isEmpty else { throw UploadError.notSignedIn }

        let ext = fileURL.pathExtension.lowercased()
        guard Self.uploadableExtensions.contains(ext) else {
            throw UploadError.unsupportedFormat(ext)
        }

        // File size for the content-length hint; the bytes are streamed from disk
        // in step 2, so the whole file is never held in memory.
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let authUser = headers["X-Goog-AuthUser"] ?? "0"

        // Step 1 — request a resumable upload URL.
        var startComponents = URLComponents(string: "https://upload.youtube.com/upload/usermusic/http")!
        startComponents.queryItems = [URLQueryItem(name: "authuser", value: authUser)]
        var start = URLRequest(url: startComponents.url!)
        start.httpMethod = "POST"
        for (header, value) in headers { start.setValue(value, forHTTPHeaderField: header) }
        start.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        start.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.httpBody = Data("filename=\(fileURL.lastPathComponent)".utf8)

        let (_, startResponse) = try await session.data(for: start)
        guard let startHTTP = startResponse as? HTTPURLResponse else { throw InnerTubeError.emptyResponse }
        PlaybackLog.note("upload: start → HTTP \(startHTTP.statusCode) for \(fileURL.lastPathComponent) (\(size) bytes)")
        guard (200..<300).contains(startHTTP.statusCode) else { throw UploadError.failed(startHTTP.statusCode) }
        guard let uploadURLString = startHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            PlaybackLog.problem("upload: no X-Goog-Upload-URL header in start response")
            throw UploadError.uploadURLMissing
        }

        // Step 2 — stream the bytes to the upload URL and finalize.
        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        for (header, value) in headers { upload.setValue(value, forHTTPHeaderField: header) }
        upload.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")

        let (uploadBody, uploadResponse) = try await session.upload(for: upload, fromFile: fileURL)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse else { throw InnerTubeError.emptyResponse }
        let status = uploadHTTP.value(forHTTPHeaderField: "X-Goog-Upload-Status") ?? "?"
        PlaybackLog.note("upload: finalize → HTTP \(uploadHTTP.statusCode), upload-status=\(status)")
        guard (200..<300).contains(uploadHTTP.statusCode) else {
            let bodyText = String(data: uploadBody.prefix(400), encoding: .utf8) ?? ""
            PlaybackLog.problem("upload: finalize failed \(uploadHTTP.statusCode) — \(bodyText)")
            throw UploadError.failed(uploadHTTP.statusCode)
        }
    }

    /// Audio containers YouTube Music accepts for uploads.
    static let uploadableExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "ogg", "wma"]

    /// Loads the signed-in user's listening history (`FEmusic_history`), grouped
    /// into date buckets ("Today", "Yesterday", …). Requires auth; anonymous
    /// requests return no history.
    func history() async throws -> [HistorySection] {
        let response: BrowseResponse = try await post(
            "browse",
            body: ["browseId": "FEmusic_history"]
        )
        return HistoryParser.parse(response)
    }

    /// Loads the signed-in user's account info (name / handle / avatar). Returns
    /// nil when signed out (the response carries no account header).
    func accountInfo() async throws -> AccountInfo? {
        let response: AccountMenuResponse = try await post("account/account_menu", body: [:])
        return AccountInfoParser.parse(response)
    }

    /// Reads what decides a stream PO token's binding from the ytcfg of the
    /// music.youtube.com page (InnerTube responses carry neither), fetched with
    /// the session cookies when signed in.
    func playerPageConfig() async throws -> PlayerPageConfig {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        if let cookie = await CredentialStore.shared.requestHeaders()["Cookie"] {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return PlayerPageConfig(page: String(bytes: data, encoding: .utf8) ?? "")
    }

    /// Loads playback streams for a video. The `signatureTimestamp` (extracted
    /// from base.js) must match the player JS used to decipher the result.
    /// `playlistId`, when the play comes from a playlist/radio, is the context
    /// the real client sends so the listen is attributed to that playlist — the
    /// response's stats beacons then carry it as the `list` param.
    func player(videoId: String, signatureTimestamp: String?, playlistId: String? = nil) async throws -> PlayerResponse {
        var body: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        if let playlistId {
            body["playlistId"] = playlistId
        }
        if let signatureTimestamp, let sts = Int(signatureTimestamp) {
            body["playbackContext"] = [
                "contentPlaybackContext": ["signatureTimestamp": sts]
            ]
        }
        return try await post("player", body: body)
    }

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

    /// Fetches a radio's first batch (~50 tracks) seeded from a video (the
    /// "Start radio" action). The queue's first entry is the seed track itself.
    /// The batch comes with a continuation token (verified live against
    /// WEB_REMIX): resend it through `continueRadio` to keep the same mix going
    /// instead of starting a new, unrelated single-song radio.
    func radio(for videoId: String) async throws -> RadioPage {
        // RDAMVM<id> = this song's radio.
        let response = try await nextResponse(videoId: videoId, playlistId: MixIds.songRadio(for: videoId))
        return RadioPage(tracks: WatchNextParser.parse(response), continuation: WatchNextParser.continuationToken(response))
    }

    /// Fetches the next batch of an already-started mix/radio via its
    /// continuation token (same `next`-endpoint continuation shape as
    /// `moreComments`, just a different panel).
    func continueRadio(_ token: String) async throws -> RadioPage {
        let response: RadioContinuationResponse = try await post("next", body: ["continuation": token])
        return RadioPage(tracks: WatchNextParser.parse(response), continuation: WatchNextParser.continuationToken(response))
    }

    /// Fetches the ordered watch queue for a `next` endpoint (a "Play all" button
    /// on a shelf, or a playlist/album radio). Returns the queue's tracks — the
    /// same renderer a radio uses — so the caller can play them with real
    /// per-track metadata rather than a single seed.
    func watchQueue(videoId: String, playlistId: String) async throws -> [Track] {
        WatchNextParser.parse(try await nextResponse(videoId: videoId, playlistId: playlistId))
    }

    private func nextResponse(videoId: String, playlistId: String) async throws -> WatchNextResponse {
        try await post(
            "next",
            body: [
                "videoId": videoId,
                "playlistId": playlistId,
                "isAudioOnly": true,
                "enablePersistentPlaylistPanel": true,
                "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
            ]
        )
    }

    /// Fetches (and caches) the parts of a track's `next` response the
    /// now-playing UI reads. The lyrics tab, related tab, and like-status paths
    /// all call this, so a track costs a single `next` round-trip rather than one
    /// each. Cached entries are dropped on rating changes and sign-in/out.
    private func watchNextInfo(for videoId: String) async throws -> WatchNextInfo {
        if let cached = await watchNextCache.cached(videoId) { return cached }
        let response: WatchNextResponse = try await post("next", body: ["videoId": videoId])
        let info = WatchNextInfo(
            lyricsBrowseId: WatchNextParser.lyricsBrowseId(response),
            relatedBrowseId: WatchNextParser.relatedBrowseId(response),
            likeStatus: WatchNextParser.likeStatus(response, expecting: videoId)
        )
        await watchNextCache.store(info, for: videoId)
        return info
    }

    /// Fetches the lyrics for a track. Two steps, mirroring the web client: the
    /// `next` response carries a "Lyrics" tab whose browse id (an `MPLYt…`) is
    /// then browsed for the text. Returns nil when the track has no lyrics.
    func lyrics(for query: LyricsQuery) async throws -> Lyrics? {
        guard let browseId = try await watchNextInfo(for: query.videoId).lyricsBrowseId else {
            return nil
        }
        let response: LyricsResponse = try await post("browse", body: ["browseId": browseId])
        return LyricsParser.parse(response)
    }

    /// Fetches a track's related-music shelves. Two steps, mirroring the web
    /// client: the `next` response carries a "Related" tab whose browse id (an
    /// `MPTRt…`) is then browsed for the shelves. Empty when the track has no
    /// related tab.
    func related(for videoId: String) async throws -> [HomeShelf] {
        guard let browseId = try await watchNextInfo(for: videoId).relatedBrowseId else {
            return []
        }
        let response: BrowseResponse = try await post("browse", body: ["browseId": browseId])
        return RelatedParser.parse(response)
    }

    /// Fetches the first page of top-level comments for a track. Comments are a
    /// regular YouTube (not YT Music) surface, so these requests target the `WEB`
    /// client at www.youtube.com — the WEB_REMIX `next` response carries no
    /// comments panel. Fetched anonymously (comments are public; the WEB origin
    /// wouldn't match the Music session's SAPISIDHASH anyway). Two steps: the
    /// videoId response carries a comments engagement panel with a continuation
    /// token, which is then loaded for the first page. Empty when the track has
    /// no comments.
    func comments(for videoId: String) async throws -> CommentPage {
        let token: CommentsTokenResponse = try await post(
            "next", body: ["videoId": videoId], client: web, authenticated: false)
        guard let continuation = CommentsParser.continuationToken(token) else { return .empty }
        return try await moreComments(token: continuation)
    }

    /// Loads a further page of top-level comments (infinite scroll).
    func moreComments(token: String) async throws -> CommentPage {
        let response: CommentsResponse = try await post(
            "next", body: ["continuation": token], client: web, authenticated: false)
        return CommentsParser.parse(response)
    }

    /// Loads a page of replies for a comment thread (the WEB client, anonymous,
    /// like the top-level comments). `parentId` is excluded from the result since
    /// the reply feed can echo the parent comment. The returned page's token
    /// pages through further replies.
    func commentReplies(token: String, parentId: String) async throws -> CommentPage {
        let response: CommentsResponse = try await post(
            "next", body: ["continuation": token], client: web, authenticated: false)
        return CommentsParser.parseReplies(response, excluding: parentId)
    }

    /// Subscribes to or unsubscribes from a channel (artist). Requires auth —
    /// the request is a no-op server-side without the signed-in session headers.
    /// Throws on a non-2xx status so callers can keep the previous UI state.
    func setSubscription(channelId: String, params: String?, subscribe: Bool) async throws {
        let endpoint = subscribe ? "subscription/subscribe" : "subscription/unsubscribe"
        var body: [String: Any] = ["channelIds": [channelId]]
        if let params { body["params"] = params }
        let _: EmptyActionResponse = try await post(endpoint, body: body)
    }

    /// Sets the signed-in user's like rating for a track via the `like/*`
    /// endpoints. Requires auth — a no-op server-side without the session
    /// headers. Throws on a non-2xx status so callers can revert the UI.
    func setLikeStatus(videoId: String, status: LikeStatus) async throws {
        let endpoint = switch status {
        case .liked:       "like/like"
        case .disliked:    "like/dislike"
        case .indifferent: "like/removelike"
        }
        let _: EmptyActionResponse = try await post(
            endpoint,
            body: ["target": ["videoId": videoId]]
        )
        // The cached watch-next info carries this track's now-stale rating.
        await watchNextCache.invalidate(videoId)
    }

    /// Adds or removes a playlist from the signed-in user's library. YT Music's
    /// "Add to library" / "Remove from library" actions are the same `like/*`
    /// endpoints used to rate a track, but applied to a `playlistId` target.
    /// Requires auth — a no-op server-side without the session headers. Throws
    /// on a non-2xx status so callers can revert the UI.
    func setPlaylistSaved(playlistId: String, saved: Bool) async throws {
        let endpoint = saved ? "like/like" : "like/removelike"
        let _: EmptyActionResponse = try await post(
            endpoint,
            body: ["target": ["playlistId": playlistId]]
        )
    }

    // MARK: - Playlist editing

    /// Loads the playlists the signed-in user can add `videoId` to — YT Music's
    /// own "Add to playlist" dialog source. This returns only editable playlists
    /// (excluding saved-but-not-owned playlists and "Liked Music"), unlike
    /// browsing the library playlists page. Requires auth.
    func addToPlaylistOptions(videoId: String) async throws -> [EditablePlaylist] {
        let data = try await postData(
            "playlist/get_add_to_playlist",
            body: ["videoIds": [videoId], "excludeWatchLater": true]
        )
        do {
            let response = try JSONDecoder().decode(AddToPlaylistResponse.self, from: data)
            return AddToPlaylistParser.parse(response)
        } catch {
            // Can't reach this API from tests (sandbox 403), so on a decode failure
            // dump the raw response to Caches (`yt-add-to-playlist.json`) to diagnose
            // the real layout. Read with Console.app or `open`.
            let path = PlaybackLog.dumpData(data, to: "yt-add-to-playlist.json") ?? "(dump failed)"
            PlaybackLog.problem("add-to-playlist: decode failed (\(error)) — dumped response to \(path)")
            throw error
        }
    }

    /// Creates a new private playlist and returns its id. `videoIds` seeds it
    /// with tracks (the "Save to a new playlist" flow). Requires auth.
    @discardableResult
    func createPlaylist(title: String, videoIds: [String] = []) async throws -> String {
        var body: [String: Any] = ["title": title, "privacyStatus": "PRIVATE"]
        if !videoIds.isEmpty { body["videoIds"] = videoIds }
        let response: CreatePlaylistResponse = try await post("playlist/create", body: body)
        guard let id = response.playlistId else { throw InnerTubeError.emptyResponse }
        return id
    }

    /// Deletes one of the user's playlists. Requires auth (and ownership — the
    /// server rejects deleting a playlist you don't own).
    func deletePlaylist(playlistId: String) async throws {
        let _: EmptyActionResponse = try await post(
            "playlist/delete",
            body: ["playlistId": playlistId]
        )
    }

    /// Renames one of the user's playlists via an `edit_playlist` set-name action.
    func renamePlaylist(playlistId: String, title: String) async throws {
        try await editPlaylist(playlistId: playlistId, actions: [
            ["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]
        ])
    }

    /// Applies metadata edits (name / description / visibility) to one of the
    /// user's playlists as one `edit_playlist` batch. Nil fields produce no
    /// action, so callers send just what changed. Requires auth.
    func updatePlaylist(
        playlistId: String,
        title: String? = nil,
        description: String? = nil,
        privacy: PlaylistPrivacy? = nil
    ) async throws {
        var actions: [[String: Any]] = []
        if let title {
            actions.append(["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title])
        }
        if let description {
            actions.append([
                "action": "ACTION_SET_PLAYLIST_DESCRIPTION",
                "playlistDescription": description,
            ])
        }
        if let privacy {
            actions.append([
                "action": "ACTION_SET_PLAYLIST_PRIVACY",
                "playlistPrivacy": privacy.rawValue,
            ])
        }
        try await editPlaylist(playlistId: playlistId, actions: actions)
    }

    /// Adds tracks to one of the user's playlists. Requires auth. Duplicate adds
    /// are an idempotent server no-op.
    func addToPlaylist(playlistId: String, videoIds: [String]) async throws {
        guard !videoIds.isEmpty else { return }
        try await editPlaylist(
            playlistId: playlistId,
            actions: videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0] }
        )
    }

    /// Removes tracks from one of the user's playlists. Each item pairs the
    /// track's plain `videoId` with its playlist-scoped `setVideoId` (both are
    /// required by the remove action). Requires auth.
    func removeFromPlaylist(
        playlistId: String,
        items: [(videoId: String, setVideoId: String)]
    ) async throws {
        guard !items.isEmpty else { return }
        try await editPlaylist(
            playlistId: playlistId,
            actions: items.map {
                [
                    "action": "ACTION_REMOVE_VIDEO",
                    "removedVideoId": $0.videoId,
                    "setVideoId": $0.setVideoId,
                ]
            }
        )
    }

    /// Posts a batch of `edit_playlist` actions against a playlist.
    private func editPlaylist(playlistId: String, actions: [[String: Any]]) async throws {
        let _: EmptyActionResponse = try await post(
            "browse/edit_playlist",
            body: ["playlistId": playlistId, "actions": actions]
        )
    }

    // MARK: - History / uploads editing

    /// Removes items from the signed-in user's listening history via their
    /// per-row feedback tokens (the `feedback` endpoint). Passing every row's
    /// token clears the whole history. Requires auth.
    func removeHistoryItems(feedbackTokens: [String]) async throws {
        guard !feedbackTokens.isEmpty else { return }
        let _: EmptyActionResponse = try await post(
            "feedback",
            body: ["feedbackTokens": feedbackTokens]
        )
    }

    /// Deletes an uploaded song/album from the user's library
    /// (`music/delete_privately_owned_entity`). `entityId` comes from the item's
    /// overflow-menu delete action. Requires auth.
    func deleteUpload(entityId: String) async throws {
        let _: EmptyActionResponse = try await post(
            "music/delete_privately_owned_entity",
            body: ["entityId": entityId]
        )
    }

    /// Reads the signed-in user's current like rating for a track from the
    /// watch-next overlay. Skips the network round-trip when signed out (the
    /// rating is per-account, so it's always `.indifferent` anonymously). Shares
    /// the cached `next` fetch with the lyrics and related paths.
    func likeStatus(for videoId: String) async throws -> LikeStatus {
        guard await CredentialStore.shared.isSignedIn else { return .indifferent }
        return try await watchNextInfo(for: videoId).likeStatus
    }

    /// Fires the `playback` beacon once at the start of a play. No-op when signed
    /// out — history is per-account, so an anonymous ping does nothing.
    func reportPlaybackStart(playbackURL: URL, cpn: String, position: Double, length: Double?) async {
        let headers = await CredentialStore.shared.requestHeaders()
        guard !headers.isEmpty else { return }
        if let url = WatchHistory.playbackURL(base: playbackURL, cpn: cpn, position: position,
                                              length: length, client: statsClientParams) {
            await ping(url, credentialHeaders: headers)
        }
    }

    /// Fires a `watchtime` heartbeat reporting the live playback position — the
    /// signal that drives YT Music history. No-op when signed out.
    func reportWatchtime(watchtimeURL: URL, cpn: String, position: Double, length: Double?) async {
        let headers = await CredentialStore.shared.requestHeaders()
        guard !headers.isEmpty else { return }
        if let url = WatchHistory.watchtimeURL(base: watchtimeURL, cpn: cpn, position: position,
                                               length: length, client: statsClientParams) {
            await ping(url, credentialHeaders: headers)
        }
    }

    /// WEB_REMIX client-identity params the stats beacons must carry. The player
    /// response's stats base omits these, but the real Music client appends them —
    /// `c=WEB_REMIX` in particular is what classifies the play as a Music listen
    /// (so it lands in YTM History, not just generic YouTube history).
    private var statsClientParams: [String: String] {
        [
            "c": clientName,            // WEB_REMIX
            "cver": clientVersion,
            "cplayer": "UNIPLAYER",
            "cos": "Macintosh",
            "cosver": "10_15_7",
            "cplatform": "DESKTOP",
            "cbrand": "apple",
            "cbr": "Chrome",
            "cbrver": "149.0.0.0",
            "hl": "en",
        ]
    }

    /// Fires a single stats beacon (GET) with the client + session headers.
    private func ping(_ url: URL, credentialHeaders: [String: String]) async {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyClientHeaders(to: &request)
        for (header, value) in credentialHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        _ = try? await session.data(for: request)
    }

    // MARK: - Request plumbing

    /// Identifies the InnerTube client a request impersonates. Most calls use the
    /// YT Music web app (`webRemix`); comments live only on the regular YouTube
    /// web client (`web`), so those requests target it instead.
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

    private var webRemix: ClientProfile {
        ClientProfile(baseURL: baseURL, clientName: clientName, clientVersion: clientVersion,
                      clientNameHeader: "67", origin: "https://music.youtube.com", apiKey: apiKey)
    }

    /// The regular YouTube (www) web client. Used for comments, which YT Music's
    /// WEB_REMIX surface doesn't expose.
    private let web = ClientProfile(
        baseURL: URL(string: "https://www.youtube.com/youtubei/v1/")!,
        clientName: "WEB",
        clientVersion: "2.20240620.05.00",
        clientNameHeader: "1",
        origin: "https://www.youtube.com",
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    )

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

    /// POSTs to an InnerTube endpoint as `client` (default: YT Music WEB_REMIX),
    /// decoding the JSON response. Pass `authenticated: false` to omit the
    /// signed-in session headers (e.g. public comments fetched as the WEB
    /// client, whose origin wouldn't match the Music SAPISIDHASH anyway).
    private func post<T: Decodable>(
        _ endpoint: String,
        body: [String: Any],
        client: ClientProfile? = nil,
        authenticated: Bool = true,
        visitorData: String? = nil
    ) async throws -> T {
        let data = try await postData(
            endpoint, body: body, client: client, authenticated: authenticated, visitorData: visitorData
        )
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Performs the POST and returns the raw response body, so callers that want
    /// to inspect/dump the payload (diagnostics) can do so before decoding.
    private func postData(
        _ endpoint: String,
        body: [String: Any],
        client: ClientProfile? = nil,
        authenticated: Bool = true,
        visitorData: String? = nil
    ) async throws -> Data {
        let profile = client ?? webRemix
        var components = URLComponents(
            url: profile.baseURL.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "key", value: profile.apiKey),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyClientHeaders(to: &request, client: profile)

        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var payload = body
        payload["context"] = context(client: profile, visitorData: visitorData)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // Attach the signed-in session, if any (Cookie + SAPISIDHASH). Empty when
        // signed out, so unauthenticated requests are unaffected.
        var didAttachCredentials = false
        if authenticated {
            let credentialHeaders = await CredentialStore.shared.requestHeaders()
            didAttachCredentials = !credentialHeaders.isEmpty
            for (header, value) in credentialHeaders {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }

        let (data, urlResponse) = try await session.data(for: request)

        if let http = urlResponse as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            // A 401 on a request we actually signed means the session expired;
            // surface it distinctly so the UI can prompt a re-sign-in.
            if http.statusCode == 401, didAttachCredentials {
                PlaybackLog.problem("auth: 401 on \(endpoint) — session expired")
                NotificationCenter.default.post(name: .ytmSessionExpired, object: nil)
                throw InnerTubeError.unauthorized
            }
            throw InnerTubeError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw InnerTubeError.emptyResponse }

        return data
    }

    /// Sets the client-identity headers common to every request (the JSON
    /// `Content-Type` is set per-request since stats pings are GETs).
    private func applyClientHeaders(to request: inout URLRequest, client: ClientProfile? = nil) {
        let profile = client ?? webRemix
        request.setValue(profile.origin, forHTTPHeaderField: "Origin")
        request.setValue(profile.origin + "/", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue(profile.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(profile.clientNameHeader, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.userAgent ?? userAgent, forHTTPHeaderField: "User-Agent")
    }

    /// The InnerTube `context.client` block identifying the impersonated client.
    private func context(client: ClientProfile? = nil, visitorData: String? = nil) -> [String: Any] {
        let profile = client ?? webRemix
        var clientContext: [String: Any] = [
            "clientName": profile.clientName,
            "clientVersion": profile.clientVersion,
            "hl": "en",
            "gl": "US",
        ]
        clientContext.merge(profile.clientDetails) { current, _ in current }
        if let visitorData { clientContext["visitorData"] = visitorData }
        return ["client": clientContext, "user": [:]]
    }
}
