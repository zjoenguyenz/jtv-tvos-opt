import SwiftUI

private struct TVLibraryConditionalFocusSection: ViewModifier {
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
    func libraryFocusSection(if enabled: Bool) -> some View {
        modifier(TVLibraryConditionalFocusSection(enabled: enabled))
    }
}

/// h:mm:ss / m:ss position formatting. Moved here in 1.3.0
/// (NEXT-B B4): it was TVPlaybackPlaceholderView.formatTime,
/// and this file was that helper's last remaining user once
/// the placeholder itself was removed.
enum TVTimeFormat {
    static func string(_ seconds: Double) -> String {
        // Review-gate fix (1.3.0): the iOS reference behaviour
        // exactly — non-finite or negative input is "0:00", and
        // the total TRUNCATES (Int(seconds)), never rounds.
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// JTV tvOS Phase 2 — Library tab (the iOS LibraryView port,
/// survey §1.6): segmented Đang xem tiếp / Yêu thích at a fixed,
/// findable position (its own tab — FL-071). History shows ALL
/// records (Home's Continue Watching filters finished ones
/// out); rows are focusable cards in a LazyVStack (no List —
/// FL-253); long-press deletes; "Xoá tất cả" when non-empty.
/// Favourites is the shared poster cell in a grid; long-press
/// removes. Both segments have designed empty states.
struct TVLibraryView: View {
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var session: PinSession
    @Environment(TVNavPath.self) private var nav
    @Environment(\.tvTheme) private var theme

    private enum Segment: Hashable {
        case history
        case favorites
    }

    @State private var segment: Segment = .history
    @State private var measuredWidth: CGFloat = 0
    @Namespace private var focusNS

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                segmentBand
                    .focusSection()
                    .prefersDefaultFocus(true, in: focusNS)
                if segment == .history {
                    historyBand
                        .libraryFocusSection(if: !history.records.isEmpty)
                } else {
                    favoritesBand
                        .libraryFocusSection(if: !favorites.records.isEmpty)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 36)
            .focusScope(focusNS)
        }
        .tvThemedBackground()
        .onAppear { session.touch() }
    }

    private var segmentBand: some View {
        HStack(spacing: 16) {
            TVChip(title: "Đang xem tiếp", selected: segment == .history) {
                segment = .history
            }
            TVChip(title: "Yêu thích", selected: segment == .favorites) {
                segment = .favorites
            }
            Spacer()
        }
    }

    // MARK: History

    @ViewBuilder
    private var historyBand: some View {
        if history.records.isEmpty {
            TVEmptyState(icon: "clock.arrow.circlepath", title: "Chưa có lịch sử xem")
                .frame(minHeight: 300)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    // A-10 (1.3.9): the long-press gesture
                    // gets a discoverable hint line.
                    Text("Giữ lâu một mục để xoá khỏi lịch sử")
                        .font(.system(size: 23))
                        .foregroundStyle(theme.textDim)
                    Spacer()
                    TVLibraryClearButton(title: "Xoá tất cả") {
                        history.clearAll()
                    }
                }
                ForEach(history.records) { record in
                    TVHistoryRow(record: record,
                                 onSelect: {
                                     nav.push(.movie(MovieRoute(pluginId: record.pluginId,
                                                                movie: record.movie,
                                                                autoResume: true)))
                                 },
                                 onLongPress: {
                                     history.remove(record)
                                 })
                }
            }
        }
    }

    // MARK: Favourites

    private var favoritesColumns: [GridItem] {
        let count = TVGridGeometry.columnCount(forWidth: measuredWidth)
        return Array(repeating: GridItem(.fixed(favoritesCellWidth), spacing: 24), count: count)
    }

    private var favoritesCellWidth: CGFloat {
        TVGridGeometry.cellWidth(forWidth: measuredWidth, spacing: 24)
    }

    @ViewBuilder
    private var favoritesBand: some View {
        if favorites.records.isEmpty {
            TVEmptyState(icon: "heart", title: "Chưa có mục yêu thích")
                .frame(minHeight: 300)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                // A-10 (1.3.9): long-press hint, favourites form.
                Text("Giữ lâu một thẻ để bỏ yêu thích")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.textDim)
            LazyVGrid(columns: favoritesColumns,
                      spacing: 30) {
                ForEach(favorites.records) { record in
                    TVGridPosterCell(movie: record.movie, width: favoritesCellWidth, isFavorite: true,
                                     onSelect: {
                                         nav.push(.movie(MovieRoute(pluginId: record.pluginId,
                                                                    movie: record.movie,
                                                                    autoResume: false)))
                                     },
                                     onLongPress: {
                                         favorites.remove(record)
                                     })
                }
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
    }
}

// MARK: - History row

/// One history record as a focusable glass card: poster left,
/// title + episode/source line, progress (video) or page text
/// (manga), play glyph trailing. The focus ring rides the
/// card's own rounded rect.
private struct TVHistoryRow: View {
    let record: HistoryRecord
    let onSelect: () -> Void
    let onLongPress: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    private let radius: CGFloat = 16

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 24) {
                TVRemoteImage(urlString: record.movie.posterUrl, bucket: 480)
                    .frame(width: 108, height: 162)
                    .clipShape(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 10) {
                    Text(record.movie.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        Image(systemName: record.isManga ? "book" : "play.tv")
                            .font(.system(size: 21, weight: .semibold))
                        Text("\(record.episodeName) • \(record.pluginName)")
                            .font(.system(size: 23))
                            .lineLimit(1)
                    }
                    .foregroundStyle(theme.textDim)
                    if record.isManga {
                        Text("Đã đọc tới trang \(Int(record.lastPosition) + 1)")
                            .font(.system(size: 22))
                            .foregroundStyle(theme.textFaint)
                    } else if record.duration > 0 {
                        HStack(spacing: 16) {
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.25))
                                Capsule().fill(theme.accent)
                                    .frame(width: 420 * CGFloat(record.progress))
                            }
                            .frame(width: 420, height: 6)
                            Text("\(TVTimeFormat.string(record.lastPosition)) / \(TVTimeFormat.string(record.duration))")
                                .font(.system(size: 22))
                                .foregroundStyle(theme.textFaint)
                        }
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.accent)
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused($isFocused)
        .onLongPressGesture(minimumDuration: 0.5) {
            onLongPress()
        }
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.13) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : theme.cardStroke,
                          lineWidth: isFocused ? theme.ringWidth : 1))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Clear-all button

private struct TVLibraryClearButton: View {
    let title: String
    let onTap: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool
    /// A-10 (1.3.9): two-tap confirm — the first tap arms
    /// (the label becomes the confirm prompt), a second tap
    /// inside the window executes; the window lapsing or
    /// focus leaving disarms. A destructive clear-all must
    /// never fire on a single inertial tap.
    @State private var armed = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        Button {
            if armed {
                disarmTask?.cancel()
                armed = false
                onTap()
            } else {
                armed = true
                disarmTask?.cancel()
                disarmTask = Task {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    armed = false
                }
            }
        } label: {
            Text(armed ? "Bấm lần nữa để xoá hết" : title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .overlay(Capsule().strokeBorder(isFocused ? theme.focusRing : .clear,
                                                lineWidth: isFocused ? theme.ringWidth : 0))
        }
        .tvCardButton()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            if !focused {
                armed = false
                disarmTask?.cancel()
            }
        }
    }
}
