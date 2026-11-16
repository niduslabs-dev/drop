import Foundation

/// Checks a staged app before Drop installs it, and staples the DMG's notarization ticket
/// into an app that has none.
///
/// Drop runs these during staging, while its popup shows, so none of them costs the user a
/// wait. Every function is synchronous or `async`, safe to call off the main thread, and
/// touches no UI. The usual order for a staged app:
///
/// 1. `ticket(fromDMG:)`, then `staple(_:into:)` when the app has no ticket of its own.
///    Stapling first means the assessment and Gatekeeper's first launch see the ticket, and
///    an offline first launch works.
/// 2. `verdict(app:)`: `validate`, `signingInfo` and `assess` combined into what the popup
///    shows (install, warn with Install Anyway, or a hard stop).
/// 3. On an update, `sameDeveloper(new:installed:)` against the copy being replaced.
///
/// Signatures are read with the public Code Signing Services API. Two calls have no public
/// header and are looked up at run time (`SecAssessmentCreate`, `SecStaticCodeCancelValidation`):
/// see `SecuritySPI`. Nothing here asks for a keychain item or a signing identity.
public enum Verifier {}
