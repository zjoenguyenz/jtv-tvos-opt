import SwiftUI

private struct TVDetailConditionalFocusSection: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.focusSection()
        } else {
            content
        }
    }
}

private extension View {
    func detailFocusSection(if enabled: Bool) -> some View {
        modifier(TVDetailConditionalFocusSection(enabled: enabled))
    }
}

/// JTV tvOS Phase 2 — title Detail (the iOS MovieDetailView port,
/// survey §1.5) over a FULL-SCREEN backdrop with the theme's
/// Ultra treatment (owner amendment: backdrop full màn hình,
/// edge-to-edge, scrim from the theme tokens). Layout follows
/// mockup 05. Load is the iOS two-stage progressive load with
/// title-recovery healing; identity is navId for every store
/// write. Play actions build the exact iOS PlaybackRequest and
/// hand it to the PlaybackPresenter — the player cover's entry
/// point (video surfaces / the manga reader inside TVPlayerView).
/// Detail writes NO history (the player owns history writes,
/// and no playback has happened yet).
struct TVDetailView: View {
    let pluginId: String
    let movie: Movie
    var autoResume: Bool = false

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var presenter: PlaybackPresenter
    @EnvironmentObject private var session: PinSession
    @Environment(\.tvTheme) private var theme

    @State private var bundle: MovieService.DetailBundle?
    /// NEXT-D (1.3.0): the backdrop preview's resolved stream
    /// and its generation guard. Set ONLY by the dwell task in
    /// the loaded branch; cleared on retire, on Play, and on
    /// disappear (the host's teardown runs on dismantle).
    @State private var previewStream: StreamInfo?
    @State private var previewGeneration = 0
    /// L-T12 (1.3.1): the preview attempt is keyed to the FINAL
    /// (stage-2) detail identity — plugin|navId|loadGeneration
    /// plus a fingerprint of the server list — not to the load
    /// generation alone, so a stage-2 server swap re-arms the
    /// probe against real episodes and a stage-1 placeholder
    /// never consumes the one attempt.
    @State private var previewResolvedKey = ""
    /// Gate fix pass (F-B1): bumping this epoch is part of the
    /// preview dwell task's `.task(id:)` identity, so a bump
    /// CANCELS the in-flight dwell/probe task itself (SwiftUI
    /// cancels the superseded .task) — the task that is running
    /// the probe chain (façade group, resolveCachedOnly, or the
    /// direct torrent-http resolve, all awaited inline in
    /// runBackdropPreview) is the task that gets cancelled, so
    /// its cooperative Task.isCancelled checks fire and no
    /// probe work runs concurrently with Play's own resolve.
    /// play() and onDisappear both bump it. A task restarted by
    /// the bump re-checks previewResolvedKey, which play() marks
    /// resolved first, so it returns without re-probing.
    @State private var previewTaskEpoch = 0
    /// Gate fix pass 2 (F-B1-R3-2): the PLAY LATCH. Once
    /// play() has been tapped for THIS Detail instance, the
    /// backdrop preview never re-arms — regardless of later
    /// task-key changes. The epoch/resolved-key disarm alone
    /// had a hole: a stage-2 or healed detail swap landing
    /// AFTER the tap changes the fingerprint in the dwell
    /// task's identity, the restarted task computes a key ≠
    /// previewResolvedKey (which was marked for the detail as
    /// of the tap), and it re-probes behind the player cover.
    /// The latch is a plain @State on the view: it is set once
    /// in play(), never cleared by any detail-content update,
    /// and resets only when the Detail instance itself is
    /// recreated (a new navigation makes a new view with
    /// fresh @State).
    @State private var playLatched = false
    /// L-23 (1.3.8): true while a play intent is healing a
    /// stage-1 placeholder detail (see healedDetailForPlay) —
    /// the episode grid is inert for that span and a second
    /// play intent returns instead of double-healing. Play
    /// itself is NOT disabled: dropping its focus mid-heal
    /// would be a worse fault than the wait.
    @State private var isHealingPlay = false
    @AppStorage(TVPreviewSettings.defaultsKey) private var previewEnabled = true
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadGeneration = 0
    /// Gate fix pass (Round 1 on R2, Lens 2 F2): the manga
    /// reader's fix-9 discipline, ported — `detailAlive` is
    /// true while the screen is on, cleared in .onDisappear
    /// (which also bumps loadGeneration), and every post-await
    /// publish in load()/recoverByTitle — above all the
    /// auto-resume presentation — re-checks it together with
    /// Task.isCancelled and the generation.
    @State private var detailAlive = true
    @State private var recoveredId: String?
    @State private var didAutoResume = false
    @State private var selectedServer = 0
    @State private var descExpanded = false
    @FocusState private var playFocused: Bool
    @FocusState private var favFocused: Bool
    @FocusState private var resumeFocused: Bool
    @FocusState private var descFocused: Bool

    private var detail: MovieDetail? { bundle?.detail }
    private var navId: String { recoveredId ?? movie.id }
    private var isManga: Bool { plugins.installedPlugin(id: pluginId)?.manifest.isManga ?? false }
    private var isFavorite: Bool { favorites.isFavorite(pluginId: pluginId, movieId: navId) }
    private var historyRecord: HistoryRecord? { history.record(for: pluginId, movieId: navId) }
    private var hasPlayableEpisode: Bool {
        detail?.servers.contains { !$0.episodes.isEmpty } ?? false
    }

    private var backdropURL: String {
        if let detail {
            if !detail.backdropUrl.isEmpty { return detail.backdropUrl }
            if !detail.posterUrl.isEmpty { return detail.posterUrl }
            return movie.displayBackdrop
        }
        return movie.displayBackdrop
    }

    private func snapshotMovie(for detail: MovieDetail) -> Movie {
        var snap = detail.asMovie
        snap.id = navId
        return snap
    }

    var body: some View {
        // L-T04: the pre-fetch body follows the iOS-proven shape
        // — while the detail has not loaded, NO backdrop is
        // built (iOS MovieDetailView renders background +
        // spinner only until its detail arrives,
        // DetailView.swift:41–52, and mounts its backdrop
        // inside the loaded-content branch, :187). The
        // pre-fetch backdrop load at bucket 1920 was the one
        // item-data-driven subsystem inside the convicted
        // Detail-open crash window; it now enters only with
        // the loaded detail, exactly as on iOS.
        // Breadcrumb D3: this body was reached.
        DiagLog.log("detail", "body plugin=\(pluginId) movie=\(movie.id) backdrop=\(DiagLog.urlForLog(backdropURL))")
        return ZStack {
            if let detail {
                TVBackdropView(urlString: backdropURL, fallbackTitle: movie.title,
                               previewStream: previewStream,
                               previewGeneration: previewGeneration,
                               onPreviewRetired: { _ in
                                   // Gate fix pass (Round 1 on R2,
                                   // Lens 3 F1): DEFER the clear
                                   // until the 0.6 s fade-out
                                   // (TVComponents) has played —
                                   // clearing synchronously here
                                   // dismantled the host in the
                                   // same view update that started
                                   // the fade, so the fade never
                                   // rendered. The delayed clear
                                   // is generation-guarded: a new
                                   // preview (generation bumped),
                                   // a Play tap or disappear (both
                                   // clear immediately themselves,
                                   // unchanged) supersedes it.
                                   let retiredGeneration = previewGeneration
                                   Task { @MainActor in
                                       try? await Task.sleep(for: .milliseconds(700))
                                       guard previewGeneration == retiredGeneration else { return }
                                       previewStream = nil
                                   }
                               })
                    .ignoresSafeArea()
                    // NEXT-D D3: the dwell task lives ONLY in
                    // this loaded branch (FL-357/FL-364: nothing
                    // item-data-driven runs pre-detail).
                    // L-T12 (1.3.1): the key now includes the
                    // server-list fingerprint, so the stage-2
                    // swap (which changes no other key part)
                    // RESTARTS the task against the final
                    // detail; ≤1 preview resolve per final
                    // detail per Detail open.
                    .task(id: "\(pluginId)|\(navId)|\(loadGeneration)|\(Self.previewFingerprint(detail))|\(previewTaskEpoch)") {
                        await runBackdropPreview(detail: detail)
                    }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 36) {
                        headerBand(detail)
                        actionRow(detail)
                            .focusSection()
                        if let record = historyRecord, !record.episodeName.isEmpty {
                            resumeBanner(record: record, detail: detail)
                                .focusSection()
                        }
                        if hasVisibleMeta(detail) {
                            metaBlock(detail)
                        }
                        if !detail.description.isEmpty {
                            descBlock(detail)
                                .focusSection()
                        }
                        if !visibleCastEntries(detail).isEmpty {
                            castsBlock(detail)
                                .focusSection()
                        }
                        serversBlock(detail)
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 40)
                }
                .defaultFocus(hasPlayableEpisode ? $playFocused : $favFocused, true)
            } else if loadError != nil {
                // A-9 (1.3.9): this error state is the ONLY
                // focusable on the screen — its retry button
                // is the declared landing focus.
                TVErrorState(message: "Không tải được thông tin phim", onRetry: {
                    Task { await load() }
                }, retryIsDefaultFocus: true)
            } else if autoResume {
                // A-11 (1.3.9, F-11): a Continue Watching
                // reopen shows a MINIMAL state — spinner +
                // label, NO focusable button — while the
                // detail loads and the player presents itself.
                // The full loading state's retry button held
                // default focus, so an inertial OK during the
                // wait reloaded instead of waiting.
                VStack(spacing: 22) {
                    ProgressView()
                        .tint(theme.textPrimary)
                        .scaleEffect(1.5)
                    Text("Đang mở lại…")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TVLoadingState(onRetry: { Task { await load() } })
            }
        }
        .tvThemedBackground()
        .onAppear {
            detailAlive = true
            session.touch()
        }
        .onDisappear {
            // Gate fix pass (Lens 2 F2): leaving the screen
            // invalidates every in-flight load — bump the
            // generation and close the alive gate so a late
            // completion (or the auto-resume block) publishes
            // nothing, above all no player presentation.
            detailAlive = false
            loadGeneration += 1
            // Gate fix pass (F-B1): cancel the preview dwell /
            // probe task itself as the Detail disappears (the
            // epoch is part of its .task identity).
            previewTaskEpoch += 1
            // NEXT-D teardown: the preview player dies with the
            // screen (its host dismantles → pause + empty).
            previewStream = nil
        }
        .task(id: movie.id) { await load() }
        // L-T31 (1.3.4) — THE Menu arbiter for this surface
        // (FL-048 family): a pushed Detail owns its Menu
        // press explicitly and pops the owning stack straight
        // to its root ("Back là về đầu menu" — owner ruling
        // 2026-11-22). Before this, NO pushed surface had any
        // Menu handler: the press fell through to the
        // system's implicit NavigationStack pop, which the
        // 1.3.3 device log shows intermittently failing —
        // the app left the foreground instead of popping
        // (log_11: foreground losses at 15:39:34 on a javhd
        // detail, 15:40:21 on the sayhentai detail, 15:41:23
        // on a torrenthub detail — one shared mechanism, not
        // a per-plugin fault). Surfaces WITH an explicit
        // arbiter (the player cover, the manga reader inside
        // it) dismissed cleanly all session; now every pushed
        // surface has one. The arbiter is per-surface (not in
        // TVNavPath) so a future route that must special-case
        // Back can override at its own seam.
        .onExitCommand {
            // B-1 actor exception (owner ruling 2026-11-22
            // 15:56, Phase 2 amendment): a Detail opened VIA
            // the actor screen returns to it first — one pop —
            // while every other Detail keeps the L-T31
            // pop-to-root above. The seam is the route directly
            // beneath this Detail in the owning stack
            // (TVNavPath.isActorBeneathTop): the exception
            // follows the real navigation chain, so no state
            // has to be threaded into the route or the view.
            if nav.isActorBeneathTop {
                DiagLog.log("menu", "back-to-actor surface=detail plugin=\(pluginId)")
                nav.pop()
            } else {
                DiagLog.log("menu", "back-to-root surface=detail plugin=\(pluginId)")
                nav.popToRoot()
            }
        }
    }

    // MARK: Bands

    private func headerBand(_ detail: MovieDetail) -> some View {
        HStack(alignment: .bottom, spacing: 34) {
            TVRemoteImage(urlString: detail.posterUrl.isEmpty ? movie.posterUrl : detail.posterUrl,
                          bucket: 960)
                .frame(width: 184, height: 276)
                .clipShape(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 14) {
                Text(detail.title)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                if !detail.originName.isEmpty {
                    Text(detail.originName)
                        .font(.system(size: 27))
                        .foregroundStyle(theme.textDim)
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    if detail.year > 0 {
                        badge(String(detail.year), background: theme.accent, foreground: theme.onAccent)
                    }
                    if !detail.quality.isEmpty {
                        badge(detail.quality, background: theme.badgeQuality, foreground: .black)
                    }
                    if !detail.lang.isEmpty {
                        badge(detail.lang, background: Color.white.opacity(0.16), foreground: .white)
                    }
                    if detail.rating > 0 {
                        Text("★ \(String(format: "%.1f", detail.rating))")
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(theme.heroMeta)
                    }
                }
            }
            Spacer()
        }
    }

    private func badge(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
    }

    private func actionRow(_ detail: MovieDetail) -> some View {
        HStack(spacing: 20) {
            Button {
                playFirstEpisode(detail)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: isManga ? "book.fill" : "play.fill")
                        .font(.system(size: 27, weight: .bold))
                    Text(isManga ? "Đọc ngay" : "Phát ngay")
                        .font(.system(size: 30, weight: .bold))
                }
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 46)
                .padding(.vertical, 19)
                .background(Capsule().fill(theme.accent))
                .overlay(Capsule().strokeBorder(playFocused ? theme.focusRing : .clear,
                                                lineWidth: playFocused ? theme.ringWidth : 0))
            }
            .tvCardButton()
            .focused($playFocused)
            .disabled(!hasPlayableEpisode)

            Button {
                favorites.toggle(pluginId: pluginId, movie: snapshotMovie(for: detail))
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(isFavorite ? theme.accent : theme.textPrimary)
                    .frame(width: 78, height: 78)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.cardFill))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(favFocused ? theme.focusRing : theme.cardStroke,
                                      lineWidth: favFocused ? theme.ringWidth : 1))
            }
            .tvCardButton()
            .focused($favFocused)
            Spacer()
        }
    }

    private func resumeBanner(record: HistoryRecord, detail: MovieDetail) -> some View {
        Button {
            resume(record, detail: detail)
        } label: {
            HStack(spacing: 18) {
                Image(systemName: record.isManga ? "book.pages.fill" : "play.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Xem tiếp: \(record.episodeName)")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                    if record.isManga {
                        Text(mangaResumeText(record))
                            .font(.system(size: 22))
                            .foregroundStyle(theme.textDim)
                    } else if record.duration > 0 {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(theme.accent)
                                .frame(width: 520 * CGFloat(record.progress))
                        }
                        .frame(width: 520, height: 6)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.textFaint)
            }
            .padding(24)
            .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused($resumeFocused)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(resumeFocused ? theme.focusRing : theme.cardStroke,
                          lineWidth: resumeFocused ? theme.ringWidth : 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A-12 (1.3.9): the manga banner names the units the
    /// reader itself uses — the STRIP ("Ảnh i/n", n = the
    /// record's duration, the chapter's image count) and,
    /// when the tvOS aux store holds the in-strip page for
    /// this exact record, the page within the strip. The old
    /// text printed the strip NUMBER labelled as a page.
    private func mangaResumeText(_ record: HistoryRecord) -> String {
        let strip = Int(record.lastPosition) + 1
        let strips = Int(record.duration)
        var text = strips > 0 ? "Đã đọc tới ảnh \(strip)/\(strips)" : "Đã đọc tới ảnh \(strip)"
        if let segment = TVMangaPositionStore.segment(
            pluginId: record.pluginId, movieId: record.movie.id,
            episodeId: record.episodeId, imageIndex: Int(record.lastPosition)) {
            text += " • trang \(segment + 1) trong ảnh"
        }
        return text
    }

    /// L-T19 / FL-403 (owner ruling 2026-11-22): a metadata
    /// value that is raw markdown-link text must never reach
    /// the screen. missav's plugin formats linked fields as
    /// "[name](/vi/…)" (plugin parseMovieDetail), and the
    /// detail model carries those strings verbatim — printed
    /// as-is they spill over the whole screen (owner photo:
    /// the Thể loại row, the Đạo diễn row and every Diễn viên
    /// chip). The owner's ruling: remove those blocks
    /// ("dẹp bỏ cái chỗ thể loại này ở missav — những chỗ nào
    /// bị như vậy thì bỏ đi"). Suppression is by VALUE, so it
    /// removes exactly the sprawl and nothing else: clean
    /// values from the other plugins keep rendering exactly
    /// as the approved Phase 2 detail design draws them.
    ///
    /// L-T25 / FL-411 (1.3.3): the markdown test alone let
    /// javhd's PLAIN comma-joined category list through (owner
    /// photo: 18 site/category names, 172 chars, spilling past
    /// the right screen edge — "Javhd nên xoá bớt giống bên
    /// missav"). The design pass (DESIGN-133-DETAIL-SPRAWL.md
    /// §c) swept all 12 plugins — 9 can emit a long
    /// comma-joined list into a meta field — and fixed the
    /// rule by VALUE SHAPE, never by plugin id: a value is
    /// sprawl when it (1) contains markdown link syntax, or
    /// (2) splits into ≥ 10 comma items, or (3) is > 150
    /// characters with ≥ 5 comma items. The thresholds sit
    /// clear of every measured clean value (the approved
    /// design's Thể loại is 2 items / 16 chars; the largest
    /// legitimate-by-construction list in the sweep is
    /// torrenthub's 8-item capped cast) and catch the
    /// convicted 18-item / 172-char list on both new tests.
    /// Suppression hides the row (or block) — never truncates:
    /// the approved design contains no presentation for a
    /// long raw list.
    private func isSprawlValue(_ value: String) -> Bool {
        if value.contains("](") { return true }
        let items = value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if items.count >= 10 { return true }
        return value.count > 150 && items.count >= 5
    }

    private func hasVisibleMeta(_ detail: MovieDetail) -> Bool {
        // 1.22.19 (L-20): category/director are judged in
        // their sanitized display form (Models.plainDisplayText)
        // — the raw plugin markdown always tripped the "]("
        // sprawl test below and hid the rows entirely.
        [detail.episode_current, detail.categoryDisplay, detail.country, detail.directorDisplay]
            .contains { !$0.isEmpty && !isSprawlValue($0) }
    }

    private func visibleCastEntries(_ detail: MovieDetail) -> [CastEntry] {
        // Phase 2 (plan §2.2 — the L-T19/L-T25 collision): the
        // pre-Phase-2 rule ran the shape tests on the RAW casts
        // string, and any value containing "](" was sprawl by
        // definition — which hid exactly the routed casts of
        // missav / 123av / njav / topxx, the entries Phase 1
        // taught the plugins to emit. New rule: when the parse
        // yields at least one ROUTED entry, the entries surface
        // (routed chips open the actor screen; unrouted keep
        // the search behaviour). With no routed entry, the old
        // rule applies unchanged — a sprawl raw string hides
        // the whole Diễn viên block; a clean one keeps the
        // per-chip markdown filter as the second line.
        let entries = detail.castEntries
        if entries.contains(where: { $0.route != nil }) { return entries }
        if isSprawlValue(detail.casts) { return [] }
        return entries.filter { !isSprawlValue($0.name) }
    }

    private func metaBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            metaRow("Tiến độ", detail.episode_current)
            metaRow("Thể loại", detail.categoryDisplay)
            metaRow("Quốc gia", detail.country)
            metaRow("Đạo diễn", detail.directorDisplay)
            // Metadata overlay (1.3.8): the supplied fields,
            // in the design's detail-page order — metaRow
            // renders nothing for an empty value, so each
            // row exists only when an overlay hit supplied
            // it.
            metaRow("Hãng phim", detail.studioLine)
            metaRow("Phát hành", detail.releaseDate)
            metaRow("Thời lượng", detail.runtimeMinutes > 0 ? "\(detail.runtimeMinutes) phút" : "")
        }
    }

    @ViewBuilder
    private func metaRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty, !isSprawlValue(value) {
            HStack(alignment: .top, spacing: 20) {
                Text(label)
                    .font(.system(size: 26))
                    .foregroundStyle(theme.textFaint)
                    .frame(width: 200, alignment: .leading)
                Text(value)
                    .font(.system(size: 26))
                    .foregroundStyle(theme.textPrimary)
            }
        }
    }

    private func descBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TVSectionHeader(title: "Nội dung")
            Text(detail.description)
                .font(.system(size: 26))
                .foregroundStyle(theme.textDim)
                .lineLimit(descExpanded ? nil : 4)
            Button {
                descExpanded.toggle()
            } label: {
                Text(descExpanded ? "Thu gọn" : "Xem thêm")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .overlay(Capsule().strokeBorder(descFocused ? theme.focusRing : .clear,
                                                    lineWidth: descFocused ? theme.ringWidth : 0))
            }
            .tvCardButton()
            .focused($descFocused)
        }
    }

    private func castsBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title: "Diễn viên")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(visibleCastEntries(detail), id: \.self) { entry in
                        TVChip(title: entry.name, selected: false) {
                            castChipTapped(entry)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @Environment(TVNavPath.self) private var nav

    /// Phase 2 chip routing (plan §1/§2.3): a routed entry of
    /// a FULL-scope plugin opens that plugin's actor screen;
    /// everything else — SEARCH-ONLY plugins, unrouted names,
    /// NONE plugins — keeps the pre-Phase-2 behaviour exactly
    /// (the keyword-search destination).
    private func castChipTapped(_ entry: CastEntry) {
        if let route = entry.route, ActorScope.isFull(pluginId: pluginId) {
            nav.push(.actor(ActorRoute(pluginId: pluginId, name: entry.name, route: route)))
        } else {
            navPushSearch(entry.name)
        }
    }

    private func navPushSearch(_ name: String) {
        nav.push(.search(SearchRoute(pluginId: pluginId, keyword: name)))
    }

    @ViewBuilder
    private func serversBlock(_ detail: MovieDetail) -> some View {
        if detail.servers.isEmpty {
            Text(isManga ? "Chưa có chương nào." : "Chưa có tập nào.")
                .font(.system(size: 26))
                .foregroundStyle(theme.textDim)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 22) {
                    TVSectionHeader(title: isManga ? "Danh sách chương" : "Danh sách tập")
                    if detail.servers.count > 1 {
                        HStack(spacing: 14) {
                            ForEach(Array(detail.servers.enumerated()), id: \.offset) { index, server in
                                TVChip(title: server.name, selected: index == selectedServer) {
                                    selectedServer = index
                                }
                            }
                        }
                    }
                }
                let server = detail.servers[min(selectedServer, detail.servers.count - 1)]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isManga ? 200 : 150), spacing: 16)],
                          spacing: 16) {
                    ForEach(server.episodes) { episode in
                        TVEpisodeChip(name: episode.name,
                                      watched: historyRecord?.episodeId == episode.id) {
                            playEpisode(episode, server: server, detail: detail)
                        }
                    }
                }
                .disabled(isHealingPlay)
            }
            .detailFocusSection(if: detail.servers.count > 1 || !detail.servers[min(selectedServer, detail.servers.count - 1)].episodes.isEmpty)
        }
    }

    // MARK: Load (iOS two-stage + healing)

    /// F-C1: keep the grid's initial server in agreement with
    /// playFirstEpisode. If the clamped selected server has no
    /// episodes but some server does, move the selection to the
    /// first non-empty server (playFirstEpisode's own rule).
    /// A non-empty selection is never overridden, and when no
    /// server has episodes the selection is left untouched.
    private func selectFirstPlayableServerIfNeeded(servers: [EpisodeServer]) {
        guard !servers.isEmpty else { return }
        let sel = min(selectedServer, servers.count - 1)
        guard servers[sel].episodes.isEmpty,
              let firstPlayable = servers.firstIndex(where: { !$0.episodes.isEmpty }) else { return }
        selectedServer = firstPlayable
    }

    /// L-T12: identity of a detail's server list for the
    /// preview task key. Gate fix pass (F-B5): WIDENED to the
    /// FULL episode/server identity — every server's name plus
    /// EVERY episode's id, name and slug (the count is implied
    /// by the joined list) — not just the first episode id +
    /// count, under which a replacement that changed only
    /// later episodes (or URLs behind the same first id) never
    /// re-keyed and never re-probed. A stage-2 swap changes it;
    /// a re-render with the same servers does not.
    private static func previewFingerprint(_ detail: MovieDetail) -> String {
        detail.servers.map { server in
            server.name + "::" + server.episodes.map { "\($0.id)|\($0.name)|\($0.slug)" }
                .joined(separator: ";")
        }
        .joined(separator: ",")
    }

    private var previewKey: String {
        guard let detail else { return "" }
        return "\(pluginId)|\(navId)|\(loadGeneration)|\(Self.previewFingerprint(detail))"
    }

    /// L-T13 §5.0: Detail-load count breadcrumb (servers /
    /// episodes) so the next device log can convict the Lane B
    /// counts at the Detail surface too.
    private func logDetailCounts(_ detail: MovieDetail, stage: String) {
        let episodes = detail.servers.reduce(0) { $0 + $1.episodes.count }
        DiagLog.log("detail", "counts stage=\(stage) plugin=\(pluginId) servers=\(detail.servers.count) episodes=\(episodes)")
    }

    private func load() async {
        // L-T04 breadcrumb D5: Detail's load task started.
        DiagLog.log("detail", "load.begin plugin=\(pluginId) movie=\(movie.id)")
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        do {
            let first = try await service.detailMeta(pluginId: pluginId, movieId: movie.id)
            guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return }
            bundle = first
            logDetailCounts(first.detail, stage: "stage1")
            selectFirstPlayableServerIfNeeded(servers: first.detail.servers)
            isLoading = false
            warmEmbedPrefetch(detail: first.detail)
            if first.detail.servers.first?.episodes.first?.id.hasPrefix("jtvstreams:") == true {
                let full = await service.detailStreams(pluginId: pluginId, movieId: movie.id,
                                                       detail: first.detail)
                guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return }
                if full.servers != first.detail.servers {
                    bundle = MovieService.DetailBundle(detail: full, detailStream: first.detailStream)
                    logDetailCounts(full, stage: "stage2")
                    selectFirstPlayableServerIfNeeded(servers: full.servers)
                }
            }
        } catch {
            guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return }
            await recoverByTitle(generation: gen)
        }
        // Above all the auto-resume publish below: the user may
        // have backed out while the load was in flight — the
        // generation bump in .onDisappear, the alive flag and
        // cancellation must ALL still pass before the player
        // may be presented.
        guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return }
        if autoResume, !didAutoResume, let detail, let record = historyRecord {
            didAutoResume = true
            resume(record, detail: detail)
        }
    }

    private func recoverByTitle(generation gen: Int) async {
        do {
            let page = try await service.search(pluginId: pluginId, keyword: movie.title, page: 1)
            guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return }
            let target = TVSearchText.normalise(movie.title)
            let found = page.items.first { TVSearchText.normalise($0.title) == target }
                ?? (movie.id.isEmpty ? page.items.first : nil)
            guard let found else {
                guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return }
                loadError = "Không tải được thông tin phim"
                isLoading = false
                return
            }
            let healed = try await service.detail(pluginId: pluginId, movieId: found.id)
            guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return }
            recoveredId = found.id
            bundle = healed
            logDetailCounts(healed.detail, stage: "healed")
            selectFirstPlayableServerIfNeeded(servers: healed.detail.servers)
            favorites.repairMovieId(pluginId: pluginId, from: movie.id, title: movie.title, to: found.id)
            warmEmbedPrefetch(detail: healed.detail)
        } catch {
            guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return }
            loadError = "Không tải được thông tin phim"
            DiagLog.log("detail", "recover failed plugin=\(pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return }
        isLoading = false
    }

    private func warmEmbedPrefetch(detail: MovieDetail) {
        guard ["123av", "javhd", "avdbapi"].contains(pluginId), !isManga,
              let server = detail.servers.first, let episode = server.episodes.first else { return }
        let request = PlaybackRequest(
            movie: snapshotMovie(for: detail),
            pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: isManga,
            serverName: server.name,
            episode: episode,
            allEpisodes: server.episodes
        )
        service.prefetchEmbedResolution(request)
    }

    // MARK: Backdrop preview (NEXT-D D3/D4/D7, 1.3.0)

    /// The dwell task: sleeps 1.5 s (JoeTV's dwell), checks
    /// cancellation, and resolves AT MOST ONE preview per
    /// Detail open (generation-guarded). The kill switch (D6)
    /// returns immediately — Detail is then identical to the
    /// pre-preview build. A preview writes NO history and
    /// consumes NO embed prefetch.
    private func runBackdropPreview(detail: MovieDetail) async {
        guard previewEnabled else { return }
        // Gate fix pass 2 (F-B1-R3-2): the play latch is
        // checked FIRST among the arming gates — after a Play
        // tap this instance never arms again, whatever key a
        // later detail swap computes.
        guard !playLatched else {
            DiagLog.log("preview", "not armed outcome=play-latched")
            return
        }
        // L-T12 RC-3: a manga plugin has no video to preview —
        // never arm at all (no armed line, no dwell, no retire).
        guard !isManga else { return }
        // L-T12 RC-2: never arm on the stage-1 placeholder
        // detail (its only episode is a `jtvstreams:` stub).
        // The stage-2 swap changes the task key, which re-runs
        // this against the final detail — and this early return
        // does NOT consume the one attempt.
        if detail.servers.first?.episodes.first?.id.hasPrefix("jtvstreams:") == true {
            DiagLog.log("preview", "probe begin plugin=\(pluginId) shape=placeholder outcome=awaiting-stage2")
            return
        }
        let key = "\(pluginId)|\(navId)|\(loadGeneration)|\(Self.previewFingerprint(detail))"
        guard previewResolvedKey != key else { return }
        previewResolvedKey = key
        DiagLog.log("preview", "armed plugin=\(pluginId)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        previewGeneration += 1
        let generation = previewGeneration
        guard let stream = await resolvePreviewStream(detail: detail) else {
            // A superseded probe (Play tapped / screen left —
            // both bump the generation) publishes and logs
            // nothing behind the cover.
            guard !Task.isCancelled, generation == previewGeneration else { return }
            // Gate fix pass (F-B5): a re-keyed probe that comes
            // back nil must CLEAR any stream published under the
            // previous key — the old stream must not keep
            // replaying under the new generation while the new
            // detail has no playable preview.
            if previewStream != nil {
                previewStream = nil
                DiagLog.log("preview", "cleared stale stream after re-keyed probe outcome=nil")
            }
            DiagLog.log("preview", "retired reason=no-playable")
            return
        }
        // Gate fix pass 2 (F-B1-R3-2): the latch is also
        // re-checked at the publish point — a probe that was
        // already in flight when Play was tapped publishes
        // nothing behind the cover, even if its cancellation
        // somehow did not land.
        guard !Task.isCancelled, generation == previewGeneration, !playLatched else { return }
        previewStream = stream
    }

    /// Phase 2 (1.3.5): the probe body lives in TVPreviewProbe
    /// (extracted verbatim — see that file); Detail delegates
    /// with its own loaded state, the actor screen with the
    /// focused film's fetched detail. One implementation, so
    /// the two preview surfaces can never drift apart.
    private func resolvePreviewStream(detail: MovieDetail) async -> StreamInfo? {
        await TVPreviewProbe.resolve(
            service: service, pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: isManga, detail: detail,
            detailStream: bundle?.detailStream,
            movie: snapshotMovie(for: detail))
    }

    // MARK: Play intents (iOS §1.5, exact)

    /// L-23: the stage-1 placeholder predicate — the exact
    /// test load() uses to decide the stage-2 swap.
    private func isPlaceholder(_ detail: MovieDetail) -> Bool {
        detail.servers.first?.episodes.first?.id.hasPrefix("jtvstreams:") == true
    }

    /// L-23 heal (1.3.8): a play intent that lands while
    /// the detail is still the torrenthub stage-1
    /// placeholder awaits the shipped stage-2 expansion
    /// FIRST (the same call load() makes, published into
    /// `bundle` the same way, under the same generation /
    /// alive guards load() observes) and only then lets
    /// the caller build its request from the real list —
    /// the placeholder episode is a loading marker, never
    /// a playable target. Returns nil when the screen has
    /// moved on or the swapped detail still has no
    /// playable episode (stage 2 failed or came back
    /// empty): no player is presented and the page keeps
    /// its loading affordance.
    private func healedDetailForPlay(_ detail: MovieDetail) async -> MovieDetail? {
        let gen = loadGeneration
        isHealingPlay = true
        defer { isHealingPlay = false }
        let full = await service.detailStreams(pluginId: pluginId, movieId: movie.id, detail: detail)
        guard gen == loadGeneration, detailAlive, !Task.isCancelled else { return nil }
        if full.servers != detail.servers, let current = bundle {
            bundle = MovieService.DetailBundle(detail: full, detailStream: current.detailStream)
            logDetailCounts(full, stage: "stage2-heal")
            selectFirstPlayableServerIfNeeded(servers: full.servers)
        }
        let healed = bundle?.detail ?? full
        guard let first = healed.servers.first(where: { !$0.episodes.isEmpty })?.episodes.first,
              !first.id.hasPrefix("jtvstreams:") else { return nil }
        return healed
    }

    private func playFirstEpisode(_ detail: MovieDetail) {
        // L-23: heal a stage-1 placeholder before building
        // the request; a second tap while a heal is in
        // flight is a no-op (the grid is inert meanwhile).
        if isPlaceholder(detail) {
            guard !isHealingPlay else { return }
            Task {
                guard let healed = await healedDetailForPlay(detail) else { return }
                playFirstEpisodeNow(healed)
            }
            return
        }
        playFirstEpisodeNow(detail)
    }

    private func playFirstEpisodeNow(_ detail: MovieDetail) {
        guard let serverIndex = detail.servers.firstIndex(where: { !$0.episodes.isEmpty }),
              let episode = detail.servers[serverIndex].episodes.first else { return }
        let server = detail.servers[serverIndex]
        selectedServer = serverIndex
        let known = bundle?.detailStream.url ?? ""
        play(episode: episode, server: server, detail: detail, startPosition: 0,
             knownStreamURL: MediaURL.isDirectMedia(known) ? known : "")
    }

    /// Episode-chip tap entry. In the placeholder state
    /// the grid shows exactly one stub cell, so the tap
    /// heals and then takes the default pick — the stub's
    /// only referent. Resume does NOT pass through here:
    /// it calls play() directly with a real episode id and
    /// is never diverted by the heal.
    private func playEpisode(_ episode: Episode, server: EpisodeServer, detail: MovieDetail) {
        if isPlaceholder(detail) {
            guard !isHealingPlay else { return }
            Task {
                guard let healed = await healedDetailForPlay(detail) else { return }
                playFirstEpisodeNow(healed)
            }
            return
        }
        play(episode: episode, server: server, detail: detail,
             startPosition: 0, knownStreamURL: "")
    }

    private func resume(_ record: HistoryRecord, detail: MovieDetail) {
        guard let server = detail.servers.first(where: { $0.name == record.serverName })
                ?? detail.servers.first else { return }
        selectedServer = detail.servers.firstIndex { $0.id == server.id } ?? 0
        let episode = server.episodes.first { $0.id == record.episodeId }
            ?? Episode(id: record.episodeId, name: record.episodeName, slug: record.episodeId)
        play(episode: episode, server: server, detail: detail,
             startPosition: record.lastPosition, knownStreamURL: record.streamURL)
    }

    private func play(episode: Episode, server: EpisodeServer, detail: MovieDetail,
                      startPosition: Double, knownStreamURL: String) {
        let request = PlaybackRequest(
            movie: snapshotMovie(for: detail),
            pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: isManga,
            serverName: server.name,
            episode: episode,
            allEpisodes: server.episodes,
            startPosition: startPosition,
            knownStreamURL: knownStreamURL,
            fallbackHeaders: bundle?.detailStream.headers ?? [:],
            switchList: switchShortlist(current: episode, detail: detail)
        )
        // NEXT-D teardown: the preview must be fully dead
        // before the real player presents (two live players is
        // the audio-leak / decoder-contention class). Clearing
        // the stream dismantles the host synchronously with
        // this view update, ahead of the cover.
        // Review-gate fix (1.3.0): invalidate any IN-FLIGHT
        // preview resolve FIRST — bump the generation and mark
        // this load's preview superseded, so a late completion's
        // guard fails and nothing publishes behind the cover.
        previewGeneration += 1
        previewResolvedKey = previewKey
        // Gate fix pass 2 (F-B1-R3-2): latch the preview off
        // for the rest of this Detail instance's life (see
        // the playLatched declaration) — set in the same update
        // as the generation/resolved-key disarm above, so no
        // restarted dwell task can slip between them.
        playLatched = true
        previewStream = nil
        // Gate fix pass (F-B1): cancel the preview dwell/probe
        // TASK itself on Play — the epoch bump changes its
        // .task(id:) identity, SwiftUI cancels the superseded
        // task, and the task cancelled is the one running the
        // probe chain (so resolveCachedOnly's between-provider
        // Task.isCancelled checks and the façade group's
        // cancellation fire, and the probe cannot run
        // concurrently with Play's own resolve for the same
        // hash). The restarted task sees previewResolvedKey
        // already set above and returns without re-probing.
        previewTaskEpoch += 1
        // L-T04 probe breadcrumb P0: the tap reached Detail's
        // play entry — the hand-off to the presenter is next.
        DiagLog.log("player", "tap.received plugin=\(pluginId) episode=\(episode.id)")
        // L-T23 (1.3.3) gate fix (Round 1, Lens C C-1): arm
        // measured auto-selection ONLY when the started
        // episode is this detail's DEFAULT pick — the first
        // non-empty server's first episode, exactly
        // playFirstEpisode's target. A chip tap on another
        // server (even its first episode) and a history
        // resume on another server are deliberate picks and
        // are never armed. The bit rides TVAutoMeasureArming
        // (PlaybackRequest and the presenter are shared core
        // and grow no TV-only fields), written in this same
        // update as the presenter hand-off.
        let defaultEpisodeID = detail.servers
            .first(where: { !$0.episodes.isEmpty })?.episodes.first?.id
        TVAutoMeasureArming.arm(requestID: request.id,
                                armed: defaultEpisodeID != nil
                                    && defaultEpisodeID == episode.id)
        presenter.request = request
    }

    /// The request's switchList, by plugin shape: javhd —
    /// L-T23 auto-selection candidates (rich mirror list);
    /// every other multi-server plugin — L-T30 (1.3.4)
    /// auto-selection candidates (cross-server correspondents
    /// of the started episode); torrenthub — the in-player
    /// panel's shortlist (iOS §1.5). Single-server non-javhd
    /// titles: empty (no auto-selection, panel falls back to
    /// allEpisodes — unchanged).
    private func switchShortlist(current: Episode, detail: MovieDetail) -> [Episode] {
        if pluginId == "javhd" {
            // L-T23 (1.3.3): AUTO-SELECTION candidates for the
            // player session's measured pick — every source of
            // the title across ALL servers, in measurement
            // priority order: each other server's first
            // episode (the family representatives — different
            // CDNs, the diversity that matters), then the
            // current server's remaining mirrors, then every
            // other server's remaining episodes. Deduped, the
            // started episode excluded, capped at 12. The
            // session measures a prefix of this list serially
            // at Play and may auto-switch to a measured-better
            // entry on a stall; the in-player panel is NOT fed
            // from this list (it keeps the current server's
            // episodes — see TVPlayerSession.switchTargets).
            let currentServer = detail.servers.first { server in
                server.episodes.contains { $0.id == current.id }
            }
            var seen: Set<String> = [current.id]
            var list: [Episode] = []
            func add(_ episode: Episode) {
                if seen.insert(episode.id).inserted { list.append(episode) }
            }
            for server in detail.servers where server.id != currentServer?.id {
                if let first = server.episodes.first { add(first) }
            }
            if let currentServer {
                for episode in currentServer.episodes { add(episode) }
            }
            for server in detail.servers where server.id != currentServer?.id {
                for episode in server.episodes { add(episode) }
            }
            return Array(list.prefix(12))
        }
        if pluginId != "torrenthub" {
            // L-T30 (1.3.4): AUTO-SELECTION candidates for
            // every OTHER multi-server plugin (owner ruling
            // 2026-11-22: "Khi mở bất kỳ phim nào nó chạy bản
            // nguồn trước mới chạy phim. Chỉ chọn ngầm thôi,
            // ưu tiên nguồn khoẻ theo tính toán của app trước
            // đây"). The candidate on each OTHER server is the
            // correspondent of the started episode — the SAME
            // episode on another source — matched by NAME
            // ONLY: the episode's identity on that server must
            // be verified, never assumed. There is no
            // positional guess and no first-episode fallback
            // (gate 1.3.4 Round 1, Lens B B-1: either can pick
            // a DIFFERENT episode — a misaligned or shorter
            // server list makes the same index, or the first
            // slot, another episode entirely — and a
            // measured-best wrong candidate would be silently
            // played). A server with no name-matching episode
            // contributes NO candidate. The current
            // server's other episodes are NEVER candidates in
            // this branch: within one server, episodes are
            // indistinguishable from series episodes (Tập 2,
            // 3…) at this seam, and silently starting a
            // different episode is the one failure this feature
            // must never produce. (javhd above keeps its
            // richer list: its servers carry the same film's
            // mirror files, proven in 1.3.3.) Single-server
            // titles get no candidates and are unchanged. The
            // in-player panel is NOT fed from this list (see
            // TVPlayerSession.switchTargets). torrenthub is
            // excluded: its switchList is the panel shortlist
            // below and its source choice is the provider
            // machinery — resolving its hash episodes here
            // could start debrid downloads, which a silent
            // background measurement must never do. Manga is
            // excluded: chapters are not sources.
            guard !isManga, detail.servers.count > 1,
                  let currentServer = detail.servers.first(where: { server in
                      server.episodes.contains { $0.id == current.id }
                  })
            else { return [] }
            var seen: Set<String> = [current.id]
            var list: [Episode] = []
            for server in detail.servers where server.id != currentServer.id {
                // Identity-verified correspondent ONLY (see
                // the branch comment above): an exact name
                // match, or no candidate from this server.
                let correspondent = server.episodes.first { $0.name == current.name }
                if let correspondent, seen.insert(correspondent.id).inserted {
                    list.append(correspondent)
                }
            }
            return Array(list.prefix(12))
        }
        // torrenthub (unchanged): all servers ranked ⭐-named
        // first → "MediaFusion" → rest, episodes flattened,
        // deduped by episode id, [current] + the next four —
        // the in-player panel's shortlist (iOS §1.5).
        let rankedServers = detail.servers.sorted { a, b in
            func rank(_ s: EpisodeServer) -> Int {
                if s.name.contains("⭐") { return 0 }
                if s.name == "MediaFusion" { return 1 }
                return 2
            }
            return rank(a) < rank(b)
        }
        var seen = Set<String>()
        var merged: [Episode] = []
        for episode in rankedServers.flatMap(\.episodes) where seen.insert(episode.id).inserted {
            merged.append(episode)
        }
        let others = merged.filter { $0.id != current.id }
        return [current] + Array(others.prefix(4))
    }
}

// MARK: - Episode chip

private struct TVEpisodeChip: View {
    let name: String
    let watched: Bool
    let onSelect: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            onSelect()
        } label: {
            Text(name)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(watched ? theme.accent : theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused($isFocused)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.14) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : (watched ? theme.accent.opacity(0.6) : theme.cardStroke),
                          lineWidth: isFocused ? theme.ringWidth : 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
