//
//  ProxiedStreamLoader.swift
//  YT Music
//
//  AVPlayer fetches media with the system network settings and has no proxy
//  option. When a proxy is configured, stream URLs are rewritten to a custom
//  scheme so AVFoundation hands every byte-range request to this loader, which
//  performs it through the proxied URLSession.
//

import AVFoundation
import UniformTypeIdentifiers

nonisolated final class ProxiedStreamLoader: NSObject, AVAssetResourceLoaderDelegate,
                                             URLSessionDataDelegate, @unchecked Sendable {
    static let scheme = "ytm-proxied"

    /// Serializes resource-loader and URLSession callbacks, guarding `requests`.
    let queue = DispatchQueue(label: "moe.tenshii.YT-Music.proxied-stream")
    private var session: URLSession!
    private var requests: [Int: AVAssetResourceLoadingRequest] = [:]

    /// nil when no valid proxy is configured; streams then load directly.
    init?(proxyURL: String? = nil) {
        let value = proxyURL ?? UserDefaults.standard.string(forKey: NetworkSession.proxyDefaultsKey)
        guard let proxy = value.flatMap(NetworkProxy.init(string:)) else { return nil }
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = proxy.connectionProxyDictionary
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    static func loaderURL(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url ?? url
    }

    static func originalURL(for url: URL) -> URL? {
        guard url.scheme == scheme,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// The `Range` header value for a data request, or nil to fetch the whole resource.
    static func rangeHeader(offset: Int64, length: Int, toEnd: Bool) -> String? {
        if toEnd { return offset == 0 ? nil : "bytes=\(offset)-" }
        return "bytes=\(offset)-\(offset + Int64(length) - 1)"
    }

    /// The total resource size from a `Content-Range: bytes a-b/total` header.
    static func totalLength(contentRange: String?) -> Int64? {
        guard let total = contentRange?.split(separator: "/").last else { return nil }
        return Int64(total)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url.flatMap(Self.originalURL(for:)) else { return false }
        var request = URLRequest(url: url)
        if let dataRequest = loadingRequest.dataRequest,
           let range = Self.rangeHeader(offset: dataRequest.requestedOffset,
                                        length: dataRequest.requestedLength,
                                        toEnd: dataRequest.requestsAllDataToEndOfResource) {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        requests[task.taskIdentifier] = loadingRequest
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let id = requests.first(where: { $0.value === loadingRequest })?.key else { return }
        requests[id] = nil
        session.getAllTasks { tasks in
            tasks.first { $0.taskIdentifier == id }?.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let loadingRequest = requests[dataTask.taskIdentifier],
              let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            requests[dataTask.taskIdentifier] = nil
            loadingRequest.finishLoading(with: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = http.mimeType.flatMap { UTType(mimeType: $0)?.identifier }
                ?? UTType.mpeg4Audio.identifier
            info.contentLength = Self.totalLength(contentRange: http.value(forHTTPHeaderField: "Content-Range"))
                ?? http.expectedContentLength
            info.isByteRangeAccessSupported = true
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        requests[dataTask.taskIdentifier]?.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let loadingRequest = requests.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            loadingRequest.finishLoading(with: error)
        } else {
            loadingRequest.finishLoading()
        }
    }
}
