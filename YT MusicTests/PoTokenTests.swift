//
//  PoTokenTests.swift
//  YT MusicTests
//
//  Network-free tests for the PO token plumbing: BotGuard service payload
//  parsing, token encoding, the page config that picks the binding, and
//  adding `pot` to stream URLs. The BotGuard run itself needs WebKit and the
//  live service, so it isn't covered here.
//

import Testing
import Foundation
@testable import YT_Music

@Suite("PO token")
struct PoTokenTests {
    private let challengeFields: [Any] = [
        "msg-id", [NSNull(), "/* interpreter */"], [], "hash", "PROGRAM", "bgGlobal", NSNull(), "blob",
    ]

    @Test("Parses a plain Create challenge")
    func parsesPlainChallenge() throws {
        let data = try JSONSerialization.data(withJSONObject: [challengeFields])
        let challenge = try PoTokenCodec.challenge(fromCreateResponse: data)
        #expect(challenge == BotGuardChallenge(
            interpreterJavaScript: "/* interpreter */", program: "PROGRAM", globalName: "bgGlobal"
        ))
    }

    @Test("Descrambles a scrambled Create challenge (base64, bytes shifted by 97)")
    func parsesScrambledChallenge() throws {
        let json = try JSONSerialization.data(withJSONObject: challengeFields)
        let scrambled = Data(json.map { $0 &- 97 }).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: [NSNull(), scrambled])

        let challenge = try PoTokenCodec.challenge(fromCreateResponse: data)
        #expect(challenge.program == "PROGRAM")
        #expect(challenge.globalName == "bgGlobal")
    }

    @Test("Rejects a Create response without a challenge")
    func rejectsEmptyChallenge() {
        #expect(throws: PoTokenError.self) {
            try PoTokenCodec.challenge(fromCreateResponse: Data("[]".utf8))
        }
    }

    @Test("Parses the GenerateIT integrity token and lifetime")
    func parsesIntegrityToken() throws {
        let data = Data(#"["AQID", 43200, 300, "fallback"]"#.utf8)
        let integrity = try PoTokenCodec.integrityToken(fromGenerateITResponse: data)
        #expect(integrity.token == [1, 2, 3])
        #expect(integrity.lifetime == 43200)
    }

    @Test("Decodes YouTube's URL-safe base64 with dot padding")
    func decodesYouTubeBase64() {
        #expect(PoTokenCodec.bytes(fromYouTubeBase64: "-_8.") == [0xFB, 0xFF])
        #expect(PoTokenCodec.bytes(fromYouTubeBase64: "-_8") == [0xFB, 0xFF])
    }

    @Test("Encodes minted tokens URL-safe")
    func encodesPot() {
        #expect(PoTokenCodec.potString([0xFB, 0xFF, 0xBF]) == "-_-_")
    }

    @Test("Reads DATASYNC_ID and the escaped video-id binding experiment from the page")
    func parsesPageConfig() {
        let page = #"ytcfg.set({"DATASYNC_ID":"abc123||","serializedExperimentFlags":"x=1&html5_generate_content_po_token=true&y=2"})"#
        #expect(PlayerPageConfig(page: page) == PlayerPageConfig(dataSyncId: "abc123||", bindsToVideoId: true))
    }

    @Test("Without the experiment, tokens bind to the session")
    func pageConfigWithoutExperiment() {
        let page = #"{"DATASYNC_ID":"abc123||","flags":"html5_generate_content_po_token=false"}"#
        #expect(PlayerPageConfig(page: page) == PlayerPageConfig(dataSyncId: "abc123||", bindsToVideoId: false))
        #expect(PlayerPageConfig(page: "<html></html>") == PlayerPageConfig(dataSyncId: nil, bindsToVideoId: false))
    }

    @Test("Adds pot to a stream URL, replacing an old one")
    func appendsPot() throws {
        let url = try #require(URL(string: "https://x.googlevideo.com/videoplayback?itag=140&pot=old"))
        let result = StreamResolver.appendingPoToken("new-_", to: url)
        let items = URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "pot" }.map(\.value) == ["new-_"])
        #expect(items.contains { $0.name == "itag" && $0.value == "140" })
    }

    @Test("A nil token leaves the URL untouched")
    func nilPotIsNoOp() throws {
        let url = try #require(URL(string: "https://x.googlevideo.com/videoplayback?itag=140"))
        #expect(StreamResolver.appendingPoToken(nil, to: url) == url)
    }
}
