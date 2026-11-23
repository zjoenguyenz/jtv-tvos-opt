import Foundation

/// Metadata overlay (1.22.20 / 1.3.8) — design:
/// METADATA-OVERLAY-DESIGN.md §5. A shared-data layer keyed
/// by film CODE that upgrades DISPLAY metadata only:
/// standard English title, correct actress names, studio,
/// release date, genres, clean cover. Playback is
/// structurally out of scope — the overlay file's schema
/// carries no playback-shaped field (the harvester
/// validator rejects them data-side), and the merge below
/// touches nothing but the display fields named in §5.3.
///
/// Data flow (§5.4): at the first display-model
/// construction of a launch, the on-disk cache loads and
/// ONE fetch of `metadata/overlay-v1.json` runs from the
/// jtv-source data repo (the same unauthenticated channel
/// as plugins.json, beside it). A successful fetch
/// replaces the entry set and rewrites the cache; any
/// failure — no file, bad JSON, transport error — leaves
/// whatever is loaded (the last-good cache, or nothing on
/// a first install) and the plugin's own data on screen.
/// No user-visible error exists anywhere in this file;
/// the only trace is a DiagLog counter line.
///
/// Merge point (§5.4.3): MovieService applies `merged`
/// where display models are constructed — list/search
/// pages and the detail record — after plugin parse,
/// before render. The cache there stores the RAW parse,
/// so an overlay that lands mid-session applies from the
/// next read on. Both shells carry this file
/// byte-identical (CORE-SYNC); the merge semantics are
/// therefore identical by construction.
enum MetadataOverlay {

    // MARK: - Schema (design §5.2, v1)

    struct Entry: Codable {
        var code: String = ""
        var contentId: String = ""
        /// Nullable by design: very new entries sit in the
        /// dataset with their translation pending (§2) — a
        /// null title must never erase the plugin's title.
        var titleEn: String? = nil
        var actresses: [String] = []
        var studio: String? = nil
        var label: String? = nil
        var series: String? = nil
        var director: String? = nil
        var releaseDate: String? = nil
        var runtimeMinutes: Int? = nil
        var genres: [String] = []
        var cover: String? = nil
        // `trailer_sample` is deliberately NOT decoded:
        // trailer playback from overlay data is unverified
        // (design §3.4) and out of scope for this round, so
        // the app never holds the value at all.

        enum CodingKeys: String, CodingKey {
            case code, actresses, studio, label, series, director, genres, cover
            case contentId = "content_id"
            case titleEn = "title_en"
            case releaseDate = "release_date"
            case runtimeMinutes = "runtime_minutes"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
            contentId = try c.decodeIfPresent(String.self, forKey: .contentId) ?? ""
            titleEn = try c.decodeIfPresent(String.self, forKey: .titleEn) ?? nil
            actresses = try c.decodeIfPresent([String].self, forKey: .actresses) ?? []
            studio = try c.decodeIfPresent(String.self, forKey: .studio) ?? nil
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? nil
            series = try c.decodeIfPresent(String.self, forKey: .series) ?? nil
            director = try c.decodeIfPresent(String.self, forKey: .director) ?? nil
            releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate) ?? nil
            runtimeMinutes = try c.decodeIfPresent(Int.self, forKey: .runtimeMinutes) ?? nil
            genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
            cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? nil
        }
    }

    private struct OverlayFile: Codable {
        var version: Int = 1
        var entries: [String: Entry] = [:]

        enum CodingKeys: String, CodingKey { case version, entries }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            entries = try c.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        }
    }

    // MARK: - Store (launch fetch + disk cache)

    @MainActor private static var entries: [String: Entry] = [:]
    @MainActor private static var didStart = false

    @MainActor private static var overlayURLString: String {
        PluginManager.defaultSourceURL.replacingOccurrences(
            of: "plugins.json", with: "metadata/overlay-v1.json")
    }

    @MainActor private static var cacheFileURL: URL {
        PluginManager.pluginsDirectory.appendingPathComponent("metadata-overlay-v1.json")
    }

    /// First merge call of the launch: load the disk cache
    /// synchronously (so a warm launch shows overlay data
    /// from the first page) and kick the one launch fetch.
    @MainActor
    private static func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        if let data = try? Data(contentsOf: cacheFileURL),
           let file = try? JSONDecoder().decode(OverlayFile.self, from: data) {
            entries = Self.normalised(file.entries)
        }
        Task { await refresh() }
    }

    @MainActor
    private static func refresh() async {
        do {
            let text = try await Net.fetchText(overlayURLString)
            guard let data = text.data(using: .utf8),
                  let file = try? JSONDecoder().decode(OverlayFile.self, from: data) else {
                DiagLog.log("overlay", "fetch failed kind=decode")
                return
            }
            entries = Self.normalised(file.entries)
            try? text.write(to: cacheFileURL, atomically: true, encoding: .utf8)
            DiagLog.log("overlay", "entries=\(entries.count)")
        } catch {
            let err = error as NSError
            DiagLog.log("overlay", "fetch failed kind=\(err.domain)#\(err.code)")
        }
    }

    /// Entry keys are stored normalised (uppercase, trimmed)
    /// so lookups never depend on the file's casing (§5.4.2).
    private static func normalised(_ raw: [String: Entry]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        out.reserveCapacity(raw.count)
        for (key, entry) in raw {
            out[key.uppercased().trimmingCharacters(in: .whitespaces)] = entry
        }
        return out
    }

    // MARK: - Lookup (dual-key, §5.4.2)

    /// (a) the exact code; (b) the digit-normalised code —
    /// leading zeros in the numeric part stripped
    /// (`PRED-0792` → `PRED-792`), which rescues avdbapi's
    /// zero-padded variants without any data-side
    /// duplication. A code with no digits part, or one
    /// that is all zeros, has no second key.
    @MainActor
    static func entry(forCode code: String) -> Entry? {
        startIfNeeded()
        if let hit = entries[code] { return hit }
        let parts = code.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let digits = parts[1]
        let stripped = digits.drop(while: { $0 == "0" })
        guard stripped.count != digits.count, !stripped.isEmpty else { return nil }
        return entries["\(parts[0])-\(stripped)"]
    }

    @MainActor
    private static func entry(for movieId: String, title: String) -> Entry? {
        guard let code = BaseCode.extract(movieId: movieId, title: title) else { return nil }
        return entry(forCode: code)
    }

    // MARK: - Merge (§5.3 precedence)

    /// List-cell merge: the overlay wins the title (when
    /// its title is non-null — a pending-translation entry
    /// never erases the plugin's) and the cover. Identity,
    /// year, quality and every other field are the
    /// plugin's, untouched.
    @MainActor
    static func merged(_ movie: Movie) -> Movie {
        guard let entry = entry(for: movie.id, title: movie.title) else { return movie }
        var merged = movie
        if let title = entry.titleEn, !title.isEmpty { merged.title = title }
        if let cover = entry.cover, !cover.isEmpty {
            merged.posterUrl = cover
            if merged.backdropUrl.isEmpty { merged.backdropUrl = cover }
        }
        return merged
    }

    @MainActor
    static func merged(_ page: ListPage) -> ListPage {
        startIfNeeded()
        guard !entries.isEmpty else { return page }
        return ListPage(items: page.items.map { merged($0) }, pagination: page.pagination)
    }

    /// Detail merge: the overlay wins title / actresses /
    /// cover / genres, and supplies studio / label /
    /// series / director / release date / runtime where
    /// the plugin's value is null or empty. Per-field
    /// fallthrough otherwise. Servers, episodes and every
    /// playback-shaped field are never touched.
    ///
    /// Actress route preservation: the overlay's names are
    /// authoritative, but a name that matches one of the
    /// plugin's routed cast entries (ActorName's
    /// normalised-equal gate — the §13 standard) keeps
    /// that entry's route, re-emitted in the plugins'
    /// `[name](route)` convention, so the actor pages the
    /// routed chips feed keep working with the corrected
    /// names. Unmatched names stay bare (search chips),
    /// exactly like a route-less plugin cast.
    @MainActor
    static func merged(_ detail: MovieDetail) -> MovieDetail {
        guard let entry = entry(for: detail.id, title: detail.title) else { return detail }
        var merged = detail
        if let title = entry.titleEn, !title.isEmpty { merged.title = title }
        if !entry.actresses.isEmpty {
            merged.casts = Self.mergedCasts(actresses: entry.actresses, pluginCasts: detail.casts)
        }
        if let cover = entry.cover, !cover.isEmpty {
            merged.posterUrl = cover
            if merged.backdropUrl.isEmpty { merged.backdropUrl = cover }
        }
        if !entry.genres.isEmpty {
            merged.category = entry.genres.joined(separator: ", ")
        }
        if detail.directorDisplay.isEmpty, let director = entry.director, !director.isEmpty {
            merged.director = director
        }
        if let studio = entry.studio, !studio.isEmpty { merged.studio = studio }
        if let label = entry.label, !label.isEmpty { merged.label = label }
        if let series = entry.series, !series.isEmpty { merged.series = series }
        if let releaseDate = entry.releaseDate, !releaseDate.isEmpty { merged.releaseDate = releaseDate }
        if let runtime = entry.runtimeMinutes, runtime > 0 { merged.runtimeMinutes = runtime }
        return merged
    }

    private static func mergedCasts(actresses: [String], pluginCasts: String) -> String {
        let pluginEntries = MovieDetail.parseCastEntries(pluginCasts)
        // 1==1 positional pairing (1.22.21): a single-cast
        // film has ONE actress — when both lists hold exactly
        // one entry, the two names are forms of the same
        // person (the translated-form case: the plugin's
        // locale name vs the overlay's romaji canonical
        // name), so the overlay name keeps the plugin entry's
        // route instead of landing bare and degrading the
        // chip to keyword search. Multi-cast films keep the
        // normalize-equal gate below, unchanged.
        if actresses.count == 1, pluginEntries.count == 1,
           let route = pluginEntries[0].route {
            return "[\(actresses[0])](\(route))"
        }
        return actresses.map { name in
            if let match = pluginEntries.first(where: { ActorName.matches($0.name, name) }),
               let route = match.route {
                return "[\(name)](\(route))"
            }
            return name
        }.joined(separator: ", ")
    }
}
