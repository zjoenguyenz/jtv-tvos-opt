import Foundation
import SwiftUI

struct PluginSource: Codable, Identifiable {
    var url: String
    var pluginIds: [String] = []
    var id: String { url }
}

struct InstalledPlugin: Identifiable {
    var manifest: PluginManifest
    var sourceURL: String
    var id: String { manifest.id }
}

/// tvOS-only (1.3.8): the plugins.json 123av entry may carry
/// a `relayBase` — the home-LAN relay base the TV reaches
/// 123av through (relay-pc design). Decoded separately from
/// the manifest text so the shared PluginManifest (kept
/// byte-identical with iOS) grows no tvOS-only field.
private struct RelayBaseEntry: Decodable {
    let id: String
    let relayBase: String?
}

private struct RelayBaseFile: Decodable {
    let plugins: [RelayBaseEntry]
}

/// Owns plugin sources, the on-disk scripts, sync, the adult gate and
/// the active-plugin selection.
@MainActor
final class PluginManager: ObservableObject {
    static let defaultSourceURL = "https://raw.githubusercontent.com/zjoenguyenz/jtv-source/main/plugins.json"

    static let adultPluginIds: Set<String> = [
        "missav", "123av", "avdbapi", "sextop1", "sextop2", "topxx",
        "javhd", "vlxx", "njav", "sayhentai", "misskon", "torrenthub",
    ]

    @Published private(set) var sources: [PluginSource] = []
    @Published private(set) var installed: [InstalledPlugin] = []
    @Published private(set) var isSyncing = false
    @Published var lastSyncError: String?
    /// Bumps whenever a sync actually added or updated a plugin, so
    /// views can refresh content built from the old scripts.
    @Published private(set) var syncGeneration = 0

    @Published var activePluginId: String {
        didSet { UserDefaults.standard.set(activePluginId, forKey: Keys.activePlugin) }
    }

    @Published var adultEnabled: Bool {
        didSet {
            UserDefaults.standard.set(adultEnabled, forKey: Keys.adultEnabled)
            // Turning the gate off while an adult plugin is active must
            // not leave the app sitting on a now-hidden source.
            if !adultEnabled, isAdult(activePluginId) {
                activePluginId = visiblePlugins.first?.id ?? ""
            }
        }
    }

    /// Plugin ids the user disabled in Settings (persisted).
    @Published private(set) var disabledIds: Set<String> = []

    private enum Keys {
        static let sourceURL = "jtv_plugin_source_url"
        static let activePlugin = "jtv_last_active_plugin_id"
        static let adultEnabled = "jtv_is_adult_enabled"
        static let sources = "jtv_sources"
        static let manifests = "jtv_installed_manifests"
        static let manifestSources = "jtv_installed_manifest_sources"
        static let disabled = "jtv_disabled_plugin_ids"
        static let relayBase123av = "jtv_relay_base_123av"
    }

    private var engines: [String: PluginEngine] = [:]
    private let enginesLock = NSLock()

    /// The configured 123av relay base ("" = direct, no
    /// prelude). Captured from plugins.json by sync (the
    /// source of truth) or introduced by the bundled floor;
    /// persisted so a cold launch honours it before the
    /// first sync lands. The value itself is never logged
    /// (it carries the relay's path token).
    private var relayBase123av: String = ""

    // MARK: - Storage locations

    static var pluginsDirectory: URL {
        // tvOS adaptation (Phase-0 gap S-1): plugin scripts live in
        // Library/Caches, not Application Support — on tvOS only
        // Caches/tmp are reliably writable, and scripts are
        // re-downloadable via sync if the OS purges Caches. A failed
        // create is logged via DiagLog, never silent (was `try?`).
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("JTV/plugins", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            DiagLog.log("plugin", "pluginsDirectory create failed error=\(error.localizedDescription)")
        }
        return dir
    }

    private func scriptFileURL(for pluginId: String) -> URL {
        Self.pluginsDirectory.appendingPathComponent("\(pluginId).js")
    }

    // MARK: - Init / persistence

    init() {
        let defaults = UserDefaults.standard
        self.activePluginId = defaults.string(forKey: Keys.activePlugin) ?? ""
        self.relayBase123av = defaults.string(forKey: Keys.relayBase123av) ?? ""
        // The 18+ gate is session-only by the owner's rule: adult sources
        // appear only while he has the switch on, so every launch starts
        // with the gate OFF regardless of the previous session.
        self.adultEnabled = false

        if let data = defaults.data(forKey: Keys.sources),
           let saved = try? JSONDecoder().decode([PluginSource].self, from: data), !saved.isEmpty {
            self.sources = saved
        } else if let custom = defaults.string(forKey: Keys.sourceURL), !custom.isEmpty {
            self.sources = [PluginSource(url: custom, pluginIds: [])]
        } else {
            self.sources = [PluginSource(url: Self.defaultSourceURL, pluginIds: [])]
        }

        if let data = defaults.data(forKey: Keys.disabled),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            self.disabledIds = Set(saved)
        }

        if let data = defaults.data(forKey: Keys.manifests),
           let manifests = try? JSONDecoder().decode([PluginManifest].self, from: data) {
            let sourceMap = defaults.dictionary(forKey: Keys.manifestSources) as? [String: String] ?? [:]
            let fallbackSource = sources.first?.url ?? Self.defaultSourceURL
            self.installed = manifests.map {
                InstalledPlugin(manifest: $0, sourceURL: sourceMap[$0.id] ?? fallbackSource)
            }
        }

        seedBundledPlugins()

        // Display truth: the bundled set mirrors the default source's
        // repo, so until a sync succeeds the source row should still
        // show how many plugins it accounts for — not "0 plugin".
        if let idx = sources.firstIndex(where: { $0.url == Self.defaultSourceURL }),
           sources[idx].pluginIds.isEmpty {
            let bundledIds = installed.filter { $0.sourceURL == "bundled" }.map { $0.id }
            if !bundledIds.isEmpty {
                sources[idx].pluginIds = bundledIds
                persist()
            }
        }

        if activePluginId.isEmpty || !installed.contains(where: { $0.id == activePluginId }) {
            activePluginId = visiblePlugins.first?.id ?? installed.first?.id ?? ""
        }
    }

    /// The app ships with the full plugin set inside the bundle (the
    /// owner's source repo is private, so a fresh install cannot fetch
    /// it). Seeds any missing bundled plugin into the plugins directory.
    /// Bundled plugins carry sourceURL "bundled" so remote sync —
    /// success or failure — never removes them.
    private func seedBundledPlugins() {
        guard let jsonURL = Bundle.main.url(forResource: "plugins", withExtension: "json", subdirectory: "Plugins")
            ?? Bundle.main.url(forResource: "plugins", withExtension: "json"),
            let data = try? Data(contentsOf: jsonURL),
            let file = try? JSONDecoder().decode(PluginManifestFile.self, from: data)
        else { return }

        // 1.3.8: the bundled floor may INTRODUCE a 123av
        // relay base. It never removes one — removal is the
        // synced source's call (syncSource sets-or-clears).
        if let relayFile = try? JSONDecoder().decode(RelayBaseFile.self, from: data),
           let base = relayFile.plugins.first(where: { $0.id == "123av" })?.relayBase,
           !base.isEmpty {
            setRelayBase123av(base)
        }

        var changed = false
        for entry in file.plugins where !entry.id.isEmpty {
            let dest = scriptFileURL(for: entry.id)
            let hasScript = FileManager.default.fileExists(atPath: dest.path)
            if !hasScript,
               let src = Bundle.main.url(forResource: "\(entry.id)_plugin", withExtension: "js", subdirectory: "Plugins")
                ?? Bundle.main.url(forResource: "\(entry.id)_plugin", withExtension: "js"),
               let script = try? String(contentsOf: src, encoding: .utf8) {
                try? script.write(to: dest, atomically: true, encoding: .utf8)
                // tvOS adaptation (Phase-0 gap S-3, stale-seed
                // version lie): if this re-seed restored the bundled
                // script for an ALREADY-installed plugin — the
                // Caches-purge path, where UserDefaults still holds
                // the newer synced manifest — record the SEEDED
                // script's version as the installed version, so the
                // version sync compares against is the version of
                // the script actually on disk. Without this, sync's
                // fast path compares the remote version against the
                // newer stored manifest, sees the (stale) script
                // file exists, and never re-downloads: the app would
                // run the old bundled script labelled as the newer
                // version indefinitely.
                if FileManager.default.fileExists(atPath: dest.path),
                   let idx = installed.firstIndex(where: { $0.id == entry.id }),
                   installed[idx].manifest.version != entry.version {
                    installed[idx].manifest.version = entry.version
                    changed = true
                }
            }
            if !installed.contains(where: { $0.id == entry.id }) {
                installed.append(InstalledPlugin(manifest: entry, sourceURL: "bundled"))
                changed = true
            }
        }
        if changed { persist() }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: Keys.sources)
        }
        if let data = try? JSONEncoder().encode(installed.map { $0.manifest }) {
            defaults.set(data, forKey: Keys.manifests)
        }
        var sourceMap: [String: String] = [:]
        for plugin in installed { sourceMap[plugin.id] = plugin.sourceURL }
        defaults.set(sourceMap, forKey: Keys.manifestSources)
        defaults.set(Array(disabledIds), forKey: Keys.disabled)
        defaults.set(sources.first?.url ?? Self.defaultSourceURL, forKey: Keys.sourceURL)
    }

    // MARK: - Visibility

    func isAdult(_ pluginId: String) -> Bool {
        if Self.adultPluginIds.contains(pluginId) { return true }
        // Sources added later can flag a plugin as adult in plugins.json.
        return installed.first { $0.id == pluginId }?.manifest.adult == true
    }

    /// Dotted-numeric version compare ("1.0.10" > "1.0.9"); -1/0/1.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    static func normBase(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// Re-points a plugin script at a new base address. plugins.json is
    /// the single source of truth for where a source lives: when a site
    /// moves domain, the repo updates one line and the app rewrites the
    /// installed script itself on the next sync — the same self-healing
    /// the owner's football apps get from their playlist repo. Rewrites
    /// plain, host-only and regex-escaped occurrences of the old base.
    static func rewritingBase(_ script: String, from oldBase: String, to newBase: String) -> String {
        let old = normBase(oldBase)
        let new = normBase(newBase)
        guard !old.isEmpty, !new.isEmpty, old != new else { return script }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "/", with: "\\/")
             .replacingOccurrences(of: ".", with: "\\.")
        }
        func host(_ s: String) -> String { s.components(separatedBy: "://").last ?? s }
        var out = script
        out = out.replacingOccurrences(of: esc(old), with: esc(new))
        out = out.replacingOccurrences(of: esc(host(old)), with: esc(host(new)))
        out = out.replacingOccurrences(of: old, with: new)
        out = out.replacingOccurrences(of: host(old), with: host(new))
        return out
    }

    /// The 123av relay prelude line (relay-pc design §3):
    /// `var JTV_RELAY_123AV = "<relayBase>";` ahead of the
    /// script. Applies to the 123av plugin only, and only
    /// while a non-empty relay base is configured; every
    /// other load passes through byte-identical.
    static func relayPrelude(pluginId: String, relayBase: String, script: String) -> String {
        guard pluginId == "123av", !relayBase.isEmpty else { return script }
        return "var JTV_RELAY_123AV = \"\(relayBase)\";\n" + script
    }

    /// Records the 123av relay base (persisted; an empty
    /// value clears it). A change drops the cached 123av
    /// engine so the next load re-applies the prelude.
    private func setRelayBase123av(_ base: String) {
        guard base != relayBase123av else { return }
        relayBase123av = base
        UserDefaults.standard.set(base, forKey: Keys.relayBase123av)
        invalidateEngine(for: "123av")
        DiagLog.log("plugin", "id=123av relay=\(base.isEmpty ? "off" : "set")")
    }

    /// Loads a candidate script and returns its manifest when it runs
    /// and identifies as the expected plugin.
    private func validatedManifest(for script: String, pluginId: String) async -> PluginManifest? {
        let engine = PluginEngine(pluginId: pluginId)
        await engine.load(script: script)
        guard let manifest = await engine.manifest(), manifest.id == pluginId else { return nil }
        return manifest
    }

    /// Domain self-heal for an already-installed plugin: rewrites the
    /// on-disk script to the base plugins.json now declares, validates
    /// the result before it replaces anything, and returns the healed
    /// manifest. Any failure keeps the working copy untouched.
    private func healInstalledBase(pluginId: String, fileURL: URL, from oldBase: String, to newBase: String) async -> PluginManifest? {
        guard let script = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let rewritten = Self.rewritingBase(script, from: oldBase, to: newBase)
        guard rewritten != script,
              let manifest = await validatedManifest(for: rewritten, pluginId: pluginId),
              Self.normBase(manifest.baseUrl) == Self.normBase(newBase) else { return nil }
        try? rewritten.write(to: fileURL, atomically: true, encoding: .utf8)
        invalidateEngine(for: pluginId)
        return manifest
    }

    /// Plugins shown in switchers/pickers: installed, adult gate applied,
    /// not user-disabled.
    var visiblePlugins: [InstalledPlugin] {
        installed.filter { plugin in
            if isAdult(plugin.id) && !adultEnabled { return false }
            return !disabledIds.contains(plugin.id)
        }
    }

    var activePlugin: InstalledPlugin? {
        visiblePlugins.first { $0.id == activePluginId } ?? visiblePlugins.first
    }

    /// Plugin lookup ignoring the adult gate / disabled state (favorites
    /// and history need to resolve their own plugin).
    func installedPlugin(id: String) -> InstalledPlugin? {
        installed.first { $0.id == id }
    }

    func setPluginEnabled(_ pluginId: String, enabled: Bool) {
        if enabled { disabledIds.remove(pluginId) } else { disabledIds.insert(pluginId) }
        // v1.22.15: disabling drops the cached engine, so a
        // re-enabled plugin starts from a fresh context instead
        // of reviving state built before the disable.
        if !enabled { invalidateEngine(for: pluginId) }
        if !enabled && activePluginId == pluginId {
            activePluginId = visiblePlugins.first?.id ?? ""
        }
        if enabled && activePluginId.isEmpty {
            activePluginId = pluginId
        }
        persist()
    }

    func isPluginEnabled(_ pluginId: String) -> Bool { !disabledIds.contains(pluginId) }

    // MARK: - Engines

    func engine(for pluginId: String) async -> PluginEngine? {
        // Swift 6: scoped withLock replaces lock()/unlock()
        // pairs in async contexts (see Cache.swift note).
        if let cached = enginesLock.withLock({ engines[pluginId] }) {
            return cached
        }

        let file = scriptFileURL(for: pluginId)
        guard let script = try? String(contentsOf: file, encoding: .utf8), !script.isEmpty else {
            return nil
        }
        // 1.3.8 relay prelude (tvOS only): with a relayBase
        // configured for 123av, the evaluated copy carries
        // the JTV_RELAY_123AV global from the start — the
        // plugin routes its catalogue hops through the home
        // relay because 123av.com does not answer the TV
        // directly. No relayBase → the script loads
        // byte-identically to before. The on-disk script
        // is never modified; the prelude exists only in
        // the evaluated copy.
        var capturedBase = relayBase123av
        let engine = PluginEngine(pluginId: pluginId)
        var loaded = await engine.load(script: Self.relayPrelude(pluginId: pluginId, relayBase: capturedBase, script: script))
        // Gate 12220 B-t5: if the relay base changed while
        // the load was in flight, setRelayBase123av's
        // invalidation found nothing cached to drop — the
        // engine just loaded carries the OLD prelude and
        // caching it would pin that stale engine for the
        // session (the stored base already equals the new
        // value, so no later sync would re-invalidate).
        // Reload with the CURRENT base until the captured
        // base survives a load unchanged; only then may the
        // engine be cached. (PluginEngine.load builds a
        // fresh JSContext per call, so reloading this
        // instance replaces its context wholesale.)
        while loaded, pluginId == "123av", relayBase123av != capturedBase {
            capturedBase = relayBase123av
            loaded = await engine.load(script: Self.relayPrelude(pluginId: pluginId, relayBase: capturedBase, script: script))
        }
        // v1.22.15: an engine whose load raised is returned for
        // this call but NOT cached — caching it would pin the
        // broken context for every later call.
        if loaded {
            enginesLock.withLock { engines[pluginId] = engine }
        } else {
            DiagLog.log("plugin", "id=\(pluginId) engine not cached (load raised)")
        }
        return engine
    }

    private func invalidateEngine(for pluginId: String) {
        enginesLock.lock()
        engines[pluginId] = nil
        enginesLock.unlock()
    }

    // MARK: - Sync

    /// Fetches every source's plugins.json, downloads changed scripts and
    /// rebuilds the installed list. Automatic syncs (launch, pull-to-
    /// refresh) pass silent: a failed update CHECK is not an app error —
    /// the installed set keeps working — so it must never surface as
    /// one. Only a manual sync from Settings reports errors.
    func syncAll(silent: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        if !silent { lastSyncError = nil }
        defer { isSyncing = false }
        DiagLog.log("sync", "start sources=\(sources.count) silent=\(silent)")

        var errors: [String] = []
        var newInstalled: [InstalledPlugin] = []
        var newSources: [PluginSource] = []
        var anyChanged = false
        /// Id sets from sources that synced successfully this pass —
        /// the authority for the deletion rule below.
        var authoritative: [String: Set<String>] = [:]

        for source in sources {
            do {
                let synced = try await syncSource(urlString: source.url)
                newInstalled.append(contentsOf: synced.plugins)
                newSources.append(PluginSource(url: source.url, pluginIds: synced.plugins.map { $0.id }))
                anyChanged = anyChanged || synced.changed
                authoritative[source.url] = synced.remoteIds
            } catch {
                DiagLog.log("sync", "source failed host=\(URL(string: source.url)?.host ?? "?") error=\((error as NSError).domain)#\((error as NSError).code)")
                if (error as? URLError)?.code == .badServerResponse {
                    // 404/403 from the raw host — for the owner's own
                    // repo this almost always means it is still private.
                    errors.append("Chưa tải được danh sách nguồn — kho nguồn đang để riêng tư hoặc link chưa đúng. Các nguồn đã cài vẫn chạy bình thường.")
                } else {
                    errors.append(error.localizedDescription)
                }
                // Keep previously installed plugins from this source.
                let kept = installed.filter { $0.sourceURL == source.url }
                newInstalled.append(contentsOf: kept)
                newSources.append(source)
            }
        }

        // Deletion is authoritative (user order): a plugin the repo
        // no longer lists is removed from the device entirely —
        // script file, engine, list entry — instead of merely being
        // hidden until the next launch. The bundled floor answers to
        // the default source's list. A source that failed to sync,
        // or whose list came back empty, purges nothing: a bad fetch
        // or a bad push can never wipe the library.
        var purgedIds = Set<String>()
        for (sourceURL, remoteIds) in authoritative where !remoteIds.isEmpty {
            for plugin in installed where plugin.sourceURL == sourceURL && !remoteIds.contains(plugin.id) {
                purgedIds.insert(plugin.id)
            }
            if sourceURL == Self.defaultSourceURL {
                for plugin in installed where plugin.sourceURL == "bundled" && !remoteIds.contains(plugin.id) {
                    purgedIds.insert(plugin.id)
                }
            }
        }
        for pluginId in purgedIds {
            try? FileManager.default.removeItem(at: scriptFileURL(for: pluginId))
            invalidateEngine(for: pluginId)
            disabledIds.remove(pluginId)
        }
        if !purgedIds.isEmpty { anyChanged = true }
        newInstalled.removeAll { purgedIds.contains($0.id) }

        // Bundled plugins are not owned by any remote source; always keep them.
        newInstalled.append(contentsOf: installed.filter { $0.sourceURL == "bundled" && !purgedIds.contains($0.id) })

        // De-duplicate by plugin id (first source wins).
        var seen = Set<String>()
        installed = newInstalled.filter { seen.insert($0.id).inserted }
        sources = newSources
        if activePluginId.isEmpty || !visiblePlugins.contains(where: { $0.id == activePluginId }) {
            activePluginId = visiblePlugins.first?.id ?? ""
        }
        persist()
        if anyChanged { syncGeneration += 1 }
        DiagLog.log("sync", "done installed=\(installed.count) sources ok=\(authoritative.count)/\(newSources.count) errors=\(errors.count) purged=\(purgedIds.count) changed=\(anyChanged)")
        if !silent && !errors.isEmpty {
            lastSyncError = errors.joined(separator: "\n")
        }
        if !silent && !installed.isEmpty && errors.isEmpty {
            Haptics.success()
        }
    }

    /// Source files may arrive wrapped (base64 of the plain
    /// text): the repo serves them that way so the contents are
    /// not readable at a glance, and the app unwraps on arrival.
    /// Plain files pass through untouched, so both forms sync
    /// identically — that dual read is what lets the repo flip
    /// forms later without breaking installs, and scripts are
    /// always stored on disk unwrapped. Detection is
    /// structural: a wrapped file consists solely of base64
    /// characters and whitespace, which real plugin scripts and
    /// JSON never do (both contain braces, quotes and other
    /// characters outside that alphabet), and the decode must
    /// additionally yield valid UTF-8 before it is used, so a
    /// plain file can never be mangled by a wrong guess.
    static func unwrapped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        guard trimmed.count >= 16,
              trimmed.allSatisfy({ alphabet.contains($0) || $0.isWhitespace }) else { return text }
        let compact = trimmed.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact),
              let decoded = String(data: data, encoding: .utf8) else { return text }
        return decoded
    }

    /// Syncs one source. Updates are version-gated and validated BEFORE
    /// they touch disk: a downloaded script replaces the installed one
    /// only when its own manifest parses, its id matches, and its
    /// version is newer (or the plugin is new). A failed or older entry
    /// keeps the working copy — a bad push can never break a source
    /// that works, the same floor the bundled set provides.
    private func syncSource(urlString: String) async throws -> (plugins: [InstalledPlugin], changed: Bool, remoteIds: Set<String>) {
        let text = Self.unwrapped(try await Net.fetchText(urlString))
        guard let data = text.data(using: .utf8) else { throw URLError(.cannotDecodeContentData) }
        let file = try JSONDecoder().decode(PluginManifestFile.self, from: data)
        let remoteIds = Set(file.plugins.map { $0.id })

        // 1.3.8: the synced manifest is the source of truth
        // for the 123av relay base — capture it, or its
        // removal, for the engine-load prelude. Gate 12220
        // leader ruling: a synced file with NO 123av entry
        // (or an entry with no relayBase) CLEARS any
        // previously set base — absence means no relay —
        // so the capture always runs when the file decodes,
        // with the same engine-invalidation discipline
        // (setRelayBase123av no-ops on an unchanged value).
        if let relayFile = try? JSONDecoder().decode(RelayBaseFile.self, from: data) {
            setRelayBase123av(relayFile.plugins.first(where: { $0.id == "123av" })?.relayBase ?? "")
        }

        var result: [InstalledPlugin] = []
        var changed = false
        var updatedCount = 0
        var failedCount = 0
        for entry in file.plugins where !entry.id.isEmpty && !entry.scriptUrl.isEmpty {
            let existing = installed.first { $0.id == entry.id }
            let fileURL = scriptFileURL(for: entry.id)
            let hasScript = FileManager.default.fileExists(atPath: fileURL.path)

            // Already at this version (or newer): keep, no re-download.
            if let existing, hasScript,
               Self.compareVersions(entry.version, existing.manifest.version) <= 0 {
                var manifest = existing.manifest
                if entry.adult { manifest.adult = true }
                if manifest.iconUrl.isEmpty { manifest.iconUrl = entry.iconUrl }
                // Domain self-heal: if plugins.json says the source
                // now lives at a new address, re-point the installed
                // script in place — no download, no version bump.
                if !entry.baseUrl.isEmpty,
                   Self.normBase(entry.baseUrl) != Self.normBase(manifest.baseUrl),
                   let healed = await healInstalledBase(pluginId: entry.id, fileURL: fileURL, from: manifest.baseUrl, to: entry.baseUrl) {
                    var m = healed
                    if m.name.isEmpty { m.name = entry.name }
                    if entry.adult { m.adult = true }
                    m.scriptUrl = manifest.scriptUrl
                    manifest = m
                    changed = true
                }
                result.append(InstalledPlugin(manifest: manifest, sourceURL: existing.sourceURL))
                continue
            }

            do {
                var script = Self.unwrapped(try await Net.fetchText(entry.scriptUrl))
                // Validate first: the script must load and identify
                // itself as this plugin before it earns the disk slot.
                let engine = PluginEngine(pluginId: entry.id)
                await engine.load(script: script)
                guard var manifest = await engine.manifest(),
                      manifest.id == entry.id else {
                    failedCount += 1
                    DiagLog.log("sync", "plugin update failed id=\(entry.id) reason=manifest mismatch")
                    if let existing { result.append(existing) }
                    continue
                }
                // plugins.json wins on where the source lives: if the
                // downloaded script still points at an old domain,
                // re-point it (validated) before it is written.
                if !entry.baseUrl.isEmpty,
                   Self.normBase(entry.baseUrl) != Self.normBase(manifest.baseUrl) {
                    let rewritten = Self.rewritingBase(script, from: manifest.baseUrl, to: entry.baseUrl)
                    if rewritten != script,
                       let m2 = await validatedManifest(for: rewritten, pluginId: entry.id),
                       Self.normBase(m2.baseUrl) == Self.normBase(entry.baseUrl) {
                        script = rewritten
                        manifest = m2
                    }
                }
                if existing != nil,
                   Self.compareVersions(manifest.version, existing!.manifest.version) < 0 {
                    result.append(existing!)
                    continue
                }
                try script.write(to: fileURL, atomically: true, encoding: .utf8)
                invalidateEngine(for: entry.id)
                if manifest.name.isEmpty { manifest.name = entry.name }
                if manifest.iconUrl.isEmpty { manifest.iconUrl = entry.iconUrl }
                if entry.adult { manifest.adult = true }
                manifest.scriptUrl = entry.scriptUrl
                // A plugin that arrived via sync keeps the bundled
                // floor: mark it with the source that delivered it.
                updatedCount += 1
                DiagLog.log("sync", "plugin updated id=\(entry.id) v\(manifest.version)")
                result.append(InstalledPlugin(manifest: manifest, sourceURL: urlString))
                changed = true
            } catch {
                // Keep the working copy; one bad entry must not fail
                // the whole source's other updates.
                failedCount += 1
                DiagLog.log("sync", "plugin update failed id=\(entry.id) error=\(error.localizedDescription)")
                if let existing { result.append(existing) }
            }
        }
        DiagLog.log("sync", "source done host=\(URL(string: urlString)?.host ?? "?") plugins=\(result.count) updated=\(updatedCount) failed=\(failedCount)")
        return (result, changed, remoteIds)
    }

    // MARK: - Source management

    @discardableResult
    func addSource(urlString: String) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            lastSyncError = "Link nguồn không hợp lệ."
            return false
        }
        guard !sources.contains(where: { $0.url == trimmed }) else {
            lastSyncError = "Nguồn này đã có trong danh sách."
            return false
        }
        sources.append(PluginSource(url: trimmed, pluginIds: []))
        persist()
        await syncAll()
        return lastSyncError == nil
    }

    func removeSource(_ source: PluginSource) {
        let removedIds = installed.filter { $0.sourceURL == source.url }.map { $0.id }
        for pluginId in removedIds {
            try? FileManager.default.removeItem(at: scriptFileURL(for: pluginId))
            invalidateEngine(for: pluginId)
        }
        installed.removeAll { $0.sourceURL == source.url }
        sources.removeAll { $0.url == source.url }
        if sources.isEmpty {
            sources = [PluginSource(url: Self.defaultSourceURL, pluginIds: [])]
        }
        if !visiblePlugins.contains(where: { $0.id == activePluginId }) {
            activePluginId = visiblePlugins.first?.id ?? ""
        }
        persist()
    }
}
