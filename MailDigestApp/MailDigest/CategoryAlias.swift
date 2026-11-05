import MailDigestCore

/// On macOS `import Foundation` re-exports `ObjectiveC.Category`, which makes an unqualified
/// `Category` ambiguous. This alias resolves it to the core enum for the whole app module.
/// It routes via `EmailCategory` because core also declares `enum MailDigestCore` (a namespace
/// marker), so `MailDigestCore.Category` would resolve inside that enum instead of the module.
typealias Category = EmailCategory
