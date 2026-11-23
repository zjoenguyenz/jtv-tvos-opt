import Foundation
import AVFoundation

/// HLS rescue layer for CDNs that disguise streams as images.
///
/// Some hosts (e.g. RapPhim's cloud152/nebula packaging) serve the
/// playlist itself as `1080p/playlist.jpg` with Content-Type
/// image/jpeg, and the fMP4 segments as .jpg files, also image/jpeg.
/// Android/ExoPlayer sniffs the #EXTM3U magic and plays anyway;
/// AVPlayer trusts the declared type and refuses the asset outright.
///
/// This loader serves the stream to AVPlayer through a custom URL
/// scheme instead: it fetches every resource itself (URLSession does
/// not care about the declared type), rewrites playlist URIs so all
/// nested resources come back through the loader, sniffs binary
/// payloads, and reports correct content types to AVFoundation.
///
/// It is used as a FALLBACK only: the player first tries the plain
/// URL, and only a failed AVPlayerItem triggers the proxied retry —
/// sources that already play natively are never touched.
///
/// @unchecked Sendable: every piece of mutable state below is
/// guarded by `lock`; delegate callbacks arrive on the loader's own
/// queue and never touch state outside the lock.
final class HLSProxyLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "jtvhls"

    private let headers: [String: String]
    /// v1.22: ONE shared session for every loader instance (was:
    /// a new session per playback, never invalidated), and the
    /// per-request timeout drops 30 s → 15 s so a dead segment
    /// host surfaces inside the player's stall budget on the
    /// first attempt instead of the third.
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()
    private let session: URLSession
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var cancelled: Set<ObjectIdentifier> = []
    private let lock = NSLock()
    /// Playlists already rewritten, by requested URL. Only playlists
    /// are cached (they are tiny); segments are fetched per request
    /// and never retained — a whole movie of segments would exhaust
    /// memory.
    private var cache: [String: (data: Data, contentType: String)] = [:]

    init(headers: [String: String]) {
        self.headers = headers
        self.session = Self.sharedSession
        super.init()
    }

    // MARK: - URL wrapping
    //
    // The original URL travels base64url-encoded in the query: pure
    // [A-Za-z0-9_-] characters, so no percent-encoding ambiguity can
    // creep in across AVFoundation's URL handling.

    static func proxiedURL(for url: URL) -> URL? {
        let b64 = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(scheme)://h/?u=\(b64)")
    }

    static func originalURL(from proxied: URL) -> URL? {
        guard let comps = URLComponents(url: proxied, resolvingAgainstBaseURL: false),
              var b64 = comps.queryItems?.first(where: { $0.name == "u" })?.value else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: string)
    }

    /// The loader-free path for playlists that flatten completely
    /// to plain public URLs (the streamxx pattern). Safari proved
    /// the point on the user's phone (2026-11-14): the rewritten
    /// playlist — same bytes this loader produces — played
    /// INSTANTLY when served as a plain playlist over the network,
    /// while the same playlist served through this custom-scheme
    /// loader never played on his device. So: fetch the playlist,
    /// rewrite it with the exact loader rules, verify that
    /// nothing in the result still points at this scheme or at a
    /// dead proxy path, and hand the caller BOTH a local file
    /// copy and the bytes themselves (the caller also serves the
    /// bytes from a loopback HTTP server — the in-app replica of
    /// the shape Safari played). Returns nil whenever anything
    /// still needs the loader (variant playlists, disguised
    /// segments), so the caller keeps the proxied asset.
    ///
    /// The vid-snap family is the one exception, and it is not
    /// an exemption: its master is flattened two-tier to the
    /// loopback server BEFORE the acceptance guard below runs
    /// (see flattenVidSnapMaster), so what passes the guard has
    /// honestly had the scheme removed from its bytes. The
    /// media-tier loopback URLs that flatten registered ride
    /// back in `loopbackURLs` for the caller's teardown
    /// bookkeeping ([] on every other path, the master itself
    /// excluded — the caller registers that from `data`).
    static func materializedPlaylist(url: URL, headers: [String: String]) async -> (fileURL: URL, data: Data, loopbackURLs: [URL])? {
        guard let (data, finalURL) = await fetchWithPolicy(url: url, headers: headers, logFailures: true) else {
            return nil
        }
        let scratch = HLSProxyLoader(headers: headers)
        var prepared = scratch.prepare(data: data, finalURL: finalURL)
        var loopbackURLs: [URL] = []
        // L-25 round 3 (FL-468): the vid-snap two-tier flatten.
        // Entry — ALL must hold, else control falls to the
        // guard below with `prepared` untouched: the prepared
        // body is a playlist, the fetch's FINAL (post-redirect)
        // host is the vid-snap family (the same predicate
        // markProxyIfNeeded marks by), and the body is a
        // master. On success `prepared` becomes the flattened
        // master and flows into the guard and the file write
        // exactly as a classic body does; on any decline the
        // flatten has already deregistered whatever it
        // registered and `prepared` is still today's bytes.
        if prepared.contentType == "com.apple.mpegurl",
           Self.isVidSnapFamily(finalURL),
           let masterText = String(data: prepared.data, encoding: .utf8),
           masterText.contains("#EXT-X-STREAM-INF"),
           let flattened = await flattenVidSnapMaster(masterText, headers: headers) {
            prepared = (data: Data(flattened.text.utf8), contentType: "com.apple.mpegurl")
            loopbackURLs = flattened.registered
        }
        guard prepared.contentType == "com.apple.mpegurl",
              let text = String(data: prepared.data, encoding: .utf8),
              !text.contains("\(scheme)://"),
              !text.contains("__hls_proxy/") else {
            DiagLog.log("hls", "phase=materialize outcome=needs-loader")
            return nil
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hls-local", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Stable per-URL file name (FNV-1a). The file is
        // rewritten from a fresh fetch on every play, so a
        // same-name file always holds the current playlist.
        var hash: UInt64 = 1469598103934665603
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let file = dir.appendingPathComponent("pl-\(hash).m3u8")
        guard (try? prepared.data.write(to: file, options: .atomic)) != nil else {
            // G1-1: a write failure AFTER a successful flatten
            // must not strand the flatten's registrations — a
            // nil return hands the caller nothing to release,
            // so deregister them here (the F7 cleanup,
            // mirrored) before declining.
            for loopbackURL in loopbackURLs {
                await LocalHLSServer.shared.deregister(loopbackURL)
            }
            DiagLog.log("hls", "phase=materialize outcome=write-failed")
            return nil
        }
        return (fileURL: file, data: prepared.data, loopbackURLs: loopbackURLs)
    }

    /// The fetch policy materializedPlaylist has always used,
    /// factored out so the vid-snap flatten's variant fetches
    /// ride the exact same policy: 3 attempts, fail-fast on a
    /// status below 500, 1 s / 2 s backoff. (Same retry policy
    /// as the loader: the origins behind these playlists drop
    /// response bodies mid-transfer, and one dropped fetch
    /// used to abandon the whole ladder.) `logFailures` keeps
    /// the two failure lines attached to the master call only,
    /// as before — variant failures surface as the flatten's
    /// own decline line instead.
    private static func fetchWithPolicy(url: URL, headers: [String: String],
                                        logFailures: Bool) async -> (data: Data, finalURL: URL)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        for attempt in 1...3 {
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    return (data, http.url ?? url)
                }
                if http.statusCode < 500 {
                    // v1.22.15 (B-2, H-1): failure line only —
                    // status class, never the URL (DiagLog law).
                    if logFailures {
                        DiagLog.log("hls", "phase=materialize outcome=http-error status=\(http.statusCode)")
                    }
                    return nil // dead/geo: fail fast
                }
            }
            if attempt < 3 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
        }
        if logFailures {
            DiagLog.log("hls", "phase=materialize outcome=fetch-failed")
        }
        return nil
    }

    /// L-25 round 3 (FL-468): the two-tier loopback flatten of
    /// a PREPARED vid-snap master. The round-2 conviction: the
    /// loader's rewritten master is valid HLS whose only
    /// variant line points at a jtvhls:// URL, and AVPlayer
    /// never issues the playlist-internal variant request to
    /// the resource-loader delegate — it dies with -11850 one
    /// tier above the media playlist round 2 fixed. So both
    /// tiers are flattened to the loopback server here, before
    /// AVPlayer ever sees them: each referenced sub-playlist
    /// is fetched and prepared by the same machinery (the
    /// media tier rewritten by the round-2 rules, its segments
    /// staying direct), registered with LocalHLSServer, and
    /// the master's references are repointed at the loopback
    /// URLs. Both tiers then arrive as ordinary network
    /// resources — the only shape this app has ever played.
    ///
    /// Any failure declines: ONE flatten-declined line naming
    /// the stage, everything this call registered is
    /// deregistered (no partial flatten ever escapes), and the
    /// caller falls through to the acceptance guard with the
    /// original prepared master — today's exact behaviour.
    private static func flattenVidSnapMaster(_ masterText: String,
                                             headers: [String: String]) async -> (text: String, registered: [URL])? {
        var registered: [URL] = []
        // F7: a decline after ≥1 registration deregisters
        // everything this call registered before returning.
        func decline(_ stage: String) async -> (text: String, registered: [URL])? {
            for url in registered {
                await LocalHLSServer.shared.deregister(url)
            }
            DiagLog.log("hls", "phase=materialize outcome=flatten-declined stage=\(stage)")
            return nil
        }

        // F1 — collect the sub-playlist references from the
        // PREPARED master text, in document order: bare URI
        // lines (each a jtvhls:// URL produced by wrap) and
        // URI="…" attribute values on tag lines (the
        // #EXT-X-MEDIA rendition case, wrapped by
        // rewriteTagLine). Each is decoded with
        // originalURL(from:) back to its origin URL — the
        // exact wrap encoding is reused; no second parser of
        // the origin master exists. Zero references, or any
        // reference that is not a decodable jtvhls:// URL (a
        // direct URL left by decodeProxyWrapped, a malformed
        // line), declines: shapes this flatten does not take.
        struct Ref { let line: Int; let value: String; let origin: URL }
        var refs: [Ref] = []
        var lines = masterText.components(separatedBy: "\n")
        let uriRegex = try? NSRegularExpression(pattern: "URI=\"([^\"]*)\"")
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#") {
                guard line.contains("URI=\""), let uriRegex else { continue }
                let ns = line as NSString
                let matches = uriRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
                for match in matches where match.numberOfRanges > 1 {
                    let value = ns.substring(with: match.range(at: 1))
                    guard let wrapped = URL(string: value), wrapped.scheme == scheme,
                          let origin = Self.originalURL(from: wrapped) else {
                        return await decline("master-parse")
                    }
                    refs.append(Ref(line: index, value: value, origin: origin))
                }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let wrapped = URL(string: line), wrapped.scheme == scheme,
                      let origin = Self.originalURL(from: wrapped) else {
                    return await decline("master-parse")
                }
                refs.append(Ref(line: index, value: line, origin: origin))
            }
        }
        guard !refs.isEmpty else {
            return await decline("master-parse")
        }

        // F2–F4 — for each distinct referenced playlist, in
        // document order: fetch it through the shared policy,
        // prepare it through a scratch loader (the same
        // classification + rewritePlaylist path the delegate
        // uses, so the media tier is rewritten by the round-2
        // rules and the direct-segments witness fires there),
        // shape-check it as a MEDIA playlist, apply the
        // guard's own acceptance test per tier, and register
        // it. F3 is where round 2's tag rule bites by design:
        // rewriteTagLine never forwards directSegments, so a
        // #EXT-X-KEY / #EXT-X-MAP / #EXT-X-MEDIA URI inside a
        // variant stays jtvhls://-wrapped, leaves the scheme
        // in the text, and declines the whole flatten — an
        // encrypted or mapped variant stays on today's path
        // instead of being handed a third transport.
        let scratch = HLSProxyLoader(headers: headers)
        var loopbackByOrigin: [URL: URL] = [:]
        var variantCount = 0
        for ref in refs where loopbackByOrigin[ref.origin] == nil {
            guard let (tierData, tierFinalURL) = await fetchWithPolicy(url: ref.origin, headers: headers, logFailures: false) else {
                return await decline("variant-fetch")
            }
            let tier = scratch.prepare(data: tierData, finalURL: tierFinalURL)
            guard tier.contentType == "com.apple.mpegurl",
                  let tierText = String(data: tier.data, encoding: .utf8),
                  tierText.contains("#EXTINF:"),
                  !tierText.contains("#EXT-X-STREAM-INF") else {
                return await decline("variant-shape")
            }
            guard !tierText.contains("\(scheme)://"),
                  !tierText.contains("__hls_proxy/") else {
                return await decline("variant-wrapped")
            }
            guard let loopback = await LocalHLSServer.shared.register(tier.data) else {
                return await decline("register")
            }
            registered.append(loopback)
            loopbackByOrigin[ref.origin] = loopback
            variantCount += 1
        }

        // F5 — substitute each reference with its loopback
        // URL: bare lines whole-line, URI="…" values in
        // place at the captured match range — the same
        // regex shape rewriteTagLine uses (§3.1 F5), never
        // a first-occurrence search on the raw value, so a
        // value that also appears elsewhere in its line
        // cannot be substituted at the wrong occurrence.
        // References are processed in reverse document
        // order (rewriteTagLine's order) so a substitution
        // can never shift the range of one still pending.
        // Every other master byte passes through
        // untouched — in particular the #EXT-X-STREAM-INF
        // attribute line is never modified (the conviction
        // verified that line's integrity is load-bearing).
        for ref in refs.reversed() {
            guard let loopback = loopbackByOrigin[ref.origin] else { continue }
            if lines[ref.line] == ref.value {
                lines[ref.line] = loopback.absoluteString
            } else if let uriRegex {
                let ns = lines[ref.line] as NSString
                let matches = uriRegex.matches(in: lines[ref.line], range: NSRange(location: 0, length: ns.length))
                for match in matches.reversed() where match.numberOfRanges > 1 {
                    guard ns.substring(with: match.range(at: 1)) == ref.value else { continue }
                    lines[ref.line] = ns.replacingCharacters(in: match.range(at: 1), with: loopback.absoluteString)
                    break
                }
            }
        }

        // F6 — final acceptance: the flattened master must
        // itself pass the guard's own test before it may flow
        // into the code below the guard. A residue means the
        // master held a wrapped reference F1 did not collect.
        let flattenedText = lines.joined(separator: "\n")
        guard !flattenedText.contains("\(scheme)://"),
              !flattenedText.contains("__hls_proxy/") else {
            return await decline("master-parse")
        }
        let flattenedData = Data(flattenedText.utf8)
        DiagLog.log("hls", "phase=materialize outcome=loopback-flatten variants=\(variantCount) bytes=\(flattenedData.count)")
        return (text: flattenedText, registered: registered)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              requestURL.scheme == Self.scheme,
              let original = Self.originalURL(from: requestURL) else {
            // v1.22.15 (B-2, H-1): declined request — failure
            // line only, no URL material (DiagLog law).
            DiagLog.log("hls", "phase=load outcome=bad-request")
            return false
        }

        let key = original.absoluteString
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached {
            respond(loadingRequest, data: cached.data, contentType: cached.contentType)
            return true
        }

        var request = URLRequest(url: original)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        startFetch(request, original: original, key: key, loadingRequest: loadingRequest, attempt: 1)
        return true
    }

    /// One loader fetch, with the TV player's retry policy
    /// (Joe TV's RetryPolicy, proven on these same sources):
    /// network hiccups and 5xx retry up to 3 attempts with
    /// 1 s / 2 s backoff — Film4K's origin measurably drops
    /// response bodies mid-transfer, and a single dropped
    /// fetch used to kill the whole item — while a dead or
    /// geo-blocked response (4xx) fails at once so the
    /// transport ladder can move on instead of burning time.
    private func startFetch(_ request: URLRequest, original: URL, key: String,
                            loadingRequest: AVAssetResourceLoadingRequest, attempt: Int) {
        let id = ObjectIdentifier(loadingRequest)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.lock.lock()
            self.tasks.removeValue(forKey: id)
            let wasCancelled = self.cancelled.remove(id) != nil
            self.lock.unlock()
            if wasCancelled || loadingRequest.isFinished { return }
            let status = (response as? HTTPURLResponse)?.statusCode
            let retryable = error != nil || (status.map { $0 >= 500 } ?? false)
            if retryable, attempt < 3 {
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(attempt)) { [weak self] in
                    guard let self, !loadingRequest.isFinished else { return }
                    self.lock.lock()
                    let cancelledNow = self.cancelled.remove(id) != nil
                    self.lock.unlock()
                    if !cancelledNow {
                        self.startFetch(request, original: original, key: key,
                                        loadingRequest: loadingRequest, attempt: attempt + 1)
                    }
                }
                return
            }
            if let error {
                // v1.22.15 (B-2, H-1): final failure only (after
                // the retry policy above is exhausted) — error
                // kind as domain#code, never the URL or raw text.
                // Per-resource successes are deliberately not
                // logged (ring volume).
                DiagLog.log("hls", "phase=fetch outcome=network-error kind=\((error as NSError).domain)#\((error as NSError).code) attempt=\(attempt)")
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let data, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                if let status {
                    DiagLog.log("hls", "phase=fetch outcome=http-error status=\(status) attempt=\(attempt)")
                } else {
                    DiagLog.log("hls", "phase=fetch outcome=bad-response attempt=\(attempt)")
                }
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }
            let finalURL = http.url ?? original
            let served = self.prepare(data: data, finalURL: finalURL)
            // L-24 witness (instrumentation only): a playlist served
            // from a DIFFERENT host than requested means the loader
            // followed a redirect (the vid-snap /v/<token> → o-*
            // shape). Successes are otherwise deliberately silent
            // (ring volume) — this one line is the device test's
            // positive proof the re-serve chain engaged.
            if served.contentType == "com.apple.mpegurl", finalURL.host != original.host {
                DiagLog.log("hls", "phase=fetch outcome=playlist-redirect host=\(finalURL.host ?? "?")")
            }
            // L-25 witness (FL-468): for the vid-snap family only,
            // log WHICH playlist tier was just served — in 1.22.21
            // the failure sat past the master tier, which was
            // invisible because successes are otherwise silent.
            // kind is read from the served (rewritten) body: a
            // master carries EXT-X-STREAM-INF, a media playlist
            // does not.
            if served.contentType == "com.apple.mpegurl",
               Self.isVidSnapFamily(original) || Self.isVidSnapFamily(finalURL) {
                let servedText = String(data: served.data, encoding: .utf8) ?? ""
                let kind = servedText.contains("#EXT-X-STREAM-INF") ? "master" : "media"
                DiagLog.log("hls", "phase=fetch outcome=playlist-served kind=\(kind) bytes=\(served.data.count)")
            }
            // Cache only complete VOD playlists; live playlists must
            // be re-fetched on every pass, segments are never kept.
            let isPlaylist = served.contentType == "com.apple.mpegurl"
            if isPlaylist && served.data.range(of: Data("#EXT-X-ENDLIST".utf8)) != nil {
                self.lock.lock()
                self.cache[key] = served
                self.lock.unlock()
            }
            if loadingRequest.isFinished { return }
            self.respond(loadingRequest, data: served.data, contentType: served.contentType)
        }
        lock.lock()
        tasks[id] = task
        lock.unlock()
        task.resume()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        let id = ObjectIdentifier(loadingRequest)
        let task = tasks.removeValue(forKey: id)
        cancelled.insert(id)
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Serving

    /// Classifies a fetched body: playlists are rewritten so every
    /// nested URI routes back through this loader; binaries are
    /// sniffed and re-typed honestly.
    private func prepare(data: Data, finalURL: URL) -> (data: Data, contentType: String) {
        var data = data
        // Some CDNs wrap each segment in a complete tiny PNG (a real
        // image header + IEND, then the actual media bytes): VSMOV's
        // TS segments and Film4K's fMP4 segments both do this. Strip
        // the wrapper or AVFoundation chokes on the garbage prefix.
        if Self.hasPNGMagic(data), let stripped = Self.stripPNGWrapper(data) {
            data = stripped
        }
        if Self.looksLikePlaylist(data),
           let text = String(data: data, encoding: .utf8) {
            let rewritten = Self.rewritePlaylist(text, base: finalURL)
            return (Data(rewritten.utf8), "com.apple.mpegurl")
        }
        return (data, Self.sniffContentType(data: data, url: finalURL))
    }

    static func hasPNGMagic(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// Returns the media payload after a PNG wrapper, or nil when no
    /// confident media start is found. Tries, in order: the bytes
    /// right after the PNG's IEND chunk; the first MPEG-TS sync
    /// pattern (0x47 at i, i+188, i+376); an fMP4 box type (ftyp/
    /// styp) backed up to its 4-byte size field.
    static func stripPNGWrapper(_ data: Data) -> Data? {
        let window = min(data.count, 8192)
        // 1) IEND terminator: 00 00 00 00 "IEND" AE 42 60 82
        let iend = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        if let range = data.range(of: iend, in: 0..<window) {
            let start = range.upperBound
            if start < data.count { return data.subdata(in: start..<data.count) }
        }
        // 2) TS sync pattern
        if data.count > 564 {
            var i = 1
            let limit = min(data.count - 565, window)
            while i < limit {
                if data[i] == 0x47 && data[i + 188] == 0x47 && data[i + 376] == 0x47 && data[i + 564] == 0x47 {
                    return data.subdata(in: i..<data.count)
                }
                i += 1
            }
        }
        // 3) fMP4 box
        for marker in ["styp", "ftyp"] {
            if let range = data.range(of: Data(marker.utf8), in: 0..<window), range.lowerBound >= 4 {
                let start = range.lowerBound - 4
                if start > 0 && start < data.count { return data.subdata(in: start..<data.count) }
            }
        }
        return nil
    }

    private func respond(_ request: AVAssetResourceLoadingRequest, data: Data, contentType: String) {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }
        let requestedOffset = Int(dataRequest.requestedOffset)
        // requestedLength can arrive as Int.max ("to the end") —
        // cap it before any addition so the arithmetic cannot overflow.
        let cappedLength = min(dataRequest.requestedLength, data.count)
        let start = min(max(requestedOffset, Int(dataRequest.currentOffset)), data.count)
        let end = min(data.count, requestedOffset + cappedLength)
        if start < end {
            dataRequest.respond(with: data.subdata(in: start..<end))
        }
        if Int(dataRequest.currentOffset) >= end {
            request.finishLoading()
        }
    }

    // MARK: - Playlist rewriting

    static func looksLikePlaylist(_ data: Data) -> Bool {
        let head = data.prefix(512)
        guard let text = String(data: head, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    static func rewritePlaylist(_ text: String, base: URL) -> String {
        // Playlist class, from the tags themselves: a master carries
        // EXT-X-STREAM-INF variant references; a media playlist carries
        // EXTINF segment entries. The two never mix in one document.
        let isMaster = text.contains("#EXT-X-STREAM-INF")
        let isMedia  = text.contains("#EXTINF:")
        // L-25: for the vid-snap family the loader serves PLAYLISTS
        // only (their served MIME is the lie AVPlayer rejects); the
        // segments are bare TS that need no stripping, so a MEDIA
        // playlist's segment URIs stay DIRECT absolute URLs and
        // AVPlayer fetches them itself — the topxx lesson recorded
        // in wrap(). A MASTER playlist is rewritten exactly as
        // before (its variant URI stays wrapped, so the variant is
        // fetched through the loader and lands here as media).
        let directSegments = isVidSnapFamily(base) && isMedia && !isMaster
        var segmentCount = 0
        var out: [String] = []
        out.reserveCapacity(1024)
        var maxInf: Double = 0
        var targetIdx: Int? = nil
        var targetVal: Double = 0
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let num = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
                if let v = Double(String(num)) { maxInf = max(maxInf, v) }
            }
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetIdx = out.count
                let num = line.dropFirst("#EXT-X-TARGETDURATION:".count)
                targetVal = Double(String(num).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            if line.hasPrefix("#") {
                out.append(rewriteTagLine(line, base: base, directSegments: directSegments))
            } else if line.isEmpty {
                out.append(rawLine)
            } else {
                if directSegments { segmentCount += 1 }
                out.append(wrap(line, base: base, directSegments: directSegments))
            }
        }
        // Some origins ship EXTINF values above their own
        // TARGETDURATION (streamxx: 33.333 s segments under a 33
        // target) — a spec violation a strict parser may reject.
        // Raise the target to cover the longest segment. This is
        // spec-correct for every playlist, so it applies to all
        // rewritten playlists, not just that origin's.
        if let idx = targetIdx, maxInf > targetVal {
            out[idx] = "#EXT-X-TARGETDURATION:\(Int(maxInf.rounded(.up)))"
        }
        if directSegments {
            DiagLog.log("hls", "phase=rewrite outcome=direct-segments segments=\(segmentCount)")
        }
        return out.joined(separator: "\n")
    }

    /// The vid-snap family (L-25/FL-468): the ONLY family whose media
    /// playlists are rewritten with DIRECT segment URIs (see
    /// rewritePlaylist). Same predicate markProxyIfNeeded uses to
    /// route this family into the loader (MovieService) — the apex
    /// host or any subdomain, nothing else.
    static func isVidSnapFamily(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "vid-snap-player.com" || host.hasSuffix(".vid-snap-player.com")
    }

    private static func wrap(_ uri: String, base: URL, directSegments: Bool) -> String {
        guard var absolute = URL(string: uri, relativeTo: base)?.absoluteURL,
              absolute.scheme == "http" || absolute.scheme == "https" else { return uri }
        // streamxx-style HLS proxies wrap the real file URL as
        // /__hls_proxy/<base64>. When that proxy dies, the playlist
        // still loads (edge cache) but every segment returns 502 —
        // while the wrapped origin file stays publicly fetchable
        // (topxx, verified 2026-11-14: HTTP 200, full size, valid
        // TS, with NO headers at all and with AVPlayer's own user
        // agent). Serve the unwrapped URL DIRECTLY in the
        // rewritten playlist and let AVPlayer fetch the segment
        // itself. Routing these segments back through this loader
        // (the pre-v1.11 behaviour) never once played on the
        // user's device across four builds, while every other
        // part of the chain verified clean — so the loader now
        // only serves playlists and resources that genuinely need
        // disguise-stripping, and plain public files take the
        // plain path.
        if let decoded = decodeProxyWrapped(absolute) { return decoded.absoluteString }
        // L-25: in direct mode (vid-snap media playlists) the
        // segment goes to AVPlayer as a plain public URL — no
        // loader wrap, no app-attached headers (the topxx direct
        // shape recorded above).
        if directSegments { return absolute.absoluteString }
        guard let proxied = proxiedURL(for: absolute) else { return uri }
        return proxied.absoluteString
    }

    private static func decodeProxyWrapped(_ url: URL) -> URL? {
        guard url.path.contains("/__hls_proxy/") else { return nil }
        var b64 = url.lastPathComponent
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let string = String(data: data, encoding: .utf8),
              string.hasPrefix("http"),
              let decoded = URL(string: string),
              (decoded.scheme == "http" || decoded.scheme == "https") else { return nil }
        return decoded
    }

    /// Rewrites every URI="..." attribute on a tag line (EXT-X-MAP,
    /// EXT-X-KEY, EXT-X-MEDIA, EXT-X-STREAM-INF companions...).
    private static func rewriteTagLine(_ line: String, base: URL, directSegments: Bool) -> String {
        guard line.contains("URI=\""),
              let regex = try? NSRegularExpression(pattern: "URI=\"([^\"]*)\"") else { return line }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        var result = line
        for match in matches.reversed() where match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            let uri = ns.substring(with: range)
            // Tag URIs (EXT-X-KEY / EXT-X-MAP / EXT-X-MEDIA) ALWAYS
            // stay wrapped, even in direct mode (L-25): key bytes
            // and init segments genuinely need the loader if they
            // ever appear — the direct treatment is for media
            // segment lines only, so directSegments is deliberately
            // NOT forwarded here.
            let wrapped = wrap(uri, base: base, directSegments: false)
            result = (result as NSString).replacingCharacters(in: range, with: wrapped)
        }
        return result
    }

    // MARK: - Content sniffing

    static func sniffContentType(data: Data, url: URL) -> String {
        if data.count >= 8 {
            let box = data.subdata(in: 4..<8)
            if box == Data("ftyp".utf8) || box == Data("styp".utf8) {
                return "public.mpeg-4"
            }
        }
        if data.first == 0x47 {
            return "public.mpeg-2-transport-stream"
        }
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "m4s": return "public.mpeg-4"
        case "m4a": return "public.mpeg-4-audio"
        case "aac": return "public.aac-audio"
        case "ts": return "public.mpeg-2-transport-stream"
        case "mp3": return "public.mp3"
        default: return "public.data"
        }
    }
}

// MARK: - Playlist synthesis for the streamxx pattern

/// For embed.streamxx.net playlists the app never needs the
/// origin host at all. Measured across several titles
/// (2026-11-14), every segment of every title lives at one
/// regular address —
/// https://f005.backblazeb2.com/file/central-repository/hls-backups/<streamId>/playlistNNNNN.ts
/// — numbered from 0 with no gaps, and the stream id in that
/// address is the same id the plugin puts in the streamxx URL.
/// The origin playlist host stalls or refuses the user's phone
/// on every in-app path tried (six builds: the resolver reaches
/// the player, then no item ever parses a playlist), while
/// Backblaze answers his phone directly — proven in Safari,
/// where the unwrapped playlist played instantly. So the
/// player builds the playlist itself: probe which segments
/// exist (HEAD requests), measure each segment's real duration
/// from its first and last PCR timestamps (two small range
/// fetches per segment; the method measured 33.300 s against a
/// true 33.333 s on the reference title), then serve the
/// synthesized playlist from the loopback server, with the
/// file copy as the next rung. Any step failing declines the
/// synthesis and the existing transports carry on unchanged.
enum PlaylistSynthesizer {

    static func streamxxID(from url: URL) -> String? {
        guard url.host == "embed.streamxx.net" else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "stream"), i + 1 < parts.count else { return nil }
        let id = parts[i + 1]
        return id.isEmpty ? nil : id
    }

    private static func segmentName(_ idx: Int) -> String {
        String(format: "playlist%05d.ts", idx)
    }

    /// Whether the segment store holds this stream's HLS backup
    /// at all (segment 0 answers 200). The operator's newer
    /// uploads have NO backup — measured 2026-11-18: a 2026
    /// title's segment 0 is a 404 while a 2025 title's segments
    /// answer 200. The resolver probes this to pick the delivery
    /// path before the player commits to synthesis.
    static func backupExists(streamID: String) async -> Bool {
        guard let url = URL(string: "https://f005.backblazeb2.com/file/central-repository/hls-backups/\(streamID)/\(segmentName(0))") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    static func synthesize(streamID: String) async -> (data: Data, fileURL: URL)? {
        let base = "https://f005.backblazeb2.com/file/central-repository/hls-backups/\(streamID)"
        let session = URLSession.shared

        func head(_ idx: Int) async -> Int? {
            guard let u = URL(string: "\(base)/\(segmentName(idx))") else { return nil }
            var req = URLRequest(url: u)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 15
            guard let (_, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return http.expectedContentLength > 0 ? Int(http.expectedContentLength) : nil
        }

        // Find the segment count by exponential + binary search
        // (v1.22): segments are contiguous from 0, so existence is
        // monotone — ~10 probes replace the old linear scan of
        // ceil(N/6) serial HEAD batches that gated playback start.
        func exists(_ idx: Int) async -> Bool { await head(idx) != nil }
        guard await exists(0) else { return nil }
        var lo = 0
        var hi = 400
        var probe = 1
        while probe < hi {
            if await exists(probe) { lo = probe; probe *= 2 } else { hi = probe; break }
        }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if await exists(mid) { lo = mid } else { hi = mid }
        }
        let n = lo + 1

        // Duration SAMPLING (v1.22): segments in these backups are
        // near-uniform, so measure a spread of samples and take
        // the median — the old code measured EVERY segment (two
        // 48 KB range fetches each: ~29 MB and ~600 requests for
        // a 300-segment title) before playback could start. High
        // sample variance means the uniformity assumption failed
        // (mixed content), so fall back to measuring all.
        func measure(_ indices: [Int]) async -> [Double] {
            await withTaskGroup(of: (Int, Double).self) { group in
                for i in indices {
                    group.addTask {
                        guard let size = await head(i) else { return (i, 0) }
                        return (i, await segmentDuration(base: base, index: i, size: size, session: session) ?? 0)
                    }
                }
                var out = [Double](repeating: 0, count: n)
                for await (i, d) in group { out[i] = d }
                return out
            }
        }
        let durations: [Double]
        if n <= 12 {
            durations = await measure(Array(0..<n))
        } else {
            var sampleIdx = Set([0, n - 1, n / 2])
            for k in 1..<8 { sampleIdx.insert(n * k / 8) }
            let sampled = await measure(sampleIdx.sorted())
            let values = sampled.filter { $0 > 0 }.sorted()
            if values.count >= 2 {
                let median = values[values.count / 2]
                if values.last! - values.first! <= 0.25 * median {
                    durations = [Double](repeating: median, count: n)
                } else {
                    durations = await measure(Array(0..<n))
                }
            } else {
                durations = sampled
            }
        }
        let measured = durations.filter { $0 > 0 }
        let fallback = measured.isEmpty ? 10.0 : measured.sorted()[measured.count / 2]
        // EXTINF gets a small upward bias: overstating a
        // segment's length slightly is harmless, understating
        // it can make a strict parser distrust the playlist.
        let exts: [Double] = durations.map { ($0 > 0 ? $0 : fallback) + 0.05 }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3",
                     "#EXT-X-TARGETDURATION:\(Int((exts.max() ?? 0).rounded(.up)))",
                     "#EXT-X-MEDIA-SEQUENCE:0"]
        for (i, d) in exts.enumerated() {
            lines.append(String(format: "#EXTINF:%.3f,", d))
            lines.append("\(base)/\(segmentName(i))")
        }
        lines.append("#EXT-X-ENDLIST")
        let data = Data(lines.joined(separator: "\n").utf8)

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hls-local", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("synth-\(streamID).m3u8")
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return (data: data, fileURL: file)
    }

    /// Duration of one TS segment from its PCR timestamps: the
    /// first PCR in the head slice and the last PCR in the tail
    /// slice. The tail slice starts at an arbitrary byte offset,
    /// so its packet alignment is found first (0x47 repeating
    /// every 188 bytes).
    private static func segmentDuration(base: String, index: Int, size: Int, session: URLSession) async -> Double? {
        guard let u = URL(string: "\(base)/\(segmentName(index))") else { return nil }
        func range(_ r: String) async -> Data? {
            var req = URLRequest(url: u)
            req.timeoutInterval = 15
            req.setValue("bytes=\(r)", forHTTPHeaderField: "Range")
            guard let (d, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 206 || http.statusCode == 200 else { return nil }
            return d
        }
        let span = 48 * 1024
        async let headD = range("0-\(span - 1)")
        async let tailD = range("\(max(0, size - span))-\(size - 1)")
        guard let head = await headD, let first = pcrs(head, aligned: true).first else { return nil }
        var end = pcrs(await tailD ?? Data(), aligned: false).last
        if end == nil { end = pcrs(head, aligned: true).last }
        guard let last = end else { return nil }
        var d = last - first
        if d < 0 { d += 95443.72 }  // PCR base wraps at 2^33 / 90000 s
        return d > 0 && d < 3600 ? d : nil
    }

    private static func pcrs(_ data: Data, aligned: Bool) -> [Double] {
        var out: [Double] = []
        var start = 0
        if !aligned {
            var found = false
            for i in 0..<188 where i + 376 < data.count {
                if data[i] == 0x47 && data[i + 188] == 0x47 && data[i + 376] == 0x47 {
                    start = i
                    found = true
                    break
                }
            }
            if !found { return out }
        }
        var i = start
        while i + 188 <= data.count {
            if data[i] == 0x47 {
                let adaptation = (data[i + 3] >> 4) & 0x3
                if adaptation == 2 || adaptation == 3 {
                    let afl = Int(data[i + 4])
                    if afl >= 7 && data[i + 5] & 0x10 != 0 {
                        let b = i + 6
                        let base = (UInt64(data[b]) << 25) | (UInt64(data[b + 1]) << 17)
                            | (UInt64(data[b + 2]) << 9) | (UInt64(data[b + 3]) << 1)
                            | (UInt64(data[b + 4]) >> 7)
                        out.append(Double(base) / 90000.0)
                    }
                }
            }
            i += 188
        }
        return out
    }
}
