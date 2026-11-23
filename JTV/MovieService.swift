import Foundation

enum MovieServiceError: Error, LocalizedError {
    case pluginUnavailable
    case noURL
    case emptyDetail
    case unresolvedEpisode
    case timedOut
    case sourceRefused(pluginName: String, status: Int?)

    var errorDescription: String? {
        switch self {
        case .pluginUnavailable: return "Plugin chưa sẵn sàng. Hãy đồng bộ nguồn plugin trong Cài đặt."
        case .noURL: return "Plugin không tạo được link dữ liệu."
        case .emptyDetail: return "Không tải được thông tin phim."
        case .unresolvedEpisode: return "Không tìm được link phát cho tập này."
        case .timedOut: return "Lấy link quá lâu. Kiểm tra mạng/VPN rồi bấm Thử lại."
        case .sourceRefused(let pluginName, _):
            return pluginName.isEmpty
                ? "Nguồn phát đã từ chối phát phim này. Không có nguồn nào khác phát được phim này."
                : "Nguồn \(pluginName) đã từ chối phát phim này. Không có nguồn nào khác phát được phim này."
        }
    }
}

/// (Removed in the 1.3.1 gate fix pass, F-B1: the preview
/// probe's budget race is now a structured task group inside
/// `resolveEpisodeForPreview` itself, so cancelling the
/// façade task — or the budget winning the race — cancels
/// the in-flight resolve chain instead of merely resuming a
/// continuation with nil while the chain ran on orphaned.)

/// Resume-once box for the cancellation-responsive pre-resolve
/// join (gate fix pass, Round 1 on R2, Lens 2 F5a): whichever
/// arrives first — the warm task's completion or the joining
/// caller's cancellation — resumes the waiting continuation
/// exactly once; the loser is dropped.
private final class PrefetchJoinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PlaybackResolution?, Never>?
    private var resumed = false

    func setContinuation(_ continuation: CheckedContinuation<PlaybackResolution?, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with value: PlaybackResolution?) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

/// Loads catalog data through the plugin contract and resolves episode
/// play targets into native streams, manga chapters or embed pages.
/// MainActor-isolated (Swift 6): it is a UI-facing store; its caches
/// were already lock-guarded, and its heavy work awaits out to
/// non-isolated helpers (Net, PluginEngine, DebridResolver).
@MainActor
final class MovieService: ObservableObject {
    let manager: PluginManager

    init(manager: PluginManager) {
        self.manager = manager
    }

    private func engine(for pluginId: String) async throws -> PluginEngine {
        guard let engine = await manager.engine(for: pluginId) else {
            throw MovieServiceError.pluginUnavailable
        }
        return engine
    }

    private func manifest(for pluginId: String) async -> PluginManifest? {
        await manager.installedPlugin(id: pluginId)?.manifest
    }

    // MARK: - Session page cache

    /// Short-TTL in-memory cache for LIST / SEARCH / DETAIL page
    /// text (v1.22): back-navigation and tab re-entry used to
    /// refetch page 1 every time (0.9–2.4 s each, measured).
    /// Playback resolution is never cached (links expire), and
    /// plugin scripts / source lists are never cached here —
    /// sync freshness is PluginManager's domain.
    private struct CachedPage { let text: String; let at: Date }
    private var pageCache: [String: CachedPage] = [:]
    private let pageCacheLock = NSLock()
    private let pageCacheTTL: TimeInterval = 60

    /// L-15 (1.3.6): parsed-list companion to the text cache
    /// above. The text cache alone still made every re-created
    /// ActorView / SearchResultsView instance re-run the full
    /// spinner → fetch → parse → paint cycle (a churned view
    /// instance pays it again per re-creation); caching the
    /// PARSED page under the same 60 s TTL lets a re-created
    /// view repaint from the stored page instead. Keyed
    /// plugin|slug-or-keyword|page — the list form carries
    /// its filter fields as one extra segment so a filtered
    /// category call can never collide with the actor
    /// surface's unfiltered call on the same slug + page.
    /// Successful parses only; playback resolution is never
    /// cached (see the text cache's note above).
    private struct CachedListPage { let page: ListPage; let at: Date }
    private var parsedListCache: [String: CachedListPage] = [:]
    private let parsedListCacheLock = NSLock()

    private func cachedListPage(forKey key: String) -> ListPage? {
        let hit = parsedListCacheLock.withLock { parsedListCache[key] }
        guard let hit, Date().timeIntervalSince(hit.at) < pageCacheTTL else { return nil }
        return hit.page
    }

    private func storeListPage(_ page: ListPage, forKey key: String) {
        parsedListCacheLock.withLock {
            parsedListCache[key] = CachedListPage(page: page, at: Date())
            if parsedListCache.count > 200 { parsedListCache.removeAll() }
        }
    }

    private static func listCacheKey(pluginId: String, slug: String, filters: ListFilters, page: Int) -> String {
        let extras = filters.extra.filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "list|\(pluginId)|\(slug)|\(page)|\(filters.category)|\(filters.country)|\(filters.year)|\(filters.sort)|\(extras)"
    }

    private func fetchPage(_ url: String) async throws -> String {
        // Swift 6: scoped withLock replaces lock()/unlock()
        // pairs in async contexts (see Cache.swift note).
        let hit = pageCacheLock.withLock { pageCache[url] }
        if let hit, Date().timeIntervalSince(hit.at) < pageCacheTTL {
            return hit.text
        }
        let text = try await Self.fetchTextWithDeadline(url)
        pageCacheLock.withLock {
            pageCache[url] = CachedPage(text: text, at: Date())
            if pageCache.count > 200 { pageCache.removeAll() }
        }
        return text
    }

    /// L-T05 guard (tvOS-only divergence from the iOS core):
    /// one page fetch gets a hard 20 s wall-clock budget.
    /// Net.fetchText's own retry policy can hold a walled or
    /// stalled host for 37 s (idle) to ~181 s (slow-drip) —
    /// tvOS has no WebView Cloudflare lane to escape into —
    /// while every healthy source in the device log lands in
    /// ~1–2 s, so the budget never fires for a working source;
    /// its retry chance inside the budget is preserved (one
    /// full 12 s attempt + backoff + a partial second attempt).
    /// On expiry the fetch task is cancelled (fetchText
    /// rethrows .cancelled immediately) and the existing
    /// MovieServiceError.timedOut surfaces to the caller's
    /// error state (Home per-section row / Browse TVErrorState).
    private static func fetchTextWithDeadline(_ url: String) async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await Net.fetchText(url) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw MovieServiceError.timedOut
                }
                guard let value = try await group.next() else {
                    throw MovieServiceError.timedOut
                }
                group.cancelAll()
                return value
            }
        } catch {
            if let mse = error as? MovieServiceError, case .timedOut = mse {
                DiagLog.log("net", "fetch timeout host=\(URL(string: url)?.host ?? "?") budget_ms=20000")
            }
            throw error
        }
    }

    /// Embed-page shapes a parser may hand back as its final answer.
    /// Deliberately narrow: disguised stream files (.vl) and signed
    /// extension-less media URLs must NOT match.
    static func looksLikeWebPage(_ urlString: String) -> Bool {
        guard let path = URL(string: urlString)?.path.lowercased() else { return false }
        return path.contains("/e/") || path.contains("/embed") || path.contains("/play/")
            || path.hasSuffix(".html") || path.hasSuffix(".htm") || path.hasSuffix(".php")
    }

    /// L-16 (1.3.6): the resolve-duration line's outcome
    /// vocabulary for a finished resolution.
    private static func chainOutcomeLabel(_ resolution: PlaybackResolution) -> String {
        switch resolution {
        case .video: return "video"
        case .embed: return "embed"
        case .manga: return "manga"
        }
    }

    func defaultHeaders(for pluginId: String) async -> [String: String] {
        var headers = ["User-Agent": Net.desktopUA]
        if let base = await manifest(for: pluginId)?.baseUrl, !base.isEmpty {
            headers["Referer"] = base.hasSuffix("/") ? base : base + "/"
        }
        return headers
    }

    // MARK: - Discovery

    func homeSections(pluginId: String) async -> [HomeSection] {
        guard let engine = try? await engine(for: pluginId) else { return [] }
        return await engine.homeSections()
    }

    func primaryCategories(pluginId: String) async -> [NameSlug] {
        guard let engine = try? await engine(for: pluginId) else { return [] }
        return await engine.primaryCategories()
    }

    func filterConfig(pluginId: String) async -> FilterConfig {
        guard let engine = try? await engine(for: pluginId) else { return FilterConfig() }
        return await engine.filterConfig()
    }

    // MARK: - Lists & search

    func list(pluginId: String, slug: String, filters: ListFilters, page: Int) async throws -> ListPage {
        let cacheKey = Self.listCacheKey(pluginId: pluginId, slug: slug, filters: filters, page: page)
        if let cached = cachedListPage(forKey: cacheKey) { return MetadataOverlay.merged(cached) }
        let engine = try await engine(for: pluginId)
        guard let url = await engine.urlForList(slug: slug, filtersJson: filters.jsonString(page: page)) else {
            throw MovieServiceError.noURL
        }
        let text = try await fetchPage(url)
        let parsed = await engine.parseList(text: text)
        // Metadata overlay (1.22.20): the cache stores the
        // RAW parse; the overlay merge applies at return,
        // so an overlay landing mid-session takes effect
        // from the next read on (design §5.4.3).
        storeListPage(parsed, forKey: cacheKey)
        return MetadataOverlay.merged(parsed)
    }

    func search(pluginId: String, keyword: String, page: Int) async throws -> ListPage {
        let cacheKey = "search|\(pluginId)|\(keyword)|\(page)"
        if let cached = cachedListPage(forKey: cacheKey) { return MetadataOverlay.merged(cached) }
        let engine = try await engine(for: pluginId)
        let filters = ListFilters()
        guard let url = await engine.urlForSearch(keyword: keyword, filtersJson: filters.jsonString(page: page)) else {
            throw MovieServiceError.noURL
        }
        let text = try await fetchPage(url)
        let parsed = await engine.parseSearch(text: text)
        storeListPage(parsed, forKey: cacheKey)
        return MetadataOverlay.merged(parsed)
    }

    // MARK: - Filter option lists

    func categories(pluginId: String) async -> [NameSlug] {
        guard let engine = try? await engine(for: pluginId),
              let url = await engine.urlForCategories(),
              let text = try? await Net.fetchText(url) else { return [] }
        return await engine.parseCategories(text: text)
    }

    func countries(pluginId: String) async -> [NameValue] {
        guard let engine = try? await engine(for: pluginId),
              let url = await engine.urlForCountries(),
              let text = try? await Net.fetchText(url) else { return [] }
        return await engine.parseCountries(text: text)
    }

    func years(pluginId: String) async -> [NameValue] {
        guard let engine = try? await engine(for: pluginId),
              let url = await engine.urlForYears(),
              let text = try? await Net.fetchText(url) else { return [] }
        return await engine.parseYears(text: text)
    }

    // MARK: - Detail

    struct DetailBundle {
        var detail: MovieDetail
        /// Stream parsed from the detail response itself (first-episode
        /// stream for API-style plugins; may be empty).
        var detailStream: StreamInfo
    }

    /// Stage 1 only: the detail record itself. Views render this
    /// immediately, then call `detailStreams` for the source list
    /// (v1.22 progressive detail — torrenthub's stage 2 measured
    /// +713 ms serial before anything could render).
    func detailMeta(pluginId: String, movieId: String) async throws -> DetailBundle {
        // L-T04 breadcrumb D6: bracket the first plugin call of
        // the Detail-open path (urlForDetail → fn=getUrlDetail).
        DiagLog.log("detail", "meta.begin plugin=\(pluginId) movie=\(movieId)")
        let engine = try await engine(for: pluginId)
        guard let url = await engine.urlForDetail(slug: movieId) else {
            throw MovieServiceError.noURL
        }
        DiagLog.log("detail", "meta.url plugin=\(pluginId) host=\(URL(string: url)?.host ?? "?")")
        let text = try await fetchPage(url)
        async let parsedDetail = engine.parseMovieDetail(text: text, url: url)
        async let parsedStream = engine.parseStream(text: text, url: url)
        let (detail, stream) = await (parsedDetail, parsedStream)
        guard let detail else { throw MovieServiceError.emptyDetail }
        // Metadata overlay (1.22.20): merged here, at
        // construction — detailStreams only swaps the
        // server list afterwards, so the merged display
        // fields survive stage 2 untouched (design §5.4.3).
        return DetailBundle(detail: MetadataOverlay.merged(detail), detailStream: stream)
    }

    /// Stage 2 for two-stage plugins (torrenthub): a meta payload's
    /// detail carries ONE placeholder episode whose id starts with
    /// "jtvstreams:" — swap the real server list in. Returns the
    /// detail unchanged for single-stage plugins or when stage 2
    /// fails. Any other plugin is unaffected: none emits the prefix.
    func detailStreams(pluginId: String, movieId: String, detail: MovieDetail) async -> MovieDetail {
        guard let placeholder = detail.servers.first?.episodes.first,
              placeholder.id.hasPrefix("jtvstreams:") else { return detail }
        // v1.22.2: stage 2 goes through the PLUGIN only — the exact
        // v1.21 path. The v1.22 native debrid-configured Torrentio
        // fetch (jtvts: episodes + resolve-link chase) was removed
        // in the same restoration as the DebridResolver chain: it
        // was never device-proven, while the plugin path was.
        guard let engine = try? await engine(for: pluginId),
              let stage2URL = await engine.urlForDetail(slug: placeholder.id),
              let stage2Text = try? await Net.fetchText(stage2URL),
              let stage2 = await engine.parseMovieDetail(text: stage2Text, url: stage2URL),
              !stage2.servers.isEmpty else { return detail }
        var resolved = detail
        resolved.servers = stage2.servers
        // L-T13 §5.0 (1.3.1): count breadcrumb around the
        // MediaFusion merge ONLY — servers/episodes before and
        // after, so the next device log can convict the Lane B
        // counts. mergeMediaFusion's behaviour is NOT changed.
        let beforeServers = resolved.servers.count
        let beforeEpisodes = resolved.servers.reduce(0) { $0 + $1.episodes.count }
        let merged = await mergeMediaFusion(pluginId: pluginId, movieId: movieId, detail: resolved)
        let afterEpisodes = merged.servers.reduce(0) { $0 + $1.episodes.count }
        DiagLog.log("detail", "stage2.counts plugin=\(pluginId) servers=\(beforeServers)->\(merged.servers.count) episodes=\(beforeEpisodes)->\(afterEpisodes)")
        return merged
    }

    /// v1.22.5: MediaFusion merge (owner request — the same
    /// second torrent gateway the Sony app runs beside
    /// Torrentio). When the owner has pasted his MediaFusion
    /// manifest URL in Settings, a torrenthub detail for an
    /// IMDb-id title gains a "MediaFusion" server: MediaFusion
    /// answers with direct per-provider links (its responses
    /// carry no infoHash), quality-sorted like the plugin's own
    /// list. Strictly additive — no URL configured, a failed
    /// fetch, or an empty answer leaves the detail exactly as
    /// the plugin made it. The manifest URL is a bearer
    /// credential: it lives only in UserDefaults, never logged.
    func mergeMediaFusion(pluginId: String, movieId: String, detail: MovieDetail) async -> MovieDetail {
        guard pluginId == "torrenthub", movieId.hasPrefix("tt") else { return detail }
        // The manifest URL is a bearer credential: the log only
        // ever learns whether one is configured (DiagLog law).
        DiagLog.log("mediafusion", "configured=\(MediaFusion.baseURL != nil ? "yes" : "no")")
        guard let base = MediaFusion.baseURL else { return detail }
        let url = "\(base)/stream/movie/\(movieId).json"
        // v1.22.15 (B-2, H-9): was `try?` — a failed fetch was
        // silent. Identical return on failure; the catch logs
        // the error kind only (domain#code, DiagLog law).
        let text: String
        do {
            text = try await Net.fetchText(url)
        } catch {
            DiagLog.log("mediafusion", "fetch failed kind=\((error as NSError).domain)#\((error as NSError).code)")
            return detail
        }
        let episodes = MediaFusion.parseStreams(text: text)
        guard !episodes.isEmpty else {
            DiagLog.log("mediafusion", "streams=0 parse-empty")
            return detail
        }
        DiagLog.log("mediafusion", "merged streams=\(episodes.count)")
        var merged = detail
        merged.servers.append(EpisodeServer(name: "MediaFusion", episodes: episodes))
        return merged
    }

    func detail(pluginId: String, movieId: String) async throws -> DetailBundle {
        var bundle = try await detailMeta(pluginId: pluginId, movieId: movieId)
        bundle.detail = await detailStreams(pluginId: pluginId, movieId: movieId, detail: bundle.detail)
        return bundle
    }

    // MARK: - Embed prefetch (v1.22)

    /// One-shot cache for a dwell-prefetched EMBED resolution:
    /// for the sources whose chains end in the sniffing webview
    /// (123av, javhd, avdbapi), the chain itself (watch page →
    /// hops → embed page) is seconds of serial fetches that used
    /// to start at the play tap. The detail screen warms it while
    /// the user reads; the tap then consumes it. Only .embed
    /// outcomes are cached — a prefetched video URL could age,
    /// and the embed outcome is just a page URL + headers.
    private var prefetchedEmbeds: [String: (resolution: PlaybackResolution, at: Date)] = [:]
    private let prefetchLock = NSLock()

    /// L-T11 (2) in-flight dedupe (tvOS-only divergence, 1.3.0):
    /// the Detail embed warm and a Play tap for the SAME
    /// plugin+episode used to run two full resolve chains
    /// concurrently and produce two different playlists. The
    /// warm's task is registered here while it runs; a tap's
    /// resolveEpisode JOINS that task instead of starting a
    /// second chain (see the join step in resolveEpisode). The
    /// embed-chain fetch mechanics are unchanged — only the
    /// duplicate concurrent run is removed.
    private var inFlightPrefetch: [String: (token: UUID, task: Task<PlaybackResolution, Error>)] = [:]

    func prefetchEmbedResolution(_ request: PlaybackRequest) {
        let key = request.pluginId + "|" + request.episode.id
        let token = UUID()
        let task = Task<PlaybackResolution, Error> {
            try await self.resolveEpisode(request, joiningPrefetch: false)
        }
        // Gate fix pass (Round 1 on R2, Lens 2 F5b): a
        // superseded warm task is CANCELLED when its registry
        // entry is overwritten — never orphaned to run to
        // completion (and possibly race the newer chain). The
        // token-keyed watcher below already refuses to let the
        // old task evict the newer entry on its way out.
        if let superseded = inFlightPrefetch[key], superseded.token != token {
            superseded.task.cancel()
        }
        inFlightPrefetch[key] = (token, task)
        Task {
            defer {
                if inFlightPrefetch[key]?.token == token { inFlightPrefetch[key] = nil }
            }
            // L-16: the warm's outcome is logged — a failed
            // warm used to vanish into `try?`, leaving the
            // play tap's cold re-run of the same chain
            // unexplained in the log.
            do {
                let resolution = try await task.value
                guard case .embed = resolution else {
                    DiagLog.log("prefetch", "warm outcome=discarded-non-embed plugin=\(request.pluginId)")
                    return
                }
                prefetchLock.withLock { prefetchedEmbeds[key] = (resolution, Date()) }
                DiagLog.log("prefetch", "warm outcome=cached plugin=\(request.pluginId)")
            } catch {
                DiagLog.log("prefetch", "warm outcome=failed plugin=\(request.pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
            }
        }
    }

    /// Cancellation-responsive join of an in-flight pre-resolve
    /// (Lens 2 F5a): races the warm task's completion against
    /// THIS caller's cancellation via withTaskCancellationHandler
    /// — on cancel, the box resumes with nil at once and the
    /// caller stops waiting (its caller-side Task.isCancelled
    /// check then throws CancellationError). The warm task is
    /// deliberately NOT cancelled: it is registry-owned and its
    /// watcher may still cache the outcome for a later tap.
    private static func joinInFlightPrefetch(
        _ task: Task<PlaybackResolution, Error>
    ) async -> PlaybackResolution? {
        let box = PrefetchJoinBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PlaybackResolution?, Never>) in
                box.setContinuation(continuation)
                Task {
                    let result = try? await task.value
                    box.resume(with: result)
                }
            }
        } onCancel: {
            box.resume(with: nil)
        }
    }

    private func consumePrefetchedEmbed(pluginId: String, target: String) -> PlaybackResolution? {
        let key = pluginId + "|" + target
        prefetchLock.lock()
        let hit = prefetchedEmbeds.removeValue(forKey: key)
        prefetchLock.unlock()
        guard let hit, Date().timeIntervalSince(hit.at) < 120 else { return nil }
        return hit.resolution
    }

    // MARK: - Playback resolution

    /// Resolves an episode tap following the plugin episode semantics:
    /// direct media -> native player; manga chapter API -> images;
    /// embed page -> plugin embed/detail parser, else webview sniffer.
    func resolveEpisode(_ request: PlaybackRequest, onDebridPhase: (@Sendable (DebridPhaseEvent) -> Void)? = nil) async throws -> PlaybackResolution {
        try await resolveEpisode(request, joiningPrefetch: true, onDebridPhase: onDebridPhase)
    }

    /// L-T12 (1.3.1) PROBE-ONLY façade for the Detail backdrop
    /// preview (DIAG-131-PREVIEW §6.2). ADDITIVE: it runs the
    /// SAME resolve machinery as `resolveEpisode` — the
    /// existing fetch/link chain is reused as-is and no existing
    /// function's behaviour changes — under three hard
    /// constraints:
    /// - it NEVER reaches `DebridResolver.resolve`: a
    ///   `jtvhash:` target is refused outright (the caller
    ///   routes hashes to `resolveCachedOnly` itself);
    /// - it NEVER consumes the Play tap's single-consumer
    ///   prefetched embed (the private chain's probeOnly flag
    ///   skips exactly that one step, on this path only);
    /// - for the prefetch-warm plugins (123av / javhd /
    ///   avdbapi) it may only JOIN an in-flight warm (the join
    ///   is non-consuming for the joiner); with no warm in
    ///   flight it returns nil rather than burning a fresh
    ///   chain — the 1.3.0 protection, kept for exactly the
    ///   plugins it was written for.
    /// Bounded at 6 s (Play's measured chains are 0.55–0.85 s;
    /// the budget protects the backdrop, not the resolver) and
    /// cancellation-responsive, both via the structured task
    /// group inside (F-B1 gate fix: the group cancels the
    /// in-flight chain, not just the wait).
    /// Returns nil on refusal / timeout / cancellation / error;
    /// the caller logs the per-rung outcome.
    func resolveEpisodeForPreview(_ request: PlaybackRequest) async -> PlaybackResolution? {
        let target = request.episode.id
        if target.hasPrefix("jtvhash:") {
            DiagLog.log("preview", "probe facade outcome=refused-hash plugin=\(request.pluginId)")
            return nil
        }
        if request.isManga {
            DiagLog.log("preview", "probe facade outcome=refused-manga plugin=\(request.pluginId)")
            return nil
        }
        if ["123av", "javhd", "avdbapi"].contains(request.pluginId) {
            let key = request.pluginId + "|" + target
            guard let inFlight = inFlightPrefetch[key] else {
                DiagLog.log("preview", "probe facade outcome=embed-unpreviewable plugin=\(request.pluginId)")
                return nil
            }
            DiagLog.log("preview", "probe facade outcome=join-warm plugin=\(request.pluginId)")
            if let shared = await Self.joinInFlightPrefetch(inFlight.task) {
                return shared
            }
            if Task.isCancelled { return nil }
            DiagLog.log("preview", "probe facade outcome=warm-failed plugin=\(request.pluginId)")
            return nil
        }
        // Gate fix pass (F-B1): REAL cancellation propagation.
        // The probe runs as a structured task group: the worker
        // child runs the resolve chain and the budget child
        // sleeps 6 s; whichever finishes first wins, and
        // `group.cancelAll()` then cancels the loser — the
        // worker included. Cancelling the CALLER's task cancels
        // the group (structured concurrency propagates the
        // cancellation into both children), so the chain's own
        // cooperative checks (Net fetches, Task.isCancelled
        // gates) actually fire. The previous shape resumed a
        // continuation with nil from onCancel while two
        // unstructured, handle-less Tasks ran the chain to its
        // natural end behind the caller.
        return await withTaskGroup(of: PlaybackResolution?.self) { group in
            group.addTask {
                try? await self.resolveEpisode(request, joiningPrefetch: true, probeOnly: true)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
    }

    private func resolveEpisode(_ request: PlaybackRequest, joiningPrefetch: Bool, probeOnly: Bool = false, onDebridPhase: (@Sendable (DebridPhaseEvent) -> Void)? = nil) async throws -> PlaybackResolution {
        // v1.22.15 (B-4): register the MediaFusion credential host
        // with the logger BEFORE any line below can carry an MF
        // stream URL through urlForLog. A persisted MF episode can
        // be resumed on a cold launch without mergeMediaFusion ever
        // running in this session (DetailView stage-2 early return),
        // so the getter's registration side effect cannot be relied
        // on having happened. Reading baseURL performs it.
        _ = MediaFusion.baseURL
        // v1.22.15 (B-5, N-12): exactly one chain-duration line
        // per resolve, emitted by the defer on every exit —
        // success and throw alike. No other change here.
        let chainStart = Date()
        let pluginId = request.pluginId
        // L-16 (1.3.6): the duration line also carries the
        // chain's terminal outcome — a resolve that died on a
        // thrown hop fetch used to leave NOTHING after its
        // start line (the 123av silent death, L-16). Every
        // exit below records its outcome in chainOutcome; the
        // default is a canary — if it ever reaches a log, an
        // exit was missed.
        var chainOutcome = "error kind=unannotated"
        defer { DiagLog.log("resolve", "duration plugin=\(pluginId) ms=\(Int(Date().timeIntervalSince(chainStart) * 1000)) outcome=\(chainOutcome)") }
        let target = request.episode.id
        guard !target.isEmpty else {
            DiagLog.log("resolve", "error plugin=\(pluginId) empty target")
            chainOutcome = "error kind=unresolvedEpisode"
            throw MovieServiceError.unresolvedEpisode
        }
        guard !target.hasPrefix("jtvstreams:") else {
            // L-23 (1.22.20/1.3.8): a torrenthub stage-1
            // placeholder id is a detail-stage marker, never a
            // resolvable target — refuse it here, labelled,
            // instead of letting the embed chain hand the
            // pseudo-scheme to the fetcher, where it dies as
            // -1002 after the ~1 s retry loop. The play
            // intents heal the placeholder before a request
            // is built; this guard is defence in depth for
            // any future path that leaks one through.
            DiagLog.log("resolve", "error plugin=\(pluginId) kind=placeholderTarget")
            chainOutcome = "error kind=placeholderTarget"
            throw MovieServiceError.unresolvedEpisode
        }
        // Log the target KIND and its redacted shape only — a
        // signed stream URL never enters the log (DiagLog law).
        let targetKind = target.hasPrefix("jtvhash:") ? "hash"
            : request.isManga ? "manga"
            : MediaURL.isDirectMedia(target) ? "direct" : "embed"
        DiagLog.log("resolve", "start plugin=\(pluginId) kind=\(targetKind) target=\(DiagLog.urlForLog(target))")

        // L-T12: the preview probe NEVER consumes the
        // single-consumer prefetched embed — that step is
        // skipped on the probeOnly path only; Play's path
        // (probeOnly == false) is byte-for-byte unchanged.
        if !probeOnly, let prefetched = consumePrefetchedEmbed(pluginId: pluginId, target: target) {
            DiagLog.log("resolve", "route=embed via=prefetched")
            chainOutcome = "embed"
            return prefetched
        }

        // L-T11 (2) in-flight dedupe (tvOS-only divergence,
        // 1.3.0): a Play tap that lands while Detail's embed
        // warm for the same plugin+episode is still running
        // awaits THAT chain instead of starting a second one.
        // The shared outcome is the chain's own fresh result
        // (embed outcomes are additionally cached by the warm's
        // watcher, exactly as before). A failed warm falls
        // through to this call's own chain, unchanged.
        if joiningPrefetch,
           let inFlight = inFlightPrefetch[pluginId + "|" + target] {
            DiagLog.log("resolve", "join in-flight pre-resolve plugin=\(pluginId)")
            // Gate fix pass (Round 1 on R2, Lens 2 F5a): the
            // join is CANCELLATION-RESPONSIVE — a plain
            // `try? await inFlight.task.value` kept a cancelled
            // caller (attempt superseded, cover dismissed)
            // suspended until the warm chain finished on its
            // own schedule. joinInFlightPrefetch races the
            // warm's completion against this caller's
            // cancellation; a cancelled caller stops waiting at
            // once and throws CancellationError instead of
            // falling through to a second chain. The warm task
            // itself is NOT cancelled — it belongs to the
            // registry, and its watcher may still cache an
            // embed outcome.
            if let shared = await Self.joinInFlightPrefetch(inFlight.task) {
                chainOutcome = Self.chainOutcomeLabel(shared)
                return shared
            }
            if Task.isCancelled {
                chainOutcome = "error kind=cancelled"
                throw CancellationError()
            }
        }

        // Fast resume: a previously resolved direct stream.
        // (Skipped for torrenthub: debrid download links expire,
        // and re-minting one from the hash is cheap when cached.)
        if pluginId != "torrenthub", !request.knownStreamURL.isEmpty && MediaURL.isDirectMedia(request.knownStreamURL) {
            var headers = request.fallbackHeaders
            if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
            let stream = await markProxyIfNeeded(StreamInfo(url: request.knownStreamURL, headers: headers), pluginId: pluginId)
            if let fallback = await streamxxPlayerFallback(url: stream.url, headers: stream.headers) {
                chainOutcome = "embed"
                return fallback
            }
            DiagLog.log("resolve", "route=video engine=\(stream.useCompatEngine ? "ksplayer" : "avplayer") via=fast-resume url=\(DiagLog.urlForLog(stream.url))")
            chainOutcome = "video"
            return .video(stream)
        }

        // Debrid torrent target (torrenthub): the episode id is an
        // info-hash, not a URL — the native debrid resolver turns
        // it into a direct file link (Real-Debrid → TorBox →
        // Premiumize), flagging containers AVPlayer cannot open
        // for the KSPlayer surface.
        if target.hasPrefix("jtvhash:") {
            // L-T12: the preview probe must never start a
            // server-side download — the façade refuses hash
            // targets before this point; this is the private
            // chain's own backstop for the same rule.
            if probeOnly {
                DiagLog.log("resolve", "route=debrid outcome=refused-probe-only")
                chainOutcome = "error kind=unresolvedEpisode"
                throw MovieServiceError.unresolvedEpisode
            }
            let hash = String(target.dropFirst("jtvhash:".count))
            DiagLog.log("resolve", "route=debrid")
            do {
                let stream = try await DebridResolver.resolve(hash: hash, onPhase: onDebridPhase)
                chainOutcome = "video"
                return .video(stream)
            } catch {
                chainOutcome = "error kind=\((error as NSError).domain)#\((error as NSError).code)"
                throw error
            }
        }

        // Direct media target.
        if MediaURL.isDirectMedia(target) {
            var headers = request.fallbackHeaders
            if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
            let stream = await markProxyIfNeeded(StreamInfo(url: target, headers: headers), pluginId: pluginId)
            if let fallback = await streamxxPlayerFallback(url: stream.url, headers: stream.headers) {
                chainOutcome = "embed"
                return fallback
            }
            DiagLog.log("resolve", "route=video engine=\(stream.useCompatEngine ? "ksplayer" : "avplayer") via=direct url=\(DiagLog.urlForLog(stream.url))")
            chainOutcome = "video"
            return .video(stream)
        }

        guard let engine = try? await engine(for: pluginId) else {
            DiagLog.log("resolve", "error plugin=\(pluginId) plugin unavailable")
            chainOutcome = "error kind=pluginUnavailable"
            throw MovieServiceError.pluginUnavailable
        }

        // Manga chapter: fetch the chapter API and parse its image list.
        if request.isManga {
            let text: String
            do {
                text = try await Net.fetchText(target)
            } catch {
                chainOutcome = "error kind=\((error as NSError).domain)#\((error as NSError).code)"
                throw error
            }
            let stream = await engine.parseStream(text: text, url: target)
            if !stream.images.isEmpty {
                var resolved = stream
                if resolved.headers.isEmpty { resolved.headers = await defaultHeaders(for: pluginId) }
                DiagLog.log("resolve", "route=manga images=\(resolved.images.count)")
                chainOutcome = "manga"
                return .manga(resolved)
            }
            DiagLog.log("resolve", "error plugin=\(pluginId) manga chapter had no images")
            chainOutcome = "error kind=unresolvedEpisode"
            throw MovieServiceError.unresolvedEpisode
        }

        // NEXT-C C1 (tvOS-only divergence, 1.3.0): torrenthub
        // non-hash http(s) targets that are media by container —
        // or that live on the registered MediaFusion credential
        // host — route DIRECTLY to .video here, immediately
        // before the embed chain. On iOS these shapes are
        // covered by the WKWebView sniffer; tvOS has no webview,
        // and torrenthub's playback parsers return empty by
        // design, so the embed chain could only end at the
        // last-resort .embed error slate. The MediaFusion URL is
        // a bearer credential: this route logs kind + host ONLY,
        // never the raw episode id or URL.
        if pluginId == "torrenthub",
           target.hasPrefix("http://") || target.hasPrefix("https://"),
           let targetURL = URL(string: target) {
            let ext = targetURL.pathExtension.lowercased()
            let videoContainers: Set<String> = ["mkv", "avi", "wmv", "flv", "webm", "m2ts",
                                                "mp4", "m4v", "mov", "m3u8", "mpd", "ts"]
            let mfHost = MediaFusion.baseURL.flatMap { URL(string: $0)?.host }
            let isMFHost = mfHost != nil && targetURL.host == mfHost
            if videoContainers.contains(ext) || isMFHost {
                var headers = request.fallbackHeaders
                if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
                // useCompatEngine by DebridResolver's extension
                // rule (friendly = mp4/m4v/mov); HLS/DASH
                // playlists are AVPlayer-native, so the two
                // playlist extensions are exempted from the
                // rule's non-friendly verdict. The rule receives
                // the URL's PATH (no query string — review-gate
                // fix, 1.3.0), consistent with the container
                // classification above: a signed friendly file
                // must not be misflagged compat by its query.
                let compat = DebridResolver.needsCompatEngine(filename: targetURL.path)
                    && ext != "m3u8" && ext != "mpd"
                let raw = StreamInfo(url: target, headers: headers, useCompatEngine: compat)
                let stream = await markProxyIfNeeded(raw, pluginId: pluginId)
                DiagLog.log("resolve", "route=video via=torrent-direct kind=\(isMFHost ? "mediafusion" : "container") host=\(targetURL.host ?? "?") engine=\(stream.useCompatEngine ? "ksplayer" : "avplayer")")
                chainOutcome = "video"
                return .video(stream)
            }
        }

        // Embed chain: plugins resolve in hops — a parser returns
        // isEmbed=true plus the NEXT url (njav: watch page → /jm/ →
        // player page → signed m3u8; vlxx: a POST config; sextop1:
        // a player-API config). Follow the chain like the reference
        // resolver does: fetch each hop (POST when the config carries
        // a postBody) and re-parse, until a hop yields a direct
        // stream (isEmbed=false), an image set, or the chain runs
        // out. The old single-pass code handed the first hop's page
        // URL to AVPlayer, which failed instantly.
        var currentURL = target
        var currentHeaders = await defaultHeaders(for: pluginId)
        var payload: String
        do {
            payload = try await Net.fetchText(currentURL, headers: currentHeaders)
        } catch {
            // L-16: hop 0 (the target page itself) — the
            // same record as the in-loop hop failures below.
            DiagLog.log("resolve", "hop failed plugin=\(pluginId) hop=0 host=\(URL(string: currentURL)?.host ?? "?") err=\((error as NSError).domain)#\((error as NSError).code)")
            chainOutcome = "error kind=\((error as NSError).domain)#\((error as NSError).code)"
            throw error
        }
        var lastEmbedURL = target
        // Embed-chain parse budget: 4 by default (the historical
        // bound). A plugin may declare a larger need in its
        // manifest (maxChainParses — hentaihub's watch-started
        // chain needs 5); the declaration can only raise the
        // bound, never lower it, and is capped so a bad value
        // cannot stall resolution in serial fetches.
        let declaredParses = await manifest(for: pluginId)?.maxChainParses ?? 0
        let parseBudget = min(max(declaredParses, 4), 8)
        if parseBudget != 4 {
            DiagLog.log("resolve", "budget plugin=\(pluginId) parses=\(parseBudget)")
        }
        for hopIndex in 0..<parseBudget {
            var step = await engine.parseEmbed(html: payload, url: currentURL)
            if step == nil || step?.hasPlayableURL != true {
                let parsed = await engine.parseStream(text: payload, url: currentURL)
                if parsed.hasPlayableURL || !parsed.images.isEmpty { step = parsed }
            }
            guard let step, step.hasPlayableURL || !step.images.isEmpty else { break }
            if !step.images.isEmpty {
                var resolved = step
                if resolved.headers.isEmpty { resolved.headers = currentHeaders }
                DiagLog.log("resolve", "route=manga via=embed-chain images=\(resolved.images.count)")
                chainOutcome = "manga"
                return .manga(resolved)
            }
            if !step.isEmbed || MediaURL.isDirectMedia(step.url) {
                // A web page is never a video: some plugins finish
                // their chain at an embed page marked isEmbed=false
                // (javhd → cloudwish /e/…). AVPlayer fails on those
                // instantly; the sniffing webview is the right home.
                if !MediaURL.isDirectMedia(step.url), Self.looksLikeWebPage(step.url),
                   let pageURL = URL(string: step.url) {
                    var pageHeaders = step.headers
                    if pageHeaders.isEmpty { pageHeaders = currentHeaders }
                    DiagLog.log("resolve", "route=embed via=webpage url=\(DiagLog.urlForLog(step.url))")
                    chainOutcome = "embed"
                    return .embed(url: pageURL, headers: pageHeaders, sniffMedia: true)
                }
                var resolved = step
                if resolved.headers.isEmpty { resolved.headers = currentHeaders }
                let stream = await markProxyIfNeeded(resolved, pluginId: pluginId)
                if let fallback = await streamxxPlayerFallback(url: stream.url, headers: stream.headers) {
                    chainOutcome = "embed"
                    return fallback
                }
                DiagLog.log("resolve", "route=video engine=\(stream.useCompatEngine ? "ksplayer" : "avplayer") via=embed-chain url=\(DiagLog.urlForLog(stream.url))")
                chainOutcome = "video"
                return .video(stream)
            }
            // Self-embed (123av's shape): the parser points back at
            // the very page we already fetched. Refetching it changes
            // nothing — hand it to the sniffing webview now, keeping
            // the plugin's step headers for the page load.
            if step.url == currentURL, let pageURL = URL(string: step.url) {
                var pageHeaders = step.headers
                if pageHeaders.isEmpty { pageHeaders = currentHeaders }
                DiagLog.log("resolve", "route=embed via=self-embed url=\(DiagLog.urlForLog(step.url))")
                chainOutcome = "embed"
                return .embed(url: pageURL, headers: pageHeaders, sniffMedia: true)
            }
            // Follow the hop.
            lastEmbedURL = step.url
            currentURL = step.url
            if !step.headers.isEmpty {
                currentHeaders = (await defaultHeaders(for: pluginId)).merging(step.headers) { _, new in new }
            }
            do {
                if let body = step.postBody, !body.isEmpty {
                    payload = try await Net.fetchTextPOST(currentURL, body: body, headers: currentHeaders)
                } else {
                    payload = try await Net.fetchText(currentURL, headers: currentHeaders)
                }
            } catch {
                // L-16: a hop fetch that throws used to kill
                // the chain without a trace — record the hop
                // (host + error kind only, never the URL)
                // before the rethrow. The HTTP status rides
                // the Net per-attempt lines beside this one.
                DiagLog.log("resolve", "hop failed plugin=\(pluginId) hop=\(hopIndex + 1) host=\(URL(string: currentURL)?.host ?? "?") err=\((error as NSError).domain)#\((error as NSError).code)")
                chainOutcome = "error kind=\((error as NSError).domain)#\((error as NSError).code)"
                throw error
            }
        }

        // Last resort: open the embed in the sniffing webview.
        guard let url = URL(string: lastEmbedURL) else {
            DiagLog.log("resolve", "error plugin=\(pluginId) unresolved episode")
            chainOutcome = "error kind=unresolvedEpisode"
            throw MovieServiceError.unresolvedEpisode
        }
        DiagLog.log("resolve", "route=embed via=last-resort url=\(DiagLog.urlForLog(lastEmbedURL))")
        chainOutcome = "embed"
        return .embed(url: url, headers: await defaultHeaders(for: pluginId), sniffMedia: true)
    }

    // MARK: - Source-rescue fallback (spec §2, 1.3.6)

    private static func fallbackMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// The outcome of the primary attempt, kept for the
    /// terminal-error rule (§2.5) once every hop has failed.
    private enum PrimaryFailure {
        case refused(status: Int)
        case notFound
        case unreachable(String)
        case emptyURL
        case thrown(Error)
    }

    private struct PreflightWalk {
        var verdict: PreflightVerdict
        var stream: StreamInfo
    }

    private struct HopServed {
        var resolution: PlaybackResolution
        var request: PlaybackRequest
    }

    private struct HopOutcome {
        var label: String
        var served: HopServed?
    }

    /// Pre-flight walk (§3.1/§3.2): candidates are the stream's
    /// own URL plus its ranked alternates, de-duplicated, in
    /// order; the first `.ok` wins and substitutes the stream
    /// URL. All candidates failing returns the LAST decided
    /// candidate's verdict. A `.skipped` verdict fails only
    /// its own candidate — it never aborts the walk and never
    /// pardons an earlier candidate's refusal; the walk as a
    /// whole is `.skipped` (stream returned untouched, nothing
    /// triggered) only when EVERY candidate is skipped.
    private func preflightWalk(pluginId: String, stream: StreamInfo) async -> PreflightWalk {
        if stream.requiresProxy || stream.isEmbed {
            DiagLog.log("preflight", "plugin=\(pluginId) host=\(URL(string: stream.url)?.host ?? "?") outcome=skipped status=- ms=0")
            return PreflightWalk(verdict: .skipped, stream: stream)
        }
        var candidates: [String] = []
        var seen = Set<String>()
        for candidate in [stream.url] + stream.alternateURLs {
            if seen.insert(candidate).inserted { candidates.append(candidate) }
        }
        var lastVerdict: PreflightVerdict = .skipped
        for (index, candidate) in candidates.enumerated() {
            // Cancellation (gate fix, L-26 round): a superseded
            // walk stops between candidates instead of spending
            // the remaining checks against a dead budget; the
            // in-flight check stays bounded by StreamPreflight's
            // own 4 s expire.
            if Task.isCancelled { break }
            let checkStart = Date()
            let verdict = await StreamPreflight.check(url: candidate, headers: stream.headers)
            let ms = Self.fallbackMs(since: checkStart)
            let outcomeLabel: String
            let statusLabel: String
            switch verdict {
            case .ok(let status, _):
                outcomeLabel = "ok"; statusLabel = "\(status)"
            case .refused(let status):
                outcomeLabel = "refused"; statusLabel = "\(status)"
            case .notFound:
                outcomeLabel = "not-found"; statusLabel = "-"
            case .unreachable:
                outcomeLabel = "unreachable"; statusLabel = "-"
            case .skipped:
                outcomeLabel = "skipped"; statusLabel = "-"
            }
            if candidates.count > 1 {
                DiagLog.log("preflight", "candidate=\(index + 1)/\(candidates.count) plugin=\(pluginId) host=\(URL(string: candidate)?.host ?? "?") outcome=\(outcomeLabel) status=\(statusLabel) ms=\(ms)")
            } else {
                DiagLog.log("preflight", "plugin=\(pluginId) host=\(URL(string: candidate)?.host ?? "?") outcome=\(outcomeLabel) status=\(statusLabel) ms=\(ms)")
            }
            if verdict == .skipped {
                // §3.2 (gate fix m-1/F-A6): a skipped candidate
                // fails that candidate only — the walk
                // continues and an earlier decided verdict
                // stands. lastVerdict keeps its initial
                // .skipped, so an all-skipped walk still
                // returns .skipped below.
                continue
            }
            if case .ok = verdict {
                var winning = stream
                if candidate != stream.url { winning.url = candidate }
                return PreflightWalk(verdict: verdict, stream: winning)
            }
            lastVerdict = verdict
        }
        return PreflightWalk(verdict: lastVerdict, stream: stream)
    }

    /// Resolves an episode, falling back across sources by base
    /// catalogue code when the origin plugin fails (§2.4).
    /// `resolveEpisode` itself is untouched by this path: every
    /// existing caller keeps byte-identical behaviour.
    func resolveWithFallback(_ request: PlaybackRequest) async throws -> FallbackOutcome {
        let origin = request.pluginId
        let started = Date()
        let code = BaseCode.extract(from: request)
        DiagLog.log("fallback", "begin plugin=\(origin) code=\(code ?? "none")")
        let primaryStart = Date()
        var primaryFailure: PrimaryFailure?
        do {
            let resolution = try await resolveEpisode(request)
            switch resolution {
            case .embed, .manga:
                DiagLog.log("fallback", "primary plugin=\(origin) outcome=played ms=\(Self.fallbackMs(since: primaryStart))")
                return FallbackOutcome(resolution: resolution, servedRequest: request, didFallback: false)
            case .video(let stream):
                if !stream.hasPlayableURL {
                    DiagLog.log("fallback", "primary plugin=\(origin) outcome=empty-url ms=\(Self.fallbackMs(since: primaryStart))")
                    primaryFailure = .emptyURL
                } else if FallbackCatalog.preflightSet.contains(origin) {
                    let walk = await preflightWalk(pluginId: origin, stream: stream)
                    switch walk.verdict {
                    case .ok, .skipped:
                        DiagLog.log("fallback", "primary plugin=\(origin) outcome=played ms=\(Self.fallbackMs(since: primaryStart))")
                        return FallbackOutcome(resolution: .video(walk.stream), servedRequest: request, didFallback: false)
                    case .refused(let status):
                        DiagLog.log("fallback", "primary plugin=\(origin) outcome=refused status=\(status) ms=\(Self.fallbackMs(since: primaryStart))")
                        primaryFailure = .refused(status: status)
                    case .notFound:
                        DiagLog.log("fallback", "primary plugin=\(origin) outcome=not-found ms=\(Self.fallbackMs(since: primaryStart))")
                        primaryFailure = .notFound
                    case .unreachable(let detail):
                        DiagLog.log("fallback", "primary plugin=\(origin) outcome=unreachable \(detail) ms=\(Self.fallbackMs(since: primaryStart))")
                        primaryFailure = .unreachable(detail)
                    }
                } else {
                    DiagLog.log("fallback", "primary plugin=\(origin) outcome=played ms=\(Self.fallbackMs(since: primaryStart))")
                    return FallbackOutcome(resolution: resolution, servedRequest: request, didFallback: false)
                }
            }
        } catch {
            let nsError = error as NSError
            DiagLog.log("fallback", "primary plugin=\(origin) outcome=error \(nsError.domain)#\(nsError.code) ms=\(Self.fallbackMs(since: primaryStart))")
            primaryFailure = .thrown(error)
        }

        // §2.5 (gate fix F-A4/M-2): the 60 s ceiling is the
        // HOPS budget — it is anchored HERE, where the
        // primary attempt has concluded, so a slow primary
        // never charges against it (the shell deadlines are
        // sized primary + hops). `started` above remains the
        // whole-chain anchor for the `served … total-ms` line.
        let hopsStarted = Date()

        guard let failure = primaryFailure else {
            // Every non-returning path above sets a failure;
            // this guard only keeps the flow total.
            throw MovieServiceError.unresolvedEpisode
        }
        guard let code else {
            let terminal = await fallbackTerminalError(for: failure, origin: origin, request: request)
            throw terminal
        }
        for target in FallbackCatalog.targets(for: origin) {
            if Date().timeIntervalSince(hopsStarted) > 60 { break }
            if Task.isCancelled { throw CancellationError() }
            let hopStart = Date()
            let hop = await runFallbackHop(target: target, code: code, origin: request)
            DiagLog.log("fallback", "hop plugin=\(target) code=\(code) outcome=\(hop.label) ms=\(Self.fallbackMs(since: hopStart))")
            if let served = hop.served {
                DiagLog.log("fallback", "served plugin=\(target) code=\(code) total-ms=\(Self.fallbackMs(since: started))")
                return FallbackOutcome(resolution: served.resolution, servedRequest: served.request, didFallback: true)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        let terminal = await fallbackTerminalError(for: failure, origin: origin, request: request)
        throw terminal
    }

    /// Terminal-error rule (§2.5): a primary pre-flight refusal
    /// names the origin source; a primary throw is rethrown
    /// unchanged (1.22.19 amendment below aside); every other
    /// primary failure keeps the existing unresolved-episode
    /// copy.
    private func fallbackTerminalError(for failure: PrimaryFailure, origin: String, request: PlaybackRequest) async -> Error {
        switch failure {
        case .refused(let status):
            let name = await manifest(for: origin)?.name ?? request.pluginName
            return MovieServiceError.sourceRefused(pluginName: name, status: status)
        case .thrown(let error):
            // 1.22.19 (L-18, §2.5 amendment): a primary that
            // died on a SERVER-SIDE error — the transport's
            // badServerResponse shape (NSURLError -1011, an
            // HTTP error status surfaced as a thrown error;
            // the 123av hop server's 404 is the convicted
            // case) — takes the §1B refused copy once the
            // chain is exhausted, instead of Apple's raw
            // error text reaching the user. The thrown error
            // carries no HTTP status, so the refusal status
            // is nil; the technical detail stays on the log
            // line (§2.7 unchanged). Every other thrown
            // error keeps §2.5's rethrow-unchanged. The
            // detection idiom is the one PluginManager
            // already ships for the same error shape.
            if (error as? URLError)?.code == .badServerResponse {
                let name = await manifest(for: origin)?.name ?? request.pluginName
                let nsError = error as NSError
                DiagLog.log("fallback", "terminal outcome=source-refused reason=primary-server-error kind=\(nsError.domain)#\(nsError.code)")
                return MovieServiceError.sourceRefused(pluginName: name, status: nil)
            }
            return error
        case .notFound, .unreachable, .emptyURL:
            return MovieServiceError.unresolvedEpisode
        }
    }

    /// One fallback hop under its 20 s ceiling (§2.5), enforced
    /// with the task-group race idiom the resolver screen uses
    /// for its 45 s deadline: the hop work races a sleep that
    /// throws `timedOut`; the loser is cancelled.
    private func runFallbackHop(target: String, code: String, origin: PlaybackRequest) async -> HopOutcome {
        do {
            return try await withThrowingTaskGroup(of: HopOutcome.self) { group in
                group.addTask { await self.performFallbackHop(target: target, code: code, origin: origin) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw MovieServiceError.timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            // §2.7 (gate fix m-2): the ceiling's own timeout
            // is a distinguishable outcome inside the hop
            // vocabulary (`error timeout`), not a bridged
            // NSError indistinguishable from a genuine hop
            // error.
            if let serviceError = error as? MovieServiceError,
               case .timedOut = serviceError {
                return HopOutcome(label: "error timeout", served: nil)
            }
            let nsError = error as NSError
            return HopOutcome(label: "error \(nsError.domain)#\(nsError.code)", served: nil)
        }
    }

    /// The hop itself (§2.4 steps a–d): ONE search call for the
    /// base code, the first exact code match, its detail via
    /// the same two calls Detail makes, and a resolve of the
    /// hop request built through Detail's population path.
    /// Never throws — every failure is an outcome label.
    private func performFallbackHop(target: String, code: String, origin: PlaybackRequest) async -> HopOutcome {
        do {
            let page = try await search(pluginId: target, keyword: code, page: 1)
            guard let match = page.items.first(where: { BaseCode.extract(id: $0.id, title: $0.title) == code }) else {
                return HopOutcome(label: "not-carried", served: nil)
            }
            let bundle = try await detailMeta(pluginId: target, movieId: match.id)
            let detail = await detailStreams(pluginId: target, movieId: match.id, detail: bundle.detail)
            guard let server = detail.servers.first, let episode = server.episodes.first else {
                return HopOutcome(label: "no-episodes", served: nil)
            }
            let hopRequest = PlaybackRequest(
                movie: detail.asMovie,
                pluginId: target,
                pluginName: await manifest(for: target)?.name ?? "",
                isManga: false,
                serverName: server.name,
                episode: episode,
                allEpisodes: server.episodes,
                startPosition: origin.startPosition,
                knownStreamURL: "",
                fallbackHeaders: bundle.detailStream.headers,
                switchList: []
            )
            let resolution = try await resolveEpisode(hopRequest)
            switch resolution {
            case .video(let stream):
                guard stream.hasPlayableURL else {
                    return HopOutcome(label: "unreachable empty-url", served: nil)
                }
                if FallbackCatalog.preflightSet.contains(target) {
                    let walk = await preflightWalk(pluginId: target, stream: stream)
                    switch walk.verdict {
                    case .ok, .skipped:
                        return HopOutcome(label: "served", served: HopServed(resolution: .video(walk.stream), request: hopRequest))
                    case .refused(let status):
                        return HopOutcome(label: "refused status=\(status)", served: nil)
                    case .notFound:
                        return HopOutcome(label: "not-found", served: nil)
                    case .unreachable(let detailText):
                        return HopOutcome(label: "unreachable \(detailText)", served: nil)
                    }
                }
                return HopOutcome(label: "served", served: HopServed(resolution: resolution, request: hopRequest))
            case .embed, .manga:
                return HopOutcome(label: "unreachable non-video-outcome", served: nil)
            }
        } catch {
            let nsError = error as NSError
            return HopOutcome(label: "error \(nsError.domain)#\(nsError.code)", served: nil)
        }
    }

    /// streamxx route decision (v1.22.11): the operator's newer
    /// uploads have NO HLS backup in the segment store, and the
    /// progressive MP4 served at their /main.m3u8 address has
    /// corrupt sample tables — measured with FFmpeg 8.1, which
    /// cannot decode a single frame ("missing mandatory atoms,
    /// broken header", "contradictionary STSC and STCO"), so no
    /// native or compat engine on the phone can play them either
    /// (the v1.22.10 KSPlayer flagging failed on the owner's
    /// device for exactly this reason). The operator's own web
    /// player at embed.streamxx.net/player/<id> DOES play the
    /// same titles (browser-verified), so a backup-less streamxx
    /// stream is handed to the webview on that player page
    /// instead of to a video surface. The hand-off is
    /// NON-SNIFFING (sniffMedia: false, round-2 review M-1):
    /// the player page loads the same broken /main.m3u8
    /// internally, and the webview's media sniffer would
    /// capture that URL and promote it to a native surface —
    /// which cannot play it — defeating the route. Left alone,
    /// the page's own player plays it in-page exactly as it
    /// does in a browser. A stream WITH a backup keeps the
    /// synthesis path: this helper returns nil and the caller
    /// proceeds to .video untouched. Never throws; any
    /// doubt → nil.
    private func streamxxPlayerFallback(url: String, headers: [String: String]) async -> PlaybackResolution? {
        guard let u = URL(string: url), let streamID = PlaylistSynthesizer.streamxxID(from: u) else { return nil }
        if await PlaylistSynthesizer.backupExists(streamID: streamID) {
            DiagLog.log("resolve", "streamxx id=\(streamID) backup=yes -> synthesis path")
            return nil
        }
        guard let playerURL = URL(string: "https://embed.streamxx.net/player/\(streamID)") else { return nil }
        DiagLog.log("resolve", "streamxx id=\(streamID) backup=no route=embed-player sniff=off url=\(DiagLog.urlForLog(playerURL.absoluteString))")
        return .embed(url: playerURL, headers: headers, sniffMedia: false)
    }

    /// Some playlists route their segments through a throwaway
    /// proxy host (streamxx's /__hls_proxy/…) that can be dead
    /// while the playlist itself still loads from an edge cache:
    /// AVPlayer then stalls on the first segment instead of
    /// failing, so the HLS-proxy rescue retry never engages. Peek
    /// at the playlist; when it uses that wrapper, mark the stream
    /// so the player starts through the rescue proxy immediately
    /// (the proxy unwraps the segment URLs itself).
    ///
    /// Film4K is marked unconditionally: its segments are fMP4
    /// files wrapped in PNG images (the TV app's v1.6.4 round
    /// closed its Film4K saga — the service itself is healthy,
    /// just slow through the tunnel, and the app's fetch layer is
    /// already patient). A wrapped segment makes AVPlayer stall
    /// rather than fail, which is exactly the case the plain-first
    /// retry cannot rescue; starting through the loader (which
    /// strips the wrappers) is the reliable order, and v1.8's
    /// proxied→plain fallback covers the reverse if ever needed.
    /// Per-host verdict cache (v1.22): the probe below downloads
    /// the whole playlist just to grep for the wrapper — measured
    /// 1.5–2.0 s on sextop1's 80 KB playlist, paid on EVERY tap for
    /// a wrapper its playlists never contain. Only the streamxx
    /// family produces the wrapper, so a host's first successful
    /// probe settles the question for the rest of the session.
    private static var proxyVerdicts: [String: Bool] = [:]
    private static let proxyVerdictLock = NSLock()

    private func markProxyIfNeeded(_ stream: StreamInfo, pluginId: String) async -> StreamInfo {
        if pluginId == "film4k", stream.url.lowercased().contains(".m3u8") {
            var marked = stream
            marked.requiresProxy = true
            return marked
        }
        // streamxx URLs return untouched (v1.22.11): their route
        // decision — synthesis when a backup exists, the
        // operator's web player when none does — is made by
        // streamxxPlayerFallback in resolveEpisode, BEFORE the
        // stream reaches a video surface. What must never happen
        // here is the generic __hls_proxy probe below: it
        // downloads the whole body as text to grep for the
        // wrapper, which on streamxx's newer uploads means
        // pulling a ~100 MB progressive MP4 down as "text" on
        // every tap — and the verdict never affected streamxx
        // playback anyway (synthesis outranks the proxy ladder).
        if let url = URL(string: stream.url), PlaylistSynthesizer.streamxxID(from: url) != nil {
            return stream
        }
        // JavSnap (L-24/FL-465): the resolve terminal is
        // https://vid-snap-player.com/v/<token> — no .m3u8 in the URL,
        // and the playlist behind its 302 is served as text/plain +
        // nosniff under a .sb name, which AVPlayer refuses outright
        // (-11828). The disguise is the HLS rescue loader's exact
        // disease class: start through it on the first attempt.
        if let host = URL(string: stream.url)?.host?.lowercased(),
           host == "vid-snap-player.com" || host.hasSuffix(".vid-snap-player.com") {
            DiagLog.log("resolve", "proxy-mark reason=vidsnap host=\(host)")
            var marked = stream
            marked.requiresProxy = true
            return marked
        }
        guard stream.url.lowercased().contains(".m3u8") else { return stream }
        let host = URL(string: stream.url)?.host ?? ""
        if !host.isEmpty {
            let cached = Self.proxyVerdictLock.withLock { Self.proxyVerdicts[host] }
            if let cached {
                guard cached else { return stream }
                var marked = stream
                marked.requiresProxy = true
                return marked
            }
        }
        guard let text = try? await Net.fetchText(stream.url, headers: stream.headers) else { return stream }
        let verdict = text.contains("__hls_proxy/")
        if !host.isEmpty {
            Self.proxyVerdictLock.withLock { Self.proxyVerdicts[host] = verdict }
        }
        guard verdict else { return stream }
        var marked = stream
        marked.requiresProxy = true
        return marked
    }

    /// Resolves one manga chapter (used by the reader's prev/next).
    func resolveMangaChapter(pluginId: String, episode: Episode) async throws -> StreamInfo {
        guard let engine = try? await engine(for: pluginId) else {
            throw MovieServiceError.pluginUnavailable
        }
        let text = try await Net.fetchText(episode.id)
        let stream = await engine.parseStream(text: text, url: episode.id)
        guard !stream.images.isEmpty else { throw MovieServiceError.unresolvedEpisode }
        var resolved = stream
        if resolved.headers.isEmpty { resolved.headers = await defaultHeaders(for: pluginId) }
        return resolved
    }
}

// MARK: - Source rescue: base code, fallback outcome, pre-flight (spec §2/§3)

/// The result of `MovieService.resolveWithFallback`: the
/// resolution to play, the request that actually serves it
/// (== the input when no fallback occurred), and whether a
/// fallback hop served it.
struct FallbackOutcome {
    var resolution: PlaybackResolution
    var servedRequest: PlaybackRequest
    var didFallback: Bool
}

/// Base catalogue code extraction (§2.2): JAV titles are
/// indexed across sources by a normalised code
/// (`<LETTERS>-<DIGITS>` or the FC2-PPV form). Candidates in
/// order: the movie id's slug (last path component first),
/// then the title. Match comparison between the query code
/// and a search result's code is exact equality on the
/// normalised form.
enum BaseCode {
    static func extract(from request: PlaybackRequest) -> String? {
        extract(movieId: request.movie.id, title: request.movie.title)
    }

    static func extract(id: String, title: String) -> String? {
        extract(movieId: id, title: title)
    }

    /// The Movie-level entry point (§13.5): the same candidate
    /// order (the id's last path component, then the title)
    /// and the same patterns as the request-based extractor —
    /// every entry point sits on this one core so the forms
    /// can never drift.
    static func extract(movieId: String, title: String) -> String? {
        let slug = movieId.split(separator: "/").last.map(String.init) ?? movieId
        if let code = fromSlug(slug) { return code }
        return fromText(title)
    }

    /// FC2 form, searched anywhere in the uppercased text:
    /// `FC2-?PPV-?(\d{5,7})` -> `FC2-PPV-<digits>`.
    private static func fc2(in upper: String) -> String? {
        guard let anchor = upper.range(of: "FC2") else { return nil }
        var rest = upper[anchor.upperBound...]
        if rest.hasPrefix("-") { rest = rest.dropFirst() }
        guard rest.hasPrefix("PPV") else { return nil }
        rest = rest.dropFirst(3)
        if rest.hasPrefix("-") { rest = rest.dropFirst() }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard digits.count >= 5 else { return nil }
        return "FC2-PPV-" + String(digits.prefix(7))
    }

    /// Standard form at the START of the slug token stream,
    /// after stripping leading locale segments (en/vi/ja):
    /// `([A-Z]{2,6})-(\d{2,6})`. Everything after the numeric
    /// token (`-uncensored-leak`, `-sub`, ...) is discarded by
    /// construction.
    private static func fromSlug(_ slug: String) -> String? {
        let upper = slug.uppercased()
        if let code = fc2(in: upper) { return code }
        var tokens = upper.split(separator: "-").map(String.init)
        while let first = tokens.first, ["EN", "VI", "JA"].contains(first) {
            tokens.removeFirst()
        }
        guard tokens.count >= 2 else { return nil }
        let letters = tokens[0]
        let digits = tokens[1]
        guard (2...6).contains(letters.count),
              letters.allSatisfy({ $0.isASCII && $0.isLetter }),
              (2...6).contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "\(letters)-\(digits)"
    }

    /// From a title: the first standard/FC2 match anywhere.
    private static func fromText(_ text: String) -> String? {
        let upper = text.uppercased()
        if let code = fc2(in: upper) { return code }
        let chars = Array(upper)
        var i = 0
        while i < chars.count {
            guard chars[i].isASCII, chars[i].isLetter else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
            // A letter run longer than 6 can still end in a
            // code: the pattern's match is its last 6 letters.
            let start = j - min(j - i, 6)
            if j < chars.count, chars[j] == "-" {
                var k = j + 1
                while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
                if k - (j + 1) >= 2 {
                    let digits = String(chars[(j + 1)..<min(k, j + 7)])
                    return String(chars[start..<j]) + "-" + digits
                }
            }
            i = j
        }
        return nil
    }
}

/// Verdict of one playlist pre-flight (§3.1).
enum PreflightVerdict: Equatable {
    case ok(status: Int, ttfbMs: Int)
    case refused(status: Int)        // 401 / 403
    case notFound                     // 404 / 410
    case unreachable(String)          // other HTTP status, or transport detail
    case skipped                      // not a pre-flightable stream
}

/// Playlist pre-flight (§3.1): an ephemeral URLSession (the
/// TVSourceProbe discipline, in core), GET with
/// `Range: bytes=0-0` and the resolved stream's headers
/// exactly as the player would send them, cancelled at the
/// first body byte, 4 s budget. The verdict is status /
/// first-byte only — the body is never read beyond the first
/// chunk and never stored. Used ONLY by the fallback engine
/// and the tvOS measurement pass — never inside
/// `resolveEpisode` itself.
enum StreamPreflight {
    /// Pre-flightable playlist candidates (§3.1): direct-media
    /// URLs, plus disguised playlist suffixes — the StreamHG
    /// family's terminal is literally named master.txt (L-26).
    /// This widening lives HERE, not in MediaURL.isDirectMedia:
    /// that predicate routes the resolve chain itself (direct
    /// vs embed classification), and a .txt URL must not become
    /// "direct media" there. StreamPreflight is used only by
    /// the fallback engine and the tvOS measurement pass, so
    /// the wider gate reaches nothing else.
    private static func isPreflightable(_ url: String) -> Bool {
        if MediaURL.isDirectMedia(url) { return true }
        // The same scheme guard MediaURL.isDirectMedia
        // applies (gate fix, round 3): only http(s)
        // candidates are pre-flightable — a scheme-less or
        // foreign-scheme string that merely ends in .txt
        // must verdict .skipped (fail-open), never a
        // decided .unreachable.
        let lower = url.lowercased()
        guard lower.hasPrefix("http") else { return false }
        let path = lower.split(separator: "?").first.map(String.init) ?? ""
        // Strip any fragment as well (gate fix): the suffix
        // test must judge the path — a ".txt" living only in
        // the fragment must not admit a candidate, and a
        // fragment must not hide a real master.txt terminal.
        let cleanPath = path.split(separator: "#").first.map(String.init) ?? ""
        return cleanPath.hasSuffix(".txt")
    }

    static func check(url: String, headers: [String: String]) async -> PreflightVerdict {
        guard Self.isPreflightable(url), let target = URL(string: url) else { return .skipped }
        var request = URLRequest(url: target)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let delegate = PreflightDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration,
                                 delegate: delegate, delegateQueue: queue)
        let verdict: PreflightVerdict = await withCheckedContinuation { continuation in
            delegate.arm(continuation: continuation)
            let task = session.dataTask(with: request)
            delegate.attach(task: task, queue: queue)
            task.resume()
            // The budget enforcer: whichever of first-byte,
            // completion, or this deadline lands first wins;
            // the delegate resumes exactly once.
            Task {
                try? await Task.sleep(for: .seconds(4))
                delegate.expire()
            }
        }
        session.invalidateAndCancel()
        return verdict
    }

    /// Resume-once delegate (the TVSourceProbe FirstByteDelegate
    /// idiom): all mutable state is touched only on the
    /// session's serial delegate queue or before the task
    /// resumes, except `expire()`, which hops onto that same
    /// queue — the `@unchecked Sendable` states exactly that
    /// confinement for the compiler.
    private final class PreflightDelegate: NSObject, URLSessionDataDelegate,
        @unchecked Sendable {
        private var continuation: CheckedContinuation<PreflightVerdict, Never>?
        private var task: URLSessionDataTask?
        private var started: Date?
        private var status: Int?
        private var finished = false
        private var callbackQueue: OperationQueue?

        func arm(continuation: CheckedContinuation<PreflightVerdict, Never>) {
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
                self?.finish(.unreachable("timeout"))
            }
        }

        private func finish(_ verdict: PreflightVerdict) {
            guard !finished else { return }
            finished = true
            task?.cancel()
            continuation?.resume(returning: verdict)
            continuation = nil
        }

        /// The verdict a status alone decides, or nil when the
        /// status is 2xx and the first body byte must land
        /// before the stream can be called ok.
        private static func verdict(forStatus status: Int) -> PreflightVerdict? {
            switch status {
            case 401, 403: return .refused(status: status)
            case 404, 410: return .notFound
            case 200..<300: return nil
            default: return .unreachable("http=\(status)")
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            status = code
            if let verdict = Self.verdict(forStatus: code) {
                completionHandler(.cancel)
                finish(verdict)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            guard let started else { finish(.unreachable("no-clock")); return }
            finish(.ok(status: status ?? 200,
                       ttfbMs: Int(Date().timeIntervalSince(started) * 1000)))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            if let error {
                let nsError = error as NSError
                finish(.unreachable("\(nsError.domain)#\(nsError.code)"))
            } else if let status, let verdict = Self.verdict(forStatus: status) {
                finish(verdict)
            } else {
                // A 2xx answer that completed with no body byte
                // at all: the host answered, so the stream is
                // not refused — ok with no measured TTFB.
                finish(.ok(status: status ?? 200, ttfbMs: 0))
            }
        }
    }
}

// MARK: - Cross-source actor merge (spec §13, 1.3.6)

/// One source's resolved actor filmography (§13.4): the
/// target plugin's OWN actor route in the exact form its
/// cast chips emit, plus the filmography's page 1 (which may
/// be empty: resolved, zero rows — §13.1a applies).
/// `avatarUrl` is set only by the topxx index resolution.
struct ActorContribution {
    let pluginId: String
    let route: String        // the target plugin's OWN actor route,
                             // in the exact form its cast chips emit
    let avatarUrl: String?   // topxx index resolution only; else nil
    let firstPage: ListPage  // the filmography's page 1 (may be empty:
                             // resolved, zero rows — §13.1a applies)
}

/// The resolution half of a §13.4 actor resolution: the
/// route a source assigns the name, reached WITHOUT the
/// filmography fetch — except where the fetch IS the proof
/// (njav construction, the javguru construction fallback),
/// in which case `firstPage` carries the page already
/// fetched so the merge never pays for it twice.
struct ActorResolution {
    let route: String?
    let avatarUrl: String?   // topxx index resolution only; else nil
    let outcome: String      // the §13.9 outcome label
    let firstPage: ListPage?
}

/// The search probe's verdict (§13.13 amendment): the
/// winning source (first canonical resolver), its verified
/// actor route, and how many sources resolved the name.
struct ActorProbeResult {
    let pluginId: String
    let route: String
    /// Every source that resolved the name, in canonical
    /// order; the winner (`pluginId`) is the first of these.
    let resolverIds: [String]
    var resolverCount: Int { resolverIds.count }
}

/// Resume-once race box for `actorProbe` — the house race
/// idiom (DebridPhase2RaceBox / PrefetchJoinBox). The
/// probe's 6 s deadline must bound the function's RETURN,
/// which a task group cannot promise: its scope exit waits
/// for every child, and a child stuck in a long fetch may
/// not unwind on cancellation. One unstructured task per
/// source races a deadline task; whichever finishes the
/// box first — every source recorded, or the deadline —
/// resumes the continuation and cancels the rest. The
/// NSLock is the whole confinement story, hence
/// @unchecked Sendable.
private final class ActorProbeRaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private var continuation: CheckedContinuation<[(pluginId: String, route: String)], Never>?
    private var resumed = false
    private var found: [(pluginId: String, route: String)] = []
    private var completed = 0
    private var tasks: [Task<Void, Never>] = []

    init(total: Int) { self.total = total }

    func arm(_ continuation: CheckedContinuation<[(pluginId: String, route: String)], Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            continuation.resume(returning: [])
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

    func record(pluginId: String, route: String?) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        completed += 1
        if let route { found.append((pluginId, route)) }
        let done = completed >= total
        lock.unlock()
        if done { finish() }
    }

    func deadline() { finish() }

    private func finish() {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        let hits = found
        let tasks = self.tasks
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: hits)
    }
}

extension MovieService {
    /// §13.4: resolves one source's actor filmography for the
    /// cross-source actor page. `nil` means "no contribution"
    /// for ANY reason (not installed, disabled, no match,
    /// error, timeout) — the caller never distinguishes; the
    /// DiagLog line does (§13.9, emitted by the merge
    /// coordinator from the detailed form below). Every path
    /// uses ONLY the existing service surfaces (`search`,
    /// `detailMeta`, `list`) — no plugin is modified.
    func actorContribution(pluginId: String, name: String) async -> ActorContribution? {
        await actorContributionDetailed(pluginId: pluginId, name: name).contribution
    }

    /// The detailed form of `actorContribution`: the
    /// contribution plus the §13.9 outcome label and the
    /// page-1 hit count for the coordinator's per-source log
    /// line. Never throws — every failure is an outcome.
    func actorContributionDetailed(pluginId: String, name: String) async
        -> (contribution: ActorContribution?, outcome: String, hits: Int) {
        let resolution = await resolveActorRoute(pluginId: pluginId, name: name)
        guard let route = resolution.route else {
            return (nil, resolution.outcome, 0)
        }
        do {
            let page: ListPage
            if let carried = resolution.firstPage {
                page = carried
            } else {
                page = try await list(pluginId: pluginId, slug: route, filters: ListFilters(), page: 1)
            }
            return (ActorContribution(pluginId: pluginId, route: route,
                                      avatarUrl: resolution.avatarUrl, firstPage: page),
                    resolution.outcome, page.items.count)
        } catch {
            let nsError = error as NSError
            return (nil, "error \(nsError.domain)#\(nsError.code)", 0)
        }
    }

    /// The resolution half of §13.4: name → the source's OWN
    /// actor route, WITHOUT fetching the filmography — except
    /// where the fetch IS the proof (njav construction, the
    /// javguru construction fallback), in which case the
    /// resolution carries the page it already fetched so the
    /// merge never pays for it twice. Shared by
    /// `actorContributionDetailed` (the merge) and
    /// `actorProbe` (the search row) so the two can never
    /// drift: a source resolves under exactly one discipline.
    /// Never throws — every failure is an outcome label.
    private func resolveActorRoute(pluginId: String, name: String) async -> ActorResolution {
        guard await manager.installedPlugin(id: pluginId) != nil,
              await manager.isPluginEnabled(pluginId) else {
            return ActorResolution(route: nil, avatarUrl: nil, outcome: "not-installed", firstPage: nil)
        }
        do {
            switch pluginId {
            case "njav":
                // By construction (§13.4): the plugin's route
                // IS the name — "/en/actor/" + the name with
                // each space replaced by %20, the exact form
                // mod08's cast chips emit. The normalize-equal
                // gate is inherent: the route embeds the query
                // name verbatim, so any films returned are
                // njav's own resolution of that exact string.
                let route = "/en/actor/" + name.replacingOccurrences(of: " ", with: "%20")
                let page = try await list(pluginId: pluginId, slug: route, filters: ListFilters(), page: 1)
                guard !page.items.isEmpty else {
                    return ActorResolution(route: nil, avatarUrl: nil, outcome: "no-match", firstPage: nil)
                }
                return ActorResolution(route: route, avatarUrl: nil, outcome: "resolved", firstPage: page)
            case "missav", "123av", "javguru", "javsnap":
                // Search harvest (§13.4): walk page 1 of the
                // plugin's own search IN ORDER, at most 3
                // detail fetches total (see harvestActorRoute).
                let harvest = try await harvestActorRoute(pluginId: pluginId, name: name)
                if let route = harvest.route {
                    return ActorResolution(route: route, avatarUrl: nil, outcome: "resolved", firstPage: nil)
                }
                if pluginId == "javguru" {
                    // Bounded secondary (§13.4, 1.22.21): ONE
                    // construction attempt. jav.guru is
                    // WordPress — its cast entries prove routes
                    // are /actress/<slug>/ and WP slugs are the
                    // sanitized name, so this is the njav
                    // pattern: the listing itself is the
                    // source's verdict (non-empty = resolved,
                    // logged distinctly as resolved-constructed).
                    let slug = "actress/" + ActorName.normalize(name)
                        .replacingOccurrences(of: " ", with: "-")
                    let page = try await list(pluginId: pluginId, slug: slug, filters: ListFilters(), page: 1)
                    guard !page.items.isEmpty else {
                        return ActorResolution(route: nil, avatarUrl: nil, outcome: "no-match", firstPage: nil)
                    }
                    return ActorResolution(route: slug, avatarUrl: nil, outcome: "resolved-constructed", firstPage: page)
                }
                if pluginId == "javsnap", harvest.searchedItems == 0 {
                    // Zero-harvest fallback (§13.4, 1.22.21):
                    // javsnap's search is code/title-oriented —
                    // a name may return nothing at all. Scan
                    // its actors index (the single page the
                    // plugin serves) for an ACTRESS item whose
                    // title normalize-equals the query (the
                    // topxx shape, capped at that one page).
                    // Avatar stays nil this round: javsnap's
                    // index image has not passed the §13.1e
                    // portrait audit (topxx remains the only
                    // avatar source).
                    let page = try await list(pluginId: pluginId, slug: "actors", filters: ListFilters(), page: 1)
                    if let hit = page.items.first(where: { $0.quality == "ACTRESS" && ActorName.matches($0.title, name) }) {
                        return ActorResolution(route: hit.id, avatarUrl: nil, outcome: "resolved", firstPage: nil)
                    }
                }
                return ActorResolution(route: nil, avatarUrl: nil, outcome: "no-match", firstPage: nil)
            case "topxx":
                // Bounded index scan (§13.4): the route needs
                // an `actor-<code>` the app cannot construct
                // from a name, and topxx's movie search
                // ignores its query (Phase 0, proven) — so
                // resolution scans the actors index through
                // the list surface, pages 1...8, stopping at
                // the first ACTRESS item whose title
                // normalize-equals the query. Its id is the
                // route; its posterUrl is the actor record's
                // avatar field (the plugin maps it there).
                var route: String?
                var avatarUrl: String?
                for indexPage in 1...8 {
                    try Task.checkCancellation()
                    let page = try await list(pluginId: pluginId, slug: "actors", filters: ListFilters(), page: indexPage)
                    if let hit = page.items.first(where: { $0.quality == "ACTRESS" && ActorName.matches($0.title, name) }) {
                        route = hit.id
                        avatarUrl = hit.posterUrl.isEmpty ? nil : hit.posterUrl
                        break
                    }
                }
                guard let resolvedRoute = route else {
                    return ActorResolution(route: nil, avatarUrl: nil, outcome: "unresolved-cap", firstPage: nil)
                }
                return ActorResolution(route: resolvedRoute, avatarUrl: avatarUrl, outcome: "resolved", firstPage: nil)
            default:
                return ActorResolution(route: nil, avatarUrl: nil, outcome: "no-match", firstPage: nil)
            }
        } catch is CancellationError {
            return ActorResolution(route: nil, avatarUrl: nil, outcome: "cancelled", firstPage: nil)
        } catch {
            let nsError = error as NSError
            return ActorResolution(route: nil, avatarUrl: nil, outcome: "error \(nsError.domain)#\(nsError.code)", firstPage: nil)
        }
    }

    /// The §13.4 search harvest, shared by every
    /// search-backed source: walk page 1 of the plugin's own
    /// search IN ORDER, at most 3 detail fetches total. An
    /// actress-index item whose title normalize-equals the
    /// query resolves the source with NO detail fetch spent;
    /// otherwise the first detail whose castEntries carry a
    /// routed entry whose name normalize-equals the query
    /// resolves it, and the route is that entry's route
    /// verbatim. `searchedItems` is the raw page-1 count —
    /// the javsnap zero-harvest fallback keys on it.
    private func harvestActorRoute(pluginId: String, name: String) async throws
        -> (route: String?, searchedItems: Int) {
        let results = try await search(pluginId: pluginId, keyword: name, page: 1)
        var detailBudget = 3
        for item in results.items {
            try Task.checkCancellation()
            if item.quality == "ACTRESS", ActorName.matches(item.title, name) {
                return (item.id, results.items.count)
            }
            guard detailBudget > 0 else { continue }
            detailBudget -= 1
            guard let bundle = try? await detailMeta(pluginId: pluginId, movieId: item.id) else { continue }
            if let entry = bundle.detail.castEntries.first(where: { $0.route != nil && ActorName.matches($0.name, name) }) {
                return (entry.route, results.items.count)
            }
        }
        return (nil, results.items.count)
    }

    /// §13.13 amendment (1.22.21): the search-box actress
    /// probe. Runs the RESOLUTION half of §13.4 — the shared
    /// `resolveActorRoute`, so probe and merge can never
    /// drift — for every canonical source in parallel under
    /// a 6 s soft deadline, and reports the first canonical
    /// resolver. A hit requires the source's own exact §13.4
    /// gate; the typed text alone is never trusted as an
    /// actress name, and the probe never blocks or delays
    /// the film results it rides alongside. Sources that
    /// miss the deadline simply don't count. avdbapi is NOT
    /// a signal (§13.13: its `wd=` search returns films, not
    /// an actor entity); vlxx keyword search likewise.
    func actorProbe(name: String) async -> ActorProbeResult? {
        guard !ActorName.normalize(name).isEmpty else { return nil }
        let started = Date()
        let sources = ActorMerge.canonicalOrder
        let box = ActorProbeRaceBox(total: sources.count)
        let hits: [(pluginId: String, route: String)] = await withCheckedContinuation { continuation in
            box.arm(continuation)
            var tasks: [Task<Void, Never>] = sources.map { pluginId in
                Task {
                    let resolution = await self.resolveActorRoute(pluginId: pluginId, name: name)
                    box.record(pluginId: pluginId, route: resolution.route)
                }
            }
            tasks.append(Task {
                try? await Task.sleep(for: .seconds(6))
                box.deadline()
            })
            box.attach(tasks: tasks)
        }
        let resolverIds = sources.filter { id in hits.contains { $0.pluginId == id } }
        guard let winner = resolverIds.first,
              let winningRoute = hits.first(where: { $0.pluginId == winner })?.route else {
            DiagLog.log("actor", "actor-probe outcome=miss sources=none ms=\(Self.fallbackMs(since: started))")
            return nil
        }
        DiagLog.log("actor", "actor-probe outcome=hit sources=\(resolverIds.joined(separator: ",")) ms=\(Self.fallbackMs(since: started))")
        return ActorProbeResult(pluginId: winner, route: winningRoute, resolverIds: resolverIds)
    }
}

/// The §13 merge engine — a per-visit object the actor
/// shells create and observe. It lives in the shared core
/// so the merge discipline exists exactly once; the shells
/// mirror its published state into their own `@State` in
/// their own idioms.
@MainActor
final class ActorMergeCoordinator {
    private(set) var rows: [ActorFilmRow] = []
    /// Plugin ids with ≥1 row on screen, origin first when it
    /// contributed, then canonical order — the header naming set
    /// (§13.1a). A resolved-but-zero-row source never appears here.
    private(set) var contributors: [String] = []
    private(set) var avatarUrl: String?      // §13.1e (topxx only)
    private(set) var originFailed = false
    private(set) var settled = false         // merge fully settled
    var onChange: (() -> Void)?

    /// The origin page's own list slug. The spec's init
    /// carries no route, but the coordinator owns the
    /// origin's pagination cursor (§13.5), so the shells
    /// assign this once, before `begin`.
    var originRoute: String = ""

    private let service: MovieService
    private let originPluginId: String
    private let name: String
    private let targets: [String]

    private var began = false
    private var frozen = false
    private var beginDate: Date?
    private var dedupedCount = 0
    private var seenCodes: Set<String> = []
    private var seenIds: [String: Set<String>] = [:]
    private var contributedTargets: Set<String> = []

    /// Per-source pagination cursor (the origin included,
    /// seeded from the handed page 1).
    private struct Cursor {
        var route: String
        var page: Int
        var totalPages: Int
        var exhausted: Bool
    }
    private var cursors: [String: Cursor] = [:]

    private enum TargetState {
        case pending
        /// Past the 8 s soft deadline (§13.5 amendment): the
        /// page has visibly settled without this target, but
        /// it keeps resolving under the 20 s ceiling and its
        /// block appends at the END when it lands.
        case deferred
        case settled(ActorContribution?)
    }
    private var targetStates: [String: TargetState] = [:]
    private var releaseIndex = 0
    private var releasedTargets: Set<String> = []
    private var softFired = false
    private(set) var fullySettled = false
    private var targetTasks: [String: Task<Void, Never>] = [:]
    private var budgetTask: Task<Void, Never>?
    private var softTask: Task<Void, Never>?
    private var isLoadingMore = false

    init(service: MovieService, originPluginId: String, name: String) {
        self.service = service
        self.originPluginId = originPluginId
        self.name = name
        self.targets = ActorMerge.targets(for: originPluginId)
    }

    /// Seed with the origin's page-1 outcome (the shells load it with
    /// today's exact call and error handling) and start the targets.
    /// nil page + originFailed=true is the origin-error entry.
    func begin(originFirstPage: ListPage?, originFailed: Bool) {
        guard !began else { return }
        began = true
        self.originFailed = originFailed
        beginDate = Date()
        DiagLog.log("actor", "merge begin origin=\(originPluginId) name=\(name) targets=\(targets.joined(separator: ","))")
        if let page = originFirstPage {
            cursors[originPluginId] = Cursor(route: originRoute,
                                             page: page.pagination.currentPage,
                                             totalPages: max(page.pagination.totalPages, 1),
                                             exhausted: false)
            appendBlock(pluginId: originPluginId, movies: page.items, isOrigin: true)
        } else {
            cursors[originPluginId] = Cursor(route: originRoute, page: 1, totalPages: 1, exhausted: true)
        }
        // §13.3: an empty normalized query never runs the
        // merge at all — the page is exactly today's.
        guard !ActorName.normalize(name).isEmpty else {
            settled = true
            fullySettled = true
            logSettled()
            onChange?()
            return
        }
        for target in targets {
            targetStates[target] = .pending
            targetTasks[target] = Task { [weak self] in
                guard let self else { return }
                await self.resolveTarget(target)
            }
        }
        budgetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled else { return }
            self.enforceTotalBudget()
        }
        softTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            self.applySoftDeadline()
        }
        onChange?()
    }

    /// Lockstep pagination (§13.5): the next page of EVERY
    /// non-exhausted source in parallel (each under the same
    /// 20 s ceiling; a failed page marks that source
    /// exhausted, non-fatally, per the house discipline),
    /// then the new rows append in canonical block order
    /// under the same dedupe rules. Pagination defers until
    /// the merge has settled — page-N rows never precede an
    /// unreleased page-1 block (see the guard in the body).
    /// In the finished-solo outcome this reduces to exactly
    /// today's origin-only loadMore.
    func loadMore() async {
        // Ordered release governs pagination too (§13.1g,
        // gate fix F-A5): while the merge is unsettled, some
        // page-1 block may still be unreleased — a settled
        // target's cursor is installed at settle time, BEFORE
        // its block necessarily released — and a page-N append
        // could land ahead of that block, or dedupe against a
        // seen-set missing the block's codes and invert the
        // first-occurrence winner rule (the page-2 copy would
        // survive and the page-1 copy drop).
        // §13.5 amendment (soft deadline): `settled` now also
        // flips at the 8 s soft deadline with some targets
        // DEFERRED. Pagination then proceeds over INSTALLED
        // cursors only — a deferred source has no cursor yet,
        // so its own page-N can never precede its page-1 block
        // (F-A5 holds for it), and when its page-1 lands it
        // appends at the end under the same dedupe rules,
        // the on-screen copy winning any shared code.
        guard began, !frozen, !isLoadingMore, settled else { return }
        let orderedIds = [originPluginId] + targets
        var fetchList: [(pluginId: String, route: String, page: Int)] = []
        for pluginId in orderedIds {
            guard let cursor = cursors[pluginId], !cursor.exhausted,
                  cursor.page >= 1, cursor.page < cursor.totalPages else { continue }
            if pluginId != originPluginId, !contributedTargets.contains(pluginId) { continue }
            fetchList.append((pluginId: pluginId, route: cursor.route, page: cursor.page + 1))
        }
        guard !fetchList.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var results: [String: ListPage?] = [:]
        await withTaskGroup(of: (String, ListPage?).self) { group in
            for entry in fetchList {
                group.addTask {
                    let page = await self.fetchPageWithCeiling(entry)
                    return (entry.pluginId, page)
                }
            }
            for await (pluginId, page) in group {
                results[pluginId] = page
            }
        }
        guard !frozen else { return }
        for pluginId in orderedIds {
            guard fetchList.contains(where: { $0.pluginId == pluginId }) else { continue }
            if let fetched = results[pluginId], let page = fetched {
                cursors[pluginId]?.page = page.pagination.currentPage
                cursors[pluginId]?.totalPages = max(page.pagination.totalPages, 1)
                appendBlock(pluginId: pluginId, movies: page.items, isOrigin: pluginId == originPluginId)
            } else {
                cursors[pluginId]?.exhausted = true
            }
        }
        DiagLog.log("actor", "merge more total=\(rows.count)")
        onChange?()
    }

    /// §13.1g: a film Detail was pushed — discard everything late.
    func freeze() {
        guard !frozen else { return }
        frozen = true
        for task in targetTasks.values { task.cancel() }
        budgetTask?.cancel()
        softTask?.cancel()
    }

    // MARK: Target resolution

    private struct TargetResult {
        var contribution: ActorContribution?
        var outcome: String
        var hits: Int
    }

    private func resolveTarget(_ pluginId: String) async {
        let started = Date()
        let result = await runTargetWithCeiling(pluginId)
        guard !frozen else { return }
        // A deferred target's late landing is processed exactly
        // like an on-time one; only an already-settled state
        // (the 45 s budget forced it empty) drops the result.
        guard let state = targetStates[pluginId] else { return }
        switch state {
        case .settled: return
        case .pending, .deferred: break
        }
        DiagLog.log("actor", "merge source=\(pluginId) outcome=\(result.outcome) hits=\(result.hits) ms=\(Self.ms(since: started))")
        targetStates[pluginId] = .settled(result.contribution)
        if let contribution = result.contribution {
            contributedTargets.insert(pluginId)
            cursors[pluginId] = Cursor(route: contribution.route,
                                       page: contribution.firstPage.pagination.currentPage,
                                       totalPages: max(contribution.firstPage.pagination.totalPages, 1),
                                       exhausted: false)
        }
        releaseReadyBlocks()
        finishIfSettled()
        onChange?()
    }

    /// One target under its 20 s ceiling (§13.5), enforced
    /// with the task-group race idiom of §2.5: the resolution
    /// races a sleep that throws `timedOut`; the loser is
    /// cancelled. Never throws — timeout is an outcome.
    private func runTargetWithCeiling(_ pluginId: String) async -> TargetResult {
        do {
            return try await withThrowingTaskGroup(of: TargetResult.self) { group in
                group.addTask {
                    let detailed = await self.service.actorContributionDetailed(pluginId: pluginId, name: self.name)
                    return TargetResult(contribution: detailed.contribution, outcome: detailed.outcome, hits: detailed.hits)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw MovieServiceError.timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            return TargetResult(contribution: nil, outcome: "timeout", hits: 0)
        }
    }

    /// One pagination fetch under the same 20 s ceiling;
    /// nil on timeout or any failure (the caller marks the
    /// source exhausted, non-fatally).
    private func fetchPageWithCeiling(_ entry: (pluginId: String, route: String, page: Int)) async -> ListPage? {
        do {
            return try await withThrowingTaskGroup(of: ListPage.self) { group in
                group.addTask {
                    try await self.service.list(pluginId: entry.pluginId, slug: entry.route,
                                                filters: ListFilters(), page: entry.page)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw MovieServiceError.timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            return nil
        }
    }

    /// The 45 s total merge budget (§13.5): any target still
    /// unsettled is treated as settled-empty for release
    /// purposes and its late result is discarded (its state
    /// is already settled when the completion lands, so the
    /// completion drops it without a second log line).
    private func enforceTotalBudget() {
        guard !frozen, !fullySettled else { return }
        var forced = false
        for target in targets {
            guard let state = targetStates[target] else { continue }
            switch state {
            case .settled: continue
            case .pending, .deferred: break
            }
            DiagLog.log("actor", "merge source=\(target) outcome=timeout hits=0 ms=\(Self.ms(since: beginDate ?? Date()))")
            targetStates[target] = .settled(nil)
            targetTasks[target]?.cancel()
            forced = true
        }
        if forced {
            releaseReadyBlocks()
            finishIfSettled()
            onChange?()
        }
    }

    /// The 8 s soft deadline (§13.5 amendment): the merge's
    /// visible settle must not wait on the slowest source —
    /// the device evidence (2026-11-23) showed every healthy
    /// answer in by 3.3 s while one 20 s ceiling held the
    /// page's header and pagination hostage. When the deadline
    /// fires, every still-pending target becomes DEFERRED:
    /// settled blocks release in canonical order (skipping
    /// deferred), `settled` flips (header settles, pagination
    /// unlocks), and each deferred target keeps resolving
    /// under the existing 20 s ceiling — when it lands, its
    /// block appends at the END via the normal release path
    /// (§13.1 append invariants preserved in full). The
    /// `merge settled` log line still fires only at true
    /// full settle (finishIfSettled).
    private func applySoftDeadline() {
        guard began, !frozen, !fullySettled else { return }
        var pending: [String] = []
        for target in targets {
            guard let state = targetStates[target], case .pending = state else { continue }
            targetStates[target] = .deferred
            pending.append(target)
        }
        softFired = true
        if !pending.isEmpty {
            DiagLog.log("actor", "merge soft-settled pending=\(pending.joined(separator: ",")) ms=\(Self.ms(since: beginDate ?? Date()))")
        }
        releaseReadyBlocks()
        if !settled { settled = true }
        finishIfSettled()
        onChange?()
    }

    // MARK: Ordered release + dedupe

    /// Ordered release (§13.1g): target blocks append whole,
    /// in canonical order — a block appends only when it AND
    /// every earlier target block have settled (resolved,
    /// failed, or timed out). The origin's rows published in
    /// `begin`, the moment the origin settled.
    /// Post-soft-deadline (§13.5 amendment): ordered release
    /// is relaxed for DEFERRED blocks only — settled blocks
    /// release in canonical scan order skipping deferred
    /// ones, and a deferred block appends at the end when it
    /// lands. The §13.1 append invariants (never insert
    /// above/between on-screen rows, never reorder on-screen
    /// rows) hold in both modes.
    private func releaseReadyBlocks() {
        if softFired {
            for target in targets where !releasedTargets.contains(target) {
                guard let state = targetStates[target],
                      case .settled(let contribution) = state else { continue }
                releasedTargets.insert(target)
                guard let contribution else { continue }
                if target == "topxx", let avatar = contribution.avatarUrl {
                    avatarUrl = avatar
                }
                appendBlock(pluginId: target, movies: contribution.firstPage.items, isOrigin: false)
            }
            return
        }
        while releaseIndex < targets.count {
            let target = targets[releaseIndex]
            guard let state = targetStates[target], case .settled(let contribution) = state else { return }
            releaseIndex += 1
            releasedTargets.insert(target)
            guard let contribution else { continue }
            if target == "topxx", let avatar = contribution.avatarUrl {
                avatarUrl = avatar
            }
            appendBlock(pluginId: target, movies: contribution.firstPage.items, isOrigin: false)
        }
    }

    /// Appends one source block at the end under the §13.5
    /// dedupe rules: the ORIGIN's rows are authoritative and
    /// never deduped against each other (their codes only
    /// seed the seen-set); a target block drops an incoming
    /// row whose code is already seen (from the origin or an
    /// earlier block) and counts it, first occurrence within
    /// the block winning; rows whose code is nil are never
    /// deduped. Every block is also deduped by id within its
    /// source — row identity is plugin+id, so a repeated id
    /// is never a distinct row.
    private func appendBlock(pluginId: String, movies: [Movie], isOrigin: Bool) {
        var ids = seenIds[pluginId] ?? []
        var appended = 0
        for movie in movies {
            guard ids.insert(movie.id).inserted else { continue }
            if isOrigin {
                if let code = BaseCode.extract(movieId: movie.id, title: movie.title) {
                    seenCodes.insert(code)
                }
            } else if let code = BaseCode.extract(movieId: movie.id, title: movie.title) {
                guard seenCodes.insert(code).inserted else {
                    dedupedCount += 1
                    continue
                }
            }
            rows.append(ActorFilmRow(pluginId: pluginId, movie: movie))
            appended += 1
        }
        seenIds[pluginId] = ids
        if appended > 0 { noteContribution(pluginId) }
    }

    /// Contributors are always named origin-first (when it
    /// contributed), then in canonical order (§13.1a) —
    /// maintained as a re-derived order, so an origin that
    /// first contributes on a later page still leads.
    private func noteContribution(_ pluginId: String) {
        guard !contributors.contains(pluginId) else { return }
        var present = Set(contributors)
        present.insert(pluginId)
        var ordered: [String] = []
        if present.contains(originPluginId) { ordered.append(originPluginId) }
        for id in ActorMerge.canonicalOrder where id != originPluginId && present.contains(id) {
            ordered.append(id)
        }
        contributors = ordered
    }

    /// True full settle: every target reached a final state.
    /// The visible `settled` flag may already be up (soft
    /// deadline), but the `merge settled` log line fires
    /// exactly once — here, when the merge is genuinely
    /// complete (or in `begin`'s empty-name early exit).
    private func finishIfSettled() {
        guard !fullySettled else { return }
        let allSettled = targets.allSatisfy { target in
            guard let state = targetStates[target], case .settled = state else { return false }
            return true
        }
        guard allSettled else { return }
        fullySettled = true
        settled = true
        softTask?.cancel()
        budgetTask?.cancel()
        logSettled()
    }

    private func logSettled() {
        let names = contributors.isEmpty ? "none" : contributors.joined(separator: ",")
        DiagLog.log("actor", "merge settled total=\(rows.count) contributors=\(names) deduped=\(dedupedCount) ms=\(Self.ms(since: beginDate ?? Date()))")
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - MediaFusion (v1.22.5)

/// Parser + settings for the owner's MediaFusion gateway. The
/// manifest URL is configured by the owner at
/// mediafusion.elfhosted.com/configure (his providers, cached
/// only) and pasted into Settings; it is a bearer credential —
/// stored only in UserDefaults, never logged, never sent
/// anywhere except the gateway itself. MediaFusion stream
/// responses carry NO infoHash: every entry is a direct
/// per-provider link, so episodes keep the URL as their id
/// (the same shape as the torrenthub plugin's direct entries).
enum MediaFusion {
    static let urlKey = "jtv_mediafusion_url"

    static var baseURL: String? {
        let stored = UserDefaults.standard.string(forKey: urlKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // tvOS adaptation (owner ruling: credentials are bundled
        // in the build): when the UserDefaults value is empty, fall
        // back to the bundled constant. A non-empty stored value
        // still wins, exactly as on iOS; nothing else changes.
        let raw = stored.isEmpty
            ? BundledSecrets.mfURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : stored
        guard !raw.isEmpty else { return nil }
        var value = raw
        if value.hasPrefix("stremio://") {
            value = "https://" + String(value.dropFirst("stremio://".count))
        }
        if value.hasSuffix("/manifest.json") {
            value = String(value.dropLast("/manifest.json".count))
        }
        if value.hasSuffix("/") { value = String(value.dropLast()) }
        guard value.hasPrefix("http") else { return nil }
        // v1.22.15 (B-4(i), H-2): register the credential
        // host with the logger so its URL paths are redacted
        // in the log. Host only — the value itself (a bearer
        // credential) never enters the log. Return unchanged.
        if let host = URLComponents(string: value)?.host, !host.isEmpty {
            DiagLog.registerCredentialHost(host)
        }
        return value
    }

    static func parseStreams(text: String) -> [Episode] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else { return [] }
        var parsed: [(episode: Episode, rank: Int, seeds: Int, sizeMB: Double)] = []
        for stream in streams {
            let name = stream["name"] as? String ?? ""
            let title = stream["title"] as? String ?? ""
            let hints = stream["behaviorHints"] as? [String: Any]
            let filename = (hints?["filename"] as? String)
                ?? title.components(separatedBy: "\n").first
                ?? ""
            let provider: String
            let lowered = name.lowercased()
            if lowered.contains("premiumize") || name.contains("PM") { provider = "PM" }
            else if lowered.contains("torbox") || name.contains("TB") { provider = "TB" }
            else if lowered.contains("real-debrid") || lowered.contains("realdebrid") || name.contains("RD") { provider = "RD" }
            else { provider = "MF" }
            let haystack = (name + " " + title + " " + filename).lowercased()
            // v1.22.8: 1440p and FHD join the 1080 tier (the plugin
            // ranks 1440p a half-step above 1080p; here the Int
            // scale ties them and the seed count decides, which is
            // the owner's stated tiebreak).
            let rank = (haystack.contains("2160") || haystack.contains("4k") || haystack.contains("uhd")) ? 4
                : (haystack.contains("1440") || haystack.contains("1080") || haystack.contains("fhd")) ? 3
                : haystack.contains("720") ? 2
                : haystack.contains("480") ? 1 : 0
            let seeds = intAfter("👤", in: title)
            let sizeMB = sizeInMB(title)
            var label = provider
            if !filename.isEmpty { label += " · " + filename }
            if sizeMB > 0 { label += " · " + formatSize(sizeMB) }
            if seeds > 0 { label += " · 👤 \(seeds)" }
            if let url = stream["url"] as? String, !url.isEmpty {
                parsed.append((Episode(id: url, name: label, slug: url), rank, seeds, sizeMB))
            } else if let hash = (stream["infoHash"] as? String)?.lowercased(), !hash.isEmpty {
                let id = "jtvhash:" + hash
                parsed.append((Episode(id: id, name: label, slug: id), rank, seeds, sizeMB))
            }
        }
        parsed.sort { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            if a.seeds != b.seeds { return a.seeds > b.seeds }
            return a.sizeMB > b.sizeMB
        }
        return parsed.prefix(15).map { $0.episode }
    }

    private static func intAfter(_ marker: String, in text: String) -> Int {
        guard let range = text.range(of: marker) else { return 0 }
        let digits = text[range.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private static func sizeInMB(_ text: String) -> Double {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(GB|GiB|MB|MiB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[valueRange]) else { return 0 }
        let unit = text[unitRange]
        return (unit == "GB" || unit == "GiB") ? value * 1024 : value
    }

    private static func formatSize(_ sizeMB: Double) -> String {
        sizeMB >= 1024
            ? String(format: "%.2f GB", sizeMB / 1024)
            : String(format: "%.0f MB", sizeMB)
    }
}
