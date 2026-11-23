import Foundation
import SwiftUI

/// JTV tvOS Phase 3 — the shared subtitle system (plan §4):
/// the selection types both surfaces speak, the language
/// matching behind the default rule, the sidecar cue store
/// (fetch + parse) for the AV surface's overlay, the shared
/// subtitle panel (§4.3), and that overlay (§4.2).
///
/// Rendering ownership (§4.2, the 5.6.2 rule): on the AV
/// surface AVFoundation renders embedded tracks and this
/// file's overlay renders ONLY a selected sidecar file track;
/// on the KS surface the KS layer renders everything and the
/// overlay never exists there.

// MARK: - Selection model

/// One subtitle selection, in surface-neutral terms. Hosts
/// translate it to their own machinery (AV media-selection
/// group option / KS `layer.select(subtitleInfo:)`).
enum TVSubtitleChoice: Equatable {
    case off
    /// An embedded track, keyed by the surface's own stable
    /// key (AV: language tag + display name; KS: subtitleID).
    case embedded(key: String, displayName: String)
    /// A sidecar file from `StreamInfo.subtitles`.
    case file(SubtitleTrack)
}

/// What a host must do at item-ready (§4.4).
enum TVSubtitleDirective {
    case applyDefault
    case applyManual(TVSubtitleChoice)
}

/// One embedded track as the panel lists it.
struct TVEmbeddedTrackRef: Identifiable, Equatable {
    let key: String
    let displayName: String
    /// Language code/tag the host knows for this track, when
    /// any — used only by the AutoSub offer rule (§4.5).
    var languageHint: String = ""

    var id: String { key }
}

struct TVSubtitleCatalog: Equatable {
    var embedded: [TVEmbeddedTrackRef] = []
}

// MARK: - Language matching

/// Word-token language matching (JoeTV's rule): engine and
/// plugin track names are inconsistent (ISO codes, full words,
/// "Tiếng Việt"), so matching is by token over name + code,
/// never by substring.
enum TVSubtitleLanguage {
    static func tokens(name: String, code: String) -> Set<String> {
        let raw = (name + " " + code).lowercased()
        return Set(raw.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    static func isVietnamese(name: String, code: String) -> Bool {
        let t = tokens(name: name, code: code)
        return t.contains("vie") || t.contains("vi") || t.contains("viet")
            || t.contains("việt") || t.contains("vietnamese")
    }

    static func isEnglish(name: String, code: String) -> Bool {
        let t = tokens(name: name, code: code)
        return t.contains("eng") || t.contains("en") || t.contains("english")
    }
}

// MARK: - Shared default ranking (§4.4)

/// The ONE shared default ranking for both surfaces
/// (language first: any Vietnamese before any English, and
/// within Vietnamese the sidecar file before the embedded
/// track): **file-VI → embedded-VI → embedded-EN → file-EN**.
/// Each host reports which of the four slots it actually has
/// a candidate for; this function alone decides which slot
/// wins, and the host then applies its own candidate for that
/// slot through its own machinery. No per-host ranking
/// remains — a host's candidate lookups are lookups, never
/// an ordering.
enum TVSubtitleDefaultRanking {
    enum Slot: Equatable {
        case fileVietnamese
        case embeddedVietnamese
        case embeddedEnglish
        case fileEnglish
    }

    static func winningSlot(hasFileVietnamese: Bool,
                            hasEmbeddedVietnamese: Bool,
                            hasEmbeddedEnglish: Bool,
                            hasFileEnglish: Bool) -> Slot? {
        if hasFileVietnamese { return .fileVietnamese }
        if hasEmbeddedVietnamese { return .embeddedVietnamese }
        if hasEmbeddedEnglish { return .embeddedEnglish }
        if hasFileEnglish { return .fileEnglish }
        return nil
    }
}

// MARK: - Cross-surface embedded pick resolution (§4.4)

/// Resolves a stored manual embedded pick against ONE
/// surface's embedded catalogue. The pick's key space is the
/// surface it was made on (AV: language tag + display name;
/// KS: subtitleID), so after an AV↔KS surface switch the key
/// usually matches nothing on the new surface. Resolution
/// order, first hit wins:
/// 1. exact key match in this surface's catalogue;
/// 2. the pick's stored display name — exact, then
///    case-insensitive;
/// 3. language: the pick's language identity, derived from
///    its stored key + display name with the ONE shared
///    matcher (TVSubtitleLanguage), matched against the
///    first embedded track of the same language.
/// Returns nil when no candidate matches at all — the caller
/// then treats (and logs) the effective selection as off.
enum TVEmbeddedPickResolver {
    static func resolve(key: String, displayName: String,
                        in catalog: [TVEmbeddedTrackRef]) -> TVEmbeddedTrackRef? {
        if let exact = catalog.first(where: { $0.key == key }) {
            return exact
        }
        if !displayName.isEmpty {
            if let exactName = catalog.first(where: { $0.displayName == displayName }) {
                return exactName
            }
            if let foldedName = catalog.first(where: {
                $0.displayName.caseInsensitiveCompare(displayName) == .orderedSame
            }) {
                return foldedName
            }
        }
        let pickIsVietnamese = TVSubtitleLanguage.isVietnamese(name: displayName, code: key)
        let pickIsEnglish = TVSubtitleLanguage.isEnglish(name: displayName, code: key)
        if pickIsVietnamese {
            return catalog.first(where: {
                TVSubtitleLanguage.isVietnamese(name: $0.displayName,
                                                code: $0.languageHint + " " + $0.key)
            })
        }
        if pickIsEnglish {
            return catalog.first(where: {
                TVSubtitleLanguage.isEnglish(name: $0.displayName,
                                              code: $0.languageHint + " " + $0.key)
            })
        }
        return nil
    }
}

// MARK: - Sidecar cues (AV overlay only)

struct TVSubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Fetches and parses sidecar subtitle files for the AV
/// surface's cue overlay. Fetched with the stream's headers
/// (a SubtitleTrack carries none of its own). Parsed formats:
/// WebVTT and SRT (the plugins' sidecars), plus a best-effort
/// ASS dialogue pass. Cues are cached per URL for the session.
@MainActor
final class TVFileSubtitleStore: ObservableObject {
    @Published private(set) var cuesByURL: [String: [TVSubtitleCue]] = [:]
    private var inFlight: Set<String> = []

    func load(track: SubtitleTrack, headers: [String: String]) {
        let urlString = track.url
        guard !urlString.isEmpty, cuesByURL[urlString] == nil,
              !inFlight.contains(urlString),
              let url = URL(string: urlString) else { return }
        inFlight.insert(urlString)
        Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let text: String?
            if let (data, _) = try? await URLSession.shared.data(for: request) {
                text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16)
            } else {
                text = nil
            }
            guard let self else { return }
            self.inFlight.remove(urlString)
            if let text {
                self.cuesByURL[urlString] = Self.parse(text)
            }
        }
    }

    /// The cue visible at `time` for `track`, or nil. Cues are
    /// stored sorted by start; a linear scan is fine at
    /// sidecar sizes and keeps the lookup obviously correct.
    func cue(at time: Double, for track: SubtitleTrack) -> String? {
        guard let cues = cuesByURL[track.url] else { return nil }
        return cues.first { time >= $0.start && time < $0.end }?.text
    }

    // MARK: Parsing

    static func parse(_ raw: String) -> [TVSubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.contains("[Events]") || text.hasPrefix("[Script Info]") {
            return parseASS(text)
        }
        return parseTimedText(text)
    }

    /// SRT / WebVTT: blank-line-separated blocks whose timing
    /// line carries `-->`; cue text is the following lines
    /// with markup stripped.
    private static func parseTimedText(_ text: String) -> [TVSubtitleCue] {
        var cues: [TVSubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]) else { continue }
            let body = lines[(timingIndex + 1)...]
                .map { stripMarkup($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(TVSubtitleCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// ASS: `Dialogue: Layer,Start,End,Style,Name,MarginL,
    /// MarginR,MarginV,Effect,Text` — text may itself contain
    /// commas, so split at most 10 fields.
    private static func parseASS(_ text: String) -> [TVSubtitleCue] {
        var cues: [TVSubtitleCue] = []
        for line in text.components(separatedBy: "\n") where line.hasPrefix("Dialogue:") {
            let fields = line.dropFirst("Dialogue:".count)
                .split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 10,
                  let start = parseTimestamp(fields[1]),
                  let end = parseTimestamp(fields[2]) else { continue }
            var body = fields[9]
            // Drop {...} override blocks, \N is a line break.
            while let open = body.range(of: "{"), let close = body.range(of: "}", range: open.lowerBound..<body.endIndex) {
                body.removeSubrange(open.lowerBound..<close.upperBound)
            }
            body = body.replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(TVSubtitleCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// `HH:MM:SS.mmm` / `MM:SS.mmm` / `H:MM:SS.cc`, with `.` or
    /// `,` as the fraction separator (SRT uses the comma).
    /// Trailing positioning junk on the end stamp (VTT cue
    /// settings) is ignored by taking the first token.
    private static func parseTimestamp(_ raw: String) -> Double? {
        let token = raw.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let seconds: Double
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            seconds = h * 3600 + m * 60 + s
        } else {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            seconds = m * 60 + s
        }
        return seconds
    }

    private static func stripMarkup(_ line: String) -> String {
        var out = ""
        var inTag = false
        for ch in line {
            if ch == "<" { inTag = true }
            else if ch == ">" { inTag = false }
            else if !inTag { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - AV cue overlay (§4.2)

/// Renders ONLY the selected sidecar file track's cues over
/// the AV surface, driven by the session's published position
/// (the AV host's periodic observer feeds it). Mounted by
/// TVPlayerView over the AV host only — it never exists on
/// the KS surface, where the layer renders.
struct TVSubtitleCueOverlayView: View {
    @ObservedObject var session: TVPlayerSession

    var body: some View {
        VStack {
            Spacer()
            if let text = currentText {
                Text(text)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(.horizontal, 160)
                    .padding(.bottom, 84)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var currentText: String? {
        guard let track = session.activeFileTrack else { return nil }
        return session.fileSubtitles.cue(at: session.currentPosition, for: track)
    }
}

// MARK: - The shared subtitle panel (§4.3)

/// One panel for both surfaces, iOS's row order: Tắt /
/// embedded tracks / external file tracks / "Tiếng Việt
/// (dịch tự động)" (Phase 4 placeholder state) / Huỷ, with
/// the "Không có phụ đề" empty state when no tracks exist at
/// all. The panel carries NO Back handler of its own: the
/// shell's single Menu arbiter (TVPlayerView) reads
/// `presentedPanel` and closes the panel only, never the
/// player, while a panel is up (FL-048). Rows are
/// element-level focusables built
/// with the Phase 2 recipe (label-untouched button style,
/// `.focusEffectDisabled()`, self-drawn inset ring).
struct TVSubtitlePanelView: View {
    @ObservedObject var session: TVPlayerSession

    @Environment(\.tvTheme) private var theme
    @FocusState private var focusedRow: RowID?
    @State private var autoSubNoteShown = false

    private enum RowID: Hashable {
        case off
        case embedded(String)
        case file(Int)
        case autoSub
        case cancel
    }

    private var files: [SubtitleTrack] { session.currentStream?.subtitles ?? [] }
    private var embedded: [TVEmbeddedTrackRef] { session.subtitleCatalog.embedded }
    private var hasAnyTrack: Bool { !embedded.isEmpty || !files.isEmpty || session.autoSubOffered }
    // The panel displays what ACTUALLY took effect on the
    // current surface: the hosts report the resolved choice
    // back as effectiveChoice (a manual pick stored in the
    // other surface's key space resolves to this surface's
    // key, or to .off when nothing matches). Keying off the
    // raw manualChoice would check no row after a
    // cross-surface switch.
    private var currentChoice: TVSubtitleChoice { session.effectiveChoice }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(spacing: 26) {
                Text("Phụ đề")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                ScrollView {
                    VStack(spacing: 12) {
                        if !hasAnyTrack {
                            Text("Không có phụ đề")
                                .font(.system(size: 27))
                                .foregroundStyle(theme.textDim)
                                .padding(.vertical, 18)
                        } else {
                            row(.off, title: "Tắt", checked: currentChoice == .off) {
                                session.selectSubtitle(.off)
                            }
                            ForEach(embedded) { track in
                                row(.embedded(track.key), title: track.displayName,
                                    checked: currentChoice == .embedded(key: track.key, displayName: track.displayName)) {
                                    session.selectSubtitle(.embedded(key: track.key, displayName: track.displayName))
                                }
                            }
                            ForEach(Array(files.enumerated()), id: \.offset) { index, track in
                                row(.file(index), title: track.displayName,
                                    checked: currentChoice == .file(track)) {
                                    session.selectSubtitle(.file(track))
                                }
                            }
                            if session.autoSubOffered {
                                autoSubRow
                            }
                        }
                        row(.cancel, title: "Huỷ", checked: false) {
                            session.presentedPanel = nil
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(44)
            .frame(width: 920)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(theme.surfaceGradient))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .defaultFocus($focusedRow, defaultRow)
    }

    private var defaultRow: RowID {
        switch currentChoice {
        case .off: return .off
        case .embedded(let key, _): return .embedded(key)
        case .file(let track):
            if let index = files.firstIndex(of: track) { return .file(index) }
            return .off
        }
    }

    /// The AutoSub row (§4.5): visibly marked unavailable in
    /// Phase 3. Selecting it changes nothing and starts
    /// nothing — it surfaces the note and leaves the §6 log
    /// line (the relay engine is Phase 4).
    private var autoSubRow: some View {
        VStack(spacing: 10) {
            row(.autoSub, title: "Tiếng Việt (dịch tự động)", checked: false,
                trailing: "Giai đoạn sau") {
                session.selectAutoSubUnavailable()
                autoSubNoteShown = true
            }
            if autoSubNoteShown {
                Text("Dịch tự động sẽ có ở giai đoạn tiếp theo.")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.heroMeta)
            }
        }
    }

    private func row(_ id: RowID, title: String, checked: Bool,
                     trailing: String? = nil,
                     action: @escaping () -> Void) -> some View {
        let isFocused = focusedRow == id
        return Button {
            action()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .opacity(checked ? 1 : 0)
                    .frame(width: 30)
                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.textFaint)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .tvCardButton()
        .focused($focusedRow, equals: id)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.14) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : .clear,
                          lineWidth: isFocused ? theme.ringWidth : 0))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
