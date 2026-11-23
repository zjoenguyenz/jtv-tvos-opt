import SwiftUI

/// JTV tvOS Phase 2 — theme system (foundation, fixed contract).
///
/// Two themes, runtime-selectable, ONE layout: only the token
/// values change. The default everywhere is `.ultraBlack` —
/// glossy black in JoeTV Ultra's design language (PHASE2-JOETV-
/// STUDY §1.2). The second theme, `.jtOriginal`, carries the
/// iOS app's approved tokens (jtv-ios/JTV/Theme.swift — deep-navy
/// glass, cyan accent, amber badges; the Phase 2 mockups' look).
///
/// Architecture mirrors JoeTV's (study §1.1): one value type of
/// tokens, resolved from the theme id, injected at the root via
/// the environment; every leaf reads `@Environment(\.tvTheme)`.
/// JoeTV uses a classic `EnvironmentKey` for this
/// (JoeTheme.swift:206-215) and this tree has no `@Entry`
/// precedent, so the classic form is used here too.
///
/// Poster geometry is owner-fixed for BOTH themes: poster art
/// corner radius is 24 on all four corners, and the focus ring
/// is the IDENTICAL RoundedRectangle(24) drawn as an inset
/// strokeBorder on the art's own frame (study §1.7 / §5.6 —
/// JoeTV Ultra precedent: clip + ring on the same rect).

// MARK: - Theme identity

enum JTVThemeID: String, CaseIterable, Identifiable {
    case ultraBlack
    case jtOriginal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ultraBlack: return "Đen bóng Ultra"
        case .jtOriginal: return "JTV gốc"
        }
    }

    var tokens: TVThemeTokens { TVThemeTokens.tokens(for: self) }
}

/// Persistence for the theme choice. The root view and Settings
/// both bind `@AppStorage(TVThemeStore.defaultsKey)` with the
/// default `JTVThemeID.ultraBlack.rawValue`.
enum TVThemeStore {
    static let defaultsKey = "jtvtv_theme_id"
}

// MARK: - Tokens

struct TVThemeTokens: Sendable {
    /// Which theme these tokens belong to.
    let id: JTVThemeID
    /// True only for the Ultra-derived theme — for the few
    /// branch-local treatments (e.g. the Ultra poster slot
    /// colour and its cyan focused title, study §1.5).
    let isUltra: Bool

    // Background gradient (top → mid → bottom).
    let backgroundTop: Color
    let backgroundMid: Color
    let backgroundBottom: Color

    // Accents.
    /// Selected fill.
    let accent: Color
    /// Primary-action fill (JoeTV `accent2`).
    let accent2: Color
    /// Accent at reduced strength / lighter variant, for
    /// text-on-dark uses.
    let accentSoft: Color
    /// Foreground that reads on `accent` fills.
    let onAccent: Color

    // Focus.
    let focusRing: Color
    let ringWidth: CGFloat

    // Text.
    let textPrimary: Color
    let textDim: Color
    let textFaint: Color
    /// Gold/amber meta colour (ratings, hero meta rows).
    let heroMeta: Color

    // Surfaces.
    let cardFill: Color
    let cardStroke: Color
    /// Card-face gradient stops (JoeTV surfaceTop → surfaceBottom).
    let surfaceTop: Color
    let surfaceBottom: Color
    /// Settings input bar fill (Ultra: owner-chosen #2F3644).
    let fieldBar: Color

    // Geometry.
    let cardRadius: CGFloat
    /// Owner-fixed: 24 on all four corners, every poster cell,
    /// both themes.
    let posterRadius: CGFloat

    // Badges.
    let badgeQuality: Color
    let badgeEpisode: Color

    // Backdrop scrim.
    /// Floor opacity the backdrop scrim never drops below
    /// inside the text zone (Ultra token, study §1.2).
    let scrimFloor: Double
    /// Vertical backdrop scrim stops (top → bottom), per
    /// study §2.4 for each theme.
    let scrimStops: [Gradient.Stop]

    var backgroundGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: backgroundTop, location: 0),
                .init(color: backgroundMid, location: 0.45),
                .init(color: backgroundBottom, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    var surfaceGradient: LinearGradient {
        LinearGradient(colors: [surfaceTop, surfaceBottom],
                       startPoint: .top, endPoint: .bottom)
    }

    var backdropScrim: LinearGradient {
        LinearGradient(stops: scrimStops, startPoint: .top, endPoint: .bottom)
    }

    static func tokens(for id: JTVThemeID) -> TVThemeTokens {
        switch id {
        case .ultraBlack: return .ultraBlack
        case .jtOriginal: return .jtOriginal
        }
    }

    // MARK: Ultra — glossy black (JoeTV Ultra, study §1.2)

    static let ultraBlack = TVThemeTokens(
        id: .ultraBlack,
        isUltra: true,
        // "Đen bóng" sheen: #0A0A0A → #050505 → black, all
        // stops kept very dark (bg #0A0A0A, JoeTheme.swift:176).
        backgroundTop: Color(red: 0.039, green: 0.039, blue: 0.039),
        backgroundMid: Color(red: 0.020, green: 0.020, blue: 0.020),
        backgroundBottom: .black,
        accent: Color(red: 0.878, green: 0.169, blue: 0.227),       // #E02B3A
        accent2: Color(red: 0.784, green: 0.118, blue: 0.188),      // #C81E30
        // Derived lighter variant of the accent for text-on-dark
        // (JoeTV has no such token; derived from `accent`).
        accentSoft: Color(red: 0.950, green: 0.350, blue: 0.420),
        onAccent: .white,
        focusRing: Color(red: 0.0, green: 0.898, blue: 1.0),        // #00E5FF
        ringWidth: 4,
        textPrimary: .white,
        textDim: Color(red: 0.659, green: 0.659, blue: 0.659),      // #A8A8A8 (meta)
        // Derived: JoeTV Ultra carries no faint token; white at
        // reduced opacity, one step below `textDim`.
        textFaint: Color.white.opacity(0.45),
        heroMeta: Color(red: 1.0, green: 0.780, blue: 0.349),       // #FFC759 gold
        // JoeTV's actual card values (study §1.2): rest fill is
        // surface2 #1C1C1C, rest stroke white 0.14.
        cardFill: Color(red: 0.110, green: 0.110, blue: 0.110),     // #1C1C1C
        cardStroke: Color.white.opacity(0.14),
        surfaceTop: Color(red: 0.137, green: 0.137, blue: 0.137),   // #232323
        surfaceBottom: Color(red: 0.090, green: 0.090, blue: 0.090), // #171717
        fieldBar: Color(red: 0.184, green: 0.212, blue: 0.267),     // #2F3644
        cardRadius: 10,
        posterRadius: 24,
        // Quality badge: JoeTV's IMDb gold (#F5C518, study §1.5),
        // black text. Episode badge: the accent red, white text.
        badgeQuality: Color(red: 0.961, green: 0.773, blue: 0.094),
        badgeEpisode: Color(red: 0.878, green: 0.169, blue: 0.227),
        scrimFloor: 0.55,
        // Ultra detail vertical melt (study §2.4):
        // black 0.30 @0 → clear @0.35 → bg 0.88 @0.85 → bg @1.
        scrimStops: [
            .init(color: Color.black.opacity(0.30), location: 0),
            .init(color: .clear, location: 0.35),
            .init(color: Color.black.opacity(0.88), location: 0.85),
            .init(color: .black, location: 1),
        ]
    )

    // MARK: JTV Original (iOS Theme.swift tokens)

    static let jtOriginal = TVThemeTokens(
        id: .jtOriginal,
        isUltra: false,
        backgroundTop: Color(red: 0.016, green: 0.071, blue: 0.180), // #04122E
        backgroundMid: Color(red: 0.039, green: 0.141, blue: 0.337), // #0A2456
        backgroundBottom: .black,
        accent: Color(red: 0.220, green: 0.741, blue: 0.973),         // #38BDF8
        // Derived darker cyan for primary-action fills (iOS has
        // a single accent; derived from `accent`).
        accent2: Color(red: 0.100, green: 0.550, blue: 0.850),
        accentSoft: Color(red: 0.560, green: 0.870, blue: 0.990),
        onAccent: .black,
        // The mockups' white ring.
        focusRing: .white,
        ringWidth: 3,
        textPrimary: .white,
        textDim: Color.white.opacity(0.62),
        textFaint: Color.white.opacity(0.38),
        heroMeta: Color(red: 0.961, green: 0.710, blue: 0.267),       // amber #F5B544
        cardFill: Color.white.opacity(0.08),                          // glassFill
        cardStroke: Color.white.opacity(0.12),                        // glassStroke
        surfaceTop: Color(red: 0.039, green: 0.141, blue: 0.337),
        surfaceBottom: Color(red: 0.016, green: 0.071, blue: 0.180),
        // Derived navy bar from bgMid (iOS has no Settings bar
        // token; the bar is a tvOS-only surface).
        fieldBar: Color(red: 0.070, green: 0.180, blue: 0.380),
        cardRadius: 18,
        posterRadius: 24,
        badgeQuality: Color(red: 0.961, green: 0.710, blue: 0.267),   // amber
        badgeEpisode: Color(red: 0.220, green: 0.741, blue: 0.973),   // accent
        scrimFloor: 0.55,
        // iOS hero fade (DetailView hero): clear → bgTop 0.55 → bgTop.
        scrimStops: [
            .init(color: .clear, location: 0),
            .init(color: Color(red: 0.016, green: 0.071, blue: 0.180).opacity(0.55), location: 0.55),
            .init(color: Color(red: 0.016, green: 0.071, blue: 0.180), location: 1),
        ]
    )
}

// MARK: - Environment injection (classic EnvironmentKey form)

private struct TVThemeKey: EnvironmentKey {
    static let defaultValue: TVThemeTokens = .ultraBlack
}

extension EnvironmentValues {
    var tvTheme: TVThemeTokens {
        get { self[TVThemeKey.self] }
        set { self[TVThemeKey.self] = newValue }
    }
}

// MARK: - Themed background

private struct TVThemedBackgroundView: View {
    @Environment(\.tvTheme) private var theme

    var body: some View {
        theme.backgroundGradient
            .ignoresSafeArea()
    }
}

extension View {
    /// Full-bleed app background gradient from the theme tokens.
    func tvThemedBackground() -> some View {
        background(TVThemedBackgroundView())
    }
}

// MARK: - Shared focus construction (Settings recipe, generalised)
//
// The device-proven recipe from TVSettingsView.swift (survey
// §1.2–§1.4), re-declared here at internal scope with TV-
// prefixed names so every Phase 2 screen shares ONE source of
// truth. The fileprivate originals in TVSettingsView.swift stay
// in place untouched; inside that file they shadow these.
//
// The construction, in both places: a ButtonStyle that returns
// the label untouched PLUS `.focusEffectDisabled()` — button
// style and focus effect are distinct layers and both are off,
// so no system platter can appear — and every focusable paints
// its OWN inset ring (strokeBorder) inside its own frame.

struct TVCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct TVCardButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(TVCardButtonStyle())
            .focusEffectDisabled()
    }
}

extension View {
    func tvCardButton() -> some View {
        modifier(TVCardButton())
    }
}

/// The StatusRow ring chain as a reusable modifier: a rounded-
/// rect fill that lifts when focused (focused ? 0.16 : base)
/// plus an INSET strokeBorder ring (focused ? ring : clear) —
/// geometrically incapable of extending past the element's own
/// frame onto neighbouring content.
///
/// `isFocused` is the caller's focus state: pass the `@FocusState`
/// value directly, or the binding form `init(focus:)` which reads
/// the binding's current value (the owning view re-renders when
/// its focus state changes, so the modifier is rebuilt with the
/// fresh value).
struct FocusInsetRing: ViewModifier {
    let isFocused: Bool
    var radius: CGFloat
    var color: Color
    var width: CGFloat
    var baseFill: Color
    var focusedFill: Color

    init(isFocused: Bool,
         radius: CGFloat = 16,
         color: Color = .white,
         width: CGFloat = 3,
         baseFill: Color = Color.white.opacity(0.05),
         focusedFill: Color = Color.white.opacity(0.16)) {
        self.isFocused = isFocused
        self.radius = radius
        self.color = color
        self.width = width
        self.baseFill = baseFill
        self.focusedFill = focusedFill
    }

    init(focus: FocusState<Bool>.Binding,
         radius: CGFloat = 16,
         color: Color = .white,
         width: CGFloat = 3,
         baseFill: Color = Color.white.opacity(0.05),
         focusedFill: Color = Color.white.opacity(0.16)) {
        self.init(isFocused: focus.wrappedValue,
                  radius: radius, color: color, width: width,
                  baseFill: baseFill, focusedFill: focusedFill)
    }

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(isFocused ? focusedFill : baseFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(isFocused ? color : .clear,
                              lineWidth: isFocused ? width : 0))
    }
}

extension View {
    func tvFocusInsetRing(isFocused: Bool,
                          radius: CGFloat = 16,
                          color: Color = .white,
                          width: CGFloat = 3,
                          baseFill: Color = Color.white.opacity(0.05),
                          focusedFill: Color = Color.white.opacity(0.16)) -> some View {
        modifier(FocusInsetRing(isFocused: isFocused, radius: radius,
                                color: color, width: width,
                                baseFill: baseFill, focusedFill: focusedFill))
    }

    func tvFocusInsetRing(focus: FocusState<Bool>.Binding,
                          radius: CGFloat = 16,
                          color: Color = .white,
                          width: CGFloat = 3,
                          baseFill: Color = Color.white.opacity(0.05),
                          focusedFill: Color = Color.white.opacity(0.16)) -> some View {
        modifier(FocusInsetRing(focus: focus, radius: radius,
                                color: color, width: width,
                                baseFill: baseFill, focusedFill: focusedFill))
    }
}

/// Applies a FocusState binding only when one was handed in
/// (shared form of TVSettingsView's EntryFocusModifier).
struct TVEntryFocusModifier: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
        } else {
            content
        }
    }
}

// MARK: - Glass card surface

/// Glass card background from the theme tokens: cardFill +
/// cardStroke rounded rect (the iOS `glassCard` shape, themed).
/// The clip is part of the helper, so a focus ring must be
/// applied AFTER this modifier to stay visible.
struct TVGlassCard: ViewModifier {
    @Environment(\.tvTheme) private var theme
    var radius: CGFloat?

    func body(content: Content) -> some View {
        let r = radius ?? theme.cardRadius
        content
            .background(RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
    }
}

extension View {
    func tvGlassCard(radius: CGFloat? = nil) -> some View {
        modifier(TVGlassCard(radius: radius))
    }
}

// MARK: - Section header

/// Section header: accent bar + bold title (+ chevron when it
/// acts). The iOS SectionHeader (4×18 bar, 17 pt title) scaled
/// for TV. When `action` is non-nil the whole header is ONE
/// focusable Button built with the shared card-button recipe
/// and an inset focus ring; when nil it is a plain label.
struct TVSectionHeader: View {
    let title: String
    var action: (() -> Void)?

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    init(title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { label }
                .tvCardButton()
                .focused($isFocused)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(theme.accent)
                .frame(width: 6, height: 36)
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.10) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : .clear,
                          lineWidth: isFocused ? theme.ringWidth : 0))
    }
}
