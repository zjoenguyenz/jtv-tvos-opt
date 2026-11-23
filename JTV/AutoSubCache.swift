import Foundation
import CryptoKit

// MARK: - AutoSub generated-track cache (spec §3.7; item S-4)
//
// Content-keyed store for finished Vietnamese cue lists:
//   • Key: SHA-256 hex of the SOURCE subtitle file's bytes (content
//     keying — stream/subtitle URLs elsewhere in this app rotate, so
//     a URL key would silently defeat the cache; §3.7).
//   • Location: Caches/autosub/ — the app's convention for derived,
//     re-creatable data (Cache.swift's jtv-images, HLSProxy's
//     hls-local); iOS may purge it under storage pressure, which is
//     safe here (worst case: re-translate).
//   • Artefact per key: <key>.vtt (the §3.3 step-6 WebVTT) plus a
//     <key>.json sidecar (source language, declared-or-detected,
//     cue count, character count, created date, engine, app
//     version).
//   • Cap: 50 MB, LRU by modification date — with one deliberate
//     refinement over a literal per-file prune: eviction removes a
//     key's .vtt and .json TOGETHER, so the directory never keeps
//     an orphan sidecar whose cue file is gone (or vice versa).
//     Recency is the newest modification date among the key's
//     files, and a cache hit refreshes it.
//
// Concurrency (FIX 2, R1-concurrency F-2/F-3): this type is an
// ACTOR. Every piece of file I/O — directory creation, load, store,
// prune — runs inside actor isolation; there is no serial queue
// and no `@unchecked Sendable` anywhere. The previous shape ran
// `queue.sync` bodies that parked the @MainActor caller for the
// full read/parse/write, and its prune ran in detached tasks
// OUTSIDE the queue, racing loads and stores. Both are gone:
// callers `await` the load/store, and prune is an actor method
// invoked via `Task { await … }` from init and after stores, so a
// prune can never interleave with a load or store mid-flight.

struct AutoSubCacheSidecar: Codable, Sendable, Equatable {
    /// Source language raw value: "en" / "zh-Hans" / "zh-Hant" / "ja".
    var sourceLanguage: String
    /// True when §3.2.1 identification came from the declaration,
    /// false when it came from detection.
    var identifiedViaDeclared: Bool
    var cueCount: Int
    /// Character count of the SOURCE cue text (the translation
    /// volume measure, cf. Part 5 of the spec).
    var characterCount: Int
    var createdAt: Date
    /// "apple-translation/<pairLabel>", e.g. "apple-translation/en-vi".
    var engine: String
    /// "<short version> (<build>)" from the app bundle.
    var appVersion: String
}

actor AutoSubCache {
    static let shared = AutoSubCache()

    private let diskDir: URL
    private let diskCap = 50 * 1024 * 1024

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("autosub", isDirectory: true)
        // The prune (and the directory creation inside it) runs as
        // an actor job — no file I/O happens in this initialiser
        // itself, which is nonisolated.
        Task { await self.prune() }
    }

    // MARK: Key

    /// The §3.7 cache key for a source subtitle file: SHA-256 hex
    /// of its bytes (the same CryptoKit primitive Cache.swift's
    /// diskURL uses, there over a key string). Pure function of the
    /// bytes — a static member, hence nonisolated, safe to call
    /// from any context without awaiting the actor.
    static func key(forSourceData data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func vttURL(for key: String) -> URL {
        diskDir.appendingPathComponent(key + ".vtt")
    }

    private func sidecarURL(for key: String) -> URL {
        diskDir.appendingPathComponent(key + ".json")
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    // MARK: Load

    /// Returns the cached translation for `key`, or nil on any
    /// miss — missing files, an unparseable artefact, a broken
    /// sidecar, or a VALIDATION failure are all just misses (the
    /// caller re-translates).
    ///
    /// FIX (R1-logic m7): validation lives HERE now. When the
    /// caller supplies the expected cue count / source language,
    /// an entry that disagrees is a miss — and `autosub cache
    /// hit=1` is logged ONLY on the path that returns a
    /// successfully parsed AND validated value (after the parse,
    /// after the sidecar decode, after validation), never before.
    /// A hit also refreshes the pair's modification dates, which
    /// is what makes the eviction below least-RECENTLY-used rather
    /// than oldest-created.
    func loadTranslated(
        key: String,
        expectedCueCount: Int? = nil,
        expectedSourceLanguage: String? = nil
    ) -> (cues: [AutoSubCue], sidecar: AutoSubCacheSidecar)? {
        ensureDirectory()
        let fm = FileManager.default
        guard let vttData = try? Data(contentsOf: vttURL(for: key)),
              let sidecarData = try? Data(contentsOf: sidecarURL(for: key)),
              let cues = try? AutoSubSubtitles.parse(vttData),
              let sidecar = try? Self.sidecarDecoder.decode(AutoSubCacheSidecar.self, from: sidecarData)
        else { return nil }
        if let expectedCueCount, cues.count != expectedCueCount { return nil }
        if let expectedSourceLanguage, sidecar.sourceLanguage != expectedSourceLanguage { return nil }
        let now = Date()
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: vttURL(for: key).path)
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: sidecarURL(for: key).path)
        DiagLog.log("autosub", "cache hit=1 cues=\(cues.count)")
        return (cues, sidecar)
    }

    // MARK: Store

    /// Writes the finished translation for `key`: the WebVTT
    /// artefact (via AutoSubSubtitles.webVTT — assembled here,
    /// inside the actor, not on the caller's main actor) and its
    /// sidecar, both atomically, then schedules a prune as an
    /// actor job. Logs `autosub cache stored bytes=<n>` (§3.8),
    /// where <n> is the .vtt artefact's byte count.
    func storeTranslated(
        key: String,
        cues: [AutoSubCue],
        source: AutoSubSourceLanguage,
        identifiedViaDeclared: Bool,
        sourceCharCount: Int
    ) {
        ensureDirectory()
        let vtt = AutoSubSubtitles.webVTT(from: cues)
        let sidecar = AutoSubCacheSidecar(
            sourceLanguage: source.rawValue,
            identifiedViaDeclared: identifiedViaDeclared,
            cueCount: cues.count,
            characterCount: sourceCharCount,
            createdAt: Date(),
            engine: "apple-translation/\(source.pairLabel)",
            appVersion: Self.appVersion
        )
        guard let vttData = vtt.data(using: .utf8),
              let sidecarData = try? Self.sidecarEncoder.encode(sidecar)
        else { return }
        do {
            try vttData.write(to: vttURL(for: key), options: .atomic)
            try sidecarData.write(to: sidecarURL(for: key), options: .atomic)
        } catch {
            return
        }
        DiagLog.log("autosub", "cache stored bytes=\(vttData.count)")
        // Post-store prune as a separate actor job (FIX 2): it runs
        // after this store has fully completed, inside the same
        // isolation, so it can never race the write above.
        Task { await self.prune() }
    }

    // MARK: Prune (LRU, actor-isolated)

    /// Evicts least-recently-used keys until the directory is at or
    /// under the cap. Actor-isolated: it can only run between other
    /// actor jobs, never concurrently with a load or store
    /// (R1-concurrency F-3 / R1-logic m6 — the old detached-task
    /// prune could delete a pair mid-load or just after a store).
    private func prune() {
        ensureDirectory()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: diskDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        var total = 0
        // Group files by cache key (filename minus extension) so a
        // key's .vtt + .json are evicted together (see header note).
        var groups: [String: (urls: [URL], size: Int, newest: Date)] = [:]
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            total += size
            let key = entry.deletingPathExtension().lastPathComponent
            let date = values?.contentModificationDate ?? .distantPast
            if var group = groups[key] {
                group.urls.append(entry)
                group.size += size
                group.newest = max(group.newest, date)
                groups[key] = group
            } else {
                groups[key] = ([entry], size, date)
            }
        }
        guard total > diskCap else { return }
        for group in groups.values.sorted(by: { $0.newest < $1.newest }) {
            if total <= diskCap { break }
            for url in group.urls {
                try? fm.removeItem(at: url)
            }
            total -= group.size
        }
    }

    // MARK: Sidecar coding & app version

    private static var sidecarEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var sidecarDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
