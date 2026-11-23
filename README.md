# JTV for tvOS — "Media Service"

The tvOS version of JTV, the owner's media app. On the Apple TV
Home screen it appears as **"Media Service"**. It shares its core
(plugin engine, models, services, debrid resolver) with the iPhone
app; the tvOS-only SwiftUI shell (PIN gate, root, settings, log
export) lives in `JTVTV/`.

- The iOS app lives in the **jtv-ios** repo and is the core's
  source of truth — shared files are kept in sync with it (see
  `CORE-SYNC.md`).
- Display name "Media Service", bundle id
  `com.luun.nguyen.jtv.tvos`, target tvOS 27.0, Swift 6.

## Build

Manual dispatch only: GitHub Actions → **"Build JTVTV IPA"** →
Run workflow. The workflow generates the Xcode project with
XcodeGen from `project.yml`, builds unsigned on a macOS runner,
and uploads the IPA as an artifact named
`JTVTV-ipa-run<run number>-<date>`.

The IPA is **unsigned** — the owner signs it himself with
Signulous before installing on the Apple TV.

## Build secrets

Credentials are bundled into the build (Signulous installs
delete-and-reinstall, wiping in-app data, so nothing is typed
into the app). Set these as repo secrets — names only here,
never values:

| Secret | Feeds |
|---|---|
| `RD_TOKEN` | Real-Debrid token for the Torrent tab's debrid resolver |
| `TORBOX_TOKEN` | TorBox token for the debrid resolver |
| `PREMIUMIZE_TOKEN` | Premiumize API key for the debrid resolver |
| `MF_URL` | MediaFusion manifest link used as the built-in fallback source |
| `APP_LOCK_PIN` | App-lock gate code — only its SHA-256 hash is compiled in; the app opens on a code-entry screen |

Tokens are injected by the workflow as base64 string literals
into generated `JTV/BundledSecrets.swift` and
`JTV/DebridSecrets.swift` files and decoded at runtime; with
no secrets set, the build still compiles with nothing
configured.
