import SwiftUI

/// JTV tvOS Phase 2 — Category tab (the iOS CategoryBrowseView
/// port, survey §1.3): the four blocks in fixed order — Danh mục,
/// Thể loại, Quốc gia, Năm phát hành — each a focus section of
/// glass chips, each omitted when its list is empty. Routing is
/// the iOS routing exactly: Quốc gia / Năm land on the plugin's
/// default category with that filter pre-applied.
struct TVCategoryView: View {
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var session: PinSession
    @Environment(TVNavPath.self) private var nav
    @Environment(\.tvTheme) private var theme

    @State private var primary: [NameSlug] = []
    @State private var categories: [NameSlug] = []
    @State private var countries: [NameValue] = []
    @State private var years: [NameValue] = []
    @State private var isLoading = false
    @State private var loadGeneration = 0
    @State private var didLoad = false
    @Namespace private var focusNS

    private var firstBlock: String? {
        if !primary.isEmpty { return "primary" }
        if !categories.isEmpty { return "categories" }
        if !countries.isEmpty { return "countries" }
        if !years.isEmpty { return "years" }
        return nil
    }

    private var allEmpty: Bool {
        primary.isEmpty && categories.isEmpty && countries.isEmpty && years.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if !plugins.visiblePlugins.isEmpty {
                chipRail
            }
            ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                if plugins.visiblePlugins.isEmpty {
                    TVEmptyState(icon: "puzzlepiece.extension",
                                 title: "Chưa có nguồn plugin",
                                 actionTitle: "Đồng bộ ngay") {
                        Task { await plugins.syncAll() }
                    }
                    .focusSection()
                } else if didLoad && allEmpty {
                    TVEmptyState(icon: "square.grid.2x2", title: "Chưa có danh mục",
                                 actionTitle: "Thử lại",
                                 action: { Task { await load() } },
                                 actionIsDefaultFocus: true)
                        .focusSection()
                } else {
                    if !primary.isEmpty {
                        block(title: "Danh mục", isDefaultFocusTarget: firstBlock == "primary") {
                            ForEach(primary) { item in
                                chip(item.name) {
                                    push(CategoryRoute(pluginId: activeId, slug: item.slug,
                                                       title: item.name, filters: ListFilters()))
                                }
                            }
                        }
                    }
                    if !categories.isEmpty {
                        block(title: "Thể loại", isDefaultFocusTarget: firstBlock == "categories") {
                            ForEach(categories) { item in
                                chip(item.name) {
                                    push(CategoryRoute(pluginId: activeId, slug: item.slug,
                                                       title: item.name, filters: ListFilters()))
                                }
                            }
                        }
                    }
                    if !countries.isEmpty {
                        block(title: "Quốc gia", isDefaultFocusTarget: firstBlock == "countries") {
                            ForEach(countries) { item in
                                chip(item.name) {
                                    var f = ListFilters()
                                    f.country = item.value
                                    push(CategoryRoute(pluginId: activeId, slug: defaultSlug,
                                                       title: item.name, filters: f))
                                }
                            }
                        }
                    }
                    if !years.isEmpty {
                        block(title: "Năm phát hành", isDefaultFocusTarget: firstBlock == "years") {
                            ForEach(years) { item in
                                chip(item.name) {
                                    var f = ListFilters()
                                    f.year = item.value
                                    push(CategoryRoute(pluginId: activeId, slug: defaultSlug,
                                                       title: "Năm \(item.name)", filters: f))
                                }
                            }
                        }
                    }
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 36)
            .focusScope(focusNS)
            }
        }
        .tvThemedBackground()
        .onAppear { session.touch() }
        .task(id: plugins.activePluginId) { await load() }
    }

    /// A-5 (1.3.9, F-05): the plugin switch rail, pinned
    /// above the scroll region exactly as on Home — switching
    /// plugin reloads this tab's lists in place (the .task
    /// above keys on activePluginId) instead of routing the
    /// user through Home. Unlike Home's rail the chips claim
    /// no default focus here: the first block's existing
    /// prefersDefaultFocus stays this screen's single
    /// landing claim.
    private var chipRail: some View {
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
            .padding(.horizontal, 80)
            .padding(.vertical, 18)
        }
        .focusSection()
    }

    private var activeId: String { plugins.activePlugin?.id ?? "" }

    private var defaultSlug: String { primary.first?.slug ?? "phim-moi" }

    private func push(_ route: CategoryRoute) {
        nav.push(.category(route))
    }

    private func block<Content: View>(title: String, isDefaultFocusTarget: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title: title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                content()
            }
            .prefersDefaultFocus(isDefaultFocusTarget, in: focusNS)
        }
        .focusSection()
    }

    private func chip(_ title: String, onTap: @escaping () -> Void) -> some View {
        TVCategoryChip(title: title, onTap: onTap)
    }

    private func load() async {
        guard let pid = plugins.activePlugin?.id else { return }
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        async let primaryResult = service.primaryCategories(pluginId: pid)
        async let categoriesResult = service.categories(pluginId: pid)
        async let countriesResult = service.countries(pluginId: pid)
        async let yearsResult = service.years(pluginId: pid)
        let p = await primaryResult
        let c = await categoriesResult
        let co = await countriesResult
        let y = await yearsResult
        guard gen == loadGeneration else { return }
        primary = p
        categories = c
        countries = co
        years = y
        didLoad = true
        if p.isEmpty && c.isEmpty && co.isEmpty && y.isEmpty {
            DiagLog.log("category", "all lists empty plugin=\(pid)")
        }
        isLoading = false
    }
}

/// Glass chip for the Category blocks (mockup 03): name centred
/// on a glass card, inset focus ring at the card's own radius.
private struct TVCategoryChip: View {
    let title: String
    let onTap: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            onTap()
        } label: {
            Text(title)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused($isFocused)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.14) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : theme.cardStroke,
                          lineWidth: isFocused ? theme.ringWidth : 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
