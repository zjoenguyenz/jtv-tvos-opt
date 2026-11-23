import Foundation

/// The Detail backdrop-preview probe (NEXT-D D3/D4/D7,
/// L-T12), extracted VERBATIM from TVDetailView in Phase 2
/// (1.3.5) so the actor screen's focus-dwell preview runs the
/// ONE probe implementation — shape-based rungs, declared
/// quality gate (stage A), torrent D4 cached-only discipline
/// — instead of a second copy that could drift. TVDetailView
/// delegates with its own state; TVActorView delegates with
/// the focused film's fetched detail. The probe consumes NO
/// embed prefetch and writes NO history (the façade's
/// probeOnly contract); its inputs are value parameters, so
/// no view state leaks into the machinery.
enum TVPreviewProbe {
    /// Declared quality rank on the MediaFusion scale already
    /// used in the tree (MovieService.parseStreams): 2160/4K=4,
    /// 1440/1080/FHD=3, 720=2, 480/SD/CAM=1, unknown=0.
    static func declaredQualityRank(_ text: String) -> Int {
        let haystack = text.lowercased()
        if haystack.contains("2160") || haystack.contains("4k") || haystack.contains("uhd") { return 4 }
        if haystack.contains("1440") || haystack.contains("1080") || haystack.contains("fhd") { return 3 }
        if haystack.contains("720") { return 2 }
        if haystack.contains("480") || haystack.contains("camrip") || haystack.contains("hdcam")
            || haystack.contains(" sd ") || haystack.hasSuffix(" sd") { return 1 }
        return 0
    }

    /// L-T12 (1.3.1, DIAG-131-PREVIEW §6.2): the probe is
    /// SHAPE-BASED — it mirrors resolveEpisode's own routing on
    /// the episode id's actual shape instead of trusting the
    /// manifest `playerType` (empty in the installed record —
    /// RC-1). Cheapest rungs first (detailStream / episode-id
    /// direct media, zero cost); `jtvhash:` episodes go through
    /// `DebridResolver.resolveCachedOnly` EXACTLY as before
    /// (cached-only — never Phase 2, never a server-side
    /// download); every other non-manga plugin goes through the
    /// probe-only façade `resolveEpisodeForPreview`, which runs
    /// the real resolve machinery without consuming the Play
    /// tap's single-consumer embed prefetch. Every rung logs a
    /// [preview] breadcrumb (RC-5) — no silent nil paths.
    /// Streams flagged useCompatEngine or requiresProxy keep
    /// the still (D3), with their own named reason.
    static func resolve(service: MovieService, pluginId: String, pluginName: String,
                        isManga: Bool, detail: MovieDetail, detailStream: StreamInfo?,
                        movie: Movie) async -> StreamInfo? {
        func playable(_ stream: StreamInfo, rung: String) -> StreamInfo? {
            if stream.url.isEmpty {
                DiagLog.log("preview", "probe rung=\(rung) outcome=empty-url")
                return nil
            }
            if stream.useCompatEngine {
                DiagLog.log("preview", "probe rung=\(rung) outcome=compat-engine")
                return nil
            }
            if stream.requiresProxy {
                DiagLog.log("preview", "probe rung=\(rung) outcome=requires-proxy")
                return nil
            }
            return stream
        }
        // Quality gate, stage A (owner rule 2026-11-21 17:52):
        // a stream KNOWN from declared data (detail.quality /
        // the episode label) to be below the floor is rejected
        // here, before any player is built. The floor is 720p,
        // adopted from the owner's same-evening JoeTV rule.
        // Unknown-declared streams are decided by the measured
        // gate in TVBackdropPreviewHost (stage B).
        let declaredRank = max(Self.declaredQualityRank(detail.quality),
                               Self.declaredQualityRank(detail.servers.first(where: { !$0.episodes.isEmpty })?.episodes.first?.name ?? ""))
        if declaredRank == 1 {
            DiagLog.log("preview", "probe rung=declared-quality outcome=low-quality rank=1")
            return nil
        }
        // Rung 1: the detail response's own parsed stream.
        if let detailStream,
           MediaURL.isDirectMedia(detailStream.url) {
            DiagLog.log("preview", "probe rung=detail-stream outcome=direct-media")
            if let ok = playable(detailStream, rung: "detail-stream") { return ok }
        } else {
            DiagLog.log("preview", "probe rung=detail-stream outcome=miss")
        }
        // The preview target is playFirstEpisode's target: the
        // first non-empty server's first episode.
        guard let server = detail.servers.first(where: { !$0.episodes.isEmpty }),
              let episode = server.episodes.first else {
            DiagLog.log("preview", "probe rung=target outcome=no-episode")
            return nil
        }
        let shape = episode.id.hasPrefix("jtvhash:") ? "hash"
            : episode.id.hasPrefix("jtvstreams:") ? "placeholder"
            : MediaURL.isDirectMedia(episode.id) ? "direct-media"
            : episode.id.hasPrefix("http") ? "http-page"
            : "other"
        DiagLog.log("preview", "probe begin plugin=\(pluginId) shape=\(shape)")
        // Rung 2: the episode id IS a direct-media URL.
        if MediaURL.isDirectMedia(episode.id) {
            let stream = StreamInfo(url: episode.id,
                                    headers: detailStream?.headers ?? [:])
            DiagLog.log("preview", "probe rung=episode-direct outcome=direct-media")
            if let ok = playable(stream, rung: "episode-direct") { return ok }
            return nil
        }
        let request = PlaybackRequest(
            movie: movie,
            pluginId: pluginId,
            pluginName: pluginName,
            isManga: isManga,
            serverName: server.name,
            episode: episode,
            allEpisodes: server.episodes
        )
        if pluginId == "torrenthub" {
            // D4 — trailer FIRST, per the owner's ruling. The
            // investigation (BUILD-1.3.0-IMPL-REPORT) found the
            // torrenthub detail payload carries NO playable
            // trailer: parseMovieDetail surfaces no trailer
            // field, MovieDetail has no trailer field, and the
            // upstream meta's trailer data (Cinemeta/TPDB) is a
            // YouTube id with no tvOS-playable route in JTV.
            // So the torrent preview falls back to the
            // cached-clip ladder below.
            if episode.id.hasPrefix("http") {
                // MediaFusion / direct-URL episode: the C1
                // route classifies it to .video with no network
                // fetch (container suffix or MF credential host).
                if let resolution = try? await service.resolveEpisode(request),
                   case .video(let stream) = resolution {
                    DiagLog.log("preview", "probe rung=torrent-http outcome=video host=\(URL(string: stream.url)?.host ?? "?")")
                    return playable(stream, rung: "torrent-http")
                }
                DiagLog.log("preview", "probe rung=torrent-http outcome=no-video")
                return nil
            }
            if episode.id.hasPrefix("jtvhash:") {
                // Cached-clip fallback (D5): probe-only — a
                // preview may spend a probe, never a download.
                // resolveCachedOnly EXACTLY as-is (L-T12).
                // Gate fix pass (F-B1): this await runs INLINE
                // in the dwell task, so the epoch-bump
                // cancellation in play()/onDisappear cancels
                // THIS task — resolveCachedOnly's
                // between-provider Task.isCancelled checks then
                // stop it before Play's own resolve for the
                // same hash starts (no concurrent duplicate).
                let hash = String(episode.id.dropFirst("jtvhash:".count))
                if let stream = await DebridResolver.resolveCachedOnly(hash: hash) {
                    DiagLog.log("preview", "probe rung=cached-only outcome=video host=\(URL(string: stream.url)?.host ?? "?")")
                    return playable(stream, rung: "cached-only")
                }
                DiagLog.log("preview", "probe rung=cached-only outcome=not-cached")
                return nil
            }
            DiagLog.log("preview", "probe rung=torrent-shape outcome=unsupported-shape")
            return nil
        }
        // All other non-manga plugins: the probe-only façade
        // over the real resolve machinery (embed chain / direct
        // / torrenthub-C1 shapes), never consuming the Play
        // tap's prefetched embed.
        guard let resolution = await service.resolveEpisodeForPreview(request) else {
            DiagLog.log("preview", "probe rung=facade outcome=nil")
            return nil
        }
        switch resolution {
        case .video(let stream):
            DiagLog.log("preview", "probe rung=facade outcome=video host=\(URL(string: stream.url)?.host ?? "?")")
            return playable(stream, rung: "facade")
        case .manga:
            DiagLog.log("preview", "probe rung=facade outcome=manga")
            return nil
        case .embed:
            DiagLog.log("preview", "probe rung=facade outcome=embed-unpreviewable")
            return nil
        }
    }
}
