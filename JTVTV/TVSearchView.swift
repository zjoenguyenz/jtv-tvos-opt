import SwiftUI

/// JTV tvOS Phase 2 — Search (plan §4.4 + the owner's Netflix
/// ruling, mechanism learned from JoeTV — study §3): ONE search
/// surface for every section; as each letter is typed, results
/// paint INSTANTLY from the data already on the device (the
/// active plugin's loaded home pool + favourites + history),
/// and the plugin's server results merge in behind them. 300 ms
/// debounce, request IDs on every publish (FL-232), dedupe by
/// id, exact matches hoisted. No facet/filter panel anywhere.
/// The recent-searches contract is the iOS one exactly
/// (survey §1.4): key `jtv_recent_searches`, max 10.
/// L-T14 / FL-384 (1.3.1): the input surface is the app's own
/// letter strip (TVLetterStrip below, mechanics learned from
/// JoeTV's JoeLetterStrip) under a DISPLAY-ONLY query row —
/// there is no native TextField on this screen, because on
/// tvOS focusing one summons Apple's full-screen keyboard and
/// hides the results the rounds paint until "done". Typing IS
/// the search: every strip edit mutates `query`, and the
/// existing .onChange → scheduleSearch() machinery runs the
/// round exactly as before.

private let recentSearchesKey = "jtv_recent_searches"

private struct TVConditionalFocusSection: ViewModifier {
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
    func focusSection(if enabled: Bool) -> some View {
        modifier(TVConditionalFocusSection(enabled: enabled))
    }
}

/// Focus identity for the letter strip (L-T14): a key, whose
/// id IS its label ("a"…"z", "1"…"0", "space", "del", "mode"),
/// or the query row's clear affordance ("clear"). JoeTV's
/// twin enum also carries a `.back` case for its search
/// *layer's* Quay lại button; JTV search is a tab root with
/// no layer to go back from, so that case is dropped
/// (DIAG-131-SEARCH §6.2.2).
private enum TVSearchKeyFocus: Hashable {
    case key(String)
}

enum TVSearchText {
    static func normalise(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func loadRecents() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
    }

    static func recordRecent(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = loadRecents()
        list.removeAll { $0.lowercased() == trimmed.lowercased() }
        list.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: recentSearchesKey)
    }

    static func clearRecents() {
        UserDefaults.standard.removeObject(forKey: recentSearchesKey)
    }
}

struct TVSearchView: View {
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var session: PinSession
    @Environment(TVHomeStore.self) private var store
    @Environment(TVNavPath.self) private var nav
    @Environment(\.tvTheme) private var theme

    @State private var query = ""
    @State private var recents: [String] = []
    @State private var results: [Movie] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var didSearch = false
    /// §13.13 amendment: the cross-source actress probe's
    /// verdict for the current term — when set, the pinned
    /// actor row renders above the film grid. Written only
    /// by the generation-guarded probe task; the row NEVER
    /// requests focus (see TVActorProbeRow).
    @State private var actorMatch: ActorProbeResult?
    @State private var probeTask: Task<Void, Never>?
    @State private var serverPage = 0
    @State private var serverTotalPages = 1
    @State private var isLoadingMore = false
    @State private var generation = 0
    @State private var debounceTask: Task<Void, Never>?
    // Gate fix pass 3 (C-R4-1): the strip's mode, hoisted
    // from TVLetterStrip's own @State so the entry
    // .defaultFocus below can be mode-aware. The strip
    // instance (and this state) survives Detail pushes and
    // tab excursions, so a re-entry with nil focus can find
    // the strip still in symbols mode — the destination must
    // be chosen against THIS mode, not the fresh-entry one.
    @State private var stripSymbols = false
    @FocusState private var keyFocus: TVSearchKeyFocus?
    @FocusState private var clearHistoryFocused: Bool
    /// A-10 (1.3.9): two-tap confirm for clearing the search
    /// history (the TVLibraryClearButton discipline).
    @State private var clearHistoryArmed = false
    @State private var clearHistoryDisarmTask: Task<Void, Never>?

    private var activeId: String { plugins.activePlugin?.id ?? "" }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            sourceBand
            fieldBand
            letterStrip
            content
        }
        .tvThemedBackground()
        // Gate fix pass 3 (C-R4-1): the entry default focus
        // is mode-aware. In letters mode it stays "a" (the
        // sensible typing start on a fresh entry). In symbols
        // mode "a" has NO matching rendered view (the symbols
        // set is digits + `- ' . & :`), so a surviving strip
        // re-entered with nil focus would consult a
        // mode-absent destination — the C1 mechanism confined
        // to the re-entry path. "mode" is rendered outside
        // the mode-swapped letter row and exists in BOTH
        // modes (the same mode-persistent destination the
        // clear action uses), so the declared destination
        // always has a matching view for the strip's current
        // mode.
        .defaultFocus($keyFocus, stripSymbols ? .key("mode") : .key("a"))
        .onAppear {
            session.touch()
            recents = TVSearchText.loadRecents()
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: plugins.activePluginId) { _, _ in scheduleSearch() }
    }

    // MARK: Bands

    private var sourceBand: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let active = plugins.activePlugin {
                HStack(spacing: 14) {
                    CachedAsyncImage(urlString: active.manifest.iconUrl)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text("Tìm trong nguồn \(active.manifest.name)")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    if isSearching {
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(plugins.visiblePlugins) { plugin in
                        TVChip(title: plugin.manifest.name,
                               iconURL: plugin.manifest.iconUrl,
                               badge18: plugins.isAdult(plugin.id),
                               selected: plugin.id == plugins.activePluginId) {
                            plugins.activePluginId = plugin.id
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 28)
        .focusSection(if: !plugins.visiblePlugins.isEmpty)
    }

    /// The query row (L-T14): DISPLAY-ONLY. It shows the query
    /// the strip is building — never a TextField, never itself
    /// focused as a field — in the screen's existing fieldBar
    /// chrome. The one focusable in the row is the clear
    /// affordance at its trailing edge (shown only while the
    /// query is non-empty); it clears the query, and the empty
    /// term re-arms the round machinery back to suggestions.
    /// Recent-term recording is NOT here any more: there is no
    /// submit in the strip model, so recording stays on the
    /// existing result-tap hook in `content` (TVPosterGrid's
    /// onSelect), which records a term exactly once when a
    /// search ends in a tap — a typed-but-never-tapped term is
    /// not recorded (DIAG-131-SEARCH §6.2.4).
    private var fieldBand: some View {
        HStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.textFaint)
            Text(query.isEmpty ? "Tìm phim, truyện…" : query)
                .font(.system(size: 30))
                .foregroundStyle(query.isEmpty ? theme.textFaint : theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !query.isEmpty {
                Button {
                    // Gate fix pass (C-F1): the clear button
                    // removes ITSELF from the hierarchy in the
                    // same update that empties the query, so the
                    // focus destination is declared HERE, in the
                    // same state update: focus relocates
                    // deterministically to a strip key instead
                    // of wherever the focus engine happens to
                    // land.
                    // Gate fix pass 2 (C1): the destination must
                    // exist in the strip's CURRENT mode — "a"
                    // does not exist in symbols mode (its set is
                    // digits + `- ' . & :`), which left the
                    // relocation indeterminate there. "mode" is
                    // rendered outside the mode-swapped letter
                    // row and is present in BOTH modes, so this
                    // one destination is always a real view at
                    // the moment of the clear.
                    keyFocus = .key("mode")
                    query = ""
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Xoá")
                            .font(.system(size: 24, weight: .semibold))
                    }
                    .foregroundStyle(keyFocus == .key("clear") ? .black : theme.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(keyFocus == .key("clear") ? theme.focusRing : .clear))
                }
                .tvCardButton()
                .focused($keyFocus, equals: .key("clear"))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.fieldBar))
        .padding(.horizontal, 80)
        .padding(.top, 22)
        .focusSection()
    }

    /// The letter strip, directly under the query row: typing
    /// lives here, always visible, so the grid below repaints
    /// while the owner types (the Netflix behaviour). Its own
    /// .focusSection() is declared inside TVLetterStrip.
    private var letterStrip: some View {
        TVLetterStrip(query: $query, symbols: $stripSymbols, focus: $keyFocus)
            .padding(.horizontal, 80)
            .padding(.top, 18)
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            suggestions
        } else if let searchError, results.isEmpty, actorMatch == nil {
            TVErrorState(message: searchError) { scheduleSearch() }
        } else if didSearch && results.isEmpty && !isSearching && actorMatch == nil {
            TVEmptyState(icon: "magnifyingglass", title: "Không tìm thấy kết quả")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if let actorMatch {
                        TVActorProbeRow(name: trimmedQuery, match: actorMatch) {
                            TVSearchText.recordRecent(trimmedQuery)
                            recents = TVSearchText.loadRecents()
                            nav.push(.actor(ActorRoute(pluginId: actorMatch.pluginId, name: trimmedQuery, route: actorMatch.route)))
                        }
                    }
                    TVPosterGrid(items: results, pluginId: activeId,
                                 isLoadingMore: isLoadingMore,
                                 onSelect: { _ in
                                     TVSearchText.recordRecent(trimmedQuery)
                                     recents = TVSearchText.loadRecents()
                                 },
                                 onLoadMore: { Task { await loadMoreServer() } })
                        .focusSection(if: !results.isEmpty)
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 30)
            }
        }
    }

    private var suggestions: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if recents.isEmpty {
                    Text("Nhập tên phim hoặc truyện để tìm trong nguồn đang chọn.")
                        .font(.system(size: 26))
                        .foregroundStyle(theme.textDim)
                        .padding(.top, 12)
                } else {
                    TVSectionHeader(title: "Tìm gần đây")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(recents, id: \.self) { term in
                            TVChip(title: term, selected: false) {
                                query = term
                            }
                        }
                    }
                    Button {
                        if clearHistoryArmed {
                            clearHistoryDisarmTask?.cancel()
                            clearHistoryArmed = false
                            TVSearchText.clearRecents()
                            recents = []
                        } else {
                            clearHistoryArmed = true
                            clearHistoryDisarmTask?.cancel()
                            clearHistoryDisarmTask = Task {
                                try? await Task.sleep(for: .seconds(4))
                                guard !Task.isCancelled else { return }
                                clearHistoryArmed = false
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "trash")
                            Text(clearHistoryArmed ? "Bấm lần nữa để xoá hết" : "Xoá lịch sử tìm kiếm")
                        }
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 13)
                        .overlay(Capsule().strokeBorder(clearHistoryFocused ? theme.focusRing : .clear,
                                                         lineWidth: clearHistoryFocused ? theme.ringWidth : 0))
                    }
                    .tvCardButton()
                    .focused($clearHistoryFocused)
                    .onChange(of: clearHistoryFocused) { _, focused in
                        if !focused {
                            clearHistoryArmed = false
                            clearHistoryDisarmTask?.cancel()
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 30)
            .focusSection(if: !recents.isEmpty)
        }
    }

    // MARK: Search machinery

    private func scheduleSearch() {
        debounceTask?.cancel()
        let term = trimmedQuery
        guard !term.isEmpty else {
            generation += 1
            results = []
            didSearch = false
            searchError = nil
            isSearching = false
            probeTask?.cancel()
            actorMatch = nil
            return
        }
        // Gate fix G-15: the probe verdict belongs to the
        // term it probed — invalidate it the moment the term
        // changes, not 300 ms later in runSearch. Otherwise
        // the pinned row (whose label and tap payload read
        // the LIVE trimmedQuery) could pair the new name
        // with the previous term's unverified route during
        // the debounce window (SPEC §14.3).
        probeTask?.cancel()
        actorMatch = nil
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await runSearch(term: term)
        }
    }

    private func runSearch(term: String) async {
        generation += 1
        serverPage = 0
        serverTotalPages = 1
        let gen = generation
        let pid = activeId
        guard !pid.isEmpty else { return }

        // §13.13 amendment: the actress probe rides the same
        // generation as the film search — a stale generation's
        // verdict is dropped, exactly like the server merge's.
        // It runs parallel to (never ahead of) the film
        // results and makes NO focus requests, ever.
        actorMatch = nil
        probeTask?.cancel()
        probeTask = Task {
            let probe = await service.actorProbe(name: term)
            guard gen == generation, !Task.isCancelled else { return }
            actorMatch = probe
        }

        // 1. Local paint — instant, from what the device holds.
        let needle = TVSearchText.normalise(term)
        var seen = Set<String>()
        var local: [Movie] = []
        let pool = store.pool(for: pid)
            + favorites.records.filter { $0.pluginId == pid }.map(\.movie)
            + history.records.filter { $0.pluginId == pid }.map(\.movie)
        for movie in pool where seen.insert(movie.id).inserted {
            if TVSearchText.normalise(movie.title).contains(needle) {
                local.append(movie)
            }
        }
        results = local
        didSearch = true
        searchError = nil
        isSearching = true

        // 2. Server merge — behind the local results.
        do {
            let page = try await service.search(pluginId: pid, keyword: term, page: 1)
            guard gen == generation else { return }
            serverPage = page.pagination.currentPage
            serverTotalPages = max(page.pagination.totalPages, 1)
            var shown = Set(results.map(\.id))
            var exact: [Movie] = []
            var rest: [Movie] = []
            for movie in page.items where shown.insert(movie.id).inserted {
                if TVSearchText.normalise(movie.title) == needle {
                    exact.append(movie)
                } else {
                    rest.append(movie)
                }
            }
            results.append(contentsOf: exact + rest)
        } catch {
            guard gen == generation else { return }
            if results.isEmpty {
                searchError = "Tìm kiếm thất bại"
            }
            DiagLog.log("search", "server search failed plugin=\(pid) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        if gen == generation { isSearching = false }
    }

    private func loadMoreServer() async {
        let term = trimmedQuery
        guard !term.isEmpty, !isLoadingMore, serverPage >= 1, serverPage < serverTotalPages else { return }
        let gen = generation
        isLoadingMore = true
        do {
            let page = try await service.search(pluginId: activeId, keyword: term, page: serverPage + 1)
            guard gen == generation else { isLoadingMore = false; return }
            var shown = Set(results.map(\.id))
            results.append(contentsOf: page.items.filter { shown.insert($0.id).inserted })
            serverPage = page.pagination.currentPage
            serverTotalPages = max(page.pagination.totalPages, 1)
        } catch {
            DiagLog.log("search", "loadMore failed kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        isLoadingMore = false
    }
}

// MARK: - Letter strip (L-T14 / FL-384)

/// The on-screen letter strip, adapted from JoeTV's
/// JoeLetterStrip (JoeSearch.swift) to JTV's theme: ONE row of
/// real Buttons — a mode key, a space key, the letters, a
/// delete key — mutating the bound query; the host's
/// .onChange(of: query) fires its existing search round per
/// settled edit, so results repaint in this same screen while
/// typing. The native TextField it replaces summoned the
/// full-screen system keyboard and hid the results until
/// "done". The second mode swaps the letters for the digits
/// and the few symbols film/manga titles carry — JoeTV's exact
/// sets. Query mutation rules are JoeTV's too: appends capped
/// at 48 characters, delete removes the last character.
/// Focus movement is geometric only: the strip is one
/// .focusSection(), no .onMoveCommand anywhere.
private struct TVLetterStrip: View {
    @Binding var query: String
    // Gate fix pass 3 (C-R4-1): the mode is a binding owned
    // by TVSearchView (was this strip's own @State) so the
    // parent's entry .defaultFocus can be chosen against the
    // strip's CURRENT mode — see the declaration there. The
    // mode still persists for the strip instance's life,
    // exactly as before; only its storage moved up one level.
    @Binding var symbols: Bool
    var focus: FocusState<TVSearchKeyFocus?>.Binding

    private var letters: [String] {
        symbols
            ? ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
               "-", "'", ".", "&", ":"]
            : Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
    }

    var body: some View {
        HStack(spacing: 8) {
            key(id: "mode", label: symbols ? "abc" : "123", width: 96) {
                symbols.toggle()
            }
            key(id: "space", label: "space", width: 128) {
                append(" ")
            }
            ForEach(letters, id: \.self) { letter in
                key(id: letter, label: letter, width: 42) {
                    append(letter)
                }
            }
            key(id: "del", label: "⌫", width: 96) {
                if !query.isEmpty { query.removeLast() }
            }
        }
        .focusSection()
    }

    private func append(_ s: String) {
        guard query.count < 48 else { return }
        query += s
    }

    private func key(id: String, label: String, width: CGFloat,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TVKeyCap(label: label, width: width,
                     focused: focus.wrappedValue == .key(id))
        }
        .tvCardButton()
        .focused(focus, equals: .key(id))
    }
}

/// One strip key's face: a quiet plate unfocused, the theme's
/// focusRing colour filled with a black label when focused —
/// the key paints its own focus, because the house button
/// style (.tvCardButton()) deliberately paints nothing.
/// Geometry follows JoeTV's JoeKeyCap: 58 pt tall, radius 12.
private struct TVKeyCap: View {
    let label: String
    let width: CGFloat
    let focused: Bool
    @Environment(\.tvTheme) private var theme

    var body: some View {
        Text(label)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(focused ? .black : theme.textPrimary)
            .frame(width: width, height: 58)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(focused ? theme.focusRing : Color.white.opacity(0.08)))
    }
}

/// The pinned actress row (§13.13 amendment), shared by
/// the search tab and the pushed search-results surface:
/// renders when the cross-source probe verified the term
/// as an actress with actor pages. FOCUS DISCIPLINE: the
/// row is focusable and appears asynchronously, but it
/// NEVER steals or relocates focus — nothing in the probe
/// path assigns focus; the letter strip keeps focus while
/// typing, and entering the results reaches this row
/// first, then the grid.
private struct TVActorProbeRow: View {
    let name: String
    let match: ActorProbeResult
    let onSelect: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 28))
                    .foregroundStyle(isFocused ? .black : theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diễn viên: \(name)")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(isFocused ? .black : theme.textPrimary)
                        .lineLimit(1)
                    Text("\(match.resolverCount) nguồn có trang diễn viên")
                        .font(.system(size: 22))
                        .foregroundStyle(isFocused ? .black : theme.textDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : theme.textDim)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isFocused ? theme.focusRing : theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFocused ? theme.focusRing : theme.cardStroke,
                              lineWidth: isFocused ? theme.ringWidth : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .tvCardButton()
        .focused($isFocused)
    }
}

// MARK: - Search results (cast destination)

/// The AppRoute.search destination (Detail cast chips) — the
/// iOS SearchResultsView semantics: server search for a fixed
/// keyword in one plugin, the shared grid, the same states.
struct TVSearchResultsView: View {
    let query: String
    let pluginId: String

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var session: PinSession
    @Environment(\.tvTheme) private var theme
    @Environment(TVNavPath.self) private var nav

    @State private var items: [Movie] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var didLoad = false
    @State private var loadGeneration = 0
    /// §13.13 amendment: the actress probe's verdict for
    /// this surface's fixed query (a route-less cast chip's
    /// keyword search now also offers the merged page).
    @State private var actorMatch: ActorProbeResult?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                Text(query)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                if let actorMatch {
                    TVActorProbeRow(name: query, match: actorMatch) {
                        nav.push(.actor(ActorRoute(pluginId: actorMatch.pluginId, name: query, route: actorMatch.route)))
                    }
                }
                contentBand
                    .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 36)
        }
        .tvThemedBackground()
        .onAppear { session.touch() }
        // L-T31 (1.3.4): this surface's Menu arbiter — Back
        // pops the owning stack straight to its root, exactly
        // like Detail's (see TVDetailView).
        .onExitCommand {
            DiagLog.log("menu", "back-to-root surface=search plugin=\(pluginId)")
            nav.popToRoot()
        }
        .task(id: query + pluginId) {
            items = []
            didLoad = false
            actorMatch = nil
            await reload()
            // §13.13 amendment: probe after the film results
            // land (never delays them); a torn-down instance
            // drops the verdict silently (L-15).
            let probe = await service.actorProbe(name: query)
            if !Task.isCancelled {
                actorMatch = probe
            }
        }
    }

    @ViewBuilder
    private var contentBand: some View {
        if !items.isEmpty {
            TVPosterGrid(items: items, pluginId: pluginId,
                         isLoadingMore: isLoadingMore,
                         onLoadMore: { Task { await loadMore() } })
        } else if loadError != nil {
            // A-9 (1.3.9): with no results on screen the
            // retry button is the landing focus (the actor
            // probe row, when present, declares no default
            // of its own).
            TVErrorState(message: "Tìm kiếm thất bại", onRetry: { Task { await reload() } },
                         retryIsDefaultFocus: true)
                .frame(minHeight: 300)
        } else if didLoad {
            TVEmptyState(icon: "magnifyingglass", title: "Không tìm thấy kết quả",
                         actionTitle: "Thử lại",
                         action: { Task { await reload() } },
                         actionIsDefaultFocus: true)
                .frame(minHeight: 300)
        } else {
            TVLoadingState(onRetry: { Task { await reload() } })
                .frame(minHeight: 300)
        }
    }

    private func reload() async {
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        do {
            let result = try await service.search(pluginId: pluginId, keyword: query, page: 1)
            guard gen == loadGeneration else { return }
            items = result.items.uniquedById()
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
        } catch {
            guard gen == loadGeneration else { return }
            // L-15: cancellation is not an error — a
            // torn-down instance stays silent instead of
            // surfacing a failure.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                DiagLog.log("search", "results cancelled plugin=\(pluginId)")
            } else {
                loadError = "Tìm kiếm thất bại"
                DiagLog.log("search", "results failed plugin=\(pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
            }
        }
        guard gen == loadGeneration else { return }
        isLoading = false
        didLoad = true
    }

    private func loadMore() async {
        guard didLoad, !isLoading, !isLoadingMore, page >= 1, page < totalPages else { return }
        let gen = loadGeneration
        isLoadingMore = true
        do {
            let result = try await service.search(pluginId: pluginId, keyword: query, page: page + 1)
            guard gen == loadGeneration else { isLoadingMore = false; return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
        } catch {
            DiagLog.log("search", "results loadMore failed kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        isLoadingMore = false
    }
}
