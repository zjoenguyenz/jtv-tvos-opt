import SwiftUI

private struct TVBrowseConditionalFocusSection: ViewModifier {
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
    func browseFocusSection(if enabled: Bool) -> some View {
        modifier(TVBrowseConditionalFocusSection(enabled: enabled))
    }
}

/// JTV tvOS Phase 2 — per-source browse (the iOS CategoryDetailView
/// port), the shared poster grid, the filter sheet, and the shared
/// navigation plumbing (route destinations + the per-tab nav path
/// model) used by every Phase 2 tab stack.
///
/// Construction follows the Phase 2 template (plan §3): ScrollView
/// + LazyVStack bands, each band a `.focusSection()`, element-level
/// focus only, no List anywhere.

// MARK: - Per-tab navigation path model

/// Pure path-mutation arithmetic for TVNavPath: every mutation is
/// computed on a LOCAL copy — append first, then the iOS
/// NavSanitizer pass — and the result is assigned to the observed
/// `path` exactly once. Kept free of SwiftUI/@Observable so the
/// exact functions the app calls can be compiled and exercised
/// standalone (the L-T04 executable proof).
enum NavPathMutation {
    /// `path` with `route` appended and sanitised.
    static func pushing(_ route: AppRoute, onto path: [AppRoute]) -> [AppRoute] {
        var next = path
        next.append(route)
        NavSanitizer.sanitize(&next)
        return next
    }

    /// `path` sanitised (adjacent duplicate .movie routes collapse
    /// to the newest, exact duplicates drop — NavSanitizer's
    /// semantics, unchanged).
    static func sanitized(_ path: [AppRoute]) -> [AppRoute] {
        var copy = path
        NavSanitizer.sanitize(&copy)
        return copy
    }
}

/// One instance per tab, created by the tab root and injected into
/// the environment, so pushed screens (Detail, Browse) append to
/// the owning stack without needing the path binding threaded
/// through every destination.
///
/// L-T04 (convicted on device, 1.2.2): the previous shape ran
/// `NavSanitizer.sanitize(&path)` from `path`'s own didSet — the
/// sanitizer mutated the observed property from inside its own
/// observer (an inout writeback cycle), and `path.append` inside
/// `push` never returned: the app died between breadcrumb D0 and
/// D1 on every card tap. The sanitizer's logic was never the
/// fault (it is byte-identical to the proven iOS copy); the CALL
/// DISCIPLINE was. Rule from here on: no property is ever mutated
/// from within its own observer. Every write to `path` — push,
/// and the NavigationStack's own binding writes (pop / pop-to-
/// root) — goes through `assign(_:)`, which sanitises a local
/// copy via NavPathMutation and assigns the observed property
/// exactly once.
@MainActor
@Observable
final class TVNavPath {
    private(set) var path: [AppRoute] = []

    /// L-T31 (1.3.4): pop the whole stack back to its root —
    /// the target of every pushed surface's Menu arbiter
    /// (owner ruling 2026-11-22: "Back là về đầu menu", the
    /// torrent pages' behaviour, applied to every film page).
    /// Goes through the same assign door as every other path
    /// write, so a pop-to-root is sanitised and assigned
    /// exactly once; already at root it is a no-op. The
    /// arbiter lives on each destination view (Detail /
    /// Browse / Search results), NOT in this model, so a
    /// future surface that must special-case its Back (e.g.
    /// a Detail pushed from a Phase 2 actor screen returning
    /// there first) can override at its own seam without
    /// touching the shared path machinery.
    func popToRoot() {
        assign([])
    }

    /// B-1 (Phase 2, owner ruling 2026-11-22 15:56): pop
    /// exactly ONE level — the step a film Detail takes back
    /// to the actor screen it was opened from, and the step
    /// the actor screen itself takes back to its origin
    /// Detail. Through the same assign door as every write.
    func pop() {
        guard !path.isEmpty else { return }
        assign(Array(path.dropLast()))
    }

    /// B-1: true when the route directly beneath the stack's
    /// top is an actor route — the signal TVDetailView's Menu
    /// arbiter reads for the actor exception. The exception
    /// follows the actual navigation chain; no flag is stored
    /// on any route, so a Detail reached any other way keeps
    /// the L-T31 pop-to-root behaviour by construction.
    var isActorBeneathTop: Bool {
        guard path.count >= 2, case .actor = path[path.count - 2] else { return false }
        return true
    }

    func push(_ route: AppRoute) {
        assign(NavPathMutation.pushing(route, onto: path))
        // L-T04 breadcrumb D1: the append + sanitise + assign
        // completed and push is returning — D1 printing at all is
        // the proof the convicted append now returns.
        switch route {
        case .movie(let r):
            DiagLog.log("detail", "push.movie plugin=\(r.pluginId) movie=\(r.movie.id)")
        case .category(let r):
            DiagLog.log("detail", "push.category plugin=\(r.pluginId) slug=\(r.slug)")
        case .search(let r):
            DiagLog.log("detail", "push.search plugin=\(r.pluginId)")
        case .actor(let r):
            DiagLog.log("actor", "push plugin=\(r.pluginId) name=\(r.name)")
        }
    }

    /// The binding the owning NavigationStack writes through, so
    /// stack-driven mutations (Back pops, pop-to-root) take the
    /// same sanitize-then-assign-once door as `push` instead of
    /// setting the observed property directly. SwiftUI invokes a
    /// navigation path binding only on the main actor, hence
    /// `MainActor.assumeIsolated` (the TVAVPlayerHost idiom) to
    /// satisfy Swift 6 isolation for the @MainActor class.
    var binding: Binding<[AppRoute]> {
        Binding(
            get: { MainActor.assumeIsolated { self.path } },
            set: { newValue in MainActor.assumeIsolated { self.assign(newValue) } }
        )
    }

    /// The single write door for `path`: sanitise the candidate
    /// on a local copy, then assign the observed property once.
    /// A candidate that sanitises to the current path is dropped
    /// — no redundant write, no spurious change notification.
    private func assign(_ candidate: [AppRoute]) {
        let sanitized = NavPathMutation.sanitized(candidate)
        guard sanitized != path else { return }
        path = sanitized
    }
}

/// Builds the Detail destination for a .movie route. L-T04
/// breadcrumb D2 lives here: the log fires when the destination
/// closure is evaluated for the route — after the push (D1),
/// before the destination's body is entered (D3) — exactly the
/// split the diagnosis spec (L-T04-DETAIL-DIAGNOSIS.md §4) asks
/// for. D2 was originally a bare statement inside the destination
/// closure, which is not a ViewBuilder expression (CI run #10:
/// `type '()' cannot conform to 'View'`; FL-359); the first fix
/// shape, `.onAppear` on the destination, compiled but fired
/// only after the first body evaluation and lost the
/// closure-reached vs body-entry split (review gate Round 1,
/// Lens B MAJOR), so the log call rides this factory instead.
private func tvMovieDestination(_ r: MovieRoute) -> TVDetailView {
    DiagLog.log("detail", "destination plugin=\(r.pluginId) movie=\(r.movie.id)")
    return TVDetailView(pluginId: r.pluginId, movie: r.movie, autoResume: r.autoResume)
}

extension View {
    /// The three AppRoute destinations every Phase 2 stack shares
    /// (FL-235 — one shared destination set, no per-tab copies).
    func tvNavigationDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .movie(let r):
                tvMovieDestination(r)
            case .category(let r):
                TVBrowseView(pluginId: r.pluginId, slug: r.slug, title: r.title, initialFilters: r.filters)
            case .search(let r):
                TVSearchResultsView(query: r.keyword, pluginId: r.pluginId)
            case .actor(let r):
                TVActorView(pluginId: r.pluginId, name: r.name, route: r.route)
            }
        }
    }
}

// MARK: - Shared poster grid

/// The one poster grid for Browse, Search results and Search's
/// cast destination (FL-235). Lives inside the parent's ScrollView
/// (no own ScrollView). Column count is derived from the measured
/// container width (FL-126 — never a hard-coded resolution).
/// Load-more hangs on the bottom sentinel's appearance — a
/// scroll-position signal (FL-234), guarded by the parent.
struct TVPosterGrid: View {
    let items: [Movie]
    let pluginId: String
    let isLoadingMore: Bool
    var onSelect: ((Movie) -> Void)? = nil
    let onLoadMore: () -> Void
    /// A-6 (1.3.9): an optional entry-focus binding handed
    /// to the FIRST cell only, so a screen whose landing
    /// focus should be its first card can declare it (the
    /// Browse screen does; other grid users pass nothing).
    var firstCellEntryFocus: FocusState<Bool>.Binding? = nil

    @EnvironmentObject private var favorites: FavoritesManager
    @Environment(TVNavPath.self) private var nav
    @State private var measuredWidth: CGFloat = 0

    private let spacing: CGFloat = 24

    private var columns: [GridItem] {
        let count = TVGridGeometry.columnCount(forWidth: measuredWidth)
        return Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: count)
    }

    private var cellWidth: CGFloat {
        TVGridGeometry.cellWidth(forWidth: measuredWidth, spacing: spacing)
    }

    var body: some View {
        VStack(spacing: 28) {
            LazyVGrid(columns: columns, spacing: 30) {
                ForEach(items) { movie in
                    TVGridPosterCell(
                        movie: movie,
                        width: cellWidth,
                        isFavorite: favorites.isFavorite(pluginId: pluginId, movieId: movie.id),
                        onSelect: {
                            // L-T04 breadcrumb D0 (grid form):
                            // the tap is leaving the grid.
                            DiagLog.log("detail", "tap.grid plugin=\(pluginId) movie=\(movie.id)")
                            onSelect?(movie)
                            nav.push(.movie(MovieRoute(pluginId: pluginId, movie: movie)))
                        },
                        onLongPress: {
                            favorites.toggle(pluginId: pluginId, movie: movie)
                        },
                        entryFocus: movie.id == items.first?.id ? firstCellEntryFocus : nil
                    )
                }
            }
            if isLoadingMore {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 8)
            }
            // Bottom sentinel: page side-effects hang on scroll
            // position (FL-234). The parent's loadMore guards on
            // its own page state, so an early fire is harmless.
            Color.clear
                .frame(height: 8)
                .onAppear { onLoadMore() }
        }
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: TVWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(TVWidthKey.self) { [binding = $measuredWidth] in binding.wrappedValue = $0 }
    }
}

extension Array where Element == Movie {
    /// Order-preserving dedupe by id — first occurrence wins.
    func uniquedById() -> [Movie] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

struct TVWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum TVGridGeometry {
    /// Target poster-cell width ≈250pt → 6 columns at the 1920
    /// design width with the screens' 80pt side margins.
    static func columnCount(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return 6 }
        let n = Int((width + 24) / (250 + 24))
        return min(8, max(4, n))
    }

    static func cellWidth(forWidth width: CGFloat, spacing: CGFloat = 24) -> CGFloat {
        guard width > 0 else { return 250 }
        let n = columnCount(forWidth: width)
        return (width - spacing * CGFloat(n - 1)) / CGFloat(n)
    }
}

// MARK: - Browse (per-source listing)

struct TVBrowseView: View {
    let pluginId: String
    let slug: String
    let title: String
    let initialFilters: ListFilters

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
    @State private var filters: ListFilters
    @State private var showFilters = false
    @State private var loadGeneration = 0
    @FocusState private var filterFocused: Bool
    /// A-6 (1.3.9): the first card's entry focus — the
    /// screen's landing focus whenever items exist.
    @FocusState private var firstCardFocused: Bool

    init(pluginId: String, slug: String, title: String, initialFilters: ListFilters) {
        self.pluginId = pluginId
        self.slug = slug
        self.title = title
        self.initialFilters = initialFilters
        _filters = State(initialValue: initialFilters)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                headerBand
                    .focusSection()
                contentBand
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 36)
        }
        .tvThemedBackground()
        // A-6 (1.3.9, F-06): the landing focus is the FIRST
        // CARD whenever the grid has items — the filter
        // button is one ↑ away — and falls back to the
        // filter button while the grid is empty/loading
        // (Detail's conditional-binding precedent).
        .defaultFocus(items.isEmpty ? $filterFocused : $firstCardFocused, true)
        // A-6 gate fix: a defaultFocus declaration does
        // not move focus that was ALREADY assigned — on a
        // fresh open the engine can land on the filter
        // button during the load window, before the first
        // card exists. When the first items land and
        // focus still sits on that fallback, hand it to
        // the first card explicitly. If the user has
        // moved focus anywhere else, filterFocused is
        // false and nothing is stolen.
        .onChange(of: items.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty, !isEmpty, filterFocused {
                firstCardFocused = true
            }
        }
        .onAppear { session.touch() }
        .task { if !didLoad { await reload() } }
        .onChange(of: filters) { _, _ in Task { await reload() } }
        .fullScreenCover(isPresented: $showFilters) {
            TVFilterSheet(pluginId: pluginId, filters: $filters)
        }
        // L-T31 (1.3.4): this surface's Menu arbiter — Back
        // pops the owning stack straight to its root, exactly
        // like Detail's (see TVDetailView). While the filter
        // sheet is up, the sheet's own arbiter owns the press.
        .onExitCommand {
            DiagLog.log("menu", "back-to-root surface=browse plugin=\(pluginId)")
            nav.popToRoot()
        }
    }

    private var headerBand: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(title)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Button {
                showFilters = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: filters.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Bộ lọc")
                        .font(.system(size: 26, weight: .semibold))
                }
                .foregroundStyle(filters.isEmpty ? theme.textPrimary : theme.accent)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            }
            .tvCardButton()
            .focused($filterFocused)
            .tvFocusInsetRing(isFocused: filterFocused, radius: 999,
                              color: theme.focusRing, width: theme.ringWidth,
                              baseFill: theme.cardFill, focusedFill: Color.white.opacity(0.16))
        }
    }

    @ViewBuilder
    private var contentBand: some View {
        if isLoading && items.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if let loadError, items.isEmpty {
            // A-9 (1.3.9): the error state's retry button
            // is a declared landing, as on Detail and the
            // search-results surface (F-09's three screens).
            TVErrorState(message: loadError, onRetry: { Task { await reload() } },
                         retryIsDefaultFocus: true)
                .frame(minHeight: 300)
                .focusSection()
        } else if didLoad && items.isEmpty {
            TVEmptyState(icon: "film.stack", title: "Không có nội dung")
                .frame(minHeight: 300)
        } else {
            TVPosterGrid(items: items, pluginId: pluginId,
                         isLoadingMore: isLoadingMore,
                         onLoadMore: { Task { await loadMore() } },
                         firstCellEntryFocus: $firstCardFocused)
                .browseFocusSection(if: !items.isEmpty)
        }
    }

    private func reload() async {
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        do {
            let result = try await service.list(pluginId: pluginId, slug: slug, filters: filters, page: 1)
            guard gen == loadGeneration else { return }
            items = result.items.uniquedById()
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
        } catch {
            guard gen == loadGeneration else { return }
            loadError = "Không tải được danh sách"
            DiagLog.log("browse", "list failed plugin=\(pluginId) slug=\(slug) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        if gen == loadGeneration {
            isLoading = false
            didLoad = true
        }
    }

    private func loadMore() async {
        guard didLoad, !isLoading, !isLoadingMore, page >= 1, page < totalPages else { return }
        let gen = loadGeneration
        isLoadingMore = true
        do {
            let result = try await service.list(pluginId: pluginId, slug: slug, filters: filters, page: page + 1)
            guard gen == loadGeneration else { isLoadingMore = false; return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
        } catch {
            // Non-fatal (iOS discipline): keep what's on screen.
            DiagLog.log("browse", "loadMore failed plugin=\(pluginId) slug=\(slug) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        isLoadingMore = false
    }
}

// MARK: - Filter sheet

/// The iOS FilterSheet ported to a full-screen cover: draft state,
/// nothing applies until "Áp dụng"; "Đặt lại" clears the draft.
/// Group order is the iOS order exactly (survey §1.2): the three
/// hard-coded groups first, then the plugin's orderedKeys.
struct TVFilterSheet: View {
    let pluginId: String
    @Binding var filters: ListFilters

    @EnvironmentObject private var service: MovieService
    @Environment(\.tvTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ListFilters
    @State private var config = FilterConfig()
    @State private var categories: [NameSlug] = []
    @State private var countries: [NameValue] = []
    @State private var years: [NameValue] = []
    @State private var didLoad = false
    @FocusState private var applyFocused: Bool
    /// Gate fix (A-4 hand-off): Đặt lại's focus binding —
    /// before the groups load, the two action buttons are
    /// the sheet's only focusables, so the load-time
    /// hand-off below keys on both of them.
    @FocusState private var resetFocused: Bool
    /// A-4 (1.3.9): the landing focus — the "Tất cả" chip of
    /// the first group that renders. Áp dụng sits at the
    /// END of the natural top-down path now, not the start.
    @FocusState private var firstChipFocused: Bool

    /// The first group with options, in sheet order; groups
    /// render only when non-empty, so this is the group the
    /// user actually sees first.
    private var firstGroupKey: String? {
        if !categories.isEmpty { return "category" }
        if !countries.isEmpty { return "country" }
        if !years.isEmpty { return "year" }
        return config.orderedKeys.first { !config.options(for: $0).isEmpty }
    }

    init(pluginId: String, filters: Binding<ListFilters>) {
        self.pluginId = pluginId
        _filters = filters
        _draft = State(initialValue: filters.wrappedValue)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                HStack {
                    Text("Bộ lọc")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                }

                groupBand(title: "Thể loại", key: "category",
                          options: categories.map { NameValue(name: $0.name, value: $0.slug) })
                groupBand(title: "Quốc gia", key: "country", options: countries)
                groupBand(title: "Năm", key: "year", options: years)
                ForEach(config.orderedKeys, id: \.self) { key in
                    groupBand(title: Self.title(for: key), key: key,
                              options: config.options(for: key))
                }

                HStack(spacing: 24) {
                    TVSheetActionButton(title: "Đặt lại", primary: false, focusBinding: $resetFocused) {
                        draft = ListFilters()
                    }
                    TVSheetActionButton(title: "Áp dụng", primary: true, focusBinding: $applyFocused) {
                        filters = draft
                        dismiss()
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .tvThemedBackground()
        .defaultFocus($firstChipFocused, true)
        // A-4 gate fix: the groups (and their chips) load
        // in .task, so at appear time the declared landing
        // has no view to land on and the engine can assign
        // focus to an action button instead; a declaration
        // never moves already-assigned focus. When the
        // first group arrives and focus still sits on one
        // of the action buttons (the only focusables that
        // existed during the load), hand it to the first
        // chip explicitly. Focus anywhere else is the
        // user's and is never stolen.
        .onChange(of: firstGroupKey) { _, newKey in
            if newKey != nil, applyFocused || resetFocused {
                firstChipFocused = true
            }
        }
        // L-T31 (1.3.4): the sheet owns its Menu press —
        // Menu closes the sheet and discards the draft (the
        // filters binding is only ever written by Áp dụng);
        // an unhandled press here would fall to the system
        // and exit the app, the L-T31 mechanism.
        .onExitCommand {
            DiagLog.log("menu", "dismiss surface=filter-sheet plugin=\(pluginId)")
            dismiss()
        }
        .task {
            if !didLoad {
                didLoad = true
                config = await service.filterConfig(pluginId: pluginId)
                categories = await service.categories(pluginId: pluginId)
                countries = await service.countries(pluginId: pluginId)
                years = await service.years(pluginId: pluginId)
            }
        }
    }

    @ViewBuilder
    private func groupBand(title: String, key: String, options: [NameValue]) -> some View {
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                TVSectionHeader(title: title)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    chip(title: "Tất cả", selected: draft.value(for: key).isEmpty,
                         entryFocus: key == firstGroupKey ? $firstChipFocused : nil) {
                        draft.set(key, value: "")
                    }
                    ForEach(options) { option in
                        chip(title: option.name, selected: draft.value(for: key) == option.value) {
                            draft.set(key, value: option.value)
                        }
                    }
                }
            }
            .focusSection()
        }
    }

    private func chip(title: String, selected: Bool,
                      entryFocus: FocusState<Bool>.Binding? = nil,
                      onTap: @escaping () -> Void) -> some View {
        TVChip(title: title, selected: selected, entryFocus: entryFocus, onSelect: onTap)
    }

    // Action buttons are built by TVSheetActionButton below
    // (own focus state + inset ring, mirroring TVStateActionLabel).

    static func title(for key: String) -> String {
        switch key {
        case "sort": return "Sắp xếp"
        case "category": return "Nhóm"
        default:
            let spaced = key.replacingOccurrences(of: "_", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }
}

// MARK: - Filter sheet action button

/// Sheet action button with its own focus rendering: capsule
/// fill (accent for primary, cardFill otherwise) PLUS an inset
/// ring keyed to its focus state (focusRing colour/width when
/// focused, clear otherwise) — mirroring TVStateActionLabel.
/// When a parent focus binding is supplied (Áp dụng, so the
/// sheet's `.defaultFocus` keeps working) it drives both the
/// focus and the ring; otherwise the button uses its internal
/// @FocusState (Đặt lại).
private struct TVSheetActionButton: View {
    let title: String
    let primary: Bool
    var focusBinding: FocusState<Bool>.Binding? = nil
    let action: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var internalFocused: Bool

    private var isFocused: Bool {
        focusBinding?.wrappedValue ?? internalFocused
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(primary ? theme.onAccent : theme.textPrimary)
                .padding(.horizontal, 44)
                .padding(.vertical, 18)
                .background(Capsule().fill(primary ? theme.accent : theme.cardFill))
                .overlay(Capsule().strokeBorder(isFocused ? theme.focusRing : .clear,
                                                lineWidth: isFocused ? theme.ringWidth : 0))
        }
        .tvCardButton()
        .modifier(TVEntryFocusModifier(binding: focusBinding ?? $internalFocused))
    }
}
