import Foundation
// tvOS adaptation: `import UIKit` dropped — its only use was
// UIDevice (export header below), replaced with ProcessInfo.

/// In-app diagnostic log (LOG RETRIEVAL LAW, owner order
/// 2026-11-18): every build ships a way to get its log out, so
/// faults are fixed from evidence instead of blind hunting.
/// On tvOS the export is the LAN server in LogExportView
/// (Settings → "Gửi log chẩn đoán"); this file is the log
/// store behind it.
///
/// Design:
/// • Ring buffer of the last ~2,000 lines in memory, PLUS a
///   write-through on-disk twin (L-T04 / FL-342): every line
///   is appended to `jtv-diag.log` in Application Support at
///   write time, under the same lock, capped at 1 MB with
///   rotation keeping the newest ~700 KB — JoeTV's
///   JoeDiagLog storage shape, ported after the in-memory-
///   only original lost a crashed session's entire log (the
///   crash under diagnosis destroyed its own evidence). The
///   export seeds from the disk file, so a crashed session's
///   tail is exportable at the next launch; the launch line
///   marks the session boundary.
/// • Thread safety: a plain NSLock around every access, the same
///   pattern ImageCacheManager uses. An actor was rejected: the
///   call sites are synchronous (UIKit error surfaces, the
///   non-isolated image cache, timer closures) and forcing an
///   async hop at each one would scatter Tasks through code
///   paths that must stay exactly as they are. The class is
///   therefore `@unchecked Sendable` with ALL mutable state —
///   buffer and date formatters alike — touched only while the
///   lock is held.
/// • REDACTION (hard rule): debrid tokens, the MediaFusion
///   manifest URL and signed-URL query strings must NEVER reach
///   this buffer. Call sites log hosts and paths via
///   `urlForLog(_:)` (scheme + host + path, query and fragment
///   stripped, credentials dropped) and refer to secrets only
///   by configured yes/no. There is deliberately no API that
///   takes a raw URL. As defence in depth — because lines now
///   also reach DISK — `append` additionally runs a central
///   scrub over every message (JoeTV's write() discipline,
///   adapted): any URL run loses its query and fragment, a
///   scheme-less credential config base is erased whole, and
///   every credential value in force is erased wherever it
///   appears. Paths survive the scrub by design:
///   the route lines diagnosis depends on must not change
///   shape, and `urlForLog` + `registerCredentialHost` are
///   what keep credential-carrying paths out in the first
///   place.
/// • v1.22.15: hosts registered via `registerCredentialHost(_:)`
///   carry their credential in the URL PATH (the MediaFusion
///   manifest), so for those hosts `urlForLog(_:)` drops the
///   path entirely — scheme + host (+ port) + "/…" only. Every
///   non-registered host keeps the path exactly as before: the
///   route lines diagnosis depends on must not change shape.
final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 2000
    /// Hosts whose URL path carries a credential (v1.22.15, see
    /// the redaction note above). Touched only while `lock` is
    /// held, like every other piece of mutable state here.
    private var credentialHosts: Set<String> = []

    /// The on-disk twin's file (Application Support /
    /// jtv-diag.log; see the design note). Resolved ONCE in
    /// init and immutable afterwards, so reads need no lock.
    private let fileURL: URL
    /// Writes since launch; the rotation check runs every 64
    /// writes (JoeTV's cadence). Touched only while `lock` is
    /// held.
    private var writeCounter = 0
    /// Bounded disk size (JoeTV's caps): the file is capped
    /// at 1 MB; on rotation the newest ~700 KB are kept.
    private static let sizeCap = 1_000_000
    private static let rotationKeepBytes = 700_000

    /// The central scrub's URL pattern: a whole URL run — no
    /// whitespace, no quotes (JoeTV's pattern shape).
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:https?|stremio)://[^\s"']+"#)

    /// A scheme-less Torrentio-style config base: a run
    /// carrying realdebrid= / torbox= / premiumize= segments
    /// with no scheme in front of it (the shape a bare base or
    /// an engine error takes). Erased whole — host included —
    /// because the run's path IS the credential (JoeTV's
    /// pass 2, ported in the L-T04 fix pass).
    private static let configBaseRegex = try! NSRegularExpression(
        pattern: #"(?i)[^\s"']*(?:realdebrid|torbox|premiumize)=[^\s"']*"#)

    /// Formatters are created once and only ever used while
    /// `lock` is held (see append/export), so they need no
    /// synchronization of their own.
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f
    }()

    private init() {
        fileURL = Self.resolveFileURL()
    }

    /// The log's directory: Application Support (created if
    /// needed), falling back to Caches, then the temporary
    /// directory — JoeDiagLog.swift's directory choice,
    /// mirrored.
    private static func resolveFileURL() -> URL {
        let fm = FileManager.default
        if let base = try? fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base.appendingPathComponent("jtv-diag.log")
        }
        if let base = try? fm.url(for: .cachesDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base.appendingPathComponent("jtv-diag.log")
        }
        return fm.temporaryDirectory.appendingPathComponent("jtv-diag.log")
    }

    // MARK: - Logging

    static func log(_ category: String, _ message: String) {
        shared.append(category: category, message: message)
    }

    private func append(category: String, message: String) {
        // Scrub + flatten BEFORE the lock (the scrub touches
        // only immutable statics, CI-injected constants and
        // thread-safe UserDefaults reads — see secretValues):
        // one write is always exactly one line, in the buffer
        // and on disk alike (JoeTV's write() discipline).
        let clean = Self.scrubbed(message)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        lock.withLock {
            let line = "\(timeFormatter.string(from: Date())) [\(category)] \(clean)"
            lines.append(line)
            if lines.count > capacity {
                lines.removeFirst(lines.count - capacity)
            }
            appendToDiskLocked(line)
            writeCounter += 1
            if writeCounter % 64 == 0 {
                rotateIfNeededLocked()
            }
        }
    }

    /// Append one formatted line to the on-disk twin: create
    /// the file on first use, then write at its end through a
    /// file handle. Called only while `lock` is held. Failures
    /// are silent by design — a diagnostic log must never be
    /// able to break the feature it is observing. One
    /// deliberate divergence from JoeTV's appendLocked: when
    /// the handle cannot be opened, JoeTV falls back to
    /// `data.write(to:)`, which OVERWRITES the whole file with
    /// the single new line; here the line is dropped instead —
    /// losing one line beats silently truncating the history
    /// this file exists to preserve (review Lens A, 1.2.1).
    private func appendToDiskLocked(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Rotation, called under the lock every 64 writes: when
    /// the file is over the cap, drop from the front up to the
    /// first newline AFTER (size − keepBytes) — so the kept
    /// tail starts on a whole line — and prepend a marker
    /// saying the older lines are gone. The newest content is
    /// always kept (JoeTV's rotateIfNeededLocked shape; the
    /// marker uses this logger's own line format).
    private func rotateIfNeededLocked() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > Self.sizeCap,
              let data = try? Data(contentsOf: fileURL),
              data.count > Self.rotationKeepBytes
        else { return }
        let threshold = data.count - Self.rotationKeepBytes
        var start = data.count
        if let newline = data[threshold...].firstIndex(of: 0x0A) {
            start = newline + 1
        }
        let marker = "\(timeFormatter.string(from: Date())) [diag] log rotated — older lines dropped\n"
        var rotated = Data(marker.utf8)
        if start < data.count {
            rotated.append(data[start...])
        }
        try? rotated.write(to: fileURL)
    }

    /// The on-disk twin's current lines (oldest first), read
    /// while `lock` is held. Empty when the file is absent or
    /// unreadable — the export then falls back to the buffer.
    private func diskLinesLocked() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Central scrub (see the redaction note in the header):
    /// 1. Every URL run loses its query and fragment — the
    ///    parts where signed URLs and minted links carry
    ///    credentials. Scheme, host and path survive untouched
    ///    (string surgery only, no parse/rebuild, so a line a
    ///    call site already shaped via `urlForLog` passes
    ///    through byte-identical).
    /// 2. A scheme-less config base (a run carrying
    ///    realdebrid= / torbox= / premiumize= with no scheme)
    ///    is erased whole (JoeTV's pass 2).
    /// 3. Value pass: every credential value in force is
    ///    erased wherever it appears, in any shape — the
    ///    pass that catches a bare token inside an engine
    ///    error string (JoeTV's pass 3). The MediaFusion URL
    ///    is also listed scheme-stripped: an error may carry
    ///    it as a bare host/path fragment.
    private static func scrubbed(_ message: String) -> String {
        var result = message
        let full = NSRange(location: 0,
                           length: (result as NSString).length)
        for match in urlRegex.matches(in: result, range: full).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            let cut = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? raw.endIndex
            result.replaceSubrange(range, with: String(raw[..<cut]))
        }
        let rest = NSRange(location: 0,
                           length: (result as NSString).length)
        for match in configBaseRegex.matches(in: result,
                                             range: rest).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "[redacted]")
        }
        for secret in secretValues() {
            result = result.replacingOccurrences(of: secret,
                                                 with: "[redacted]")
        }
        return result
    }

    /// Every credential value in force, longest first so a
    /// longer value is erased before any shorter value it
    /// contains. Sources (JoeTV's gather-both discipline): the
    /// EFFECTIVE token values via `DebridTokens` (a stored
    /// UserDefaults value wins, the baked `DebridSecrets`
    /// value is the fallback), the baked `DebridSecrets` and
    /// `BundledSecrets` values themselves (a baked value can
    /// ride an engine error string even when a stored value
    /// has overridden it), and the MediaFusion URL in every
    /// form in force — stored, bundled, and the derived
    /// `MediaFusion.baseURL` requests are built from. Values under 8
    /// characters are skipped — too short to be a credential,
    /// too likely to be an innocent substring of ordinary
    /// text (JoeTV's floor).
    private static func secretValues() -> [String] {
        // Only the credential-carrying form of the derived
        // MediaFusion base is listed: a base that reduces to
        // scheme+host alone (a pasted MF URL with no config
        // segment — a configuration that cannot fetch a
        // manifest) would put a bare host on the secret list
        // and over-redact structured host= lines, so a
        // path-less base is skipped (review Lens B, 1.2.1).
        let mfBase: String? = MediaFusion.baseURL.flatMap { base in
            guard let comps = URLComponents(string: base),
                  !comps.path.isEmpty else { return nil }
            return base
        }
        let raw: [String?] = [
            DebridTokens.rd,
            DebridTokens.torbox,
            DebridTokens.premiumize,
            DebridSecrets.rdToken,
            DebridSecrets.torboxToken,
            DebridSecrets.premiumizeToken,
            BundledSecrets.rdToken,
            BundledSecrets.torboxToken,
            BundledSecrets.premiumizeToken,
            BundledSecrets.mfURL,
            UserDefaults.standard.string(forKey: MediaFusion.urlKey),
            // The DERIVED base form (scheme-normalised, no
            // /manifest.json suffix) — the shape requests are
            // actually built from, and therefore the shape an
            // engine error carries. The raw values above do
            // not match it as substrings (JoeTV lists mfBase
            // alongside mfURL for exactly this reason).
            mfBase,
        ]
        var seen = Set<String>()
        var out: [String] = []
        for value in raw {
            let v = (value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.count >= 8, seen.insert(v).inserted else { continue }
            out.append(v)
        }
        let originals = out
        for v in originals {
            for scheme in ["https://", "http://", "stremio://"] {
                guard v.lowercased().hasPrefix(scheme) else { continue }
                let stripped = String(v.dropFirst(scheme.count))
                if stripped.count >= 8, seen.insert(stripped).inserted {
                    out.append(stripped)
                }
                break
            }
        }
        return out.sorted { $0.count > $1.count }
    }

    // MARK: - Export

    static func exportText() -> String {
        shared.export()
    }

    private func export() -> String {
        // Seed from the on-disk twin (L-T04): the disk file
        // carries previous sessions' tails — a crashed
        // session's lines up to the crash — which the
        // per-launch buffer alone can never contain. The
        // buffer is the fallback when the file is absent or
        // unreadable.
        let (snapshot, exportedAt) = lock.withLock { () -> ([String], String) in
            let disk = diskLinesLocked()
            return (disk.isEmpty ? lines : disk,
                    exportDateFormatter.string(from: Date()))
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let header = [
            "JTV diagnostic log",
            "Exported: \(exportedAt)",
            "App: JTV \(version) (\(build))",
            // tvOS adaptation: header names tvOS; version comes
            // from ProcessInfo, not UIDevice.
            "System: tvOS \(Self.osVersionString) on \(Self.deviceModel)",
            "Lines: \(snapshot.count) (oldest first, times are local)",
            "---",
        ]
        return (header + snapshot).joined(separator: "\n") + "\n"
    }

    /// Hardware identifier (e.g. "iPhone17,2") — more useful in
    /// a log than UIDevice's marketing-free "iPhone".
    private static var deviceModel: String {
        var sys = utsname()
        uname(&sys)
        return Mirror(reflecting: sys.machine).children.reduce("") { acc, child in
            guard let byte = child.value as? Int8, byte != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(bitPattern: byte)))
        }
    }

    /// tvOS adaptation: formatted ProcessInfo OS version
    /// (e.g. "27.2.1"), replacing UIDevice.current.systemVersion.
    private static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - Redaction helper

    /// Registers a host whose URL path carries a credential
    /// (v1.22.15): `urlForLog(_:)` will return no path segments
    /// at all for it. Empty hosts are ignored; registering the
    /// same host twice is a no-op.
    static func registerCredentialHost(_ host: String) {
        guard !host.isEmpty else { return }
        shared.lock.withLock { _ = shared.credentialHosts.insert(host) }
    }

    /// The ONLY shape in which a URL may enter the log:
    /// scheme://host[:port]/path — query and fragment stripped,
    /// any embedded credentials dropped. For a host registered
    /// via `registerCredentialHost(_:)` the path is dropped too
    /// (scheme://host[:port]/…), because that path IS the
    /// credential. Non-URL targets
    /// (episode ids such as "jtvhash:…" or "jtvstreams:…")
    /// collapse to their scheme-like prefix so the payload —
    /// a hash, a signed id — is never written either.
    static func urlForLog(_ urlString: String) -> String {
        if let comps = URLComponents(string: urlString),
           let scheme = comps.scheme, let host = comps.host, !host.isEmpty {
            var out = "\(scheme)://\(host)"
            if let port = comps.port { out += ":\(port)" }
            let isCredentialHost = shared.lock.withLock { shared.credentialHosts.contains(host) }
            if isCredentialHost { return out + "/…" }
            out += comps.path
            return out
        }
        if let colon = urlString.firstIndex(of: ":") {
            return String(urlString[..<colon]) + ":…"
        }
        return "…"
    }
}
