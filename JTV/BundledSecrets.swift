/// Bundled credentials for the tvOS build.
///
/// tvOS has no practical text entry for long tokens/URLs, and a
/// Signulous delete-and-reinstall wipes the app sandbox, so the
/// owner's ruling is that credentials are bundled INTO the build.
///
/// What lives here vs. elsewhere (two files, two readers):
/// `DebridTokens` — the functional debrid reader — does NOT
/// read this file; it falls back to `DebridSecrets`, which the
/// CI workflow regenerates from the same three repo secrets
/// (RD_TOKEN / TORBOX_TOKEN / PREMIUMIZE_TOKEN) with the same
/// base64 mechanism as this file, so the bundled values reach
/// DebridTokens through DebridSecrets. This file
/// (`BundledSecrets`) carries `mfURL` (the MediaFusion fallback
/// read by MovieService.MediaFusion.baseURL), the PIN hash +
/// `pinConfigured` (read by the PIN gate), and the debrid token
/// values the Settings status rows read.
///
/// The copy committed here carries EMPTY defaults on purpose —
/// no credential ever lives in source control. The CI workflow
/// regenerates this file from base64-encoded secrets before
/// compiling; when it does not, every consumer falls back to an
/// empty/unconfigured state exactly as the iOS build does with
/// an empty DebridSecrets.
enum BundledSecrets {
    static let rdToken = ""
    static let torboxToken = ""
    static let premiumizeToken = ""
    static let mfURL = ""
    static let pinHash = ""
    static let pinConfigured = false
}
