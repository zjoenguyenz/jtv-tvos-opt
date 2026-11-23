import Foundation
import NaturalLanguage

// MARK: - AutoSub subtitle files (spec §3.2.1, §3.3 steps 1–2 & 6; item S-2)
//
// Fetch (via the app's existing Net layer — no new networking),
// identification (declared normalisation in AutoSub.swift, or
// NLLanguageRecognizer detection here), and parsing of SRT / WebVTT /
// ASS into the shared cue model, plus the §3.3 step-6 WebVTT
// reassembly used as the cache artefact.
//
// RECON verdict (binding, autosub-work/RECON.md §C1): Net.fetchData
// does NOT check the HTTP status code — a 404 or a Cloudflare
// challenge body comes back as ordinary Data. The parsers below are
// therefore strict at the STRUCTURE level: garbage (unrecognised
// format, empty data, zero valid cues) yields a typed failure,
// never a partial cue list presented as success (spec S-2).
//
// FIX (R1-logic m1 / row tolerance): within a recognised file,
// individually malformed cue blocks/rows are SKIPPED, not fatal —
// one bad row must not kill a 252-cue file. This is a deliberate
// deviation from the strictest reading of spec S-2, matching every
// real-world parser (including KSPlayer's): structural failure
// still throws, per-row damage degrades to a shorter cue list.

// MARK: Cue model (shared contract)

struct AutoSubCue: Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

// MARK: Typed failure (S-2)

enum AutoSubSubtitleError: Error, Sendable {
    /// The fetched bytes were empty.
    case emptyData
    /// The content matches none of the supported formats (e.g. an
    /// HTML error/challenge page returned instead of a subtitle).
    case unrecognisedFormat
    /// The format was recognised but the structure is broken
    /// (bad timestamps, missing ASS Format line, zero cues, …).
    case malformed
}

// MARK: Identification outcome (§3.3 step 2)

/// How a fetched track's language was settled. `declared`/`detected`
/// are the `via=` values of the §3.8 log line.
enum AutoSubIdentificationVia: String, Sendable, Equatable {
    case declared
    case detected
}

enum AutoSubIdentification: Sendable, Equatable {
    case source(AutoSubSourceLanguage, via: AutoSubIdentificationVia)
    /// The track is a native Vietnamese track — not a source at all
    /// (§3.2.1 step 2; T1 territory).
    case vietnamese
    /// Unidentifiable — the track is excluded, never guessed
    /// (§3.2.1 step 3).
    case unknown
}

/// The product of §3.3 steps 1–3 for one track: the raw source bytes
/// (the §3.7 cache key is their SHA-256), the parsed source cues,
/// and the identification outcome.
struct AutoSubLoadedSubtitle: Sendable {
    var sourceData: Data
    var cues: [AutoSubCue]
    var identification: AutoSubIdentification
}

// MARK: - Pipeline, parser, detector

enum AutoSubSubtitles {

    // MARK: Fetch + identify (§3.3 steps 1–2)

    /// Downloads one external subtitle track with the stream's own
    /// headers (`StreamInfo.headers` — SubtitleTrack carries none,
    /// RECON §C3), parses it, and identifies its language per
    /// §3.2.1:
    ///
    /// • declared `.source` → taken as-is, no detection;
    /// • declared `.chineseScriptOpen` → detection resolves ONLY
    ///   the script; a detection result that is not zh-Hans/zh-Hant
    ///   falls back to `.unknown` — never a guess;
    /// • declared `.vietnamese` → `.vietnamese`;
    /// • `.undeclared` → detection decides (source / vietnamese /
    ///   unknown).
    ///
    /// FIX PASS 3 (R3-1): for a multi-style ASS file the
    /// identification — and the cue list itself — is settled by
    /// `identify(parsed:declared:)`, which filters the file's
    /// style groups against the identified language (a bilingual
    /// fansub's wrong-language group never reaches the overlay or
    /// the translation session). Single-stream files follow the
    /// rules above exactly.
    ///
    /// Logs (§3.8): `autosub source srclang=<raw> via=declared|detected`
    /// on a source outcome, `autosub source lang=unknown` on
    /// exclusion. A Vietnamese outcome logs neither (it is a native
    /// track, not an AutoSub source and not an exclusion).
    ///
    /// Throws: `AutoSubSubtitleError` for parse failures; the
    /// underlying error from `Net.fetchData` for fetch failures
    /// (Net.fetchData does not check HTTP status — a garbage body
    /// surfaces as a parse error, which is the typed failure S-2
    /// requires).
    static func load(track: SubtitleTrack, headers: [String: String]) async throws -> AutoSubLoadedSubtitle {
        let data = try await Net.fetchData(track.url, headers: headers)
        let parsed = try parseFile(data)

        let declared = AutoSubSourceLanguage.normaliseDeclared(lang: track.lang, label: track.label)
        let (cues, identification) = identify(parsed: parsed, declared: declared)

        switch identification {
        case .source(let language, let via):
            DiagLog.log("autosub", "source srclang=\(language.rawValue) via=\(via.rawValue)")
        case .unknown:
            DiagLog.log("autosub", "source lang=unknown")
        case .vietnamese:
            break
        }

        return AutoSubLoadedSubtitle(sourceData: data, cues: cues, identification: identification)
    }

    /// Settles a parsed track's identification — and, for a
    /// multi-style ASS file, WHICH of its cues survive — per
    /// §3.2.1.
    ///
    /// Single-stream files (SRT / WebVTT, and ASS files whose kept
    /// rows carry at most one Style value) take the original rules
    /// verbatim: a declared source/Vietnamese outcome is taken
    /// as-is; `.chineseScriptOpen` lets detection settle ONLY the
    /// script; `.undeclared` lets detection decide.
    ///
    /// FIX PASS 3 (R3-1): a multi-style ASS file can be a BILINGUAL
    /// fansub — two dialogue groups under different Style values
    /// with identical timings (the SweetSub fixtures pair a Chinese
    /// group with a Japanese group row-for-row). Keeping both
    /// groups fed the wrong-language rows to the overlay and to a
    /// translation session configured for the other language. So
    /// for such a file each style group is detected separately and
    /// filtered against the file's identified language:
    ///
    /// • a group whose detection EQUALS the identified language is
    ///   kept (for Chinese the script must match exactly — Hans ≠
    ///   Hant here);
    /// • a group whose detection is a DIFFERENT positively
    ///   identified language is dropped;
    /// • a group whose detection is undetectable is kept
    ///   (fail-open: a small or ambiguous group — signs, credits —
    ///   must not be lost on a recogniser shrug);
    /// • if NO group positively matches the identified language
    ///   while at least one group positively detects as something
    ///   else, the identification itself fails: the track is
    ///   `.unknown` — excluded, never guessed (§3.2.1 step 3).
    ///   (If every group is undetectable, the file is kept whole
    ///   and a declared identification stands, as before.)
    ///
    /// The identified language itself comes from the existing
    /// rules, with one adaptation for the two paths that need
    /// detection: detection runs PER GROUP, and the group that
    /// speaks for the file is the DOMINANT one (see
    /// `dominanceOrder`). For `.chineseScriptOpen` the dominant
    /// CHINESE-detecting group settles the script (no Chinese group
    /// → `.unknown`, as before). For `.undeclared` the dominant
    /// positively-detecting group settles the language (no group
    /// detecting as a source or Vietnamese → `.unknown`, as
    /// before). Style NAMES are never consulted — the filter is
    /// generic over any fansub's style scheme.
    private static func identify(
        parsed: ParsedSubtitle,
        declared: AutoSubDeclaredResult
    ) -> (cues: [AutoSubCue], identification: AutoSubIdentification) {
        guard let groups = parsed.styleGroups, groups.count > 1 else {
            // Single-stream path — the pre-Pass-3 rules, verbatim.
            switch declared {
            case .source(let language):
                return (parsed.cues, .source(language, via: .declared))
            case .vietnamese:
                return (parsed.cues, .vietnamese)
            case .chineseScriptOpen:
                // Detection may settle ONLY Hans vs Hant here.
                // Anything else means the declaration and the
                // content disagree — exclude rather than guess
                // (§3.2.1 step 3).
                switch detectLanguage(cues: parsed.cues) {
                case .source(.zhHans):
                    return (parsed.cues, .source(.zhHans, via: .detected))
                case .source(.zhHant):
                    return (parsed.cues, .source(.zhHant, via: .detected))
                default:
                    return (parsed.cues, .unknown)
                }
            case .undeclared:
                switch detectLanguage(cues: parsed.cues) {
                case .source(let language):
                    return (parsed.cues, .source(language, via: .detected))
                case .vietnamese:
                    return (parsed.cues, .vietnamese)
                case .chineseScriptOpen, .undeclared:
                    return (parsed.cues, .unknown)
                }
            }
        }

        // Multi-style ASS: detect each style group separately.
        let detections = groups.map { detectLanguage(cues: $0.cues) }
        let order = dominanceOrder(groups)

        // The identified language (as a declared-result target) and
        // how it was reached.
        let target: AutoSubDeclaredResult
        let via: AutoSubIdentificationVia
        switch declared {
        case .source(let language):
            target = .source(language)
            via = .declared
        case .vietnamese:
            target = .vietnamese
            via = .declared
        case .chineseScriptOpen:
            // Only a Chinese-detecting group may settle the
            // script; the dominant such group speaks for the file.
            guard let speaker = order.first(where: {
                detections[$0] == .source(.zhHans) || detections[$0] == .source(.zhHant)
            }) else {
                return (parsed.cues, .unknown)
            }
            target = detections[speaker]
            via = .detected
        case .undeclared:
            // The dominant positively-detecting group speaks for
            // the file; no positive detection anywhere → excluded.
            guard let speaker = order.first(where: {
                detections[$0] != .undeclared && detections[$0] != .chineseScriptOpen
            }) else {
                return (parsed.cues, .unknown)
            }
            target = detections[speaker]
            via = .detected
        }

        // Filter the groups against the identified language.
        var kept: [AutoSubCue] = []
        var anyMatch = false
        var anyPositive = false
        for (group, detection) in zip(groups, detections) {
            if detection == target {
                anyMatch = true
                anyPositive = true
                kept.append(contentsOf: group.cues)
            } else if detection == .undeclared {
                // Fail-open: undetectable groups are kept.
                kept.append(contentsOf: group.cues)
            } else {
                // A positively different language (including the
                // other Chinese script): the group is dropped.
                anyPositive = true
            }
        }
        if !anyMatch && anyPositive {
            // The content positively contradicts the identified
            // language — exclusion, never a guess (§3.2.1 step 3).
            // The unfiltered cues ride along, as on every other
            // `.unknown` outcome; the identification is the gate
            // and no consumer reads cues of an excluded track.
            return (parsed.cues, .unknown)
        }
        let filtered = kept.sorted { $0.start < $1.start }
        switch target {
        case .source(let language):
            return (filtered, .source(language, via: via))
        case .vietnamese:
            return (filtered, .vietnamese)
        case .chineseScriptOpen, .undeclared:
            // Unreachable: the targets above are only ever a
            // settled `.source` / `.vietnamese` (detection never
            // returns `.chineseScriptOpen`, and the `.undeclared`
            // path returns early when no group positively
            // detects). Fail closed rather than guess.
            return (parsed.cues, .unknown)
        }
    }

    /// Group indices in dominance order: most cues first; ties
    /// broken by most cue-text characters, then by style name
    /// ascending — so the speaking group is deterministic for a
    /// given file.
    private static func dominanceOrder(_ groups: [ASSStyleGroup]) -> [Int] {
        groups.indices.sorted { a, b in
            let groupA = groups[a]
            let groupB = groups[b]
            if groupA.cues.count != groupB.cues.count {
                return groupA.cues.count > groupB.cues.count
            }
            let charsA = groupA.cues.reduce(0) { $0 + $1.text.count }
            let charsB = groupB.cues.reduce(0) { $0 + $1.text.count }
            if charsA != charsB { return charsA > charsB }
            return groupA.style < groupB.style
        }
    }

    // MARK: Language detection (§3.2.1 step 2)

    /// Runs `NLLanguageRecognizer` over a sample of cue text (up
    /// to 50 cues spread evenly across the list, joined —
    /// representative text, not one line)
    /// and maps its dominant language into the declared-result
    /// space. The recogniser is not Sendable: it is created, used
    /// and released inside this one synchronous function, and only
    /// the Sendable result crosses out of it.
    static func detectLanguage(cues: [AutoSubCue]) -> AutoSubDeclaredResult {
        // FIX (R1-logic m12): the sample is up to 50 cues spread
        // EVENLY across the whole cue list, not strictly the first
        // 50 — signs-first ASS files put dozens of typesetting rows
        // (drawing-path ASCII gibberish) at the head, which poisoned
        // a head-only sample and degraded the track to .unknown.
        let sampleCues: [AutoSubCue]
        if cues.count <= 50 {
            sampleCues = cues
        } else {
            sampleCues = (0..<50).map { cues[$0 * cues.count / 50] }
        }
        let sample = sampleCues.map(\.text).joined(separator: " ")
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .undeclared
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        switch recognizer.dominantLanguage {
        case .english: return .source(.en)
        case .simplifiedChinese: return .source(.zhHans)
        case .traditionalChinese: return .source(.zhHant)
        case .japanese: return .source(.ja)
        case .vietnamese: return .vietnamese
        default: return .undeclared
        }
    }

    // MARK: Parse dispatch

    /// Parses a subtitle file's bytes into cues. Format is detected
    /// by content, never by file extension: a `WEBVTT` header →
    /// WebVTT; `[Script Info]`/`[Events]` sections → ASS; otherwise
    /// SRT. Throws a typed `AutoSubSubtitleError` on empty,
    /// unrecognised or malformed input — a partial cue list is
    /// never returned as success (S-2).
    static func parse(_ data: Data) throws -> [AutoSubCue] {
        try parseFile(data).cues
    }

    /// One ASS style group: the kept cues that share a `Style`
    /// value, in file order. Groups are formed in first-appearance
    /// order of the style among kept rows.
    private struct ASSStyleGroup {
        var style: String
        var cues: [AutoSubCue]
    }

    /// The full parse product: the flat cue list (start-sorted),
    /// plus — for ASS files whose `[Events]` Format line carries a
    /// Style field — the same cues grouped by style. SRT / WebVTT
    /// files and style-less ASS files have `styleGroups == nil`.
    /// FIX PASS 3 (R3-1): the groups exist solely so `load()` can
    /// filter a bilingual file's style groups by language; the
    /// public `parse()` contract above is unchanged.
    private struct ParsedSubtitle {
        var cues: [AutoSubCue]
        var styleGroups: [ASSStyleGroup]?
    }

    private static func parseFile(_ data: Data) throws -> ParsedSubtitle {
        guard !data.isEmpty else { throw AutoSubSubtitleError.emptyData }
        let text = decodeText(data)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutoSubSubtitleError.emptyData
        }
        let lowered = text.lowercased()
        let cues: [AutoSubCue]
        var styleGroups: [ASSStyleGroup]?
        if firstContentLine(of: text).uppercased().hasPrefix("WEBVTT") {
            cues = try parseWebVTT(text)
        } else if lowered.contains("[script info]") || lowered.contains("[events]") {
            let ass = try parseASS(text)
            cues = ass.cues
            styleGroups = ass.styleGroups
        } else {
            cues = try parseSRT(text)
        }
        // FIX (R1-logic B1): every cue list in the system must be
        // chronological — the controller's binary-search lookup
        // is only valid on start-sorted data, and real ASS
        // files are routinely out of order (Sign/typesetting rows
        // grouped at the top). Swift's sort is stable, so cues that
        // share a start keep their file order. Sorting here, at the
        // single parse exit, covers source, translated, external-VI
        // and cache-loaded lists alike (cache artefacts are written
        // from sorted lists, so they round-trip consistently).
        return ParsedSubtitle(cues: cues.sorted { $0.start < $1.start }, styleGroups: styleGroups)
    }

    /// UTF-8 first (the overwhelmingly common case); a UTF-16 BOM
    /// routes to UTF-16 decoding; anything else falls back to a
    /// lossy UTF-8 decode, whose replacement characters will make
    /// the format parsers fail typed rather than guess.
    private static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let decoded = String(data: data, encoding: .utf16) {
            return decoded
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first line that is not blank / not the BOM, for header
    /// detection.
    private static func firstContentLine(of text: String) -> String {
        for line in normalizedLines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Lines with the BOM stripped and CRLF/CR normalised to LF.
    private static func normalizedLines(_ text: String) -> [String] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        body = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return body.components(separatedBy: "\n")
    }

    /// Splits normalised lines into blank-line-separated blocks.
    private static func blocks(from lines: [String]) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: SRT

    private static func parseSRT(_ text: String) throws -> [AutoSubCue] {
        var cues: [AutoSubCue] = []
        var sawTimingLine = false
        for block in blocks(from: normalizedLines(text)) {
            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }) else {
                // A block with no timing line is not a cue. If NO
                // block has one, this was never an SRT file (an
                // HTML error page lands here) — decided after the
                // loop via sawTimingLine.
                continue
            }
            sawTimingLine = true
            // Row tolerance (FIX 7a): a timing line that does not
            // parse skips THIS block only, never the whole file.
            guard let (start, end) = parseTimingLine(block[timingIndex]) else {
                continue
            }
            let body = block[(timingIndex + 1)...].map { $0 }
            let cleaned = cleanCueText(body, isASS: false)
            cues.append(AutoSubCue(start: start, end: end, text: cleaned))
        }
        guard sawTimingLine else { throw AutoSubSubtitleError.unrecognisedFormat }
        guard !cues.isEmpty else { throw AutoSubSubtitleError.malformed }
        return cues
    }

    // MARK: WebVTT

    private static func parseWebVTT(_ text: String) throws -> [AutoSubCue] {
        var lines = normalizedLines(text)
        // Drop the header line itself (may carry a title after
        // "WEBVTT"); anything before the first blank line is header.
        if let headerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("WEBVTT")
        }) {
            lines = Array(lines[(headerIndex + 1)...])
        } else {
            throw AutoSubSubtitleError.unrecognisedFormat
        }
        var cues: [AutoSubCue] = []
        for block in blocks(from: lines) {
            guard let first = block.first?.trimmingCharacters(in: .whitespaces) else { continue }
            // Metadata blocks carry no cues. FIX (R1-logic m3): the
            // keyword must be the whole first token — followed by a
            // space, a tab, or end-of-line. A cue whose identifier
            // merely STARTS with the letters (e.g. "NOTE-12",
            // "STYLESHEET") is a real cue, not a comment.
            if Self.isMetadataBlock(firstLine: first) {
                continue
            }
            // The timing line is the first line containing "-->";
            // a line before it is a cue identifier and is skipped.
            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            // Row tolerance (FIX 7a): skip this block only.
            guard let (start, end) = parseTimingLine(block[timingIndex]) else {
                continue
            }
            let body = block[(timingIndex + 1)...].map { $0 }
            cues.append(AutoSubCue(start: start, end: end, text: cleanCueText(body, isASS: false)))
        }
        guard !cues.isEmpty else { throw AutoSubSubtitleError.malformed }
        return cues
    }

    /// True when a WebVTT block's first line is a NOTE / STYLE /
    /// REGION metadata block: the keyword alone, or the keyword
    /// followed by a space or tab (per the WebVTT spec, the keyword
    /// must be followed by a space, tab, or newline).
    private static func isMetadataBlock(firstLine: String) -> Bool {
        let upper = firstLine.uppercased()
        for keyword in ["NOTE", "STYLE", "REGION"] {
            if upper == keyword { return true }
            if upper.hasPrefix(keyword + " ") || upper.hasPrefix(keyword + "\t") { return true }
        }
        return false
    }

    // MARK: ASS / SSA

    private static func parseASS(_ text: String) throws -> (cues: [AutoSubCue], styleGroups: [ASSStyleGroup]?) {
        let lines = normalizedLines(text)
        // Locate the [Events] section and its Format line; field
        // positions come from Format, never from assumed order.
        var formatFields: [String]?
        var inEvents = false
        var cues: [AutoSubCue] = []
        // FIX PASS 3 (R3-1): each kept row's Style is retained and
        // the cues are also grouped by it (first-appearance order),
        // so `load()` can filter a bilingual file's style groups
        // by language. `styleGroups` stays nil when the Format
        // line carries no Style field at all.
        var styleGroups: [ASSStyleGroup] = []
        var groupIndexByStyle: [String: Int] = [:]
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                formatFields = line.dropFirst("format:".count)
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            // Row tolerance (FIX 7a): a Dialogue row that arrives
            // before the Format line is skipped, not fatal.
            guard let formatFields else { continue }
            // A Format line that lacks Start/End/Text is a
            // STRUCTURAL failure — no row can be read at all.
            guard let startIndex = formatFields.firstIndex(of: "start"),
                  let endIndex = formatFields.firstIndex(of: "end"),
                  let textIndex = formatFields.firstIndex(of: "text")
            else {
                throw AutoSubSubtitleError.malformed
            }
            // FIX (R1-logic m2): the Text field takes the REMAINDER
            // of the line. Split WITHOUT a cap, then merge any
            // surplus parts back into the Text field's slot, so
            // commas inside Text survive wherever the Format line
            // places Text (last by spec, but not assumed here).
            let payload = line.dropFirst("dialogue:".count)
                .trimmingCharacters(in: .whitespaces)
            let parts = payload.split(
                separator: ",", omittingEmptySubsequences: false
            ).map { String($0) }
            // Row tolerance: a short row (e.g. a converter dropped a
            // trailing empty field) is skipped, not fatal.
            guard parts.count >= formatFields.count else { continue }
            let fields: [String]
            if parts.count == formatFields.count {
                fields = parts
            } else {
                let surplus = parts.count - formatFields.count
                var merged = Array(parts[0..<textIndex])
                merged.append(parts[textIndex...(textIndex + surplus)].joined(separator: ","))
                merged.append(contentsOf: parts[(textIndex + surplus + 1)...])
                fields = merged
            }
            // FIX PASS 2 (R2-logic N1, parser half): a Dialogue row
            // whose override block enables ASS drawing mode (a
            // `\p<digit>` tag — \p1, \p2, \p3…) is a vector graphic
            // (typeset sign backing, mask, logo shape), NOT
            // dialogue: its "text" is path data
            // (`m 258.657 -1.811 l 260.483 …`). Such rows are
            // DROPPED here, before they can become cues — they
            // were rendering as gibberish in the overlay whenever
            // they overlapped a real dialogue cue, and they were
            // poisoning the translation input the same way. The
            // tag is detected in the RAW Text field, before any
            // stripping (it lives inside the `{...}` override
            // block). All other rows are unchanged.
            // FIX PASS 3 (R3-3) refines WHICH rows count as drawing
            // rows — see `isASSDrawingRow`.
            if isASSDrawingRow(rawText: fields[textIndex]) { continue }
            // Row tolerance: unparseable timestamps skip this row.
            guard let start = parseTimestamp(fields[startIndex]),
                  let end = parseTimestamp(fields[endIndex])
            else { continue }
            let cleaned = cleanCueText([fields[textIndex]], isASS: true)
            let cue = AutoSubCue(start: start, end: end, text: cleaned)
            cues.append(cue)
            if let styleIndex = formatFields.firstIndex(of: "style") {
                let style = fields[styleIndex].trimmingCharacters(in: .whitespaces)
                if let groupIndex = groupIndexByStyle[style] {
                    styleGroups[groupIndex].cues.append(cue)
                } else {
                    groupIndexByStyle[style] = styleGroups.count
                    styleGroups.append(ASSStyleGroup(style: style, cues: [cue]))
                }
            }
        }
        guard formatFields != nil else { throw AutoSubSubtitleError.malformed }
        guard !cues.isEmpty else { throw AutoSubSubtitleError.malformed }
        let hasStyleField = formatFields?.contains("style") ?? false
        return (cues, hasStyleField ? styleGroups : nil)
    }

    /// True when an ASS Dialogue row's raw Text is a DRAWING row:
    /// one of its `{...}` override blocks enables drawing mode
    /// with a `\p<digit>` tag AND the row's stripped text is pure
    /// path data — no real dialogue in it.
    ///
    /// FIX PASS 3 (R3-3) refines the Pass-2 rule on both sides:
    ///
    /// (a) `\p0` does NOT count: in ASS it is drawing mode OFF —
    ///     typesetters use it to reset a style-level drawing
    ///     default on an ordinary dialogue row. Only `\p` followed
    ///     by a digit 1–9 enables drawing. (A `\p` sequence OUTSIDE
    ///     an override block, and lookalikes inside one —
    ///     `\pos(...)`, `\p` followed by a letter — never counted
    ///     and still do not.)
    ///
    /// (b) A row that mixes a drawing segment with real dialogue
    ///     (`Hello {\p1}m 1 2 …`) is KEPT whole: its stripped text
    ///     carries dialogue — any CJK character, or any word token
    ///     of ≥3 letters — and dropping the row would silently lose
    ///     the line. A row is dropped only when a `\p1`–`\p9` tag
    ///     is present AND the stripped text is pure path data
    ///     (every token numeric or a single letter/punctuation,
    ///     e.g. `m 258.657 -1.811 l 260.483 …`).
    ///
    /// An unclosed `{` treats the rest of the text as the block,
    /// matching how the row would be interpreted.
    private static func isASSDrawingRow(rawText: String) -> Bool {
        guard hasASSDrawingTag(rawText) else { return false }
        let stripped = cleanCueText([rawText], isASS: true)
        return !assTextContainsDialogue(stripped)
    }

    /// True when any `{...}` override block in the raw Text
    /// contains a `\p<digit 1–9>` drawing-mode tag.
    private static func hasASSDrawingTag(_ rawText: String) -> Bool {
        var index = rawText.startIndex
        while index < rawText.endIndex {
            guard rawText[index] == "{" else {
                index = rawText.index(after: index)
                continue
            }
            // Scan this override block for `\p<digit 1-9>`.
            var scan = rawText.index(after: index)
            var blockEnd = rawText.endIndex
            while scan < rawText.endIndex {
                let character = rawText[scan]
                if character == "}" {
                    blockEnd = scan
                    break
                }
                if character == "\\" {
                    let pIndex = rawText.index(after: scan)
                    if pIndex < rawText.endIndex, rawText[pIndex] == "p" {
                        let digitIndex = rawText.index(after: pIndex)
                        if digitIndex < rawText.endIndex,
                           "123456789".contains(rawText[digitIndex]) {
                            return true
                        }
                    }
                }
                scan = rawText.index(after: scan)
            }
            // Continue after this block (an unclosed block ends
            // the scan — blockEnd is endIndex then).
            index = blockEnd < rawText.endIndex ? rawText.index(after: blockEnd) : rawText.endIndex
        }
        return false
    }

    /// True when stripped cue text carries real dialogue rather
    /// than vector path data: any CJK character anywhere, or any
    /// whitespace-delimited word token containing ≥3 letters.
    /// Path data (`m 258.657 -1.811 l 260.483 …`) has neither —
    /// its tokens are numbers or single command letters.
    private static func assTextContainsDialogue(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF,   // CJK Unified Ideographs Ext. A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0x3040...0x309F,   // Hiragana
                 0x30A0...0x30FF,   // Katakana
                 0xAC00...0xD7AF:   // Hangul syllables
                return true
            default:
                continue
            }
        }
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if token.filter({ $0.isLetter }).count >= 3 { return true }
        }
        return false
    }

    // MARK: Timing lines & timestamps

    /// Parses "start --> end" with optional trailing settings
    /// (VTT cue settings, SRT position metadata) ignored: the
    /// timestamp is the first whitespace-delimited token on each
    /// side of the arrow.
    private static func parseTimingLine(_ line: String) -> (start: Double, end: Double)? {
        let sides = line.components(separatedBy: "-->")
        guard sides.count == 2 else { return nil }
        func firstToken(_ side: String) -> String? {
            side.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init)
        }
        guard let startToken = firstToken(sides[0]),
              let endToken = firstToken(sides[1]),
              let start = parseTimestamp(startToken),
              let end = parseTimestamp(endToken)
        else { return nil }
        return (start, end)
    }

    /// Parses HH:MM:SS.mmm / MM:SS.mmm (VTT), HH:MM:SS,mmm (SRT)
    /// and H:MM:SS.cc (ASS) into seconds. The fraction is read as
    /// a decimal fraction, so centiseconds and milliseconds both
    /// land correctly (".45" and ".450" are the same value).
    private static func parseTimestamp(_ token: String) -> Double? {
        let unified = token
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        // Convert to [String] up front so every numeric parse below
        // goes through the plain String initialisers.
        let parts = unified.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondPieces = parts[parts.count - 1]
            .split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard secondPieces.count == 1 || secondPieces.count == 2,
              let secondsWhole = Double(secondPieces[0])
        else { return nil }
        var fraction = 0.0
        if secondPieces.count == 2 {
            guard let value = Double("0." + secondPieces[1]) else { return nil }
            fraction = value
        }
        guard let minutes = Double(parts[parts.count - 2]) else { return nil }
        var hours = 0.0
        if parts.count == 3 {
            guard let value = Double(parts[0]) else { return nil }
            hours = value
        }
        return hours * 3600 + minutes * 60 + secondsWhole + fraction
    }

    // MARK: Cue text cleaning

    /// Joins a cue's text lines with a single space (spec S-2: the
    /// joined text is what gets translated; line breaks are a
    /// render concern), strips HTML-ish tags `<...>`, and decodes
    /// the handful of entities subtitle files actually use.
    ///
    /// FIX PASS 2 (R2-logic N6): the ASS-specific cleaning —
    /// `{...}` override-block stripping and the `\N` / `\n` /
    /// `\h` expansions — applies ONLY when `isASS` is true (the
    /// ASS parser). The SRT/WebVTT parsers pass false: braces and
    /// backslash sequences are ordinary text there, and must stay
    /// literal — translated text replayed from the WebVTT cache
    /// artefact can legitimately contain `{...}` or a literal
    /// `\N`, and the first-play text must survive the cache
    /// round-trip unchanged (the WebVTT escape/unescape
    /// round-trip of FIX 7f is unaffected: entities are still
    /// decoded here, `&amp;` last, after tag stripping).
    private static func cleanCueText(_ lines: [String], isASS: Bool) -> String {
        let joined = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var expanded = joined
        if isASS {
            expanded = expanded
                .replacingOccurrences(of: "\\N", with: " ")
                .replacingOccurrences(of: "\\n", with: " ")
                .replacingOccurrences(of: "\\h", with: " ")
        }
        expanded = stripTags(expanded, stripOverrideBlocks: isASS)
        expanded = expanded
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        // Collapse whitespace runs left by stripping/expansion.
        return expanded
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// Removes `{...}` override blocks (ASS only — the caller
    /// passes `stripOverrideBlocks` only for ASS text) and
    /// well-formed `<...>` tags in one scan.
    ///
    /// FIX (R1-logic m5): only a span with a matching closer ahead
    /// is stripped — a lone unmatched `<` (dialogue like
    /// "I <3 you") or `{` remains literal text instead of
    /// truncating the cue at that point.
    ///
    /// FIX PASS 2 (m5 residual): the `<...>` test is tightened to
    /// actual well-formedness. A span counts as a tag ONLY when
    /// `<` is immediately followed by a letter, `/`, or `!` AND a
    /// `>` follows with no other `<` in between, within a bounded
    /// lookahead. Otherwise the `<` is literal
    /// text: "2 < 3 and 5 > 4" and "I <3 you > me" now survive
    /// intact (the old any-`>`-ahead rule ate them). The rule is
    /// applied consistently by every parser (ASS included).
    /// FIX PASS 3 (R3-5): the lookahead is 256 characters and the
    /// scan is quote-aware — see `tagCloseIndex`.
    private static func stripTags(_ text: String, stripOverrideBlocks: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{", stripOverrideBlocks {
                if let closeIndex = text[index...].firstIndex(of: "}") {
                    index = text.index(after: closeIndex)
                } else {
                    // Unmatched opener — literal text, keep it.
                    result.append(character)
                    index = text.index(after: index)
                }
            } else if character == "<" {
                if let closeIndex = tagCloseIndex(in: text, from: index) {
                    index = text.index(after: closeIndex)
                } else {
                    // Not a well-formed tag — literal text.
                    result.append(character)
                    index = text.index(after: index)
                }
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    /// The index of the `>` closing a well-formed tag whose `<`
    /// sits at `start`, or nil when the `<` at `start` is literal
    /// text: the character after `<` must be a letter, `/`, or
    /// `!`, and the closing `>` must appear within 256 characters
    /// with no other `<` in between.
    ///
    /// FIX PASS 3 (R3-5): double-quoted sections inside the tag
    /// are skipped while scanning — a `>` inside a quoted
    /// attribute value (`<font face="a>b">`) does not close the
    /// tag (and a `<` inside quotes does not abort it either) —
    /// and the lookahead cap rises from 64 to 256 characters, so
    /// a well-formed tag with a long attribute is still stripped
    /// instead of shown raw. An unterminated quote simply runs
    /// the scan out to the cap / end of text and the `<` stays
    /// literal, as for any other unclosed span.
    private static func tagCloseIndex(in text: String, from start: String.Index) -> String.Index? {
        let first = text.index(after: start)
        guard first < text.endIndex else { return nil }
        let firstCharacter = text[first]
        guard firstCharacter.isLetter || firstCharacter == "/" || firstCharacter == "!" else {
            return nil
        }
        var scan = first
        var looked = 0
        var inQuotes = false
        while scan < text.endIndex, looked < 256 {
            let character = text[scan]
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                if character == ">" { return scan }
                if character == "<" { return nil }
            }
            scan = text.index(after: scan)
            looked += 1
        }
        return nil
    }

    // MARK: WebVTT reassembly (§3.3 step 6)

    /// Reassembles cues as a standard WebVTT file — the cache
    /// artefact (§3.7) and the renderer's interchange form.
    /// Timestamps are formatted HH:MM:SS.mmm; VTT needs no cue
    /// indices, so cues are renumbered implicitly by order.
    /// Cues are emitted in the order given (parse() hands over
    /// start-sorted lists — FIX 6). FIX (R1-logic m13): cue text is
    /// escaped (& first, then < and >) so a translation containing
    /// angle brackets round-trips: parse(webVTT(cues)) == cues,
    /// because the VTT parser's cleanCueText unescapes the entities
    /// after tag stripping.
    static func webVTT(from cues: [AutoSubCue]) -> String {
        var out = "WEBVTT\n"
        for cue in cues {
            out += "\n\(formatTimestamp(cue.start)) --> \(formatTimestamp(cue.end))\n"
            out += escapeVTTText(cue.text) + "\n"
        }
        return out
    }

    private static func escapeVTTText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        // FIX (R1-logic m10): guard the Double→Int conversion
        // against absurd inputs — a hostile source timestamp like
        // 99999999999:00:00.000 would otherwise TRAP on overflow
        // here during cache-store reassembly. Negatives clamp to 0
        // (as before), non-finite values become 0, and the value is
        // capped at 359,999,999 s (~100,000 hours — far beyond any
        // real programme) so the millisecond product always fits.
        guard seconds.isFinite else { return "00:00:00.000" }
        let clamped = min(max(0, seconds), 359_999_999)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let secs = (totalMilliseconds / 1_000) % 60
        let millis = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }
}
