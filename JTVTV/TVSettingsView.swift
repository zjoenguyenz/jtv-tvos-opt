import SwiftUI

/// Settings (Phase 1 shell; container/focus structure rebuilt
/// in Phase C for L-T01 — Diagnosis §4.1/§4.2).
///
/// Under the owner's bundling ruling every credential arrives
/// inside the build, so there are NO editable credential fields
/// here at all: each row is status-only, read from the
/// corresponding `BundledSecrets` value, and no part of any
/// secret value is ever displayed. Per the owner's standing
/// Settings design ruling there is no white outer frame around
/// rows, and a configured row carries a green dot/tick.
///
/// The one value read for the About section comes from the
/// bundle (never hardcoded); the app presents under its
/// disguised display name, "Media Service".
///
/// Phase C structure (mirrors JoeTV's JoeSettingsView,
/// JoeSettings.swift:73,78,98-266,306,314-316): a vertical
/// ScrollView over a single LazyVStack, grouped into
/// .focusSection() regions. On tvOS scrolling is a side effect
/// of focus movement, so the focus chain is UNBROKEN over the
/// full vertical extent: EVERY region contains at least one
/// focusable descendant, the status rows and the About rows are
/// focusable at ROW level (never a container-level
/// .focusable()), and the About region's focusable stops sit
/// AT the About rows themselves, so focus-driven scrolling
/// brings both rows fully on screen (Diagnosis §4.1.4). There
/// is deliberately no .onMoveCommand or other movement trap
/// (§4.1.7): geometric movement on this single sectioned
/// column does the routing unaided, as in JoeTV.
struct TVSettingsView: View {
    @EnvironmentObject private var session: PinSession

    /// Theme choice (Phase 2): the same @AppStorage key the
    /// root binds; writing it re-renders the whole app with the
    /// picked theme's tokens (runtime-selectable themes, owner
    /// ruling 2026-11-20 — default glossy black "Đen bóng Ultra").
    @AppStorage(TVThemeStore.defaultsKey) private var themeRaw = JTVThemeID.ultraBlack.rawValue

    /// NEXT-D D6 (1.3.0): backdrop-preview kill switch,
    /// default ON. Off → the Detail dwell task returns
    /// immediately and Detail is identical to the pre-preview
    /// build. The same key is read by TVDetailView.
    @AppStorage(TVPreviewSettings.defaultsKey) private var previewEnabled = true
    @FocusState private var previewButtonFocused: Bool

    /// B-2 (1.3.9, owner ruling 2026-11-23): auto-advance to
    /// the next episode at item end — default ON. The same
    /// key is read by TVPlayerSession at every item end.
    @AppStorage(TVAutoAdvance.defaultsKey) private var autoAdvanceEnabled = true
    @FocusState private var autoAdvanceButtonFocused: Bool

    /// Entry focus (Diagnosis §4.1.6, JoeSettings.swift:306
    /// shape), retargeted by A-7 (1.3.9): the landing focus
    /// is the first ACTIONABLE row — the first theme chip.
    /// The credential status rows stay focusable for
    /// traversal; they no longer own the entry focus.
    @FocusState private var firstRowFocused: Bool
    @FocusState private var pinButtonFocused: Bool
    @FocusState private var logButtonFocused: Bool
    @FocusState private var netProbeButtonFocused: Bool

    /// Cover presentation for the two action rows (Diagnosis
    /// §4.2, JoeSettings.swift:58,314-316 shape): plain Buttons
    /// set these; the pushed NavigationLink shape is gone.
    @State private var showPinChange = false
    @State private var showLogExport = false
    @State private var showNetProbe = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                // The visible heading stays on screen, carried
                // in-column now that the NavigationStack (and
                // its nav title) is gone — as JoeTV screens
                // carry their titles in-body.
                Text("Cài đặt")
                    .font(.system(size: 56, weight: .heavy))

                credentialsSection
                    .focusSection()

                themeSection
                    .focusSection()

                previewSection
                    .focusSection()

                playbackSection
                    .focusSection()

                if BundledSecrets.pinConfigured {
                    securitySection
                        .focusSection()
                }

                diagnosticsSection
                    .focusSection()

                aboutSection
                    .focusSection()
            }
            .padding(60)
        }
        .defaultFocus($firstRowFocused, true)
        .fullScreenCover(isPresented: $showPinChange) {
            // Plumbing only (Diagnosis §4.4 note): PinChangeView
            // declares its own .navigationTitle and dismisses
            // itself, i.e. it was written to live inside a
            // navigation context. The cover therefore carries
            // its own NavigationStack so the view's internals,
            // flow and texts are completely unchanged.
            NavigationStack {
                PinChangeView()
            }
        }
        .fullScreenCover(isPresented: $showLogExport) {
            LogExportView()
        }
        .fullScreenCover(isPresented: $showNetProbe) {
            TVNetProbeView()
        }
        .onAppear { session.touch() }
    }

    // MARK: - Credential status (bundled, status-only)

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dịch vụ đã nạp sẵn")
                .font(.system(size: 30, weight: .semibold))
            StatusRow(label: "Real-Debrid",
                      configured: Self.isConfigured(BundledSecrets.rdToken))
            StatusRow(label: "TorBox",
                      configured: Self.isConfigured(BundledSecrets.torboxToken))
            StatusRow(label: "Premiumize",
                      configured: Self.isConfigured(BundledSecrets.premiumizeToken))
            StatusRow(label: "MediaFusion",
                      configured: Self.isConfigured(BundledSecrets.mfURL))
            Text("Mọi thông tin đăng nhập được nạp sẵn trong bản cài đặt — không cần nhập trên TV và không mất khi cài lại.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
        }
    }

    private static func isConfigured(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Appearance (Phase 2 theme picker)

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Giao diện")
                .font(.system(size: 30, weight: .semibold))
            HStack(spacing: 16) {
                ForEach(JTVThemeID.allCases) { id in
                    TVChip(title: id.displayName,
                           selected: themeRaw == id.rawValue,
                           entryFocus: id == JTVThemeID.allCases.first ? $firstRowFocused : nil) {
                        themeRaw = id.rawValue
                    }
                }
            }
            Text("Theme áp dụng ngay cho toàn bộ app. Mặc định: Đen bóng Ultra.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Backdrop preview (NEXT-D D6)

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Xem trước nền")
                .font(.system(size: 30, weight: .semibold))
            Button {
                previewEnabled.toggle()
            } label: {
                ActionRowLabel {
                    Label(previewEnabled ? "Đang bật — chạm để tắt" : "Đang tắt — chạm để bật",
                          systemImage: previewEnabled ? "play.rectangle.fill" : "play.rectangle")
                }
            }
            .jtvCardButton()
            .focused($previewButtonFocused)
            Text("Khi mở chi tiết phim, nền sẽ tự chạy một đoạn video xem trước (không tiếng) sau khoảng 1,5 giây. Tắt thì màn hình chi tiết giữ nguyên ảnh nền tĩnh như trước.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Playback (B-2, 1.3.9)

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Phát lại")
                .font(.system(size: 30, weight: .semibold))
            Button {
                autoAdvanceEnabled.toggle()
            } label: {
                ActionRowLabel {
                    Label(autoAdvanceEnabled ? "Tự chạy tập tiếp theo — Đang bật" : "Tự chạy tập tiếp theo — Đang tắt",
                          systemImage: autoAdvanceEnabled ? "play.circle.fill" : "play.circle")
                }
            }
            .jtvCardButton()
            .focused($autoAdvanceButtonFocused)
            Text("Khi một tập kết thúc, tập tiếp theo của cùng nguồn sẽ tự phát. Tắt thì app dừng ở cuối tập và hiện hàng nút Tập trước / Xem lại / Tập tiếp theo.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - App lock

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Khóa app")
                .font(.system(size: 30, weight: .semibold))
            Button {
                showPinChange = true
            } label: {
                ActionRowLabel {
                    Label("Đổi mã khóa app", systemImage: "lock.rotation")
                }
            }
            .jtvCardButton()
            .focused($pinButtonFocused)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chẩn đoán")
                .font(.system(size: 30, weight: .semibold))
            Button {
                showLogExport = true
            } label: {
                ActionRowLabel {
                    Label("Gửi log chẩn đoán", systemImage: "doc.text.magnifyingglass")
                }
            }
            .jtvCardButton()
            .focused($logButtonFocused)
            Text("Khi app gặp lỗi, mở màn hình này và tải file log về iPhone để gửi lại. Log không chứa token hay link đã ký.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
            Button {
                showNetProbe = true
            } label: {
                ActionRowLabel {
                    Label("Đo đường truyền", systemImage: "network")
                }
            }
            .jtvCardButton()
            .focused($netProbeButtonFocused)
            Text("Đo thử DNS và kết nối HTTPS tới các máy chủ phim ngay trên TV; kết quả ghi vào log chẩn đoán ở trên.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Giới thiệu")
                .font(.system(size: 30, weight: .semibold))
            AboutRow(label: "Ứng dụng", value: "Media Service")
            AboutRow(label: "Phiên bản", value: "\(appVersion) (\(appBuild))")
        }
    }
}

// MARK: - Focusable rows (row-level focus, bounded visuals)
//
// Every focusable element on this screen paints its OWN
// bounded focus indication: a rounded-rect fill inside the
// row's own frame plus an INSET ring (strokeBorder) that is
// geometrically incapable of extending past the row onto
// neighbouring text — the JoeTV card construction
// (JoeTheme.swift:543-555 + the JoeSecondaryLabel recipe),
// which retires the system List-row platter (Diagnosis §3).
// The system platter is disabled for the Buttons by
// .jtvCardButton(); the focusable rows draw inside their own
// frames only.

/// One credential status row: label on the left; on the right
/// either a green dot + "Đã cấu hình ✓" or "Chưa cấu hình".
/// The secret value itself never appears, in whole or in part.
/// Focusable at row level so the credentials region carries
/// the focus chain (Diagnosis §4.1.2/§4.1.5).
private struct StatusRow: View {
    let label: String
    let configured: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if configured {
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
                Text("Đã cấu hình ✓")
                    .foregroundStyle(.secondary)
            } else {
                Text("Chưa cấu hình")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 28))
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(isFocused ? Color.white.opacity(0.16)
                            : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(isFocused ? Color.white : .clear,
                          lineWidth: isFocused ? 3 : 0))
        .focusable()
        .focusEffectDisabled()
    }
}

/// One About row, focusable at row level: the About region's
/// focusable stops sit AT the About rows (Diagnosis §4.1.4),
/// so focus-driven scrolling brings both rows fully on screen
/// and they stay readable while focus is in this region.
private struct AboutRow: View {
    let label: String
    let value: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 28))
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(isFocused ? Color.white.opacity(0.16)
                            : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(isFocused ? Color.white : .clear,
                          lineWidth: isFocused ? 3 : 0))
        .focusable()
        .focusEffectDisabled()
    }
}

/// The label of an action Button: the row's content on a
/// capsule, with the focused state drawn as an inset ring
/// INSIDE the capsule (JoeTheme.swift:543-555 construction —
/// the custom button style below adds no system effects, so
/// this label is the only focus treatment).
private struct ActionRowLabel<Content: View>: View {
    let content: Content
    @Environment(\.isFocused) private var isFocused

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .font(.system(size: 28, weight: .semibold))
            .padding(.horizontal, 36)
            .padding(.vertical, 17)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(
                isFocused ? Color.white : Color.white.opacity(0.25),
                lineWidth: isFocused ? 3 : 1.5))
    }
}

// MARK: - Card button construction (JoeTV shape)
//
// JoeTheme.swift:543-555: a custom ButtonStyle that returns
// the label untouched ("adds no existing effects for pressing
// and focused states", WWDC20-10042) PLUS
// .focusEffectDisabled() — button style and focus effect are
// distinct layers and both are off, so no system platter can
// appear under or over the label's own inset ring.

private struct JTVCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct JTVCardButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(JTVCardButtonStyle())
            .focusEffectDisabled()
    }
}

extension View {
    fileprivate func jtvCardButton() -> some View {
        modifier(JTVCardButton())
    }
}
