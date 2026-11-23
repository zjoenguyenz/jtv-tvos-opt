import AVFoundation
import SwiftUI

/// JTV for tvOS — Phase 1 shell entry point.
///
/// Root logic (survey §4, the PIN gate spec):
/// • If a PIN is configured in the build
///   (`BundledSecrets.pinConfigured`) and the session is locked,
///   ONLY the gate exists — the shell view is not instantiated
///   at all while locked, so no content view can be created,
///   rendered or snapshotted before unlock.
/// • If no PIN is configured (`pinConfigured == false` — the
///   secrets-absent build state) there is no gate: the shell
///   shows directly.
/// • The moment the app leaves the active state a cover
///   replaces content, so the tvOS app-switcher snapshot never
///   shows content; when the app reaches the background the
///   session locks immediately (L-T28, owner ruling
///   2026-11-22): on return the gate is shown and waits for
///   the code — no flash-and-admit. A merely transient
///   inactive (Control Center, Siri) covers without locking,
///   so an interruption never kills playback (gate fix,
///   Round 1, Lens B F-B3). The 15-minute idle rule (see
///   PinSession) remains as the in-foreground backup layer.
///
/// tvOS is landscape-native: there is deliberately NO
/// orientation machinery here (the iOS app's orientation lock
/// is an iOS-only artefact and is not ported).
@main
struct JTVTVApp: App {
    @StateObject private var pinSession = PinSession()

    init() {
        // Playback audio session — the tvOS equivalent of the
        // iOS app's AudioSession.swift (which is NOT ported).
        // Same category/mode values and the same discipline as
        // the iOS helper: each step attempted independently,
        // a failure logged by error kind only, never a payload.
        do {
            try AVAudioSession.sharedInstance()
                .setCategory(.playback, mode: .moviePlayback)
        } catch {
            DiagLog.log("audio", "configure failed step=category kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            DiagLog.log("audio", "configure failed step=activate kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        DiagLog.log("app", "launch pinConfigured=\(BundledSecrets.pinConfigured ? "yes" : "no")")
    }

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .environmentObject(pinSession)
                .preferredColorScheme(.dark)
        }
    }
}

/// Chooses between cover, gate and shell — and ONLY that. The
/// three branches are mutually exclusive view constructions:
/// while the gate (or cover) branch is taken, `TVRootView` is
/// never built.
private struct RootContainerView: View {
    @EnvironmentObject private var session: PinSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.isCovered {
                CoverView()
            } else if session.isUnlocked {
                TVRootView()
            } else {
                PinGateView()
            }
        }
        .onAppear {
            session.startIdleMonitoring()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                session.appDidBecomeActive()
            case .inactive:
                // Cover only — a transient interruption must
                // not lock (Lens B F-B3).
                session.appWillResignActive()
            case .background:
                // Truly left the foreground: lock (L-T28).
                session.appDidEnterBackground()
            @unknown default:
                break
            }
        }
    }
}

/// The app-switcher cover: a plain black screen carrying only
/// the disguised display name and a lock glyph — no catalogue
/// art, no titles, nothing that hints at the app's content
/// (owner's disguised-identity ruling: the app presents as
/// "Media Service").
private struct CoverView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Media Service")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
