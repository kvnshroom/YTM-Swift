//
//  PoTokenProvider.swift
//  YT Music
//
//  googlevideo now wants a GVS "proof of origin" token (`pot`) on WEB_REMIX
//  stream URLs. Without one it serves only the first ~1 MB of a track and then
//  answers 403, so AVPlayer fails to load the item.
//
//  The token is minted by Google's own BotGuard attestation script, the same
//  way the YT Music web player does it:
//    1. `jnn/v1/Create` hands out a BotGuard challenge (interpreter JS + program).
//    2. The challenge runs in a hidden WKWebView, a real browser engine, which
//       is what BotGuard checks for. Its snapshot is the BotGuard response.
//    3. `jnn/v1/GenerateIT` trades that response for an integrity token with a
//       lifetime of several hours.
//    4. The minter BotGuard left behind turns the integrity token plus a content
//       binding into the `pot` value. While YouTube runs its
//       `html5_generate_content_po_token` experiment the binding is the video
//       id (so one mint per track); otherwise the account's `datasyncId` when
//       signed in, else `visitorData`.
//
//  All four steps run in one short-lived web view per binding (~0.5 s); the
//  token is cached until it expires. Only the account source needs it, and only
//  when the account isn't Premium (see StreamSourcePolicy). Reference
//  implementations: LuanRT/BgUtils (MIT) and NewPipe's
//  `PoTokenWebView`. Like the signature solver this is FRAGILE: if BotGuard or
//  the jnn endpoints change, compare against those projects and yt-dlp's
//  PO Token guide. Failures are logged and playback continues without `pot`.
//

import Foundation
import WebKit

enum PoTokenError: LocalizedError {
    case badResponse(String)
    case botGuard(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let m): "Unexpected BotGuard service response: \(m)"
        case .botGuard(let m):    "BotGuard failed: \(m)"
        }
    }
}

/// The parts of a `jnn/v1/Create` challenge needed to run BotGuard.
nonisolated struct BotGuardChallenge: Sendable, Equatable {
    let interpreterJavaScript: String
    let program: String
    let globalName: String
}

/// Network-free parsing for the BotGuard service payloads (unit-tested).
nonisolated enum PoTokenCodec {
    /// Parses a `jnn/v1/Create` response. The challenge comes either as a plain
    /// nested array or scrambled: base64 of a JSON array with every byte shifted
    /// down by 97.
    static func challenge(fromCreateResponse data: Data) throws -> BotGuardChallenge {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw PoTokenError.badResponse("Create is not a JSON array")
        }

        let fields: [Any]
        if outer.count > 1, let scrambled = outer[1] as? String {
            guard let bytes = bytes(fromYouTubeBase64: scrambled) else {
                throw PoTokenError.badResponse("Create challenge is not base64")
            }
            let descrambled = Data(bytes.map { $0 &+ 97 })
            guard let array = try? JSONSerialization.jsonObject(with: descrambled) as? [Any] else {
                throw PoTokenError.badResponse("descrambled challenge is not a JSON array")
            }
            fields = array
        } else if let array = outer.first as? [Any] {
            fields = array
        } else {
            throw PoTokenError.badResponse("Create has no challenge")
        }

        guard fields.count > 5,
              let interpreter = (fields[1] as? [Any])?.first(where: { $0 is String }) as? String,
              let program = fields[4] as? String,
              let globalName = fields[5] as? String else {
            throw PoTokenError.badResponse("challenge is missing interpreter/program/globalName")
        }
        return BotGuardChallenge(interpreterJavaScript: interpreter, program: program, globalName: globalName)
    }

    /// Parses a `jnn/v1/GenerateIT` response: `[integrityTokenBase64, lifetimeSeconds, …]`.
    static func integrityToken(fromGenerateITResponse data: Data) throws -> (token: [UInt8], lifetime: TimeInterval) {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let encoded = array.first as? String,
              let token = bytes(fromYouTubeBase64: encoded) else {
            throw PoTokenError.badResponse("GenerateIT has no integrity token")
        }
        let lifetime = (array.count > 1 ? array[1] as? NSNumber : nil)?.doubleValue ?? 3600
        return (token, lifetime)
    }

    /// Decodes YouTube's base64 flavour (URL-safe alphabet, `.` as padding,
    /// padding often omitted).
    static func bytes(fromYouTubeBase64 string: String) -> [UInt8]? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: ".", with: "=")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64).map { [UInt8]($0) }
    }

    /// Encodes a minted token the way the web player puts it in `pot`.
    static func potString(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

/// Mints GVS PO tokens with BotGuard in a hidden WKWebView. Each mint uses a
/// fresh web view that is dropped right after: a BotGuard VM left idle in a
/// hidden page mints later tokens googlevideo rejects, and this way no WebKit
/// process lingers between tracks. Main-actor bound because WebKit is.
@MainActor
final class PoTokenProvider {
    static let shared = PoTokenProvider()

    private struct MintedToken {
        let value: String
        let expiry: Date
    }

    private var tokens: [String: MintedToken] = [:]
    private var pending: [String: Task<MintedToken, Error>] = [:]
    private let session = NetworkSession.make()

    // Public constants of the web player's BotGuard integration (as used by
    // BgUtils/NewPipe): the jnn API key and the "request key" of the program.
    private static let apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    /// Must match the engine BotGuard runs in. A Chrome user agent on WebKit
    /// yields an integrity token that mints tokens googlevideo rejects (403).
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// The `pot` value for a content binding (video id, `datasyncId` or
    /// `visitorData`; see `StreamResolver`). Cached until it expires;
    /// concurrent requests for the same binding share one mint.
    func token(for binding: String) async throws -> String {
        if let cached = tokens[binding], cached.expiry > Date() { return cached.value }
        if let task = pending[binding] { return try await task.value.value }

        let task = Task { try await self.mint(for: binding) }
        pending[binding] = task
        defer { pending[binding] = nil }

        let minted = try await task.value
        tokens = tokens.filter { $0.value.expiry > Date() } // per-video bindings pile up
        tokens[binding] = minted
        return minted.value
    }

    // MARK: - Minting

    private func mint(for binding: String) async throws -> MintedToken {
        let started = Date()
        let webView = try await loadBlankPlayerPage()
        defer { webView.stopLoading() } // dropped on return; WebKit then ends its process

        let createData = try await postBotGuardService("Create", body: [Self.requestKey])
        let challenge = try PoTokenCodec.challenge(fromCreateResponse: createData)

        let snapshot = try await webView.callAsyncJavaScript(
            Self.runBotGuardScript,
            arguments: [
                "interpreter": challenge.interpreterJavaScript,
                "program": challenge.program,
                "globalName": challenge.globalName,
            ],
            contentWorld: .page
        )
        guard let botGuardResponse = snapshot as? String, !botGuardResponse.isEmpty else {
            throw PoTokenError.botGuard("snapshot returned nothing")
        }

        let itData = try await postBotGuardService("GenerateIT", body: [Self.requestKey, botGuardResponse])
        let integrity = try PoTokenCodec.integrityToken(fromGenerateITResponse: itData)

        let result = try await webView.callAsyncJavaScript(
            Self.mintScript,
            arguments: ["integrityToken": integrity.token.map(Int.init), "binding": binding],
            contentWorld: .page
        )
        guard let numbers = result as? [NSNumber], !numbers.isEmpty else {
            throw PoTokenError.botGuard("minter returned no bytes")
        }

        // Renew ten minutes early so a token never expires mid-track.
        let lifetime = max(integrity.lifetime - 600, 60)
        PlaybackLog.note(String(format: "potoken: minted in %.1fs", Date().timeIntervalSince(started)))
        return MintedToken(
            value: PoTokenCodec.potString(numbers.map(\.uint8Value)),
            expiry: Date().addingTimeInterval(lifetime)
        )
    }

    /// A hidden web view on an empty page with a youtube.com origin, which is
    /// where BotGuard expects to run. It needs no cookies or storage.
    private func loadBlankPlayerPage() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.customUserAgent = Self.userAgent

        let loader = PageLoadObserver()
        webView.navigationDelegate = loader
        try await loader.load(
            "<!DOCTYPE html><html><head><title></title></head><body></body></html>",
            baseURL: URL(string: "https://www.youtube.com")!,
            in: webView
        )
        webView.navigationDelegate = nil
        return webView
    }

    private func postBotGuardService(_ method: String, body: [String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/api/jnn/v1/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PoTokenError.badResponse("\(method) HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: - Scripts

    /// Loads the challenge's VM, runs the program and takes a snapshot. Leaves
    /// BotGuard's `webPoSignalOutput` (which holds the minter factory) on the
    /// page and returns the snapshot string for GenerateIT.
    private static let runBotGuardScript = """
    new Function(interpreter)();
    const vm = window[globalName];
    if (!vm || !vm.a) throw new Error("BotGuard VM not found");

    let vmFunctions = null;
    const ready = (asyncSnapshot, shutdown, passEvent, checkCamera) => {
        vmFunctions = { asyncSnapshot };
    };
    vm.a(program, ready, true, undefined, () => {}, [[], []]);

    // The VM finishes initialising in the background and then calls `ready`.
    for (let i = 0; !vmFunctions; i++) {
        if (i > 1000) throw new Error("BotGuard VM did not initialise");
        await new Promise(r => setTimeout(r, 10));
    }

    const webPoSignalOutput = [];
    const response = await new Promise(resolve =>
        vmFunctions.asyncSnapshot(resolve, [undefined, undefined, webPoSignalOutput, undefined]));
    window.__ytWebPoSignalOutput = webPoSignalOutput;
    return response;
    """

    /// Mints the token for `binding` from the integrity token and returns its
    /// bytes as plain numbers.
    private static let mintScript = """
    const getMinter = window.__ytWebPoSignalOutput && window.__ytWebPoSignalOutput[0];
    if (!getMinter) throw new Error("BotGuard minter missing");
    const mint = await getMinter(new Uint8Array(integrityToken));
    if (typeof mint !== "function") throw new Error("BotGuard minter is not a function");
    const token = await mint(new TextEncoder().encode(binding));
    if (!(token instanceof Uint8Array)) throw new Error("minted token is not bytes");
    return Array.from(token);
    """
}

/// Bridges a one-off `loadHTMLString` to async/await.
@MainActor
private final class PageLoadObserver: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, baseURL: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
