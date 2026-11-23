import Foundation
import KSPlayer
import SwiftUI
import UIKit

/// JTV tvOS Phase 3 — the KS surface (plan §3.4).
///
/// Core `KSPlayer` product only (NO KSPlayerUI), hosted the
/// JoeTV way: a `UIViewControllerRepresentable` whose view
/// controller creates the `KSPlayerLayer` deferred, at real
/// bounds, and starts it with an explicit `layer.play()`.
/// Headers ride `KSOptions` (`userAgent` + `appendHeader` from
/// StreamInfo.headers); NO buffering options are set — the
/// engine defaults are JoeTV's proven posture (FL-039). The
/// FFmpeg HTTP-patience keys in `formatContextOptions` are
/// JoeTV's, verbatim — they are transport options, not
/// buffering options.
///
/// Subtitles: the layer renders (5.6.2's own renderer).
/// Embedded tracks and sidecar files are both fed into
/// `layer.subtitleModel`; selection goes through
/// `layer.select(subtitleInfo:)`. NO app overlay exists on
/// this surface (FL-039 — its absence is the double-render
/// guard).
///
/// Remote discipline: exactly one owner per press (FL-040) —
/// the host's press handler ignores Select when focus sits on
/// a bar button (the button's own action is the consumer);
/// Menu is never handled here, it propagates to the shell's
/// arbitration (FL-048).
struct TVKSPlayerHost: UIViewControllerRepresentable {
    let stream: StreamInfo
    let attemptID: Int
    let session: TVPlayerSession

    func makeUIViewController(context: Context) -> TVKSPlayerHostViewController {
        // L-T04 probe breadcrumb P8: the KS host is being made.
        DiagLog.log("player", "host.make surface=ks")
        let host = TVKSPlayerHostViewController()
        host.start(stream: stream, attemptID: attemptID, session: session)
        return host
    }

    func updateUIViewController(_ controller: TVKSPlayerHostViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: TVKSPlayerHostViewController,
                                          coordinator: ()) {
        controller.teardown()
    }
}

// MARK: - Host view controller

@MainActor
final class TVKSPlayerHostViewController: UIViewController, KSPlayerLayerDelegate {

    private var stream: StreamInfo?
    private var attemptID = 0
    private var session: TVPlayerSession?
    // Gate fix pass 4 (B-R6-1): validity flag for the
    // resume-seek completion's MainActor hop — teardown()
    // clears it FIRST, so a seek completing after teardown
    // no-ops instead of doing surface work on the dismantled
    // host (the F-B-R4-1 class, mirroring TVAVPlayerHost).
    // teardown() also nils the session reference, as a
    // second layer for other late callbacks.
    private var hostValid = true

    private var layer: KSPlayerLayer?
    /// Play/pause is commanded from this intent flag, never
    /// from `layer.state` (a load-lifecycle enum with no
    /// .playing case) — JoeTV's rule. The flag is a PURE
    /// command flag: it changes only where this host
    /// commands play/pause or a terminal state lands
    /// (.paused / .playedToTheEnd / finish / failure). It
    /// is NEVER derived from `layer.player.isPlaying`:
    /// syncing it from the engine at state callbacks
    /// clobbered it at exactly the moments the watchdog
    /// exists to judge (ready-to-play before the resume
    /// seek, buffering states mid-stall), holding the
    /// ~30 s wait clock open forever.
    private var intentPlaying = false
    private var readyHandled = false
    private var playing = false
    private var failed = false
    private var ended = false

    private var watchdogTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var waitingSince: Date?
    private var lastNoteAt = Date.distantPast
    private var subtitleFedPlayerID: ObjectIdentifier?

    // Transport bar (hand-built, frame layout — JoeTV pattern).
    private var barView: UIView?
    private var playPauseButton: UIButton?
    private var sourceButton: UIButton?
    private var subtitleButton: UIButton?
    private var timeLabel: UILabel?
    private var seekBar: TVSeekBarView?
    private var barVisible = false
    /// Gate fix pass (C-F3): the Đổi nguồn button's visibility
    /// is LATCHED per presentation. It starts hidden and is
    /// shown only once switchable rows exist (the initial
    /// gating is unchanged), but once shown it is NEVER hidden
    /// again while this host lives — one host == one
    /// presentation (recreated per attempt via .id(attemptID))
    /// — so a probe landing mid-browse (hasSwitchRows flipping
    /// true → false) cannot remove the button while it holds
    /// focus or while the controls are presented.
    private var sourceButtonLatchedVisible = false

    // MARK: View lifecycle

    override func loadView() {
        let root = TVKSRootView()
        root.backgroundColor = .black
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildControls()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let playerView = layer?.player.view {
            playerView.frame = view.bounds
        }
        layoutControls()
        beginPlaybackIfPossible()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginPlaybackIfPossible()
        if watchdogTask == nil, layer != nil, !failed {
            armWatchdog()
        }
        if barVisible {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // FL-210: the watchdog (and every other task) is
        // cancelled on BOTH exit paths — disappear here,
        // teardown() at dismantle.
        watchdogTask?.cancel()
        watchdogTask = nil
        hideTask?.cancel()
        hideTask = nil
        feedTask?.cancel()
        feedTask = nil
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if barVisible, let playPauseButton {
            return [playPauseButton]
        }
        return [view]
    }

    // MARK: Start / teardown

    func start(stream: StreamInfo, attemptID: Int, session: TVPlayerSession) {
        self.stream = stream
        self.attemptID = attemptID
        self.session = session
        guard stream.streamURL != nil else {
            session.itemFailed(attempt: attemptID, errorLabel: "player#invalid-url")
            return
        }
        session.registerHost(
            attempt: attemptID,
            positionProvider: { [weak self] in
                guard let self, let layer = self.layer else { return 0 }
                let seconds = layer.player.currentPlaybackTime
                return seconds.isFinite ? seconds : 0
            },
            subtitleApplier: { [weak self] choice in
                self?.applyChoiceNow(choice) ?? choice
            })
        beginPlaybackIfPossible()
        // L-T04 probe breadcrumb (P10 twin for the KS host):
        // start() completed — layer creation may still be
        // deferred to first real bounds, as in JoeTV's host.
        DiagLog.log("player", "start.done surface=ks")
    }

    func teardown() {
        // Gate fix pass 4 (B-R6-1): validity cleared FIRST —
        // a resume-seek completion already enqueued on the
        // MainActor before the cancellations below must find
        // the host invalid and no-op (mirroring
        // TVAVPlayerHost.invalidate() ordering).
        hostValid = false
        watchdogTask?.cancel()
        watchdogTask = nil
        hideTask?.cancel()
        hideTask = nil
        feedTask?.cancel()
        feedTask = nil
        layer?.delegate = nil
        layer?.stop()
        layer = nil
        session?.deregisterHost(attempt: attemptID)
        // Gate fix pass 4 (B-R6-1): nil the session LAST, so
        // any other late delegate/task callback reaching
        // session? no-ops on the reference itself, not only
        // on the session's attempt guards. Done last: every
        // step above still needs the session.
        session = nil
    }

    /// Creates the layer — but only once the host view has
    /// REAL, non-zero bounds (creating it in
    /// makeUIViewController froze JoeTV's surface at the
    /// pre-layout safe-area size forever). Sizing is frame +
    /// autoresizingMask, per the library's contract, and the
    /// player view goes UNDER the transport bar.
    private func beginPlaybackIfPossible() {
        guard layer == nil,
              let stream, let url = stream.streamURL,
              view.bounds.width > 0, view.bounds.height > 0
        else { return }
        let options = KSOptions()
        options.userAgent = stream.headers["User-Agent"] ?? Net.desktopUA
        if !stream.headers.isEmpty {
            options.appendHeader(stream.headers)
        }
        // JoeTV's FFmpeg HTTP patience (transport, not
        // buffering): 20 s read/write timeout + automatic
        // reconnect, so a dropped debrid connection is resumed
        // by the engine itself before any watchdog judges.
        options.formatContextOptions["rw_timeout"] = "20000000"
        options.formatContextOptions["reconnect"] = "1"
        options.formatContextOptions["reconnect_streamed"] = "1"
        options.formatContextOptions["reconnect_at_eof"] = "1"
        options.formatContextOptions["reconnect_delay_max"] = "5"
        // The FFmpeg engine, deterministically.
        KSOptions.firstPlayerType = KSMEPlayer.self
        let layer = KSPlayerLayer(url: url, options: options, delegate: self)
        self.layer = layer
        let playerView = layer.player.view
        playerView.frame = view.bounds
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(playerView, at: 0)
        // Play EXPLICITLY — never rely on library autoplay.
        layer.play()
        intentPlaying = true
        armWatchdog()
        showControls()
    }

    // MARK: Watchdog (mirrors the AV rule, §3.4)

    /// One rule on both surfaces: intending to play but not
    /// playing — pre-first-frame buffering or a mid-play stall
    /// — runs the wait clock; ~30 s continuous fails the
    /// attempt. A user pause (intent off) holds the clock open.
    private func armWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        guard !failed, !ended, let layer else { return }
        if intentPlaying, !layer.player.isPlaying {
            if waitingSince == nil { waitingSince = Date() }
            if let since = waitingSince, Date().timeIntervalSince(since) >= 30 {
                let waited = Int(Date().timeIntervalSince(since))
                failed = true
                watchdogTask?.cancel()
                watchdogTask = nil
                layer.stop()
                session?.watchdogFailed(attempt: attemptID, surface: "ks", waitedSeconds: waited)
            }
        } else {
            waitingSince = nil
        }
    }

    // MARK: KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        switch state {
        case .readyToPlay:
            if !readyHandled {
                readyHandled = true
                guard let session else { return }
                let target = session.itemReady(attempt: attemptID)
                prepareSubtitleModel(layer: layer)
                refreshBar()
                if TVResumeRule.shouldSeek(target) {
                    // The shared resume rule (§5.2): seek
                    // once, play only on finished == true.
                    layer.seek(time: target, autoPlay: false) { [weak self, weak layer] finished in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            // Gate fix pass 4 (B-R6-1): a seek
                            // completing after teardown() must
                            // not note the session, play the
                            // dismantled layer, or touch the
                            // controls/bar (mirrors the AV
                            // surface's F-B-R4-1 guard).
                            guard self.hostValid else { return }
                            self.session?.noteResumeSeek(attempt: self.attemptID,
                                                         target: target, finished: finished)
                            if finished {
                                // Play only if the command
                                // intent still stands: a user
                                // pause commanded before or
                                // during the seek (intent off)
                                // is never overridden — the
                                // KS mirror of the AV surface's
                                // user-pause veto. Intent is
                                // already true on the untouched
                                // path (set when playback was
                                // commanded at layer creation),
                                // so a hung seek also leaves
                                // intent standing and the
                                // watchdog clock runs.
                                if self.intentPlaying {
                                    layer?.play()
                                }
                                // Through showControls() like
                                // every other resume path, so the
                                // auto-hide clock is re-armed even
                                // if it fired (and was vetoed)
                                // during a slow seek (FL-081).
                                self.showControls()
                                self.refreshBar()
                            }
                        }
                    }
                }
            }
        case .bufferFinished:
            if !playing {
                playing = true
                // §6: the inventory has no first-frame-rendered
                // callback; bufferFinished (the playing
                // transition) is the surface's first-frame
                // signal, named in the line via via=.
                session?.noteFirstFrame(attempt: attemptID, surface: "ks", via: "bufferFinished")
            }
            refreshBar()
        case .paused, .playedToTheEnd:
            intentPlaying = false
            refreshBar()
        case .error:
            failLoad(errorLabel: "KSPlayerState#0")
        default:
            // Non-enumerated states (buffering and friends)
            // change nothing: in particular they must never
            // touch the command intent — a stall accompanied
            // by a buffering callback is exactly what the
            // watchdog's wait clock exists to measure.
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        let now = Date()
        guard now.timeIntervalSince(lastNoteAt) >= 0.5 else { return }
        lastNoteAt = now
        session?.notePosition(attempt: attemptID,
                              position: currentTime.isFinite ? currentTime : 0,
                              duration: totalTime.isFinite ? totalTime : 0)
        refreshBar()
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error {
            failLoad(errorLabel: TVPlayerSession.errorLabel(error))
        } else if !ended, !failed {
            // !failed: a watchdog kill sets failed and calls
            // layer.stop() BEFORE reporting; if stop() delivers
            // finish(nil) synchronously, the attempt was killed,
            // not finished — it must not reach itemEnded.
            ended = true
            intentPlaying = false
            session?.itemEnded(attempt: attemptID)
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}

    private func failLoad(errorLabel: String) {
        guard !failed else { return }
        failed = true
        intentPlaying = false
        watchdogTask?.cancel()
        watchdogTask = nil
        session?.itemFailed(attempt: attemptID, errorLabel: errorLabel)
    }

    // MARK: Subtitles — feed + selection (§4.2: the layer renders)

    static func fileSubtitleID(index: Int) -> String { "jtv-file-\(index)" }

    /// Feeds the layer's subtitle model ONCE per player
    /// instance (addSubtitle appends — a second feed would
    /// duplicate every panel row), delayed 1 s because
    /// embedded subtitles carried inside the stream can land
    /// after readyToPlay (JoeTV's discipline, verbatim shape).
    private func prepareSubtitleModel(layer: KSPlayerLayer) {
        let playerID = ObjectIdentifier(layer.player as AnyObject)
        guard subtitleFedPlayerID != playerID else { return }
        subtitleFedPlayerID = playerID
        guard let stream else { return }
        let dataSource = layer.player.subtitleDataSource
        guard dataSource != nil || !stream.subtitles.isEmpty else {
            applySubtitleDirective(layer: layer)
            return
        }
        feedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled,
                  let layer = self.layer,
                  ObjectIdentifier(layer.player as AnyObject) == playerID
            else { return }
            let model = layer.subtitleModel
            if let dataSource {
                model.addSubtitle(dataSource: dataSource)
            }
            for (index, track) in stream.subtitles.enumerated() {
                guard let url = URL(string: track.url) else { continue }
                let info = URLSubtitleInfo(
                    subtitleID: Self.fileSubtitleID(index: index),
                    name: track.displayName,
                    url: url,
                    userAgent: stream.headers["User-Agent"] ?? Net.desktopUA)
                model.addSubtitle(dataSource: TVFileSubtitleDataSource(info: info))
            }
            self.applySubtitleDirective(layer: layer)
            self.refreshBar()
        }
    }

    /// Applies the session's directive (manual pick or the
    /// default rule) to the fed model and reports the §6 subs
    /// line. The default rule uses the ONE shared ranking
    /// (TVSubtitleDefaultRanking, §4.4): file VI → embedded
    /// VI → embedded EN → file EN → nothing.
    private func applySubtitleDirective(layer: KSPlayerLayer) {
        guard let session, let stream else { return }
        let model = layer.subtitleModel
        let all = model.subtitleInfos
        let fileIDs = Set(stream.subtitles.indices.map { Self.fileSubtitleID(index: $0) })
        let embedded = all.filter { !fileIDs.contains($0.subtitleID) }
        let fileInfos = all.filter { fileIDs.contains($0.subtitleID) }
        session.updateCatalog(attempt: attemptID, embedded: embedded.map {
            TVEmbeddedTrackRef(key: $0.subtitleID,
                               displayName: $0.name.isEmpty ? $0.subtitleID : $0.name,
                               languageHint: "")
        })

        var applied = "default-none"
        var effective: TVSubtitleChoice = .off
        switch session.subtitleDirective() {
        case .applyManual(let choice):
            // applied=/effective report what selectOnLayer
            // ACTUALLY selected: a cross-surface embedded pick
            // resolves to this surface's track (§4.4), and a
            // pick that matches nothing is off — never a
            // claimed "track" that was not selected.
            let resolved = selectOnLayer(choice, layer: layer)
            effective = resolved
            switch resolved {
            case .off: applied = "off"
            case .embedded: applied = "track"
            case .file: applied = "file"
            }
        case .applyDefault:
            let viFileIndex = stream.subtitles.firstIndex {
                TVSubtitleLanguage.isVietnamese(name: $0.label, code: $0.lang)
            }
            let enFileIndex = stream.subtitles.firstIndex {
                TVSubtitleLanguage.isEnglish(name: $0.label, code: $0.lang)
            }
            let viEmbedded = embedded.first(where: {
                TVSubtitleLanguage.isVietnamese(name: $0.name, code: $0.subtitleID)
            })
            let enEmbedded = embedded.first(where: {
                TVSubtitleLanguage.isEnglish(name: $0.name, code: $0.subtitleID)
            })
            switch TVSubtitleDefaultRanking.winningSlot(
                hasFileVietnamese: viFileIndex != nil,
                hasEmbeddedVietnamese: viEmbedded != nil,
                hasEmbeddedEnglish: enEmbedded != nil,
                hasFileEnglish: enFileIndex != nil) {
            case .some(.fileVietnamese):
                if let viFileIndex,
                   let info = fileInfos.first(where: { $0.subtitleID == Self.fileSubtitleID(index: viFileIndex) }) {
                    layer.select(subtitleInfo: info)
                    applied = "default-vi"
                    effective = .file(stream.subtitles[viFileIndex])
                } else {
                    // The winning slot existed but its fed
                    // info is missing (the track was skipped
                    // at feed time, e.g. a malformed URL):
                    // report the honest "off", never
                    // "default-none" — a default DID exist.
                    layer.select(subtitleInfo: nil)
                    applied = "off"
                }
            case .some(.embeddedVietnamese):
                if let viEmbedded {
                    layer.select(subtitleInfo: viEmbedded)
                    applied = "default-vi"
                    // Display name normalised exactly as
                    // the panel catalogue normalises it
                    // (empty name -> the subtitleID), so the
                    // effective choice can equal a panel row.
                    effective = .embedded(key: viEmbedded.subtitleID,
                                          displayName: viEmbedded.name.isEmpty ? viEmbedded.subtitleID : viEmbedded.name)
                }
            case .some(.embeddedEnglish):
                if let enEmbedded {
                    layer.select(subtitleInfo: enEmbedded)
                    applied = "default-en"
                    effective = .embedded(key: enEmbedded.subtitleID,
                                          displayName: enEmbedded.name.isEmpty ? enEmbedded.subtitleID : enEmbedded.name)
                }
            case .some(.fileEnglish):
                if let enFileIndex,
                   let info = fileInfos.first(where: { $0.subtitleID == Self.fileSubtitleID(index: enFileIndex) }) {
                    layer.select(subtitleInfo: info)
                    applied = "default-en"
                    effective = .file(stream.subtitles[enFileIndex])
                } else {
                    // Same missing-info edge as the
                    // Vietnamese file slot above: honest
                    // "off", not "default-none".
                    layer.select(subtitleInfo: nil)
                    applied = "off"
                }
            case .none:
                break
            }
        }
        session.noteSubtitlesApplied(attempt: attemptID,
                                     embedded: embedded.count,
                                     files: stream.subtitles.count,
                                     applied: applied,
                                     effective: effective,
                                     overlayFile: nil)
    }

    /// A panel pick applied to the live layer at once.
    /// Returns what ACTUALLY took effect (the session
    /// stores it as the effective choice, so the panel's
    /// checkmark follows the resolved pick, not the raw
    /// cross-surface key).
    @discardableResult
    private func applyChoiceNow(_ choice: TVSubtitleChoice) -> TVSubtitleChoice {
        guard let layer else { return choice }
        let resolved = selectOnLayer(choice, layer: layer)
        // No intent re-sync here: a subtitle pick is not a
        // play/pause command, and the engine's momentary
        // isPlaying (e.g. mid-buffering) must never rewrite
        // the command flag.
        refreshBar()
        return resolved
    }

    /// Selects a choice on the layer and returns what
    /// ACTUALLY took effect. An embedded pick is resolved
    /// against this surface's catalogue through the shared
    /// cross-surface order (§4.4: exact key → display name →
    /// language), because a pick stored on the AV surface
    /// carries an AV key that matches nothing here; a pick
    /// that resolves to nothing selects nil and reports .off.
    @discardableResult
    private func selectOnLayer(_ choice: TVSubtitleChoice, layer: KSPlayerLayer) -> TVSubtitleChoice {
        guard let stream else { return .off }
        let model = layer.subtitleModel
        switch choice {
        case .off:
            layer.select(subtitleInfo: nil)
            return .off
        case .embedded(let key, let displayName):
            let fileIDs = Set(stream.subtitles.indices.map { Self.fileSubtitleID(index: $0) })
            let catalog = model.subtitleInfos
                .filter { !fileIDs.contains($0.subtitleID) }
                .map { TVEmbeddedTrackRef(key: $0.subtitleID,
                                           displayName: $0.name.isEmpty ? $0.subtitleID : $0.name,
                                           languageHint: "") }
            if let resolved = TVEmbeddedPickResolver.resolve(key: key, displayName: displayName, in: catalog),
               let info = model.subtitleInfos.first(where: { $0.subtitleID == resolved.key }) {
                layer.select(subtitleInfo: info)
                return .embedded(key: resolved.key, displayName: resolved.displayName)
            }
            layer.select(subtitleInfo: nil)
            return .off
        case .file(let track):
            if let index = stream.subtitles.firstIndex(of: track),
               let info = model.subtitleInfos.first(where: { $0.subtitleID == Self.fileSubtitleID(index: index) }) {
                layer.select(subtitleInfo: info)
                return choice
            }
            layer.select(subtitleInfo: nil)
            return .off
        }
    }

    // MARK: Remote presses (Menu deliberately untouched)

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .select:
                showControls()
                // FL-040: exactly one owner per press. When
                // focus sits on one of the bar's own buttons,
                // the button's action consumes Select and the
                // host must not also toggle (the JoeTV
                // double-toggle fault).
                if !focusIsOnBarButton() {
                    togglePlayPause()
                }
                handled = true
            case .playPause:
                showControls()
                togglePlayPause()
                handled = true
            case .leftArrow:
                showControls()
                // With focus inside the bar (or a panel up),
                // arrows belong to focus movement; an
                // edge-of-row press that still bubbles up
                // must never become a seek.
                if session?.presentedPanel == nil, !focusInControls() {
                    seekBy(-30)
                }
                handled = true
            case .rightArrow:
                showControls()
                if session?.presentedPanel == nil, !focusInControls() {
                    seekBy(30)
                }
                handled = true
            case .menu:
                // Never handled here — Menu propagates to the
                // shell's Menu arbitration (FL-048).
                break
            default:
                // Up/Down and anything else only wake the bar;
                // never swallowed, so the focus engine still
                // receives them.
                showControls()
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    private func focusedView() -> UIView? {
        func search(_ candidate: UIView) -> UIView? {
            if candidate.isFocused { return candidate }
            for subview in candidate.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(view)
    }

    private func focusIsOnBarButton() -> Bool {
        guard let focused = focusedView() else { return false }
        return focused === playPauseButton
            || focused === sourceButton
            || focused === subtitleButton
    }

    private func focusInControls() -> Bool {
        guard let focused = focusedView(), let barView else { return false }
        return focused === barView || focused.isDescendant(of: barView)
    }

    private func togglePlayPause() {
        guard let layer else { return }
        if intentPlaying {
            layer.pause()
            intentPlaying = false
        } else {
            layer.play()
            intentPlaying = true
        }
        refreshBar()
    }

    private func seekBy(_ delta: TimeInterval) {
        guard let layer else { return }
        let from = layer.player.currentPlaybackTime
        let target = max(0, (from.isFinite ? from : 0) + delta)
        layer.seek(time: target, autoPlay: true) { _ in }
        intentPlaying = true
        refreshBar()
    }

    // MARK: Transport bar (hand-built)

    private func buildControls() {
        let bar = UIView()
        bar.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        bar.layer.cornerRadius = 24
        bar.isHidden = true
        view.addSubview(bar)
        barView = bar

        let playPause = Self.makeBarButton(symbol: "play.fill")
        playPause.addTarget(self, action: #selector(playPauseTapped), for: .primaryActionTriggered)
        bar.addSubview(playPause)
        playPauseButton = playPause

        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.text = "0:00 / 0:00"
        bar.addSubview(label)
        timeLabel = label

        let source = Self.makeBarButton(title: "Đổi nguồn")
        // L-T13 §5.3: starts hidden; refreshBar() unhides it
        // only when switchable rows exist.
        source.isHidden = true
        source.addTarget(self, action: #selector(sourceTapped), for: .primaryActionTriggered)
        bar.addSubview(source)
        sourceButton = source

        let subtitles = Self.makeBarButton(title: "Phụ đề")
        subtitles.addTarget(self, action: #selector(subtitleTapped), for: .primaryActionTriggered)
        bar.addSubview(subtitles)
        subtitleButton = subtitles

        let seek = TVSeekBarView()
        seek.onStep = { [weak self] delta in
            // Through showControls() like every other resume
            // path, so the auto-hide clock is re-armed.
            self?.showControls()
            self?.seekBy(delta)
        }
        seek.onTogglePlayPause = { [weak self] in
            // Through showControls() like every other resume
            // path, so the auto-hide clock is re-armed.
            self?.showControls()
            self?.togglePlayPause()
        }
        bar.addSubview(seek)
        seekBar = seek
    }

    private func layoutControls() {
        guard let bar = barView else { return }
        let bounds = view.bounds
        let barWidth = bounds.width - 120
        let barHeight: CGFloat = 138
        bar.frame = CGRect(x: 60, y: bounds.height - barHeight - 52,
                           width: barWidth, height: barHeight)
        playPauseButton?.frame = CGRect(x: 18, y: 14, width: 68, height: 62)
        timeLabel?.frame = CGRect(x: 104, y: 14, width: 330, height: 62)
        let sourceWidth: CGFloat = 196
        let subtitleWidth: CGFloat = 176
        subtitleButton?.frame = CGRect(x: barWidth - subtitleWidth - 18, y: 14,
                                       width: subtitleWidth, height: 62)
        sourceButton?.frame = CGRect(x: barWidth - subtitleWidth - sourceWidth - 34, y: 14,
                                     width: sourceWidth, height: 62)
        seekBar?.frame = CGRect(x: 18, y: 92, width: barWidth - 36, height: 34)
    }

    private static func makeBarButton(title: String? = nil, symbol: String? = nil) -> UIButton {
        // The plate lives INSIDE the filled configuration —
        // one rendering owner per control (JoeTV v2.0.30
        // FIX6: a hand-set backgroundColor + layer radius on
        // a .system button double-rendered with the system's
        // own focus platter).
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.16)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        if let title {
            config.title = title
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.systemFont(ofSize: 24, weight: .semibold)
                return attributes
            }
        }
        if let symbol {
            config.image = UIImage(systemName: symbol)
        }
        return UIButton(configuration: config)
    }

    @objc private func playPauseTapped() {
        showControls()
        togglePlayPause()
    }

    @objc private func sourceTapped() {
        // L-T13 §5.3 (1.3.1): the KS Đổi nguồn button is gated
        // like every other surface — with nothing to switch to
        // it no longer opens a one-row dead panel (the panel
        // itself carries the provider rows for hash titles).
        // Gate fix pass 2 (C2): behaviour must match
        // VISIBILITY. The F3 latch keeps this button visible
        // and focusable after the probe flips hasSwitchRows to
        // false (≤1 configured provider), so in exactly that
        // latched state the tap must still present the source
        // panel — populated with whatever switch rows
        // currently exist (a single row reads as the current
        // source) — never a silent dead tap. The guard below
        // therefore passes when rows exist OR the button is
        // latched visible; a hidden (never-latched, no-rows)
        // button cannot be tapped at all, and the guard keeps
        // that invariant if it ever were.
        guard session?.hasSwitchRows == true || sourceButtonLatchedVisible else { return }
        if session?.hasSwitchRows != true {
            DiagLog.log("player", "source.tapped latched=true rows=current-only panel=sources")
        }
        session?.presentedPanel = .sources
    }

    @objc private func subtitleTapped() {
        session?.presentedPanel = .subtitles
    }

    private func refreshBar() {
        guard let playPauseButton else { return }
        // L-T13 §5.3: hide the Đổi nguồn button when the total
        // switchable rows (episode variants + provider rows)
        // are ≤ 1 — the same gate as the AV menu and the
        // loading/error surfaces.
        // Gate fix pass (C-F3): through the per-presentation
        // latch — once hasSwitchRows has shown the button, a
        // later flip (the probe publishing ≤1 configured
        // provider) no longer hides it mid-presentation.
        if session?.hasSwitchRows == true {
            sourceButtonLatchedVisible = true
        }
        sourceButton?.isHidden = !sourceButtonLatchedVisible
        var config = playPauseButton.configuration
        config?.image = UIImage(systemName: intentPlaying ? "pause.fill" : "play.fill")
        playPauseButton.configuration = config
        let position = layer?.player.currentPlaybackTime ?? 0
        let duration = layer?.player.duration ?? 0
        timeLabel?.text = "\(Self.clock(position)) / \(Self.clock(duration))"
        if let seekBar {
            seekBar.fraction = (duration.isFinite && duration > 0 && position.isFinite)
                ? min(1, max(0, position / duration)) : 0
            seekBar.setNeedsDisplay()
        }
    }

    private func showControls() {
        barVisible = true
        barView?.isHidden = false
        (view as? TVKSRootView)?.acceptsFocus = false
        setNeedsFocusUpdate()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.hideControlsIfPlaying()
        }
    }

    /// Auto-hide (FL-081): only while playing, never under an
    /// open panel. The panel veto re-arms (via showControls);
    /// the not-playing veto does NOT re-arm — the bar stays up
    /// until the next resume path calls showControls().
    private func hideControlsIfPlaying() {
        guard session?.presentedPanel == nil else {
            showControls()
            return
        }
        guard intentPlaying else { return }
        barVisible = false
        barView?.isHidden = true
        (view as? TVKSRootView)?.acceptsFocus = true
        setNeedsFocusUpdate()
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Root view (the host's one focusable surface)

/// With focus on this view, remote presses bubble up the
/// responder chain to the host's pressesEnded. Its focus
/// eligibility is DYNAMIC (JoeTV's rule): while the bar is
/// up the root refuses focus, forcing relocation into the
/// bar's controls.
private final class TVKSRootView: UIView {
    var acceptsFocus = true
    override var canBecomeFocused: Bool { acceptsFocus }
}

// MARK: - Seek bar (FL-016: focus must reach it)

/// A hand-drawn focusable seek bar (UISlider cannot take tvOS
/// focus). Draws track / played fill / knob only — no buffered
/// fill, because the KS delegate surface exposes no buffered
/// time range. Left/Right step ∓30 s, Select toggles
/// play/pause; presses it does not handle pass up the
/// responder chain untouched (so a handled press never also
/// reaches the host — one owner per press, FL-040).
private final class TVSeekBarView: UIView {
    var fraction: Double = 0
    var onStep: ((TimeInterval) -> Void)?
    var onTogglePlayPause: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    override func draw(_ rect: CGRect) {
        let barHeight: CGFloat = isFocused ? 10 : 6
        let y = (rect.height - barHeight) / 2
        let trackRect = CGRect(x: 0, y: y, width: rect.width, height: barHeight)
        UIColor.white.withAlphaComponent(0.35).setFill()
        UIBezierPath(roundedRect: trackRect, cornerRadius: barHeight / 2).fill()
        let fillWidth = rect.width * CGFloat(max(0, min(1, fraction)))
        if fillWidth > 0 {
            let fillRect = CGRect(x: 0, y: y, width: fillWidth, height: barHeight)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: fillRect, cornerRadius: barHeight / 2).fill()
        }
        let knob: CGFloat = isFocused ? 30 : 18
        let knobX = max(0, min(rect.width - knob, fillWidth - knob / 2))
        let knobRect = CGRect(x: knobX, y: (rect.height - knob) / 2,
                              width: knob, height: knob)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: knobRect).fill()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        setNeedsDisplay()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:
                onStep?(-30)
                handled = true
            case .rightArrow:
                onStep?(30)
                handled = true
            case .select:
                onTogglePlayPause?()
                handled = true
            default:
                break
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }
}

// MARK: - Sidecar file data source (JoeTV's pattern)

/// A fixed-slate subtitle data source carrying ONE sidecar
/// file. KSPlayer's URLSubtitleInfo downloads and parses the
/// file lazily when it becomes the selected info.
private final class TVFileSubtitleDataSource: ConstantSubtitleDataSource {
    private let info: URLSubtitleInfo
    init(info: URLSubtitleInfo) { self.info = info }
    func infos() -> [any SubtitleInfo] { [info] }
}
