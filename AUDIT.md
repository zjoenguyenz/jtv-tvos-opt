# AUDIT.md: JTV tvOS code audit (Phase 1, report only)

- **Tree audited:** `zjoenguyenz/jtv-tvos-opt` @ `ebdff64` (the faithful clone of production `ffe70030`, 1.3.11/19). All `file:line` references are to this tree.
- **Date:** 2026-11-23
- **Scope:** all 40 Swift files (26,033 lines), `project.yml`, the CI workflow, `CORE-SYNC.md`, and the committed secrets stubs. The 13 plugin JS files and `plugins.json` are out of scope (plugin format and source repo are excluded by the brief). They were scanned only for credential literals.
- **Method:** static reading only. This environment has no macOS, Xcode or Apple TV, so **nothing was compiled, run or measured.** Every performance statement below is **UNMEASURED**. Each one names the measurement that must precede a "faster/lighter" claim (rule 8).
- **Confidence labels:**
  - **CONFIRMED**: the defect follows directly from the code as read.
  - **PLAUSIBLE**: the code permits it, but whether it happens on device depends on framework behaviour I could not observe. It needs device evidence before any fix.
- **Flags used:**
  - `PROTECTED`: touches rule-3 machinery. Report or proposal only, risk analysis attached.
  - `SYNC-BREAKING`: touches a CORE-SYNC file, so it needs a mirrored iOS port.
  - `BEHAVIOUR CHANGE`: changes observable results, timings, retry counts or logs, and needs approval.

No code was changed in this phase.

---

## 0. Ranked summary (impact ÷ risk, highest first)

| # | ID | Class | Finding | Impact | Risk | Flags | Conf. |
|---|----|-------|---------|--------|------|-------|-------|
| 1 | A1 | A/B | `TVRootView.init` builds a throwaway `PluginManager` + `MovieService` on every `PinSession` publish (every screen appear, tab switch, and every 60 s during playback) | High | Low | – | CONFIRMED |
| 2 | A2 | A | Playback history save every 2 s: JSON-encode + `UserDefaults` write on main, plus app-wide view invalidation under the player | High | Low (part a) / Med (part b) | (b) BEHAVIOUR CHANGE, SYNC-BREAKING | CONFIRMED |
| 3 | A3 | A | Manga page planner (full-height grayscale scan) and the strip's first decode run on the main thread | Med-High | Med | – | CONFIRMED |
| 4 | C1 | C/D | Shell `shellPreflightWalk` replica has drifted from the core walk: it lacks the core's cancellation stop between candidates and logs differently | Med | Low | BEHAVIOUR CHANGE | CONFIRMED |
| 5 | A4 | A | Every network image fetch decodes twice (validity gate at 240 px, then the real rung) | Med | Low-Med | SYNC-BREAKING | CONFIRMED |
| 6 | A5 | A | `DiagLog.log` per-line cost: secret list rebuilt (4 `UserDefaults` reads + URL parse + sort), 2 regex passes, file open/seek/write/close, all on the caller's thread | Med | Low-Med | SYNC-BREAKING | CONFIRMED (cost UNMEASURED) |
| 7 | A6 | A/B | Wide-strip images skip the downscale and come back as a lazily decoded `UIImage(data:)`. Up to 64 MP, about 256 MB decoded, decoded on first draw (main) | Med | Med | SYNC-BREAKING | CONFIRMED |
| 8 | A7 | A | Home `.task` re-fires a silent `syncAll` (refetches `plugins.json`) on every Home re-appearance | Med | Med | BEHAVIOUR CHANGE | PLAUSIBLE |
| 9 | A8 | A | `MetadataOverlay` reads and decodes its cache file synchronously on the main actor at first catalogue merge, and decodes/writes the refresh on main | Low-Med | Low | SYNC-BREAKING | CONFIRMED (size UNMEASURED) |
| 10 | A9 | A/C | `PluginManager.engine(for:)` has no in-flight dedupe across its `await`: concurrent misses each read the script on main and build a JSContext | Low-Med | Low-Med | SYNC-BREAKING | CONFIRMED |
| 11 | E1 | E | `HLSProxyLoader` downloads the whole resource for every loading request and ignores the requested byte range | Med-High | High | PROTECTED, SYNC-BREAKING | PLAUSIBLE |
| 12 | E2 | E/C | `HLSProxyLoader` keys cancellation by `ObjectIdentifier`. A stale `cancelled` entry plus address reuse can leave a later request unanswered (stall) | Med | High | PROTECTED, SYNC-BREAKING | PLAUSIBLE |
| 13 | E3 | E/C | `LocalHLSServer.start()` continuation can wait forever if the listener never reaches ready/failed/cancelled | Med | Med | PROTECTED, SYNC-BREAKING | PLAUSIBLE |
| 14 | E4 | E | `LocalHLSServer` listens on all interfaces, with an unbounded request buffer and no idle timeout | Low-Med | Low | PROTECTED, SYNC-BREAKING | CONFIRMED |
| 15 | E5 | E/A | URL caches: `Net.session` has a 100 MB disk `URLCache` it never reads; the proxy and image sessions inherit `URLCache.shared` | Low-Med | Med | PROTECTED, SYNC-BREAKING | PLAUSIBLE |
| 16 | B1 | B | `MovieService.pageCache`: expired page HTML is kept until 200 entries, then everything is wiped at once | Med | Med | PROTECTED, SYNC-BREAKING | CONFIRMED |
| 17 | B2 | B | `TVAVPlayerHost.invalidate()` pauses but does not release the item or loader, so a superseded attempt may keep buffering | Med | High | BEHAVIOUR CHANGE (teardown timing) | PLAUSIBLE |
| 18 | B3 | B | `MovieService.prefetchedEmbeds` is pruned only on consume | Low | Low | PROTECTED, SYNC-BREAKING | CONFIRMED |
| 19 | B4 | B | 14 JSContexts, each with its own VM, live for the `PluginManager` lifetime | Low-? | Med | SYNC-BREAKING | UNMEASURED |
| 20 | B5 | B | Image disk tier prunes only at launch and evicts by write time, not access time | Low | Low | SYNC-BREAKING | CONFIRMED |
| 21 | C2 | C | `StreamPreflight` / `TVSourceProbe` budget Tasks are never cancelled after the verdict | Low | Low | PROTECTED (StreamPreflight) | CONFIRMED |
| 22 | D1–D7 | D | Dead/staged code, duplicated machinery, oversized types (see §D) | Low | – | varies | CONFIRMED |
| – | S1–S2 | Secrets | **No committed credential found (no P1).** Design-level observations only | – | – | – | CONFIRMED |
| – | X1–X2 | Build | CI is dispatch-only, so "green on every PR" cannot hold as is. Xcode `26.x` pin vs the tvOS 27 target needs checking | – | – | – | CONFIRMED / verify |

---

## A. Performance

### A1: Throwaway `PluginManager` + `MovieService` on every `PinSession` publish — CONFIRMED
**Where.**
- `JTVTV/TVRootView.swift:42-46`: `let plugins = PluginManager()` runs *outside* the `StateObject` autoclosure, so it runs on every `TVRootView.init`. The same holds for `MovieService(manager: plugins)`.
- `JTVTV/JTVTVApp.swift:67-80`: `RootContainerView` observes `PinSession` and rebuilds `TVRootView()` in its body.
- `JTVTV/PinGate.swift:109,126-128`: `lastActivity` is `@Published`, and `touch()` sets it.
- `touch()` is called from 20+ sites: every tab's `onAppear` (TVHomeView:203, TVCategoryView:115, TVLibraryView:82, TVSettingsView:132, TVBrowseView:373, TVSearchView:146/668, TVDetailView:248, TVActorView:157), the tab-selection change (TVRootView:117), and the playback refresher every 60 s (PinGate:140-150).

**Cost today.** Each publish re-evaluates `RootContainerView.body`, which constructs a new `TVRootView` value. Its init constructs a full `PluginManager`, and `StateObject` immediately discards it (it keeps the first). The discarded `PluginManager.init` (`JTV/PluginManager.swift:113-162`) does all of the following on the main thread:
- 3 `UserDefaults` JSON decodes.
- `seedBundledPlugins()`: a Bundle lookup, a read of `plugins.json` decoded twice, and 13 × `fileExists`.
- A `createDirectory` per script lookup (`pluginsDirectory` is a computed property, `:91-105`).

Worse, `seedBundledPlugins` can **write**. If a Caches purge removed a script, the throwaway instance copies bundled scripts to disk and calls `persist()` (`:186-219`), racing the live instance's `UserDefaults` state. This is a correctness hazard as well as wasted work.

**Proposed change (shell only, not synced).** Defer construction into the autoclosures while still sharing one instance. A cheap box is created per init; its lazy members are only touched by the autoclosures, which SwiftUI evaluates once, at install:
```swift
@MainActor private final class RootStoreBox {
    lazy var plugins = PluginManager()
    lazy var service = MovieService(manager: plugins)
}
init() {
    let box = RootStoreBox()
    _plugins = StateObject(wrappedValue: box.plugins)
    _service = StateObject(wrappedValue: box.service)
}
```
Both `@StateObject`s and their observation stay exactly as they are today.

**Risk.** Low. Same objects and same observation; only the discarded duplicates disappear. Behaviour change: NONE.

**Verify.**
- **Before/after:** a temporary measurement-build counter or os_signpost in `PluginManager.init`, with a scripted session (launch, switch all 5 tabs, open a detail, play 3 min). Expect the count to drop from N≈tabs+appears+3 to 1.
- **Parity:** the `[sync]`, `[home]` and `[player]` DiagLog lines of the same script are identical apart from timestamps.

### A2: History persistence every 2 s during playback — CONFIRMED
**Where.**
- `JTVTV/TVPlayerSession.swift:1775-1797`: the host ticks every 250 ms and calls `history.upsert(...)` each time.
- `JTV/Library.swift:119-136`: a 2 s per-record throttle, then `records[idx] = …` (publishes) and `save()` (`:160-164`), which JSON-encodes all 60 records and writes `UserDefaults` on main.
- Observers of `history`:
  - `TVRootView` (`@StateObject`, `TVRootView.swift:30`), which re-runs its body and the `fullScreenCover` content closure.
  - `TVHomeView:179`, `TVSearchView:81`, `TVLibraryView:48`, `TVDetailView:38`, all alive under the cover.

**Cost today.** Every 2 s for the whole film:
- One encode and write of the whole history array.
- A body re-evaluation of the root and every mounted screen behind the player.

This is main-thread work concurrent with playback. Magnitude UNMEASURED.

**Proposed change.**
- **(a) Zero-behaviour part (shell only):** stop the root from observing `history`. It only forwards the object; it never reads it in `body`. Use the same box pattern as A1, holding `history` without `@StateObject` observation. Screens still observe it themselves.
- **(b) Optional part:** coalesce `save()` so a throttled tick updates memory and the write happens at most every N s and always on `flushHistory()` / `force`. This is a **BEHAVIOUR CHANGE**: a crash could lose up to N s of resume position. It is also **SYNC-BREAKING** (`Library.swift` is byte-identical with iOS). It needs approval and is not proposed for the first PR.

**Risk.**
- (a) Low. Check that nothing in `TVRootView.body` reads `history` (it passes `history` into `TVPlayerView(...)` by value only).
- (b) Medium.

**Verify.** Instruments Time Profiler on main during 5 min of playback, before and after (a). For (b), the resume position after a force-quit at a known time must stay within the approved tolerance.

### A3: Manga page planning and first decode on the main thread — CONFIRMED
**Where.**
- `JTVTV/TVMangaReaderView.swift:286-296`: `recordPlan` is a method of a SwiftUI `View`, so it is MainActor-isolated under Swift 6.
- Called synchronously from the load tasks at `:893, :920, :975, :983`.
- It calls `TVMangaPagePlanner.plan(cgImage:)` (`JTVTV/TVMangaPagePlanner.swift:104`). That plan draws the **full-height** strip into a grayscale context up to 200 px wide (`:87`, `:394-410`), then runs per-row histogram/variance loops over every row (about 10,000 rows per strip).
- `pageImage` → `cg.cropping` (`:342-362`) then forces decode of a lazily decoded strip (see A6) on main.

**Cost today.** A main-thread stall on every new strip, for remote-driven page turns. UNMEASURED.

**Proposed change (shell only).** Compute the plan off the main actor: a `nonisolated` static async helper, with the `CGImage` handed across. CGImage's `Sendable` status in the tvOS 27 SDK **must be checked against the SDK headers before relying on it**. If it is not Sendable, wrap it in a documented `@unchecked Sendable` box (immutable value). Apply the result back on main, exactly where `recordPlan` stores `pagePlans` / `segmentCounts` today. Optionally pre-decode the image off-main with `UIImage.preparingForDisplay()` (tvOS 15+; confirm in the tvOS 27 SDK).

**Risk.** Medium. The order of state updates changes: the page count lands one hop later. The invariants at `:108-160` (plan/count pairing, landOnLastSegment, the F-B2 failure reset) must hold across the hop, and the result must be dropped if `stillCurrent()` is false. No UI change.

**Verify.**
- Time Profiler / Hangs instrument on a 30-strip chapter, before and after.
- Parity: for a fixed set of strips, the plan arrays (`y`, `height`) must be identical. The planner is a pure function, so a unit-test harness can compare them byte for byte.

### A4: Double decode of every network image — CONFIRMED
**Where.**
- `JTV/Cache.swift:444`: the validity gate `Self.decodeImage(data: data, bucket: 240) != nil` runs a full thumbnail decode, or a full libwebp scaled decode for WebP.
- `:379-380`: then `decodeImage(data:bucket: rung)` runs again for the real rung.

**Cost today.** Two decodes per first load of every poster and backdrop. WebP is decoded in software (libwebp). UNMEASURED.

**Proposed change.** Make the target-rung decode the gate. `fetchBytes` keeps the same transient/permanent classification, but the decode result for the requested rung is returned with the bytes, so `loadImage` does not decode again. The prefetch path uses rung 720 and behaves the same way.

**Risk.** Low-Med. One edge must stay identical: a body that is "undecodable" must still be classed transient and retried. A body that decodes at 240 but not at the target rung (same decoder, practically impossible) would now retry instead of returning nil after a successful fetch. Call that out in the PR. `Cache.swift` is a synced file and `Net` lives in it, but this change does not touch `Net`. SYNC-BREAKING.

**Verify.**
- Decode count per poster via a measurement-build counter.
- Wall time from first appearance to image for a Home rail, cold cache.
- Image bytes on disk are byte-identical (same file per key).

### A5: Per-line `DiagLog` cost — CONFIRMED, cost UNMEASURED
**Where.** `JTV/DiagLog.swift`:
- `:149`: `scrubbed()` runs on every line, before the lock.
- `:280-333`: `secretValues()` is rebuilt on every line. That means 4 `UserDefaults` reads (`DebridTokens` ×3 via `DebridResolver.swift:12-22`, plus the MF key), `MediaFusion.baseURL` (`MovieService.swift:2418-2445`: trims, URLComponents, and a `registerCredentialHost` lock), a second URLComponents parse, dedupe and a sort.
- `:246-262`: 2 regex passes, then up to about 12 `replacingOccurrences` scans.
- `:177-188`: open `FileHandle`, seek, write and close **per line**, inside the lock, on the calling thread. That is often main, because `TVPlayerSession` has 67 call sites.
- `:155-157`: `removeFirst` on a 2,000-element array per line once full (O(n)).

**Cost today.** Hundreds of lines per play session, each paying the cost above. UNMEASURED.

**Proposed change (rule 5: zero lines removed, zero lines reworded).**
1. Cache the computed secret list, keyed on its raw inputs. Recompute only when an input string differs; reading the 4 inputs is still cheap.
2. Keep one `FileHandle` open for the logger's lifetime and reopen it after rotation. `FileHandle.write(contentsOf:)` is an unbuffered `write(2)`, so crash durability is unchanged.
3. Use a ring index instead of `removeFirst`.

The redaction output must stay byte-identical.

**Risk.** Low-Med. The redaction is a hard rule, and a cache keyed incorrectly could miss a newly typed token. Keying on the raw inputs avoids that. SYNC-BREAKING (`DiagLog.swift` is shared, with a recorded tvOS adaptation).

**Verify.**
- A test harness feeds 10k recorded lines, including synthetic tokens and MF URLs, through old and new `scrubbed()`. Output must be byte-identical.
- Microbenchmark of `DiagLog.log` ×10k, before and after.
- Export-file parity on a recorded session.

### A6: Wide strips bypass downscale and decode lazily on main — CONFIRMED
**Where.**
- `JTV/Cache.swift:518-527`: when the long side is over 2048 and the short side is 1080 or less, the code returns `UIImage(data: data)`. That is lazily decoded, and the cap is 64 MP, which is about 256 MB of RGBA.
- `capped()` (`:302-315`) only shrinks when the short side is over 1080, so these strips pass through at full size.
- The bitmap is materialised at first draw or crop, which happens on main (A3).
- The NSCache budget is 48–120 MB (`:241-246`), so a single strip can exceed the entire budget.

**Proposed change.** Force the decode off-main inside the load task (`preparingForDisplay()`, SDK to be confirmed) so the bitmap exists before it reaches the view. The 64 MP cap and the native-resolution policy stay. Whether to lower the cap is a separate **BEHAVIOUR CHANGE** (visible sharpness on manga), so it is not proposed.

**Risk.** Medium. Memory peaks move from draw time to load time, and prefetch of the next strip (`TVMangaReaderView.swift:935-944`) would now decode eagerly. The R-1 "≤2 strips resident" discipline must be re-checked. SYNC-BREAKING.

**Verify.** Allocations/VM Tracker peak footprint and main-thread hangs over a 30-strip chapter, before and after.

### A7: Silent `syncAll` on every Home re-appearance — PLAUSIBLE
**Where.** `JTVTV/TVHomeView.swift:204-210`: `.task { … Task { await plugins.syncAll(silent: true) } … }`. `.task` restarts each time the view appears, for example a tab switch back to Home or a pop to the Home root. `syncAll` only guards on `isSyncing` (`JTV/PluginManager.swift:430-431`), so each appearance refetches `plugins.json` (`:546`) and may re-heal scripts or invalidate engines.

**Cost today.** One `plugins.json` fetch (up to 3 attempts) per Home appearance, plus a `syncGeneration` bump when anything changed, which triggers `store.load`.

**Proposed change.** Gate the silent sync with a minimum interval, for example once per launch plus every N minutes. This is a **BEHAVIOUR CHANGE**: plugin updates would land later. It needs approval.

**Risk.** Medium. Sync timing is part of how fixes reach the device.

**Verify first (before any PR).** Count `[sync] start … silent=true` lines against Home appearances in an exported log. That confirms or refutes the PLAUSIBLE label.

### A8: `MetadataOverlay` main-actor file I/O and decode — CONFIRMED (size UNMEASURED)
**Where.**
- `JTV/MetadataOverlay.swift:113-122`: `startIfNeeded()` is `@MainActor`, with a synchronous `Data(contentsOf:)` + `JSONDecoder` + `normalised` on the first `merged(_ page:)` call (`MovieService.swift:238,250,255,264,321`).
- `:124-137`: `refresh()` is `@MainActor`; the download decode, `normalised` and `text.write` all run on main.

**Proposed change.** Do the decode and write in a nonisolated helper and assign `entries` on main. The merge semantics stay the same, with one difference: the very first merge may run before entries load. This is a **BEHAVIOUR CHANGE** unless the first merge awaits the load, so prefer awaiting it.

**Risk.** Low. SYNC-BREAKING (`MetadataOverlay.swift` is byte-identical).

**Verify.** Record the overlay file size on device, then time `startIfNeeded` with a signpost.

### A9: `PluginManager.engine(for:)` without in-flight dedupe — CONFIRMED
**Where.** `JTV/PluginManager.swift:367-415`. The cache check (`:370`) and the store (`:410`) straddle `await engine.load(...)` (`:389`) on the main actor, so concurrent callers for the same plugin each miss. Each one reads the script file on main (`:375`) and evaluates it in a new JSContext; the last store wins. The race is realistic when a silent sync invalidates an engine mid-load (`:628`) while Home sections fan out (`TVHomeView.swift:124-148`).

**Proposed change.** Cache the in-flight load task per plugin id, keyed with a generation counter so an invalidation can never re-insert a stale engine. Read the script off-main.

**Risk.** Low-Med. Concurrent calls would then share one engine, which has one serial queue, instead of two parallel engines. That is a timing change on the plugin path and must be labelled as such. SYNC-BREAKING (`PluginManager.swift` is shared, with recorded adaptations).

**Verify.** Count `JSContext` creations per session via a measurement-build counter. The `[plugin] fn=… ms=` lines show any queueing change.

---

## B. Memory and lifecycle

### B1: `MovieService.pageCache` keeps expired HTML up to 200 entries — CONFIRMED — `PROTECTED`, `SYNC-BREAKING`
**Where.** `JTV/MovieService.swift:96-100, 140-152`. Entries are only checked for TTL on read. On insert, `count > 200` wipes the whole cache. `parsedListCache` (`:111-130`) behaves the same way.

**Cost today.** Up to 200 full page bodies (often 100–500 KB of HTML each) retained long after their 60 s TTL. That is tens of MB of strings on a TV memory budget (UNMEASURED). The wipe also discards *fresh* entries.

**Proposal and risk analysis.**
- **Proposal:** on insert, drop expired entries first, and bound the cache by total UTF-8 bytes as well as count.
- **Hit behaviour:** within 60 s it is unchanged, because an expired entry is already a miss. The difference is that a fresh entry no longer disappears in a cliff wipe.
- **Risk:** low for resolve results, because playback resolution is never cached here.
- **Constraint:** the change sits in the shared region, so it requires a mirrored iOS port.

**Verify.**
- Hit/miss parity on a recorded navigation script, with a log-only counter.
- Heap size of `pageCache` after 30 min of browsing.

### B2: AV host teardown does not release the item or loader — PLAUSIBLE
**Where.**
- `JTVTV/TVAVPlayerHost.swift:317-356`: `invalidate()` removes observers and calls `player?.pause()`. It does **not** `replaceCurrentItem(with: nil)` or nil `player` / `proxyLoader`.
- By contrast, `TVBackdropPreviewHost.swift:342` does call `replaceCurrentItem(with: nil)`.
- The proxy loader's in-flight `URLSessionDataTask`s are never cancelled at teardown (`HLSProxy.swift:396-480`).

**Cost (if confirmed).** A superseded attempt, for example an auto-switch to the next source, could keep buffering and compete for bandwidth with the attempt that replaced it, until the coordinator is deallocated.

**Proposal and risk analysis.** The teardown order is device-proven and carefully gated (FL-202, the gate-fix comments). The proposal is to release the item (and cancel loader tasks) at the **end** of `invalidate()`. This is a **BEHAVIOUR CHANGE** in teardown timing, and the risk is high, because a wrong order can break menu rebuild or seek completion paths.

**Verify first.** Use Network instrument / `nettop` during a forced source switch to see whether the old host's hosts keep transferring after `invalidate`. Only propose a fix if they do.

### B3: `prefetchedEmbeds` pruned only on consume — CONFIRMED — `PROTECTED`, `SYNC-BREAKING`
**Where.** `JTV/MovieService.swift:405, 455, 488-494`. An entry is removed only by `consumePrefetchedEmbed`. Every detail page whose embed was warmed but never played stays for the life of the service.

**Proposal.** Prune entries older than the existing 120 s window on insert. Observable behaviour is the same, because an older entry is already rejected on read. Low risk; small objects.

### B4: One JSVirtualMachine per plugin for the manager's lifetime — UNMEASURED
**Where.** `JTV/PluginEngine.swift:48`: `JSContext()` with no shared VM creates a VM per engine. Engines are cached until invalidated (`PluginManager.swift:410`), up to 14 of them.

**Proposal.** Measure first, with a memgraph and the footprint with 1 vs 14 engines loaded. Do not change anything without a number. Sharing one VM would serialise JS across plugins: a **BEHAVIOUR CHANGE** in concurrency, and SYNC-BREAKING.

### B5: Image disk tier — CONFIRMED
**Where.** `JTV/Cache.swift:251, 259-276`. Pruning happens once per launch, by modification date. A disk hit (`:374`) does not touch the date, so eviction is effectively first-in-first-out, and the tier can grow past 300 MB within one session.

**Proposal.** Update the file's modification date on a disk hit. Low priority. SYNC-BREAKING.

---

## C. Concurrency correctness (Swift 6)

### C1: Shell preflight replica drifted from the core walk — CONFIRMED — BEHAVIOUR CHANGE
**Where.**
- Core: `JTV/MovieService.swift:959-1016`.
- Shell replica: `JTVTV/TVPlayerSession.swift:989-1046`, called at `:775` and `:912`.

The two have diverged in three ways:
1. **Cancellation.** The core stops between candidates (`MovieService.swift:976`, `if Task.isCancelled { break }`; the "gate fix, L-26 round"). The replica has no such check (loop at `TVPlayerSession.swift:1001-1002`). A superseded attempt keeps spending up to 4 s per remaining candidate. The callers' `superseded()` guards (`:756`, `:877`) discard the result afterwards, but only after the wasted checks.
2. **Logging.** The replica uses the `candidate=i/n` form only for `missav` (`:1019`); the core uses it for any multi-candidate walk.
3. **Timing.** The `ms` computation differs: `fallbackMs(since:)` in the core, an inline `Int(… * 1000)` in the replica.

**Proposed change (shell only, not synced).** Add the same `if Task.isCancelled { break }` at the top of the replica's loop. Whether to align the log form is the owner's call. Both are **BEHAVIOUR CHANGES**: fewer checks on superseded attempts, and different log lines.

**Risk.** Low. It mirrors a change already reviewed and shipped in the core.

**Verify.** A forced supersede during a multi-candidate walk, before and after. Count the `[preflight]` lines after the supersede.

### C2: Uncancelled budget Tasks — CONFIRMED
**Where.**
- `JTV/MovieService.swift:1524-1528` (`StreamPreflight.check`; PROTECTED file).
- `JTVTV/TVSourceProbe.swift` (`timeToFirstByte`, the same shape).

The `Task { sleep(timeout); delegate.expire() }` is never cancelled when the verdict arrives first, so it holds the delegate for up to 4 s (or the timeout) after each check. It is harmless today, because `expire()` no-ops.

**Proposal.** Keep the handle and cancel it after the continuation returns. NONE expected; low priority.

### Other concurrency notes (no defect found)
- `DebridPhase2RaceBox` (`DebridResolver.swift:1053-1157`), `PrefetchJoinBox` (`MovieService.swift:38-62`), `ImageCacheManager` dedupe (`Cache.swift:363-389`) and the `TVPlayerSessionReuse` / `TVAutoMeasureArming` locks (`TVPlayerView.swift:112-160`) all resume exactly once and keep check-and-set inside one critical section. Every `MainActor.assumeIsolated` site I checked runs on the main queue or main run loop (`TVAVPlayerHost.swift:245-252, 668-671`; `TVMangaReaderView.swift:1322-1347`; `TVBrowseView.swift:143-144`).
- No project-wide default isolation or upcoming-feature flags are set (`project.yml`). Nonisolated `async` functions therefore run on the global executor, so the JSON decodes in `PluginEngine.decode` are off-main as intended.
- For E2/E3 (continuation and cancellation holes in the protected proxy/server), see §E.

---

## D. Code health

| ID | Finding | Where | Recommendation |
|----|---------|-------|----------------|
| D1 | `AutoSubSubtitles.swift` (966 lines) and `AutoSubCache.swift` (233 lines) are in the tree but **not in `project.yml` sources**. `Net.fetchData` (`Cache.swift:155-174`) has no compiled caller other than AutoSub, so it is dead in this build. | project.yml `sources:` | Keep. CORE-SYNC records them as staged byte-identical ports. List them as "not compiled" in CORE-SYNC so audits don't mistake them for live code. |
| D2 | Preflight walk duplicated between core and shell, with drift already present. | see C1 | Long term: expose the core walk (SYNC-BREAKING), or add a parity test that runs both on fixed fixtures. |
| D3 | Two copies of the "first-byte / resume-once delegate + budget Task" machinery. | `MovieService.swift:1504-1610` vs `TVSourceProbe.swift:20-121` | No merge now: one is protected and synced, the other shell-only. Note for a future core-sync round. |
| D4 | Two remote-image views: core `CachedAsyncImage` (fixed rung 720, `Cache.swift:804-855`) and shell `TVRemoteImage` (`TVComponents.swift:30-130`). `CachedAsyncImage` is used only for plugin icons (`TVSearchView.swift:159`, `TVComponents.swift:540`). | — | Leave it; changing which view draws icons is a UI-adjacent change. |
| D5 | Oversized units that raise change risk: `MovieService` (one class of 1,290 lines; `resolveEpisode` 339 lines), `TVPlayerSession.swift` (1,936 lines; `beginAttempt` 216 lines), `TVMangaReaderView.swift` (1,360 lines). | — | No refactor proposed. These are protected or playback-critical, and a split would be a large unmeasured diff. Recorded for awareness only. |
| D6 | Redundant `NSLock`s on state that is already `@MainActor` (`PluginManager.engines`, `MovieService` page caches). | `PluginManager.swift:78-79`; `MovieService.swift:99,117` | Harmless. Leave it (synced files). |
| D7 | The committed `BundledSecrets` is `enum` (internal), but the CI-generated one is `public enum`. The generated file also duplicates the three debrid tokens already in `DebridSecrets` (read only by the Settings status rows). | `JTV/BundledSecrets.swift:25`; workflow `:87` | Cosmetic. Don't touch without owner direction (CI and secrets path). |

---

## E. Playback-path risks in protected machinery (report only, rule 3)

Every item here is `PROTECTED` and `SYNC-BREAKING` (`HLSProxy.swift`, `LocalHLSServer.swift` and `Cache.swift`/`Net` are shared with iOS). None is proposed for an optimisation PR without the owner approving the risk analysis below.

### E1: Proxy loader ignores byte ranges and refetches the whole resource per request — PLAUSIBLE
**Where.**
- `JTV/HLSProxy.swift:382-384`: the request to the origin is built without a `Range` header.
- `:552-574`: `respond` slices the full body to `requestedOffset/Length`. Only `#EXT-X-ENDLIST` playlists are cached (`:467-472`); segments never are.
- `:556`: `isByteRangeAccessSupported = true` is advertised.

**Cost (if confirmed).**
- AVFoundation may split one resource into several loading requests, such as a small content-information probe followed by the data request, or several ranges.
- Any `#EXT-X-BYTERANGE` playlist (many sub-ranges of one large file) would make the loader download the **entire file for each sub-range**.
- The result is extra bandwidth, slower start, and on large single-file HLS potentially an unplayable stream.

**Risk analysis.** Forwarding `Range` changes what origins see. Some hosts behind this proxy are exactly the fragile ones (PNG-wrapped segments at `:503-505` are stripped from offset 0, so a ranged fetch would break `stripPNGWrapper`). A short-lived per-resource body cache is safer than forwarding `Range`, but it still costs memory. High risk.

**Verify first.** Add a log-only counter of origin fetches per original URL (host and path only, per `urlForLog`) and play one stream from each proxied source. Two or more fetches per segment confirms the finding.

### E2: Cancellation keyed by `ObjectIdentifier` can strand a later request — PLAUSIBLE
**Where.**
- `JTV/HLSProxy.swift:398` (`let id = ObjectIdentifier(loadingRequest)`).
- `:403`: the completion removes `cancelled[id]`.
- `:487`: `didCancel` inserts `id` even when the task is already gone.
- `:410`: the retry closure returns early when `loadingRequest.isFinished`, *without* clearing `cancelled[id]`.

**Failure scenario.**
1. `didCancel` arrives after the completion has removed the task, or during a retry backoff for a request that then finishes. A stale `id` stays in `cancelled`.
2. The request object is deallocated, and a new `AVAssetResourceLoadingRequest` is allocated at the same address. `ObjectIdentifier` is equal.
3. When its fetch completes, `cancelled.remove(id) != nil`, so the code returns without `finishLoading`.
4. AVPlayer waits on a resource that is never answered and stalls.

**Proposal.** Key by a per-request token stored alongside the request, for example a dictionary of `id → (request, token)` with an identity check (`===`) before trusting a `cancelled` entry. Alternatively, insert into `cancelled` only while a task or a pending retry exists for that id.

**Risk.** High (playback core), though the diff would be small.

**Verify first.** Soak test with frequent seeks on a proxied stream. Add a log-only line when a completion is dropped as `wasCancelled`, including whether `didCancel` was ever called for *that* request instance.

### E3: `LocalHLSServer.start()` can wait forever — PLAUSIBLE
**Where.** `JTV/LocalHLSServer.swift:84-123`. Waiters are resumed only on `.ready`, `.failed` or `.cancelled` (`:95-110`). If the listener sits in `.setup` or `.waiting(_)`, `register(_:)` never returns, and the caller's ladder never moves to its next rung. The session's loopback lane does have a watchdog (`TVPlayerSession.swift:1193-1217`), which bounds the user-visible impact on that path. `materializedPlaylist` / `flattenVidSnapMaster` callers have no watchdog of their own (`HLSProxy.swift:309`).

**Proposal.** Resume waiters with `nil` on `.waiting`, or add a start timeout that resolves nil.

**Risk.** Medium: it changes ladder timing when the listener is slow.

**Verify.** Add a log-only line when `start()` waits longer than X ms. Check device logs for `phase=loopback` gaps.

### E4: Loopback server listens on all interfaces — CONFIRMED
**Where.**
- `JTV/LocalHLSServer.swift:91`: `NWListener(using: .tcp, on: .any)` accepts LAN connections, although it is only ever addressed as `127.0.0.1` (`:55`).
- `:140-150`: the request buffer grows without bound until `\r\n\r\n` arrives.
- No idle timeout on accepted connections; `connections` (`:28`) is pruned only on cancelled/failed.

Exposure is limited: playlist names are 64-bit content hashes and the bodies are playlists, not credentials.

**Proposal.** Restrict the listener to loopback (`NWParameters.requiredLocalEndpoint` set to `127.0.0.1`; exists since tvOS 12, but confirm in the tvOS 27 SDK), cap the request buffer (for example 16 KB, then respond 400), and add an idle cancel.

**Risk.** Low-Med. Binding semantics have to be proven on device, because the loopback lane is device-evidenced (L-25).

### E5: URL caches written but not used as intended — PLAUSIBLE
**Where.**
- `JTV/Cache.swift:14-22`: `Net.session` gets a dedicated 100 MB disk `URLCache`, while `requestCachePolicy = .reloadIgnoringLocalCacheData` means that cache is never read. URLSession can still *store* cacheable responses (headers permitting).
- `HLSProxy.swift:34-39`: the proxy's `sharedSession` uses `.default`, so `URLCache.shared` applies to segment bodies fetched through the proxy.
- `Cache.swift:199-207`: the image session also uses `URLCache.shared`, on top of its own disk tier.

**Cost (if confirmed).** Disk write churn of page and segment bodies that are never reused.

**Proposal.** Set `urlCache = nil` on these three sessions, or keep `Net`'s cache but drop its disk capacity. The policy already ignores the cache, so reads cannot change. The only difference is that nothing is written.

**Risk.** Medium: three protected sessions, and the proxy path is device-proven.

**Verify first.** Read the app container's `Library/Caches/com.luun.nguyen.jtv.tvos/Cache.db*` sizes after a session (Devices window container download). Non-trivial sizes confirm it.

---

## Secrets (rule 6)

**S1: No committed credentials found. There is no P1 finding.**
- Scan method: regexes for `api_key / token / secret / password / bearer / authorization` assignments with literal values of 12 or more characters, plus any quoted 32-plus alphanumeric literal, across all `.swift`, `.js` and `.json` files.
- The committed `JTV/BundledSecrets.swift` and `JTV/DebridSecrets.swift` hold empty strings only.
- Credential-bearing requests put tokens in the `Authorization` header (`DebridResolver.swift:659, 818, 975`). The one exception is TorBox `requestdl`, which takes the token as a query item (`:773-778`) because that is the provider's API shape.
- Log redaction is centralised in `DiagLog.scrubbed` (`DiagLog.swift:242-264`). No `DiagLog.log` call site I found interpolates a token, the PIN or a raw URL.

**S2: Design-level observations (no change proposed; owner decisions).**
1. The tokens are base64-encoded literals in the shipped binary (by design, per the README). Anyone holding an IPA can recover them, including anyone with read access to this repo's Actions artifacts during their retention period.
2. The app lock stores an **unsalted SHA-256 of a short PIN** in the binary (workflow `:67-71`), which is brute-forceable offline in milliseconds from the IPA. It guards against casual access on the couch, not against someone holding the IPA.
3. `LogExportView`'s LAN server is protected by a 6-digit path token (`LogExportView.swift:139`) while the screen is open. Exported content is redacted, so the exposure is limited.

---

## Build and CI (affects Phase 2)

- **X1: CI is dispatch-only.** `.github/workflows/build-jtv-tvos.yml:9-10` has `on: workflow_dispatch` only. There is no `pull_request` trigger, so the brief's "keep the copy's CI green on every PR" cannot be checked automatically. **Options for the leader:**
  - (a) Add `pull_request` to the copy's workflow. It costs one macOS job per PR push and needs repo secrets, or the build compiles "nothing configured", which is fine for a compile gate.
  - (b) Dispatch the workflow manually on each PR branch.
- **X2: Xcode pin.** `:31-33` selects Xcode `26.x` while `project.yml` sets `deploymentTarget tvOS: "27.0"` and the brief assumes the tvOS 27 SDK. Check `DTSDKName` / `DTPlatformVersion` / `DTXcode` in a delivered IPA's `Info.plist` to confirm which SDK actually built 1.3.11/19. This matters for rule 7: an API "verified in the tvOS 27 SDK" is moot if CI compiles against 26.
- **Push access from this session was refused** at attach time: the Claude GitHub App is not installed or linked for this repo. Phase 2 PRs cannot be opened from here until that is fixed.

---

## Proposed Phase 2 order (subject to approval)

| PR | Closes | Behaviour change | Sync | Measurement to attach |
|----|--------|------------------|------|------------------------|
| 1 | A1 + A2(a): root store box | NONE | shell only | `PluginManager.init` count; main-thread profile during playback |
| 2 | A3: manga planner off-main | NONE (state ordering argued in PR) | shell only | Hangs on a 30-strip chapter; plan-array parity |
| 3 | A4: single decode per fetch | NONE (edge noted) | SYNC-BREAKING | decode count; cold rail time |
| 4 | A5: DiagLog cached secrets + persistent handle + ring | NONE (byte-identical scrub proven) | SYNC-BREAKING | 10k-line benchmark; scrub parity |
| 5 | C1: replica cancellation stop | **BEHAVIOUR CHANGE**: needs approval | shell only | `[preflight]` lines after a forced supersede |
| – | A6, A7, A8, A9, A2(b), B1–B5, C2 | as flagged | as flagged | approval + "verify first" step |
| – | E1–E5 | protected: proposals only | SYNC-BREAKING | the "verify first" evidence above |

**Before PR 1, the leader needs to decide three things:**
1. The CI trigger (X1).
2. Whether SYNC-BREAKING PRs are welcome on the copy at all, given that each one implies an iOS port.
3. GitHub App access for pushes.


---

## F. Bundled vs live plugin sync

**Compared:** bundled set `JTV/Plugins/` (12 scripts + `plugins.json`) in the app tree at `aec5cdc`, against the live snapshot `sync-reference/jtv-source/` (jtv-source @ `e89c0454`, 14 entries). `modNN.js` is mapped to a plugin id through each live entry's `scriptUrl`.

**Method:**
- Three version numbers were compared for each plugin: the bundled `plugins.json` version, the live `plugins.json` version, and the version each script declares in its own `getManifest()` (that last one is what the app actually records).
- Content: SHA-256 of each script, plus a line diff after normalising CRLF to LF.

*Erratum to §0 scope: the bundle holds 12 plugin scripts plus `plugins.json`, not 13 scripts.*

### F.1 How the app uses the bundled copy (code facts the verdicts depend on)

- **Seeding** (`JTV/PluginManager.swift:169-219`): every bundled plugin whose script file is missing is copied from the app bundle into `Library/Caches/…/plugins` (`:91-97`). A plugin that is installed but whose script was removed gets its recorded version reset to the bundled version (S-3).
- **The bundled copy runs in four situations:**
  1. **Every fresh install's first Home load.** After seeding, `installed` is not empty, so Home takes the *silent* branch (`TVHomeView.swift:204-210`). That loads the bundled scripts at once, while the sync runs alongside.
  2. **Any sync failure.** If `plugins.json` or a script fails to download, the existing copy is kept (`PluginManager.swift:448-460, 640-645`).
  3. **Every tvOS Caches purge**, which reseeds the bundled script and resets its version. tvOS purges Caches routinely, so this is a recurring path, not a rare one.
  4. **For a plugin whose version is equal on both sides, permanently.** The sync's fast path (`:568-588`) compares only versions (live `plugins.json` version vs installed). If live is less than or equal to installed and a script file exists, it never downloads. **A same-version content difference therefore never heals.**
- **What the download path records** (`:590-630`): the version the script *declares itself* (`engine.manifest()`), not the `plugins.json` version. Only name, icon, adult and `scriptUrl` are copied from the `plugins.json` entry. **Other per-entry fields, such as `maxChainParses`, never reach the installed manifest.**

### F.2 Per-plugin verdicts

| Plugin | Bundled (json / js) | Live (json / js) | Live file | Verdict | Content |
|---|---|---|---|---|---|
| avdbapi | 1.0.6 / 1.0.6 | 1.0.6 / 1.0.6 | mod03 | **IN SYNC** | byte-identical |
| javhd | 1.0.7 / 1.0.7 | 1.0.7 / 1.0.7 | mod06 | **IN SYNC** | byte-identical |
| misskon | 1.0.1 / 1.0.1 | 1.0.1 / 1.0.1 | mod10 | **IN SYNC** | byte-identical |
| torrenthub | 1.0.7 / 1.0.7 | 1.0.7 / 1.0.7 | mod14 | **IN SYNC** | byte-identical |
| vlxx | 1.0.7 / 1.0.7 | 1.0.7 / 1.0.7 | mod07 | **IN SYNC** | byte-identical |
| 123av | 1.0.5 / 1.0.5 | 1.0.8 / 1.0.8 | mod02 | **STALE** | +108/−25 lines; live entry adds `relayBase` |
| missav | 1.1.4 / 1.1.4 | 1.1.7 / 1.1.7 | mod01 | **STALE** | +298/−95 |
| njav | 1.0.7 / 1.0.7 | 1.0.8 / 1.0.8 | mod08 | **STALE** | +55/−4 |
| sextop1 | 2.0.3 / 2.0.3 | 2.0.4 / 2.0.4 | mod04 | **STALE** | +5/−5 (domain `.cash` → `.farm`) |
| topxx | 1.0.2 / 1.0.2 | 1.0.3 / 1.0.3 | mod05 | **STALE** | +5/−2 |
| hentaihub | 1.0.2 / 1.0.2 | **1.0.7 / 1.0.5** | mod15 | **STALE** + live json≠js mismatch | +51/−5; live entry adds `maxChainParses: 5` |
| sayhentai | 3.2.0 / 3.2.0 | **3.2.0 / 3.1.0** | mod09 | **CONTENT-DIFFERS-SAME-VERSION** (bundle is *newer*) | bundle has +242 lines that live lacks |
| javguru | — | 1.0.0 / 1.0.0 | mod16 | **MISSING IN BUNDLE** | — |
| javsnap | — | 1.0.0 / 1.0.0 | mod17 | **MISSING IN BUNDLE** | — |

**Leader's preliminary measurement:**
- **Confirmed:** all versions, the two missing plugins, and the five equal-version plugins being byte-identical.
- **Refined:**
  - **sayhentai** is equal-version but **not** in sync, and the live script is the older one.
  - **hentaihub**'s live "1.0.7" is only the `plugins.json` label; the script declares 1.0.5.

### F.3 User-visible consequence when the bundled copy runs

The plugin change notes below are quoted from the diffed scripts. None of these effects was observed on device.

- **123av (1.0.5 vs 1.0.8): source effectively unusable on the TV.**
  - 1.0.8 added relay mode because 123av.com does not answer the TV directly (`PluginManager.swift:378-382`). The bundled 1.0.5 has no relay path.
  - It also misses the 1.0.8 embed-id fix: mixed-case ids such as `8W30XN` get truncated to `8`, so resolving them fails.
  - Single-actress pages are misclassified as the actress index, and cast taps don't route to the actress's filmography.
- **missav (1.1.4 vs 1.1.7):**
  - **No mirror rotation (1.1.5):** if `missav.media` is down, browsing fails instead of rotating to `.live` / `123.com`.
  - **Class-prefix stripping** handles only `missav_media-`, so pages served by another mirror parse badly.
  - **Pre-1.1.5 stream-id extraction** misses the stream id hidden inside the page's packed `eval()` script on some titles, so those **titles won't play**.
  - **Missing:** ranked fallback stream ids (1.1.6) and the 1.1.7 extraction variants.
- **njav (1.0.7 vs 1.0.8):** actor filmography pages 404, because the bundle adds a trailing slash that actor routes reject. Detail-page cast extraction targets the old `<dt>/<dd>` markup, so the cast comes back empty and cast taps go nowhere.
- **sextop1 (2.0.3 vs 2.0.4):** the bundle points at `sextop1.cash`, and the source has moved to `.farm`. The fast path's base-healing only runs when a sync reaches the live entry. Offline or after a failed sync, the whole source fails if `.cash` no longer serves.
- **topxx (1.0.2 vs 1.0.3):** an actor's page shows the entire "latest" catalogue instead of that actor's films, because the old search fallback ignores `?q=`.
- **hentaihub (1.0.2 vs live script 1.0.5):** missing the 1.0.3–1.0.5 resolve-chain work (resolve-scoped note in 1.0.4, the unsigned-MP4 shortcut on watch-started resolves in 1.0.5). Watch-started resolves fall back to the 1.0.2 chain.
- **sayhentai (bundle 3.2.0 newer than live 3.1.0):** here the bundle is the *good* copy. It has the mirror gap-fill (`khotruyen.win`) for titles whose chapter lists `.cx` has pruned. Consequences:
  - Bundle-seeded installs keep 3.2.0 permanently, which is correct by accident.
  - Any install whose sayhentai script came from live (3.1.0) **never gets the gap-fill**, so chapters are still missing in the middle of affected titles.
  - It also falls into the re-download loop below.
- **javguru, javsnap (missing in bundle):**
  - Fresh install before the first successful sync, or a sync failure: these sources **are absent** from the source list.
  - After a Caches purge: they stay listed (the manifest lives in `UserDefaults`), but the script is gone and nothing reseeds it. `engine(for:)` returns nil (`PluginManager.swift:375-377`), so the source shows empty or error until the next successful sync.

### F.4 Live-repo defects found by this check (source repo, so out of this copy's scope; reported for the owner)

**F.4.1 Perpetual re-download loop — CONFIRMED by code reading.** It is caused by a live `plugins.json` version that is higher than the version the script declares. That covers hentaihub (1.0.7 vs 1.0.5), and sayhentai on any install sitting at 3.1.0.
- **The loop:** each sync sees json > installed and downloads the script. It then records the script's own version (still lower), writes the file, invalidates the engine, and sets `changed`, which bumps `syncGeneration` (`PluginManager.swift:590-631`). The bump triggers a Home and Category reload, and the next sync repeats all of it.
- **Combined with A7** (a silent sync on every Home appearance), that is a 70 KB download, two JS evaluations, an engine rebuild and a Home reload on every return to Home.
- **Log evidence to look for:** a repeated `[sync] plugin updated id=hentaihub v1.0.5` in an exported log.

**F.4.2 `maxChainParses: 5` for hentaihub is dead on arrival — CONFIRMED by code reading.**
- It exists only in the live `plugins.json` entry, not in the script's `getManifest()`.
- The sync records the script's manifest (§F.1), so `MovieService.swift:830` always reads 0, and the parse budget stays at the default 4 hops (the "needs 5" comment at `:826-827` never takes effect).
- Whether the 1.0.5 shortcut makes the 5th hop unnecessary in practice is unverified.

**F.4.3 Relay URL in the live 123av entry — possible P1 (rule 6, owner to classify).**
- `relayBase` is `http://192.168.68.x:8797/r/<16-hex token>` (not reproduced here).
- If the path segment is an access key, then it is credential material that is:
  - now committed to this copy repo (`sync-reference/jtv-source/plugins.json`);
  - stored in plain `UserDefaults` (`PluginManager.swift:300`);
  - **not** in DiagLog's redaction set (`DiagLog.swift:280-333`). `urlForLog` keeps the URL path (`:414`), so relayed URLs would carry the token into exported diagnostic logs.
- I made no change.

### F.5 Recommended bundle-refresh policy

1. **Refresh at every release round.** Regenerate `JTV/Plugins/` from the live repo at a pinned jtv-source commit:
   - Rename `modNN.js` to `<id>_plugin.js`, and include **every** live id (today, add javguru and javsnap).
   - Record the source commit (for example a `"sourceCommit"` field in the bundled `plugins.json`, or a CORE-SYNC line) so the bundle's provenance is auditable.
   - Decide `relayBase` explicitly: it is home-LAN-specific and possibly a credential (F.4.3), so it should probably not be bundled.
2. **Gate the release with an automated check that fails the build when any of these are false:**
   - (a) live `plugins.json` version == live script `getManifest()` version for every entry;
   - (b) bundled == live by SHA-256 for every bundled id;
   - (c) every live id is bundled.

   Rules (a) and (b) would each have caught both sayhentai and hentaihub. Such a script fits the copy's CI as a read-only check.
3. **Never change script content without a version bump.** The sync compares versions only, so an equal-version edit never reaches existing installs.
4. **Order of fixes (owner decision, source repo):**
   - **sayhentai:** publish the 3.2.0 script to jtv-source before the next bundle refresh. Otherwise a refresh would downgrade the bundle to 3.1.0 and lose the gap-fill.
   - **hentaihub:** align its two versions. If `maxChainParses` is meant to apply, put it inside `getManifest()`.
5. **App-side hardening (proposal only).** Have the sync carry per-entry fields from `plugins.json`, and compare against the version it will actually record. `PluginManager.swift` is a synced file, so this would be SYNC-BREAKING. It would also be a BEHAVIOUR CHANGE, so it needs approval and is not part of any optimisation PR.
