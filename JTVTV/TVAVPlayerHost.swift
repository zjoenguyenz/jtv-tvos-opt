import AVFoundation
import AVKit
import Combine
import Foundation
import SwiftUI

/// JTV tvOS Phase 3 — the AV surface (plan §3.3).
///
/// A stock `AVPlayerViewController` (system transport, system
/// rendering of embedded subtitle groups) fed an `AVURLAsset`
/// built the JoeTV way: `AVURLAssetHTTPHeaderFieldsKey` carries
/// the StreamInfo headers (plus the house UA when the stream
/// set none). For `requiresProxy` streams the asset is the
/// core's `HLSProxyLoader` custom-scheme asset instead — the
/// loader fetches every resource itself with the same headers.
///
/// Discipline: initial play is gated on `.readyToPlay`
/// (FL-201); every observer registration below has its removal
/// written beside it in `invalidate()` (FL-202); interruption /
/// end-of-item / stall observers are registered from the start
/// (FL-206); the freeze watchdog reads the waiting state with a
/// ~30 s continuous-wait ceiling (FL-042).
struct TVAVPlayerHost: UIViewControllerRepresentable {
    let stream: StreamInfo
    let attemptID: Int
    let useProxy: Bool
    let session: TVPlayerSession

    @MainActor
    final class Coordinator {
        weak var controller: AVPlayerViewController?
        var player: AVPlayer?
        var proxyLoader: HLSProxyLoader?

        private var stream: StreamInfo?
        private var attemptID = 0
        private var session: TVPlayerSession?

        // Observer tokens — every registration's removal lives
        // in invalidate() (FL-202).
        private var statusObservation: NSKeyValueObservation?
        private var timeControlObservation: NSKeyValueObservation?
        private var periodicObserver: Any?
        private var notificationTokens: [NSObjectProtocol] = []

        private var watchdogTask: Task<Void, Never>?
        private var waitingSince: Date?

        private var stallTask: Task<Void, Never>?
        /// L-T21: seconds a mid-playback stall may persist
        /// before the stall fast path takes the watchdog's
        /// exit (fail the attempt → the session re-resolves
        /// and resumes) instead of waiting out the full 30 s
        /// watchdog. The grace only forgives stalls the
        /// player recovers from on its own inside the window.
        private let stallGraceSeconds = 5

        // Gate fix pass (F-B3/C-F2): the transport menu is a
        // snapshot of session.providerRows, so the coordinator
        // observes that ONE published property (the same
        // stored-token discipline as the KVO observers above:
        // the cancellable is stored and cancelled in
        // invalidate()). The snapshot of the rows the menu was
        // last built from gates the rebuild — the menu rebuilds
        // ONLY when the provider rows actually change, never on
        // unrelated session publishes, and never in a loop (a
        // rebuild publishes nothing itself).
        private var providerRowsCancellable: AnyCancellable?
        private var lastMenuProviderRows: [TVPlayerSession.ProviderRow]?
        // Gate fix pass 2 (C3): a provider-rows rebuild must
        // not reassign transportBarCustomMenuItems WHILE the
        // transport menu is presented (it would reset the menu
        // mid-browse). When a real rows change lands during a
        // presentation, the rebuild is deferred into this flag
        // and applied by the periodic observer the moment the
        // presentation is gone (see observeProviderRows /
        // applyPendingMenuRebuild). AVKit exposes NO public
        // "transport menu presented" signal; the strongest
        // available proxy in this host's structure is the
        // controller's presentedViewController (AVKit presents
        // its transport-menu UI through the view-controller
        // hierarchy). Stated limit: if a tvOS version presents
        // that menu without surfacing a presented view
        // controller on this controller, the deferral does not
        // engage and the rebuild lands immediately — the R3
        // behaviour, which Lens C bounded as a non-destructive
        // presentation hiccup (value-captured actions, fresh
        // check state on reopen). The deferral can only ever
        // DELAY a rebuild, never lose one: the flag is drained
        // by the 0.25 s periodic observer while time advances
        // and, since gate fix pass 3 (C-R4-2), by a 0.5 s
        // wall-clock timer while it is set (the observer does
        // not fire while paused); it is cleared only by
        // applying it or by invalidate().
        private var pendingMenuRebuild = false
        // Gate fix pass 3 (C-R4-2): the periodic time
        // observer does NOT fire while playback is paused
        // (it is driven by the player's time progressing),
        // so a rebuild deferred while paused could sit
        // undrained until playback resumed — the re-opened
        // menu would still show the stale snapshot. While
        // pendingMenuRebuild is set, this wall-clock timer
        // (0.5 s, main run loop — the coordinator is
        // MainActor-isolated, the same context the periodic
        // observer's .main queue lands on) re-checks the
        // SAME dismissal condition and drains via the SAME
        // applyPendingMenuRebuild(). It is armed when a
        // deferral is recorded, stops the moment the flag
        // drains (whichever driver drains it), and is
        // invalidated in invalidate() with the other
        // teardown. The defer condition, the snapshot guard
        // and buildTransportMenu are unchanged.
        private var menuRebuildTimer: Timer?
        // Gate fix pass 2 (F-B3-R3-1): validity flag for the
        // sink's MainActor hop — invalidate() clears it FIRST,
        // so a delivery that was already enqueued when the
        // cancellable was cancelled no-ops instead of
        // rebuilding the menu on the dismantled host.
        // invalidate() also nils the session/controller
        // references the rebuild reads, as a second layer.
        private var hostValid = true

        private var readyHandled = false
        /// A resume seek was attempted at ready and is still
        /// IN FLIGHT. The flag's guarded window is the seek's
        /// flight only: it is set when the seek starts and
        /// cleared in the seek completion, whatever the result
        /// (finished true or false). Inside the window a
        /// `.paused` read may be the seek's own dead pause, so
        /// the watchdog counts it as waiting; once the seek has
        /// completed the window is over and a `.paused` read is
        /// a user pause again, holding the watchdog clock open
        /// like any other user pause (FL-204: playback may
        /// only follow a finished seek).
        private var resumeSeekAwaitingPlayback = false
        /// Set when the user pauses DURING the seek window:
        /// the timeControlStatus observer saw a transition to
        /// `.paused` after the status had left `.paused` since
        /// the seek started (playback or waiting had begun, so
        /// the pause is the user's act, not the seek's own
        /// starting state, which is `.paused` throughout and
        /// produces no such transition). A marked pause vetoes
        /// the seek completion's play() — user intent wins.
        private var userPausedDuringSeek = false
        /// Whether timeControlStatus has left `.paused` at all
        /// since the current resume seek started; the witness
        /// that distinguishes a user pause transition from the
        /// seek's own dead pause (see userPausedDuringSeek).
        private var resumeSeekSawNonPaused = false
        private var firstFrameReported = false
        /// L-T04 probe: P11 logs the FIRST item-status callback
        /// only — the flag flips once and never affects flow.
        private var statusFirstLogged = false
        private var failed = false
        private var ended = false

        // MARK: Start

        func start(controller: AVPlayerViewController, stream: StreamInfo,
                   attemptID: Int, session: TVPlayerSession, useProxy: Bool) {
            self.controller = controller
            self.stream = stream
            self.attemptID = attemptID
            self.session = session

            guard let url = stream.streamURL else {
                session.itemFailed(attempt: attemptID, errorLabel: "player#invalid-url")
                return
            }

            let asset: AVURLAsset
            if useProxy, let proxied = HLSProxyLoader.proxiedURL(for: url) {
                // The rescue route (§3.2): the loader fetches
                // playlist AND segments itself, with the
                // stream's headers on every request.
                let loader = HLSProxyLoader(headers: stream.headers)
                proxyLoader = loader
                let proxiedAsset = AVURLAsset(url: proxied)
                proxiedAsset.resourceLoader.setDelegate(
                    loader, queue: DispatchQueue(label: "jtv.hlsproxy.delegate"))
                asset = proxiedAsset
            } else {
                var headers = stream.headers
                if headers["User-Agent"] == nil {
                    headers["User-Agent"] = Net.desktopUA
                }
                asset = AVURLAsset(url: url,
                                   options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            }

            // L-T04 probe breadcrumb P9: the asset exists —
            // proxyLoader is non-nil exactly when the proxy
            // fork built it.
            DiagLog.log("player", "asset.built route=\(proxyLoader != nil ? "proxy" : "plain")")
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            self.player = player
            controller.player = player
            controller.showsPlaybackControls = true

            observe(item: item, player: player)
            buildTransportMenu()
            observeProviderRows()
            // L-T04 probe breadcrumb P10a: the transport menu
            // was built inside start() (shortlist row 3's site).
            DiagLog.log("player", "menu.built")
            session.registerHost(
                attempt: attemptID,
                positionProvider: { [weak self] in
                    guard let self, let player = self.player else { return 0 }
                    let seconds = player.currentTime().seconds
                    return seconds.isFinite ? seconds : 0
                },
                subtitleApplier: { [weak self] choice in
                    // A live panel pick: drives the surface
                    // and returns what actually took effect;
                    // the session stores that as the
                    // effective choice (selectSubtitle).
                    self?.applyChoiceToItem(choice) ?? choice
                })
            armWatchdog()
            // A fast item may already be ready before the
            // observers settle (the JoeTV warmed-item check).
            if item.status == .readyToPlay {
                handleReady(item: item)
            }
            // L-T04 probe breadcrumb P10b: start() completed.
            DiagLog.log("player", "start.done")
        }

        // MARK: Observers (FL-202/FL-206)

        private func observe(item: AVPlayerItem, player: AVPlayer) {
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let item = self.player?.currentItem else { return }
                    self.handleItemStatus(item)
                }
            }
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.handleTimeControlStatus()
                }
            }
            periodicObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                // queue: .main — the handler provably runs on
                // the main actor (the house pattern, iOS
                // PlayerView).
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Gate fix pass 2 (C3): drain a deferred
                    // transport-menu rebuild as soon as the
                    // menu presentation is gone.
                    self.applyPendingMenuRebuild()
                    let position = time.seconds.isFinite ? time.seconds : 0
                    let duration = self.player?.currentItem?.duration.seconds ?? 0
                    self.session?.notePosition(attempt: self.attemptID,
                                               position: position,
                                               duration: duration.isFinite ? duration : 0)
                }
            }
            let center = NotificationCenter.default
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.ended else { return }
                    self.ended = true
                    self.session?.itemEnded(attempt: self.attemptID)
                }
            })
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] note in
                // Only the Sendable label crosses the hop
                // (Swift 6) — JoeTV's proven shape at this
                // site: domain#code is all failLoad needs.
                let nsError = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                let label = nsError.map { "\($0.domain)#\($0.code)" }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.failLoad(errorLabel: label ?? "player#play-to-end-failed")
                }
            })
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // A stall is evidence, not a verdict: the
                    // waiting-state watchdog judges it (§3.3) —
                    // and, since L-T21, the stall fast path
                    // arms its short grace on it (noteStall).
                    DiagLog.log("player", "stall attempt=\(self?.attemptID ?? -1) surface=av")
                    self?.noteStall()
                }
            })
            notificationTokens.append(center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = raw == AVAudioSession.InterruptionType.began.rawValue
                Task { @MainActor [weak self] in
                    guard let self, began else { return }
                    self.player?.pause()
                    DiagLog.log("player", "interruption attempt=\(self.attemptID) surface=av")
                }
            })
        }

        /// Symmetric teardown for every registration above
        /// (FL-202), plus the watchdog (FL-210: dismantle is
        /// one of its two cancellation paths — the session's
        /// own stop is the other, via the attempt guards).
        func invalidate() {
            // Gate fix pass 2 (F-B3-R3-1): validity cleared
            // FIRST — a sink delivery already enqueued on the
            // MainActor before the cancel below must find the
            // host invalid and no-op (see observeProviderRows).
            hostValid = false
            providerRowsCancellable?.cancel()
            providerRowsCancellable = nil
            // Gate fix pass 3 (C-R4-2): the menu-rebuild
            // drain timer is torn down with the other
            // registrations. hostValid was cleared FIRST
            // above, so even a firing already queued on the
            // main run loop no-ops — no drain after
            // invalidate.
            stopMenuRebuildTimer()
            watchdogTask?.cancel()
            watchdogTask = nil
            cancelStallTask()
            statusObservation?.invalidate()
            statusObservation = nil
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            if let periodicObserver, let player {
                player.removeTimeObserver(periodicObserver)
            }
            periodicObserver = nil
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
            player?.pause()
            session?.deregisterHost(attempt: attemptID)
            // Gate fix pass 2 (F-B3-R3-1): nil the references
            // the menu rebuild uses, so an already-enqueued
            // sink delivery that somehow passes the validity
            // flag still finds nothing to rebuild with. Done
            // LAST: every step above still needs the session.
            pendingMenuRebuild = false
            session = nil
            controller = nil
        }

        // MARK: Ready / first frame / failure

        private func handleItemStatus(_ item: AVPlayerItem) {
            // L-T04 probe breadcrumb P11: first status callback.
            if !statusFirstLogged {
                statusFirstLogged = true
                let token: String
                switch item.status {
                case .readyToPlay: token = "ready"
                case .failed: token = "failed"
                default: token = "unknown"
                }
                DiagLog.log("player", "item.status.first value=\(token)")
            }
            guard !failed else { return }
            switch item.status {
            case .readyToPlay:
                handleReady(item: item)
            case .failed:
                if let error = item.error {
                    failLoad(error: error)
                } else {
                    failLoad(errorLabel: "player#item-failed")
                }
            default:
                break
            }
        }

        /// The gated start (FL-201): subtitles first (the
        /// default/manual application, §4.4), then the shared
        /// resume rule (§5.2) — seek once if the recorded
        /// target > 5 s, zero tolerance, play only on a
        /// finished seek; otherwise play directly.
        private func handleReady(item: AVPlayerItem) {
            guard !readyHandled, !failed else { return }
            readyHandled = true
            // L-T04 probe breadcrumb P12a: ready handling began.
            DiagLog.log("player", "ready.handled")
            guard let session, let player else { return }
            let target = session.itemReady(attempt: attemptID)
            applySubtitleDirective(item: item)
            buildTransportMenu()
            if TVResumeRule.shouldSeek(target) {
                resumeSeekAwaitingPlayback = true
                userPausedDuringSeek = false
                resumeSeekSawNonPaused = false
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Gate fix (R4 Lens B, F-B-R4-1): a seek
                        // completing after invalidate() must not
                        // note the session or call play() on the
                        // dismantled, display-less player.
                        guard self.hostValid else { return }
                        self.session?.noteResumeSeek(attempt: self.attemptID,
                                                     target: target, finished: finished)
                        // The window ends HERE, whatever the
                        // result: clear the flag (and the
                        // window's intent marks) in the
                        // completion itself, not on the road
                        // to first .playing.
                        let userPaused = self.userPausedDuringSeek
                        self.resumeSeekAwaitingPlayback = false
                        self.userPausedDuringSeek = false
                        self.resumeSeekSawNonPaused = false
                        // Play only on a finished seek
                        // (FL-204) AND only when no user
                        // pause intervened during the window.
                        if finished, !userPaused {
                            // L-T04 probe breadcrumb P12b.
                            DiagLog.log("player", "play.called")
                            self.player?.play()
                        }
                    }
                }
            } else {
                // L-T04 probe breadcrumb P12b.
                DiagLog.log("player", "play.called")
                player.play()
            }
            handleTimeControlStatus()
        }

        private func handleTimeControlStatus() {
            guard let player else { return }
            // L-T21: playback resuming inside the grace
            // window disarms the stall fast path — the stall
            // recovered on its own and is not a failure. A
            // user pause disarms it too: paused playback is
            // never failed for stalling.
            if player.timeControlStatus == .playing
                || player.timeControlStatus == .paused {
                cancelStallTask()
            }
            // User-intent tracking for the resume-seek window
            // (Fix 2): a transition INTO .paused after the
            // status had left .paused since the seek started
            // is a user pause; the seek's own state never
            // leaves .paused, so it can never mark itself.
            if resumeSeekAwaitingPlayback {
                switch player.timeControlStatus {
                case .playing, .waitingToPlayAtSpecifiedRate:
                    resumeSeekSawNonPaused = true
                case .paused:
                    if resumeSeekSawNonPaused {
                        userPausedDuringSeek = true
                    }
                @unknown default:
                    break
                }
            }
            guard readyHandled, !firstFrameReported, !failed else { return }
            // §6: AV first frame = first .playing with the
            // item .readyToPlay. (The resume-seek flag is NOT
            // cleared here — the seek completion clears it.)
            if player.timeControlStatus == .playing,
               player.currentItem?.status == .readyToPlay {
                firstFrameReported = true
                session?.noteFirstFrame(attempt: attemptID, surface: "av", via: nil)
            }
        }

        private func failLoad(error: Error) {
            failLoad(errorLabel: TVPlayerSession.errorLabel(error))
        }

        private func failLoad(errorLabel: String) {
            guard !failed else { return }
            failed = true
            watchdogTask?.cancel()
            watchdogTask = nil
            cancelStallTask()
            player?.pause()
            session?.itemFailed(attempt: attemptID, errorLabel: errorLabel)
        }

        // MARK: Stall fast path (L-T21)

        /// A stall AFTER first frame means the host stopped
        /// feeding a playing item (log_9: hentaihub stalled
        /// ~8 s into playback and never recovered; the 30 s
        /// watchdog was the only reaction, so the viewer sat
        /// on a frozen frame for ~31 s). Arm a short grace:
        /// if the player is still waiting when it expires,
        /// take the watchdog's exact exit — fail the attempt
        /// through session.watchdogFailed, so the session's
        /// existing retry (re-resolve + resume seek) runs
        /// unchanged, only sooner. Pre-first-frame stalls
        /// stay with the watchdog alone: they are load waits,
        /// and the load path already has its own budget. A
        /// user pause (.paused) never arms the grace.
        private func noteStall() {
            guard hostValid, firstFrameReported, !failed, !ended,
                  let player, player.timeControlStatus != .paused else { return }
            stallTask?.cancel()
            let grace = stallGraceSeconds
            stallTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(grace))
                guard let self, !Task.isCancelled else { return }
                self.stallGraceExpired()
            }
        }

        private func stallGraceExpired() {
            stallTask = nil
            guard hostValid, !failed, !ended, let player,
                  player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            DiagLog.log("player", "stall.fastfail attempt=\(attemptID) surface=av waited=\(stallGraceSeconds)")
            failed = true
            watchdogTask?.cancel()
            watchdogTask = nil
            stallTask = nil
            player.pause()
            session?.watchdogFailed(attempt: attemptID, surface: "av", waitedSeconds: stallGraceSeconds)
        }

        private func cancelStallTask() {
            stallTask?.cancel()
            stallTask = nil
        }

        // MARK: Watchdog (FL-042)

        /// While the player waits to play at the specified
        /// rate (or the item has not readied at all, or a
        /// resume seek is still in flight) the wait clock
        /// runs; ~30 s of CONTINUOUS waiting fails the
        /// attempt. A user pause (.paused — including one
        /// made during the seek window, once that seek has
        /// completed and its flag has cleared) and actual
        /// playing both hold the clock open. The
        /// watchdog failing the attempt — never an auto-play
        /// after an unfinished seek — is the recovery
        /// (FL-204).
        private func armWatchdog() {
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    self.watchdogTick()
                }
            }
        }

        private func watchdogTick() {
            guard !failed, !ended, let player else { return }
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                || (!readyHandled && player.currentItem?.status == .unknown)
                || (resumeSeekAwaitingPlayback && player.timeControlStatus != .playing)
            if waiting {
                if waitingSince == nil { waitingSince = Date() }
                if let since = waitingSince, Date().timeIntervalSince(since) >= 30 {
                    let waited = Int(Date().timeIntervalSince(since))
                    failed = true
                    watchdogTask?.cancel()
                    watchdogTask = nil
                    cancelStallTask()
                    player.pause()
                    session?.watchdogFailed(attempt: attemptID, surface: "av", waitedSeconds: waited)
                }
            } else {
                waitingSince = nil
            }
        }

        /// Gate fix pass (F-B3/C-F2): rebuild the transport
        /// menu when — and only when — the session's provider
        /// rows change (the probe publishing its filtered,
        /// corrected rows is the case that matters: seeded
        /// .checking rows, including not-configured providers,
        /// must not linger as the menu's permanent state).
        private func observeProviderRows() {
            guard let session else { return }
            providerRowsCancellable = session.$providerRows.sink { [weak self] rows in
                Task { @MainActor [weak self] in
                    // Gate fix pass 2 (F-B3-R3-1): a delivery
                    // enqueued before invalidate() cancelled
                    // the cancellable must not rebuild the menu
                    // on the dismantled host.
                    guard let self, self.hostValid else { return }
                    guard rows != self.lastMenuProviderRows else { return }
                    // Gate fix pass 2 (C3): never reassign the
                    // menu items under a presented transport
                    // menu — defer and let the periodic
                    // observer apply the rebuild once the
                    // presentation is gone.
                    if self.transportMenuPresented {
                        self.pendingMenuRebuild = true
                        DiagLog.log("player", "menu.rebuild deferred reason=presented")
                        // Gate fix pass 3 (C-R4-2): arm the
                        // wall-clock drain — the periodic
                        // observer alone starves while paused.
                        self.startMenuRebuildTimerIfNeeded()
                        return
                    }
                    self.buildTransportMenu()
                }
            }
        }

        /// Gate fix pass 2 (C3): the strongest presentation
        /// signal available for AVKit's transport menu — see
        /// the pendingMenuRebuild declaration for the stated
        /// limit of this proxy.
        private var transportMenuPresented: Bool {
            controller?.presentedViewController != nil
        }

        /// Gate fix pass 2 (C3): apply a deferred menu rebuild
        /// once the transport menu is no longer presented.
        /// Driven by the periodic observer (0.25 s, main
        /// queue, host-lifetime), so a deferred rebuild lands
        /// within a quarter second of dismissal WHILE TIME
        /// ADVANCES; gate fix pass 3 (C-R4-2) adds the
        /// wall-clock timer drain below for the paused state,
        /// where the time observer does not fire. It is never
        /// applied early and never dropped while the host
        /// lives.
        private func applyPendingMenuRebuild() {
            guard hostValid, pendingMenuRebuild, !transportMenuPresented else { return }
            pendingMenuRebuild = false
            // Gate fix pass 3 (C-R4-2): the flag has drained,
            // whichever driver drained it — the wall-clock
            // timer's work is done.
            stopMenuRebuildTimer()
            // buildTransportMenu re-reads the LIVE rows, so a
            // deferral window that saw several publishes still
            // builds exactly one, current menu.
            buildTransportMenu()
            DiagLog.log("player", "menu.rebuild applied after dismissal")
        }

        /// Gate fix pass 3 (C-R4-2): arm the bounded
        /// wall-clock drain for a deferred menu rebuild. The
        /// timer is scheduled from the coordinator's MainActor
        /// context onto the main run loop, so its firings land
        /// on the main actor exactly as the periodic
        /// observer's .main-queue callbacks do (the house
        /// MainActor.assumeIsolated pattern at that site). It
        /// is NOT an unstructured task: it is a stored token
        /// torn down in invalidate() alongside every other
        /// registration, and hostValid (cleared FIRST there)
        /// makes any already-queued firing a no-op — no drain
        /// can land after invalidate.
        private func startMenuRebuildTimerIfNeeded() {
            guard menuRebuildTimer == nil else { return }
            DiagLog.log("player", "menu.rebuild timer armed interval=0.5")
            menuRebuildTimer = Timer.scheduledTimer(
                withTimeInterval: 0.5, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.hostValid else { return }
                    // The flag drained through the periodic
                    // observer (or never re-armed): stop.
                    guard self.pendingMenuRebuild else {
                        self.stopMenuRebuildTimer()
                        return
                    }
                    self.applyPendingMenuRebuild()
                }
            }
        }

        private func stopMenuRebuildTimer() {
            menuRebuildTimer?.invalidate()
            menuRebuildTimer = nil
        }

        // MARK: Transport menu (§3.3)

        /// Đổi nguồn (submenu of the session's switch targets,
        /// the current one checked) + Phụ đề (opens the shared
        /// panel) — JoeTV's AV-surface pattern. Rebuilt at
        /// ready so the check mark is never stale. Picking a
        /// source captures the LIVE playhead synchronously in
        /// the action, before anything moves (FL-041).
        private func buildTransportMenu() {
            guard let controller, let session else { return }
            var children: [UIMenuElement] = []
            // A-8 (1.3.9): Đổi nguồn is its own TOP-LEVEL
            // transport item, no longer nested inside the
            // custom menu — `topLevel` collects the bar's
            // custom items in order.
            var topLevel: [UIMenuElement] = []
            let targets = session.switchTargets
            // L-T13 (1.3.1): the Đổi nguồn submenu now also
            // carries the PROVIDER rows (same hash, chosen
            // debrid provider + live cache state) next to the
            // episode-variant rows — it appears when EITHER
            // kind has a switchable row, so a single-variant
            // torrent title is no longer starved of the menu.
            let providerRows = session.providerRows
            if targets.count > 1 || providerRows.count > 1 {
                let currentID = session.currentRequest.episode.id
                var switchChildren: [UIMenuElement] = []
                if targets.count > 1 {
                    for episode in targets {
                        switchChildren.append(UIAction(
                            title: episode.name,
                            state: episode.id == currentID ? .on : .off) { [weak self] _ in
                            guard let self else { return }
                            let now = self.player?.currentTime().seconds ?? 0
                            self.session?.switchSource(
                                to: episode,
                                capturedPosition: (now.isFinite && now > 0) ? now : nil)
                        })
                    }
                }
                for providerRow in providerRows {
                    switchChildren.append(UIAction(
                        title: providerRow.title,
                        // Gate fix pass (C-F4): a .checking row
                        // is information, not a command — it is
                        // disabled until its probe verdict lands
                        // (the rebuild above then re-enables it).
                        attributes: providerRow.state == .checking ? [.disabled] : [],
                        state: session.forcedProvider == providerRow.provider ? .on : .off) { [weak self] _ in
                        guard let self else { return }
                        let now = self.player?.currentTime().seconds ?? 0
                        self.session?.switchProvider(
                            to: providerRow.provider,
                            capturedPosition: (now.isFinite && now > 0) ? now : nil)
                    })
                }
                // §1A (1.3.6): the menu title carries the
                // PLAYING plugin's name once (rows are episode
                // names and cannot).
                let playingName = session.playingPluginName
                let switchMenu = UIMenu(
                    title: playingName.isEmpty ? "Đổi nguồn" : "Đổi nguồn · \(playingName)",
                    image: UIImage(systemName: "arrow.triangle.2.circlepath"),
                    children: switchChildren)
                topLevel.append(switchMenu)
            }
            // L-T13 §5.0 breadcrumb: menu contents are now
            // countable from the log (items = the top-level
            // custom items, switch menu included when present).
            DiagLog.log("player", "menu.built items=\(topLevel.count + 1) switchTargets=\(targets.count) providers=\(providerRows.count)")
            // Gate fix pass (F-B3/C-F2): remember exactly which
            // provider rows this menu was built from — the
            // observation above rebuilds only on a real change
            // against this snapshot.
            lastMenuProviderRows = providerRows
            children.append(UIAction(
                title: "Phụ đề",
                image: UIImage(systemName: "captions.bubble")
            ) { [weak self] _ in
                self?.session?.presentedPanel = .subtitles
            })
            // B-3 (1.3.9, owner ruling 2026-11-23): the custom
            // menu's label is functional now, no longer the
            // app's camouflage name. Design-pass ruling
            // (D-4): after the A-8 split this menu holds
            // ONLY the subtitle item, so it is titled
            // "Phụ đề" — the name must describe its
            // contents; B-3's findability goal is carried
            // by the top-level Đổi nguồn item above.
            topLevel.append(UIMenu(title: "Phụ đề", children: children))
            controller.transportBarCustomMenuItems = topLevel
        }

        // MARK: Subtitles (§4.2/§4.4)

        private func legibleGroup(for item: AVPlayerItem) -> AVMediaSelectionGroup? {
            item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
        }

        private func applySubtitleDirective(item: AVPlayerItem) {
            guard let session else { return }
            // Publish the embedded catalogue for the panel.
            let group = legibleGroup(for: item)
            let options = group?.options ?? []
            session.updateCatalog(attempt: attemptID, embedded: options.map {
                TVEmbeddedTrackRef(key: Self.key(for: $0),
                                   displayName: $0.displayName,
                                   languageHint: $0.extendedLanguageTag ?? "")
            })
            switch session.subtitleDirective() {
            case .applyManual(let choice):
                applyManualChoice(choice, item: item)
            case .applyDefault:
                applySubtitleDefault(item: item, options: options)
            }
        }

        /// A selection applied to the live item. Embedded
        /// picks select the group option (AVFoundation
        /// renders); file picks clear the group and hand the
        /// track to the cue overlay; Off clears both (§4.2).
        /// The two renderers are mutually exclusive by
        /// construction. Returns what actually took effect.
        @discardableResult
        func applyChoiceToItem(_ choice: TVSubtitleChoice) -> TVSubtitleChoice {
            guard let item = player?.currentItem else { return .off }
            return applyChoice(choice, to: item)
        }

        private func applyChoice(_ choice: TVSubtitleChoice, to item: AVPlayerItem) -> TVSubtitleChoice {
            let group = legibleGroup(for: item)
            switch choice {
            case .off:
                if let group { item.select(nil, in: group) }
                return .off
            case .embedded(let key, let displayName):
                // Resolve through the shared cross-surface
                // order (§4.4: exact key → display name →
                // language): a pick stored on the KS surface
                // carries a KS key that matches nothing here.
                // Returns the track ACTUALLY selected (in this
                // surface's key space), or .off when no
                // candidate matches at all.
                if let group {
                    let catalog = group.options.map {
                        TVEmbeddedTrackRef(key: Self.key(for: $0),
                                           displayName: $0.displayName,
                                           languageHint: $0.extendedLanguageTag ?? "")
                    }
                    if let resolved = TVEmbeddedPickResolver.resolve(key: key, displayName: displayName, in: catalog),
                       let option = group.options.first(where: { Self.key(for: $0) == resolved.key }) {
                        item.select(option, in: group)
                        return .embedded(key: resolved.key, displayName: resolved.displayName)
                    }
                }
                // Unresolved: ENFORCE the reported .off, as
                // every sibling branch does — a fresh item
                // can carry an automatic legible selection,
                // and "off" must mean nothing renders.
                if let group { item.select(nil, in: group) }
                return .off
            case .file(let track):
                if let group { item.select(nil, in: group) }
                // Validate against THIS attempt's sidecar
                // list, exactly as the KS surface does (§4.4):
                // a pick stored on a previous item that is
                // absent here resolves to .off — never a
                // claimed "file" that would render the
                // previous item's cues over this content.
                if let stream, stream.subtitles.contains(track) {
                    return choice
                }
                return .off
            }
        }

        /// The directive's manual branch at ready: apply the
        /// session's stored pick and report the attempt's §6
        /// subs line (the live panel-pick path deliberately
        /// does not re-log it).
        private func applyManualChoice(_ choice: TVSubtitleChoice, item: AVPlayerItem) {
            guard let session else { return }
            let effective = applyChoice(choice, to: item)
            let applied: String
            var overlayFile: SubtitleTrack?
            switch effective {
            case .off: applied = "off"
            case .embedded: applied = "track"
            case .file(let track):
                applied = "file"
                overlayFile = track
            }
            session.noteSubtitlesApplied(attempt: attemptID,
                                         embedded: legibleGroup(for: item)?.options.count ?? 0,
                                         files: stream?.subtitles.count ?? 0,
                                         applied: applied,
                                         effective: effective,
                                         overlayFile: overlayFile)
        }

        /// The default rule (§4.4), applied ONCE per item:
        /// Vietnamese if available, else English, in the ONE
        /// shared ranking (TVSubtitleDefaultRanking: file-VI
        /// → embedded-VI → embedded-EN → file-EN). Every
        /// branch ENFORCES what it reports, exactly as
        /// applyChoice does: file winners and the no-slot
        /// case clear the legible group (a fresh item can
        /// carry an automatic selection — §4.2's mutual
        /// exclusion and the honesty of "default-none" both
        /// depend on it).
        private func applySubtitleDefault(item: AVPlayerItem, options: [AVMediaSelectionOption]) {
            guard let session, let stream else { return }
            let group = legibleGroup(for: item)
            var applied = "default-none"
            var effective: TVSubtitleChoice = .off
            var overlayFile: SubtitleTrack?
            let viFile = stream.subtitles.first(where: {
                TVSubtitleLanguage.isVietnamese(name: $0.label, code: $0.lang)
            })
            let enFile = stream.subtitles.first(where: {
                TVSubtitleLanguage.isEnglish(name: $0.label, code: $0.lang)
            })
            let vi = options.first(where: {
                TVSubtitleLanguage.isVietnamese(name: $0.displayName,
                                                code: $0.extendedLanguageTag ?? $0.locale?.identifier ?? "")
            })
            let en = options.first(where: {
                TVSubtitleLanguage.isEnglish(name: $0.displayName,
                                              code: $0.extendedLanguageTag ?? $0.locale?.identifier ?? "")
            })
            switch TVSubtitleDefaultRanking.winningSlot(
                hasFileVietnamese: viFile != nil,
                hasEmbeddedVietnamese: vi != nil,
                hasEmbeddedEnglish: en != nil,
                hasFileEnglish: enFile != nil) {
            case .some(.fileVietnamese):
                if let viFile {
                    // The overlay renders the file; the
                    // legible group must render NOTHING
                    // (§4.2 mutual exclusion) — a fresh item
                    // can carry an automatic selection.
                    group.map { item.select(nil, in: $0) }
                    applied = "default-vi"
                    effective = .file(viFile)
                    overlayFile = viFile
                }
            case .some(.embeddedVietnamese):
                if let vi {
                    group.map { item.select(vi, in: $0) }
                    applied = "default-vi"
                    effective = .embedded(key: Self.key(for: vi), displayName: vi.displayName)
                }
            case .some(.embeddedEnglish):
                if let en {
                    group.map { item.select(en, in: $0) }
                    applied = "default-en"
                    effective = .embedded(key: Self.key(for: en), displayName: en.displayName)
                }
            case .some(.fileEnglish):
                if let enFile {
                    group.map { item.select(nil, in: $0) }
                    applied = "default-en"
                    effective = .file(enFile)
                    overlayFile = enFile
                }
            case .none:
                // "default-none" must be enforced, not
                // just reported: clear any automatic
                // legible selection so nothing renders,
                // exactly as the manual path enforces .off.
                group.map { item.select(nil, in: $0) }
            }
            session.noteSubtitlesApplied(attempt: attemptID,
                                         embedded: options.count,
                                         files: stream.subtitles.count,
                                         applied: applied,
                                         effective: effective,
                                         overlayFile: overlayFile)
        }

        // MARK: Track matching (iOS D-1, verbatim rule)

        static func key(for option: AVMediaSelectionOption) -> String {
            (option.extendedLanguageTag ?? option.locale?.identifier ?? "") + "|" + option.displayName
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // L-T04 probe breadcrumb P8: the AV host is being made.
        DiagLog.log("player", "host.make surface=av")
        let controller = AVPlayerViewController()
        context.coordinator.start(controller: controller, stream: stream,
                                  attemptID: attemptID, session: session, useProxy: useProxy)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController,
                                          coordinator: Coordinator) {
        coordinator.invalidate()
        controller.player = nil
    }
}
