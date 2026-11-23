import AVFoundation

/// Plays huangguo HLS (incl. AES-128) through AVPlayer.
/// Playlists are fetched through a resourceLoader so we can attach Referer/Origin/X-User-Agent,
/// and EXT-X-KEY URIs are rewritten to a local scheme that serves the key we already resolved.
final class HLSPlayback: NSObject, AVAssetResourceLoaderDelegate {
    static let plScheme = "stvhls"
    static let keyScheme = "stvkey"

    let headers: [String: String]
    let keyHex: String
    private let queue = DispatchQueue(label: "stv.hls.loader")
    /// Shared per process: every loader used to spin up its own URLSession, leaking one per episode.
    private static let session = URLSession(configuration: .default)

    /// `AVAssetResourceLoader` holds its delegate UNRETAINED and can still invoke it while the
    /// playback pipeline drains after the coordinator dropped this source — messaging the freed
    /// delegate ends in SIGSEGV or an escaping exception (std::terminate on stv.hls.loader).
    /// Self-retain while any request is in flight so the delegate always outlives its callbacks.
    private let lock = NSLock()
    private var inflight = 0
    private var selfKeep: HLSPlayback?
    /// Loading requests we accepted and have not settled yet. Membership IS the once-semantics:
    /// a request leaves this set exactly once (network completion or didCancel).
    private var openRequests: Set<ObjectIdentifier> = []

    init(headers: [String: String], keyHex: String) {
        self.headers = headers
        self.keyHex = keyHex
        super.init()
    }

    private func retainWhileBusy() {
        lock.lock(); inflight += 1
        if inflight == 1 { selfKeep = self }
        lock.unlock()
    }

    /// Settle a loading request. Returns true exactly once per request — the caller that gets true
    /// may call finishLoading; finishLoading on an already-settled or cancelled request throws
    /// NSInternalInconsistencyException.
    @discardableResult
    private func settle(_ req: AVAssetResourceLoadingRequest) -> Bool {
        lock.lock()
        let wasOpen = openRequests.remove(ObjectIdentifier(req)) != nil
        if wasOpen {
            inflight = max(0, inflight - 1)
            if inflight == 0 { selfKeep = nil }
        }
        lock.unlock()
        return wasOpen
    }

    func makeAsset(url: String) -> AVURLAsset? {
        guard var c = URLComponents(string: url) else { return nil }
        let isHLS = url.lowercased().contains(".m3u8") || url.contains("/m3u8/")
        if isHLS { c.scheme = c.scheme == "http" ? Self.plScheme + "-http" : Self.plScheme }
        guard let u = c.url else { return nil }
        let asset = AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        if isHLS { asset.resourceLoader.setDelegate(self, queue: queue) }
        return asset
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        retainWhileBusy()
        lock.lock(); openRequests.insert(ObjectIdentifier(req)); lock.unlock()
        guard let url = req.request.url, let scheme = url.scheme else {
            settle(req); req.finishLoading(with: URLError(.badURL)); return true
        }
        if scheme == Self.keyScheme {
            settle(req)
            guard let key = Bytes.fromHex(keyHex), key.count == 16 else { req.finishLoading(with: URLError(.userAuthenticationRequired)); return true }
            req.contentInformationRequest?.contentType = "public.data"
            req.contentInformationRequest?.contentLength = 16
            req.contentInformationRequest?.isByteRangeAccessSupported = false
            req.dataRequest?.respond(with: Data(key))
            req.finishLoading()
            return true
        }
        guard scheme.hasPrefix(Self.plScheme), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            settle(req); return false
        }
        c.scheme = scheme.hasSuffix("-http") ? "http" : "https"
        guard let real = c.url else {
            settle(req); req.finishLoading(with: URLError(.badURL)); return true
        }
        var r = URLRequest(url: real)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        Self.session.dataTask(with: r) { [weak self] data, resp, err in
            guard let self, self.settle(req) else { return }
            guard let data, err == nil, (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                req.finishLoading(with: err ?? URLError(.badServerResponse)); return
            }
            let text = self.rewrite(HLSAdFilter.apply(String(decoding: data, as: UTF8.self), base: real), base: real)
            req.contentInformationRequest?.contentType = "public.m3u-playlist"
            req.contentInformationRequest?.contentLength = Int64(text.utf8.count)
            req.dataRequest?.respond(with: Data(text.utf8))
            req.finishLoading()
        }.resume()
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        // Only release here — the request must not be finished once cancelled.
        settle(request)
    }

    /// Absolutize URIs; nested playlists go back through the loader, keys go to the local key scheme.
    private func rewrite(_ pl: String, base: URL) -> String {
        func abs(_ s: String) -> URL? { URL(string: s, relativeTo: base)?.absoluteURL }
        func via(_ u: URL, _ scheme: String) -> String {
            var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
            c?.scheme = scheme == Self.plScheme && u.scheme == "http" ? Self.plScheme + "-http" : scheme
            return c?.url?.absoluteString ?? u.absoluteString
        }
        var expectPlaylist = false
        return pl.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("#EXT-X-STREAM-INF") { expectPlaylist = true; return line }
            if line.uppercased().hasPrefix("#EXT-X-KEY") || line.uppercased().hasPrefix("#EXT-X-MEDIA") || line.uppercased().hasPrefix("#EXT-X-MAP") {
                let isKey = line.uppercased().hasPrefix("#EXT-X-KEY")
                guard let m = HTML.groups("URI\\s*=\\s*\"([^\"]+)\"", line), let u = abs(m[1]) else { return line }
                let repl: String
                if isKey { repl = keyHex.isEmpty ? u.absoluteString : Self.keyScheme + "://key" }
                else if line.uppercased().hasPrefix("#EXT-X-MEDIA") { repl = via(u, Self.plScheme) }
                else { repl = u.absoluteString }
                return line.replacingOccurrences(of: m[1], with: repl)
            }
            if line.isEmpty || line.hasPrefix("#") { return line }
            guard let u = abs(line) else { return line }
            defer { expectPlaylist = false }
            return expectPlaylist || u.path.lowercased().hasSuffix(".m3u8") ? via(u, Self.plScheme) : u.absoluteString
        }.joined(separator: "\n")
    }
}
