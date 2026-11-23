import CryptoKit
import Foundation
import SwiftUI

// MARK: - PIN verification (survey §4 + owner ruling D-5)
//
// The app-lock code itself NEVER appears in this file or in the
// build as plain text. The build carries only
// `BundledSecrets.pinHash` — the SHA-256 hex digest of the code's
// digits — injected from the APP_LOCK_PIN secret at build time.
// Verification hashes the entered digits and compares digests.
//
// Owner ruling D-5 (2026-11-20, final): the code IS changeable
// in-app. A change stores the NEW code's hash in UserDefaults
// under `jtvtv_pin_hash_override`; the effective hash is the
// override when present, otherwise the bundled hash. A
// delete-and-reinstall wipes UserDefaults, so the bundled code
// becomes the factory code again automatically.

enum PinVerifier {
    /// UserDefaults key holding the in-app-changed code's hash.
    static let overrideKey = "jtvtv_pin_hash_override"

    /// The hash a code is checked against right now: the
    /// on-device override wins, the bundled hash is the factory
    /// fallback.
    static var effectiveHash: String {
        let override = UserDefaults.standard
            .string(forKey: overrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? BundledSecrets.pinHash : override
    }

    /// SHA-256 of the code's UTF-8 digits, lower-case hex — the
    /// exact shape `BundledSecrets.pinHash` is generated in.
    static func hash(of code: String) -> String {
        SHA256.hash(data: Data(code.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func verify(_ code: String) -> Bool {
        let expected = effectiveHash
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !expected.isEmpty, !code.isEmpty else { return false }
        return hash(of: code) == expected
    }

    /// Stores a new code (as its hash only — the digits are
    /// never persisted anywhere).
    static func storeNewCode(_ code: String) {
        UserDefaults.standard.set(hash(of: code), forKey: overrideKey)
    }
}

// MARK: - PinSession (idle re-lock, survey §4)
//
// Shared lock/activity state for the whole shell.
//
// • `lastActivity` is refreshed by every remote interaction the
//   shell can observe (gate pad presses, shell appearances, tab
//   changes, pushed-screen appearances) and continuously by
//   playback: while `playbackActive` is true a 60 s refresher
//   keeps touching the clock, so a two-hour film never falls
//   back to the gate mid-watch. Later phases call `touch()` /
//   `setPlaybackActive(_:)` from their own surfaces.
/// • Re-lock rules (owner-set): (1) ENTERING THE BACKGROUND
///   locks IMMEDIATELY (L-T28, owner ruling 2026-11-22: this
///   is an 18+ app — backing out to Home and returning must
///   meet the gate again, never a panel flash followed by
///   silent admission, which is what the idle-only rule
///   produced). The lock is keyed to .background, NOT to
///   .inactive (gate fix, Round 1, Lens B F-B3): a transient
///   inactive — Control Center, Siri, a switcher peek —
///   never reaches .background, so it covers but does NOT
///   lock and does NOT tear down playback; an exit to Home
///   always passes through .background, where the lock
///   engages while the cover is already up, so the return
///   still meets a locked gate with no flash. (2) the
///   15-minute idle rule below remains as the in-foreground
///   backup: on a repeating 30 s check, if
///   now − lastActivity ≥ 15 min and nothing is playing, the
///   session locks. Cold start is always locked (the initial
///   value below), regardless of the clock.
/// • Snapshot cover: `isCovered` flips the moment the app
///   leaves the active state, so the tvOS app-switcher
///   snapshot shows the cover, never content — and because
///   the cover rises at .inactive, before the .background
///   lock, no frame of any return can show the shell before
///   the gate.
/// • When no PIN is configured in the build
///   (`BundledSecrets.pinConfigured == false` — the
///   secrets-absent build state) the session is permanently
///   unlocked and every lock path is a no-op.
///
/// Swift 6 / register R-02: the timers are lightweight
/// main-actor Tasks (30 s / 60 s sleeps) — no Timer, no NSLock,
/// no watchdog on any executor the UI waits on. Both loops hold
/// only a weak reference and end themselves when the session is
/// gone or when cancelled.
@MainActor
final class PinSession: ObservableObject {
    /// Owner-set idle limit: 15 minutes.
    static let idleLimit: TimeInterval = 15 * 60

    @Published private(set) var isUnlocked: Bool
    @Published private(set) var isCovered = false
    @Published private(set) var lastActivity: Date
    @Published private(set) var playbackActive = false

    private var idleTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?

    init() {
        // Cold start is always gated when a PIN is configured.
        isUnlocked = !BundledSecrets.pinConfigured
        lastActivity = Date()
    }

    // MARK: Activity

    /// Records a remote interaction. Every button action in the
    /// gate and the shell calls this (directly or via
    /// `onAppear` hooks); later phases do the same.
    func touch() {
        lastActivity = Date()
    }

    /// Playback counts as activity (survey §4): while true, a
    /// 60 s refresher keeps `lastActivity` current so the idle
    /// rule can never fire mid-watch, and `evaluateIdle()`
    /// itself refuses to lock.
    func setPlaybackActive(_ active: Bool) {
        playbackActive = active
        touch()
        playbackTask?.cancel()
        playbackTask = nil
        guard active else { return }
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if self.playbackActive {
                    self.touch()
                } else {
                    return
                }
            }
        }
    }

    // MARK: Lock / unlock

    func unlock() {
        guard BundledSecrets.pinConfigured else {
            isUnlocked = true
            return
        }
        isUnlocked = true
        touch()
        DiagLog.log("gate", "pin accepted")
        startIdleMonitoring()
    }

    func lock(reason: String = "idle rule") {
        guard BundledSecrets.pinConfigured else { return }
        guard isUnlocked else { return }
        isUnlocked = false
        DiagLog.log("gate", "session locked (\(reason))")
    }

    // MARK: Idle rule

    /// Starts the repeating 30 s in-foreground idle check.
    /// Idempotent; also started by the app root on appear so the
    /// no-PIN build and the post-unlock state share one path.
    func startIdleMonitoring() {
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                self.evaluateIdle()
            }
        }
    }

    /// The 15-minute rule, applied verbatim: nothing playing
    /// and no interaction for ≥ 15 minutes → lock.
    func evaluateIdle() {
        guard BundledSecrets.pinConfigured, isUnlocked, !playbackActive
        else { return }
        if Date().timeIntervalSince(lastActivity) >= Self.idleLimit {
            lock()
        }
    }

    // MARK: Scene phase (driven by JTVTVApp's root container)

    /// The app is leaving the active state (.inactive):
    /// cover ONLY, so the snapshot tvOS takes can never show
    /// content. No lock here (gate fix, Round 1, Lens B
    /// F-B3): .inactive also fires for transient interruptions
    /// (Control Center, Siri, a switcher peek) that never
    /// leave the foreground — those must not lock the session
    /// or tear down playback. A real exit continues to
    /// .background, which locks (below).
    func appWillResignActive() {
        isCovered = true
    }

    /// The app has entered the background: it has truly LEFT
    /// the foreground (an exit to Home always lands here), so
    /// LOCK now (L-T28) — the cover is already up from the
    /// .inactive step, and the session locks while away, so
    /// the gate on return WAITS for the code; there is no
    /// flash-and-admit path.
    func appDidEnterBackground() {
        isCovered = true
        lock(reason: "left foreground")
    }

    /// Back in the foreground: drop the cover. A session that
    /// reached the background is already locked (the gate
    /// shows); a session returning from a transient inactive
    /// was never locked and simply resumes — with the idle
    /// rule applied before anything else renders.
    func appDidBecomeActive() {
        isCovered = false
        if playbackActive {
            touch()
        } else {
            evaluateIdle()
        }
    }
}

// MARK: - Shared pad pieces

/// The entered digits as dots — the digits themselves are never
/// rendered anywhere.
private struct PinDotsView: View {
    let count: Int
    var total: Int = 4

    var body: some View {
        HStack(spacing: 22) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < count ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 22, height: 22)
            }
        }
        .accessibilityLabel("\(count) số đã nhập")
    }
}

/// On-screen digit pad (0–9 + delete) built for the Siri Remote:
/// plain SwiftUI buttons, so focus is the OS's own rendering —
/// per the tvOS focus doctrine there is NO hand-drawn ring, no
/// custom button style and no `.card` slab anywhere in the gate.
private struct PinPadView: View {
    let onDigit: (Int) -> Void
    let onDelete: () -> Void

    @FocusState private var firstKeyFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            row([1, 2, 3], firstKey: true)
            row([4, 5, 6], firstKey: false)
            row([7, 8, 9], firstKey: false)
            HStack(spacing: 18) {
                // Empty slot keeps 0 centred under 8, remote-
                // geometry the owner already knows from tvOS.
                Color.clear
                    .frame(width: 120, height: 84)
                digitButton(0)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 34))
                        .frame(width: 120, height: 84)
                }
                .accessibilityLabel("Xoá")
            }
        }
        .defaultFocus($firstKeyFocused, true)
    }

    private func row(_ digits: [Int], firstKey: Bool) -> some View {
        HStack(spacing: 18) {
            ForEach(digits, id: \.self) { digit in
                if firstKey && digit == 1 {
                    digitButton(digit)
                        .focused($firstKeyFocused)
                } else {
                    digitButton(digit)
                }
            }
        }
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            onDigit(digit)
        } label: {
            Text("\(digit)")
                .font(.system(size: 40, weight: .semibold))
                .frame(width: 120, height: 84)
        }
        .accessibilityLabel("Số \(digit)")
    }
}

// MARK: - The gate

/// The app-lock gate (survey §4): the FIRST thing shown, with
/// nothing behind it. While this view is on screen the shell
/// view is not instantiated at all (see JTVTVApp's root
/// container), so no catalogue, poster or title can leak on any
/// path. Plain code screen only — no art, no titles from the
/// catalogue. 4 digits auto-submit; a wrong code clears the
/// dots and stays on the gate. No attempt limit, no lockout —
/// this is a household lock, not a security vault.
struct PinGateView: View {
    @EnvironmentObject private var session: PinSession
    @State private var entered = ""
    @State private var showError = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 44) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Nhập mã khóa")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                PinDotsView(count: entered.count)
                if showError {
                    Text("Mã chưa đúng — nhập lại")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                }
                PinPadView(onDigit: pressDigit, onDelete: pressDelete)
            }
            .padding(60)
        }
        .onAppear { session.touch() }
    }

    private func pressDigit(_ digit: Int) {
        session.touch()
        showError = false
        guard entered.count < 4 else { return }
        entered.append(String(digit))
        if entered.count == 4 {
            submit()
        }
    }

    private func pressDelete() {
        session.touch()
        showError = false
        if !entered.isEmpty { entered.removeLast() }
    }

    private func submit() {
        let code = entered
        entered = ""
        if PinVerifier.verify(code) {
            session.unlock()
        } else {
            showError = true
            DiagLog.log("gate", "pin rejected")
        }
    }
}

// MARK: - In-app PIN change (owner ruling D-5)

/// Settings → "Đổi mã khóa app": enter the CURRENT code first
/// (verified against the effective hash), then the new code,
/// then the new code again to confirm. Only the new code's
/// SHA-256 hash is stored (see PinVerifier). A mismatch at
/// confirm restarts the new-code step; a wrong current code
/// never advances the flow.
struct PinChangeView: View {
    @EnvironmentObject private var session: PinSession
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case verifyCurrent
        case enterNew
        case confirmNew
        case done
    }

    @State private var step: Step = .verifyCurrent
    @State private var entered = ""
    @State private var pendingNew = ""
    @State private var errorText: String?
    @FocusState private var doneFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 40) {
                Text(title)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                if step == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text("Từ lần mở app sau, dùng mã mới để mở khóa.")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                    Button("Xong") { dismiss() }
                        .font(.system(size: 28))
                        .focused($doneFocused)
                        .defaultFocus($doneFocused, true)
                } else {
                    PinDotsView(count: entered.count)
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 26))
                            .foregroundStyle(.orange)
                    }
                    PinPadView(onDigit: pressDigit, onDelete: pressDelete)
                }
            }
            .padding(60)
        }
        .navigationTitle("Đổi mã khóa app")
        .onAppear { session.touch() }
        // L-T31 (1.3.4): this cover owns its Menu press —
        // Menu abandons the flow and dismisses (mid-flow
        // nothing is written: the only store happens at the
        // confirm match, which lands on .done, where Menu is
        // the Xong button's act). An unhandled press would
        // fall to the system and exit the app, the L-T31
        // mechanism. The PIN GATE itself (PinGateView, the
        // root branch) is deliberately NOT given an arbiter:
        // it is not a pushed/presented surface, and Menu
        // there keeps the system's root behaviour.
        .onExitCommand {
            DiagLog.log("menu", "dismiss surface=pin-change")
            dismiss()
        }
    }

    private var title: String {
        switch step {
        case .verifyCurrent: return "Nhập mã hiện tại"
        case .enterNew: return "Nhập mã mới"
        case .confirmNew: return "Nhập lại mã mới"
        case .done: return "Đã đổi mã khóa"
        }
    }

    private func pressDigit(_ digit: Int) {
        session.touch()
        errorText = nil
        guard entered.count < 4 else { return }
        entered.append(String(digit))
        if entered.count == 4 {
            advance()
        }
    }

    private func pressDelete() {
        session.touch()
        errorText = nil
        if !entered.isEmpty { entered.removeLast() }
    }

    private func advance() {
        let code = entered
        entered = ""
        switch step {
        case .verifyCurrent:
            if PinVerifier.verify(code) {
                step = .enterNew
            } else {
                errorText = "Mã hiện tại chưa đúng — nhập lại"
                DiagLog.log("gate", "pin change rejected at current-code step")
            }
        case .enterNew:
            pendingNew = code
            step = .confirmNew
        case .confirmNew:
            if code == pendingNew {
                PinVerifier.storeNewCode(code)
                pendingNew = ""
                session.touch()
                step = .done
                DiagLog.log("gate", "pin changed in-app")
            } else {
                pendingNew = ""
                errorText = "Hai lần nhập chưa khớp — nhập mã mới lại"
                step = .enterNew
            }
        case .done:
            break
        }
    }
}
