@testable import MailDigestCore

/// On macOS `import Foundation` re-exports `ObjectiveC.Category`, which shadows
/// `MailDigestCore.Category` in unqualified type lookups. This module-level alias
/// resolves `Category` back to the core enum for every test file. It routes via
/// `EmailCategory` because the module also declares `enum MailDigestCore`, so a
/// `MailDigestCore.Category` qualifier would resolve inside that enum instead.
typealias Category = EmailCategory
