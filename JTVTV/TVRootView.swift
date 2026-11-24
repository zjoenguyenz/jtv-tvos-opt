import SwiftUI

/// The post-unlock shell — Phase 2: the five-tab browse app
/// (Trang chủ · Thể loại · Tìm kiếm · Thư viện · Cài đặt, the
/// iOS tab order; Torrent joins in Phase 4). Each browse tab
/// owns a NavigationStack and a TVNavPath; the shared core
/// objects (PluginManager, MovieService, favourites, history,
/// the playback presenter) are created ONCE here and injected,
/// and the picked theme's tokens ride the environment from
/// this root (one theme constant source for the whole app —
/// FL-125).
///
/// Access control: the PIN gate is this app's adult gate. The
/// core's session adult flag starts OFF at every launch (its
/// iOS rule), which would leave `visiblePlugins` empty by
/// construction; content exists only after the gate, so the
/// shell enables the flag as it appears — inside the gate, the
/// full plugin set is visible.
///
/// Activity hooks for the PIN idle rule: the shell's appearance
/// and every tab change refresh `PinSession.lastActivity` via
/// `touch()`; play actions will drive `setPlaybackActive(_:)`
/// from the Phase 3 player.
struct TVRootView: View {
    @EnvironmentObject private var session: PinSession

    @StateObject private var plugins: PluginManager
    @StateObject private var service: MovieService
    @StateObject private var favorites = FavoritesManager()
    // A2(a): the root only FORWARDS the history store (into the
    // environment and into the player's value deps); it never
    // reads it in `body`. Holding it through a non-publishing
    // holder keeps its one-instance lifetime without subscribing
    // the root to its 2 s playback-progress publishes. Every
    // screen that shows history still observes it itself via
    // @EnvironmentObject.
    @StateObject private var historyHolder = TVRootHistoryHolder()
    @StateObject private var presenter = PlaybackPresenter()

    @State private var homeStore = TVHomeStore()
    @State private var homeNav = TVNavPath()
    @State private var categoryNav = TVNavPath()
    @State private var searchNav = TVNavPath()
    @State private var libraryNav = TVNavPath()

    @AppStorage(TVThemeStore.defaultsKey) private var themeRaw = JTVThemeID.ultraBlack.rawValue
    @State private var selection = 0

    // A1: SwiftUI re-runs this init on every parent re-render
    // (RootContainerView re-renders on each PinSession publish:
    // every touch(), tab change, and the 60 s playback refresh).
    // Construction stays inside the StateObject autoclosures,
    // which SwiftUI evaluates once, when the view is installed;
    // the per-init box is cheap and its lazy members are touched
    // only by those closures, so both StateObjects still share
    // ONE PluginManager. No throwaway PluginManager / MovieService
    // is built on a re-init any more.
    init() {
        let box = TVRootStoreBox()
        _plugins = StateObject(wrappedValue: box.plugins)
        _service = StateObject(wrappedValue: box.service)
    }

    private var history: WatchHistoryManager { historyHolder.history }

    private var theme: TVThemeTokens {
        (JTVThemeID(rawValue: themeRaw) ?? .ultraBlack).tokens
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack(path: homeNav.binding) {
                TVHomeView()
                    .tvNavigationDestinations()
            }
            .environment(homeNav)
            .tabItem { Label("Trang chủ", systemImage: "house") }
            .tag(0)

            NavigationStack(path: categoryNav.binding) {
                TVCategoryView()
                    .tvNavigationDestinations()
            }
            .environment(categoryNav)
            .tabItem { Label("Thể loại", systemImage: "square.grid.2x2") }
            .tag(1)

            NavigationStack(path: searchNav.binding) {
                TVSearchView()
                    .tvNavigationDestinations()
            }
            .environment(searchNav)
            .tabItem { Label("Tìm kiếm", systemImage: "magnifyingglass") }
            .tag(2)

            NavigationStack(path: libraryNav.binding) {
                TVLibraryView()
                    .tvNavigationDestinations()
            }
            .environment(libraryNav)
            .tabItem { Label("Thư viện", systemImage: "books.vertical") }
            .tag(3)

            TVSettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }
                .tag(4)
        }
        .environmentObject(plugins)
        .environmentObject(service)
        .environmentObject(favorites)
        .environmentObject(history)
        .environmentObject(presenter)
        .environment(homeStore)
        .environment(\.tvTheme, theme)
        .background(theme.backgroundGradient.ignoresSafeArea())
        .fullScreenCover(item: $presenter.request) { request in
            // L-T06: the player's dependencies ride as VALUES
            // from this root (their owner) — the cover's
            // subtree reads no @EnvironmentObject, and the
            // session is built in TVPlayerView.init, before
            // the cover's body machinery runs (JoeTV's
            // pre-build shape, player map R-1).
            TVPlayerView(request: request, service: service, history: history,
                         pinSession: session) {
                presenter.request = nil
            }
        }
        .onAppear {
            session.touch()
            if !plugins.adultEnabled {
                plugins.adultEnabled = true
            }
        }
        .onChange(of: selection) { _, _ in
            session.touch()
        }
    }
}

/// A1: deferred construction for TVRootView's two linked
/// StateObjects. A fresh box is made on every TVRootView.init,
/// but `plugins` / `service` are only evaluated inside the
/// StateObject autoclosures (i.e. once, at install), and
/// `service` reuses the same lazily built `plugins`.
@MainActor
private final class TVRootStoreBox {
    lazy var plugins = PluginManager()
    lazy var service = MovieService(manager: plugins)
}

/// A2(a): owns the root's WatchHistoryManager for the root's
/// lifetime. Deliberately has no @Published state, so its
/// objectWillChange never fires and the root view is not
/// re-rendered by history changes.
@MainActor
private final class TVRootHistoryHolder: ObservableObject {
    let history = WatchHistoryManager()
}
