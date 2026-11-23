import Foundation
import SwiftUI
import UIKit
import CryptoKit
import ImageIO
import libwebp

// MARK: - Networking

enum Net {
    static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024)
        config.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: config)
    }()

    static func makeRequest(url: URL, headers: [String: String] = [:], referer: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(defaultUA, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// Cloudflare's JS challenge ("Just a moment…") is served with a
    /// 403/503 (rarely a 200 interstitial). Ordinary Cloudflare pages
    /// also carry challenge-platform scripts, so the body marker alone
    /// is not enough — status or the interstitial title must agree.
    static func isCloudflareChallenge(_ text: String, status: Int) -> Bool {
        let t = text.lowercased()
        if t.contains("<title>just a moment") { return true }
        if status == 403 || status == 503 {
            return t.contains("just a moment")
                || t.contains("challenge-platform")
                || t.contains("challenges.cloudflare.com")
        }
        return false
    }

    /// Marker check for rendered DOM coming back from the WebView
    /// fetcher (no HTTP status available there).
    static func isChallengeHTML(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("<title>just a moment") || t.contains("challenges.cloudflare.com")
    }

    static func fetchText(_ urlString: String, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        // Up to 3 attempts with a short backoff: the VPN tunnel path can
        // drop or garble a first response (-1011), a retry usually lands.
        // v1.22: a hard 4xx (except 429) is NOT retried — the old
        // policy burned ~61 s on failures that could never succeed —
        // and the per-attempt timeout drops to 12 s.
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            var attemptStatus = 0
            do {
                var req = makeRequest(url: url, headers: headers)
                req.timeoutInterval = 12
                let (data, response) = try await session.data(for: req)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                attemptStatus = status
                if isCloudflareChallenge(text, status: status) {
                    // tvOS adaptation: there is no WebView
                    // Cloudflare lane on tvOS (that class does
                    // not exist in this copy) — a challenged
                    // fetch fails this attempt and the plain
                    // retry/backoff path below applies, exactly
                    // as it does for any other failed attempt.
                    throw URLError(.badServerResponse)
                }
                if !(200...299).contains(status) {
                    throw URLError(.badServerResponse)
                }
                // tvOS adaptation: the forced nhplayer WebView
                // detour (v1.22.13/v1.22.14 in the iOS original)
                // does not exist on tvOS — those resources behave
                // as a normal fetch and the plain body is returned.
                return text
            } catch {
                // L-T17/FL-385 (log-only): record the real transport
                // error's domain+code per attempt — without this the
                // error was reduced to lastError and thrown with no
                // trace, so a pre-HTTP failure (DNS/TLS/reset/timeout)
                // was indistinguishable in the device log.
                DiagLog.log("net", "fetchText failed host=\(url.host ?? "?") attempt=\(attempt) status=\(attemptStatus) err=\((error as NSError).domain)#\((error as NSError).code)")
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if (400..<500).contains(attemptStatus), attemptStatus != 429 { throw lastError }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    // tvOS adaptation: the post-detour plain-retry helper and
    // the forced-detour resource predicate from the iOS original
    // are removed — both existed only to serve the WebView
    // Cloudflare lane, which does not exist on tvOS.

    /// POST variant for plugin hop configs that carry a postBody
    /// (e.g. vlxx's /ajax.php player call). Same retry policy.
    static func fetchTextPOST(_ urlString: String, body: String, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            var attemptStatus = 0
            do {
                var req = makeRequest(url: url, headers: headers)
                req.httpMethod = "POST"
                req.timeoutInterval = 12
                if req.value(forHTTPHeaderField: "Content-Type") == nil {
                    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                }
                req.httpBody = body.data(using: .utf8)
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                attemptStatus = status
                if !(200...299).contains(status) {
                    throw URLError(.badServerResponse)
                }
                return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            } catch {
                // L-T17/FL-385 (log-only): same per-attempt transport
                // error record as fetchText (see above).
                DiagLog.log("net", "fetchTextPOST failed host=\(url.host ?? "?") attempt=\(attempt) status=\(attemptStatus) err=\((error as NSError).domain)#\((error as NSError).code)")
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if (400..<500).contains(attemptStatus), attemptStatus != 429 { throw lastError }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    static func fetchData(_ urlString: String, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        // v1.22: same retry policy as fetchText (was: zero retries).
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            do {
                return try await session.data(for: makeRequest(url: url, headers: headers)).0
            } catch {
                // L-T17/FL-385 (log-only): same per-attempt transport
                // error record as fetchText (see above).
                DiagLog.log("net", "fetchData failed host=\(url.host ?? "?") attempt=\(attempt) err=\((error as NSError).domain)#\((error as NSError).code)")
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }
}

// MARK: - WebView fetcher — absent on tvOS (adaptation)
//
// tvOS adaptation: the iOS WebView fetcher class (an off-screen
// WKWebView Cloudflare-challenge lane) does not exist in this
// copy at all. Fetches degrade to the plain URLSession paths:
// Net.fetchText uses its normal retry path, and the image
// cache fetches bytes directly.

// MARK: - Image cache

final class ImageCacheManager: @unchecked Sendable {
    static let shared = ImageCacheManager()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()
    /// Phase 2 (JoeTV pipeline adoption): dedicated image
    /// session — 8 connections per host (JoeTV's measured
    /// value; the shared Net.session is tuned for text/plugin
    /// fetches, not poster bursts). waitsForConnectivity is
    /// off: a poster fetch on a dead network must fail into
    /// the retry/classification path, not park indefinitely.
    private let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    /// Phase 2 prefetch state (guarded by `lock`, like
    /// inFlight): a FIFO pending queue drained by at most
    /// `prefetchWorkers` concurrent loads at bucket 720. A
    /// new prefetch() call REPLACES the pending queue —
    /// already-running workers are not disturbed.
    private var prefetchQueue: [(urlString: String, headers: [String: String], key: String)] = []
    private var prefetchActive = 0
    private static let prefetchWorkers = 3
    /// Decode size ladder (Phase 2): a requested bucket is
    /// normalised UP to the smallest rung ≥ the request,
    /// capped at 1920, so cache keys stay stable across call
    /// sites asking for near-identical sizes.
    private static let bucketLadder = [240, 480, 720, 960, 1280, 1920]

    static func bucket(forPixels px: Int) -> Int {
        for rung in bucketLadder where px <= rung { return rung }
        return 1920
    }
    /// v1.22 disk tier (~300 MB, LRU by modification date): every
    /// cold launch used to re-download every poster — the memory
    /// cache alone could not survive a relaunch.
    private let diskDir: URL
    private let diskCap = 300 * 1024 * 1024

    private init() {
        // Phase 2: decoded-cache budget DERIVED from the
        // memory available to the process (JoeTV's rule,
        // JoeImagePipeline.swift init): 6% of
        // os_proc_available_memory(), clamped to
        // [48 MB, 120 MB], count limit 600. The old flat
        // 256 MB / 400 cap was fictitious headroom on TV
        // hardware — decoded posters evicted each other
        // long before the cap mattered.
        let available = os_proc_available_memory()
        let derived = available > 0
            ? Int(Double(available) * 0.06) : 120 * 1024 * 1024
        cache.totalCostLimit = min(120 * 1024 * 1024,
                                   max(48 * 1024 * 1024, derived))
        cache.countLimit = 600
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("jtv-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        let dir = diskDir, cap = diskCap
        Task.detached { Self.pruneDisk(dir: dir, cap: cap) }
    }

    private func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(digest)
    }

    private static func pruneDisk(dir: URL, cap: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var total = 0
        var sized: [(url: URL, size: Int, date: Date)] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            total += size
            sized.append((entry, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > cap else { return }
        for entry in sized.sorted(by: { $0.date < $1.date }) {
            if total <= cap { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Real memory cost of a decoded bitmap. The old accounting
    /// used the COMPRESSED byte count, so the 256 MB cap was
    /// fictitious — decoded posters run 5–15× their file size.
    /// Phase 2: the cost is the bitmap's true byte count —
    /// CGImage bytesPerRow × height — with the size×scale
    /// estimate kept only for the rare image with no CGImage
    /// backing.
    private func decodedCost(_ image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    /// Caps pathological decodes (4K backdrops) at a 2048 px long
    /// edge; normal posters and manga pages pass through untouched.
    /// A reading page or strip is NEVER capped: its short edge is
    /// the reading width (a SayHentai strip runs ~720 x 10000), and
    /// capping the long edge crushed one to ~147 px wide — the
    /// owner-reported "very blurry" pages of 2026-11-18, which the
    /// plugin's HD files never caused. Only an image large in BOTH
    /// dimensions (a backdrop, a photo) is capped. The disk tier
    /// stores the original bytes, so this fix also heals chapters
    /// already cached on the device.
    private func capped(_ image: UIImage) -> UIImage {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let longest = max(pixelW, pixelH)
        guard longest > 2048 else { return image }
        guard min(pixelW, pixelH) > 1080 else { return image }
        let ratio = 2048 / longest
        let target = CGSize(width: pixelW * ratio, height: pixelH * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func key(for url: String, headers: [String: String]) -> String {
        if headers.isEmpty { return url }
        let suffix = headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return url + "|" + suffix
    }

    /// Phase 2 bucketed API: `bucket` is the maximum pixel
    /// dimension to decode to. The decoded-cache key is the
    /// existing key(for:headers:) + "|b" + the normalised
    /// rung, so the same URL at two buckets is two entries;
    /// the DISK tier keeps storing the original bytes under
    /// the existing (bucketless) key, so one download serves
    /// every bucket by re-decoding from the stored original.
    func cachedImage(urlString: String, headers: [String: String] = [:], bucket: Int = 720) -> UIImage? {
        let rung = Self.bucket(forPixels: bucket)
        let k = key(for: urlString, headers: headers) + "|b\(rung)"
        return cache.object(forKey: k as NSString)
    }

    /// Pre-Phase-2 label kept as a thin wrapper so existing
    /// call sites (CachedAsyncImage) compile unchanged; it
    /// reads the default 720 bucket, exactly what the new
    /// default parameter would give them.
    func cachedImage(for urlString: String, headers: [String: String] = [:]) -> UIImage? {
        cachedImage(urlString: urlString, headers: headers)
    }

    func loadImage(urlString: String, headers: [String: String] = [:], bucket: Int = 720) async -> UIImage? {
        let rung = Self.bucket(forPixels: bucket)
        let baseKey = key(for: urlString, headers: headers)
        let k = baseKey + "|b\(rung)"
        if let hit = cache.object(forKey: k as NSString) { return hit }
        guard let url = URL(string: urlString) else { return nil }

        // Swift 6: NSLock.lock()/unlock() are unavailable in
        // async contexts; scoped withLock is the sanctioned
        // form. The check-and-set MUST stay inside ONE critical
        // section — the pre-migration code held the lock across
        // the check, the Task creation and the registration,
        // and splitting that into two sections (an earlier
        // conversion did) loses the dedupe guarantee: two
        // concurrent calls could both miss the check and both
        // fetch, and a finishing task's cleanup could clear a
        // successor's registration. So the task is created AND
        // registered inside a single withLock section that
        // returns it; the section itself never awaits.
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inFlight[k] { return existing }
            let created = Task<UIImage?, Never> {
                defer {
                    self.lock.withLock { self.inFlight[k] = nil }
                }
                // Disk tier first: decode (at this bucket) +
                // promote to memory. The disk file lives under
                // the bucketless base key — original bytes, one
                // download serving every bucket.
                let disk = self.diskURL(for: baseKey)
                if let data = try? Data(contentsOf: disk), let image = Self.decodeImage(data: data, bucket: rung) {
                    let cappedImage = self.capped(image)
                    self.cache.setObject(cappedImage, forKey: k as NSString, cost: self.decodedCost(cappedImage))
                    return cappedImage
                }
                guard let data = await self.fetchBytes(url: url, headers: headers),
                      let image = Self.decodeImage(data: data, bucket: rung) else { return nil }
                try? data.write(to: disk, options: .atomic)
                let cappedImage = self.capped(image)
                self.cache.setObject(cappedImage, forKey: k as NSString, cost: self.decodedCost(cappedImage))
                return cappedImage
            }
            inFlight[k] = created
            return created
        }
        return await task.value
    }

    /// tvOS adaptation: plain fetch only. The iOS original's
    /// WebView fallback ladder (clear the host's wall in a web
    /// view, retry direct, then pull the bytes out of the web
    /// view) is dropped — no such lane exists on tvOS. A
    /// response that does not decode as an image fails,
    /// exactly as ordinary failures (404, dead host, timeout)
    /// always did.
    private func fetchBytes(url: URL, headers: [String: String]) async -> Data? {
        // Some hosts (sayhentai.cx's /storage/ covers, measured
        // 2026-11-18) refuse image requests that arrive with no
        // Referer at all — Cloudflare serves its hard block page
        // even to Safari on a direct image navigation, while the
        // same image loads fine inside the site's own pages. A
        // browser loading an image embedded in a page sends that
        // page as the Referer; with no caller-supplied Referer,
        // send the image host's own root — the closest equivalent
        // (the site's pages are the only referrers these images
        // ever legitimately have). Callers that pass an explicit
        // Referer (the manga reader) keep theirs.
        var hdrs = headers
        if !hdrs.keys.contains(where: { $0.lowercased() == "referer" }), let host = url.host, !host.isEmpty {
            hdrs["Referer"] = "\(url.scheme ?? "https")://\(host)/"
        }
        // Phase 2 (JoeTV adoption): bounded retry on the
        // dedicated image session — up to 3 attempts, backoff
        // 0.5 s / 1.5 s, with JoeTV's transient-vs-permanent
        // classification: a thrown error/timeout, HTTP 429,
        // 408 or ≥500, or an undecodable body is TRANSIENT
        // (retry may heal it); any other 4xx or a non-HTTP
        // response is PERMANENT and stops at once. The whole
        // sequence lives inside the one in-flight task, so
        // dedupe/cache semantics are unchanged.
        var lastClass = "transient"
        var lastStatus = 0
        // L-T17/FL-385 (log-only): domain+code of the last thrown
        // transport error, carried to the final failure line below —
        // a thrown pre-HTTP error otherwise left status=0 with no
        // trace of its cause (DNS/TLS/reset/timeout indistinguishable).
        var lastErr = ""
        let backoffs: [UInt64] = [500_000_000, 1_500_000_000]
        for attempt in 0..<3 {
            do {
                var req = Net.makeRequest(url: url, headers: hdrs)
                req.timeoutInterval = 30
                let (data, response) = try await imageSession.data(for: req)
                if let http = response as? HTTPURLResponse {
                    lastStatus = http.statusCode
                    if http.statusCode == 429 || http.statusCode == 408 || http.statusCode >= 500 {
                        lastClass = "transient"
                    } else if !(200...299).contains(http.statusCode) {
                        lastClass = "permanent"
                        break
                    } else if Self.decodeImage(data: data, bucket: 240) != nil {
                        // Validity gate: a successful decode at
                        // the smallest rung is the proof this
                        // body is a real image (Phase 2 — this
                        // replaces the old full-size
                        // UIImage(data:) test, which WebP bodies
                        // could never pass on tvOS).
                        return data
                    } else {
                        lastClass = "transient"
                    }
                } else {
                    lastClass = "permanent"
                    break
                }
            } catch {
                if (error as? URLError)?.code == .cancelled { return nil }
                lastClass = "transient"
                lastErr = "\((error as NSError).domain)#\((error as NSError).code)"
            }
            if attempt < backoffs.count {
                try? await Task.sleep(nanoseconds: backoffs[attempt])
            }
        }
        // Log the HOST only (DiagLog law — never the signed/
        // full URL) plus the failure class, so a dead or
        // walled image host stays diagnosable from the
        // exported log (FL-146/147/214).
        DiagLog.log("image", "fetch failed host=\(url.host ?? "?") class=\(lastClass) status=\(lastStatus) err=\(lastErr.isEmpty ? "none" : lastErr)")
        return nil
    }

    // MARK: - Decode (Phase 2 — JoeTV pipeline adoption)

    /// Pixel dimensions from the image source's properties,
    /// WITHOUT materialising a bitmap — used by the strip
    /// exemption and the full-size fallback guard below.
    private static func pixelDimensions(data: Data) -> (w: Int, h: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// The ONE decode entry point for the poster/backdrop
    /// path (Phase 2). Contract (JoeTV's, JoeImagePipeline
    /// .decode): the returned bitmap's longest side is
    /// ≤ bucket with the aspect untouched — proportional
    /// scale, never a stretch, never a crop — and the
    /// full-size bitmap is NEVER materialised on this path:
    ///  (i) WebP magic bytes (RIFF....WEBP, never a URL
    ///      suffix) → the libwebp route below;
    ///  (ii) everything else → ImageIO thumbnail decode
    ///      straight to the bucket (CreateThumbnailFromImage
    ///      Always + ThumbnailMaxPixelSize = bucket +
    ///      ShouldCacheImmediately).
    /// Two guarded exceptions, both pre-dating Phase 2 in
    /// spirit: the STRIP exemption mirrors capped()'s own
    /// rule — an image large in only ONE dimension (a manga
    /// strip, ~720×10000) is never bucket-crushed, because
    /// its short edge IS the reading width (the 2026-11-18
    /// "very blurry" fault); it decodes full-size under the
    /// 64M-pixel cap and capped() downstream leaves it
    /// untouched exactly as before. And when the thumbnail
    /// path yields nil, a full-size UIImage(data:) fallback
    /// is allowed ONLY when the image already fits the
    /// bucket (or the body is small), still under the
    /// 64M-pixel cap, and is logged when taken.
    private static func decodeImage(data: Data, bucket: Int) -> UIImage? {
        if isWebP(data) {
            return decodeWebP(data, maxPixel: bucket)
        }
        if let dims = pixelDimensions(data: data) {
            let longest = max(dims.w, dims.h)
            let shortest = min(dims.w, dims.h)
            if longest > 2048, shortest <= 1080 {
                guard Int64(dims.w) * Int64(dims.h) <= 64_000_000 else {
                    DiagLog.log("image", "decode strip over cap \(dims.w)x\(dims.h)")
                    return nil
                }
                return UIImage(data: data)
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        // Thumbnail failed: guarded full-size fallback.
        if let dims = pixelDimensions(data: data) {
            guard Int64(dims.w) * Int64(dims.h) <= 64_000_000,
                  max(dims.w, dims.h) <= bucket else { return nil }
            DiagLog.log("image", "decode fallback full-size \(dims.w)x\(dims.h) bucket=\(bucket)")
            return UIImage(data: data)
        }
        if data.count <= 1_000_000 {
            DiagLog.log("image", "decode fallback full-size bytes=\(data.count) bucket=\(bucket)")
            return UIImage(data: data)
        }
        return nil
    }

    /// RIFF/WEBP magic: bytes 0–3 "RIFF", bytes 8–11 "WEBP".
    /// (JoeImagePipeline.swift isWebP, copied.)
    private static func isWebP(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard raw.count >= 12, let base = raw.baseAddress else { return false }
            let b = base.assumingMemoryBound(to: UInt8.self)
            return b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
                && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50
        }
    }

    /// libwebp decode for WebP bodies. Mechanism copied
    /// faithfully from joetv-tvos JoeImagePipeline.swift
    /// (decodeWebP / decodeWebPScaled / decodeWebPNative,
    /// v2.0.8): the PRIMARY path is the advanced API with
    /// in-decoder scaling to the bucket, so the native-size
    /// bitmap is never materialised; any failure falls back
    /// to the device-proven simple-API path (WebPDecodeRGBA
    /// + CGContext scale-down). A 64M-pixel sanity cap
    /// guards both paths. The strip exemption applies here
    /// too: a WebP strip (large in one dimension only, per
    /// capped()'s rule) decodes via the native path with no
    /// scaling requested.
    private static func decodeWebP(_ data: Data, maxPixel: Int) -> UIImage? {
        var infoW: Int32 = 0
        var infoH: Int32 = 0
        let infoOK = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return WebPGetInfo(base.assumingMemoryBound(to: UInt8.self),
                               data.count, &infoW, &infoH) != 0
        }
        if infoOK, infoW > 0, infoH > 0 {
            let longest = max(Int(infoW), Int(infoH))
            let shortest = min(Int(infoW), Int(infoH))
            if longest > 2048, shortest <= 1080 {
                return decodeWebPNative(data, maxPixel: longest)
            }
        }
        if let scaled = decodeWebPScaled(data, maxPixel: maxPixel) {
            return scaled
        }
        return decodeWebPNative(data, maxPixel: maxPixel)
    }

    /// The advanced-API scaled decode (JoeImagePipeline
    /// .swift decodeWebPScaled, copied). The plan-named
    /// WebPInitDecoderConfig / WebPGetFeatures are
    /// `static WEBP_INLINE` wrappers with no exported
    /// symbol, so — exactly as JoeTV does — this calls
    /// their exported Internal twins with
    /// WEBP_DECODER_ABI_VERSION. Output is an EXTERNAL RGBA
    /// buffer allocated at the target size; no
    /// WebPFreeDecBuffer (nothing decoder-owned to free).
    private static func decodeWebPScaled(_ data: Data, maxPixel: Int) -> UIImage? {
        var config = WebPDecoderConfig()
        guard WebPInitDecoderConfigInternal(&config,
                Int32(WEBP_DECODER_ABI_VERSION)) != 0 else { return nil }

        let featuresOK = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return WebPGetFeaturesInternal(
                base.assumingMemoryBound(to: UInt8.self),
                data.count, &config.input,
                Int32(WEBP_DECODER_ABI_VERSION)) == VP8_STATUS_OK
        }
        guard featuresOK else { return nil }

        let w = Int(config.input.width)
        let h = Int(config.input.height)
        guard w > 0, h > 0,
              Int64(w) * Int64(h) <= 64_000_000 else { return nil }

        let longest = max(w, h)
        var tw = w, th = h
        if longest > maxPixel {
            let scale = Double(maxPixel) / Double(longest)
            tw = max(1, Int((Double(w) * scale).rounded()))
            th = max(1, Int((Double(h) * scale).rounded()))
            config.options.use_scaling = 1
            config.options.scaled_width = Int32(tw)
            config.options.scaled_height = Int32(th)
        }

        let bytesPerRow = tw * 4
        let byteCount = bytesPerRow * th
        var buffer = Data(count: byteCount)
        config.output.colorspace = MODE_RGBA
        config.output.width = Int32(tw)
        config.output.height = Int32(th)
        config.output.is_external_memory = 1

        let status = data.withUnsafeBytes { src -> VP8StatusCode? in
            guard let srcBase = src.baseAddress else { return nil }
            return buffer.withUnsafeMutableBytes { raw -> VP8StatusCode? in
                guard let base = raw.baseAddress else { return nil }
                config.output.u.RGBA.rgba =
                    base.assumingMemoryBound(to: UInt8.self)
                config.output.u.RGBA.stride = Int32(bytesPerRow)
                config.output.u.RGBA.size = byteCount
                return WebPDecode(
                    srcBase.assumingMemoryBound(to: UInt8.self),
                    data.count, &config)
            }
        }
        guard status == VP8_STATUS_OK,
              Int(config.output.width) == tw,
              Int(config.output.height) == th else { return nil }

        let copy = Data(buffer)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: copy as CFData),
              let image = CGImage(width: tw, height: th,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: space,
                                  bitmapInfo: bitmapInfo, provider: provider,
                                  decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }

    /// The simple-API path (JoeImagePipeline.swift
    /// decodeWebPNative, copied): WebPGetInfo for the same
    /// 64M-pixel cap, WebPDecodeRGBA at native size, then a
    /// CGContext scale-down when the longest side exceeds
    /// maxPixel. Kept as the scaled path's fallback.
    private static func decodeWebPNative(_ data: Data, maxPixel: Int) -> UIImage? {
        var infoW: Int32 = 0
        var infoH: Int32 = 0
        let infoOK = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return WebPGetInfo(base.assumingMemoryBound(to: UInt8.self),
                               data.count, &infoW, &infoH) != 0
        }
        guard infoOK, infoW > 0, infoH > 0,
              Int64(infoW) * Int64(infoH) <= 64_000_000 else { return nil }

        var outW: Int32 = 0
        var outH: Int32 = 0
        let pixels = data.withUnsafeBytes { raw -> UnsafeMutablePointer<UInt8>? in
            guard let base = raw.baseAddress else { return nil }
            return WebPDecodeRGBA(base.assumingMemoryBound(to: UInt8.self),
                                  data.count, &outW, &outH)
        }
        guard let pixels, outW > 0, outH > 0 else { return nil }
        defer { WebPFree(pixels) }

        let w = Int(outW), h = Int(outH)
        let bytesPerRow = w * 4
        let copy = Data(bytes: pixels, count: bytesPerRow * h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: copy as CFData),
              let full = CGImage(width: w, height: h,
                                 bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: bytesPerRow, space: space,
                                 bitmapInfo: bitmapInfo, provider: provider,
                                 decode: nil, shouldInterpolate: true,
                                 intent: .defaultIntent) else { return nil }

        let longest = max(w, h)
        guard longest > maxPixel else { return UIImage(cgImage: full) }
        let scale = Double(maxPixel) / Double(longest)
        let tw = max(1, Int((Double(w) * scale).rounded()))
        let th = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: bitmapInfo.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }
        return UIImage(cgImage: scaled)
    }

    /// Warms memory/disk for images about to be scrolled into
    /// (rails after a section lands, the manga reader's next
    /// pages). Deduped against the cache and in-flight loads.
    ///
    /// Phase 2 (JoeTV adoption): the old cap-60, one-Task-per
    /// -URL burst is replaced by a FIFO pending queue drained
    /// by at most 3 concurrent workers at bucket 720 (the
    /// session allows 8 connections per host; capping warm-up
    /// at 3 leaves the pool to visible loads). A new call
    /// REPLACES the pending (not-yet-started) queue — the
    /// newest list is what the owner is looking at now.
    func prefetch(urlStrings: [String], headers: [String: String] = [:]) {
        let rung = Self.bucket(forPixels: 720)
        lock.withLock {
            var seen = Set<String>()
            var queue: [(urlString: String, headers: [String: String], key: String)] = []
            for urlString in urlStrings {
                let k = key(for: urlString, headers: headers) + "|b\(rung)"
                if !seen.insert(k).inserted { continue }
                if cache.object(forKey: k as NSString) != nil { continue }
                if inFlight[k] != nil { continue }
                queue.append((urlString, headers, k))
            }
            prefetchQueue = queue
        }
        pumpPrefetch()
    }

    /// Claims pending items under the lock (never awaiting
    /// while holding it) and starts their loads; each
    /// finished load frees its worker slot and re-pumps.
    /// Entries that became cached or in-flight since enqueue
    /// are dropped without consuming a slot.
    private func pumpPrefetch() {
        while true {
            let item: (urlString: String, headers: [String: String], key: String)? = lock.withLock {
                while prefetchActive < Self.prefetchWorkers, !prefetchQueue.isEmpty {
                    let next = prefetchQueue.removeFirst()
                    if cache.object(forKey: next.key as NSString) != nil { continue }
                    if inFlight[next.key] != nil { continue }
                    prefetchActive += 1
                    return next
                }
                return nil
            }
            guard let item else { return }
            Task {
                _ = await self.loadImage(urlString: item.urlString, headers: item.headers, bucket: 720)
                self.lock.withLock { self.prefetchActive -= 1 }
                self.pumpPrefetch()
            }
        }
    }

    func clear() {
        lock.withLock { prefetchQueue = [] }
        cache.removeAllObjects()
        // v1.22.15 (F-2): the Settings action ("Xoá bộ nhớ đệm
        // ảnh") now tells the truth — it also empties the disk
        // tier, not just the memory tier. Synchronous on purpose: clear() is
        // an explicit user action and the disk directory is
        // empty when it returns.
        if let entries = try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

/// Async image view backed by ImageCacheManager (supports custom headers,
/// e.g. the Referer manga CDNs require).
struct CachedAsyncImage: View {
    let urlString: String
    var headers: [String: String] = [:]
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    /// v1.22.15 (F-1): the task identity MUST match
    /// ImageCacheManager.key(for:headers:) — the URL alone
    /// when headers is empty, else the URL + "|" + the
    /// headers sorted by key as "k=v" joined by "&" — so the
    /// view reloads exactly when the manager's cache entry
    /// would differ (a same-URL/different-headers request is
    /// a different image to the manager, and now to the view).
    private var identity: String {
        if headers.isEmpty { return urlString }
        let suffix = headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return urlString + "|" + suffix
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.25))
                    }
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .overlay { ProgressView().tint(.white.opacity(0.5)) }
            }
        }
        .task(id: identity) {
            image = nil
            failed = false
            if let cached = ImageCacheManager.shared.cachedImage(for: urlString, headers: headers) {
                image = cached
                return
            }
            let loaded = await ImageCacheManager.shared.loadImage(urlString: urlString, headers: headers)
            if let loaded { image = loaded } else { failed = true }
        }
    }
}

// MARK: - Haptics

/// tvOS adaptation: no-op stub with the SAME public API as the
/// iOS original (tap / select / success). tvOS has no haptic
/// feedback generators, so every existing call site compiles
/// unchanged and simply does nothing on TV.
enum Haptics {
    static func tap() {}

    static func select() {}

    static func success() {}
}
