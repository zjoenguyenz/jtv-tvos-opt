import SwiftUI

/// Row identity for the merged filmography (§13.2/§13.8):
/// Movie.id is unique only within its own plugin, so a merged
/// list keys on plugin + id, never the bare id. (The iOS shell
/// declares the same conformance in its own target.)
extension ActorFilmRow: Identifiable {
    var id: String { "\(pluginId)#\(movie.id)" }
}

/// JTV tvOS Phase 2 (1.3.5) — the actor filmography screen
/// (L-T26), built to the approved drawing
/// (phase2-actor/PREVIEW-actor-tvos.png): actor header with
/// the no-photo initial-letter slot, the source's own film
/// grid on the left (3 × TVPosterCard 240 in a clipped 596
/// viewport), and the focused film's trailer in the fixed
/// 928×522 frame beside the list. tvOS-native throughout:
/// remote focus only, the SwiftUI focus kit renders focus
/// (element-level focus + focus sections + a focus scope —
/// no hand-drawn focus geometry), Menu is this surface's own
/// arbiter.
///
/// Data: an actor route is a category-shaped slug, so the
/// ORIGIN's page 1 rides the same MovieService.list surface
/// TVBrowseView uses, with TVBrowseView's generation-guarded
/// reload discipline. §13 (1.3.6): the outcome is handed to a
/// per-visit ActorMergeCoordinator, which merges the other
/// actor-capable sources in canonical order behind it; this
/// view mirrors the coordinator's published state (rows /
/// contributors / avatar / settled / originFailed) into its
/// own @State via onChange and renders from the mirrors. The
/// coordinator owns every pagination cursor after page 1.
///
/// Preview: focus-dwell 1.5 s (JTV Detail's own value), one
/// attempt per dwell, the attempt dies on any focus move
/// (the .task identity is the focused film + epoch), and the
/// probe is the ONE implementation Detail uses
/// (TVPreviewProbe) — plus the list-item previewUrl fast
/// path for the plugins that emit one (missav / njav), under
/// the same declared + measured ≥720p gates. The Play latch
/// carries over: opening a film latches the preview off
/// behind the pushed Detail; returning re-arms it for the
/// newly current dwell.
///
/// Back (B-1, owner ruling 2026-11-22 15:56): this screen
/// pops ONE level (to its origin Detail); a film Detail
/// opened from here pops back HERE first (its arbiter reads
/// the route beneath it), and the origin Detail's own
/// arbiter completes the chain to the root.
struct TVActorView: View {
    let pluginId: String
    let name: String
    let route: String

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var session: PinSession
    @Environment(\.tvTheme) private var theme
    @Environment(TVNavPath.self) private var nav

    @State private var rows: [ActorFilmRow] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var didLoad = false
    @State private var loadGeneration = 0

    // §13 merge mirrors: copied out of the coordinator on
    // every onChange (the coordinator owns the merge; these
    // are this view's render state). A fresh coordinator is
    // created per reload().
    @State private var mergeCoordinator: ActorMergeCoordinator?
    @State private var contributors: [String] = []
    @State private var mergedAvatarUrl: String?
    @State private var mergeSettled = false
    /// Gate fix G-14: the coordinator's FULL settle (soft
    /// deadline + every deferred source resolved) — the
    /// §13.1f FINALITY branches key on this, exactly as the
    /// iOS ActorView does; the header/running states keep
    /// the soft `mergeSettled` (§14.2).
    @State private var mergeFullySettled = false
    @State private var originFailed = false

    // §13.1e borrowed-avatar state (TopXX only).
    @State private var avatarImage: UIImage?
    @State private var avatarLogged = false

    // Focus-dwell preview state (Detail's discipline, scoped
    // to the focused film instead of the page).
    @State private var focusedRow: ActorFilmRow?
    @State private var previewStream: StreamInfo?
    @State private var previewGeneration = 0
    @State private var previewEpoch = 0
    @State private var previewVisible = false
    @State private var previewPlaying = false
    @State private var previewNoTrailer = false
    @State private var previewLatched = false
    @AppStorage(TVPreviewSettings.defaultsKey) private var previewEnabled = true

    @Namespace private var focusNS

    private var pluginName: String {
        plugins.installedPlugin(id: pluginId)?.manifest.name ?? pluginId
    }

    private var focusedIndex: Int {
        guard let focusedRow else { return 0 }
        return rows.firstIndex { $0.id == focusedRow.id } ?? 0
    }

    /// §13.1c: the header's merged condition — ANY
    /// non-origin contributor with rows on screen makes the
    /// page merged, whatever the origin did: contributed
    /// alongside it (the normal merge), failed (contributors
    /// stand in for it), or settled with 0 rows (gate fix
    /// D-2: the contributors' films are then the page's
    /// content and are never presented as the origin's own
    /// solo page). Solo is exactly: no non-origin
    /// contributor, and no origin failure with contributors.
    private var isMerged: Bool {
        contributors.contains { $0 != pluginId } || (originFailed && !contributors.isEmpty)
    }

    /// §13.1f: the merge is still running and nothing has
    /// landed yet (any loadError state — contributed rows, not
    /// the error surface, are this state's resolution).
    private var isRunningAtZero: Bool {
        didLoad && !mergeFullySettled && rows.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBand
                .padding(.top, 56)
            Spacer().frame(height: 50)
            HStack(alignment: .top, spacing: 64) {
                leftColumn
                    .frame(width: 768)
                // Drawing: the trailer column starts 8 pt
                // below the section-title line (eyebrow top
                // 336 vs 328) — without this offset the
                // preview frame lands at 378 instead of its
                // drawn 386, and the frame title/meta shift
                // up by the same 8.
                rightColumn
                    .frame(width: 928)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusScope(focusNS)
        .tvThemedBackground()
        .onAppear {
            session.touch()
            // Returning from a film's Detail: the latch did
            // its job behind the cover — release it and bump
            // the epoch so a fresh dwell can arm for the
            // currently focused card.
            if previewLatched {
                previewLatched = false
                previewEpoch += 1
            }
        }
        .onDisappear {
            // Cancel the dwell/probe (epoch is in its .task
            // identity) and drop the stream: the preview host
            // dismantles and tears its player down.
            previewEpoch += 1
            previewStream = nil
        }
        .task { if !didLoad { await reload() } }
        .task(id: dwellTaskKey) { await runDwell() }
        .task(id: mergedAvatarUrl) { await loadAvatar() }
        .onChange(of: focusedRow?.id) { _, _ in
            // A new focus owner retires the previous film's
            // preview in the same update: the frame falls back
            // to the newly focused film's still while its own
            // dwell runs.
            previewStream = nil
            previewVisible = false
            previewPlaying = false
            previewNoTrailer = false
        }
        // B-1: the actor screen's own Menu step is ONE pop —
        // back to the origin Detail, whose arbiter then owns
        // the next press (its pop-to-root completes the
        // chain actor → origin Detail → menu root).
        .onExitCommand {
            DiagLog.log("menu", "back-one surface=actor plugin=\(pluginId)")
            nav.pop()
        }
    }

    // MARK: Header (drawing: slot 158×222, eyebrow, name,
    // meta, hint; source chip top-right)

    private var headerBand: some View {
        HStack(alignment: .top, spacing: 32) {
            portraitSlot
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("DIỄN VIÊN")
                        .foregroundStyle(theme.accentSoft)
                    Text("·")
                        .foregroundStyle(theme.textFaint)
                    // §13.1c eyebrow: the origin's name until
                    // a contributor block lands (isMerged),
                    // then the merged form. Finished solo is
                    // byte-identical to 1.3.5.
                    Text(isMerged ? "TỔNG HỢP NHIỀU NGUỒN" : "NGUỒN \(pluginName.uppercased())")
                        .foregroundStyle(theme.textFaint)
                }
                .font(.system(size: 17, weight: .bold))
                .tracking(4)
                .padding(.top, 22)
                Text(name)
                    .font(.system(size: 66, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 10)
                metaLine
                    .padding(.top, 26)
                Text("Giữ yên trên một thẻ để xem trailer · Bấm OK để mở phim")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.textFaint)
                    .padding(.top, 14)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 12) {
                sourceChip
                // §13.1f: the origin-failure retry chip lives
                // in the header band under the source chip, in
                // its own focus section, never the default
                // focus — present only while contributed rows
                // are on screen over a failed origin.
                if originFailed && !rows.isEmpty {
                    retryChip
                }
            }
            .padding(.top, 8)
        }
        .frame(height: 222)
    }

    /// The header slot. Default (almost no JTV source
    /// supplies a portrait): the actor's initial over the
    /// Ultra poster-slot colour, exactly as drawn — a fake
    /// photo is never substituted (plan §2.4). §13.1e: when
    /// the merge borrowed a TopXX avatar and it loaded, the
    /// photo covers the slot instead and the KHÔNG CÓ ẢNH
    /// caption is gone; any load failure falls back to the
    /// drawn slot instantly.
    @ViewBuilder
    private var portraitSlot: some View {
        if let avatarImage {
            Image(uiImage: avatarImage)
                .resizable()
                .scaledToFill()
                .frame(width: 158, height: 222)
                .clipShape(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        } else {
            VStack(spacing: 14) {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 76, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.45))
                Text("KHÔNG CÓ ẢNH")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(2.5)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .frame(width: 158, height: 222)
            .background(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous)
                .fill(theme.isUltra ? Color(red: 0.149, green: 0.149, blue: 0.169) : theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        }
    }

    /// §13.1e: load the borrowed avatar the coordinator
    /// published (TopXX only, by construction of the core).
    /// Runs as .task(id: mergedAvatarUrl): a new URL clears
    /// the slot first; success shows the photo and logs the
    /// borrow once per view (§13.9).
    private func loadAvatar() async {
        avatarImage = nil
        guard let url = mergedAvatarUrl else { return }
        let image = await ImageCacheManager.shared.loadImage(urlString: url, bucket: 720)
        guard !Task.isCancelled, mergedAvatarUrl == url else { return }
        if let image {
            avatarImage = image
            if !avatarLogged {
                avatarLogged = true
                DiagLog.log("actor", "avatar source=topxx")
            }
        }
    }

    /// §13.1c suffixes, appended in this order when they
    /// apply: the origin-failure disclosure (§13.1f), then
    /// the borrowed-avatar credit for the edge where TopXX
    /// resolved the actor but contributed no rows and so is
    /// named nowhere else on the page (§13.1e). In the pure
    /// solo outcome neither applies and the suffix is empty —
    /// the settled-solo line stays byte-identical to 1.3.5.
    private var metaSuffixExtras: String {
        var extras = ""
        if originFailed && !rows.isEmpty {
            extras += " · nguồn chính lỗi tải"
        }
        if avatarImage != nil && !contributors.contains("topxx") {
            extras += " · Ảnh đại diện: TopXX"
        }
        return extras
    }

    @ViewBuilder
    private var metaLine: some View {
        if didLoad {
            if originFailed && mergeFullySettled && rows.isEmpty {
                // §13.1f: the merge settled empty over a
                // failed origin — today's failure copy (the
                // grid zone shows the error surface itself).
                Text("Không tải được danh sách phim")
                    .font(.system(size: 26))
                    .foregroundStyle(theme.textPrimary)
            } else {
                HStack(spacing: 0) {
                    Text("\(rows.count) phim trong danh sách")
                        .foregroundStyle(theme.textPrimary)
                    Text(metaLineSuffix)
                        .foregroundStyle(theme.textDim)
                }
                .font(.system(size: 26))
            }
        } else if loadError != nil {
            Text("Không tải được danh sách phim")
                .font(.system(size: 26))
                .foregroundStyle(theme.textPrimary)
        } else {
            Text("Đang tải danh sách…")
                .font(.system(size: 26))
                .foregroundStyle(theme.textPrimary)
        }
    }

    /// §13.1c meta suffix: running / settled-merged /
    /// settled-solo, plus the ordered extras.
    private var metaLineSuffix: String {
        if !mergeSettled {
            return " · đang gộp thêm từ các nguồn khác…" + metaSuffixExtras
        }
        if isMerged {
            return " · gộp từ \(contributors.count) nguồn theo thứ tự cố định" + metaSuffixExtras
        }
        return " · sắp theo thứ tự nguồn trả về" + metaSuffixExtras
    }

    private var sourceChip: some View {
        HStack(spacing: 8) {
            Text("Nguồn")
                .foregroundStyle(theme.textPrimary)
            Text(sourceChipName)
                .fontWeight(.bold)
                .foregroundStyle(theme.heroMeta)
        }
        .font(.system(size: 24, weight: .semibold))
        .padding(.horizontal, 26)
        .padding(.vertical, 13)
        .background(Capsule().fill(theme.cardFill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5))
    }

    /// §13.1c source chip: the chip always names the ORIGIN
    /// anchor — running, it says the merge is still looking;
    /// settled-merged, it counts the OTHER contributors
    /// (contributors minus the origin when the origin itself
    /// contributed); settled-solo (and pre-load) it is
    /// today's chip verbatim.
    private var sourceChipName: String {
        if didLoad && !mergeSettled {
            return "\(pluginName) · đang tìm thêm"
        }
        if didLoad && isMerged {
            let others = contributors.count - (contributors.contains(pluginId) ? 1 : 0)
            return "\(pluginName) + \(others) nguồn khác"
        }
        return pluginName
    }

    /// §13.1f retry chip: a full reload(), offered only
    /// while a failed origin has contributed rows standing
    /// in for it. TVChip language, its OWN focus section,
    /// never the default focus.
    private var retryChip: some View {
        TVChip(title: "Thử tải lại", selected: false) {
            Task { await reload() }
        }
        .focusSection()
    }

    // MARK: Left column — section row, grid, bottom hint

    /// §13.1f: the empty state exists only once the merge
    /// has SETTLED with zero rows and no origin failure —
    /// while the merge runs at zero rows the page waits
    /// (isRunningAtZero), it does not declare itself empty.
    private var isEmptyResult: Bool { didLoad && loadError == nil && rows.isEmpty && mergeFullySettled }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionRow
            Spacer().frame(height: 22)
            gridZone
                .frame(height: 596)
            Spacer().frame(height: 14)
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 768, height: 1)
            Spacer().frame(height: 16)
            Text("↑↓←→ Duyệt danh sách · OK Mở chi tiết · Menu Quay lại")
                .font(.system(size: 20))
                .foregroundStyle(theme.textFaint)
        }
    }

    private var sectionRow: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(theme.accent)
                .frame(width: 6, height: 36)
            Text(isEmptyResult ? "Chưa có dữ liệu phim" : "Phim có \(name)")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !rows.isEmpty {
                Text(String(format: "%02d / %02d", focusedIndex + 1, rows.count))
                    .font(.system(size: 20))
                    .tracking(1)
                    .foregroundStyle(theme.textFaint)
            }
        }
    }

    /// The focusable Quay lại chip shared by the empty and
    /// running-at-0 branches: it holds the initial focus in
    /// both (Menu also exits — this surface's arbiter).
    private var backChipRow: some View {
        HStack {
            TVChip(title: "Quay lại", selected: false) { nav.pop() }
            Spacer()
        }
    }

    @ViewBuilder
    private var gridZone: some View {
        if isLoading && rows.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, rows.isEmpty && mergeFullySettled {
            // Audit P-4: the actor grid's failure uses the
            // shared error surface with the A-9 default-focus
            // opt-in, so the retry is the landing focus.
            // §13.1f: this surface appears ONLY on a settled
            // zero-row outcome — while the merge runs, or once
            // any contributor has landed, contributed rows win
            // over the error.
            TVErrorState(message: loadError, onRetry: { Task { await reload() } },
                         retryIsDefaultFocus: true)
        } else if isRunningAtZero {
            // §13.1f running-at-0: the waiting line in place
            // of the grid, trailer zone hidden (rightColumn),
            // and the Quay lại chip holding focus exactly as
            // in the empty branch.
            VStack(alignment: .leading, spacing: 22) {
                Text("Đang tìm ở các nguồn khác…")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.textDim)
                backChipRow
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .focusSection()
            .prefersDefaultFocus(true, in: focusNS)
        } else if isEmptyResult {
            // Plan §3: the trailer zone hides and a focusable
            // Quay lại chip holds the initial focus (Menu also
            // exits — this surface's arbiter).
            backChipRow
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()
                .prefersDefaultFocus(true, in: focusNS)
        } else {
            ScrollView {
                VStack(spacing: 28) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(240), spacing: 24), count: 3),
                              spacing: 44) {
                        ForEach(rows) { row in
                            TVGridPosterCell(
                                movie: row.movie,
                                width: 240,
                                isFavorite: favorites.isFavorite(pluginId: row.pluginId, movieId: row.movie.id),
                                onSelect: { openFilm(row) },
                                onLongPress: { favorites.toggle(pluginId: row.pluginId, movie: row.movie) },
                                onFocusChange: { focused in
                                    if focused { focusedRow = row }
                                },
                                selectOnImageFailure: true
                            )
                        }
                    }
                    if isLoadingMore {
                        ProgressView()
                            .tint(.white)
                            .padding(.vertical, 8)
                    }
                    // Bottom sentinel: load-more hangs on the
                    // scroll position (FL-234) and delegates to
                    // the coordinator's lockstep pagination
                    // (§13.5) — it owns every source's cursor.
                    Color.clear
                        .frame(height: 8)
                        .onAppear { Task { await loadMore() } }
                }
            }
            .clipped()
            .focusSection()
            .prefersDefaultFocus(true, in: focusNS)
        }
    }

    // MARK: Right column — trailer zone (drawing: eyebrow +
    // status, 928×522 frame, frame title + meta)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("TRAILER THEO TIÊU ĐIỂM")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(theme.textFaint)
                Spacer(minLength: 0)
                Text(trailerStatusText)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.textDim)
            }
            .frame(height: 40)
            Spacer().frame(height: 10)
            if rows.isEmpty && !isLoading {
                // Plan §3 + §13.1f: with no rows on screen
                // (empty result, settled error, or the merge
                // still running at zero) the trailer zone
                // hides — the zone keeps its geometry so the
                // composition does not jump.
                Color.clear.frame(width: 928, height: 522)
            } else {
                previewFrame
            }
            Spacer().frame(height: 26)
            if let focusedRow {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(focusedRow.movie.title)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if focusedRow.movie.year > 0 {
                        Text(String(focusedRow.movie.year))
                            .font(.system(size: 22))
                            .foregroundStyle(theme.textDim)
                    }
                }
                Text(frameMetaText(focusedRow))
                    .font(.system(size: 22))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .padding(.top, 12)
            }
        }
    }

    private var trailerStatusText: String {
        if previewPlaying { return "Đang phát · Tắt tiếng" }
        if previewNoTrailer { return "Không có trailer" }
        return ""
    }

    /// §13.1d: the frame's meta line names the focused
    /// ROW's source for EVERY card, origin rows included —
    /// the frame is where the card's source matters (dwell
    /// resolution and OK both act through it).
    private func frameMetaText(_ row: ActorFilmRow) -> String {
        var parts = [row.movie.episode_current, row.movie.lang]
            .filter { !$0.isEmpty }
        parts.append("Nguồn \(plugins.installedPlugin(id: row.pluginId)?.manifest.name ?? row.pluginId)")
        return parts.joined(separator: " · ")
    }

    /// The frame's layer stack, in the drawing's fallback
    /// order: the trailer (TVBackdropPreviewHost, fading in
    /// on its first frame exactly as on Detail) → the focused
    /// film's backdrop → its poster (displayBackdrop already
    /// falls back to the poster) → the plain panel + title.
    private var previewFrame: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surfaceBottom)
            if let row = focusedRow {
                if row.movie.displayBackdrop.isEmpty {
                    Text(row.movie.title)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(theme.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(40)
                } else {
                    TVRemoteImage(urlString: row.movie.displayBackdrop, bucket: 1920)
                }
                if let previewStream {
                    TVBackdropPreviewHost(
                        stream: previewStream,
                        onFirstFrame: {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                previewVisible = true
                            }
                            previewPlaying = true
                        },
                        onRetire: { _ in
                            // Mirror Detail: fade first, clear
                            // after — clearing in the same
                            // update would dismantle the host
                            // mid-fade. Generation-guarded.
                            let wasShown = previewVisible
                            withAnimation(.easeInOut(duration: 0.6)) {
                                previewVisible = false
                            }
                            previewPlaying = false
                            if !wasShown {
                                // The attempt concluded without
                                // a frame (low quality / failed /
                                // never ready): the frame falls
                                // back to the still + the note.
                                previewNoTrailer = true
                            }
                            let retiredGeneration = previewGeneration
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(700))
                                guard previewGeneration == retiredGeneration else { return }
                                self.previewStream = nil
                            }
                        })
                        .frame(width: 928, height: 522)
                        .clipped()
                        .opacity(previewVisible ? 1 : 0)
                        .id(previewGeneration)
                }
                if !row.movie.quality.isEmpty {
                    VStack {
                        HStack {
                            Text(row.movie.quality)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.badgeQuality))
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(14)
                }
                if previewPlaying {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Trailer · Tắt tiếng")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundStyle(Color.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                        }
                    }
                    .padding(16)
                }
                if previewNoTrailer && previewStream == nil {
                    VStack {
                        Spacer()
                        HStack {
                            Text("Không có trailer")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.black.opacity(0.45)))
                            Spacer()
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 928, height: 522)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: Intents

    /// Card tap → the film's own Detail, pushed over this
    /// screen (FL-057 prevention: the destination carries the
    /// FILM's identity, never the origin context — §13.6: the
    /// ROW's plugin, so a contributed film opens in its own
    /// source). The push also sets the play latch so no
    /// preview re-arms behind the Detail, and freezes the
    /// merge (§13.1g): this visit's list never changes again.
    private func openFilm(_ row: ActorFilmRow) {
        previewLatched = true
        previewEpoch += 1
        previewStream = nil
        mergeCoordinator?.freeze()
        DiagLog.log("actor", "open-film plugin=\(row.pluginId) movie=\(row.movie.id)")
        nav.push(.movie(MovieRoute(pluginId: row.pluginId, movie: row.movie)))
    }

    // MARK: List loading (TVBrowseView's discipline for the
    // origin's page 1 — generation-guarded; the coordinator
    // owns everything after, §13.5/§13.8)

    private func reload() async {
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        // Gate fix (F-A2/C-2): the OUTGOING coordinator is
        // frozen BEFORE its replacement is installed — its
        // target/budget tasks are cancelled and its late
        // completions drop on the coordinator's frozen
        // guards, so a superseded visit can never write into
        // this reload's mirrors.
        mergeCoordinator?.freeze()
        // Fresh coordinator per reload (§13.8). Its onChange
        // mirrors the published state into this view's @State;
        // the capture list binds the @State wrappers directly
        // (not the view value), so no view ↔ coordinator
        // retain cycle forms through the mergeCoordinator
        // storage — and the coordinator itself is captured
        // WEAKLY (gate fix F-A2): the closure lives ON the
        // coordinator, so a strong capture would close a
        // coordinator → closure → coordinator self-retain
        // cycle and leak one coordinator per visit; the
        // view's @State storage is the sole strong owner.
        // The mirrors reset with the new coordinator — a
        // retry reload is a FULL reload (§13.1f): the grid
        // resets and focus returns to the first card.
        let coordinator = ActorMergeCoordinator(service: service, originPluginId: pluginId, name: name)
        coordinator.originRoute = route
        coordinator.onChange = { [weak coordinator, rowsBox = _rows, contributorsBox = _contributors,
                                  avatarBox = _mergedAvatarUrl, settledBox = _mergeSettled,
                                  fullySettledBox = _mergeFullySettled,
                                  failedBox = _originFailed] in
            guard let coordinator,
                  let rowsBox, let contributorsBox, let avatarBox,
                  let settledBox, let fullySettledBox, let failedBox
            else { return }
            rowsBox.wrappedValue = coordinator.rows
            contributorsBox.wrappedValue = coordinator.contributors
            avatarBox.wrappedValue = coordinator.avatarUrl
            settledBox.wrappedValue = coordinator.settled
            fullySettledBox.wrappedValue = coordinator.fullySettled
            failedBox.wrappedValue = coordinator.originFailed
        }
        mergeCoordinator = coordinator
        rows = []
        contributors = []
        mergedAvatarUrl = nil
        mergeSettled = false
        mergeFullySettled = false
        originFailed = false
        focusedRow = nil
        do {
            let result = try await service.list(pluginId: pluginId, slug: route,
                                                filters: ListFilters(), page: 1)
            guard gen == loadGeneration else { return }
            // The coordinator id-dedupes the origin block as
            // it appends (replacing uniquedById()); begin()
            // publishes synchronously, so the mirrored rows
            // already carry the deduped count for this line.
            coordinator.begin(originFirstPage: result, originFailed: false)
            DiagLog.log("actor", "list plugin=\(pluginId) count=\(rows.count) totalPages=\(max(result.pagination.totalPages, 1))")
        } catch {
            guard gen == loadGeneration else { return }
            // L-15: cancellation is not an error — an
            // instance torn down mid-load must not flash
            // the error state or mark the origin failed
            // for a merge nobody is watching.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                DiagLog.log("actor", "list cancelled plugin=\(pluginId)")
                // Gate fix (C-M3, mirrored from iOS): a
                // cancelled reload leaves the view UNLOADED
                // — didLoad stays false. The fresh
                // coordinator above was never begun, so
                // claiming a completed load here would
                // strand the page in the still-merging
                // branch with no merge running and no retry
                // path; with didLoad false the page keeps
                // its pre-load surface and re-entering
                // re-runs the load. (Beginning the
                // coordinator as origin-failed instead would
                // contradict the L-15 rule above: a
                // cancelled load is not an origin failure.)
                isLoading = false
                return
            } else {
                loadError = "Không tải được danh sách phim"
                DiagLog.log("actor", "list failed plugin=\(pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
                // §13.1f: the targets still run over a failed
                // origin — contributed rows win over the error
                // surface.
                coordinator.begin(originFirstPage: nil, originFailed: true)
            }
        }
        if gen == loadGeneration {
            isLoading = false
            didLoad = true
        }
    }

    /// §13.5 lockstep pagination, owned by the coordinator
    /// (every source's cursor, canonical block order, the
    /// same dedupe). The shell no longer logs `list.more` —
    /// §13.9 assigns the cycle to the coordinator's
    /// `merge more` line.
    private func loadMore() async {
        guard didLoad, !isLoading, !isLoadingMore,
              let coordinator = mergeCoordinator else { return }
        isLoadingMore = true
        await coordinator.loadMore()
        isLoadingMore = false
    }

    // MARK: Focus-dwell preview

    private var dwellTaskKey: String {
        "\(focusedRow?.id ?? "-")#\(previewEpoch)#\(previewEnabled)"
    }

    /// One attempt per dwell: sleep 1.5 s (SwiftUI cancels
    /// this task on any focus move — the key changes), resolve,
    /// and publish only if this attempt is still the current
    /// one and the play latch is open (F-B1 discipline: the
    /// latch is re-checked at the publish point, not only at
    /// arming).
    private func runDwell() async {
        guard let row = focusedRow, previewEnabled, !previewLatched else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let stream = await resolveActorPreview(row: row)
        guard !Task.isCancelled, generation == previewGeneration, !previewLatched else { return }
        if let stream {
            previewNoTrailer = false
            previewStream = stream
        } else {
            previewStream = nil
            previewNoTrailer = true
            DiagLog.log("actor", "preview outcome=no-trailer plugin=\(row.pluginId) movie=\(row.movie.id)")
        }
    }

    /// The actor screen's preview resolution: the list-item
    /// previewUrl fast path first (plan §2.5 — the URL
    /// declares no height, so the declared gate here can only
    /// convict a KNOWN-low source; the host's measured gate
    /// decides the rest), otherwise the focused film's detail
    /// through the shared probe, exactly as Detail runs it.
    /// §13.6/§13.8: every rung runs with the ROW's plugin —
    /// a contributed film previews through its own source.
    private func resolveActorPreview(row: ActorFilmRow) async -> StreamInfo? {
        let movie = row.movie
        if !movie.previewUrl.isEmpty, MediaURL.isDirectMedia(movie.previewUrl) {
            let declaredRank = max(TVPreviewProbe.declaredQualityRank(movie.quality),
                                   TVPreviewProbe.declaredQualityRank(movie.episode_current))
            if declaredRank == 1 {
                DiagLog.log("actor", "preview outcome=low-quality-declared plugin=\(row.pluginId) movie=\(movie.id)")
                return nil
            }
            DiagLog.log("actor", "preview rung=preview-url host=\(URL(string: movie.previewUrl)?.host ?? "?")")
            return StreamInfo(url: movie.previewUrl, headers: [:])
        }
        guard let bundle = try? await service.detail(pluginId: row.pluginId, movieId: movie.id) else {
            DiagLog.log("actor", "preview outcome=detail-failed plugin=\(row.pluginId) movie=\(movie.id)")
            return nil
        }
        var snap = bundle.detail.asMovie
        snap.id = movie.id
        return await TVPreviewProbe.resolve(
            service: service, pluginId: row.pluginId,
            pluginName: plugins.installedPlugin(id: row.pluginId)?.manifest.name ?? "",
            isManga: false, detail: bundle.detail,
            detailStream: bundle.detailStream, movie: snap)
    }
}
