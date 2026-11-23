import Foundation

/// Where the Torrent tab's debrid tokens come from: a token typed
/// in Settings (UserDefaults) wins; the build-time baked value
/// (DebridSecrets) is the fallback, so a reinstall keeps working
/// without re-typing — the same arrangement the TV apps use.
enum DebridTokens {
    static let rdKey = "jtv_rd_token"
    static let torboxKey = "jtv_torbox_token"
    static let premiumizeKey = "jtv_pm_token"

    static var rd: String { stored(rdKey) ?? DebridSecrets.rdToken }
    static var torbox: String { stored(torboxKey) ?? DebridSecrets.torboxToken }
    static var premiumize: String { stored(premiumizeKey) ?? DebridSecrets.premiumizeToken }

    static var isConfigured: Bool { !rd.isEmpty || !torbox.isEmpty || !premiumize.isEmpty }

    private static func stored(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}

enum DebridError: LocalizedError {
    case noToken
    case http(Int, String)
    case message(String)
    case timeout
    /// Internal signal, never shown: the provider accepted the
    /// torrent and is still downloading it server-side when the
    /// caller's window closed. The orchestrator uses it to move
    /// to the next provider instead of parking on this one.
    case downloading

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Chưa có token debrid. Nhập token TorBox, Premiumize hoặc Real-Debrid trong Cài đặt (mục Torrent) rồi thử lại."
        case .http(let code, let body):
            return "Dịch vụ debrid trả lỗi \(code)\(body.isEmpty ? "" : ": \(body)")"
        case .message(let text):
            return text
        case .timeout, .downloading:
            return "Torrent chưa có sẵn trên debrid và tải quá lâu. Thử lại sau ít phút — debrid vẫn đang tải ở phía máy chủ."
        }
    }
}

/// Turns a torrent info-hash (the torrenthub plugin's `jtvhash:`
/// episode ids) into a direct file URL via a debrid service.
///
/// Priority (owner order 2026-11-16): whichever provider HAS the
/// title wins, probed per title at tap time in the order TorBox →
/// Real-Debrid → Premiumize — the owner's Sony/Torrentio view shows
/// TorBox holding the most cached sources of the three. v1.22.3
/// adds a CACHE-PROBE phase ahead of the download chain: one cheap
/// availability call per configured provider (TorBox checkcached,
/// RD instantAvailability, Premiumize directdl); the first provider
/// reporting the title cached resolves it through its normal flow.
/// When NO provider has it, the chain falls back to the proven
/// v1.21 sequential shape (restored in v1.22.2 after a line-by-line
/// diff against commit 55cd609): each provider's own flow with its
/// own full budget, same priority order. The file pick prefers the
/// largest VIDEO file, preferring AVPlayer-friendly containers
/// (mp4/m4v/mov) so most titles stay on the native player; anything
/// else is flagged `useCompatEngine` and the resolver screen routes
/// it to the KSPlayer (FFmpeg) surface, which opens MKV/AVI
/// natively.
/// Phase events for the torrent wait line (spec §5.3):
/// emitted ONLY by `DebridResolver.resolve(hash:onPhase:)` —
/// the probe-only and provider-pinned entry points stay
/// silent. Tokens are the providers' DiagLog log tokens
/// (e.g. ["torbox", "premiumize"]), not the tvOS-only
/// `Provider` enum, so this type exists identically in both
/// cores; shells map tokens to display names with their own
/// tables.
enum DebridPhaseEvent: Sendable, Equatable {
    case probing
    case downloading(providers: [String])
    case finished
}

enum DebridResolver {
    // MARK: Provider switch types (L-T13, 1.3.1 — tvOS adaptation)

    /// One debrid provider, for the in-player provider switch.
    enum Provider: String, CaseIterable {
        case torbox
        case realDebrid
        case premiumize

        var displayName: String {
            switch self {
            case .torbox: return "TorBox"
            case .realDebrid: return "Real-Debrid"
            case .premiumize: return "Premiumize"
            }
        }
        /// Short token used in DiagLog lines (never a credential).
        var logToken: String {
            switch self {
            case .torbox: return "torbox"
            case .realDebrid: return "rd"
            case .premiumize: return "premiumize"
            }
        }
    }

    /// Live cache state of one provider for one hash.
    enum CacheState: Equatable {
        case checking
        case cached
        case notCached
        case probeError
        case notConfigured

        var logToken: String {
            switch self {
            case .checking: return "checking"
            case .cached: return "cached"
            case .notCached: return "not-cached"
            case .probeError: return "probe-error"
            case .notConfigured: return "not-configured"
            }
        }
        /// Row suffix for the switch surfaces (Vietnamese).
        var rowLabel: String {
            switch self {
            case .checking: return "đang kiểm tra…"
            case .cached: return "đã cache"
            case .notCached: return "chưa cache"
            case .probeError: return "lỗi kiểm tra"
            case .notConfigured: return "chưa cấu hình"
            }
        }
    }

    struct ProviderProbe: Equatable {
        let provider: Provider
        let state: CacheState
    }

    private static let videoExts: Set<String> = ["mkv", "mp4", "avi", "m4v", "mov", "ts", "m2ts", "wmv", "flv", "webm"]
    private static let friendlyExts: Set<String> = ["mp4", "m4v", "mov"]
    /// Server-side downloads of uncached torrents get a long but
    /// bounded budget; past it the user gets a clear message
    /// instead of an endless spinner.
    private static let budget: TimeInterval = 900

    static func resolve(hash: String, onPhase: (@Sendable (DebridPhaseEvent) -> Void)? = nil) async throws -> StreamInfo {
        // v1.22.15 (B-2): phase logging for the silent debrid
        // subsystem (H-1, V-14). Log lines only — provider +
        // phase + outcome kind, error kind as NSError
        // domain#code; never tokens, URLs, hashes or raw error
        // text (DiagLog law). No flow, order or budget changes.
        onPhase?(.probing)
        defer { onPhase?(.finished) }
        let clean = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count >= 32 else {
            DiagLog.log("debrid", "provider=all phase=resolve outcome=invalid-hash")
            throw DebridError.message("Mã torrent không hợp lệ.")
        }
        let tb = DebridTokens.torbox, rd = DebridTokens.rd, pm = DebridTokens.premiumize
        guard !tb.isEmpty || !rd.isEmpty || !pm.isEmpty else {
            DiagLog.log("debrid", "provider=all phase=resolve outcome=no-token")
            throw DebridError.noToken
        }
        DiagLog.log("debrid", "provider=all phase=resolve outcome=start")
        // P5 (spec §5.1): RD's probe has returned 403
        // disabled_endpoint on every call since L-T15 — the
        // automatic path no longer probes or resolves through
        // RD at all. The token, the Settings fields and the
        // provider functions are retained (a manual pin still
        // runs RD's flow); only the automatic legs are out.
        if !rd.isEmpty {
            DiagLog.log("debrid", "provider=rd phase=probe outcome=skipped reason=disabled-endpoint")
        }
        var lastError: Error = DebridError.noToken
        var attempted: Set<String> = []

        // Phase 1 — cache probes (v1.22.3): the first provider
        // that already HAS the title resolves it now. A probe is
        // one availability call; a provider whose probe misses (or
        // whose cached flow still fails) keeps its phase-2 turn.
        if !tb.isEmpty, await torboxIsCached(hash: clean, token: tb) {
            attempted.insert("tb")
            do {
                let stream = try await resolveTorBox(hash: clean, token: tb)
                logServed(provider: "torbox", stream: stream)
                return stream
            }
            catch {
                DiagLog.log("debrid", "provider=torbox phase=resolve-cached outcome=error kind=\((error as NSError).domain)#\((error as NSError).code)")
                lastError = error
            }
        }
        if !pm.isEmpty {
            // v1.22.15 (B-2, V-14): was `try?` — a probe failure
            // was indistinguishable from "not cached". The
            // not-cached outcome is logged inside
            // premiumizeDirectDL itself; only genuine probe
            // errors are logged here. Fallback unchanged: any
            // failure falls through to phase 2 exactly as the
            // `try?` did.
            do {
                let hit = try await premiumizeDirectDL(hash: clean, token: pm)
                logServed(provider: "premiumize", stream: hit)
                return hit
            } catch {
                if let debridError = error as? DebridError,
                   case .message(let text) = debridError,
                   text == "Premiumize chưa có sẵn torrent này." {
                    // Not cached — already logged as
                    // outcome=not-cached by premiumizeDirectDL.
                } else {
                    DiagLog.log("debrid", "provider=premiumize phase=probe outcome=probe-error kind=\((error as NSError).domain)#\((error as NSError).code)")
                }
            }
        }

        // Phase 2 — nobody has it cached (P2, spec §5.2):
        // candidates are the configured providers not attempted
        // in Phase 1, RD excluded (P5). Two candidates RACE —
        // both flows start together, each keeping its own
        // 900 s budget anchored at Phase-2 entry; the first
        // success wins and returns immediately, the loser is
        // cancelled locally (its server-side transfer continues
        // account-side and may serve a later play via the
        // Phase-1 cache probe). Both failing throws
        // Premiumize's error — the same error the old serial
        // order (TorBox → Premiumize) surfaced last. One
        // candidate runs alone. `DebridError.downloading` from
        // a leg is that leg's failure. The `attempted` rule is
        // preserved verbatim: a provider whose Phase-1 cached
        // flow ran and failed does NOT join Phase 2.
        let phase2Start = Date()
        var phase2Tokens: [String] = []
        if !tb.isEmpty && !attempted.contains("tb") { phase2Tokens.append("torbox") }
        if !pm.isEmpty { phase2Tokens.append("premiumize") }
        if !phase2Tokens.isEmpty {
            DiagLog.log("debrid", "provider=all phase=phase2 mode=\(phase2Tokens.count > 1 ? "race" : "single") providers=\(phase2Tokens.joined(separator: ","))")
            onPhase?(.downloading(providers: phase2Tokens))
        }
        if phase2Tokens.count == 2 {
            let box = DebridPhase2RaceBox(providers: phase2Tokens)
            // 1.22.19 (L-21): heartbeat — a race whose legs
            // are both still polling used to leave NO trace
            // between its start lines and its end (the
            // 2026-11-22 23:43 session shows a both-uncached
            // race silent for 52 s, indistinguishable from a
            // hang). Every ~10 s the race now states who is
            // still pending and for how long. The task is
            // cancelled when the race resolves and self-exits
            // once the box reports itself resolved.
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if Task.isCancelled { return }
                    guard let pending = box.pendingProviders() else { return }
                    DiagLog.log("debrid", "provider=all phase=phase2 outcome=heartbeat pending=\(pending.joined(separator: ",")) elapsed_ms=\(Int(Date().timeIntervalSince(phase2Start) * 1000))")
                }
            }
            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<DebridPhase2RaceBox.Outcome, Never>) in
                    box.arm(continuation)
                    let torboxTask = Task {
                        do {
                            let stream = try await resolveTorBox(hash: clean, token: tb)
                            logServed(provider: "torbox", stream: stream)
                            box.succeed(stream)
                        } catch {
                            DiagLog.log("debrid", "provider=torbox phase=resolve outcome=error kind=\((error as NSError).domain)#\((error as NSError).code)")
                            if let remaining = box.fail(provider: "torbox", error: error) {
                                onPhase?(.downloading(providers: remaining))
                            }
                        }
                    }
                    let premiumizeTask = Task {
                        do {
                            let stream = try await resolvePremiumize(hash: clean, token: pm,
                                                                      deadline: phase2Start.addingTimeInterval(budget))
                            logServed(provider: "premiumize", stream: stream)
                            box.succeed(stream)
                        } catch {
                            DiagLog.log("debrid", "provider=premiumize phase=resolve outcome=error kind=\((error as NSError).domain)#\((error as NSError).code)")
                            if let remaining = box.fail(provider: "premiumize", error: error) {
                                onPhase?(.downloading(providers: remaining))
                            }
                        }
                    }
                    box.attach(tasks: [torboxTask, premiumizeTask])
                }
            } onCancel: {
                box.cancel()
            }
            heartbeat.cancel()
            // 1.22.19 (L-21, F-B1): join the heartbeat before
            // the terminal line — a cancelled-but-unawaited
            // heartbeat could otherwise log after it.
            await heartbeat.value
            // 1.22.19 (L-21): the race's terminal line —
            // EVERY exit is on the record (won / both-failed
            // / cancelled), so a superseded attempt can no
            // longer vanish mid-flight the way the
            // 2026-11-22 23:01 attempt did.
            switch outcome {
            case .success(let stream):
                DiagLog.log("debrid", "provider=all phase=phase2 outcome=won")
                return stream
            case .failed(let failures):
                DiagLog.log("debrid", "provider=all phase=phase2 outcome=both-failed")
                lastError = failures["premiumize"] ?? lastError
            case .cancelled:
                DiagLog.log("debrid", "provider=all phase=phase2 outcome=cancelled")
                throw CancellationError()
            }
        } else if phase2Tokens == ["torbox"] {
            do {
                let stream = try await resolveTorBox(hash: clean, token: tb)
                logServed(provider: "torbox", stream: stream)
                return stream
            }
            catch {
                DiagLog.log("debrid", "provider=torbox phase=resolve outcome=error kind=\((error as NSError).domain)#\((error as NSError).code)")
                lastError = error
            }
        } else if phase2Tokens == ["premiumize"] {
            do {
                let stream = try await resolvePremiumize(hash: clean, token: pm,
                                                          deadline: phase2Start.addingTimeInterval(budget))
                logServed(provider: "premiumize", stream: stream)
                return stream
            } catch {
                DiagLog.log("debrid", "provider=premiumize phase=resolve outcome=error kind=\((error as NSError).domain)#\((error as NSError).code)")
                lastError = error
            }
        }
        DiagLog.log("debrid", "provider=all phase=resolve outcome=failed kind=\((lastError as NSError).domain)#\((lastError as NSError).code)")
        throw lastError
    }

    /// 1.22.19 (L-21): the served-stream accountability
    /// line — provider + URL scheme/host ONLY (DiagLog
    /// law: never the full signed URL, never a token), so
    /// a future player-side URL failure can be attributed
    /// to the leg that produced the stream. Called at
    /// every success exit of `resolve(hash:onPhase:)` and
    /// inside the race legs just before they hand their
    /// stream to the box.
    private static func logServed(provider: String, stream: StreamInfo) {
        let url = URL(string: stream.url)
        DiagLog.log("debrid", "provider=\(provider) phase=resolve outcome=served scheme=\(url?.scheme ?? "?") host=\(url?.host ?? "?")")
    }

    /// NEXT-D D5 (tvOS-only divergence, 1.3.0): PROBE-ONLY
    /// resolve for the Detail backdrop preview. Runs the same
    /// Phase-1 cache probes as `resolve(hash:)` (TorBox
    /// checkcached → Premiumize directdl — RD dropped, §5.1),
    /// and when a provider reports the title cached
    /// it resolves through that provider's normal flow, exactly
    /// like Phase 1. It NEVER reaches the Phase-2 download
    /// chain: when no provider reports the title cached it
    /// returns nil, so a preview can spend a probe but can
    /// never start a server-side download. `resolve(hash:)`
    /// itself is unchanged.
    static func resolveCachedOnly(hash: String) async -> StreamInfo? {
        let clean = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count >= 32 else {
            DiagLog.log("debrid", "provider=all phase=probe-only outcome=invalid-hash")
            return nil
        }
        let tb = DebridTokens.torbox, rd = DebridTokens.rd, pm = DebridTokens.premiumize
        guard !tb.isEmpty || !rd.isEmpty || !pm.isEmpty else {
            DiagLog.log("debrid", "provider=all phase=probe-only outcome=no-token")
            return nil
        }
        // Review-gate fix (1.3.0): cancellation is never
        // swallowed here — Task.isCancelled is checked between
        // provider attempts, and a CancellationError out of a
        // provider flow aborts promptly with nil (this
        // function's shape) instead of being converted by a
        // `try?` into "try the next provider".
        if !tb.isEmpty, await torboxIsCached(hash: clean, token: tb) {
            if Task.isCancelled { return nil }
            do {
                return try await resolveTorBox(hash: clean, token: tb)
            } catch is CancellationError {
                return nil
            } catch {
                // Cached flow failed — the next provider's
                // probe still gets its turn (as in Phase 1).
            }
        }
        if Task.isCancelled { return nil }
        // P5 tvOS delta (spec §5.1): the RD leg is dropped —
        // resolveCachedOnly never probes RD (its endpoint is
        // disabled); a manual provider pin still runs RD's
        // flow through resolve(hash:provider:).
        if Task.isCancelled { return nil }
        if !pm.isEmpty {
            // premiumizeDirectDL IS the probe: it returns the
            // final links when cached and throws the not-cached
            // message otherwise (already logged inside).
            do {
                return try await premiumizeDirectDL(hash: clean, token: pm)
            } catch is CancellationError {
                return nil
            } catch {
                // Not cached / probe error — logged inside.
            }
        }
        DiagLog.log("debrid", "provider=all phase=probe-only outcome=not-cached")
        return nil
    }

    /// L-T13 (1.3.1, tvOS adaptation): per-provider cache state
    /// for one hash — the Phase-1 probe set generalised so the
    /// player session can render provider switch rows with LIVE
    /// state. Probe-only exactly like `resolveCachedOnly`: it
    /// never starts a server-side download. Providers without a
    /// configured token report `.notConfigured`.
    static func probeAll(hash: String) async -> [ProviderProbe] {
        let clean = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count >= 32 else {
            DiagLog.log("debrid", "provider=all phase=probe-all outcome=invalid-hash")
            return Provider.allCases.map { ProviderProbe(provider: $0, state: .probeError) }
        }
        var probes: [ProviderProbe] = []
        let tb = DebridTokens.torbox, rd = DebridTokens.rd, pm = DebridTokens.premiumize
        if tb.isEmpty {
            probes.append(ProviderProbe(provider: .torbox, state: .notConfigured))
        } else {
            probes.append(ProviderProbe(provider: .torbox,
                                        state: await torboxCacheState(hash: clean, token: tb)))
        }
        if Task.isCancelled { return probes }
        if rd.isEmpty {
            probes.append(ProviderProbe(provider: .realDebrid, state: .notConfigured))
        } else {
            // P5 tvOS delta (spec §5.1): RD's row is reported
            // as .probeError WITHOUT a network call — the same
            // visible state as today's real 403 from the
            // disabled endpoint, at zero network cost.
            DiagLog.log("debrid", "provider=rd phase=probe outcome=skipped reason=disabled-endpoint")
            probes.append(ProviderProbe(provider: .realDebrid, state: .probeError))
        }
        if Task.isCancelled { return probes }
        if pm.isEmpty {
            probes.append(ProviderProbe(provider: .premiumize, state: .notConfigured))
        } else {
            probes.append(ProviderProbe(provider: .premiumize,
                                        state: await premiumizeCacheState(hash: clean, token: pm)))
        }
        let summary = probes.map { "\($0.provider.logToken)=\($0.state.logToken)" }.joined(separator: " ")
        DiagLog.log("debrid", "provider=all phase=probe-all outcome=done \(summary)")
        return probes
    }

    /// L-T13 (1.3.1, tvOS adaptation): provider-PINNED resolve
    /// for a user-initiated provider switch. Runs ONLY the named
    /// provider's flow, reusing the existing per-provider
    /// internals — for Premiumize the cached directdl first,
    /// then its full flow; TorBox / Real-Debrid run their own
    /// flow (which serves both the cached and the download
    /// case). A user pick may therefore start a server-side
    /// download on that provider — the cached-only rule binds
    /// the PREVIEW probe, never a user intent. The default
    /// `resolve(hash:)` above is unchanged.
    static func resolve(hash: String, provider: Provider) async throws -> StreamInfo {
        let clean = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count >= 32 else {
            DiagLog.log("debrid", "provider=\(provider.logToken) phase=provider-pinned outcome=invalid-hash")
            throw DebridError.message("Mã torrent không hợp lệ.")
        }
        DiagLog.log("debrid", "provider=\(provider.logToken) phase=provider-pinned outcome=start")
        switch provider {
        case .torbox:
            let token = DebridTokens.torbox
            guard !token.isEmpty else { throw DebridError.noToken }
            return try await resolveTorBox(hash: clean, token: token)
        case .realDebrid:
            let token = DebridTokens.rd
            guard !token.isEmpty else { throw DebridError.noToken }
            return try await resolveRD(hash: clean, token: token)
        case .premiumize:
            let token = DebridTokens.premiumize
            guard !token.isEmpty else { throw DebridError.noToken }
            if let hit = try? await premiumizeDirectDL(hash: clean, token: token) {
                return hit
            }
            if Task.isCancelled { throw CancellationError() }
            return try await resolvePremiumize(hash: clean, token: token,
                                               deadline: Date().addingTimeInterval(budget))
        }
    }

    // MARK: - Cache probes

    /// TorBox cache check: does TorBox already hold this hash?
    /// Response shapes vary (list or dict keyed by hash), so the
    /// parse is defensive: any entry for our hash flagged cached.
    private static func torboxIsCached(hash: String, token: String) async -> Bool {
        await torboxCacheState(hash: hash, token: token) == .cached
    }

    /// L-T13 generalisation of `torboxIsCached`: the same probe
    /// and the same log lines, but the outcome distinguishes a
    /// probe ERROR from a plain not-cached (the Bool wrapper
    /// above keeps the historical Phase-1 fallback — `false`
    /// on any failure).
    private static func torboxCacheState(hash: String, token: String) async -> CacheState {
        let base = "https://api.torbox.app/v1/api"
        // v1.22.15 (B-2, V-14): was `try?` — a failed probe
        // returned the same `false` as "not cached". The
        // do/catch keeps the identical fallback (`false` on any
        // failure) and only adds the distinguishing outcome.
        let response: [String: Any]
        do {
            response = try await torboxRequest(base, token, "GET",
                                               "/torrents/checkcached?hash=\(hash)&format=list", form: nil)
        } catch {
            DiagLog.log("debrid", "provider=torbox phase=probe outcome=probe-error kind=\((error as NSError).domain)#\((error as NSError).code)")
            return .probeError
        }
        guard (response["success"] as? Bool) ?? true else {
            DiagLog.log("debrid", "provider=torbox phase=probe outcome=not-cached")
            return .notCached
        }
        let result: Bool
        if let list = response["data"] as? [[String: Any]] {
            result = list.contains { entry in
                ((entry["hash"] as? String)?.lowercased() == hash) && ((entry["cached"] as? Bool) ?? false)
            }
        } else if let dict = response["data"] as? [String: Any], let entry = dict[hash] as? [String: Any] {
            result = (entry["cached"] as? Bool) ?? false
        } else {
            result = false
        }
        DiagLog.log("debrid", "provider=torbox phase=probe outcome=\(result ? "hit" : "not-cached")")
        return result ? .cached : .notCached
    }

    /// Real-Debrid instant availability: a non-empty variant list
    /// for the hash means RD can serve it without downloading.
    private static func rdIsAvailable(hash: String, token: String) async -> Bool {
        await rdCacheState(hash: hash, token: token) == .cached
    }

    /// L-T13 generalisation of `rdIsAvailable`: same probe, same
    /// log lines, with the probe-error outcome distinguished
    /// (the Bool wrapper keeps the historical `false` fallback).
    private static func rdCacheState(hash: String, token: String) async -> CacheState {
        let base = "https://api.real-debrid.com/rest/1.0"
        // v1.22.15 (B-2, V-14): same `try?` distinction fix as
        // torboxIsCached — identical `false` fallback, probe
        // failures now log outcome=probe-error instead of
        // masquerading as "not cached".
        let response: [String: Any]
        do {
            response = try await rdRequest(base, token, "GET",
                                           "/torrents/instantAvailability/\(hash)", form: nil)
        } catch {
            DiagLog.log("debrid", "provider=rd phase=probe outcome=probe-error kind=\((error as NSError).domain)#\((error as NSError).code)")
            return .probeError
        }
        guard let entry = response[hash] as? [String: Any],
              let variants = entry["rd"] as? [[String: Any]] else {
            DiagLog.log("debrid", "provider=rd phase=probe outcome=not-cached")
            return .notCached
        }
        let result = variants.contains { !($0.isEmpty) }
        DiagLog.log("debrid", "provider=rd phase=probe outcome=\(result ? "hit" : "not-cached")")
        return result ? .cached : .notCached
    }

    /// L-T13: Premiumize's cache state — `premiumizeDirectDL`
    /// IS the probe (it returns the final links iff cached and
    /// throws the known not-cached message otherwise, both
    /// already logged inside). The resolved stream is discarded
    /// here; only the state is reported.
    private static func premiumizeCacheState(hash: String, token: String) async -> CacheState {
        do {
            _ = try await premiumizeDirectDL(hash: hash, token: token)
            return .cached
        } catch let error as DebridError {
            if case .message(let text) = error,
               text == "Premiumize chưa có sẵn torrent này." {
                return .notCached
            }
            return .probeError
        } catch {
            return .probeError
        }
    }

    static func needsCompatEngine(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return !ext.isEmpty && !friendlyExts.contains(ext)
    }

    // MARK: - Real-Debrid

    private static func resolveRD(hash: String, token: String) async throws -> StreamInfo {
        // v1.22.15 (B-2): phase-boundary log lines only.
        DiagLog.log("debrid", "provider=rd phase=resolve outcome=start")
        let base = "https://api.real-debrid.com/rest/1.0"
        let magnet = "magnet:?xt=urn:btih:" + hash
        let added = try await rdRequest(base, token, "POST", "/torrents/addMagnet", form: ["magnet": magnet])
        guard let id = added["id"] as? String, !id.isEmpty else {
            DiagLog.log("debrid", "provider=rd phase=create outcome=failed")
            throw DebridError.message("Real-Debrid không nhận magnet này.")
        }

        let info = try await rdRequest(base, token, "GET", "/torrents/info/\(id)", form: nil)
        let files = (info["files"] as? [[String: Any]]) ?? []
        guard let pick = pickFile(files.map {
            (id: ($0["id"] as? Int) ?? -1,
             bytes: ($0["bytes"] as? Int) ?? 0,
             path: ($0["path"] as? String) ?? "")
        }) else {
            throw DebridError.message("Torrent không có file nào chọn được.")
        }
        _ = try await rdRequest(base, token, "POST", "/torrents/selectFiles/\(id)", form: ["files": String(pick.id)])

        let deadline = Date().addingTimeInterval(budget)
        var link: String?
        while link == nil {
            let poll = try await rdRequest(base, token, "GET", "/torrents/info/\(id)", form: nil)
            if let status = poll["status"] as? String, status == "magnet_error" || status == "error" || status == "dead" {
                DiagLog.log("debrid", "provider=rd phase=poll outcome=torrent-error")
                throw DebridError.message("Real-Debrid báo torrent lỗi (trạng thái \(status)).")
            }
            if let links = poll["links"] as? [String], let first = links.first, !first.isEmpty {
                link = first
            } else {
                if Date() > deadline {
                    DiagLog.log("debrid", "provider=rd phase=poll outcome=timeout")
                    throw DebridError.timeout
                }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }

        let unrestricted = try await rdRequest(base, token, "POST", "/unrestrict/link", form: ["link": link!])
        guard let download = unrestricted["download"] as? String, !download.isEmpty else {
            DiagLog.log("debrid", "provider=rd phase=unrestrict outcome=failed")
            throw DebridError.message("Real-Debrid không trả link tải.")
        }
        let filename = (unrestricted["filename"] as? String) ?? pick.path
        DiagLog.log("debrid", "provider=rd phase=resolve outcome=ok")
        return StreamInfo(url: download, headers: [:], useCompatEngine: needsCompatEngine(filename: filename))
    }

    private static func rdRequest(_ base: String, _ token: String, _ method: String, _ path: String, form: [String: String]?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(form)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            // v1.22.15 (B-2): log line only; the throw is unchanged.
            DiagLog.log("debrid", "provider=rd phase=request outcome=network-error kind=\((error as NSError).domain)#\((error as NSError).code)")
            throw DebridError.message("Real-Debrid: lỗi kết nối (mã \(error.code.rawValue))")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            DiagLog.log("debrid", "provider=rd phase=request outcome=http-error status=\(code)")
            // L-T15 (1.3.1, log-only): the RD error BODY was
            // discarded on this path — callers (probe /
            // unrestrict) only ever saw domain#code, so RD's
            // own error_code (e.g. the disabled-endpoint code
            // behind the recurring probe 403) could never be
            // read from a device log. One line: status + a
            // short, single-line body excerpt. The body is
            // RD's error payload (error / error_code fields);
            // the bearer token travels in the request HEADER,
            // never in a response body, so nothing secret can
            // appear here. No behaviour change.
            let bodyExcerpt = (String(data: data, encoding: .utf8) ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(160)
            DiagLog.log("debrid", "provider=rd phase=request outcome=http-error-body status=\(code) body=\(bodyExcerpt)")
            throw DebridError.http(code, String(data: data, encoding: .utf8)?.prefix(160).description ?? "")
        }
        if data.isEmpty { return [:] }
        // v1.22.15 (B-2, V-14): was `try?` — a JSON-parse
        // failure returned the same `[:]` as an empty/absent
        // payload. Identical fallback (`[:]`); the outcome
        // kind now distinguishes parse-error from parse-empty.
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            if let dict = object as? [String: Any] { return dict }
            DiagLog.log("debrid", "provider=rd phase=request outcome=parse-empty")
            return [:]
        } catch {
            DiagLog.log("debrid", "provider=rd phase=request outcome=parse-error kind=\((error as NSError).domain)#\((error as NSError).code)")
            return [:]
        }
    }

    // MARK: - TorBox

    private static func resolveTorBox(hash: String, token: String) async throws -> StreamInfo {
        // v1.22.15 (B-2): phase-boundary log lines only.
        DiagLog.log("debrid", "provider=torbox phase=resolve outcome=start")
        let base = "https://api.torbox.app/v1/api"
        let magnet = "magnet:?xt=urn:btih:" + hash
        let created = try await torboxRequest(base, token, "POST", "/torrents/createtorrent", form: ["magnet": magnet])
        let createdData = (created["data"] as? [String: Any]) ?? [:]
        guard let torrentId = (createdData["torrent_id"] as? Int) ?? (created["torrent_id"] as? Int) else {
            DiagLog.log("debrid", "provider=torbox phase=create outcome=failed")
            throw DebridError.message("TorBox không nhận magnet này.")
        }

        let deadline = Date().addingTimeInterval(budget)
        var downloadURL: String?
        var pickedName = ""
        while downloadURL == nil {
            // v1.22.3 fix (doc-verified against the TorBox SDK and
            // live-captured clients): poll THIS torrent by id with
            // the server cache bypassed. The previous code scanned
            // the FULL mylist, which TorBox serves from its own
            // cache — a fresh torrent was often invisible or stale
            // there, so the loop starved and TorBox "had no link"
            // even when it held the file. Readiness uses all three
            // documented fields (present / cached / finished).
            let response = try await torboxRequest(base, token, "GET",
                                                   "/torrents/mylist?id=\(torrentId)&bypass_cache=true", form: nil)
            var entry: [String: Any]?
            if let single = response["data"] as? [String: Any] {
                entry = single
            } else if let list = response["data"] as? [[String: Any]] {
                entry = list.first(where: { ($0["id"] as? Int) == torrentId })
            }
            if let entry {
                let finished = (entry["download_finished"] as? Bool) ?? false
                let present = (entry["download_present"] as? Bool) ?? false
                let cached = (entry["cached"] as? Bool) ?? false
                if finished || present || cached {
                    let files = (entry["files"] as? [[String: Any]]) ?? []
                    guard let pick = pickFile(files.map {
                        (id: ($0["id"] as? Int) ?? -1,
                         bytes: ($0["size"] as? Int) ?? 0,
                         path: ($0["short_name"] as? String) ?? ($0["name"] as? String) ?? "")
                    }) else {
                        throw DebridError.message("Torrent không có file nào chọn được.")
                    }
                    pickedName = pick.path
                    downloadURL = try await torboxDownloadURL(base, token, torrentId, pick.id)
                }
            }
            if downloadURL == nil {
                if Date() > deadline {
                    DiagLog.log("debrid", "provider=torbox phase=poll outcome=timeout")
                    throw DebridError.timeout
                }
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        DiagLog.log("debrid", "provider=torbox phase=resolve outcome=ok")
        return StreamInfo(url: downloadURL!, headers: [:], useCompatEngine: needsCompatEngine(filename: pickedName))
    }

    private static func torboxDownloadURL(_ base: String, _ token: String, _ torrentId: Int, _ fileId: Int) async throws -> String {
        var components = URLComponents(string: base + "/torrents/requestdl")!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "torrent_id", value: String(torrentId)),
            URLQueryItem(name: "file_id", value: String(fileId)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            // v1.22.15 (B-2): log line only; the throw is unchanged.
            DiagLog.log("debrid", "provider=torbox phase=requestdl outcome=network-error kind=\((error as NSError).domain)#\((error as NSError).code)")
            throw DebridError.message("TorBox: lỗi kết nối khi xin link (mã \(error.code.rawValue))")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            DiagLog.log("debrid", "provider=torbox phase=requestdl outcome=http-error status=\(code)")
            throw DebridError.http(code, String(body.prefix(160)))
        }
        // v1.22.15 (B-2, V-14): was `try?` — a JSON-parse
        // failure fell through silently to the plain-body
        // check. Identical fall-through; parse failures now
        // leave an outcome line.
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            if let json = object as? [String: Any],
               let url = json["data"] as? String, !url.isEmpty {
                return url
            }
        } catch {
            DiagLog.log("debrid", "provider=torbox phase=requestdl outcome=parse-error kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http") { return trimmed }
        throw DebridError.message("TorBox không trả link tải.")
    }

    private static func torboxRequest(_ base: String, _ token: String, _ method: String, _ path: String, form: [String: String]?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(form)
        }
        // 1.22.19 (L-21): the endpoint (path only — the
        // query carries the torrent hash, which DiagLog
        // law keeps off the record) rides the failure
        // lines so a torbox HTTP error names the call
        // that failed (createtorrent vs the mylist poll
        // were indistinguishable in the 2026-11-22 log).
        let endpoint = String(path.prefix(while: { $0 != "?" }))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            // v1.22.15 (B-2): log line only; the throw is unchanged.
            DiagLog.log("debrid", "provider=torbox phase=request outcome=network-error kind=\((error as NSError).domain)#\((error as NSError).code) endpoint=\(endpoint)")
            throw DebridError.message("TorBox: lỗi kết nối (mã \(error.code.rawValue))")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            DiagLog.log("debrid", "provider=torbox phase=request outcome=http-error status=\(code) endpoint=\(endpoint)")
            throw DebridError.http(code, String(data: data, encoding: .utf8)?.prefix(160).description ?? "")
        }
        if data.isEmpty { return [:] }
        // v1.22.15 (B-2, V-14): same `try?` JSON distinction
        // fix as rdRequest — identical `[:]` fallback.
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            if let dict = object as? [String: Any] { return dict }
            DiagLog.log("debrid", "provider=torbox phase=request outcome=parse-empty")
            return [:]
        } catch {
            DiagLog.log("debrid", "provider=torbox phase=request outcome=parse-error kind=\((error as NSError).domain)#\((error as NSError).code)")
            return [:]
        }
    }

    // MARK: - Premiumize

    /// Cache probe: when the torrent is already on Premiumize,
    /// directdl answers with the final file links in one call.
    /// Throws (message) when it is not cached — callers tell
    /// that apart from probe errors via the logged outcome
    /// (v1.22.15; previously they used `try?`).
    private static func premiumizeDirectDL(hash: String, token: String) async throws -> StreamInfo {
        // v1.22.15 (B-2, V-14): outcome lines only — the
        // not-cached throws below are what callers distinguish
        // from genuine probe errors (see resolve's probe).
        let magnet = "magnet:?xt=urn:btih:" + hash
        let response = try await pmRequest(token, "POST", "/transfer/directdl", form: ["src": magnet], query: nil)
        guard (response["status"] as? String) == "success" else {
            DiagLog.log("debrid", "provider=premiumize phase=directdl outcome=not-cached")
            throw DebridError.message("Premiumize chưa có sẵn torrent này.")
        }
        let content = (response["content"] as? [[String: Any]]) ?? []
        let rows: [(id: Int, bytes: Int, path: String)] = content.enumerated().map { pair in
            (id: pair.offset,
             bytes: (pair.element["size"] as? Int) ?? 0,
             path: (pair.element["path"] as? String) ?? "")
        }
        guard let pick = pickFile(rows),
              let link = content[pick.id]["link"] as? String, !link.isEmpty else {
            DiagLog.log("debrid", "provider=premiumize phase=directdl outcome=not-cached")
            throw DebridError.message("Premiumize chưa có sẵn torrent này.")
        }
        DiagLog.log("debrid", "provider=premiumize phase=directdl outcome=ok")
        return StreamInfo(url: link, headers: [:], useCompatEngine: needsCompatEngine(filename: pick.path))
    }

    private static func resolvePremiumize(hash: String, token: String, deadline: Date) async throws -> StreamInfo {
        // v1.22.15 (B-2): phase-boundary log lines only.
        DiagLog.log("debrid", "provider=premiumize phase=resolve outcome=start")
        let magnet = "magnet:?xt=urn:btih:" + hash
        let created = try await pmRequest(token, "POST", "/transfer/create", form: ["src": magnet], query: nil)
        guard (created["status"] as? String) == "success", let transferId = created["id"] as? String, !transferId.isEmpty else {
            DiagLog.log("debrid", "provider=premiumize phase=create outcome=failed")
            throw DebridError.message("Premiumize không nhận magnet này.")
        }
        while true {
            let list = try await pmRequest(token, "GET", "/transfer/list", form: nil, query: nil)
            let transfers = (list["transfers"] as? [[String: Any]]) ?? []
            if let entry = transfers.first(where: { ($0["id"] as? String) == transferId }) {
                let status = (entry["status"] as? String) ?? ""
                if status == "error" {
                    DiagLog.log("debrid", "provider=premiumize phase=poll outcome=torrent-error")
                    let detail = (entry["message"] as? String) ?? ""
                    throw DebridError.message("Premiumize báo torrent lỗi\(detail.isEmpty ? "" : ": \(detail)")")
                }
                if status == "finished" || status == "seeding" {
                    if let folderId = entry["folder_id"] as? String, !folderId.isEmpty,
                       let picked = try await premiumizeFolderPick(token, folderId) {
                        DiagLog.log("debrid", "provider=premiumize phase=resolve outcome=ok")
                        return picked
                    }
                    // Single-file transfer, or the folder listing
                    // carried no playable file: the content is in
                    // the cloud now, so directdl should answer.
                    // v1.22.15 (B-2, V-14): was `try?` — same
                    // distinction as the phase-1 probe: the
                    // not-cached outcome is logged inside
                    // premiumizeDirectDL; only genuine errors
                    // log here. Fallback unchanged (throw below).
                    do {
                        let hit = try await premiumizeDirectDL(hash: hash, token: token)
                        DiagLog.log("debrid", "provider=premiumize phase=resolve outcome=ok")
                        return hit
                    } catch {
                        if let debridError = error as? DebridError,
                           case .message(let text) = debridError,
                           text == "Premiumize chưa có sẵn torrent này." {
                            // Not cached — already logged as
                            // outcome=not-cached by premiumizeDirectDL.
                        } else {
                            DiagLog.log("debrid", "provider=premiumize phase=directdl outcome=probe-error kind=\((error as NSError).domain)#\((error as NSError).code)")
                        }
                    }
                    DiagLog.log("debrid", "provider=premiumize phase=resolve outcome=failed")
                    throw DebridError.message("Premiumize đã tải xong nhưng không lấy được link file.")
                }
            }
            if Date() > deadline {
                DiagLog.log("debrid", "provider=premiumize phase=poll outcome=timeout")
                throw DebridError.downloading
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private static func premiumizeFolderPick(_ token: String, _ folderId: String) async throws -> StreamInfo? {
        let folder = try await pmRequest(token, "GET", "/folder/list", form: nil, query: ["id": folderId])
        let content = ((folder["content"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "file" }
        let rows: [(id: Int, bytes: Int, path: String)] = content.enumerated().map { pair in
            (id: pair.offset,
             bytes: (pair.element["size"] as? Int) ?? 0,
             path: (pair.element["name"] as? String) ?? "")
        }
        guard let pick = pickFile(rows),
              let link = content[pick.id]["link"] as? String, !link.isEmpty else {
            // v1.22.15 (B-2): log line only; the nil return is unchanged.
            DiagLog.log("debrid", "provider=premiumize phase=folder-pick outcome=empty")
            return nil
        }
        DiagLog.log("debrid", "provider=premiumize phase=folder-pick outcome=ok")
        return StreamInfo(url: link, headers: [:], useCompatEngine: needsCompatEngine(filename: pick.path))
    }

    private static func pmRequest(_ token: String, _ method: String, _ path: String, form: [String: String]?, query: [String: String]?) async throws -> [String: Any] {
        var components = URLComponents(string: "https://www.premiumize.me/api" + path)!
        if let query {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(form)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            // v1.22.15 (B-2): log line only; the throw is unchanged.
            DiagLog.log("debrid", "provider=premiumize phase=request outcome=network-error kind=\((error as NSError).domain)#\((error as NSError).code)")
            throw DebridError.message("Premiumize: lỗi kết nối (mã \(error.code.rawValue))")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            DiagLog.log("debrid", "provider=premiumize phase=request outcome=http-error status=\(code)")
            throw DebridError.http(code, String(data: data, encoding: .utf8)?.prefix(160).description ?? "")
        }
        if data.isEmpty { return [:] }
        // v1.22.15 (B-2, V-14): same `try?` JSON distinction
        // fix as rdRequest — identical `[:]` fallback.
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            if let dict = object as? [String: Any] { return dict }
            DiagLog.log("debrid", "provider=premiumize phase=request outcome=parse-empty")
            return [:]
        } catch {
            DiagLog.log("debrid", "provider=premiumize phase=request outcome=parse-error kind=\((error as NSError).domain)#\((error as NSError).code)")
            return [:]
        }
    }

    // MARK: - Shared

    private static func formBody(_ form: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let parts = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(parts.joined(separator: "&").utf8)
    }

    /// Picks the file a player should receive: the largest video
    /// file, preferring AVPlayer-friendly containers so most titles
    /// stay on the native player; falls back to the largest file of
    /// any kind when no video extension is recognisable.
    private static func pickFile(_ files: [(id: Int, bytes: Int, path: String)]) -> (id: Int, path: String)? {
        // v1.22.15 (B-2): outcome lines only — the ranking
        // itself (V-15, recorded) is untouched.
        let valid = files.filter { $0.id >= 0 }
        guard !valid.isEmpty else {
            DiagLog.log("debrid", "provider=shared phase=pick outcome=empty")
            return nil
        }
        func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }
        let videos = valid.filter { videoExts.contains(ext($0.path)) }
        if !videos.isEmpty {
            let friendly = videos.filter { friendlyExts.contains(ext($0.path)) }
            let pool = friendly.isEmpty ? videos : friendly
            let best = pool.max(by: { $0.bytes < $1.bytes })!
            DiagLog.log("debrid", "provider=shared phase=pick outcome=ok")
            return (best.id, best.path)
        }
        let best = valid.max(by: { $0.bytes < $1.bytes })!
        DiagLog.log("debrid", "provider=shared phase=pick outcome=ok")
        return (best.id, best.path)
    }
}
/// Resume-once box for the Phase-2 provider race (spec §5.2):
/// the first leg to succeed resumes the waiting resolve at
/// once and cancels the loser locally; a leg failure resumes
/// only when it was the last leg standing. Two unstructured
/// tasks + this box is the house race idiom (TVNetProbe's DNS
/// race / TVSourceProbe) — a throwing task group would cancel
/// its sibling and its exit would await a loser stuck in a
/// long request. The NSLock is the whole confinement story,
/// so the `@unchecked Sendable` states exactly that.
private final class DebridPhase2RaceBox: @unchecked Sendable {
    enum Outcome {
        case success(StreamInfo)
        case failed([String: Error])
        case cancelled
    }

    private let lock = NSLock()
    private let providers: [String]
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var resumed = false
    private var failures: [String: Error] = [:]
    private var tasks: [Task<Void, Never>] = []

    init(providers: [String]) {
        self.providers = providers
    }

    /// Called once, before either leg is created — a
    /// happens-before edge. If cancellation already resumed
    /// the box, the continuation is resumed on the spot
    /// (the PrefetchJoinBox setContinuation pattern).
    func arm(_ continuation: CheckedContinuation<Outcome, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            continuation.resume(returning: .cancelled)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func attach(tasks: [Task<Void, Never>]) {
        lock.lock()
        self.tasks = tasks
        let alreadyResumed = resumed
        lock.unlock()
        if alreadyResumed { tasks.forEach { $0.cancel() } }
    }

    func succeed(_ stream: StreamInfo) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: .success(stream))
    }

    /// Records one leg's failure. Returns the surviving
    /// provider tokens when the race continues (so the caller
    /// can re-emit the phase event naming the survivor), nil
    /// when the race is over — either this failure was the
    /// last leg's (resumed here with every failure) or a
    /// winner already resumed the box.
    func fail(provider: String, error: Error) -> [String]? {
        lock.lock()
        failures[provider] = error
        let remaining = providers.filter { failures[$0] == nil }
        if remaining.isEmpty {
            guard !resumed else { lock.unlock(); return nil }
            resumed = true
            let continuation = self.continuation
            self.continuation = nil
            let allFailures = failures
            lock.unlock()
            continuation?.resume(returning: .failed(allFailures))
            return nil
        }
        let alreadyResumed = resumed
        lock.unlock()
        return alreadyResumed ? nil : remaining
    }

    /// Outer cancellation: cancel both legs locally and
    /// resume as cancelled (the caller throws
    /// CancellationError).
    func cancel() {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: .cancelled)
    }

    /// 1.22.19 (L-21): read-only snapshot for the race
    /// heartbeat — the providers that have neither
    /// succeeded nor failed yet, in race order; nil once
    /// the box has resolved (success, both-failed or
    /// cancelled), so the heartbeat stops with the race.
    func pendingProviders() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return nil }
        return providers.filter { failures[$0] == nil }
    }
}
