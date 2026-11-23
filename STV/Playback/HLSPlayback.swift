import AVFoundation

/// Plays huangguo HLS (incl. AES-128) through AVPlayer.
/// Playlists are fetched through a resourceLoader so we can attach Referer/Origin/X-User-Agent,
/// and EXT-X-KEY URIs are rewritten to a local scheme that serves the key we already resolved.
///
/// AVFCore throws NSInternalInconsistencyException from `finishLoadingWithError:` when a request
/// is finished twice or after cancellation; the exception escapes the dispatch block on the loader
/// queue and terminates the process (std::terminate, SIGABRT — see STV-2026-11-23-125006/144458).
/// Both the synchronous delegate body and the network completion are therefore wrapped in the
/// Objective-C exception guard (HLSGuardExceptions): whatever AVFCore throws is logged and
/// swallowed, degrading to a failed load / retry instead of a crash.
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
    /// delegate would crash. Self-retain while any accepted request is unsettled.
    private let lock = NSLock()
    private var inflight = 0
    private var selfKeep: HLSPlayback?
    /// Requests ever accepted — entries are NEVER removed, so a re-delivered request object is
    /// always refused instead of being handled (and finished) a second time. The set dies with
    /// the instance; the loader only sees playlists and AES keys, not segments.
    private var accepted: Set<ObjectIdentifier> = []
    /// Accepted but not yet settled requests (finished by us or cancelled by AVFCore).
    private var unsettled: Set<ObjectIdentifier> = []

    init(headers: [String: String], keyHex: String) {
        self.headers = headers
        self.keyHex = keyHex
        super.init()
    }

    /// Release the in-flight count for a request. Returns true exactly once per request — the
    /// first settle (later ones from didCancel after finish, or catch handlers, are no-ops).
    @discardableResult
    private func settle(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        let wasUnsettled = unsettled.remove(id) != nil
        if wasUnsettled {
            inflight = max(0, inflight - 1)
            if inflight == 0 { selfKeep = nil }
        }
        lock.unlock()
        return wasUnsettled
    }

    /// Finish a request only while AVFCore still considers it live. The cancellation flag is set
    /// inside AVFCore immediately, while the didCancel callback only queues on our serial queue.
    private func finish(_ req: AVAssetResourceLoadingRequest, error: Error?) {
        guard !req.isCancelled else { return }
        if let error { req.finishLoading(with: error) } else { req.finishLoading() }
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
        final class Box { var handled = false }
        let box = Box()
        let clean = HLSGuardExceptions("hls.shouldWait") { [weak self] in
            guard let self else { return }
            box.handled = self.handleResourceLoader(loader, req: req)
        }
        if !clean { settle(ObjectIdentifier(req)) }   // idempotent; the body may have settled already
        return box.handled
    }

    /// Called inside the exception guard: anything thrown here degrades to `handled = false`
    /// (AVFCore fails the request; the player surfaces a retryable error) instead of a crash.
    private func handleResourceLoader(_ loader: AVAssetResourceLoader, req: AVAssetResourceLoadingRequest) -> Bool {
        lock.lock()
        let first = accepted.insert(ObjectIdentifier(req)).inserted
        if first {
            unsettled.insert(ObjectIdentifier(req))
            inflight += 1
            if inflight == 1 { selfKeep = self }
        }
        lock.unlock()
        // Same request object delivered again: it was already handled (and finished) once —
        // never touch it again, a second finishLoading throws.
        guard first else { return false }
        // AVFCore may deliver a request whose cancellation flag is already set (the didCancel
        // callback only queues later). Touching such a request throws — refuse it; settle() is
        // idempotent, so the queued didCancel becomes a no-op.
        guard !req.isCancelled else { settle(ObjectIdentifier(req)); return true }
        guard let url = req.request.url, let scheme = url.scheme else {
            finish(req, error: URLError(.badURL))
            settle(ObjectIdentifier(req))
            return true
        }
        if scheme == Self.keyScheme {
            guard let key = Bytes.fromHex(keyHex), key.count == 16 else {
                finish(req, error: URLError(.userAuthenticationRequired))
                settle(ObjectIdentifier(req))
                return true
            }
            guard !req.isCancelled else { settle(ObjectIdentifier(req)); return true }
            req.contentInformationRequest?.contentType = "public.data"
            req.contentInformationRequest?.contentLength = 16
            req.contentInformationRequest?.isByteRangeAccessSupported = false
            req.dataRequest?.respond(with: Data(key))
            finish(req, error: nil)
            settle(ObjectIdentifier(req))
            return true
        }
        guard scheme.hasPrefix(Self.plScheme), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            settle(ObjectIdentifier(req))
            return false
        }
        c.scheme = scheme.hasSuffix("-http") ? "http" : "https"
        guard let real = c.url else {
            finish(req, error: URLError(.badURL))
            settle(ObjectIdentifier(req))
            return true
        }
        var r = URLRequest(url: real)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        Self.session.dataTask(with: r) { [weak self] data, resp, err in
            guard let self else { return }
            let clean = HLSGuardExceptions("hls.completion") {
                guard self.settle(ObjectIdentifier(req)) else { return }   // didCancel beat us
                guard !req.isCancelled else { return }
                guard let data, err == nil, (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                    self.finish(req, error: err ?? URLError(.badServerResponse))
                    return
                }
                guard !req.isCancelled else { return }
                let text = self.rewrite(HLSAdFilter.apply(String(decoding: data, as: UTF8.self), base: real), base: real)
                req.contentInformationRequest?.contentType = "public.m3u-playlist"
                req.contentInformationRequest?.contentLength = Int64(text.utf8.count)
                req.dataRequest?.respond(with: Data(text.utf8))
                self.finish(req, error: nil)
            }
            if !clean { self.settle(ObjectIdentifier(req)) }   // idempotent
        }.resume()
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        // Only settle — a cancelled request must never be finished.
        settle(ObjectIdentifier(request))
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
