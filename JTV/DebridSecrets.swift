/// Baked-in debrid tokens for the Torrent tab.
///
/// The copy in the repo is EMPTY on purpose: tokens never live in
/// source control (jtv-source is public, and even the private app
/// repo is the wrong place for a credential). The CI build may
/// overwrite this file from repo secrets before compiling; when it
/// does not, the app falls back to the tokens the owner types once
/// in Settings (stored in UserDefaults — see DebridTokens).
enum DebridSecrets {
    static let rdToken = ""
    static let torboxToken = ""
    static let premiumizeToken = ""
}
