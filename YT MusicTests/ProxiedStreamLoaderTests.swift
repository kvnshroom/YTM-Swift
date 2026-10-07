//
//  ProxiedStreamLoaderTests.swift
//  YT MusicTests
//

import Testing
import Foundation
@testable import YT_Music

@Suite("Proxied stream loader")
struct ProxiedStreamLoaderTests {
    @Test("Only exists when a valid proxy is configured")
    func requiresProxy() {
        #expect(ProxiedStreamLoader(proxyURL: "") == nil)
        #expect(ProxiedStreamLoader(proxyURL: "ftp://host:21") == nil)
        #expect(ProxiedStreamLoader(proxyURL: "http://localhost:8888") != nil)
    }

    @Test("Stream URLs round-trip through the loader scheme")
    func urlRoundTrip() throws {
        let url = URL(string: "https://rr1.googlevideo.com/videoplayback?itag=140&ip=1.2.3.4")!
        let loaderURL = ProxiedStreamLoader.loaderURL(for: url)
        #expect(loaderURL.scheme == ProxiedStreamLoader.scheme)
        #expect(ProxiedStreamLoader.originalURL(for: loaderURL) == url)
        #expect(ProxiedStreamLoader.originalURL(for: url) == nil)
    }

    @Test("Builds Range headers for bounded, open-ended, and whole-resource requests")
    func rangeHeaders() {
        #expect(ProxiedStreamLoader.rangeHeader(offset: 0, length: 2, toEnd: false) == "bytes=0-1")
        #expect(ProxiedStreamLoader.rangeHeader(offset: 100, length: 50, toEnd: false) == "bytes=100-149")
        #expect(ProxiedStreamLoader.rangeHeader(offset: 4096, length: 0, toEnd: true) == "bytes=4096-")
        #expect(ProxiedStreamLoader.rangeHeader(offset: 0, length: 0, toEnd: true) == nil)
    }

    @Test("Reads the total size from Content-Range")
    func contentRange() {
        #expect(ProxiedStreamLoader.totalLength(contentRange: "bytes 0-1/3456789") == 3_456_789)
        #expect(ProxiedStreamLoader.totalLength(contentRange: "bytes */*") == nil)
        #expect(ProxiedStreamLoader.totalLength(contentRange: nil) == nil)
    }
}
