import Foundation
import SwiftUI

// MARK: - Built-in network probe (1.3.3, Item 5)
//
// WHY THIS EXISTS (owner's measurement ruling, 2026-11-22
// 14:22 CST): the 123av / njav transport fault — every fetch
// to those hosts dying with NSURLErrorDomain -1001 on the TV
// while the SAME fetches succeed from the VM and from the
// owner's residential PC — lives somewhere in the TV's own
// resolver / egress path, so it can only be measured FROM
// the TV. The owner's words: "Đo chỉ có thể đưa a app và a
// đo gửi log về em thôi" — Muse ships the probe inside the
// app, the owner runs it on the TV and returns the exported
// diagnostic log as usual. Settings → Chẩn đoán → "Đo đường
// truyền" runs the sequence once; every measurement lands in
// DiagLog under the `netprobe` tag, and the screen shows a
// short per-host summary while it runs.
//
// PER TARGET HOST, THREE MEASUREMENTS (serial, bounded):
//   1. dns.system — getaddrinfo through the TV's own
//      resolver: the IP list the system hands the app.
//   2. dns.doh — the same name resolved over HTTPS through
//      Cloudflare's public resolver (cloudflare-dns.com,
//      application/dns-json, A records): the IP list public
//      DNS returns.
//   3. https — a real HTTPS GET of https://<host>/ on the
//      probe's OWN ephemeral URLSession (default TLS stack,
//      default user agent, no custom headers — the same
//      network path the app's fetches take): HTTP status of
//      the final response at first body byte, or the
//      URLError domain#code, plus elapsed ms. The transfer
//      is cancelled at the first body byte; nothing is kept.
// The three together discriminate the fault family:
//   dns.system empty/divergent while dns.doh answers →
//   the TV's resolver is the fault (verdict note
//   dns-system-fail / dns-diverge). Both DNS legs agree but
//   https times out (-1001 / no-answer) → egress. https
//   fails in the -1200 family → TLS.
//
// TARGETS (hosts exactly as the shipped plugins use them,
// plus the embed/player hosts from the device log):
//   123av.com               123av baseUrl (mod02.js:10,72);
//                           log_10: image + fetchText -1001.
//   sadie-shop.site         123av embed origin (per-title
//                           from payloads; the iOS log proved
//                           the embed resolve runs here).
//   www.njav.com            njav baseUrl (mod08.js:16,81);
//                           log_10: fetchText -1001.
//   upload18.org            njav player host — the /jm/ hop
//                           redirects there (mod08.js:630).
//   njav.tv                 123av official mirror (1.3.4,
//   123av.me                DIAG-123AV-MIRRORS): the mirror
//                           domains serve an SPA shell the
//                           plugin cannot parse, so no swap
//                           is possible — the open question
//                           these two answer is whether ANY
//                           other zone of the same operator
//                           passes the TV's connection at
//                           all (transport only, observe-only
//                           like every other target).
//   missav.ws               CONTROL — proven good on this TV.
//   raw.githubusercontent.com CONTROL — plugin sync works
//                           from the TV (log_10 passim).
//
// DISCIPLINE: the probe OBSERVES ONLY. It never touches the
// shared Net machinery in Cache.swift, no cache, header or
// retry behaviour changes, and its sessions are ephemeral
// and its own. Public hosts only; nothing secret is logged
// (hosts, IPs, statuses, error codes, timings — the same
// redacted-by-construction material DiagLog already holds).
// Runtime is bounded per host (system DNS raced against a
// 6 s budget, DoH 6 s, GET 8 s, serial over 8 hosts) and the
// run is cancellable from the screen, so Settings can never
// wedge on it.

enum TVNetProbe {

    enum TargetKind {
        /// The existing three-leg measurement.
        case host
        /// §6.2: DNS legs + a body-keeping root GET, classified.
        case mirrorState
        /// §6.3: the JavGuru chain walk (own section below).
        case chainWalk
    }

    struct Target {
        let host: String
        /// ASCII role token for the log line.
        let role: String
        /// Path used by the HTTPS leg (default root).
        var path: String = "/"
        var kind: TargetKind = .host
    }

    static let targets: [Target] = [
        Target(host: "123av.com", role: "123av-main"),
        Target(host: "sadie-shop.site", role: "123av-embed"),
        Target(host: "www.njav.com", role: "njav-main"),
        Target(host: "upload18.org", role: "njav-player"),
        Target(host: "njav.tv", role: "mirror-123av-njavtv", kind: .mirrorState),
        Target(host: "123av.me", role: "mirror-123av-me", kind: .mirrorState),
        Target(host: "missav.ws", role: "control-missav"),
        Target(host: "raw.githubusercontent.com", role: "control-github"),
        // §6.1 new host targets (1.3.6).
        Target(host: "jav.guru", role: "javguru-main"),
        Target(host: "javclan.com", role: "javguru-embed"),
        Target(host: "guest.freeanimehentai.net", role: "hanime-api",
               path: "/api/v11/search_hvs"),
        Target(host: "hanime-cdn.com", role: "hanime-cdn"),
        Target(host: "www.javmost.ws", role: "javmost-main"),
        Target(host: "jav.spa", role: "javspa-main"),
        Target(host: "upload18.to", role: "njav-player-to"),
        Target(host: "static.javcdn.vip", role: "njav-posters"),
        // §6.2: 24av.net joins the mirror-state set.
        Target(host: "24av.net", role: "mirror-123av-24av", kind: .mirrorState),
        // §6.3: the JavGuru chain walk (host jav.guru).
        Target(host: "jav.guru", role: "javguru-chain", kind: .chainWalk),
        // Round-2 source candidates (1.3.8, RESEARCH-SOURCES-ROUND2
        // probe batch): plain reachability only — the javsnap
        // player host exactly as sampled in the research, the
        // omgjav CDN, and the two JavMenu lines. One run settles
        // these three candidates alongside the JavGuru walk above.
        Target(host: "o-1wxmrhzolp.vid-snap-player.com", role: "javsnap-player"),
        Target(host: "a41.355510382.xyz", role: "omgjav-cdn"),
        Target(host: "xbv2608.com", role: "javmenu-xbv"),
        Target(host: "t30.cdn2020.com", role: "javmenu-t30"),
    ]

    private static let sysBudget: TimeInterval = 6
    private static let dohTimeout: TimeInterval = 6
    private static let getBudget: TimeInterval = 8

    // MARK: - One host, three measurements

    struct HostResult {
        /// True when the HTTPS leg got any HTTP response.
        let answered: Bool
        /// One short Vietnamese line for the screen.
        let displayLine: String
    }

    /// Runs the three measurements for one target, logging
    /// each leg under `netprobe`. Returns nil when the run
    /// was cancelled mid-host (the caller stops the run).
    static func measure(_ target: Target,
                        dohSession: URLSession) async -> HostResult? {
        if target.kind == .chainWalk {
            return await runChainWalk()
        }
        let host = target.host
        DiagLog.log("netprobe", "host=\(host) role=\(target.role) begin")

        // Leg 1 — the TV's own resolver.
        let sys = await systemResolve(host: host)
        if Task.isCancelled { return nil }
        if sys.deadline {
            DiagLog.log("netprobe", "host=\(host) dns.system outcome=deadline ms=\(sys.ms)")
        } else if sys.gai == 0 {
            DiagLog.log("netprobe", "host=\(host) dns.system ips=\(ipList(sys.ips)) ms=\(sys.ms)")
        } else {
            DiagLog.log("netprobe", "host=\(host) dns.system error=gai:\(sys.gai) ms=\(sys.ms)")
        }

        // Leg 2 — public DNS over HTTPS.
        let doh = await dohResolve(host: host, session: dohSession)
        if Task.isCancelled { return nil }
        if let errorLabel = doh.errorLabel {
            DiagLog.log("netprobe", "host=\(host) dns.doh error=\(errorLabel) ms=\(doh.ms)")
        } else {
            DiagLog.log("netprobe", "host=\(host) dns.doh ips=\(ipList(doh.ips)) ms=\(doh.ms)")
        }

        // DNS relationship note (only when it discriminates).
        let sysSet = Set(sys.ips)
        let dohSet = Set(doh.ips)
        var dnsNote = ""
        if sys.gai != 0 || sys.deadline, !dohSet.isEmpty {
            dnsNote = "dns-system-fail"
        } else if !sysSet.isEmpty, !dohSet.isEmpty, sysSet != dohSet {
            dnsNote = "dns-diverge"
        } else if sysSet.isEmpty, dohSet.isEmpty {
            dnsNote = "dns-both-empty"
        }

        // Leg 3 (mirror-state targets, §6.2): the root GET
        // KEEPS its body up to 48 KB for classification.
        if target.kind == .mirrorState {
            let fetched = await httpsGetBody(host: host, path: target.path,
                                             maxBytes: 48 * 1024, budget: 10)
            if Task.isCancelled { return nil }
            let state: String
            let bytes: Int
            let status: Int
            var mirrorAnswered = false
            switch fetched {
            case .responded(let fetchedStatus, let body, _):
                mirrorAnswered = true
                status = fetchedStatus
                bytes = body.count
                state = classifyMirror(body: body)
            case .failed, .deadline:
                status = 0
                bytes = 0
                state = "unknown"
            }
            DiagLog.log("netprobe", "host=\(host) mirror-state=\(state) bytes=\(bytes) status=\(status)")
            let stateText: String
            switch state {
            case "moved": stateText = "đã chuyển nhà (moved)"
            case "content": stateText = "CÓ NỘI DUNG"
            case "shell": stateText = "vỏ SPA"
            default: stateText = "chưa rõ"
            }
            var mirrorLine = "\(host) — gương 123av: \(stateText)"
            switch dnsNote {
            case "dns-system-fail": mirrorLine += " · DNS hệ thống không phân giải được"
            case "dns-diverge": mirrorLine += " · DNS lệch với DNS công cộng"
            case "dns-both-empty": mirrorLine += " · cả hai DNS đều trống"
            default: break
            }
            DiagLog.log("netprobe", "host=\(host) verdict=mirror-\(state)\(dnsNote.isEmpty ? "" : " " + dnsNote)")
            return HostResult(answered: mirrorAnswered, displayLine: mirrorLine)
        }

        // Leg 3 — a real HTTPS GET.
        let outcome = await httpsGet(host: host, path: target.path)
        if Task.isCancelled { return nil }
        let verdict: String
        let display: String
        var answered = false
        switch outcome {
        case .responded(let status, let ms):
            answered = true
            verdict = "ok"
            DiagLog.log("netprobe", "host=\(host) https status=\(status) ms=\(ms)")
            display = "\(host) — trả lời HTTP \(status) · \(ms) ms"
        case .failed(let domain, let code, let ms):
            DiagLog.log("netprobe", "host=\(host) https error=\(domain)#\(code) ms=\(ms)")
            switch code {
            case NSURLErrorTimedOut:
                verdict = "timeout"
                display = "\(host) — HTTPS hết giờ (\(code)) · \(ms) ms"
            case -1200 ... -1206:
                verdict = "tls"
                display = "\(host) — lỗi TLS (\(code)) · \(ms) ms"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                verdict = "unreachable"
                display = "\(host) — không tới được máy chủ (\(code)) · \(ms) ms"
            default:
                verdict = "error"
                display = "\(host) — lỗi \(domain)#\(code) · \(ms) ms"
            }
        case .deadline(let ms):
            verdict = "no-answer"
            DiagLog.log("netprobe", "host=\(host) https outcome=deadline ms=\(ms)")
            display = "\(host) — không trả lời sau \(Int(getBudget)) giây"
        }
        DiagLog.log("netprobe", "host=\(host) verdict=\(verdict)\(dnsNote.isEmpty ? "" : " " + dnsNote)")

        var line = display
        switch dnsNote {
        case "dns-system-fail": line += " · DNS hệ thống không phân giải được"
        case "dns-diverge": line += " · DNS lệch với DNS công cộng"
        case "dns-both-empty": line += " · cả hai DNS đều trống"
        default: break
        }
        return HostResult(answered: answered, displayLine: line)
    }

    private static func ipList(_ ips: [String]) -> String {
        ips.isEmpty ? "-" : ips.joined(separator: ",")
    }

    /// Stable display/log order: IPv4 first, then IPv6, each
    /// lexicographic. (Set comparison for the divergence note
    /// is order-free; this is only for readable lines.)
    private static func sortedIPs(_ ips: Set<String>) -> [String] {
        ips.sorted { a, b in
            let a6 = a.contains(":")
            let b6 = b.contains(":")
            if a6 != b6 { return !a6 }
            return a < b
        }
    }

    // MARK: - Leg 1: system DNS (getaddrinfo)

    private struct SystemDNSResult: Sendable {
        let ips: [String]
        /// getaddrinfo status; 0 = resolved (ips may still be
        /// empty in principle), non-zero = resolver failure.
        /// Carries no meaning when `deadline` is set — the
        /// resolver never returned a status at all.
        let gai: Int32
        /// True when the leg's own 6 s budget expired before
        /// the resolver answered: the probe's budget outcome,
        /// logged as `outcome=deadline`, never dressed up as
        /// a gai code.
        let deadline: Bool
        let ms: Int
    }

    /// getaddrinfo blocks, so it runs on a detached task —
    /// never on the main actor, never on the caller's queue.
    /// The resolver itself is the system one the app uses;
    /// nothing is configured or overridden. The blocking call
    /// cannot be killed, and awaiting a detached task's
    /// `.value` ignores the caller's cancellation, so the
    /// result is RACED against the leg's own 6 s budget
    /// (SystemDNSRaceBox, resume-once): on budget expiry the
    /// leg reports the probe's `deadline` outcome and the run
    /// stops waiting. The abandoned call finishes on the
    /// resolver's own schedule, writes nothing, retains
    /// nothing beyond its own locals, and its late result is
    /// discarded by the box.
    private static func systemResolve(host: String) async -> SystemDNSResult {
        let started = Date()
        return await withCheckedContinuation { continuation in
            let race = SystemDNSRaceBox()
            race.arm(continuation)
            // The resolver side: ferry the detached call's
            // result to the race box.
            Task {
                let (ips, gai) = await Task.detached(priority: .utility) {
                    () -> ([String], Int32) in
                    var hints = addrinfo()
                    hints.ai_family = AF_UNSPEC
                    hints.ai_socktype = SOCK_STREAM
                    var result: UnsafeMutablePointer<addrinfo>?
                    let status = getaddrinfo(host, nil, &hints, &result)
                    guard status == 0 else { return ([], status) }
                    guard let result else { return ([], 0) }
                    defer { freeaddrinfo(result) }
                    var found = Set<String>()
                    var cursor: UnsafeMutablePointer<addrinfo>? = result
                    while let ptr = cursor {
                        cursor = ptr.pointee.ai_next
                        guard let addr = ptr.pointee.ai_addr else { continue }
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                          &buffer, socklen_t(buffer.count),
                                          nil, 0, NI_NUMERICHOST) == 0
                        else { continue }
                        found.insert(String(cString: buffer))
                    }
                    return (sortedIPs(found), 0)
                }.value
                race.resume(SystemDNSResult(
                    ips: ips, gai: gai, deadline: false,
                    ms: Int(Date().timeIntervalSince(started) * 1000)))
            }
            // The budget side: at 6 s the run stops waiting.
            Task {
                try? await Task.sleep(for: .seconds(sysBudget))
                race.resume(SystemDNSResult(
                    ips: [], gai: 0, deadline: true,
                    ms: Int(Date().timeIntervalSince(started) * 1000)))
            }
        }
    }

    /// Resume-once race box for leg 1: the resolver ferry and
    /// the budget task race to deliver the leg's outcome;
    /// whichever arrives second is discarded. The NSLock is
    /// the whole confinement story — the continuation slot is
    /// touched only under it and the resume itself happens
    /// outside it — so the `@unchecked Sendable` states
    /// exactly that (the GET delegate below makes the same
    /// claim with a serial queue instead of a lock).
    private final class SystemDNSRaceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<SystemDNSResult, Never>?

        /// Called once, before either racer is created — a
        /// happens-before edge, as with the GET delegate's
        /// arm/attach.
        func arm(_ continuation: CheckedContinuation<SystemDNSResult, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ result: SystemDNSResult) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    // MARK: - Leg 2: DNS over HTTPS (Cloudflare)

    private struct DoHResult {
        let ips: [String]
        /// nil on a parsed answer; otherwise the failure in
        /// the house log shape (`Domain#code`, `http=<n>` or
        /// `parse`).
        let errorLabel: String?
        let ms: Int
    }

    /// One A-record query to cloudflare-dns.com's JSON API.
    /// Note the dependency this leg itself has: the DoH
    /// endpoint's own name resolves through system DNS, so a
    /// totally broken resolver fails this leg too — the error
    /// is logged as-is and the discrimination falls back to
    /// legs 1 and 3, which is still evidence, never silence.
    private static func dohResolve(host: String,
                                   session: URLSession) async -> DoHResult {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "cloudflare-dns.com"
        components.path = "/dns-query"
        components.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: "A"),
        ]
        guard let url = components.url else {
            return DoHResult(ips: [], errorLabel: "bad-url", ms: elapsed())
        }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = dohTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return DoHResult(ips: [], errorLabel: "non-http", ms: elapsed())
            }
            guard http.statusCode == 200 else {
                return DoHResult(ips: [], errorLabel: "http=\(http.statusCode)",
                                 ms: elapsed())
            }
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any] else {
                return DoHResult(ips: [], errorLabel: "parse", ms: elapsed())
            }
            var found = Set<String>()
            if let answers = dict["Answer"] as? [[String: Any]] {
                for answer in answers {
                    if let type = answer["type"] as? Int, type == 1,
                       let data = answer["data"] as? String {
                        found.insert(data)
                    }
                }
            }
            return DoHResult(ips: sortedIPs(found), errorLabel: nil, ms: elapsed())
        } catch {
            let nsError = error as NSError
            return DoHResult(ips: [],
                             errorLabel: "\(nsError.domain)#\(nsError.code)",
                             ms: elapsed())
        }
    }

    // MARK: - Leg 3: HTTPS GET (first byte, then cancel)

    private enum GetOutcome {
        /// An HTTP response arrived and its first body byte
        /// landed (status is the FINAL response's, after any
        /// redirects).
        case responded(status: Int, ms: Int)
        /// The task completed with an error before any body
        /// byte — the URLError domain + code, verbatim.
        case failed(domain: String, code: Int, ms: Int)
        /// The probe's own budget expired with no answer at
        /// all. Reported as its own outcome, never dressed up
        /// as a system error code.
        case deadline(ms: Int)
    }

    /// Times one HTTPS GET of the host's root on an ephemeral
    /// session, TVSourceProbe's construction: the transfer is
    /// cancelled at the first body byte and nothing is kept.
    private static func httpsGet(host: String, path: String = "/") async -> GetOutcome {
        guard let url = URL(string: "https://\(host)\(path)") else {
            return .failed(domain: "probe", code: 0, ms: 0)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = getBudget
        let delegate = GetProbeDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = getBudget
        configuration.timeoutIntervalForResource = getBudget
        let session = URLSession(configuration: configuration,
                                 delegate: delegate, delegateQueue: queue)
        let outcome = await withCheckedContinuation { continuation in
            delegate.arm(continuation: continuation)
            let task = session.dataTask(with: request)
            delegate.attach(task: task, queue: queue)
            task.resume()
            // The budget enforcer: whichever of first-byte,
            // completion, or this deadline lands first wins;
            // the delegate resumes exactly once.
            Task {
                try? await Task.sleep(for: .seconds(getBudget))
                delegate.expire()
            }
        }
        session.invalidateAndCancel()
        return outcome
    }

    /// Resume-once delegate, TVSourceProbe's discipline: all
    /// mutable state is touched only on the session's serial
    /// delegate queue or before the task resumes (arm/attach
    /// — a happens-before edge), except `expire()`, which
    /// hops onto that same queue. The `@unchecked Sendable`
    /// conformance states exactly that confinement: the
    /// budget-enforcer Task captures the delegate and is
    /// sound precisely because `expire()` only enqueues.
    private final class GetProbeDelegate: NSObject, URLSessionDataDelegate,
        @unchecked Sendable {
        private var continuation: CheckedContinuation<GetOutcome, Never>?
        private var task: URLSessionDataTask?
        private var started: Date?
        private var lastStatus: Int?
        private var finished = false
        /// The serial queue the owning URLSession delivers
        /// callbacks on; expire() re-enters through it.
        private var callbackQueue: OperationQueue?

        func arm(continuation: CheckedContinuation<GetOutcome, Never>) {
            self.continuation = continuation
            self.started = Date()
        }

        func attach(task: URLSessionDataTask, queue: OperationQueue) {
            self.task = task
            // The queue is the session's own delegate queue,
            // handed in by the caller that created both: a
            // URLSessionTask exposes no `session` back-pointer
            // in the tvOS SDK (CI run #19 convicted the assumed
            // API), so the queue travels explicitly.
            self.callbackQueue = queue
        }

        func expire() {
            guard let queue = callbackQueue else { return }
            queue.addOperation { [weak self] in
                self?.finish(.deadline(ms: self?.elapsedMs() ?? 0))
            }
        }

        private func elapsedMs() -> Int {
            guard let started else { return 0 }
            return Int(Date().timeIntervalSince(started) * 1000)
        }

        private func finish(_ outcome: GetOutcome) {
            guard !finished else { return }
            finished = true
            task?.cancel()
            continuation?.resume(returning: outcome)
            continuation = nil
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                lastStatus = http.statusCode
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            // First body byte of the final response: the
            // status recorded above is that response's own.
            if let status = lastStatus {
                finish(.responded(status: status, ms: elapsedMs()))
            } else {
                finish(.failed(domain: "non-http", code: 0, ms: elapsedMs()))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            if let error {
                let nsError = error as NSError
                finish(.failed(domain: nsError.domain, code: nsError.code,
                               ms: elapsedMs()))
            } else if let status = lastStatus {
                // Completed with no body byte (e.g. an empty
                // 204): still an answer from the host.
                finish(.responded(status: status, ms: elapsedMs()))
            } else {
                finish(.deadline(ms: elapsedMs()))
            }
        }
    }

    // MARK: - Body-keeping GET (§6.2 mirror-state + §6.3 chain steps)

    private enum BodyOutcome {
        case responded(status: Int, body: Data, ms: Int)
        case failed(domain: String, code: Int, ms: Int)
        case deadline(ms: Int)
    }

    /// §6.2 classification (case-insensitive body scan).
    static func classifyMirror(body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self).lowercased()
        if text.contains("we have moved") { return "moved" }
        if text.contains("class=\"card\"") || mirrorVideoHref(text) {
            return "content"
        }
        if body.count < 8 * 1024,
           text.contains("id=\"app\"") || text.contains("id=\"root\"")
            || text.contains("__nuxt") || text.contains("type=\"module\"") {
            return "shell"
        }
        return "unknown"
    }

    /// A `/v/<code>` href marker (§6.2 content test).
    private static func mirrorVideoHref(_ text: String) -> Bool {
        var searchStart = text.startIndex
        while let hit = text.range(of: "/v/", range: searchStart..<text.endIndex) {
            let after = text[hit.upperBound...]
            if let first = after.first, first.isLetter || first.isNumber {
                return true
            }
            searchStart = hit.upperBound
        }
        return false
    }

    /// One HTTPS GET on an ephemeral session that KEEPS the
    /// body up to `maxBytes` (then cancels), under `budget`
    /// seconds. Redirects follow the session default. Used by
    /// the mirror-state leg and every chain-walk step.
    private static func httpsGetBody(host: String, path: String,
                                     maxBytes: Int, budget: TimeInterval) async -> BodyOutcome {
        guard let url = URL(string: "https://\(host)\(path)") else {
            return .failed(domain: "probe", code: 0, ms: 0)
        }
        return await httpsGetBody(url: url, maxBytes: maxBytes, budget: budget)
    }

    private static func httpsGetBody(url: URL, maxBytes: Int,
                                     budget: TimeInterval) async -> BodyOutcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = budget
        let delegate = BodyProbeDelegate(limit: maxBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = budget
        configuration.timeoutIntervalForResource = budget
        let session = URLSession(configuration: configuration,
                                 delegate: delegate, delegateQueue: queue)
        let outcome = await withCheckedContinuation { continuation in
            delegate.arm(continuation: continuation)
            let task = session.dataTask(with: request)
            delegate.attach(task: task, queue: queue)
            task.resume()
            Task {
                try? await Task.sleep(for: .seconds(budget))
                delegate.expire()
            }
        }
        session.invalidateAndCancel()
        return outcome
    }

    /// Resume-once body-accumulating delegate — the
    /// GetProbeDelegate discipline (serial delegate queue /
    /// arm-attach happens-before / expire hops onto the queue).
    private final class BodyProbeDelegate: NSObject, URLSessionDataDelegate,
        @unchecked Sendable {
        private var continuation: CheckedContinuation<BodyOutcome, Never>?
        private var task: URLSessionDataTask?
        private var started: Date?
        private var lastStatus: Int?
        private var body = Data()
        private let limit: Int
        private var finished = false
        private var callbackQueue: OperationQueue?

        init(limit: Int) { self.limit = limit }

        func arm(continuation: CheckedContinuation<BodyOutcome, Never>) {
            self.continuation = continuation
            self.started = Date()
        }

        func attach(task: URLSessionDataTask, queue: OperationQueue) {
            self.task = task
            self.callbackQueue = queue
        }

        func expire() {
            guard let queue = callbackQueue else { return }
            queue.addOperation { [weak self] in
                self?.finish(.deadline(ms: self?.elapsedMs() ?? 0))
            }
        }

        private func elapsedMs() -> Int {
            guard let started else { return 0 }
            return Int(Date().timeIntervalSince(started) * 1000)
        }

        private func finish(_ outcome: BodyOutcome) {
            guard !finished else { return }
            finished = true
            task?.cancel()
            continuation?.resume(returning: outcome)
            continuation = nil
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                lastStatus = http.statusCode
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            body.append(data)
            if body.count >= limit {
                body = Data(body.prefix(limit))
                if let status = lastStatus {
                    finish(.responded(status: status, body: body, ms: elapsedMs()))
                } else {
                    finish(.failed(domain: "non-http", code: 0, ms: elapsedMs()))
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            if let error {
                let nsError = error as NSError
                finish(.failed(domain: nsError.domain, code: nsError.code,
                               ms: elapsedMs()))
            } else if let status = lastStatus {
                finish(.responded(status: status, body: body, ms: elapsedMs()))
            } else {
                finish(.deadline(ms: elapsedMs()))
            }
        }
    }

    // MARK: - §6.3 JavGuru chain walk

    /// One manual redirect hop's answer: the status and the
    /// raw Location header, if any (redirects NOT followed).
    private struct HopAnswer {
        let status: Int
        let location: String?
        let ms: Int
    }

    /// GETs `url` WITHOUT following redirects (own ephemeral
    /// session, own no-follow delegate). nil on transport
    /// failure / deadline.
    private static func httpsHop(url: URL, budget: TimeInterval) async -> HopAnswer? {
        var request = URLRequest(url: url)
        request.timeoutInterval = budget
        let delegate = HopProbeDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = budget
        configuration.timeoutIntervalForResource = budget
        let session = URLSession(configuration: configuration,
                                 delegate: delegate, delegateQueue: queue)
        let answer = await withCheckedContinuation { continuation in
            delegate.arm(continuation: continuation)
            let task = session.dataTask(with: request)
            delegate.attach(task: task, queue: queue)
            task.resume()
            Task {
                try? await Task.sleep(for: .seconds(budget))
                delegate.expire()
            }
        }
        session.invalidateAndCancel()
        return answer
    }

    /// Resume-once no-follow delegate: finishes at the
    /// response headers (status + Location) and cancels.
    private final class HopProbeDelegate: NSObject, URLSessionDataDelegate,
        @unchecked Sendable {
        private var continuation: CheckedContinuation<HopAnswer?, Never>?
        private var task: URLSessionDataTask?
        private var started: Date?
        private var finished = false
        private var callbackQueue: OperationQueue?

        func arm(continuation: CheckedContinuation<HopAnswer?, Never>) {
            self.continuation = continuation
            self.started = Date()
        }

        func attach(task: URLSessionDataTask, queue: OperationQueue) {
            self.task = task
            self.callbackQueue = queue
        }

        func expire() {
            guard let queue = callbackQueue else { return }
            queue.addOperation { [weak self] in
                self?.finish(nil)
            }
        }

        private func elapsedMs() -> Int {
            guard let started else { return 0 }
            return Int(Date().timeIntervalSince(started) * 1000)
        }

        private func finish(_ answer: HopAnswer?) {
            guard !finished else { return }
            finished = true
            task?.cancel()
            continuation?.resume(returning: answer)
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                let location = http.value(forHTTPHeaderField: "Location")
                finish(HopAnswer(status: http.statusCode, location: location,
                                 ms: elapsedMs()))
            } else {
                finish(nil)
            }
            completionHandler(.cancel)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            finish(nil)
        }
    }

    /// All `href="…"` values in a page, in document order.
    private static func hrefs(in text: String) -> [String] {
        var values: [String] = []
        var cursor = text.startIndex
        while let hit = text.range(of: "href=\"", range: cursor..<text.endIndex) {
            let start = hit.upperBound
            guard let close = text.range(of: "\"", range: start..<text.endIndex) else { break }
            values.append(String(text[start..<close.lowerBound]))
            cursor = close.upperBound
        }
        return values
    }

    /// String values assigned to `key` in an inline config
    /// (the TVPlayerSession embedConfigValues scan shape).
    private static func configValues(in text: String, key: String) -> [(range: Range<String.Index>, value: String)] {
        var results: [(range: Range<String.Index>, value: String)] = []
        var cursor = text.startIndex
        while let hit = text.range(of: key, range: cursor..<text.endIndex) {
            cursor = hit.upperBound
            var i = hit.upperBound
            while i < text.endIndex, text[i] == "\"" || text[i] == " " || text[i] == "\t" {
                i = text.index(after: i)
            }
            guard i < text.endIndex, text[i] == ":" else { continue }
            i = text.index(after: i)
            while i < text.endIndex, text[i] == " " || text[i] == "\t" || text[i] == "\n" || text[i] == "\r" {
                i = text.index(after: i)
            }
            guard i < text.endIndex, text[i] == "\"" else { continue }
            let start = text.index(after: i)
            guard let close = text.range(of: "\"", range: start..<text.endIndex) else { break }
            let raw = String(text[start..<close.lowerBound])
            results.append((hit, raw.replacingOccurrences(of: "\\/", with: "/")))
            cursor = close.upperBound
        }
        return results
    }

    private static func chainFail(step: Int, reason: String) -> HostResult {
        DiagLog.log("netprobe", "chain outcome=failed step=\(step) reason=\(reason)")
        return HostResult(answered: false,
                          displayLine: "jav.guru — chuỗi JavGuru: dừng ở bước \(step) (\(reason))")
    }

    /// The §6.3 walk: front → detail → gateway → manual
    /// redirect walk → first byte of the landing URL. Budget
    /// 45 s total, 10 s per step; string-level only.
    static func runChainWalk() async -> HostResult? {
        let walkStart = Date()
        func overBudget() -> Bool {
            Date().timeIntervalSince(walkStart) > 45 || Task.isCancelled
        }
        // Step 1 — the front page → first detail-page link.
        let frontStart = Date()
        guard case .responded(let frontStatus, let frontBody, _) =
                await httpsGetBody(host: "jav.guru", path: "/", maxBytes: 256 * 1024, budget: 10)
        else { return chainFail(step: 1, reason: "fetch") }
        if overBudget() { return nil }
        DiagLog.log("netprobe", "chain step=front status=\(frontStatus) ms=\(Int(Date().timeIntervalSince(frontStart) * 1000))")
        let frontText = String(decoding: frontBody, as: UTF8.self)
        let detailPath = hrefs(in: frontText).first { href in
            guard let url = URL(string: href, relativeTo: URL(string: "https://jav.guru/")),
                  url.host == "jav.guru" else { return false }
            let path = url.path
            guard path.count > 1, !path.contains("wp-"),
                  !path.hasPrefix("/category"), !path.hasPrefix("/tag"),
                  !path.hasPrefix("/page"), !path.hasPrefix("/actor"),
                  !path.hasPrefix("/studio") else { return false }
            let last = url.lastPathComponent
            return last.contains("-") && last.contains { $0.isNumber }
        }
        guard let detailPath, let detailURL = URL(string: detailPath, relativeTo: URL(string: "https://jav.guru/"))?.absoluteURL
        else { return chainFail(step: 1, reason: "no-detail-link") }
        // Step 2 — the detail page → a server config's gateway.
        guard case .responded(let detailStatus, let detailBody, _) =
                await httpsGetBody(url: detailURL, maxBytes: 384 * 1024, budget: 10)
        else { return chainFail(step: 2, reason: "fetch") }
        if overBudget() { return nil }
        let detailText = String(decoding: detailBody, as: UTF8.self)
        let configs = configValues(in: detailText, key: "iframe_url")
        guard !configs.isEmpty else { return chainFail(step: 2, reason: "no-server-config") }
        // Prefer the SB server config (its label sits in the
        // markup just before its config); else the first.
        var chosen = configs[0]
        var serverLabel = "first"
        for config in configs {
            let windowStart = detailText.index(config.range.lowerBound, offsetBy: -300, limitedBy: detailText.startIndex) ?? detailText.startIndex
            let context = detailText[windowStart..<config.range.lowerBound]
            if context.contains("\"SB\"") || context.contains(">SB<") || context.contains("STREAM SB") {
                chosen = config
                serverLabel = "SB"
                break
            }
        }
        let cleaned = chosen.value.filter { !$0.isWhitespace }
        guard let decodedData = Data(base64Encoded: cleaned),
              let gatewayText = String(data: decodedData, encoding: .utf8),
              let gatewayURL = URL(string: gatewayText)
        else { return chainFail(step: 2, reason: "bad-gateway") }
        DiagLog.log("netprobe", "chain step=detail status=\(detailStatus) server=\(serverLabel) gateway-host=\(gatewayURL.host ?? "jav.guru")")
        // Step 3 — the gateway page → reversed-token embed URL
        // (RESEARCH-SOURCE-HEALTH's construction: the token
        // hides in data-* fragments; window.cfg carries base
        // + rtype; embed = searcho/?<rtype>r=<token reversed>).
        guard case .responded(let gatewayStatus, let gatewayBody, _) =
                await httpsGetBody(url: gatewayURL, maxBytes: 64 * 1024, budget: 10)
        else { return chainFail(step: 3, reason: "fetch") }
        if overBudget() { return nil }
        let gatewayPage = String(decoding: gatewayBody, as: UTF8.self)
        guard let embedURL = buildEmbedURL(from: gatewayPage, gateway: gatewayURL)
        else { return chainFail(step: 3, reason: "no-token") }
        DiagLog.log("netprobe", "chain step=gateway status=\(gatewayStatus)")
        // Step 4 — manual redirect walk (max 5 hops), then a
        // first-byte GET of the final URL.
        var current = embedURL
        var hops = 0
        var finalAnswer: HopAnswer?
        while hops < 5 {
            if overBudget() { return nil }
            guard let answer = await httpsHop(url: current, budget: 10) else {
                return chainFail(step: 4, reason: "hop-fetch")
            }
            finalAnswer = answer
            guard let location = answer.location,
                  (300...399).contains(answer.status),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL
            else { break }
            current = next
            hops += 1
        }
        guard let finalAnswer else { return chainFail(step: 4, reason: "hop-fetch") }
        let streamStart = Date()
        let firstByte: GetOutcome
        if let host = current.host {
            var path = current.path
            if let query = current.query, !query.isEmpty { path += "?\(query)" }
            if path.isEmpty { path = "/" }
            firstByte = await httpsGet(host: host, path: path)
        } else {
            firstByte = .failed(domain: "probe", code: 0, ms: 0)
        }
        if overBudget() { return nil }
        let streamMs = Int(Date().timeIntervalSince(streamStart) * 1000)
        switch firstByte {
        case .responded(let status, _):
            DiagLog.log("netprobe", "chain step=streamhost host=\(current.host ?? "?") status=\(status) ms=\(streamMs)")
            DiagLog.log("netprobe", "chain outcome=done host=\(current.host ?? "?") status=\(status)")
            return HostResult(answered: true,
                              displayLine: "jav.guru — chuỗi JavGuru: tới \(current.host ?? "?") · HTTP \(status)")
        case .failed(let domain, let code, _):
            DiagLog.log("netprobe", "chain step=streamhost host=\(current.host ?? "?") status=0 ms=\(streamMs)")
            return chainFail(step: 4, reason: "stream-\(domain)#\(code)")
        case .deadline:
            return chainFail(step: 4, reason: "stream-deadline")
        }
    }

    /// Builds the reversed-token embed URL from the gateway
    /// page: window.cfg's `rtype` + the data-* token fragments
    /// concatenated in document order, reversed.
    private static func buildEmbedURL(from page: String, gateway: URL) -> URL? {
        guard let rtype = configValues(in: page, key: "rtype").first?.value,
              !rtype.isEmpty else { return nil }
        var fragments: [String] = []
        var cursor = page.startIndex
        while let hit = page.range(of: "data-", range: cursor..<page.endIndex) {
            var i = hit.upperBound
            while i < page.endIndex, page[i] != "=", page[i] != "\"", page[i] != " " {
                i = page.index(after: i)
            }
            guard i < page.endIndex, page[i] == "=" else { cursor = hit.upperBound; continue }
            i = page.index(after: i)
            guard i < page.endIndex, page[i] == "\"" else { cursor = hit.upperBound; continue }
            let start = page.index(after: i)
            guard let close = page.range(of: "\"", range: start..<page.endIndex) else { break }
            let value = String(page[start..<close.lowerBound])
            if value.count >= 4, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                fragments.append(value)
            }
            cursor = close.upperBound
        }
        let token = fragments.joined()
        guard token.count >= 8 else { return nil }
        let reversed = String(token.reversed())
        var components = URLComponents()
        components.scheme = gateway.scheme ?? "https"
        components.host = gateway.host ?? "jav.guru"
        components.path = "/searcho/"
        components.query = "\(rtype)r=\(reversed)"
        return components.url
    }
}

// MARK: - Run model

/// Owns ONE probe run for the screen's lifetime: serial over
/// the targets, one display line per finished host, all
/// detail in DiagLog. @MainActor, so the published lines and
/// the run's bookkeeping need no synchronisation; the heavy
/// legs suspend off-actor on their own machinery.
@MainActor
final class TVNetProbeModel: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var isRunning = false

    private var runTask: Task<Void, Never>?

    func start() {
        guard runTask == nil else { return }
        isRunning = true
        runTask = Task { await self.execute() }
    }

    /// Cancels the run: the loop checks between legs and
    /// between hosts and stops quietly; an in-flight leg is
    /// bounded by its own budget (system DNS 6 s, DoH 6 s,
    /// GET 8 s) and its result is discarded by the cancelled
    /// continuation path.
    func cancel() {
        runTask?.cancel()
    }

    private func execute() async {
        let dohConfiguration = URLSessionConfiguration.ephemeral
        dohConfiguration.timeoutIntervalForRequest = 6
        dohConfiguration.timeoutIntervalForResource = 6
        let dohSession = URLSession(configuration: dohConfiguration)
        defer {
            dohSession.finishTasksAndInvalidate()
            isRunning = false
            runTask = nil
        }
        DiagLog.log("netprobe", "run start targets=\(TVNetProbe.targets.count)")
        var answered = 0
        for target in TVNetProbe.targets {
            if Task.isCancelled {
                DiagLog.log("netprobe", "run cancelled answered=\(answered)")
                lines.append("Đã dừng đo.")
                return
            }
            guard let result = await TVNetProbe.measure(target,
                                                        dohSession: dohSession)
            else {
                DiagLog.log("netprobe", "run cancelled answered=\(answered)")
                lines.append("Đã dừng đo.")
                return
            }
            if result.answered { answered += 1 }
            lines.append(result.displayLine)
        }
        lines.append("Xong: \(answered)/\(TVNetProbe.targets.count) máy có trả lời HTTPS. Mở “Gửi log chẩn đoán” để lấy log về.")
        DiagLog.log("netprobe", "run done answered=\(answered)/\(TVNetProbe.targets.count)")
    }
}

// MARK: - The screen

/// Settings → Chẩn đoán → "Đo đường truyền". Presented by
/// fullScreenCover from Settings, exactly like LogExportView:
/// no navigation chrome, the in-body title is the title, and
/// the run lives only while this screen is open (start on
/// appear, cancel on disappear).
struct TVNetProbeView: View {
    @EnvironmentObject private var session: PinSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = TVNetProbeModel()
    @FocusState private var closeFocused: Bool
    /// A-13 (1.3.9): the done state offers the log export
    /// right here — no trip back through Settings.
    @State private var showLogExport = false
    @FocusState private var logFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .center, spacing: 32) {
                Text("Đo đường truyền")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)

                Text("App thử phân giải tên miền và kết nối HTTPS tới từng máy chủ phim ngay trên TV này. Kết quả đầy đủ ghi vào log chẩn đoán — đo xong, bấm “Gửi log ngay” ở dưới để lấy log về.")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1250, alignment: .center)

                if model.isRunning {
                    HStack(spacing: 16) {
                        ProgressView()
                            .tint(.white)
                        Text("Đang đo…")
                            .font(.system(size: 27))
                            .foregroundStyle(.white)
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 27))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: 1250, alignment: .leading)
                }

                HStack(spacing: 24) {
                    // A-13 (1.3.9): at the done state (probe
                    // finished, results on screen) the log
                    // export opens from right here.
                    if !model.isRunning && !model.lines.isEmpty {
                        Button {
                            showLogExport = true
                        } label: {
                            Text("Gửi log ngay")
                                .font(.system(size: 28))
                        }
                        .focused($logFocused)
                    }
                    Button {
                        model.cancel()
                        dismiss()
                    } label: {
                        Text("Đóng")
                            .font(.system(size: 28))
                    }
                    .focused($closeFocused)
                }
            }
            .padding(60)
        }
        .defaultFocus($closeFocused, true)
        .fullScreenCover(isPresented: $showLogExport) {
            LogExportView()
        }
        .onAppear {
            session.touch()
            DiagLog.log("settings", "net probe screen opened")
            model.start()
        }
        .onDisappear {
            model.cancel()
        }
        // L-T31 (1.3.4): this cover owns its Menu press —
        // Menu is the Đóng button (cancel + dismiss); an
        // unhandled press would fall to the system and exit
        // the app, the L-T31 mechanism.
        .onExitCommand {
            DiagLog.log("menu", "dismiss surface=netprobe")
            model.cancel()
            dismiss()
        }
    }
}
